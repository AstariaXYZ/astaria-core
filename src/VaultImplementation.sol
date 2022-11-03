// SPDX-License-Identifier: UNLICENSED

/**
 *       __  ___       __
 *  /\  /__'  |   /\  |__) |  /\
 * /~~\ .__/  |  /~~\ |  \ | /~~\
 *
 * Copyright (c) Astaria Labs, Inc
 */

pragma solidity ^0.8.17;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {ERC721, ERC721TokenReceiver} from "solmate/tokens/ERC721.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {SafeCastLib} from "gpl/utils/SafeCastLib.sol";
import {CollateralLookup} from "core/libraries/CollateralLookup.sol";

import {IAuctionHouse} from "gpl/interfaces/IAuctionHouse.sol";
import {IAstariaRouter} from "core/interfaces/IAstariaRouter.sol";
import {ILienToken} from "core/interfaces/ILienToken.sol";
import {IVault} from "core/interfaces/IVault.sol";
import {IVaultImplementation} from "core/interfaces/IVaultImplementation.sol";

import {AstariaVaultBase} from "core/AstariaVaultBase.sol";
import {LienToken} from "core/LienToken.sol";

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

  bytes32 constant VI_SLOT =
    keccak256("xyz.astaria.core.VaultImplementation.storage.location");
  address public delegate; //account connected to the daemon
  bool public allowListEnabled;
  uint256 public depositCap;

  struct VIData {
    address delegate;
    bool allowListEnabled;
    uint256 depositCap;
    mapping(address => bool) allowList;
  }

  mapping(address => bool) public allowList;
  event NewLien(
    bytes32 strategyRoot,
    address tokenContract,
    uint256 tokenId,
    uint256 amount
  );

  event NewVault(address appraiser, address vault);

  /**
   * @notice modify the deposit cap for the vault
   * @param newCap The deposit cap.
   */
  function modifyDepositCap(uint256 newCap) public onlyOwner {
    depositCap = newCap;
  }

  function _loadVISlot() internal pure returns (VIData storage vi) {
    bytes32 slot = VI_SLOT;
    assembly {
      vi.slot := slot
    }
  }

  /**
   * @notice modify the allowlist for the vault
   * @param depositor the depositor to modify
   * @param enabled the status of the depositor
   */
  function modifyAllowList(address depositor, bool enabled)
    external
    virtual
    onlyOwner
  {
    allowList[depositor] = enabled;
  }

  /**
   * @notice disable the allowlist for the vault
   */
  function disableAllowList() external virtual onlyOwner {
    allowListEnabled = false;
  }

  /**
   * @notice receive hook for ERC721 tokens, nothing special done
   */
  function onERC721Received(
    address operator_,
    address from_,
    uint256 tokenId_,
    bytes calldata data_
  ) external pure override returns (bytes4) {
    return ERC721TokenReceiver.onERC721Received.selector;
  }

  modifier whenNotPaused() {
    if (IAstariaRouter(ROUTER()).paused()) {
      revert("protocol is paused");
    }
    _;
  }

  function domainSeparator() public view virtual returns (bytes32) {
    return
      keccak256(
        abi.encode(
          keccak256(
            "EIP712Domain(string version,uint256 chainId,address verifyingContract)"
          ),
          keccak256("0"),
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

  // cast k "StrategyDetails(uint256 nonce,uint256 deadline,bytes32 root)"
  bytes32 private constant STRATEGY_TYPEHASH =
    0x679f3933bd13bd2e4ec6e9cde341ede07736ad7b635428a8a211e9cccb4393b0;

  function encodeStrategyData(
    IAstariaRouter.StrategyDetails calldata strategy,
    bytes32 root
  ) public view returns (bytes memory) {
    bytes32 hash = keccak256(
      abi.encode(
        STRATEGY_TYPEHASH,
        IAstariaRouter(ROUTER()).strategistNonce(strategy.strategist),
        strategy.deadline,
        root
      )
    );
    return
      abi.encodePacked(bytes1(0x19), bytes1(0x01), domainSeparator(), hash);
  }

  struct InitParams {
    address delegate;
    bool allowListEnabled;
    address[] allowList;
    uint256 depositCap; // max amount of tokens that can be deposited
  }

  function init(InitParams calldata params) external virtual {
    require(msg.sender == address(ROUTER()));
    VIData storage vi;
    bytes32 slot = VI_SLOT;
    assembly {
      vi.slot := slot
    }

    if (params.delegate != address(0)) {
      vi.delegate = params.delegate;
    }
    depositCap = params.depositCap;
    if (params.allowListEnabled) {
      vi.allowListEnabled = true;
      for (uint256 i = 0; i < params.allowList.length; i++) {
        vi.allowList[params.allowList[i]] = true;
      }
    }
  }

  modifier onlyOwner() {
    require(msg.sender == owner()); //owner is "strategist"
    _;
  }

  function setDelegate(address delegate_) public onlyOwner {
    allowList[delegate] = false;
    allowList[delegate_] = true;
    delegate = delegate_;
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
    if (
      params.lienRequest.amount > ERC20(underlying()).balanceOf(address(this))
    ) {
      revert InvalidRequest(InvalidRequestReason.INSUFFICIENT_FUNDS);
    }
    uint256 collateralId = params.tokenContract.computeId(params.tokenId);
    ERC721 CT = ERC721(address(COLLATERAL_TOKEN()));
    address operator = CT.getApproved(collateralId);

    address holder = ERC721(address(COLLATERAL_TOKEN())).ownerOf(collateralId);

    if (
      msg.sender != holder &&
      receiver != holder &&
      receiver != operator &&
      receiver != recipient() &&
      !IAstariaRouter(ROUTER()).isValidVault(receiver)
    ) {
      if (operator != address(0)) {
        require(operator == receiver);
      } else {
        require(CT.isApprovedForAll(holder, receiver));
      }
    }

    address recovered = ecrecover(
      keccak256(
        encodeStrategyData(
          params.lienRequest.strategy,
          params.lienRequest.merkle.root
        )
      ),
      params.lienRequest.v,
      params.lienRequest.r,
      params.lienRequest.s
    );
    if (recovered != params.lienRequest.strategy.strategist) {
      revert InvalidRequest(InvalidRequestReason.INVALID_SIGNATURE);
    }
    if (recovered != owner() && recovered != delegate) {
      revert InvalidRequest(InvalidRequestReason.INVALID_STRATEGIST);
    }
  }

  function _afterCommitToLien(
    uint40 end,
    uint256 lienId,
    uint256 amount,
    uint256 slope
  ) internal virtual {}

  function _beforeCommitToLien(
    IAstariaRouter.Commitment calldata,
    address receiver
  ) internal virtual {}

  /**
   * @notice Pipeline for lifecycle of new loan origination.
   * Origination consists of a few phases: pre-commitment validation, lien token issuance, strategist reward, and after commitment actions
   * Starts by depositing collateral and take out a lien against it. Next, verifies the merkle proof for a loan commitment. Vault owners are then rewarded fees for successful loan origination.
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
    _beforeCommitToLien(params, receiver);
    uint256 slopeAddition;
    (lienId, stack, slopeAddition) = _requestLienAndIssuePayout(
      params,
      receiver
    );
    _afterCommitToLien(
      stack[stack.length - 1].point.end,
      lienId,
      params.lienRequest.amount,
      slopeAddition
    );
    emit NewLien(
      params.lienRequest.merkle.root,
      params.tokenContract,
      params.tokenId,
      params.lienRequest.amount
    );
  }

  /**
   * @notice Buy out a lien to replace it with new terms.
   * @param collateralId The ID of the underlying CollateralToken.
   * @param position The position of the specified lien.
   * @param incomingTerms The loan terms of the new lien.
   */
  function buyoutLien(
    uint256 collateralId,
    uint8 position,
    IAstariaRouter.Commitment calldata incomingTerms,
    ILienToken.Stack[] calldata stack
  ) external whenNotPaused {
    (uint256 owed, uint256 buyout) = IAstariaRouter(ROUTER())
      .LIEN_TOKEN()
      .getBuyout(stack[position]);

    if (buyout > ERC20(underlying()).balanceOf(address(this))) {
      revert InvalidRequest(InvalidRequestReason.INSUFFICIENT_FUNDS);
    }

    _validateCommitment(incomingTerms, recipient());

    ERC20(underlying()).safeApprove(
      address(IAstariaRouter(ROUTER()).TRANSFER_PROXY()),
      buyout
    );

    LienToken lienToken = LienToken(
      address(IAstariaRouter(ROUTER()).LIEN_TOKEN())
    );

    if (
      recipient() != address(this) &&
      !lienToken.isApprovedForAll(address(this), recipient())
    ) {
      lienToken.setApprovalForAll(recipient(), true);
    }

    ILienToken.Lien memory newLien = ROUTER().validateCommitment(incomingTerms);

    lienToken.buyoutLien(
      ILienToken.LienActionBuyout({
        incoming: incomingTerms,
        position: position,
        encumber: ILienToken.LienActionEncumber({
          collateralId: collateralId,
          amount: incomingTerms.lienRequest.amount,
          receiver: recipient(),
          lien: newLien,
          stack: stack
        })
      })
    );
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
    (newLienId, stack, slope) = IAstariaRouter(ROUTER()).requestLienPosition(
      c,
      recipient()
    );

    uint256 payout = _handleProtocolFee(c.lienRequest.amount);
    ERC20(underlying()).safeTransfer(receiver, payout);
  }

  function _handleProtocolFee(uint256 amount) internal returns (uint256) {
    address feeTo = IAstariaRouter(ROUTER()).feeTo();
    bool feeOn = feeTo != address(0);
    if (feeOn) {
      uint256 fee = IAstariaRouter(ROUTER()).getProtocolFee(amount);

      unchecked {
        amount -= fee;
      }
      ERC20(underlying()).safeTransfer(feeTo, fee);
    }
    return amount;
  }
}
