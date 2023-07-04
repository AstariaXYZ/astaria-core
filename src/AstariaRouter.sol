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

import {Authority} from "solmate/auth/Auth.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {ERC721} from "solmate/tokens/ERC721.sol";
import {ITransferProxy} from "core/interfaces/ITransferProxy.sol";
import {SafeCastLib} from "gpl/utils/SafeCastLib.sol";
import {
  Create2ClonesWithImmutableArgs
} from "create2-clones-with-immutable-args/Create2ClonesWithImmutableArgs.sol";

import {CollateralLookup} from "core/libraries/CollateralLookup.sol";

import {IAstariaRouter} from "core/interfaces/IAstariaRouter.sol";
import {ICollateralToken} from "core/interfaces/ICollateralToken.sol";
import {ILienToken} from "core/interfaces/ILienToken.sol";
import {IVaultImplementation} from "core/interfaces/IVaultImplementation.sol";
import {IAstariaVaultBase} from "core/interfaces/IAstariaVaultBase.sol";
import {IStrategyValidator} from "core/interfaces/IStrategyValidator.sol";

import {MerkleProofLib} from "core/utils/MerkleProofLib.sol";
import {Pausable} from "core/utils/Pausable.sol";
import {IERC4626} from "core/interfaces/IERC4626.sol";
import {ERC4626Router} from "gpl/ERC4626Router.sol";
import {IPublicVault} from "core/interfaces/IPublicVault.sol";
import {OrderParameters} from "seaport-types/src/lib/ConsiderationStructs.sol";
import {AuthInitializable} from "core/AuthInitializable.sol";
import {Initializable} from "./utils/Initializable.sol";

/**
 * @title AstariaRouter
 * @notice This contract manages the deployment of Vaults and universal Astaria actions.
 */
contract AstariaRouter is
  AuthInitializable,
  Initializable,
  ERC4626Router,
  Pausable,
  IAstariaRouter
{
  using SafeTransferLib for ERC20;
  using SafeCastLib for uint256;
  using CollateralLookup for address;
  using FixedPointMathLib for uint256;

  uint256 private constant ROUTER_SLOT =
    uint256(keccak256("xyz.astaria.AstariaRouter.storage.location")) - 1;
  bytes32 public constant STRATEGY_TYPEHASH =
    keccak256("StrategyDetails(uint256 nonce,uint256 deadline,bytes32 root)");
  // cast --to-bytes32 $(cast sig "OutOfBoundError()")
  uint256 private constant OUTOFBOUND_ERROR_SELECTOR =
    0x571e08d100000000000000000000000000000000000000000000000000000000;
  uint256 private constant ONE_WORD = 0x20;

  constructor() {
    _disableInitializers();
  }

  /**
   * @dev Setup transfer authority and set up addresses for deployed CollateralToken, LienToken, TransferProxy contracts, as well as PublicVault and SoloVault implementations to clone.
   * @param _AUTHORITY The authority manager.
   * @param _COLLATERAL_TOKEN The address of the deployed CollateralToken contract.
   * @param _LIEN_TOKEN The address of the deployed LienToken contract.
   * @param _TRANSFER_PROXY The address of the deployed TransferProxy contract.
   * @param _VAULT_IMPL The address of a base implementation of VaultImplementation for cloning.
   * @param _SOLO_IMPL The address of a base implementation of a PrivateVault for cloning.
   */
  function initialize(
    Authority _AUTHORITY,
    ICollateralToken _COLLATERAL_TOKEN,
    ILienToken _LIEN_TOKEN,
    ITransferProxy _TRANSFER_PROXY,
    address _VAULT_IMPL,
    address _SOLO_IMPL,
    address _WITHDRAW_IMPL,
    address _BEACON_PROXY_IMPL,
    address _WETH
  ) external initializer {
    __initAuth(msg.sender, address(_AUTHORITY));
    RouterStorage storage s = _loadRouterSlot();

    s.COLLATERAL_TOKEN = _COLLATERAL_TOKEN;
    s.LIEN_TOKEN = _LIEN_TOKEN;
    s.TRANSFER_PROXY = _TRANSFER_PROXY;
    s.implementations[uint8(ImplementationType.PrivateVault)] = _SOLO_IMPL;
    s.implementations[uint8(ImplementationType.PublicVault)] = _VAULT_IMPL;
    s.implementations[uint8(ImplementationType.WithdrawProxy)] = _WITHDRAW_IMPL;
    s.BEACON_PROXY_IMPLEMENTATION = _BEACON_PROXY_IMPL;
    s.auctionWindow = uint32(3 days);

    s.liquidationFeeNumerator = uint32(130);
    s.liquidationFeeDenominator = uint32(1000);
    s.minEpochLength = uint32(7 days);
    s.maxEpochLength = uint32(45 days);
    s.maxInterestRate = ((uint256(1e16) * 200) / (365 days));
    s.maxStrategistFee = uint256(50e17);
    //63419583966; // 200% apy / second
    s.guardian = msg.sender;
    s.minLoanDuration = 1 hours;
    s.WETH = _WETH;
  }

  function mint(
    IERC4626 vault,
    address to,
    uint256 shares,
    uint256 maxAmountIn
  )
    public
    payable
    virtual
    override
    validVault(address(vault))
    returns (uint256 amountIn)
  {
    return super.mint(vault, to, shares, maxAmountIn);
  }

  function deposit(
    IERC4626 vault,
    address to,
    uint256 amount,
    uint256 minSharesOut
  )
    public
    payable
    virtual
    override
    validVault(address(vault))
    returns (uint256 sharesOut)
  {
    return super.deposit(vault, to, amount, minSharesOut);
  }

  function withdraw(
    IERC4626 vault,
    address to,
    uint256 amount,
    uint256 maxSharesOut
  )
    public
    payable
    virtual
    override
    validVault(address(vault))
    returns (uint256 sharesOut)
  {
    return super.withdraw(vault, to, amount, maxSharesOut);
  }

  function redeem(
    IERC4626 vault,
    address to,
    uint256 shares,
    uint256 minAmountOut
  )
    public
    payable
    virtual
    override
    validVault(address(vault))
    returns (uint256 amountOut)
  {
    return super.redeem(vault, to, shares, minAmountOut);
  }

  function redeemFutureEpoch(
    IPublicVault vault,
    uint256 shares,
    address receiver,
    uint64 epoch
  ) public virtual validVault(address(vault)) returns (uint256 assets) {
    return vault.redeemFutureEpoch(shares, receiver, msg.sender, epoch);
  }

  modifier validVault(address targetVault) {
    if (!isValidVault(targetVault)) {
      revert InvalidVault(targetVault);
    }
    _;
  }

  function pullToken(
    address token,
    uint256 amount,
    address recipient
  ) public payable override {
    RouterStorage storage s = _loadRouterSlot();
    s.TRANSFER_PROXY.tokenTransferFrom(
      address(token),
      msg.sender,
      recipient,
      amount
    );
  }

  function _loadRouterSlot() internal pure returns (RouterStorage storage rs) {
    uint256 slot = ROUTER_SLOT;
    assembly {
      rs.slot := slot
    }
  }

  /**
   * @notice Retrieves the address that collects protocol-level fees.
   */
  function feeTo() public view returns (address) {
    RouterStorage storage s = _loadRouterSlot();
    return s.feeTo;
  }

  /**
   * @notice Retrieves the Beacon proxy implementation
   */
  function BEACON_PROXY_IMPLEMENTATION() public view returns (address) {
    RouterStorage storage s = _loadRouterSlot();
    return s.BEACON_PROXY_IMPLEMENTATION;
  }

  /**
   * @notice Retrieves the ILienToken
   */
  function LIEN_TOKEN() public view returns (ILienToken) {
    RouterStorage storage s = _loadRouterSlot();
    return s.LIEN_TOKEN;
  }

  /**
   * @notice Retrieves the ITransferProxy
   */
  function TRANSFER_PROXY() public view returns (ITransferProxy) {
    RouterStorage storage s = _loadRouterSlot();
    return s.TRANSFER_PROXY;
  }

  /**
   * @notice Retrieves the ICollateralToken
   */
  function COLLATERAL_TOKEN() public view returns (ICollateralToken) {
    RouterStorage storage s = _loadRouterSlot();
    return s.COLLATERAL_TOKEN;
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

  /**
   * @notice Sets universal protocol parameters or changes the addresses for deployed contracts.
   * @param files The incoming Files.
   */
  function fileBatch(File[] calldata files) external requiresAuth {
    uint256 i;
    for (; i < files.length; ) {
      _file(files[i]);
      unchecked {
        ++i;
      }
    }
  }

  /**
   * @notice Sets universal protocol parameters or changes the addresses for deployed contracts.
   * @param incoming The incoming file.
   */
  function file(File calldata incoming) public requiresAuth {
    _file(incoming);
  }

  function _file(File calldata incoming) internal {
    RouterStorage storage s = _loadRouterSlot();
    FileType what = incoming.what;
    bytes memory data = incoming.data;

    if (what == FileType.AuctionWindow) {
      uint256 window = abi.decode(data, (uint256));
      s.auctionWindow = window.safeCastTo32();
    } else if (what == FileType.LiquidationFee) {
      (uint256 numerator, uint256 denominator) = abi.decode(
        data,
        (uint256, uint256)
      );
      if (denominator < numerator) revert InvalidFileData();
      s.liquidationFeeNumerator = numerator.safeCastTo32();
      s.liquidationFeeDenominator = denominator.safeCastTo32();
    } else if (what == FileType.ProtocolFee) {
      (uint256 numerator, uint256 denominator) = abi.decode(
        data,
        (uint256, uint256)
      );
      if (denominator < numerator) revert InvalidFileData();
      s.protocolFeeNumerator = numerator.safeCastTo32();
      s.protocolFeeDenominator = denominator.safeCastTo32();
    } else if (what == FileType.MinEpochLength) {
      s.minEpochLength = abi.decode(data, (uint256)).safeCastTo32();
    } else if (what == FileType.MaxEpochLength) {
      s.maxEpochLength = abi.decode(data, (uint256)).safeCastTo32();
    } else if (what == FileType.MaxInterestRate) {
      s.maxInterestRate = abi.decode(data, (uint256));
    } else if (what == FileType.MaxStrategistFee) {
      uint256 maxFee = abi.decode(data, (uint256));
      //vaults process denominators of the fee as base 1e18
      if (maxFee > 1e18) revert InvalidFileData();
      s.maxStrategistFee = maxFee;
    } else if (what == FileType.MinLoanDuration) {
      //vaults process denominators of the fee as base 1e18
      s.minLoanDuration = abi.decode(data, (uint256)).safeCastTo32();
    } else if (what == FileType.FeeTo) {
      address addr = abi.decode(data, (address));
      if (addr == address(0)) revert InvalidFileData();
      s.feeTo = addr;
    } else if (what == FileType.StrategyValidator) {
      (uint8 TYPE, address addr) = abi.decode(data, (uint8, address));
      if (addr == address(0)) revert InvalidFileData();
      s.strategyValidators[TYPE] = addr;
    } else {
      revert UnsupportedFile();
    }

    emit FileUpdated(what, data);
  }

  /**
   * @notice Retrieves the address of the WETH used by the protocol.
   */
  function WETH() external returns (address) {
    RouterStorage storage s = _loadRouterSlot();
    return s.WETH;
  }

  /**
   * @notice Updates the guardian address.
   * @param _guardian The new guardian.
   */
  function setNewGuardian(address _guardian) external {
    RouterStorage storage s = _loadRouterSlot();
    require(msg.sender == s.guardian);
    s.newGuardian = _guardian;
  }

  /**
   * @notice renounce the guardian role
   */
  function __renounceGuardian() external {
    RouterStorage storage s = _loadRouterSlot();
    require(msg.sender == s.guardian);
    s.guardian = address(0);
    s.newGuardian = address(0);
  }

  /**
   * @notice accept the guardian role
   */
  function __acceptGuardian() external {
    RouterStorage storage s = _loadRouterSlot();
    require(msg.sender == s.newGuardian);
    s.guardian = s.newGuardian;
    delete s.newGuardian;
  }

  /**
   * @notice Specially guarded file().
   * @param file The incoming data to file.
   */
  function fileGuardian(File[] calldata file) external {
    RouterStorage storage s = _loadRouterSlot();
    require(msg.sender == address(s.guardian));

    uint256 i;
    for (; i < file.length; ) {
      FileType what = file[i].what;
      bytes memory data = file[i].data;
      if (what == FileType.Implementation) {
        (uint8 implType, address addr) = abi.decode(data, (uint8, address));
        if (addr == address(0)) revert InvalidFileData();
        s.implementations[implType] = addr;
      } else if (what == FileType.CollateralToken) {
        address addr = abi.decode(data, (address));
        if (addr == address(0)) revert InvalidFileData();
        s.COLLATERAL_TOKEN = ICollateralToken(addr);
      } else if (what == FileType.LienToken) {
        address addr = abi.decode(data, (address));
        if (addr == address(0)) revert InvalidFileData();
        s.LIEN_TOKEN = ILienToken(addr);
      } else if (what == FileType.TransferProxy) {
        address addr = abi.decode(data, (address));
        if (addr == address(0)) revert InvalidFileData();
        s.TRANSFER_PROXY = ITransferProxy(addr);
      } else {
        revert UnsupportedFile();
      }
      emit FileUpdated(what, data);
      unchecked {
        ++i;
      }
    }
  }

  //PUBLIC
  /**
   * @notice Returns the address for the current implementation of a contract from the ImplementationType enum.
   * @return impl The address of the clone implementation.
   */
  function getImpl(uint8 implType) external view returns (address impl) {
    impl = _loadRouterSlot().implementations[implType];
    if (impl == address(0)) {
      revert("unsupported/impl");
    }
  }

  /**
   * @notice Returns auction window
   */
  function getAuctionWindow() public view returns (uint256) {
    RouterStorage storage s = _loadRouterSlot();
    return s.auctionWindow;
  }

  function _sliceUint(
    bytes memory bs,
    uint256 start
  ) internal pure returns (uint256 x) {
    uint256 length = bs.length;

    assembly {
      let end := add(ONE_WORD, start)

      if lt(length, end) {
        mstore(0, OUTOFBOUND_ERROR_SELECTOR)
        revert(0, ONE_WORD)
      }

      x := mload(add(bs, end))
    }
  }

  /**
   * @notice Validates the incoming loan commitment.
   * @param commitment The commitment proofs and requested loan data for each loan.
   * @return lien the new Lien data.
   */
  function validateCommitment(
    IAstariaRouter.Commitment calldata commitment
  ) public view returns (ILienToken.Lien memory lien) {
    return _validateCommitment(_loadRouterSlot(), commitment);
  }

  /**
   * @notice return the strategy validator for this commitment
   * @param commitment The commitment proofs and requested loan data for each loan.
   */
  function getStrategyValidator(
    IAstariaRouter.Commitment calldata commitment
  ) external view returns (address strategyValidator) {
    uint8 nlrType = uint8(_sliceUint(commitment.lienRequest.nlrDetails, 0));
    RouterStorage storage s = _loadRouterSlot();
    strategyValidator = s.strategyValidators[nlrType];
    if (strategyValidator == address(0)) {
      revert InvalidStrategy(nlrType);
    }
  }

  function _validateCommitment(
    RouterStorage storage s,
    IAstariaRouter.Commitment calldata commitment
  ) internal view returns (ILienToken.Lien memory lien) {
    uint8 nlrType = uint8(_sliceUint(commitment.lienRequest.nlrDetails, 0));
    address strategyValidator = s.strategyValidators[nlrType];
    if (strategyValidator == address(0)) {
      revert InvalidStrategy(nlrType);
    }
    (bytes32 leaf, ILienToken.Details memory details) = IStrategyValidator(
      strategyValidator
    ).validateAndParse(
        commitment.lienRequest,
        msg.sender,
        commitment.tokenContract,
        commitment.tokenId
      );

    if (details.rate == uint256(0) || details.rate > s.maxInterestRate) {
      revert InvalidCommitmentState(CommitmentState.INVALID_RATE);
    }

    if (details.maxAmount < commitment.lienRequest.amount) {
      revert InvalidCommitmentState(CommitmentState.INVALID_AMOUNT);
    }

    if (
      !MerkleProofLib.verify(
        commitment.lienRequest.proof,
        commitment.lienRequest.root,
        leaf
      )
    ) {
      revert InvalidCommitmentState(CommitmentState.INVALID);
    }

    lien = ILienToken.Lien({
      collateralType: nlrType,
      details: details,
      //      strategyRoot: commitment.lienRequest.root,
      collateralId: commitment.tokenContract.computeId(commitment.tokenId),
      vault: commitment.lienRequest.strategy.vault,
      token: IAstariaVaultBase(commitment.lienRequest.strategy.vault).asset()
    });
  }

  /**
   * @notice Deposits collateral and requests loans for multiple NFTs at once.
   * @param commitment The commitment proofs and requested loan data for each loan.
   */
  function commitToLien(
    IAstariaRouter.Commitment calldata commitment
  )
    public
    whenNotPaused
    returns (uint256 lienId, ILienToken.Stack memory stack)
  {
    RouterStorage storage s = _loadRouterSlot();

    (lienId, stack) = _executeCommitment(s, commitment);
  }

  /**
   * @dev Validates the incoming request for a lien
   * Who is requesting the borrow, is it a smart contract? or is it a user?
   * if a smart contract, then ensure that the contract is approved to borrow and is also receiving the funds.
   * if a user, then ensure that the user is approved to borrow and is also receiving the funds.
   * The terms are hashed and signed by the borrower, and the signature validated against the strategist's address
   * lien details are decoded from the obligation data and validated the collateral
   *
   * @param params The Commitment information containing the loan parameters and the merkle proof for the strategy supporting the requested loan.
   */
  function _validateRequest(
    RouterStorage storage s,
    IAstariaRouter.Commitment calldata params,
    ILienToken.Stack memory newStack,
    uint256 owingAtEnd
  ) internal {
    if (params.lienRequest.amount == 0) {
      revert ILienToken.InvalidLienState(
        ILienToken.InvalidLienStates.AMOUNT_ZERO
      );
    }
    if (newStack.lien.details.duration < s.minLoanDuration) {
      revert ILienToken.InvalidLienState(
        ILienToken.InvalidLienStates.MIN_DURATION_NOT_MET
      );
    }
    if (
      newStack.lien.details.liquidationInitialAsk < owingAtEnd ||
      newStack.lien.details.liquidationInitialAsk == 0
    ) {
      revert ILienToken.InvalidLienState(
        ILienToken.InvalidLienStates.INVALID_LIQUIDATION_INITIAL_ASK
      );
    }

    if (block.timestamp > params.lienRequest.strategy.deadline) {
      revert StrategyExpired();
    }
  }

  /**
   * @notice Deploys a new PrivateVault.
   * @param delegate The address of the delegate account.
   * @param underlying The address of the underlying token.
   * @return The address of the new PrivateVault.
   */
  function newVault(
    address delegate,
    address underlying
  ) external whenNotPaused returns (address) {
    address[] memory allowList = new address[](1);
    allowList[0] = msg.sender;
    RouterStorage storage s = _loadRouterSlot();

    return
      _newVault(
        s,
        NewVaultParams(
          underlying,
          uint256(0),
          delegate,
          uint256(0),
          true,
          allowList,
          uint256(0)
        )
      );
  }

  /**
   * @notice Deploys a new PublicVault.
   * @param epochLength The length of each epoch for the new PublicVault.
   * @param delegate The address of the delegate account.
   * @param underlying The underlying deposit asset for the vault
   * @param vaultFee fee for the vault
   * @param allowListEnabled flag for the allowlist
   * @param allowList the starting allowList
   * @param depositCap the deposit cap for the vault if any
   */
  function newPublicVault(
    uint256 epochLength,
    address delegate,
    address underlying,
    uint256 vaultFee,
    bool allowListEnabled,
    address[] calldata allowList,
    uint256 depositCap
  ) public whenNotPaused returns (address) {
    RouterStorage storage s = _loadRouterSlot();
    if (s.minEpochLength > epochLength) {
      revert IPublicVault.InvalidVaultState(
        IPublicVault.InvalidVaultStates.EPOCH_TOO_LOW
      );
    }
    if (s.maxEpochLength < epochLength) {
      revert IPublicVault.InvalidVaultState(
        IPublicVault.InvalidVaultStates.EPOCH_TOO_HIGH
      );
    }

    if (vaultFee > s.maxStrategistFee) {
      revert IAstariaRouter.InvalidVaultFee();
    }
    return
      _newVault(
        s,
        NewVaultParams(
          underlying,
          epochLength,
          delegate,
          vaultFee,
          allowListEnabled,
          allowList,
          depositCap
        )
      );
  }

  /**
   * @notice Returns whether a specified lien can be liquidated.
   */
  function canLiquidate(
    ILienToken.Stack memory stack
  ) public view returns (bool) {
    return (stack.point.end <= block.timestamp);
  }

  /**
   * @notice Liquidate a CollateralToken that has defaulted on one of its liens.
   * @param stack the stack being liquidated
   */
  function liquidate(
    ILienToken.Stack memory stack
  ) public whenNotPaused returns (OrderParameters memory listedOrder) {
    if (!canLiquidate(stack)) {
      revert InvalidLienState(LienState.HEALTHY);
    }

    RouterStorage storage s = _loadRouterSlot();
    uint256 auctionWindowMax = s.auctionWindow;

    s.LIEN_TOKEN.handleLiquidation(auctionWindowMax, stack, msg.sender);

    emit Liquidation(
      stack.lien.collateralId,
      msg.sender,
      s.COLLATERAL_TOKEN.SEAPORT().getCounter(address(s.COLLATERAL_TOKEN))
    );
    listedOrder = s.COLLATERAL_TOKEN.auctionVault(
      ICollateralToken.AuctionVaultParams({
        settlementToken: stack.lien.token,
        collateralId: stack.lien.collateralId,
        maxDuration: auctionWindowMax,
        startingPrice: stack.lien.details.liquidationInitialAsk,
        endingPrice: 1_000 wei
      })
    );
  }

  /**
   * @notice Computes the fee the protocol earns on loan origination from the protocolFee numerator and denominator.
   */
  function getProtocolFee(uint256 amountIn) public view returns (uint256) {
    RouterStorage storage s = _loadRouterSlot();

    return _getProtocolFee(s, amountIn);
  }

  function _getProtocolFee(
    RouterStorage storage s,
    uint256 amountIn
  ) internal view returns (uint256) {
    return
      amountIn.mulDivDown(s.protocolFeeNumerator, s.protocolFeeDenominator);
  }

  /**
   * @notice Computes the fee the users earn on liquidating an expired lien from the liquidationFee numerator and denominator.
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
   * @notice Returns whether a given address is that of a Vault.
   * @param vault The Vault address.
   * @return A boolean representing whether the address exists as a Vault.
   */
  function isValidVault(address vault) public view returns (bool) {
    return _loadRouterSlot().vaults[vault];
  }

  struct NewVaultParams {
    address underlying;
    uint256 epochLength;
    address delegate;
    uint256 vaultFee;
    bool allowListEnabled;
    address[] allowList;
    uint256 depositCap;
  }

  /**
   * @dev Deploys a new Vault.
   * @param params The parameters for the new Vault.
   * @return vaultAddr The address for the new Vault.
   */
  function _newVault(
    RouterStorage storage s,
    NewVaultParams memory params
  ) internal returns (address vaultAddr) {
    uint8 vaultType;

    if (params.underlying.code.length == 0) {
      revert InvalidUnderlying(params.underlying);
    }
    if (params.epochLength > uint256(0)) {
      vaultType = uint8(ImplementationType.PublicVault);
    } else {
      vaultType = uint8(ImplementationType.PrivateVault);
    }

    //immutable data
    vaultAddr = Create2ClonesWithImmutableArgs.clone(
      s.BEACON_PROXY_IMPLEMENTATION,
      abi.encodePacked(
        address(this),
        vaultType,
        msg.sender,
        params.underlying,
        block.timestamp,
        params.epochLength,
        params.vaultFee,
        address(s.WETH)
      ),
      keccak256(abi.encodePacked(msg.sender, blockhash(block.number - 1)))
    );

    if (s.LIEN_TOKEN.balanceOf(vaultAddr) > 0) {
      revert InvalidVaultState(IAstariaRouter.VaultState.CORRUPTED);
    }
    //mutable data
    IVaultImplementation(vaultAddr).init(
      IVaultImplementation.InitParams({
        delegate: params.delegate,
        allowListEnabled: params.allowListEnabled,
        allowList: params.allowList,
        depositCap: params.depositCap
      })
    );

    s.vaults[vaultAddr] = true;

    emit NewVault(msg.sender, params.delegate, vaultAddr, vaultType);
  }

  function _validateSignature(
    IAstariaRouter.NewLienRequest calldata params,
    uint256 nonce,
    bytes32 domainSepatator,
    address strategist,
    address delegate
  ) internal pure {
    address recovered = ecrecover(
      keccak256(
        _encodeStrategyData(
          params.strategy,
          nonce,
          domainSepatator,
          params.root
        )
      ),
      params.v,
      params.r,
      params.s
    );
    if (
      (recovered != strategist && recovered != delegate) ||
      recovered == address(0)
    ) {
      revert IVaultImplementation.InvalidRequest(
        IVaultImplementation.InvalidRequestReason.INVALID_SIGNATURE
      );
    }
  }

  function _encodeStrategyData(
    IAstariaRouter.StrategyDetailsParam calldata strategy,
    uint256 nonce,
    bytes32 domainSeparator,
    bytes32 root
  ) internal pure returns (bytes memory) {
    return
      abi.encodePacked(
        bytes1(0x19),
        bytes1(0x01),
        domainSeparator,
        keccak256(abi.encode(STRATEGY_TYPEHASH, nonce, strategy.deadline, root))
      );
  }

  function _executeCommitment(
    RouterStorage storage s,
    IAstariaRouter.Commitment calldata c
  ) internal returns (uint256 lienId, ILienToken.Stack memory stack) {
    if (!s.vaults[c.lienRequest.strategy.vault]) {
      revert InvalidVault(c.lienRequest.strategy.vault);
    }
    (
      ,
      address delegate,
      address owner,
      ,
      ,
      uint256 nonce,
      bytes32 domainSeparator
    ) = IVaultImplementation(c.lienRequest.strategy.vault).getState();
    ERC721(c.tokenContract).transferFrom(
      msg.sender,
      address(s.COLLATERAL_TOKEN),
      c.tokenId
    );
    s.COLLATERAL_TOKEN.depositERC721(c.tokenContract, c.tokenId, msg.sender);
    _validateSignature(c.lienRequest, nonce, domainSeparator, owner, delegate);

    uint256 owingAtEnd;

    ILienToken.Lien memory lien = _validateCommitment({s: s, commitment: c});
    IPublicVault publicVault = IPublicVault(c.lienRequest.strategy.vault);
    if (publicVault.supportsInterface(type(IPublicVault).interfaceId)) {
      uint256 timeToSecondEpochEnd = publicVault.timeToSecondEpochEnd();
      require(timeToSecondEpochEnd > 0, "already two epochs ahead");
      if (timeToSecondEpochEnd < lien.details.duration) {
        lien.details.duration = timeToSecondEpochEnd;
      }
    }
    (lienId, stack, owingAtEnd) = s.LIEN_TOKEN.createLien(
      ILienToken.LienActionEncumber({
        lien: lien,
        borrower: msg.sender,
        amount: c.lienRequest.amount,
        receiver: c.lienRequest.strategy.vault,
        feeTo: s.feeTo,
        fee: s.feeTo == address(0)
          ? 0
          : _getProtocolFee(s, c.lienRequest.amount)
      })
    );
    _validateRequest(s, c, stack, owingAtEnd);
  }
}
