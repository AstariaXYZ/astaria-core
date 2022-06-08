pragma solidity ^0.8.13;

import "openzeppelin/token/ERC1155/ERC1155.sol";
import "openzeppelin/token/ERC721/IERC721.sol";
import "openzeppelin/token/ERC20/IERC20.sol";
import "openzeppelin/utils/cryptography/MerkleProof.sol";
import "gpl/interfaces/IAuctionHouse.sol";
import "clones-with-immutable-args/ClonesWithImmutableArgs.sol";
import {IStarNFT} from "./interfaces/IStarNFT.sol";
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
    struct NewBondVaultParams {
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
        uint256 collateralVault;
        bytes32 broker;
        bytes32[] proof;
        uint256[] loanDetails;
        address receiver;
    }

    struct BuyoutLienParams {
        IStarNFT.Terms outgoing;
        IStarNFT.Terms incoming;
    }

    struct RefinanceCheckParams {
        IStarNFT.Terms outgoing;
        IStarNFT.Terms incoming;
    }

    struct BorrowAndBuyParams {
        CommitmentParams[] commitments;
        address invoker;
        uint256 purchasePrice;
        bytes purchaseData;
    }

    struct BondVault {
        address appraiser; // address of the appraiser for the BondVault
        uint256 expiration; // expiration for lenders to add assets and expiration when borrowers cannot create new borrows
        address broker; //cloned proxy
    }

    function newBondVault(NewBondVaultParams memory params) external;

    function encodeBondVaultHash(
        address appraiser,
        bytes32 root,
        uint256 expiration,
        uint256 appraiserNonce,
        uint256 deadline,
        uint256 buyout
    ) external view returns (bytes memory);

    //    function buyoutLienPosition(BuyoutLienParams memory params) external;

    //    function commitToLoans(CommitmentParams[] calldata commitments) external;

    //    function requestLienPosition(
    //        uint256 collateralVault,
    //        bytes32 bondVault,
    //        uint256 lienPosition,
    //        uint256 newIndex,
    //        uint256 amount
    //    ) external;

    function lendToVault(bytes32 bondVault, uint256 amount) external;

    function getLiens(uint256 collateralVault)
        external
        view
        returns (IStarNFT.Lien[] memory);

    function getLoan(uint256 collateralVault, uint256 index)
        external
        view
        returns (IStarNFT.Lien memory);

    function getBroker(bytes32 bondVault) external view returns (address);

    function liquidate(IStarNFT.Terms memory)
        external
        returns (uint256 reserve);

    function canLiquidate(IStarNFT.Terms memory) external view returns (bool);

    function brokerIsOwner(uint256 collateralVault, uint256 position)
        external
        view
        returns (bool, address);

    function isValidRefinance(RefinanceCheckParams memory params)
        external
        view
        returns (bool);
}

contract BrokerRouter is IBrokerRouter {
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
    mapping(address => bytes32) public brokerHashes;
    mapping(address => uint256) public appraiserNonces;

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

    constructor(
        address _WETH,
        address _COLLATERAL_VAULT,
        address _TRANSFER_PROXY,
        address _BROKER_IMPL
    ) {
        WETH = IERC20(_WETH);
        COLLATERAL_VAULT = IStarNFT(_COLLATERAL_VAULT);
        TRANSFER_PROXY = TransferProxy(_TRANSFER_PROXY);
        BROKER_IMPLEMENTATION = _BROKER_IMPL;
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
    //    function verifyMerkleBranch(
    //        bytes32[] calldata proof,
    //        bytes32 leaf,
    //        bytes32 root
    //    ) public view returns (bool) {
    //        bool isValidLeaf = MerkleProof.verify(proof, root, leaf);
    //        return isValidLeaf;
    //    }

    // verifies the signature on the root of the merkle tree to be the appraiser
    // we need an additional method to prevent a griefing attack where the signature is stripped off and reserrved by an attacker

    function newBondVault(NewBondVaultParams memory params) external {
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

        address broker = ClonesWithImmutableArgs.clone(
            BROKER_IMPLEMENTATION,
            abi.encodePacked(
                address(COLLATERAL_VAULT),
                address(WETH),
                address(this),
                params.root,
                params.expiration,
                params.buyout,
                params.appraiser
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

    function _newBondVault(
        address appraiser,
        bytes32 root,
        uint256 expiration,
        uint256 deadline,
        uint256 buyout,
        bytes32 contentHash,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) internal {}

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
            c.loanDetails.length == 7 &&
                c.broker != bytes32(0) &&
                c.collateralVault != uint256(0)
        );
        require(
            msg.sender == COLLATERAL_VAULT.ownerOf(c.collateralVault),
            "invalid sender for collateralVault"
        );
    }

    //    function _executeCommitment(Terms calldata c) internal {
    //        _validateCommitment(c);
    //        _borrow(c.broker, c.proof, c.loanDetails, c.receiver);
    //    }

    //    function borrowAndBuy(BorrowAndBuyParams calldata params) external {
    //        uint256 spendableBalance;
    //        for (uint256 i = 0; i < params.commitments.length; ++i) {
    //            _executeCommitment(params.commitments[i]);
    //            if (params.commitments[i].receiver == address(this)) {
    //                spendableBalance += params.commitments[i].loanDetails[4]; //amount borrowed
    //            }
    //        }
    //        require(
    //            params.purchasePrice <= spendableBalance,
    //            "purchase price cannot be for more than your aggregate loan"
    //        );
    //
    //        WETH.approve(params.invoker, params.purchasePrice);
    //        require(
    //            IInvoker(params.invoker).onBorrowAndBuy(
    //                params.purchaseData, // calldata for the invoker
    //                address(WETH), // token
    //                params.purchasePrice, //max approval
    //                payable(msg.sender) // recipient
    //            ),
    //            "borrow and buy failed"
    //        );
    //        if (spendableBalance - params.purchasePrice > uint256(0)) {
    //            WETH.transfer(
    //                address(msg.sender),
    //                spendableBalance - params.purchasePrice
    //            );
    //        }
    //    }

    function _borrow(
        IStarNFT.Terms memory terms,
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

        //        WETH.approve(purchaseTarget, purchasePrice);
    }

    function buyoutLienPosition(BuyoutLienParams memory params) external {
        IStarNFT.Lien memory lien = COLLATERAL_VAULT.getLien(
            params.outgoing.collateralVault,
            params.outgoing.position
        );

        BrokerImplementation(params.outgoing.broker).validateTerms(
            params.outgoing
        );

        uint256 amountOwed = lien.amount +
            (lien.amount * params.outgoing.rate) /
            100;

        uint256 buyout = (lien.amount *
            BrokerImplementation(params.outgoing.broker).buyout()) / 100;
        TRANSFER_PROXY.tokenTransferFrom(
            address(WETH),
            address(msg.sender),
            address(this),
            uint256(amountOwed + buyout)
        );
        WETH.approve(params.incoming.broker, uint256(amountOwed + buyout));
        //        BrokerImplementation(params.incoming.broker).buyoutLien(
        //            params.incoming.position,
        //            params.incoming.collateralVault,
        //            params.incoming.proof,
        //            params.incoming.loanDetails
        //        );
    }

    //    function commitToLoans(CommitmentParams[] calldata commitments) external {
    //        for (uint256 i = 0; i < commitments.length; ++i) {
    //            _executeCommitment(commitments[i]);
    //        }
    //    }

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
    ) internal {}

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

    function _addLien(IStarNFT.LienActionEncumber memory params) internal {
        COLLATERAL_VAULT.manageLien(
            IStarNFT.LienAction.ENCUMBER,
            abi.encode(params)
        );
    }

    function requestLienPosition(IStarNFT.LienActionEncumber calldata params)
        external
        onlyVaults
        returns (bool)
    {
        _addLien(IStarNFT.LienActionEncumber(params.terms, params.amount));
        return true;
    }

    //    struct LienPayments {
    //        IStarNFT.LienActionPayment[] payments;
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

    function _removeLien(IStarNFT.LienActionUnEncumber memory params) internal {
        COLLATERAL_VAULT.manageLien(
            IStarNFT.LienAction.UN_ENCUMBER,
            abi.encode(params)
        );
    }

    function _swapLien(
        //        bytes32 bondVaultOld,
        //        bytes32 bondVaultNew,
        //        uint256 collateralVault,
        //        uint256 lienPosition,
        //        uint256 newIndex,
        //        uint256 amountOwed

        IStarNFT.LienActionSwap memory params
    ) internal {
        COLLATERAL_VAULT.manageLien(
            IStarNFT.LienAction.SWAP_VAULT,
            abi.encode(params)
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
        returns (IStarNFT.Lien[] memory)
    {
        return COLLATERAL_VAULT.getLiens(collateralVault);
    }

    function getLoan(uint256 collateralVault, uint256 index)
        public
        view
        returns (IStarNFT.Lien memory)
    {
        return COLLATERAL_VAULT.getLien(collateralVault, index);
    }

    function getBrokerHash(address broker) external view returns (bytes32) {
        return brokerHashes[broker];
    }

    function getBroker(bytes32 bondVault) external view returns (address) {
        return bondVaults[bondVault].broker;
    }

    function brokerIsOwner(uint256 collateralVault, uint256 position)
        external
        view
        returns (bool, address)
    {
        IStarNFT.Lien memory lien = COLLATERAL_VAULT.getLien(
            collateralVault,
            position
        );
        address owner = COLLATERAL_VAULT.ownerOf(lien.lienId);

        return (brokerHashes[owner] != bytes32(0), owner);
    }

    event Repayment(uint256 collateralVault, uint256 position, uint256 amount);

    //    function _makeLienPayments(LienPayments memory params) internal {
    //        COLLATERAL_VAULT.manageLien(
    //            IStarNFT.LienAction.PAY_LIEN,
    //            abi.encode(params)
    //        );
    //    }

    //    function makePayment(uint256 collateralVault, uint256 repayment) external {
    //        // calculates interest here and apply it to the loan
    //
    //        IStarNFT.Lien[] memory liens = COLLATERAL_VAULT.getLiens(
    //            collateralVault
    //        );
    //        IStarNFT.LienActionPayment[] memory payments;
    //
    //        for (uint256 i = 0; i < liens.length; ++i) {
    //            uint256 openInterest = COLLATERAL_VAULT.getInterest(
    //                collateralVault,
    //                i
    //            );
    //            uint256 maxLienPayment = liens[i].amount + openInterest;
    //            address owner = COLLATERAL_VAULT.ownerOf(liens[i].lienId);
    //            if (maxLienPayment >= repayment) {
    //                repayment = maxLienPayment;
    //            }
    //            //            payments.push(
    //            //                IStarNFT.LienActionPayment(collateralVault, i, repayment)
    //            //            );
    //            TRANSFER_PROXY.tokenTransferFrom(
    //                address(WETH),
    //                address(msg.sender),
    //                owner,
    //                repayment
    //            );
    //            emit Repayment(collateralVault, i, repayment);
    //        }
    //
    //        //        _makeLienPayments(LienPayments(payments));
    //        //        //TODO: ensure math is correct on calcs
    //        //        uint256 appraiserPayout = (20 * convertToShares(openInterest)) / 100;
    //        //        _mint(appraiser(), appraiserPayout);
    //        //
    //        //        unchecked {
    //        //            repayment -= appraiserPayout;
    //        //
    //        //            terms[collateralVault][index].amount += getInterest(
    //        //                index,
    //        //                collateralVault
    //        //            );
    //        //            repayment = (terms[collateralVault][index].amount >= repayment)
    //        //                ? repayment
    //        //                : terms[collateralVault][index].amount;
    //        //
    //        //            terms[collateralVault][index].amount -= repayment;
    //        //        }
    //        //
    //        //        if (terms[collateralVault][index].amount == 0) {
    //        //            BrokerRouter(router()).updateLien(
    //        //                collateralVault,
    //        //                index,
    //        //                msg.sender
    //        //            );
    //        //            delete terms[collateralVault][index];
    //        //        } else {
    //        //            terms[collateralVault][index].start = uint64(block.timestamp);
    //        //        }
    //    }

    function canLiquidate(IStarNFT.Terms memory params)
        public
        view
        returns (bool)
    {
        require(COLLATERAL_VAULT.validateTerms(params), "invalid loan hash");
        IStarNFT.Lien memory lien = COLLATERAL_VAULT.getLien(
            params.collateralVault,
            params.position
        );
        uint256 interestAccrued = COLLATERAL_VAULT.getInterest(
            params.collateralVault,
            params.position
        );
        uint256 maxInterest = lien.amount * lien.rate * params.schedule;

        return
            maxInterest > interestAccrued ||
            (lien.end <= block.timestamp && lien.amount > 0);
    }

    // person calling liquidate should get some incentive from the auction
    function liquidate(IStarNFT.Terms memory params)
        external
        returns (uint256 reserve)
    {
        require(canLiquidate(params), "liquidate: borrow is healthy");
        //        //grab all lien positions compute all outstanding
        //        (
        //            address[] memory brokers,
        //            ,
        //            uint256[] memory indexes
        //        ) = COLLATERAL_VAULT.getLiens(collateralVault);
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
            params,
            address(msg.sender),
            LIQUIDATION_FEE_PERCENT
        );

        emit Liquidation(params.collateralVault, params.position, reserve);
    }

    function isValidRefinance(RefinanceCheckParams memory params)
        external
        view
        returns (bool)
    {
        IStarNFT.Lien memory lien = COLLATERAL_VAULT.getLien(
            params.outgoing.collateralVault,
            params.outgoing.position
        );
        uint256 minNewRate = (((lien.rate * MIN_INTEREST_BPS) / 1000));

        if (params.incoming.rate > minNewRate)
            revert InvalidRefinanceRate(params.incoming.rate);

        if (
            (block.timestamp + params.incoming.duration) - (lien.end) <
            MIN_DURATION_INCREASE
        ) revert InvalidRefinanceDuration(params.incoming.duration);

        return true;
    }
}
