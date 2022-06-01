pragma solidity ^0.8.13;

import "openzeppelin/token/ERC1155/ERC1155.sol";
import "openzeppelin/token/ERC721/IERC721.sol";
import "openzeppelin/token/ERC20/IERC20.sol";
import "openzeppelin/utils/cryptography/MerkleProof.sol";
import "gpl/interfaces/IAuctionHouse.sol";
//import "openzeppelin/proxy/Clones.sol";
import "clones-with-immutable-args/ClonesWithImmutableArgs.sol";
import "./interfaces/IStarNFT.sol";
import "./TransferProxy.sol";
import "./BrokerImplementation.sol";

contract NFTBondController {
    bytes32 public immutable DOMAIN_SEPARATOR;

    string public constant name = "Astaria NFT Bond Vault";
    IERC20 public immutable WETH;
    IStarNFT public immutable COLLATERAL_VAULT;
    TransferProxy public immutable TRANSFER_PROXY;
    address BROKER_IMPLEMENTATION;

    uint256 LIQUIDATION_FEE; // a percent(13) then mul by 100

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
        // bytes32 root; // root for the appraisal merkle tree provided by the appraiser
        address appraiser; // address of the appraiser for the BondVault
        //        uint256 totalSupply;
        //        uint256 balance; // WETH balance of vault=
        //        mapping(uint256 => Loan[]) loans; // all open borrows in vault
        //        uint256 loanCount;
        uint256 expiration; // expiration for lenders to add assets and expiration when borrowers cannot create new borrows
        //        uint256 maturity; // epoch when the loan becomes due
        address broker; //cloned proxy
    }

    // could be replaced with a single byte32 value, pass in merkle proof to liquidate
    //    struct Loan {
    //        //        uint256 collateralVault; // ERC721, 1155 will be wrapped to create a singular tokenId
    //        uint256 amount; // loans are only in wETH
    //        uint256 interestRate; // rate of interest accruing on the borrow (should be in seconds to make calculations easy)
    //        uint256 start; // epoch time of last interest accrual
    //        uint256 end; // epoch time at which the loan must be repaid
    //        // lienPosition should be managed on the CollateralVault
    ////        bytes32 bondVault;
    //        //        uint8 lienPosition; // position of repayment, borrower can take out multiple loans on the same NFT, if the NFT becomes liquidated the lowest lien psoition is repaid first
    //        uint256 schedule; // percentage margin before the borrower needs to repay
    //    }

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
        LIQUIDATION_FEE = 3;
        uint256 chainId;
        assembly {
            chainId := chainid()
        }
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256("NFTBondController"),
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
    // keccak256("Permit(address owner,address spender,bool approved,uint256 nonce,uint256 deadline)");
    //    bytes32 private constant PERMIT_SIGNATURE_HASH =
    //        keccak256(
    //            "Permit(address owner,address spender,bool approved,uint256 nonce,uint256 deadline)"
    //        );
    bytes32 private constant NEW_VAULT_SIGNATURE_HASH =
        keccak256(
            "NewBondVault(address appraiser,bytes32 root,uint256 expiration,uint256 nonce,uint256 deadline,uint256 maturity)"
        );

    //    function permit(
    //        address owner_,
    //        address spender,
    //        bool approved,
    //        uint256 deadline,
    //        uint8 v,
    //        bytes32 r,
    //        bytes32 s
    //    ) external {
    //        require(owner_ != address(0), "ERC1155: Owner cannot be 0");
    //        require(block.timestamp < deadline, "ERC1155: Expired");
    //        bytes32 digest = keccak256(
    //            abi.encodePacked(
    //                EIP191_PREFIX_FOR_EIP712_STRUCTURED_DATA,
    //                DOMAIN_SEPARATOR,
    //                keccak256(
    //                    abi.encode(
    //                        PERMIT_SIGNATURE_HASH,
    //                        owner_,
    //                        spender,
    //                        approved,
    //                        tokenNonces[owner_]++,
    //                        deadline
    //                    )
    //                )
    //            )
    //        );
    //        address recoveredAddress = ecrecover(digest, v, r, s);
    //        require(recoveredAddress == owner_, "ERC1155: Invalid Signature");
    //        _setApprovalForAll(owner_, spender, approved);
    //    }

    // _verify() internal
    // merkle tree verifier
    function verifyMerkleBranch(
        bytes32[] calldata proof,
        bytes32 leaf,
        bytes32 root
    ) public view returns (bool) {
        bool isValidLeaf = MerkleProof.verify(proof, root, leaf);
        return isValidLeaf;
        //        return true;
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
            "NFTBondController.newBondVault(): Appraiser address cannot be zero"
        );
        require(
            bondVaults[root].appraiser == address(0),
            "NFTBondController.newBondVault(): Root of BondVault already instantiated"
        );
        require(
            block.timestamp < deadline,
            "NFTBondController.newBondVault(): Expired"
        );
        bytes32 digest = keccak256(
            encodeBondVaultHash(
                appraiser,
                root,
                expiration,
                appraiserNonces[msg.sender]++,
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

    function refinanceLoan(
        bytes32 bondVaultOutgoing,
        bytes32 bondVaultIncoming,
        uint256 collateralVault,
        uint256 outgoingIndex,
        uint256 newInterestRate,
        uint256 newDuration
    ) external {
        require(
            bondVaults[bondVaultIncoming].expiration < block.timestamp,
            "bond vault has expired"
        );
        BrokerImplementation broker = BrokerImplementation(
            bondVaults[bondVaultOutgoing].broker
        );
        uint256 buyout = broker.getBuyout(collateralVault, outgoingIndex);
        (
            uint256 amount,
            uint256 interestRate,
            uint256 start,
            uint256 duration,
            uint256 schedule,
            uint256 lienPosition
        ) = getLoan(broker, collateralVault, outgoingIndex);
        //move this into the get
        {
            require(
                newInterestRate <= interestRate + (interestRate * 500) / 1000
            ); //TODO: min "beat price"
            uint256 minDuration = start + duration + (duration * 500) / 1000;

            require(newDuration >= minDuration); //TODO: min "beat duration"

            broker.repayLoan(collateralVault, outgoingIndex, buyout);
        }
        TRANSFER_PROXY.tokenTransferFrom(
            address(WETH),
            address(msg.sender),
            address(this),
            buyout
        );
        broker = BrokerImplementation(bondVaults[bondVaultIncoming].broker);
        {
            uint256 newIndex = broker.issueLoan(
                collateralVault,
                buyout,
                newInterestRate,
                newDuration,
                schedule,
                lienPosition
            );
            //transfer proxy in the weth from sender to the bondvault

            //if we dont create here perhaps we require that a bondvault is created before you can refinance,

            _swapLien(
                bondVaultOutgoing,
                bondVaultIncoming,
                collateralVault,
                outgoingIndex,
                newIndex,
                buyout
            );
        }
    }

    function _newBondVault(
        address appraiser,
        bytes32 root,
        bytes32 contentHash,
        uint256 expiration,
        uint256 buyout
    ) internal {
        //        address proxy = Clones.cloneDeterministic(BEACON_CLONE, root);
        //        address[] memory tokens = new address[](1);
        //        tokens[0] = address(WETH);
        //        BrokerImplementation(proxy).initialize(tokens, address(TRANSFER_PROXY));

        //        address proxy = Clones.predictDeterministicAddress(
        //            BEACON_CLONE,
        //            root,
        //            address(this)
        //        );

        address vault = ClonesWithImmutableArgs.clone(
            BROKER_IMPLEMENTATION,
            abi.encodePacked(
                address(this),
                address(WETH),
                address(this),
                root,
                expiration,
                buyout
            )
        );
        BondVault storage bondVault = bondVaults[root];
        bondVault.appraiser = appraiser;
        bondVault.expiration = expiration;
        bondVault.broker = vault;

        brokers[vault] = root;

        emit NewBondVault(appraiser, vault, root, contentHash, expiration);
    }

    // maxAmount so the borrower has the option to borrow less
    // collateralVault is a tokenId that is precomputed off chain using the elements from the request
    function commitToLoan(
        bytes32[] calldata proof,
        bytes32 bondVault,
        uint256 collateralVault,
        uint256 maxAmount,
        uint256 interestRate,
        uint256 duration,
        uint256 amount,
        uint8 lienPosition,
        uint256 schedule
    ) external {
        require(
            msg.sender == COLLATERAL_VAULT.ownerOf(collateralVault),
            "NFTBondController.commitToLoan(): Owner of the collateral vault must be msg.sender"
        );
        require(
            bondVaults[bondVault].appraiser != address(0),
            "NFTBondController.commitToLoan(): Attempting to instantiate an unitialized vault"
        );
        require(
            maxAmount >= amount,
            "NFTBondController.commitToLoan(): Attempting to borrow more than maxAmount"
        );
        require(
            amount <= WETH.balanceOf(bondVaults[bondVault].broker),
            "NFTBondController.commitToLoan():  Attempting to borrow more than available in the specified vault"
        );
        // filler hashing schema for merkle tree
        bytes32 leaf = keccak256(
            abi.encode(
                bytes32(collateralVault),
                maxAmount,
                interestRate,
                duration,
                lienPosition,
                schedule
            )
        );
        require(
            verifyMerkleBranch(proof, leaf, bondVault),
            "NFTBondController.commitToLoan(): Verification of provided merkle branch failed for the bondVault and parameters"
        );

        //ensure that we have space left in our appraisal value to take on more debt or refactor so each collateral
        //can only have one loan per bondvault associated to it

        //reach out to the bond vault and send loan to user

        uint256 newIndex = BrokerImplementation(bondVaults[bondVault].broker)
            .issueLoan(
                collateralVault,
                amount,
                interestRate,
                duration,
                schedule,
                lienPosition
            );

        _addLien(collateralVault, bondVault, lienPosition, newIndex, amount);

        //        TRANSFER_PROXY.tokenTransferFrom(
        //            address(WETH),
        //            bondVaults[bondVault].broker,
        //            address(msg.sender),
        //            amount
        //        );
        //        bondVaults[bondVault].loanCount++;
        //        bondVaults[bondVault].balance -= amount;
        emit NewLoan(bondVault, collateralVault, amount);
    }

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

    function removeLien(uint256 collateralVault, uint256 position)
        external
        onlyVaults
    {
        _removeLien(msg.sender, collateralVault, position);
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
        require(
            block.timestamp < bondVaults[bondVault].expiration,
            "lendToVault: expiration exceeded"
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
            uint256
        )
    {
        return broker.loans(collateralVault, index);
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
            uint256 schedule,
            uint256 lienPosition
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
        require(
            canLiquidate(bondVault, index, collateralVault),
            "liquidate: borrow is healthy"
        );
        //grab all lien positions compute all outstanding
        (
            address[] memory brokers,
            ,
            uint256[] memory indexes
        ) = COLLATERAL_VAULT.getLiens(collateralVault);

        for (uint256 i = 0; i < brokers.length; i++) {
            reserve += BrokerImplementation(brokers[i]).liquidateLoan(
                collateralVault,
                indexes[i]
            );
        }

        reserve += ((reserve * LIQUIDATION_FEE) / 100);

        COLLATERAL_VAULT.auctionVault(collateralVault, reserve, msg.sender);
    }
}
