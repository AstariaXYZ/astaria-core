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

import {ERC20} from "solmate/tokens/ERC20.sol";
import {ERC721, ERC721TokenReceiver} from "solmate/tokens/ERC721.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {CollateralLookup} from "core/libraries/CollateralLookup.sol";

import {IAstariaRouter} from "core/interfaces/IAstariaRouter.sol";
import {LienToken} from "core/LienToken.sol";
import {ILienToken} from "core/interfaces/ILienToken.sol";
import {IPublicVault} from "core/interfaces/IPublicVault.sol";
import {AstariaVaultBase} from "core/AstariaVaultBase.sol";
import {IVaultImplementation} from "core/interfaces/IVaultImplementation.sol";
import {SafeCastLib} from "gpl/utils/SafeCastLib.sol";

/**
 * @title VaultImplementation
 * @notice A base implementation for the minimal features of an Astaria Vault.
 */
abstract contract VaultImplementation is
  AstariaVaultBase,
  ERC721TokenReceiver,
  IVaultImplementation
{
  using SafeTransferLib for ERC20;
  using SafeCastLib for uint256;
  using CollateralLookup for address;
  using FixedPointMathLib for uint256;

  bytes32 public constant STRATEGY_TYPEHASH =
    keccak256("StrategyDetails(uint256 nonce,uint256 deadline,bytes32 root)");

  bytes32 constant EIP_DOMAIN =
    keccak256(
      "EIP712Domain(string version,uint256 chainId,address verifyingContract)"
    );
  bytes32 constant VERSION = keccak256("0");

  function name() external view virtual override returns (string memory);

  function symbol() external view virtual override returns (string memory);

  uint256 private constant VI_SLOT =
    uint256(keccak256("xyz.astaria.VaultImplementation.storage.location")) - 1;

  function getStrategistNonce() external view returns (uint256) {
    return _loadVISlot().strategistNonce;
  }

  function getState()
    external
    view
    virtual
    returns (uint, address, bool, bool, uint)
  {
    VIData storage s = _loadVISlot();
    return (
      s.depositCap,
      s.delegate,
      s.allowListEnabled,
      s.isShutdown,
      s.strategistNonce
    );
  }

  function getAllowList(address depositor) external view returns (bool) {
    VIData storage s = _loadVISlot();
    if (!s.allowListEnabled) {
      return true;
    }
    return s.allowList[depositor];
  }

  function incrementNonce() external {
    VIData storage s = _loadVISlot();
    if (msg.sender != owner() && msg.sender != s.delegate) {
      revert InvalidRequest(InvalidRequestReason.NO_AUTHORITY);
    }
    s.strategistNonce++;
    emit NonceUpdated(s.strategistNonce);
  }

  /**
   * @notice modify the deposit cap for the vault
   * @param newCap The deposit cap.
   */
  function modifyDepositCap(uint256 newCap) external {
    require(msg.sender == owner()); //owner is "strategist"
    _loadVISlot().depositCap = newCap;
  }

  function _loadVISlot() internal pure returns (VIData storage s) {
    uint256 slot = VI_SLOT;

    assembly {
      s.slot := slot
    }
  }

  /**
   * @notice modify the allowlist for the vault
   * @param depositor the depositor to modify
   * @param enabled the status of the depositor
   */
  function modifyAllowList(address depositor, bool enabled) external virtual {
    require(msg.sender == owner()); //owner is "strategist"
    _loadVISlot().allowList[depositor] = enabled;
    emit AllowListUpdated(depositor, enabled);
  }

  /**
   * @notice disable the allowList for the vault
   */
  function disableAllowList() external virtual {
    require(msg.sender == owner()); //owner is "strategist"
    _loadVISlot().allowListEnabled = false;
    emit AllowListEnabled(false);
  }

  /**
   * @notice enable the allowList for the vault
   */
  function enableAllowList() external virtual {
    require(msg.sender == owner()); //owner is "strategist"
    _loadVISlot().allowListEnabled = true;
    emit AllowListEnabled(true);
  }

  /**
   * @notice receive hook for ERC721 tokens, nothing special done
   */
  function onERC721Received(
    address operator, // operator_
    address from, // from_
    uint256 tokenId, // tokenId_
    bytes calldata data // data_
  ) external virtual override returns (bytes4) {
    return ERC721TokenReceiver.onERC721Received.selector;
  }

  modifier whenNotPaused() {
    if (ROUTER().paused()) {
      revert InvalidRequest(InvalidRequestReason.PAUSED);
    }

    if (_loadVISlot().isShutdown) {
      revert InvalidRequest(InvalidRequestReason.SHUTDOWN);
    }
    _;
  }

  function getShutdown() external view returns (bool) {
    return _loadVISlot().isShutdown;
  }

  function shutdown() external {
    require(msg.sender == owner()); //owner is "strategist"
    _loadVISlot().isShutdown = true;
    emit VaultShutdown();
  }

  function domainSeparator() public view virtual returns (bytes32) {
    return
      keccak256(
        abi.encode(
          EIP_DOMAIN,
          VERSION, //version
          block.chainid,
          address(this)
        )
      );
  }

  /*
   * @notice encodes the data for a 712 signature
   * @param tokenContract The address of the token contract
   * @param tokenId The id of the token
   * @param amount The amount of the token
   */
  function encodeStrategyData(
    IAstariaRouter.StrategyDetailsParam calldata strategy,
    bytes32 root
  ) external view returns (bytes memory) {
    VIData storage s = _loadVISlot();
    return _encodeStrategyData(s, strategy, root);
  }

  function _encodeStrategyData(
    VIData storage s,
    IAstariaRouter.StrategyDetailsParam calldata strategy,
    bytes32 root
  ) internal view returns (bytes memory) {
    bytes32 hash = keccak256(
      abi.encode(STRATEGY_TYPEHASH, s.strategistNonce, strategy.deadline, root)
    );
    return
      abi.encodePacked(bytes1(0x19), bytes1(0x01), domainSeparator(), hash);
  }

  function init(InitParams calldata params) external virtual {
    require(msg.sender == address(ROUTER()));
    VIData storage s = _loadVISlot();

    if (params.delegate != address(0)) {
      s.delegate = params.delegate;
    }
    s.depositCap = params.depositCap;
    if (params.allowListEnabled) {
      s.allowListEnabled = true;
      uint256 i;
      for (; i < params.allowList.length; ) {
        s.allowList[params.allowList[i]] = true;
        unchecked {
          ++i;
        }
      }
    }
  }

  function setDelegate(address delegate_) external {
    require(msg.sender == owner()); //owner is "strategist"
    VIData storage s = _loadVISlot();
    s.delegate = delegate_;
    emit DelegateUpdated(delegate_);
    emit AllowListUpdated(delegate_, true);
  }

  function validateStrategy(
    IAstariaRouter.NewLienRequest calldata params
  ) external view returns (bytes4 selector) {
    _validateSignature(params);
    selector = IVaultImplementation.validateStrategy.selector;
  }

  function _validateSignature(
    IAstariaRouter.NewLienRequest calldata params
  ) internal view {
    VIData storage s = _loadVISlot();
    if (params.strategy.vault != address(this)) {
      revert InvalidRequest(InvalidRequestReason.INVALID_VAULT);
    }
    address recovered = ecrecover(
      keccak256(_encodeStrategyData(s, params.strategy, params.merkle.root)),
      params.v,
      params.r,
      params.s
    );
    if (
      (recovered != owner() && recovered != s.delegate) ||
      recovered == address(0)
    ) {
      revert IVaultImplementation.InvalidRequest(
        InvalidRequestReason.INVALID_SIGNATURE
      );
    }
  }

  function _afterCommitToLien(
    uint40 end,
    uint256 lienId,
    uint256 slope
  ) internal virtual {}

  function _beforeCommitToLien(
    IAstariaRouter.Commitment calldata
  ) internal virtual {}

  //  /**
  //   * @notice Pipeline for lifecycle of new loan origination.
  //   * Origination consists of a few phases: pre-commitment validation, lien token issuance, strategist reward, and after commitment actions
  //   * Starts by depositing collateral and take optimized-out a lien against it. Next, verifies the merkle proof for a loan commitment. Vault owners are then rewarded fees for successful loan origination.
  //   * @param params Commitment data for the incoming lien request
  //   */
  //  function commitToLien(
  //    IAstariaRouter.Commitment calldata params,
  //    uint256 lienId,
  //    uint40 lienEnd,
  //    uint256 slopeAddition
  //  ) external {
  //    if (msg.sender != address(ROUTER())) {
  //      revert InvalidRequest(InvalidRequestReason.NO_AUTHORITY);
  //    }
  //    if (_loadVISlot().isShutdown) {
  //      revert InvalidRequest(InvalidRequestReason.SHUTDOWN);
  //    }
  //    _beforeCommitToLien(params);
  //    //    uint256 slopeAddition;
  //    //    (lienId, stack, slopeAddition) = _requestLienAndIssuePayout(params);
  //    _issuePayout(params);
  //    _afterCommitToLien(lienEnd, lienId, slopeAddition);
  //  }

  function _timeToSecondEndIfPublic()
    internal
    view
    virtual
    returns (uint256 timeToSecondEpochEnd)
  {
    return 0;
  }

  function timeToSecondEpochEnd() public view returns (uint256) {
    return _timeToSecondEndIfPublic();
  }

  /**
   * @notice Retrieves the recipient of loan repayments. For PublicVaults (VAULT_TYPE 2), this is always the vault address. For PrivateVaults, retrieves the owner() of the vault.
   * @return The address of the recipient.
   */
  function recipient() public view returns (address) {
    if (_isPublicVault()) {
      return address(this);
    } else {
      return owner();
    }
  }

  function _isPublicVault() internal view returns (bool) {
    return IMPL_TYPE() == uint8(IAstariaRouter.ImplementationType.PublicVault);
  }

  /**
   * @dev Generates a Lien for a valid loan commitment proof and sends the loan amount to the borrower.
   * @param receiver the address being paid
   * @param amount the amount being paid
   */
  function _issuePayout(address receiver, uint256 amount) internal {
    ERC20(asset()).safeTransfer(receiver, amount);
  }
}
