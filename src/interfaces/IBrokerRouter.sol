pragma solidity ^0.8.15;

import {IERC721} from "openzeppelin/token/ERC721/IERC721.sol";
import {ILienToken} from "./ILienToken.sol";
import {ICollateralVault} from "./ICollateralVault.sol";
import {ITransferProxy} from "./ITransferProxy.sol";

interface IBrokerRouter {
    struct Terms {
        address broker;
        address token;
        bytes32[] proof;
        uint256 collateralVault;
        uint256 maxAmount;
        uint256 maxDebt;
        uint256 rate;
        uint256 maxRate;
        uint256 duration;
        uint256 schedule;
    }

    struct LienDetails {
        uint256 maxAmount;
        uint256 maxSeniorDebt;
        uint256 rate;
        uint256 maxInterestRate; //max at origination
        uint256 duration;
    }

    enum ObligationType {
        STANDARD,
        COLLECTION
    }

    struct CollectionDetails {
        uint8 version;
        address token;
        address borrower;
        LienDetails lien;
    }

    struct CollateralDetails {
        uint8 version;
        address token;
        uint256 tokenId;
        address borrower;
        LienDetails lien;
    }

    struct StrategyDetails {
        uint8 version;
        address strategist;
        address delegate;
        //        uint256 expiration;
        uint256 nonce;
        address vault;
    }

    struct NewObligationRequest {
        StrategyDetails strategy;
        uint8 obligationType;
        bytes obligationDetails;
        bytes32 obligationRoot;
        bytes32[] obligationProof;
        uint256 amount;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    struct Commitment {
        address tokenContract;
        uint256 tokenId;
        bytes32[] depositProof;
        NewObligationRequest nor;
    }

    struct BrokerParams {
        address appraiser;
        address delegate;
        //        uint256 expiration;
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    struct RefinanceCheckParams {
        uint256 position;
        Terms incoming;
    }

    struct BorrowAndBuyParams {
        Commitment[] commitments;
        address invoker;
        uint256 purchasePrice;
        bytes purchaseData;
        address receiver;
    }

    struct BondVault {
        address appraiser; // address of the appraiser for the BondVault
        uint256 expiration; // expiration for lenders to add assets and expiration when borrowers cannot create new borrows
    }

    function newPublicVault(uint256) external returns (address);

    function feeTo() external returns (address);

    function commitToLoans(Commitment[] calldata)
        external
        returns (uint256 totalBorrowed);

    function requestLienPosition(ILienToken.LienActionEncumber calldata params)
        external
        returns (uint256);

    function LIEN_TOKEN() external view returns (ILienToken);

    function TRANSFER_PROXY() external view returns (ITransferProxy);

    function WITHDRAW_IMPLEMENTATION() external view returns (address);

    function VAULT_IMPLEMENTATION() external view returns (address);

    function COLLATERAL_VAULT() external view returns (ICollateralVault);

    function getAppraiserFee() external view returns (uint256, uint256);

    function lendToVault(address vault, uint256 amount) external;

    function liquidate(uint256 collateralVault, uint256 position)
        external
        returns (uint256 reserve);

    function canLiquidate(uint256 collateralVault, uint256 position)
        external
        view
        returns (bool);

    function isValidVault(address) external view returns (bool);

    function isValidRefinance(RefinanceCheckParams memory params)
        external
        view
        returns (bool);

    event Liquidation(
        uint256 collateralVault, uint256 position, uint256 reserve
    );
    event NewVault(address appraiser, address vault);

    error InvalidAddress(address);
    error InvalidRefinanceRate(uint256);
    error InvalidRefinanceDuration(uint256);
}
