pragma solidity ^0.8.17;

import {IERC721} from "gpl/interfaces/IERC721.sol";
import {ILienBase, ILienToken} from "./ILienToken.sol";
import {ICollateralToken} from "./ICollateralToken.sol";
import {ITransferProxy} from "gpl/interfaces/ITransferProxy.sol";
import {IPausable} from "../utils/Pausable.sol";

interface IAstariaRouter is IPausable {
    struct LienDetails {
        uint256 maxAmount;
        uint256 rate; //rate per second
        uint256 duration;
        uint256 maxPotentialDebt;
    }

    enum LienRequestType {
        UNIQUE,
        COLLECTION,
        UNIV3_LIQUIDITY
    }

    struct StrategyDetails {
        uint8 version;
        address strategist;
        uint256 nonce; //nonce of the owner of the vault
        uint256 deadline;
        address vault;
    }

    struct MultiMerkleData {
        bytes32 root;
        bytes32[] proof;
        bool[] flags;
    }

    struct NewLienRequest {
        StrategyDetails strategy;
        uint8 nlrType;
        bytes nlrDetails;
        MultiMerkleData merkle;
        uint256 amount;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    struct Commitment {
        address tokenContract;
        uint256 tokenId;
        NewLienRequest lienRequest;
    }

    struct RefinanceCheckParams {
        uint256 position;
        Commitment incoming;
    }

    struct BorrowAndBuyParams {
        Commitment[] commitments;
        address invoker;
        uint256 purchasePrice;
        bytes purchaseData;
        address receiver;
    }

    function strategistNonce(address strategist) external view returns (uint256);

    function validateCommitment(Commitment calldata) external returns (bool, IAstariaRouter.LienDetails memory);

    function newPublicVault(uint256, address) external returns (address);

    function newVault(address) external returns (address);

    function feeTo() external returns (address);

    function commitToLiens(Commitment[] calldata) external returns (uint256 totalBorrowed);

    function requestLienPosition(IAstariaRouter.Commitment calldata) external returns (uint256);

    function LIEN_TOKEN() external view returns (ILienToken);

    function TRANSFER_PROXY() external view returns (ITransferProxy);

    function WITHDRAW_IMPLEMENTATION() external view returns (address);

    function LIQUIDATION_IMPLEMENTATION() external view returns (address);

    function VAULT_IMPLEMENTATION() external view returns (address);

    function COLLATERAL_TOKEN() external view returns (ICollateralToken);

    function MIN_INTEREST_BPS() external view returns (uint256);

    function getStrategistFee(uint256) external view returns (uint256);

    function getProtocolFee(uint256) external view returns (uint256);

    function lendToVault(address vault, uint256 amount) external;

    function liquidate(uint256 collateralId, uint256 position) external returns (uint256 reserve);

    function canLiquidate(uint256 collateralId, uint256 position) external view returns (bool);

    function isValidVault(address) external view returns (bool);

    function isValidRefinance(ILienBase.Lien memory, LienDetails memory) external returns (bool);

    event Liquidation(uint256 collateralId, uint256 position, uint256 reserve);
    event NewVault(address appraiser, address vault);

    error InvalidAddress(address);
    error InvalidRefinanceRate(uint256);
    error InvalidRefinanceDuration(uint256);
}
