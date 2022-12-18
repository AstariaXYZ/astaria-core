// SPDX-License-Identifier: UNLICENSED

/**
 *       __  ___       __
 *  /\  /__'  |   /\  |__) |  /\
 * /~~\ .__/  |  /~~\ |  \ | /~~\
 *
 * Copyright (c) Astaria Labs, Inc
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

  function name() public view virtual override returns (string memory);

  function symbol() public view virtual override returns (string memory);

  uint256 private constant VI_SLOT =
    uint256(keccak256("xyz.astaria.VaultImplementation.storage.location")) - 1;

  function getStrategistNonce() external view returns (uint256) {
    return _loadVISlot().strategistNonce;
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
  function modifyDepositCap(uint256 newCap) public {
    require(msg.sender == owner()); //owner is "strategist"
    _loadVISlot().depositCap = newCap.safeCastTo88();
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
    address, // operator_
    address, // from_
    uint256, // tokenId_
    bytes calldata // data_
  ) external pure override returns (bytes4) {
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
          keccak256(
            "EIP712Domain(string version,uint256 chainId,address verifyingContract)"
          ),
          keccak256("0"), //version
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
    s.depositCap = params.depositCap.safeCastTo88();
    if (params.allowListEnabled) {
      s.allowListEnabled = true;
      for (uint256 i = 0; i < params.allowList.length; i++) {
        s.allowList[params.allowList[i]] = true;
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

  /**
   * @dev Validates the terms for a requested loan.
   * Who is requesting the borrow, is it a smart contract? or is it a user?
   * if a smart contract, then ensure that the contract is approved to borrow and is also receiving the funds.
   * if a user, then ensure that the user is approved to borrow and is also receiving the funds.
   * The terms are hashed and signed by the borrower, and the signature validated against the strategist's address
   * lien details are decoded from the obligation data and validated the collateral
   *
   * @param params The Commitment information containing the loan parameters and the merkle proof for the strategy supporting the requested loan.
   * @param receiver The address of the prospective borrower.
   */
  function _validateCommitment(
    IAstariaRouter.Commitment calldata params,
    address receiver
  ) internal view {
    uint256 collateralId = params.tokenContract.computeId(params.tokenId);
    ERC721 CT = ERC721(address(COLLATERAL_TOKEN()));
    address holder = CT.ownerOf(collateralId);
    address operator = CT.getApproved(collateralId);
    if (
      msg.sender != holder &&
      receiver != holder &&
      receiver != operator &&
      !ROUTER().isValidVault(receiver) &&
      !CT.isApprovedForAll(holder, receiver) &&
      receiver != params.lienRequest.strategy.vault
    ) {
      revert InvalidRequest(InvalidRequestReason.NO_AUTHORITY);
    }
    VIData storage s = _loadVISlot();
    address recovered = ecrecover(
      keccak256(
        _encodeStrategyData(
          s,
          params.lienRequest.strategy,
          params.lienRequest.merkle.root
        )
      ),
      params.lienRequest.v,
      params.lienRequest.r,
      params.lienRequest.s
    );
    if (
      recovered != owner() && recovered != s.delegate && recovered != address(0)
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

  function _beforeCommitToLien(IAstariaRouter.Commitment calldata)
    internal
    virtual
  {}

  /**
   * @notice Pipeline for lifecycle of new loan origination.
   * Origination consists of a few phases: pre-commitment validation, lien token issuance, strategist reward, and after commitment actions
   * Starts by depositing collateral and take optimized-out a lien against it. Next, verifies the merkle proof for a loan commitment. Vault owners are then rewarded fees for successful loan origination.
   * @param params Commitment data for the incoming lien request
   * @param receiver The borrower receiving the loan.
   * @return lienId The id of the newly minted lien token.
   */
  function commitToLien(
    IAstariaRouter.Commitment calldata params,
    address receiver
  )
    external
    whenNotPaused
    returns (uint256 lienId, ILienToken.Stack[] memory stack)
  {
    _beforeCommitToLien(params);
    uint256 slopeAddition;
    (lienId, stack, slopeAddition) = _requestLienAndIssuePayout(
      params,
      receiver
    );
    _afterCommitToLien(
      stack[stack.length - 1].point.end,
      lienId,
      slopeAddition
    );
  }

  /**
   * @notice Buy optimized-out a lien to replace it with new terms.
   * @param collateralId The ID of the underlying CollateralToken.
   * @param position The position of the specified lien.
   * @param incomingTerms The loan terms of the new lien.
   */
  function buyoutLien(
    uint256 collateralId,
    uint8 position,
    IAstariaRouter.Commitment calldata incomingTerms,
    ILienToken.Stack[] calldata stack
  )
    external
    whenNotPaused
    returns (ILienToken.Stack[] memory, ILienToken.Stack memory)
  {
    (uint256 owed, uint256 buyout) = IAstariaRouter(ROUTER())
      .LIEN_TOKEN()
      .getBuyout(stack[position]);

    if (buyout > ERC20(asset()).balanceOf(address(this))) {
      revert IVaultImplementation.InvalidRequest(
        InvalidRequestReason.INSUFFICIENT_FUNDS
      );
    }

    _validateCommitment(incomingTerms, recipient());

    ERC20(asset()).safeApprove(address(ROUTER().TRANSFER_PROXY()), buyout);

    LienToken lienToken = LienToken(address(ROUTER().LIEN_TOKEN()));

    if (
      recipient() != address(this) &&
      !lienToken.isApprovedForAll(address(this), recipient())
    ) {
      lienToken.setApprovalForAll(recipient(), true);
    }

    return
      lienToken.buyoutLien(
        ILienToken.LienActionBuyout({
          incoming: incomingTerms,
          position: position,
          encumber: ILienToken.LienActionEncumber({
            collateralId: collateralId,
            amount: owed,
            receiver: recipient(),
            lien: ROUTER().validateCommitment({
              commitment: incomingTerms,
              timeToSecondEpochEnd: _timeToSecondEndIfPublic()
            }),
            stack: stack
          })
        })
      );
  }

  function _timeToSecondEndIfPublic()
    internal
    view
    virtual
    returns (uint256 timeToSecondEpochEnd)
  {
    return 0;
  }

  /**
   * @notice Retrieves the recipient of loan repayments. For PublicVaults (VAULT_TYPE 2), this is always the vault address. For PrivateVaults, retrieves the owner() of the vault.
   * @return The address of the recipient.
   */
  function recipient() public view returns (address) {
    if (IMPL_TYPE() == uint8(IAstariaRouter.ImplementationType.PublicVault)) {
      return address(this);
    } else {
      return owner();
    }
  }

  /**
   * @dev Generates a Lien for a valid loan commitment proof and sends the loan amount to the borrower.
   * @param c The Commitment information containing the loan parameters and the merkle proof for the strategy supporting the requested loan.
   * @param receiver The borrower requesting the loan.
   */
  function _requestLienAndIssuePayout(
    IAstariaRouter.Commitment calldata c,
    address receiver
  )
    internal
    returns (
      uint256 newLienId,
      ILienToken.Stack[] memory stack,
      uint256 slope
    )
  {
    _validateCommitment(c, receiver);
    (newLienId, stack, slope) = ROUTER().requestLienPosition(c, recipient());
    uint256 payout = _handleProtocolFee(c.lienRequest.amount);
    ERC20(asset()).safeTransfer(receiver, payout);
  }

  function _handleProtocolFee(uint256 amount) internal returns (uint256) {
    address feeTo = ROUTER().feeTo();
    bool feeOn = feeTo != address(0);
    if (feeOn) {
      uint256 fee = ROUTER().getProtocolFee(amount);

      unchecked {
        amount -= fee;
      }
      ERC20(asset()).safeTransfer(feeTo, fee);
    }
    return amount;
  }
}
