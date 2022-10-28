// SPDX-License-Identifier: UNLICENSED

/**
 *       __  ___       __
 *  /\  /__'  |   /\  |__) |  /\
 * /~~\ .__/  |  /~~\ |  \ | /~~\
 *
 * Copyright (c) Astaria Labs, Inc
 */

pragma solidity ^0.8.17;

import {Auth, Authority} from "solmate/auth/Auth.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";

import {IAuctionHouse} from "gpl/interfaces/IAuctionHouse.sol";
import {IERC721} from "core/interfaces/IERC721.sol";
import {ITransferProxy} from "core/interfaces/ITransferProxy.sol";
import {SafeCastLib} from "gpl/utils/SafeCastLib.sol";

import {
  ClonesWithImmutableArgs
} from "clones-with-immutable-args/ClonesWithImmutableArgs.sol";

import {CollateralLookup} from "core/libraries/CollateralLookup.sol";

import {IAstariaRouter} from "core/interfaces/IAstariaRouter.sol";
import {ICollateralToken} from "core/interfaces/ICollateralToken.sol";
import {ILienToken} from "core/interfaces/ILienToken.sol";
import {IStrategyValidator} from "core/interfaces/IStrategyValidator.sol";
import {IPublicVault} from "core/interfaces/IPublicVault.sol";

import {IVault} from "gpl/interfaces/IVault.sol";

import {PublicVault} from "core/PublicVault.sol";
import {VaultImplementation} from "core/VaultImplementation.sol";
import {LiquidationAccountant} from "core/LiquidationAccountant.sol";

import {MerkleProofLib} from "core/utils/MerkleProofLib.sol";
import {Pausable} from "core/utils/Pausable.sol";
import "./interfaces/ILienToken.sol";

/**
 * @title AstariaRouter
 * @notice This contract manages the deployment of Vaults and universal Astaria actions.
 */
contract AstariaRouter is Auth, Pausable, IAstariaRouter {
  using SafeTransferLib for ERC20;
  using SafeCastLib for uint256;
  using CollateralLookup for address;
  using FixedPointMathLib for uint256;

  bytes32 constant ROUTER_SLOT =
    keccak256("xyz.astaria.router.storage.location");

  address newGuardian;
  address guardian;

  struct RouterStorage {
    ERC20 WETH;
    ICollateralToken COLLATERAL_TOKEN;
    ILienToken LIEN_TOKEN;
    ITransferProxy TRANSFER_PROXY;
    mapping(uint8 => address) implementations;
    address BEACON_PROXY_IMPLEMENTATION;
    address feeTo;
    uint256 liquidationFeeNumerator;
    uint256 liquidationFeeDenominator;
    uint256 maxInterestRate;
    uint256 maxEpochLength;
    uint256 minEpochLength;
    uint256 minInterestBPS; // was uint64
    uint256 protocolFeeNumerator;
    uint256 protocolFeeDenominator;
    uint256 strategistFeeNumerator;
    uint256 strategistFeeDenominator;
    uint256 buyoutFeeNumerator;
    uint256 buyoutFeeDenominator;
    uint32 minDurationIncrease;
    uint32 buyoutInterestWindow;
    //A strategist can have many deployed vaults
    mapping(address => address) vaults;
    mapping(address => uint256) strategistNonce;
    mapping(uint16 => address) strategyValidators;
  }

  //  ERC20 public immutable WETH;
  //  ICollateralToken public immutable COLLATERAL_TOKEN;
  //  ILienToken public immutable LIEN_TOKEN;
  //  ITransferProxy public immutable TRANSFER_PROXY;
  //
  //  mapping(uint8 => address) public implementations;
  //
  //  address public BEACON_PROXY_IMPLEMENTATION;
  //
  //  address public newGuardian;
  //  address public guardian;
  //
  //  address public feeTo;
  //  uint256 public liquidationFeeNumerator;
  //  uint256 public liquidationFeeDenominator;
  //  uint256 public maxInterestRate;
  //  uint256 public maxEpochLength;
  //  uint256 public minEpochLength;
  //  uint256 public minInterestBPS; // was uint64
  //  uint256 public protocolFeeNumerator;
  //  uint256 public protocolFeeDenominator;
  //  uint256 public strategistFeeNumerator;
  //  uint256 public strategistFeeDenominator;
  //  uint256 public buyoutFeeNumerator;
  //  uint256 public buyoutFeeDenominator;
  //  uint32 public minDurationIncrease;
  //  uint32 public buyoutInterestWindow;
  //
  //  //A strategist can have many deployed vaults
  //  mapping(address => address) public vaults;
  //  mapping(address => uint256) public strategistNonce;
  //  mapping(uint16 => address) public strategyValidators;

  /**
   * @dev Setup transfer authority and set up addresses for deployed CollateralToken, LienToken, TransferProxy contracts, as well as PublicVault and SoloVault implementations to clone.
   * @param _AUTHORITY The authority manager.
   * @param _WETH The WETH address to use for transfers.
   * @param _COLLATERAL_TOKEN The address of the deployed CollateralToken contract.
   * @param _LIEN_TOKEN The address of the deployed LienToken contract.
   * @param _TRANSFER_PROXY The address of the deployed TransferProxy contract.
   * @param _VAULT_IMPL The address of a base implementation of VaultImplementation for cloning.
   * @param _SOLO_IMPL The address of a base implementation of a PrivateVault for cloning.
   */
  constructor(
    Authority _AUTHORITY,
    address _WETH,
    ICollateralToken _COLLATERAL_TOKEN,
    ILienToken _LIEN_TOKEN,
    ITransferProxy _TRANSFER_PROXY,
    address _VAULT_IMPL,
    address _SOLO_IMPL,
    address _LIQUIDATION_IMPL,
    address _WITHDRAW_IMPL,
    address _BEACON_PROXY_IMPL
  ) Auth(address(msg.sender), _AUTHORITY) {
    RouterStorage storage s = _loadRouterSlot();

    s.WETH = ERC20(_WETH);
    s.COLLATERAL_TOKEN = _COLLATERAL_TOKEN;
    s.LIEN_TOKEN = _LIEN_TOKEN;
    s.TRANSFER_PROXY = _TRANSFER_PROXY;
    s.implementations[uint8(ImplementationType.PrivateVault)] = _SOLO_IMPL;
    s.implementations[uint8(ImplementationType.PublicVault)] = _VAULT_IMPL;
    s.implementations[
      uint8(ImplementationType.LiquidationAccountant)
    ] = _LIQUIDATION_IMPL;
    s.implementations[uint8(ImplementationType.WithdrawProxy)] = _WITHDRAW_IMPL;

    s.BEACON_PROXY_IMPLEMENTATION = _BEACON_PROXY_IMPL;
    s.liquidationFeeNumerator = 130;
    s.liquidationFeeDenominator = 1000;
    s.minInterestBPS = (uint256(1e15) * 5) / (365 days);
    s.minEpochLength = 7 days;
    s.maxEpochLength = 45 days;
    s.maxInterestRate = (uint256(1e16) * 200) / (365 days); //63419583966; // 200% apy / second
    s.strategistFeeNumerator = 200;
    s.strategistFeeDenominator = 1000;
    s.buyoutFeeNumerator = 200;
    s.buyoutFeeDenominator = 1000;
    s.minDurationIncrease = 5 days;
    s.buyoutInterestWindow = 60 days;

    //
    guardian = address(msg.sender);
  }

  function _loadRouterSlot() internal pure returns (RouterStorage storage rs) {
    bytes32 slot = ROUTER_SLOT;
    assembly {
      rs.slot := slot
    }
  }

  function strategistNonce(address strategist) public view returns (uint256) {
    RouterStorage storage s = _loadRouterSlot();
    return s.strategistNonce[strategist];
  }

  function feeTo() public view returns (address) {
    RouterStorage storage s = _loadRouterSlot();
    return s.feeTo;
  }

  function BEACON_PROXY_IMPLEMENTATION() public view returns (address) {
    RouterStorage storage s = _loadRouterSlot();
    return s.BEACON_PROXY_IMPLEMENTATION;
  }

  function LIEN_TOKEN() public view returns (ILienToken) {
    RouterStorage storage s = _loadRouterSlot();
    return s.LIEN_TOKEN;
  }

  function TRANSFER_PROXY() public view returns (ITransferProxy) {
    RouterStorage storage s = _loadRouterSlot();
    return s.TRANSFER_PROXY;
  }

  function WETH() public view returns (ERC20) {
    RouterStorage storage s = _loadRouterSlot();
    return s.WETH;
  }

  function COLLATERAL_TOKEN() public view returns (ICollateralToken) {
    RouterStorage storage s = _loadRouterSlot();
    return s.COLLATERAL_TOKEN;
  }

  function maxInterestRate() public view returns (uint256) {
    RouterStorage storage s = _loadRouterSlot();
    return s.maxInterestRate;
  }

  /**
   * @dev Enables _pause, freezing functions with the whenNotPaused modifier.
   */
  function __emergencyPause() external requiresAuth whenNotPaused {
    _pause();
  }

  /**
   * @dev Disables _pause, un-freezing functions with the whenNotPaused modifier.
   */
  function __emergencyUnpause() external requiresAuth whenPaused {
    _unpause();
  }

  function __acceptGuardian() external {
    require(msg.sender == newGuardian);
    guardian = msg.sender;
    newGuardian = address(0);
  }

  function incrementNonce() external {
    _loadRouterSlot().strategistNonce[msg.sender]++;
  }

  struct File {
    bytes32 what;
    bytes data;
  }

  event FileUpdated(bytes32 indexed what, bytes data);

  /**
   * @notice Sets universal protocol parameters or changes the addresses for deployed contracts.
   * @param files structs to file
   */
  function fileBatch(File[] calldata files) external requiresAuth {
    for (uint256 i = 0; i < files.length; i++) {
      file(files[i]);
    }
  }

  /**
   * @notice Sets universal protocol parameters or changes the addresses for deployed contracts.
   * @param incoming incoming files
   */
  function file(File calldata incoming) public requiresAuth {
    RouterStorage storage s = _loadRouterSlot();
    bytes32 what = incoming.what;
    bytes memory data = incoming.data;
    if (what == "setLiquidationFee") {
      (uint256 numerator, uint256 denominator) = abi.decode(
        data,
        (uint256, uint256)
      );
      s.liquidationFeeNumerator = numerator;
      s.liquidationFeeDenominator = denominator;
    } else if (what == "setStrategistFee") {
      (uint256 numerator, uint256 denominator) = abi.decode(
        data,
        (uint256, uint256)
      );
      s.strategistFeeNumerator = numerator;
      s.strategistFeeDenominator = denominator;
    } else if (what == "setProtocolFee") {
      (uint256 numerator, uint256 denominator) = abi.decode(
        data,
        (uint256, uint256)
      );
      s.protocolFeeNumerator = numerator;
      s.protocolFeeDenominator = denominator;
    } else if (what == "setBuyoutFee") {
      (uint256 numerator, uint256 denominator) = abi.decode(
        data,
        (uint256, uint256)
      );
      s.buyoutFeeNumerator = numerator;
      s.buyoutFeeDenominator = denominator;
    } else if (what == "MIN_INTEREST_BPS") {
      uint256 value = abi.decode(data, (uint256));
      s.minInterestBPS = uint256(value);
    } else if (what == "MIN_DURATION_INCREASE") {
      uint256 value = abi.decode(data, (uint256));
      s.minDurationIncrease = value.safeCastTo32();
    } else if (what == "MIN_EPOCH_LENGTH") {
      s.minEpochLength = abi.decode(data, (uint256));
    } else if (what == "MAX_EPOCH_LENGTH") {
      s.maxEpochLength = abi.decode(data, (uint256));
    } else if (what == "MAX_INTEREST_RATE") {
      s.maxInterestRate = abi.decode(data, (uint256));
    } else if (what == "feeTo") {
      address addr = abi.decode(data, (address));
      s.feeTo = addr;
    } else if (what == "setBuyoutInterestWindow") {
      uint256 value = abi.decode(data, (uint256));
      s.buyoutInterestWindow = value.safeCastTo32();
    } else if (what == "setStrategyValidator") {
      (uint8 TYPE, address addr) = abi.decode(data, (uint8, address));
      s.strategyValidators[TYPE] = addr;
    } else {
      revert("unsupported/file");
    }

    emit FileUpdated(what, data);
  }

  function setNewGuardian(address _guardian) external {
    require(msg.sender == guardian);

    newGuardian = _guardian;
  }

  /* @notice specially guarded file
   * @param file incoming data to file
   */
  function fileGuardian(File[] calldata file) external {
    require(msg.sender == address(guardian)); //only the guardian can call this
    RouterStorage storage s = _loadRouterSlot();
    for (uint256 i = 0; i < file.length; i++) {
      bytes32 what = file[i].what;
      bytes memory data = file[i].data;
      if (what == "setImplementation") {
        (uint8 implType, address addr) = abi.decode(data, (uint8, address));
        s.implementations[implType] = addr;
      } else {
        revert("unsupported/file");
      }
    }
  }

  // MODIFIERS
  modifier onlyVaults() {
    if (_loadRouterSlot().vaults[msg.sender] == address(0)) {
      revert InvalidVaultState(VaultState.UNINITIALIZED);
    }
    _;
  }

  //PUBLIC

  function getImpl(uint8 implType) external view returns (address impl) {
    impl = _loadRouterSlot().implementations[implType];
    if (impl == address(0)) {
      revert("unsupported/impl");
    }
  }

  function validateCommitment(IAstariaRouter.Commitment calldata commitment)
    public
    returns (bool valid, ILienToken.Details memory ld)
  {
    if (block.timestamp > commitment.lienRequest.strategy.deadline) {
      revert InvalidCommitmentState(CommitmentState.EXPIRED);
    }
    //    require(
    //      commitment.lienRequest.strategy.deadline >= block.timestamp,
    //      "deadline passed"
    //    );
    RouterStorage storage s = _loadRouterSlot();

    if (s.strategyValidators[commitment.lienRequest.nlrType] == address(0)) {
      revert InvalidStrategy(commitment.lienRequest.nlrType);
    }

    //    require(
    //      strategyValidators[commitment.lienRequest.nlrType] != address(0),
    //      "invalid strategy type"
    //    );

    bytes32 leaf;
    (leaf, ld) = IStrategyValidator(
      s.strategyValidators[commitment.lienRequest.nlrType]
    ).validateAndParse(
        commitment.lienRequest,
        s.COLLATERAL_TOKEN.ownerOf(
          commitment.tokenContract.computeId(commitment.tokenId)
        ),
        commitment.tokenContract,
        commitment.tokenId
      );

    return (
      MerkleProofLib.verify(
        commitment.lienRequest.merkle.proof,
        commitment.lienRequest.merkle.root,
        leaf
      ),
      ld
    );
  }

  /**
   * @notice Deposits collateral and requests loans for multiple NFTs at once.
   * @param commitments The commitment proofs and requested loan data for each loan.
   * @return lienIds the lienIds for each loan.
   */
  function commitToLiens(IAstariaRouter.Commitment[] calldata commitments)
    external
    whenNotPaused
    returns (
      uint256[] memory lienIds,
      ILienToken.LienEvent[] memory stack //todo fix this
    )
  {
    RouterStorage storage s = _loadRouterSlot();

    uint256 totalBorrowed = 0;
    lienIds = new uint256[](commitments.length);
    for (uint256 i = 0; i < commitments.length; ++i) {
      _transferAndDepositAsset(
        s,
        commitments[i].tokenContract,
        commitments[i].tokenId
      );
      (lienIds[i], stack) = _executeCommitment(s, commitments[i]);
      totalBorrowed += commitments[i].lienRequest.amount;

      uint256 collateralId = commitments[i].tokenContract.computeId(
        commitments[i].tokenId
      );
    }
    s.WETH.safeApprove(address(s.TRANSFER_PROXY), totalBorrowed);
    s.TRANSFER_PROXY.tokenTransferFrom(
      address(s.WETH),
      address(this),
      address(msg.sender),
      totalBorrowed
    );
  }

  /**
   * @notice Deploys a new PrivateVault.
   * @return The address of the new PrivateVault.
   */
  function newVault(address delegate) external whenNotPaused returns (address) {
    address[] memory allowList = new address[](2);
    allowList[0] = address(msg.sender);
    allowList[1] = delegate;

    return
      _newVault(uint256(0), delegate, uint256(0), true, allowList, uint256(0));
  }

  /**
   * @notice Deploys a new PublicVault.
   * @param epochLength The length of each epoch for the new PublicVault.
   */
  function newPublicVault(
    uint256 epochLength,
    address delegate,
    uint256 vaultFee,
    bool allowListEnabled,
    address[] calldata allowList,
    uint256 depositCap
  ) external whenNotPaused returns (address) {
    return
      _newVault(
        epochLength,
        delegate,
        vaultFee,
        allowListEnabled,
        allowList,
        depositCap
      );
  }

  /**
   * @notice Create a new lien against a CollateralToken.
   * @param terms the decoded lien details from the commitment
   * @param params The valid proof and lien details for the new loan.
   * @return The ID of the created lien.
   */
  function requestLienPosition(
    ILienToken.Details memory terms,
    IAstariaRouter.Commitment calldata params
  )
    external
    whenNotPaused
    onlyVaults
    returns (uint256, ILienToken.LienEvent[] memory)
  {
    return
      _loadRouterSlot().LIEN_TOKEN.createLien(
        ILienToken.LienActionEncumber({
          tokenContract: params.tokenContract,
          tokenId: params.tokenId,
          terms: terms,
          strategyRoot: params.lienRequest.merkle.root,
          amount: params.lienRequest.amount,
          stack: params.lienRequest.stack,
          vault: address(msg.sender)
        })
      );
  }

  /**
   * @notice Lend to a PublicVault.
   * @param vault The address of the PublicVault.
   * @param amount The amount to lend.
   */
  function lendToVault(IVault vault, uint256 amount) external whenNotPaused {
    RouterStorage storage s = _loadRouterSlot();
    s.TRANSFER_PROXY.tokenTransferFrom(
      address(s.WETH),
      address(msg.sender),
      address(this),
      amount
    );

    if (s.vaults[address(vault)] == address(0)) {
      revert InvalidVaultState(VaultState.UNINITIALIZED);
    }

    //    require(
    //      ,
    //      "lendToVault: vault doesn't exist"
    //    );
    s.WETH.safeApprove(address(vault), amount);
    vault.deposit(amount, address(msg.sender));
  }

  /**
   * @notice Returns whether a specific lien can be liquidated.
   * @param collateralId The ID of the underlying CollateralToken.
   * @param position The specified lien position.
   * @return A boolean value indicating whether the specified lien can be liquidated.
   */
  function canLiquidate(
    uint256 collateralId,
    uint256 position,
    ILienToken.LienEvent[] memory stack
  ) public view returns (bool) {
    RouterStorage storage s = _loadRouterSlot();
    ILienToken.LienDataPoint memory point = s.LIEN_TOKEN.getPoint(stack[0]);

    return (stack[position].end <= block.timestamp);
  }

  /**
   * @notice Liquidate a CollateralToken that has defaulted on one of its liens.
   * @param collateralId The ID of the CollateralToken.
   * @param position The position of the defaulted lien.
   * @return reserve The amount owed on all liens for against the collateral being liquidated, including accrued interest.
   */
  function liquidate(
    uint256 collateralId,
    uint256 position,
    ILienToken.LienEvent[] memory stack
  ) external returns (uint256 reserve) {
    if (!canLiquidate(collateralId, position, stack)) {
      revert InvalidLienState(LienState.HEALTHY);
    }

    //    require(
    //      ,
    //      "liquidate: borrow is healthy"
    //    );

    // if expiration will be past epoch boundary, then create a LiquidationAccountant

    RouterStorage storage s = _loadRouterSlot();
    uint256[] memory liens = s.LIEN_TOKEN.getLiens(collateralId);
    for (uint256 i = 0; i < liens.length; ++i) {
      uint256 currentLien = liens[i];
      require(currentLien == LIEN_TOKEN().validateLien(stack[i]));

      address owner = s.LIEN_TOKEN.getPayee(currentLien);
      if (
        IPublicVault(owner).supportsInterface(type(IPublicVault).interfaceId)
      ) {
        // update the public vault state and get the liquidation accountant back if any
        address accountantIfAny = PublicVault(owner)
          .updateVaultAfterLiquidation(stack[i]);

        if (accountantIfAny != address(0)) {
          s.LIEN_TOKEN.setPayee(stack[i], accountantIfAny);
        }
      }
    }

    (uint256 reserve, ) = s.LIEN_TOKEN.stopLiens(collateralId, stack);
    s.COLLATERAL_TOKEN.auctionVault(collateralId, address(msg.sender), reserve);

    emit Liquidation(collateralId, position, reserve);
  }

  /**
   * @notice Retrieves the fee PublicVault strategists earn on loan origination.
   * @return The numerator and denominator used to compute the percentage fee strategists earn by receiving minted vault shares.
   */
  function getStrategistFee(uint256 amountIn) external view returns (uint256) {
    RouterStorage storage s = _loadRouterSlot();
    return
      amountIn.mulDivDown(s.strategistFeeNumerator, s.strategistFeeDenominator);
  }

  /**
   * @notice Retrieves the fee the protocol earns on loan origination.
   * @return The numerator and denominator used to compute the percentage fee taken by the protocol
   */
  function getProtocolFee(uint256 amountIn) external view returns (uint256) {
    RouterStorage storage s = _loadRouterSlot();

    return
      amountIn.mulDivDown(s.protocolFeeNumerator, s.protocolFeeDenominator);
  }

  /**
   * @notice Retrieves the fee the liquidator earns for processing auctions
   * @return The numerator and denominator used to compute the percentage fee taken by the liquidator
   */
  function getLiquidatorFee(uint256 amountIn) external view returns (uint256) {
    RouterStorage storage s = _loadRouterSlot();

    return
      amountIn.mulDivDown(
        s.liquidationFeeNumerator,
        s.liquidationFeeDenominator
      );
  }

  /**
   * @notice Retrieves the fee the protocol earns on loan origination.
   * @return The numerator and denominator used to compute the percentage fee taken by the protocol
   */

  function getBuyoutFee(uint256 remainingInterestIn)
    external
    view
    returns (uint256)
  {
    RouterStorage storage s = _loadRouterSlot();
    return
      remainingInterestIn.mulDivDown(
        s.buyoutFeeNumerator,
        s.buyoutFeeDenominator
      );
  }

  /**
   * @notice Retrieves the time window for computing maxbuyout costs
   * @return The numerator and denominator used to compute the percentage fee taken by the protocol
   */
  function getBuyoutInterestWindow() external view returns (uint32) {
    return _loadRouterSlot().buyoutInterestWindow;
  }

  /**
   * @notice Returns whether a given address is that of a Vault.
   * @param vault The Vault address.
   * @return A boolean representing whether the address exists as a Vault.
   */
  function isValidVault(address vault) external view returns (bool) {
    return _loadRouterSlot().vaults[vault] != address(0);
  }

  /**
   * @notice Determines whether a potential refinance meets the minimum requirements for replacing a lien.
   * @param lien The Lien to be refinanced.
   * @param newLien The new Lien to replace the existing one.
   * @return A boolean representing whether the potential refinance is valid.
   */
  function isValidRefinance(
    ILienToken.Lien memory lien,
    ILienToken.Details memory newLien
  ) external view returns (bool) {
    RouterStorage storage s = _loadRouterSlot();
    uint256 minNewRate = uint256(lien.rate) - s.minInterestBPS;

    if (
      (newLien.rate < minNewRate) ||
      (block.timestamp + newLien.duration - lien.end < s.minDurationIncrease)
    ) {
      return false;
    }

    return true;
  }

  //INTERNAL FUNCS

  /**
   * @dev Deploys a new PublicVault.
   * @param epochLength The length of each epoch for the new PublicVault.
   * @return vaultAddr The address for the new PublicVault.
   */
  function _newVault(
    uint256 epochLength,
    address delegate,
    uint256 vaultFee,
    bool allowListEnabled,
    address[] memory allowList,
    uint256 depositCap
  ) internal returns (address vaultAddr) {
    uint8 vaultType;

    RouterStorage storage s = _loadRouterSlot();
    if (epochLength > uint256(0)) {
      if (s.minEpochLength > epochLength || epochLength > s.maxEpochLength) {
        revert InvalidEpochLength(epochLength);
      }

      vaultType = uint8(ImplementationType.PublicVault);
    } else {
      vaultType = uint8(ImplementationType.PrivateVault);
    }

    //immutable data
    vaultAddr = ClonesWithImmutableArgs.clone(
      s.BEACON_PROXY_IMPLEMENTATION,
      abi.encodePacked(
        address(this),
        vaultType,
        address(msg.sender),
        address(s.WETH),
        block.timestamp,
        epochLength,
        vaultFee
      )
    );

    //mutable data
    VaultImplementation(vaultAddr).init(
      VaultImplementation.InitParams({
        delegate: delegate,
        allowListEnabled: allowListEnabled,
        allowList: allowList,
        depositCap: depositCap
      })
    );

    s.vaults[vaultAddr] = msg.sender;

    emit NewVault(msg.sender, vaultAddr);

    return vaultAddr;
  }

  /**
   * @dev validates msg sender is owner
   * @param c The commitment Data
   * @return the amount borrowed
   */
  function _executeCommitment(
    RouterStorage storage s,
    IAstariaRouter.Commitment memory c
  ) internal returns (uint256, ILienToken.LienEvent[] memory stack) {
    uint256 collateralId = c.tokenContract.computeId(c.tokenId);

    if (msg.sender != s.COLLATERAL_TOKEN.ownerOf(collateralId)) {
      revert InvalidSenderForCollateral(msg.sender, collateralId);
    }
    //router must be approved for the collateral to take a loan,
    return
      VaultImplementation(c.lienRequest.strategy.vault).commitToLien(
        c,
        address(this)
      );
  }

  function _transferAndDepositAsset(
    RouterStorage storage s,
    address tokenContract,
    uint256 tokenId
  ) internal {
    IERC721(tokenContract).safeTransferFrom(
      address(msg.sender),
      address(s.COLLATERAL_TOKEN),
      tokenId,
      ""
    );
  }
}
