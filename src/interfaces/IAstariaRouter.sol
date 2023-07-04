// SPDX-License-Identifier: BUSL-1.1

/**
 *  █████╗ ███████╗████████╗ █████╗ ██████╗ ██╗ █████╗
 * ██╔══██╗██╔════╝╚══██╔══╝██╔══██╗██╔══██╗██║██╔══██╗
 * ███████║███████╗   ██║   ███████║██████╔╝██║███████║
 * ██╔══██║╚════██║   ██║   ██╔══██║██╔══██╗██║██╔══██║
 * ██║  ██║███████║   ██║   ██║  ██║██║  ██║██║██║  ██║
 * ╚═╝  ╚═╝╚══════╝   ╚═╝   ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝╚═╝  ╚═╝
 *
 * Astaria Labs, Inc
 */

pragma solidity =0.8.17;

import {IERC721} from "core/interfaces/IERC721.sol";
import {ITransferProxy} from "core/interfaces/ITransferProxy.sol";
import {IERC4626} from "core/interfaces/IERC4626.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {ICollateralToken} from "core/interfaces/ICollateralToken.sol";
import {ILienToken} from "core/interfaces/ILienToken.sol";

import {IPausable} from "core/utils/Pausable.sol";
import {IBeacon} from "core/interfaces/IBeacon.sol";
import {IERC4626RouterBase} from "gpl/interfaces/IERC4626RouterBase.sol";
import {OrderParameters} from "seaport-types/src/lib/ConsiderationStructs.sol";

interface IAstariaRouter is IPausable, IBeacon {
  enum FileType {
    FeeTo,
    LiquidationFee,
    ProtocolFee,
    MaxStrategistFee,
    MinEpochLength,
    MaxEpochLength,
    MinInterestRate,
    MaxInterestRate,
    MinLoanDuration,
    AuctionWindow,
    StrategyValidator,
    Implementation,
    CollateralToken,
    LienToken,
    TransferProxy
  }

  struct File {
    FileType what;
    bytes data;
  }

  event FileUpdated(FileType what, bytes data);

  struct RouterStorage {
    //slot 1
    uint32 auctionWindow;
    uint32 liquidationFeeNumerator;
    uint32 liquidationFeeDenominator;
    uint32 maxEpochLength;
    uint32 minEpochLength;
    uint32 protocolFeeNumerator;
    uint32 protocolFeeDenominator;
    uint32 minLoanDuration;
    //slot 2
    ICollateralToken COLLATERAL_TOKEN; //20
    ILienToken LIEN_TOKEN; //20
    ITransferProxy TRANSFER_PROXY; //20
    address feeTo; //20
    address BEACON_PROXY_IMPLEMENTATION; //20
    uint256 maxInterestRate; //6
    //slot 3 +
    address guardian; //20
    address newGuardian; //20
    mapping(uint8 => address) strategyValidators;
    mapping(uint8 => address) implementations;
    //A strategist can have many deployed vaults
    mapping(address => bool) vaults;
    uint256 maxStrategistFee; //4
    address WETH;
  }

  enum ImplementationType {
    PrivateVault,
    PublicVault,
    WithdrawProxy
  }

  enum LienRequestType {
    DEACTIVATED,
    UNIQUE,
    COLLECTION,
    UNIV3_LIQUIDITY
  }

  struct StrategyDetailsParam {
    uint8 version;
    uint256 deadline;
    address payable vault;
  }

  struct MerkleData {
    bytes32 root;
    bytes32[] proof;
  }

  struct NewLienRequest {
    StrategyDetailsParam strategy;
    bytes nlrDetails;
    bytes32 root;
    bytes32[] proof;
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

  function STRATEGY_TYPEHASH() external view returns (bytes32);

  function validateCommitment(
    IAstariaRouter.Commitment calldata commitment
  ) external returns (ILienToken.Lien memory lien);

  function getStrategyValidator(
    Commitment calldata
  ) external view returns (address);

  function newPublicVault(
    uint256 epochLength,
    address delegate,
    address underlying,
    uint256 vaultFee,
    bool allowListEnabled,
    address[] calldata allowList,
    uint256 depositCap
  ) external returns (address);

  function newVault(
    address delegate,
    address underlying
  ) external returns (address);

  function feeTo() external returns (address);

  function WETH() external returns (address);

  function commitToLien(
    Commitment memory commitments
  ) external returns (uint256, ILienToken.Stack memory);

  function LIEN_TOKEN() external view returns (ILienToken);

  function TRANSFER_PROXY() external view returns (ITransferProxy);

  function BEACON_PROXY_IMPLEMENTATION() external view returns (address);

  function COLLATERAL_TOKEN() external view returns (ICollateralToken);

  function getAuctionWindow() external view returns (uint256);

  function getProtocolFee(uint256) external view returns (uint256);

  function getLiquidatorFee(uint256) external view returns (uint256);

  function liquidate(
    ILienToken.Stack calldata stack
  ) external returns (OrderParameters memory);

  function canLiquidate(ILienToken.Stack calldata) external view returns (bool);

  function isValidVault(address vault) external view returns (bool);

  function fileBatch(File[] calldata files) external;

  function file(File calldata incoming) external;

  function setNewGuardian(address _guardian) external;

  function fileGuardian(File[] calldata file) external;

  function getImpl(uint8 implType) external view returns (address impl);

  event Liquidation(
    uint256 collateralId,
    address liquidator,
    uint256 offererCounterAtLiquidation
  );
  event NewVault(
    address strategist,
    address delegate,
    address vault,
    uint8 vaultType
  );

  error InvalidFileData();
  error InvalidEpochLength(uint256);
  error InvalidRefinanceRate(uint256);
  error InvalidRefinanceDuration(uint256);
  error InvalidVaultFee();
  error InvalidVaultState(VaultState);
  error InvalidSenderForCollateral(address, uint256);
  error InvalidLienState(LienState);
  error InvalidCollateralState(CollateralStates);
  error InvalidCommitmentState(CommitmentState);
  error InvalidStrategy(uint16);
  error InvalidVault(address);
  error InvalidUnderlying(address);
  error InvalidSender();
  error StrategyExpired();
  error UnsupportedFile();

  enum LienState {
    HEALTHY,
    AUCTION
  }

  enum CollateralStates {
    AUCTION,
    NO_DEPOSIT,
    NO_LIENS
  }

  enum CommitmentState {
    INVALID,
    INVALID_RATE,
    INVALID_AMOUNT,
    COLLATERAL_NO_DEPOSIT
  }

  enum VaultState {
    UNINITIALIZED,
    CORRUPTED,
    CLOSED,
    LIQUIDATED
  }
}
