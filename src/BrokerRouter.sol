pragma solidity ^0.8.13;
import {Auth, Authority} from "solmate/auth/Auth.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import "openzeppelin/token/ERC1155/ERC1155.sol";
import "openzeppelin/token/ERC721/IERC721.sol";
import "openzeppelin/token/ERC20/IERC20.sol";
import "openzeppelin/utils/cryptography/MerkleProof.sol";
import "gpl/interfaces/IAuctionHouse.sol";
import "clones-with-immutable-args/ClonesWithImmutableArgs.sol";
import {ICollateralVault} from "./interfaces/ICollateralVault.sol";
import {ILienToken} from "./interfaces/ILienToken.sol";
import {ITransferProxy} from "./interfaces/ITransferProxy.sol";
import {IBroker, BrokerImplementation} from "./BrokerImplementation.sol";
import {SafeERC20} from "openzeppelin/token/ERC20/utils/SafeERC20.sol";

interface IInvoker {
    function onBorrowAndBuy(
        bytes calldata data,
        address token,
        uint256 amount,
        address payable recipient
    ) external returns (bool);
}

//abstract contract Invoker is IInvoker {
//    function onBorrowAndBuy(
//        IERC20 asset,
//        uint256 maxSpend,
//        address recipient
//    ) external returns (bool) {
//        //        asset.transferFrom(msg.sender, address(this), purchasePrice);
//
//        return true;
//    }
//}

interface IBrokerRouter {
    struct Terms {
        address broker;
        bytes32[] proof;
        uint256 collateralVault;
        uint256 maxAmount;
        uint256 rate;
        uint256 duration;
        uint256 position;
        uint256 schedule;
    }
    struct BrokerParams {
        address appraiser;
        bytes32 root;
        uint256 expiration;
        uint256 deadline;
        uint256 buyout;
        bytes32 contentHash;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    struct CommitmentParams {
        Terms terms;
        uint256 amount;
    }

    struct BuyoutLienParams {
        IBrokerRouter.Terms outgoing;
        IBrokerRouter.Terms incoming;
    }

    struct RefinanceCheckParams {
        IBrokerRouter.Terms outgoing;
        IBrokerRouter.Terms incoming;
    }

    struct BorrowAndBuyParams {
        CommitmentParams[] commitments;
        address invoker;
        uint256 purchasePrice;
        bytes purchaseData;
        address receiver;
    }

    struct BondVault {
        address appraiser; // address of the appraiser for the BondVault
        uint256 expiration; // expiration for lenders to add assets and expiration when borrowers cannot create new borrows
        address broker; //cloned proxy
    }

    function newBondVault(BrokerParams memory params) external;

    function encodeBondVaultHash(
        address appraiser,
        bytes32 root,
        uint256 expiration,
        uint256 appraiserNonce,
        uint256 deadline,
        uint256 buyout
    ) external view returns (bytes memory);

    //    function buyoutLienPosition(BuyoutLienParams memory params) external;

    function commitToLoans(CommitmentParams[] calldata commitments) external;

    //    function requestLienPosition(
    //        uint256 collateralVault,
    //        bytes32 bondVault,
    //        uint256 lienPosition,
    //        uint256 newIndex,
    //        uint256 amount
    //    ) external;

    function lendToVault(bytes32 bondVault, uint256 amount) external;

    function getBroker(bytes32 bondVault) external view returns (address);

    function liquidate(uint256 collateralVault, uint256 position)
        external
        returns (uint256 reserve);

    function canLiquidate(uint256 collateralVault, uint256 position)
        external
        view
        returns (bool);

    function isValidRefinance(RefinanceCheckParams memory params)
        external
        view
        returns (bool);

    event Liquidation(
        uint256 collateralVault,
        uint256 position,
        uint256 reserve
    );
    event NewBondVault(
        address appraiser,
        address broker,
        bytes32 bondVault,
        bytes32 contentHash,
        uint256 expiration
    );

    error InvalidAddress(address);
    error InvalidRefinanceRate(uint256);
    error InvalidRefinanceDuration(uint256);
}

contract BrokerRouter is IBrokerRouter, Auth {
    bytes32 public immutable DOMAIN_SEPARATOR;
    using SafeERC20 for IERC20;
    string public constant name = "Astaria NFT Bond Vault";
    IERC20 public immutable WETH;
    ICollateralVault public immutable COLLATERAL_VAULT;
    ILienToken public immutable LIEN_TOKEN;
    ITransferProxy public immutable TRANSFER_PROXY;
    address VAULT_IMPLEMENTATION;
    address SOLO_IMPLEMENTATION;

    uint256 public LIQUIDATION_FEE_PERCENT; // a percent(13) then mul by 100
    uint64 public MIN_INTEREST_BPS; // a percent(13) then mul by 100
    uint64 public MIN_DURATION_INCREASE; // a percent(13) then mul by 100

    mapping(bytes32 => BondVault) public bondVaults;
    mapping(address => bytes32) public brokerHashes;
    mapping(address => bool) public appraisers;
    mapping(address => uint256) public appraiserNonces;

    constructor(
        Authority _AUTHORITY,
        address _WETH,
        address _COLLATERAL_VAULT,
        address _LIEN_TOKEN,
        address _TRANSFER_PROXY,
        address _VAULT_IMPL,
        address _SOLO_IMPL
    ) Auth(address(msg.sender), _AUTHORITY) {
        WETH = IERC20(_WETH);
        COLLATERAL_VAULT = ICollateralVault(_COLLATERAL_VAULT);
        LIEN_TOKEN = ILienToken(_LIEN_TOKEN);
        TRANSFER_PROXY = ITransferProxy(_TRANSFER_PROXY);
        VAULT_IMPLEMENTATION = _VAULT_IMPL;
        SOLO_IMPLEMENTATION = _SOLO_IMPL;
        LIQUIDATION_FEE_PERCENT = 13;
        MIN_INTEREST_BPS = 5; //5 bps
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
        WETH.safeApprove(address(TRANSFER_PROXY), type(uint256).max);
    }

    // See https://eips.ethereum.org/EIPS/eip-191
    string private constant EIP191_PREFIX_FOR_EIP712_STRUCTURED_DATA =
        "\x19\x01";

    bytes32 private constant NEW_VAULT_SIGNATURE_HASH =
        keccak256(
            "NewBondVault(address appraiser,bytes32 root,uint256 expiration,uint256 nonce,uint256 deadline)"
        );

    // _verify() internal
    //     merkle tree verifier
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

    function newSoloVault(BrokerParams memory params) external {
        require(params.appraiser == msg.sender);
        _newBondVault(params, false);
    }

    modifier onlyAppraisers(address appraiser) {
        require(appraisers[appraiser] == true, "sender is not an appraiser");
        _;
    }

    function setAppraisers(address[] memory vaultAppraisers)
        external
        requiresAuth
    {
        for (uint256 i = 0; i < vaultAppraisers.length; ++i) {
            appraisers[vaultAppraisers[i]] = true;
        }
    }

    function newBondVault(BrokerParams memory params)
        external
        onlyAppraisers(params.appraiser)
    {
        _newBondVault(params, true);
    }

    function _newBondVault(BrokerParams memory params, bool vault) internal {
        require(
            params.appraiser != address(0),
            "BrokerRouter.newBondVault(): Appraiser address cannot be zero"
        );
        require(
            bondVaults[params.root].appraiser == address(0),
            "BrokerRouter.newBondVault(): Root of BondVault already instantiated"
        );
        require(
            block.timestamp < params.deadline,
            "BrokerRouter.newBondVault(): Expired"
        );
        bytes32 digest = keccak256(
            encodeBondVaultHash(
                params.appraiser,
                params.root,
                params.expiration,
                appraiserNonces[params.appraiser]++,
                params.deadline,
                params.buyout
            )
        );

        address recoveredAddress = ecrecover(
            digest,
            params.v,
            params.r,
            params.s
        );
        require(
            recoveredAddress == params.appraiser,
            "newBondVault: Invalid Signature"
        );
        address implementation;
        if (vault) {
            implementation = VAULT_IMPLEMENTATION;
        } else {
            implementation = SOLO_IMPLEMENTATION;
        }

        address broker = ClonesWithImmutableArgs.clone(
            implementation,
            abi.encodePacked(
                address(COLLATERAL_VAULT),
                address(WETH),
                address(this),
                params.root,
                params.expiration,
                params.buyout,
                recoveredAddress
            )
        );
        BondVault storage bondVault = bondVaults[params.root];
        bondVault.appraiser = params.appraiser;
        bondVault.expiration = params.expiration;
        bondVault.broker = broker;

        brokerHashes[broker] = params.root;

        emit NewBondVault(
            params.appraiser,
            broker,
            params.root,
            params.contentHash,
            params.expiration
        );
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

    function _validateCommitment(CommitmentParams calldata c) internal {
        require(
            msg.sender == COLLATERAL_VAULT.ownerOf(c.terms.collateralVault),
            "invalid sender for collateralVault"
        );
    }

    function _executeCommitment(CommitmentParams calldata c) internal {
        _validateCommitment(c);
        _borrow(c.terms, c.amount, address(this));
    }

    function borrowAndBuy(BorrowAndBuyParams calldata params) external {
        uint256 spendableBalance;
        for (uint256 i = 0; i < params.commitments.length; ++i) {
            _executeCommitment(params.commitments[i]);
            spendableBalance += params.commitments[i].amount; //amount borrowed
        }
        require(
            params.purchasePrice <= spendableBalance,
            "purchase price cannot be for more than your aggregate loan"
        );

        WETH.safeApprove(params.invoker, params.purchasePrice);
        require(
            IInvoker(params.invoker).onBorrowAndBuy(
                params.purchaseData, // calldata for the invoker
                address(WETH), // token
                params.purchasePrice, //max approval
                payable(msg.sender) // recipient
            ),
            "borrow and buy failed"
        );
        if (spendableBalance - params.purchasePrice > uint256(0)) {
            WETH.safeTransfer(
                msg.sender,
                spendableBalance - params.purchasePrice
            );
        }
    }

    function _borrow(
        IBrokerRouter.Terms memory terms,
        uint256 amount,
        address receiver
    ) internal returns (uint256) {
        //router must be approved for the star nft to take a loan,
        BrokerImplementation(terms.broker).commitToLoan(
            terms,
            amount,
            receiver
        );
        if (receiver == address(this)) return amount;
        return uint256(0);
    }

    function buyoutLien(
        IBrokerRouter.Terms memory outgoingTerms,
        IBrokerRouter.Terms memory incomingTerms //        onlyNetworkBrokers( //            outgoingTerms.collateralVault, //            outgoingTerms.position //        )
    ) external {
        {
            BrokerImplementation(incomingTerms.broker).buyoutLien(
                outgoingTerms,
                incomingTerms
            );
        }
    }

    function commitToLoans(CommitmentParams[] calldata commitments) external {
        for (uint256 i = 0; i < commitments.length; ++i) {
            _executeCommitment(commitments[i]);
        }
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
            brokerHashes[msg.sender] != bytes32(0),
            "this vault has not been initialized"
        );
        _;
    }

    function _addLien(ILienToken.LienActionEncumber memory params) internal {
        //        COLLATERAL_VAULT.manageLien(
        //            ILienToken.LienAction.ENCUMBER,
        //            abi.encode(params)
        //        );

        LIEN_TOKEN.createLien(params);
    }

    function requestLienPosition(ILienToken.LienActionEncumber calldata params)
        external
        onlyVaults
        returns (bool)
    {
        _addLien(ILienToken.LienActionEncumber(params.terms, params.amount));
        return true;
    }

    //    struct LienPayments {
    //        ILienToken.LienActionPayment[] payments;
    //    }

    //    function _updateLiens(BulkLienActionSwap params) internal {}

    //    function updateLiens(BulkLienActionSwap params) external onlyVaults {
    //        _updateLien(params);
    //    }

    //    function updateLien(
    //        uint256 collateralVault,
    //        uint256 position,
    //        address payee
    //    ) external onlyVaults {
    //        if (brokers[payee] != bytes32(0)) {
    //            uint256 newIndex = BrokerImplementation(payee).getLoanCount(
    //                collateralVault
    //            );
    //
    //            if (newIndex != uint256(0)) {
    //                unchecked {
    //                    newIndex--;
    //                }
    //            }
    //
    //            (uint256 amount, , , , , , ) = getLoan(
    //                BrokerImplementation(payee),
    //                collateralVault,
    //                newIndex
    //            );
    //
    //            _swapLien(
    //                brokers[msg.sender],
    //                brokers[payee],
    //                collateralVault,
    //                position,
    //                newIndex,
    //                amount
    //            );
    //        } else {
    //            _removeLien(msg.sender, collateralVault, position);
    //        }
    //    }

    //    function _removeLien(ILienToken.LienActionUnEncumber memory params)
    //        internal
    //    {
    //        //        COLLATERAL_VAULT.manageLien(
    //        //            ILienToken.LienAction.UN_ENCUMBER,
    //        //            abi.encode(params)
    //        //        );
    //    }

    //    function _swapLien(
    //        //        bytes32 bondVaultOld,
    //        //        bytes32 bondVaultNew,
    //        //        uint256 collateralVault,
    //        //        uint256 lienPosition,
    //        //        uint256 newIndex,
    //        //        uint256 amountOwed
    //
    //        ILienToken.LienActionSwap memory params
    //    ) internal {
    //        //        COLLATERAL_VAULT.manageLien(
    //        //            ILienToken.LienAction.SWAP_VAULT,
    //        //            abi.encode(params)
    //        //        );
    //    }

    function lendToVault(bytes32 bondVault, uint256 amount) external {
        TRANSFER_PROXY.tokenTransferFrom(
            address(WETH),
            address(msg.sender),
            address(this),
            amount
        );
        WETH.safeApprove(bondVaults[bondVault].broker, amount);
        require(
            bondVaults[bondVault].broker != address(0),
            "lendToVault: vault doesn't exist"
        );
        IBroker(bondVaults[bondVault].broker).deposit(
            amount,
            address(msg.sender)
        );
    }

    //    function getLiens(uint256 collateralVault)
    //        public
    //        view
    //        returns (ILienToken.Lien[] memory)
    //    {
    //        return LIEN_TOKEN.getLiens(collateralVault);
    //    }

    //    function getLoan(uint256 collateralVault, uint256 index)
    //        public
    //        view
    //        returns (ILienToken.Lien memory)
    //    {
    //        return LIEN_TOKEN.getLien(collateralVault, index);
    //    }

    function getBrokerHash(address broker) external view returns (bytes32) {
        return brokerHashes[broker];
    }

    function getBroker(bytes32 bondVault) external view returns (address) {
        return bondVaults[bondVault].broker;
    }

    event Repayment(uint256 collateralVault, uint256 position, uint256 amount);

    function canLiquidate(uint256 collateralVault, uint256 position)
        public
        view
        returns (bool)
    {
        ILienToken.Lien memory lien = LIEN_TOKEN.getLien(
            collateralVault,
            position
        );

        uint256 interestAccrued = LIEN_TOKEN.getInterest(
            collateralVault,
            position
        );
        uint256 maxInterest = lien.amount * lien.rate * lien.schedule;

        return
            maxInterest > interestAccrued ||
            (lien.start + lien.duration <= block.timestamp && lien.amount > 0);
    }

    // person calling liquidate should get some incentive from the auction
    function liquidate(uint256 collateralVault, uint256 position)
        external
        returns (uint256 reserve)
    {
        require(
            canLiquidate(collateralVault, position),
            "liquidate: borrow is healthy"
        );
        //        //grab all lien positions compute all outstanding
        //        (
        //            address[] memory brokers,
        //            ,
        //            uint256[] memory indexes
        //        ) = LIEN_TOKEN.getLiens(collateralVault);
        //
        //        for (uint256 i = 0; i < brokers.length; i++) {
        //            reserve += BrokerImplementation(brokers[i]).moveToReceivership(
        //                collateralVault,
        //                indexes[i]
        //            );
        //        }
        //
        //        reserve += ((reserve * LIQUIDATION_FEE_PERCENT) / 100);

        reserve = COLLATERAL_VAULT.auctionVault(
            collateralVault,
            address(msg.sender),
            LIQUIDATION_FEE_PERCENT
        );

        emit Liquidation(collateralVault, position, reserve);
    }

    function isValidRefinance(RefinanceCheckParams memory params)
        external
        view
        returns (bool)
    {
        ILienToken.Lien memory lien = LIEN_TOKEN.getLien(
            params.outgoing.collateralVault,
            params.outgoing.position
        );
        uint256 minNewRate = (((lien.rate * MIN_INTEREST_BPS) / 1000));

        if (params.incoming.rate > minNewRate)
            revert InvalidRefinanceRate(params.incoming.rate);

        if (
            (block.timestamp + params.incoming.duration) -
                (lien.start + params.outgoing.duration) <
            MIN_DURATION_INCREASE
        ) revert InvalidRefinanceDuration(params.incoming.duration);

        return true;
    }
}
