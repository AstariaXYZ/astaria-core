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

import {IAuctionHouse} from "gpl/interfaces/IAuctionHouse.sol";
import {IVault, AstariaVaultBase} from "gpl/ERC4626-Cloned.sol";

import {CollateralLookup} from "./libraries/CollateralLookup.sol";

import {IAstariaRouter} from "./interfaces/IAstariaRouter.sol";
import {ICollateralToken} from "./interfaces/ICollateralToken.sol";
import {ILienBase, ILienToken} from "./interfaces/ILienToken.sol";
import {ILienToken} from "./interfaces/ILienToken.sol";

/**
 * @title VaultImplementation
 * @author androolloyd
 * @notice A base implementation for the minimal features of an Astaria Vault.
 */
abstract contract VaultImplementation is ERC721TokenReceiver, AstariaVaultBase {
  using SafeTransferLib for ERC20;
  using CollateralLookup for address;
  using FixedPointMathLib for uint256;

  address public delegate; //account connected to the daemon

  event NewLien(
    bytes32 strategyRoot,
    address tokenContract,
    uint256 tokenId,
    uint256 amount
  );

  event NewVault(address appraiser, address vault);

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

  /**
   * @dev hook to allow inheriting contracts to perform payout for strategist
   */
  function _handleStrategistInterestReward(uint256, uint256) internal virtual {}

  struct InitParams {
    address delegate;
  }

  function init(InitParams calldata params) external virtual {
    require(msg.sender == address(ROUTER()), "only router");

    if (params.delegate != address(0)) {
      delegate = params.delegate;
    }
  }

  modifier onlyOwner() {
    require(msg.sender == owner(), "only strategist");
    _;
  }

  function setDelegate(address delegate_) public onlyOwner {
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
  ) internal returns (IAstariaRouter.LienDetails memory) {
    uint256 collateralId = params.tokenContract.computeId(params.tokenId);

    address operator = ERC721(COLLATERAL_TOKEN()).getApproved(collateralId);

    address holder = ERC721(COLLATERAL_TOKEN()).ownerOf(collateralId);

    if (msg.sender != holder) {
      require(msg.sender == operator, "invalid request");
    }

    if (receiver != holder) {
      require(
        receiver == operator || IAstariaRouter(ROUTER()).isValidVault(receiver),
        "can only issue funds to an vault or operator if not the holder"
      );
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
    require(
      recovered == params.lienRequest.strategy.strategist,
      "strategist must match signature"
    );
    require(
      recovered == owner() || recovered == delegate,
      "invalid strategist"
    );

    (bool valid, IAstariaRouter.LienDetails memory ld) = IAstariaRouter(
      ROUTER()
    ).validateCommitment(params);

    require(
      valid,
      "Vault._validateCommitment(): Verification of provided merkle branch failed for the vault and parameters"
    );

    require(
      ld.rate > 0,
      "Vault._validateCommitment(): Cannot have a 0 interest rate"
    );

    require(
      ld.rate < IAstariaRouter(ROUTER()).maxInterestRate(),
      "Vault._validateCommitment(): Rate is above maximum"
    );

    require(
      ld.maxAmount >= params.lienRequest.amount,
      "Vault._validateCommitment(): Attempting to borrow more than maxAmount available for this asset"
    );

    uint256 seniorDebt = IAstariaRouter(ROUTER())
      .LIEN_TOKEN()
      .getTotalDebtForCollateralToken(
        params.tokenContract.computeId(params.tokenId)
      );
    require(
      params.lienRequest.amount <= ERC20(underlying()).balanceOf(address(this)),
      "Vault._validateCommitment():  Attempting to borrow more than available in the specified vault"
    );

    uint256 potentialDebt = seniorDebt * (ld.rate + 1) * ld.duration;
    require(
      potentialDebt <= ld.maxPotentialDebt,
      "Vault._validateCommitment(): Attempting to initiate a loan with debt potentially higher than maxPotentialDebt"
    );

    return ld;
  }

  function _afterCommitToLien(uint256 lienId, uint256 amount)
    internal
    virtual
  {}

  /**
   * @notice Pipeline for lifecycle of new loan origination.
   * Origination consists of a few phases: pre-commitment validation, lien token issuance, strategist reward, and after commitment actions
   * Starts by depositing collateral and take out a lien against it. Next, verifies the merkle proof for a loan commitment. Vault owners are then rewarded fees for successful loan origination.
   * @param params Commitment data for the incoming lien request
   * @param receiver The borrower receiving the loan.
   */
  function commitToLien(
    IAstariaRouter.Commitment calldata params,
    address receiver
  ) external whenNotPaused {
    IAstariaRouter.LienDetails memory ld = _validateCommitment(
      params,
      receiver
    );
    uint256 lienId = _requestLienAndIssuePayout(ld, params, receiver);
    _afterCommitToLien(lienId, params.lienRequest.amount);
    emit NewLien(
      params.lienRequest.merkle.root,
      params.tokenContract,
      params.tokenId,
      params.lienRequest.amount
    );
  }

  /**
   * @notice Returns whether a specific lien can be liquidated.
   * @param collateralId The ID of the underlying CollateralToken.
   * @param position The specified lien position.
   * @return A boolean value indicating whether the specified lien can be liquidated.
   */
  function canLiquidate(uint256 collateralId, uint256 position)
    public
    view
    returns (bool)
  {
    return IAstariaRouter(ROUTER()).canLiquidate(collateralId, position);
  }

  /**
   * @notice Buy out a lien to replace it with new terms.
   * @param collateralId The ID of the underlying CollateralToken.
   * @param position The position of the specified lien.
   * @param incomingTerms The loan terms of the new lien.
   */
  function buyoutLien(
    uint256 collateralId,
    uint256 position,
    IAstariaRouter.Commitment calldata incomingTerms
  ) external whenNotPaused {
    (, uint256 buyout) = IAstariaRouter(ROUTER()).LIEN_TOKEN().getBuyout(
      collateralId,
      position
    );

    require(
      buyout <= ERC20(underlying()).balanceOf(address(this)),
      "not enough balance to buy out loan"
    );

    _validateCommitment(incomingTerms, recipient());

    ERC20(underlying()).safeApprove(
      address(IAstariaRouter(ROUTER()).TRANSFER_PROXY()),
      buyout
    );
    IAstariaRouter(ROUTER()).LIEN_TOKEN().buyoutLien(
      ILienBase.LienActionBuyout(incomingTerms, position, recipient())
    );
  }

  /**
   * @notice Retrieves the recipient of loan repayments. For PublicVaults (VAULT_TYPE 2), this is always the vault address. For PrivateVaults, retrieves the owner() of the vault.
   * @return The address of the recipient.
   */
  function recipient() public view returns (address) {
    if (VAULT_TYPE() == uint8(IAstariaRouter.VaultType.PUBLIC)) {
      return address(this);
    } else {
      return owner();
    }
  }

  /**
   * @dev Generates a Lien for a valid loan commitment proof and sends the loan amount to the borrower.
   * @param c The Commitment information containing the loan parameters and the merkle proof for the strategy supporting the requested loan.
   * @param receiver The borrower requesting the loan.
   * @return The ID of the created Lien.
   */
  function _requestLienAndIssuePayout(
    IAstariaRouter.LienDetails memory ld,
    IAstariaRouter.Commitment calldata c,
    address receiver
  ) internal returns (uint256) {
    uint256 newLienId = IAstariaRouter(ROUTER()).requestLienPosition(ld, c);

    uint256 payout = _handleProtocolFee(c.lienRequest.amount);
    ERC20(underlying()).safeTransfer(receiver, payout);
    return newLienId;
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
