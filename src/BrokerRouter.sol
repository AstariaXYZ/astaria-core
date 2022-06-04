pragma solidity ^0.8.13;

import "openzeppelin/token/ERC1155/ERC1155.sol";
import "openzeppelin/token/ERC721/IERC721.sol";
import "openzeppelin/token/ERC20/IERC20.sol";
import "openzeppelin/utils/cryptography/MerkleProof.sol";
import "gpl/interfaces/IAuctionHouse.sol";
import "clones-with-immutable-args/ClonesWithImmutableArgs.sol";
import "./interfaces/IStarNFT.sol";
import "./TransferProxy.sol";
import "./BrokerImplementation.sol";

interface IInvoker {
    function onBorrowAndBuy(
        bytes calldata data,
        address token,
        uint256 amount,
        address payable recipient
    ) external returns (bool);
}

abstract contract Invoker is IInvoker {
    function onBorrowAndBuy(
        IERC20 asset,
        uint256 maxSpend,
        address recipient
    ) external returns (bool) {
        //        asset.transferFrom(msg.sender, address(this), purchasePrice);

        return true;
    }
}

contract BrokerRouter {
    bytes32 public immutable DOMAIN_SEPARATOR;

    string public constant name = "Astaria NFT Bond Vault";
    IERC20 public immutable WETH;
    IStarNFT public immutable COLLATERAL_VAULT;
    TransferProxy public immutable TRANSFER_PROXY;
    address BROKER_IMPLEMENTATION;

    uint256 public LIQUIDATION_FEE_PERCENT; // a percent(13) then mul by 100
    uint64 public MIN_INTEREST_BPS; // a percent(13) then mul by 100
    uint64 public MIN_DURATION_INCREASE; // a percent(13) then mul by 100

    mapping(bytes32 => BondVault) public bondVaults;
    mapping(address => bytes32) public brokers;
    mapping(address => uint256) public appraiserNonces;

    event NewLoan(bytes32 bondVault, uint256 collateralVault, uint256 amount);
    event Repayment(
        bytes32 bondVault,
        uint256 collateralVault,
        uint256 index,
        uint256 amount
    );
    event Liquidation(
        uint256 collateralVault,
        bytes32[] bondVaults,
        uint256[] indexes,
        uint256 recovered
    );
    event NewBondVault(
        address appraiser,
        address broker,
        bytes32 bondVault,
        bytes32 contentHash,
        uint256 expiration
    );
    event RedeemBond(
        bytes32 bondVault,
        uint256 amount,
        address indexed redeemer
    );

    error InvalidAddress(address);

    struct BondVault {
        address appraiser; // address of the appraiser for the BondVault
        uint256 expiration; // expiration for lenders to add assets and expiration when borrowers cannot create new borrows
        address broker; //cloned proxy
    }

    constructor(
        address _WETH,
        address _COLLATERAL_VAULT,
        address _TRANSFER_PROXY,
        address _BEACON_CLONE
    ) {
        WETH = IERC20(_WETH);
        COLLATERAL_VAULT = IStarNFT(_COLLATERAL_VAULT);
        TRANSFER_PROXY = TransferProxy(_TRANSFER_PROXY);
        BROKER_IMPLEMENTATION = _BEACON_CLONE;
        LIQUIDATION_FEE_PERCENT = 13;
        MIN_INTEREST_BPS = 5;
        MIN_DURATION_INCREASE = 14 days;
        uint256 chainId;
        assembly {
            chainId := chainid()
        }
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256("BrokerRouter"),
                keccak256("1"),
                chainId,
                address(this)
            )
        );
        WETH.approve(address(TRANSFER_PROXY), type(uint256).max);
    }

    // See https://eips.ethereum.org/EIPS/eip-191
    string private constant EIP191_PREFIX_FOR_EIP712_STRUCTURED_DATA =
        "\x19\x01";

    bytes32 private constant NEW_VAULT_SIGNATURE_HASH =
        keccak256(
            "NewBondVault(address appraiser,bytes32 root,uint256 expiration,uint256 nonce,uint256 deadline,uint256 maturity)"
        );

    // _verify() internal
    // merkle tree verifier
    function verifyMerkleBranch(
        bytes32[] calldata proof,
        bytes32 leaf,
        bytes32 root
    ) public view returns (bool) {
        bool isValidLeaf = MerkleProof.verify(proof, root, leaf);
        return isValidLeaf;
    }

    // verifies the signature on the root of the merkle tree to be the appraiser
    // we need an additional method to prevent a griefing attack where the signature is stripped off and reserrved by an attacker
    function newBondVault(
        address appraiser,
        bytes32 root,
        uint256 expiration,
        uint256 deadline,
        uint256 buyout,
        bytes32 contentHash,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        require(
            appraiser != address(0),
            "BrokerRouter.newBondVault(): Appraiser address cannot be zero"
        );
        require(
            bondVaults[root].appraiser == address(0),
            "BrokerRouter.newBondVault(): Root of BondVault already instantiated"
        );
        require(
            block.timestamp < deadline,
            "BrokerRouter.newBondVault(): Expired"
        );
        bytes32 digest = keccak256(
            encodeBondVaultHash(
                appraiser,
                root,
                expiration,
                appraiserNonces[appraiser]++,
                deadline,
                buyout
            )
        );

        address recoveredAddress = ecrecover(digest, v, r, s);
        require(
            recoveredAddress == appraiser,
            "newBondVault: Invalid Signature"
        );

        _newBondVault(appraiser, root, contentHash, expiration, buyout);
    }

    function encodeBondVaultHash(
        address appraiser,
        bytes32 root,
        uint256 expiration,
        uint256 appraiserNonce,
        uint256 deadline,
        uint256 buyout
    ) public view returns (bytes memory) {
        return
            abi.encodePacked(
                EIP191_PREFIX_FOR_EIP712_STRUCTURED_DATA,
                DOMAIN_SEPARATOR,
                keccak256(
                    abi.encode(
                        NEW_VAULT_SIGNATURE_HASH,
                        appraiser,
                        root,
                        expiration,
                        appraiserNonce,
                        deadline
                    )
                )
            );
    }

    function borrowAndBuy(
        bytes32[] calldata proof,
        bytes32 bondVault,
        uint256[7] calldata loanTerms,
        address invoker,
        uint256 purchasePrice, //the max to spend on the "buy portion of the txn"
        bytes calldata purchaseData
    ) external {
        require(
            msg.sender == COLLATERAL_VAULT.ownerOf(loanTerms[0]),
            "BrokerRouter.borrowAndBuy(): Owner of the collateral vault must be msg.sender"
        );
        //router must be approved for the star nft to take a loan,
        BrokerImplementation(bondVaults[bondVault].broker).commitToLoan(
            proof,
            loanTerms[0], //collateral vault
            loanTerms[1],
            loanTerms[2],
            loanTerms[3],
            loanTerms[4],
            loanTerms[5],
            loanTerms[6],
            address(this)
        );

        //        WETH.approve(purchaseTarget, purchasePrice);

        require(
            purchasePrice <= loanTerms[0],
            "purchase price cannot be for more than your aggregate loan"
        );

        WETH.transfer(invoker, purchasePrice);
        require(
            IInvoker(invoker).onBorrowAndBuy(
                purchaseData, // calldata for the invoker
                address(WETH),
                purchasePrice, //purchase
                payable(msg.sender) // recipient
            ),
            "borrow and buy failed"
        );
    }

    //    function refinanceLoan(
    //        bytes32[] calldata dealBrokers, //outgoing, incoming
    //        bytes32[] calldata proof,
    //        uint256[] calldata outgoingLoan,
    //        uint256[] calldata incomingLoan //        uint256 maxAmount, //        uint256 interestRate, //        uint256 duration, //        uint256 amount, //        uint256 lienPosition, //        uint256 schedule
    //    ) external {
    //        //        loanDetails2[0] = uint256(100000000000000000000); //maxAmount
    //        //        loanDetails2[1] = uint256(50000000000000000000 / 2); //interestRate
    //        //        loanDetails2[2] = uint256(block.timestamp + 10 minutes * 2); //duration
    //        //        loanDetails2[3] = uint256(1 ether); //amount
    //        //        loanDetails2[4] = uint256(0); //lienPosition
    //        //        loanDetails2[5] = uint256(50); //schedule
    //        require(
    //            bondVaults[dealBrokers[1]].expiration > block.timestamp,
    //            "bond vault has expired"
    //        );
    //        //        _validateLoanTerms(
    //        //            proof,
    //        //            bondVaultIncoming,
    //        //            collateralVault,
    //        //            loanDetails[0],
    //        //            loanDetails[1],
    //        //            loanDetails[2],
    //        //            loanDetails[3],
    //        //            loanDetails[4],
    //        //            loanDetails[5]
    //        //        );
    //
    //        require(lienPosition <= incomingLoan[4], "Invalid Appraisal"); // must have appraised a valid lien position
    //        {
    //            uint256 newIndex = BrokerImplementation(
    //                bondVaults[dealBrokers[1]].broker
    //            ).buyoutLoan(
    //                    BrokerImplementation(bondVaults[dealBrokers[0]].broker),
    //                    outgoingLoan[0],
    //                    outgoingLoan[1],
    //                    proof,
    //                    incomingLoan
    //                );
    //        }
    //    }

    //uint256 collateralVault,
    //        uint256 outgoingIndex,
    //        uint256 buyout,
    //        bytes32[] calldata proof,
    //        uint256[] memory loanDetails
    function _newBondVault(
        address appraiser,
        bytes32 root,
        bytes32 contentHash,
        uint256 expiration,
        uint256 buyout
    ) internal {
        address broker = ClonesWithImmutableArgs.clone(
            BROKER_IMPLEMENTATION,
            abi.encodePacked(
                address(COLLATERAL_VAULT),
                address(WETH),
                address(this),
                root,
                expiration,
                buyout,
                appraiser
            )
        );
        BondVault storage bondVault = bondVaults[root];
        bondVault.appraiser = appraiser;
        bondVault.expiration = expiration;
        bondVault.broker = broker;

        brokers[broker] = root;

        emit NewBondVault(appraiser, broker, root, contentHash, expiration);
    }

    //    function _validateLoanTerms(
    //        bytes32[] calldata proof,
    //        bytes32 bondVault,
    //        uint256 collateralVault,
    //        uint256 maxAmount,
    //        uint256 interestRate,
    //        uint256 duration,
    //        uint256 amount,
    //        uint256 lienPosition,
    //        uint256 schedule
    //    ) internal {
    //        require(
    //            bondVaults[bondVault].appraiser != address(0),
    //            "BrokerRouter.commitToLoan(): Attempting to instantiate an unitialized vault"
    //        );
    //        require(
    //            maxAmount >= amount,
    //            "BrokerRouter.commitToLoan(): Attempting to borrow more than maxAmount"
    //        );
    //        require(
    //            amount <= WETH.balanceOf(bondVaults[bondVault].broker),
    //            "BrokerRouter.commitToLoan():  Attempting to borrow more than available in the specified vault"
    //        );
    //        // filler hashing schema for merkle tree
    //        bytes32 leaf = keccak256(
    //            abi.encode(
    //                bytes32(collateralVault),
    //                maxAmount,
    //                interestRate,
    //                duration,
    //                lienPosition,
    //                schedule
    //            )
    //        );
    //        require(
    //            verifyMerkleBranch(proof, leaf, bondVault),
    //            "BrokerRouter.commitToLoan(): Verification of provided merkle branch failed for the bondVault and parameters"
    //        );
    //    }

    //
    //    // maxAmount so the borrower has the option to borrow less
    //    // collateralVault is a tokenId that is precomputed off chain using the elements from the request
    //    function commitToLoan(
    //        bytes32[] calldata proof,
    //        bytes32 bondVault,
    //        uint256 collateralVault,
    //        uint256 maxAmount,
    //        uint256 interestRate,
    //        uint256 duration,
    //        uint256 amount,
    //        uint256 lienPosition,
    //        uint256 schedule
    //    ) public {
    //        require(
    //            msg.sender == COLLATERAL_VAULT.ownerOf(collateralVault) ||
    //                msg.sender == address(this),
    //            "BrokerRouter.commitToLoan(): Owner of the collateral vault must be msg.sender"
    //        );
    //        _validateLoanTerms(
    //            proof,
    //            bondVault,
    //            collateralVault,
    //            maxAmount,
    //            interestRate,
    //            duration,
    //            amount,
    //            lienPosition,
    //            schedule
    //        );
    //
    //        //ensure that we have space left in our appraisal value to take on more debt or refactor so each collateral
    //        //can only have one loan per bondvault associated to it
    //
    //        //reach out to the bond vault and send loan to user
    //
    //        uint256 newIndex = BrokerImplementation(bondVaults[bondVault].broker)
    //            .issueLoan(
    //                address(msg.sender),
    //                collateralVault,
    //                amount,
    //                interestRate,
    //                duration,
    //                schedule,
    //                lienPosition
    //            );
    //
    //        emit NewLoan(bondVault, collateralVault, amount);
    //    }

    modifier onlyVaults() {
        require(
            brokers[msg.sender] != bytes32(0),
            "this vault has not been initialized"
        );
        _;
    }

    function _addLien(
        uint256 collateralVault,
        bytes32 bondVault,
        uint256 position,
        uint256 newIndex,
        uint256 amount
    ) internal {
        address broker = address(bondVaults[bondVault].broker);
        COLLATERAL_VAULT.manageLien(
            collateralVault,
            IStarNFT.LienAction.ENCUMBER,
            abi.encode(broker, position, newIndex, amount)
        );
    }

    function addLien(
        uint256 collateralVault,
        bytes32 bondVault,
        uint256 lienPosition,
        uint256 newIndex,
        uint256 amount
    ) external onlyVaults {
        _addLien(collateralVault, bondVault, lienPosition, newIndex, amount);
    }

    function updateLien(
        uint256 collateralVault,
        uint256 position,
        address payee
    ) external onlyVaults {
        if (brokers[payee] != bytes32(0)) {
            uint256 newIndex = BrokerImplementation(payee).getLoanCount(
                collateralVault
            );

            if (newIndex != uint256(0)) {
                unchecked {
                    newIndex--;
                }
            }

            (uint256 amount, , , , , , ) = getLoan(
                BrokerImplementation(payee),
                collateralVault,
                newIndex
            );

            _swapLien(
                brokers[msg.sender],
                brokers[payee],
                collateralVault,
                position,
                newIndex,
                amount
            );
        } else {
            _removeLien(msg.sender, collateralVault, position);
        }
    }

    function _removeLien(
        address bondVault,
        uint256 collateralVault,
        uint256 index
    ) internal {
        COLLATERAL_VAULT.manageLien(
            collateralVault,
            IStarNFT.LienAction.UN_ENCUMBER,
            abi.encode(bondVault, index)
        );
    }

    function _swapLien(
        bytes32 bondVaultOld,
        bytes32 bondVaultNew,
        uint256 collateralVault,
        uint256 lienPosition,
        uint256 newIndex,
        uint256 amountOwed
    ) internal {
        COLLATERAL_VAULT.manageLien(
            collateralVault,
            IStarNFT.LienAction.SWAP_VAULT,
            abi.encode(
                bondVaults[bondVaultOld].broker,
                bondVaults[bondVaultNew].broker,
                lienPosition,
                newIndex,
                amountOwed
            )
        );
    }

    function lendToVault(bytes32 bondVault, uint256 amount) external {
        TRANSFER_PROXY.tokenTransferFrom(
            address(WETH),
            address(msg.sender),
            address(this),
            amount
        );
        WETH.approve(bondVaults[bondVault].broker, amount);
        require(
            bondVaults[bondVault].broker != address(0),
            "lendToVault: vault doesn't exist"
        );
        BrokerImplementation(bondVaults[bondVault].broker).deposit(
            amount,
            address(msg.sender)
        );
    }

    function getLiens(uint256 collateralVault)
        public
        view
        returns (
            address[] memory,
            uint256[] memory,
            uint256[] memory
        )
    {
        return COLLATERAL_VAULT.getLiens(collateralVault);
    }

    function getLoan(
        BrokerImplementation broker,
        uint256 collateralVault,
        uint256 index
    )
        public
        view
        returns (
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256
        )
    {
        return broker.getLoan(collateralVault, index);
    }

    function getBroker(bytes32 bondVault) external view returns (address) {
        return bondVaults[bondVault].broker;
    }

    function isActiveBroker(address bondVault) external view returns (bool) {
        return
            brokers[bondVault] != bytes32(0) &&
            bondVaults[brokers[bondVault]].broker == bondVault;
    }

    function canLiquidate(
        bytes32 bondVault,
        uint256 index,
        uint256 collateralVault
    ) public view returns (bool) {
        BrokerImplementation broker = BrokerImplementation(
            bondVaults[bondVault].broker
        );
        uint256 interestAccrued = broker.getInterest(index, collateralVault);
        (
            uint256 amount,
            uint256 interest,
            uint256 start,
            uint256 duration,
            uint256 lienPosition,
            uint256 schedule,
            uint256 buyout
        ) = getLoan(broker, collateralVault, index);
        uint256 maxInterest = amount * schedule; //TODO: if schedule is 0, then this is a bug

        return
            maxInterest > interestAccrued ||
            (start + duration >= block.timestamp && amount > 0);
    }

    // person calling liquidate should get some incentive from the auction
    function liquidate(
        bytes32 bondVault,
        uint256 index,
        uint256 collateralVault
    ) external returns (uint256 reserve) {
        BrokerImplementation broker = BrokerImplementation(
            bondVaults[bondVault].broker
        );
        require(
            broker.canLiquidate(collateralVault, index),
            "liquidate: borrow is healthy"
        );
        //grab all lien positions compute all outstanding
        (
            address[] memory brokers,
            ,
            uint256[] memory indexes
        ) = COLLATERAL_VAULT.getLiens(collateralVault);

        for (uint256 i = 0; i < brokers.length; i++) {
            reserve += BrokerImplementation(brokers[i]).moveToReceivership(
                collateralVault,
                indexes[i]
            );
        }

        reserve += ((reserve * LIQUIDATION_FEE_PERCENT) / 100);

        COLLATERAL_VAULT.auctionVault(
            collateralVault,
            reserve,
            address(msg.sender),
            LIQUIDATION_FEE_PERCENT
        );
    }
}
