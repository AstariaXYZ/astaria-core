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
import {ERC721} from "solmate/tokens/ERC721.sol";
import {ITransferProxy} from "core/interfaces/ITransferProxy.sol";
import {SafeCastLib} from "gpl/utils/SafeCastLib.sol";

import {
  ClonesWithImmutableArgs
} from "clones-with-immutable-args/ClonesWithImmutableArgs.sol";

import {CollateralLookup} from "core/libraries/CollateralLookup.sol";

import {IAstariaRouter} from "core/interfaces/IAstariaRouter.sol";
import {ICollateralToken} from "core/interfaces/ICollateralToken.sol";
import {ILienToken} from "core/interfaces/ILienToken.sol";
import {IVaultImplementation} from "core/interfaces/IVaultImplementation.sol";
import {IStrategyValidator} from "core/interfaces/IStrategyValidator.sol";

import {IVaultImplementation} from "core/interfaces/IVaultImplementation.sol";

import {MerkleProofLib} from "core/utils/MerkleProofLib.sol";
import {Pausable} from "core/utils/Pausable.sol";
import {IERC4626} from "core/interfaces/IERC4626.sol";
import {ERC4626Router} from "gpl/ERC4626Router.sol";
import {ERC4626RouterBase} from "gpl/ERC4626RouterBase.sol";
import {IERC4626} from "core/interfaces/IERC4626.sol";
import {IPublicVault} from "core/interfaces/IPublicVault.sol";
import {OrderParameters} from "seaport/lib/ConsiderationStructs.sol";

/**
 * @title AstariaRouter
 * @notice This contract manages the deployment of Vaults and universal Astaria actions.
 */
contract AstariaRouter is Auth, ERC4626Router, Pausable, IAstariaRouter {
  using SafeTransferLib for ERC20;
  using SafeCastLib for uint256;
  using CollateralLookup for address;
  using FixedPointMathLib for uint256;

  uint256 constant ROUTER_SLOT =
    0xb5d37468eefb1c75507259f9212a7d55dca0c7d08d9ef7be1cda5c5103eaa88e;

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
    address _WITHDRAW_IMPL,
    address _BEACON_PROXY_IMPL,
    address _CLEARING_HOUSE_IMPL
  ) Auth(address(msg.sender), _AUTHORITY) {
    RouterStorage storage s = _loadRouterSlot();

    s.WETH = ERC20(_WETH);
    s.COLLATERAL_TOKEN = _COLLATERAL_TOKEN;
    s.LIEN_TOKEN = _LIEN_TOKEN;
    s.TRANSFER_PROXY = _TRANSFER_PROXY;
    s.implementations[uint8(ImplementationType.PrivateVault)] = _SOLO_IMPL;
    s.implementations[uint8(ImplementationType.PublicVault)] = _VAULT_IMPL;
    s.implementations[uint8(ImplementationType.WithdrawProxy)] = _WITHDRAW_IMPL;
    s.implementations[
      uint8(ImplementationType.ClearingHouse)
    ] = _CLEARING_HOUSE_IMPL;
    s.BEACON_PROXY_IMPLEMENTATION = _BEACON_PROXY_IMPL;
    s.auctionWindow = uint32(2 days);
    s.auctionWindowBuffer = uint32(1 days);

    s.liquidationFeeNumerator = uint32(130);
    s.liquidationFeeDenominator = uint32(1000);
    s.minInterestBPS = uint32((uint256(1e15) * 5) / (365 days));
    s.minEpochLength = uint32(7 days);
    s.maxEpochLength = uint32(45 days);
    s.maxInterestRate = ((uint256(1e16) * 200) / (365 days)).safeCastTo88();
    //63419583966; // 200% apy / second
    s.strategistFeeNumerator = uint32(200);
    s.strategistFeeDenominator = uint32(1000);
    s.buyoutFeeNumerator = uint32(100);
    s.buyoutFeeDenominator = uint32(1000);
    s.minDurationIncrease = uint32(5 days);
    s.guardian = address(msg.sender);
  }

  function redeemFutureEpoch(
    IPublicVault vault,
    uint256 shares,
    address receiver,
    uint64 epoch
  ) public virtual returns (uint256 assets) {
    pullToken(address(vault), shares, address(this));
    ERC20(address(vault)).safeApprove(address(vault), shares);
    vault.redeemFutureEpoch(shares, receiver, msg.sender, epoch);
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
    assembly {
      rs.slot := ROUTER_SLOT
    }
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

  function fileBatch(File[] calldata files) external requiresAuth {
    for (uint256 i = 0; i < files.length; i++) {
      file(files[i]);
    }
  }

  function file(File calldata incoming) public requiresAuth {
    RouterStorage storage s = _loadRouterSlot();
    FileType what = incoming.what;
    bytes memory data = incoming.data;
    if (what == FileType.AuctionWindow) {
      (uint256 window, uint256 windowBuffer) = abi.decode(
        data,
        (uint256, uint256)
      );
      s.auctionWindow = window.safeCastTo32();
      s.auctionWindowBuffer = windowBuffer.safeCastTo32();
    } else if (what == FileType.LiquidationFee) {
      (uint256 numerator, uint256 denominator) = abi.decode(
        data,
        (uint256, uint256)
      );
      s.liquidationFeeNumerator = numerator.safeCastTo32();
      s.liquidationFeeDenominator = denominator.safeCastTo32();
    } else if (what == FileType.StrategistFee) {
      (uint256 numerator, uint256 denominator) = abi.decode(
        data,
        (uint256, uint256)
      );
      s.strategistFeeNumerator = numerator.safeCastTo32();
      s.strategistFeeDenominator = denominator.safeCastTo32();
    } else if (what == FileType.ProtocolFee) {
      (uint256 numerator, uint256 denominator) = abi.decode(
        data,
        (uint256, uint256)
      );
      s.protocolFeeNumerator = numerator.safeCastTo32();
      s.protocolFeeDenominator = denominator.safeCastTo32();
    } else if (what == FileType.BuyoutFee) {
      (uint256 numerator, uint256 denominator) = abi.decode(
        data,
        (uint256, uint256)
      );
      s.buyoutFeeNumerator = numerator.safeCastTo32();
      s.buyoutFeeDenominator = denominator.safeCastTo32();
    } else if (what == FileType.MinInterestBPS) {
      uint256 value = abi.decode(data, (uint256));
      s.minInterestBPS = value.safeCastTo32();
    } else if (what == FileType.MinDurationIncrease) {
      uint256 value = abi.decode(data, (uint256));
      s.minDurationIncrease = value.safeCastTo32();
    } else if (what == FileType.MinEpochLength) {
      s.minEpochLength = abi.decode(data, (uint256)).safeCastTo32();
    } else if (what == FileType.MaxEpochLength) {
      s.maxEpochLength = abi.decode(data, (uint256)).safeCastTo32();
    } else if (what == FileType.MaxInterestRate) {
      s.maxInterestRate = abi.decode(data, (uint256)).safeCastTo48();
    } else if (what == FileType.MinInterestRate) {
      s.maxInterestRate = abi.decode(data, (uint256)).safeCastTo48();
    } else if (what == FileType.FeeTo) {
      address addr = abi.decode(data, (address));
      s.feeTo = addr;
    } else if (what == FileType.StrategyValidator) {
      (uint8 TYPE, address addr) = abi.decode(data, (uint8, address));
      s.strategyValidators[TYPE] = addr;
    } else {
      revert UnsupportedFile();
    }

    emit FileUpdated(what, data);
  }

  function setNewGuardian(address _guardian) external {
    RouterStorage storage s = _loadRouterSlot();
    require(address(msg.sender) == s.guardian);
    s.guardian = _guardian;
  }

  function fileGuardian(File[] calldata file) external {
    RouterStorage storage s = _loadRouterSlot();
    require(address(msg.sender) == address(s.guardian));
    //only the guardian can call this
    for (uint256 i = 0; i < file.length; i++) {
      FileType what = file[i].what;
      bytes memory data = file[i].data;
      if (what == FileType.Implementation) {
        (uint8 implType, address addr) = abi.decode(data, (uint8, address));
        s.implementations[implType] = addr;
      } else if (what == FileType.CollateralToken) {
        address addr = abi.decode(data, (address));
        s.COLLATERAL_TOKEN = ICollateralToken(addr);
      } else if (what == FileType.LienToken) {
        address addr = abi.decode(data, (address));
        s.LIEN_TOKEN = ILienToken(addr);
      } else if (what == FileType.TransferProxy) {
        address addr = abi.decode(data, (address));
        s.TRANSFER_PROXY = ITransferProxy(addr);
      } else {
        revert UnsupportedFile();
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

  function getAuctionWindow(bool includeBuffer) public view returns (uint256) {
    RouterStorage storage s = _loadRouterSlot();
    return s.auctionWindow + (includeBuffer ? s.auctionWindowBuffer : 0);
  }

  function _sliceUint(bytes memory bs, uint256 start)
    internal
    pure
    returns (uint256)
  {
    require(bs.length >= start + 32);
    uint256 x;
    assembly {
      x := mload(add(bs, add(0x20, start)))
    }
    return x;
  }

  function validateCommitment(
    IAstariaRouter.Commitment calldata commitment,
    uint256 timeToSecondEpochEnd
  ) public view returns (ILienToken.Lien memory lien) {
    return
      _validateCommitment(_loadRouterSlot(), commitment, timeToSecondEpochEnd);
  }

  function _validateCommitment(
    RouterStorage storage s,
    IAstariaRouter.Commitment calldata commitment,
    uint256 timeToSecondEpochEnd
  ) internal view returns (ILienToken.Lien memory lien) {
    if (block.timestamp > commitment.lienRequest.strategy.deadline) {
      revert InvalidCommitmentState(CommitmentState.EXPIRED);
    }
    uint8 nlrType = uint8(_sliceUint(commitment.lienRequest.nlrDetails, 0));
    if (s.strategyValidators[nlrType] == address(0)) {
      revert InvalidStrategy(nlrType);
    }
    (bytes32 leaf, ILienToken.Details memory details) = IStrategyValidator(
      s.strategyValidators[nlrType]
    ).validateAndParse(
        commitment.lienRequest,
        s.COLLATERAL_TOKEN.ownerOf(
          commitment.tokenContract.computeId(commitment.tokenId)
        ),
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
        commitment.lienRequest.merkle.proof,
        commitment.lienRequest.merkle.root,
        leaf
      )
    ) {
      revert InvalidCommitmentState(CommitmentState.INVALID);
    }

    if (timeToSecondEpochEnd > 0 && details.duration > timeToSecondEpochEnd) {
      details.duration = timeToSecondEpochEnd;
    }

    lien = ILienToken.Lien({
      details: details,
      strategyRoot: commitment.lienRequest.merkle.root,
      collateralId: commitment.tokenContract.computeId(commitment.tokenId),
      vault: commitment.lienRequest.strategy.vault,
      token: address(s.WETH)
    });
  }

  //todo fix this //return from _executeCommitment is a stack array, this needs to be a multi dimension stack to support updates to many tokens at once
  function commitToLiens(IAstariaRouter.Commitment[] memory commitments)
    public
    whenNotPaused
    returns (uint256[] memory lienIds, ILienToken.Stack[] memory stack)
  {
    RouterStorage storage s = _loadRouterSlot();

    uint256 totalBorrowed;
    lienIds = new uint256[](commitments.length);
    _transferAndDepositAssetIfAble(
      s,
      commitments[0].tokenContract,
      commitments[0].tokenId
    );
    for (uint256 i; i < commitments.length; ) {
      if (i != 0) {
        commitments[i].lienRequest.stack = stack;
      }
      (lienIds[i], stack) = _executeCommitment(s, commitments[i]);
      totalBorrowed += commitments[i].lienRequest.amount;
      unchecked {
        ++i;
      }
    }
    s.WETH.safeApprove(address(s.TRANSFER_PROXY), totalBorrowed);

    s.TRANSFER_PROXY.tokenTransferFrom(
      address(s.WETH),
      address(this),
      address(msg.sender),
      totalBorrowed
    );
  }

  function newVault(address delegate) external whenNotPaused returns (address) {
    address[] memory allowList = new address[](2);
    allowList[0] = address(msg.sender);
    allowList[1] = delegate;
    RouterStorage storage s = _loadRouterSlot();

    return
      _newVault(
        s,
        uint256(0),
        delegate,
        uint256(0),
        true,
        allowList,
        uint256(0)
      );
  }

  function newPublicVault(
    uint256 epochLength,
    address delegate,
    uint256 vaultFee,
    bool allowListEnabled,
    address[] calldata allowList,
    uint256 depositCap
  ) public whenNotPaused returns (address) {
    RouterStorage storage s = _loadRouterSlot();
    if (s.minEpochLength > epochLength) {
      revert IPublicVault.InvalidState(
        IPublicVault.InvalidStates.EPOCH_TOO_LOW
      );
    }
    if (s.maxEpochLength < epochLength) {
      revert IPublicVault.InvalidState(
        IPublicVault.InvalidStates.EPOCH_TOO_HIGH
      );
    }
    return
      _newVault(
        s,
        epochLength,
        delegate,
        vaultFee,
        allowListEnabled,
        allowList,
        depositCap
      );
  }

  function requestLienPosition(
    IAstariaRouter.Commitment calldata params,
    address receiver
  )
    external
    whenNotPaused
    onlyVaults
    returns (
      uint256,
      ILienToken.Stack[] memory,
      uint256
    )
  {
    RouterStorage storage s = _loadRouterSlot();

    return
      s.LIEN_TOKEN.createLien(
        ILienToken.LienActionEncumber({
          collateralId: params.tokenContract.computeId(params.tokenId),
          lien: _validateCommitment({
            s: s,
            commitment: params,
            timeToSecondEpochEnd: IPublicVault(msg.sender).supportsInterface(
              type(IPublicVault).interfaceId
            )
              ? IPublicVault(msg.sender).timeToSecondEpochEnd()
              : 0
          }),
          amount: params.lienRequest.amount,
          stack: params.lienRequest.stack,
          receiver: receiver
        })
      );
  }

  function canLiquidate(ILienToken.Stack memory stack)
    public
    view
    returns (bool)
  {
    RouterStorage storage s = _loadRouterSlot();
    return (stack.point.end <= block.timestamp ||
      msg.sender == s.COLLATERAL_TOKEN.ownerOf(stack.lien.collateralId));
  }

  function liquidate(ILienToken.Stack[] memory stack, uint8 position)
    public
    returns (OrderParameters memory listedOrder)
  {
    if (!canLiquidate(stack[position])) {
      revert InvalidLienState(LienState.HEALTHY);
    }

    RouterStorage storage s = _loadRouterSlot();
    uint256 auctionWindowMax = s.auctionWindow + s.auctionWindowBuffer;

    s.LIEN_TOKEN.stopLiens(
      stack[position].lien.collateralId,
      auctionWindowMax,
      stack,
      msg.sender
    );
    emit Liquidation(stack[position].lien.collateralId, position);
    listedOrder = s.COLLATERAL_TOKEN.auctionVault(
      ICollateralToken.AuctionVaultParams({
        settlementToken: address(s.WETH),
        collateralId: stack[position].lien.collateralId,
        maxDuration: uint256(s.auctionWindow + s.auctionWindowBuffer),
        startingPrice: stack[0].lien.details.liquidationInitialAsk,
        endingPrice: 1_000 wei
      })
    );
  }

  function getStrategistFee(uint256 amountIn) external view returns (uint256) {
    RouterStorage storage s = _loadRouterSlot();
    return
      amountIn.mulDivDown(s.strategistFeeNumerator, s.strategistFeeDenominator);
  }

  function getProtocolFee(uint256 amountIn) external view returns (uint256) {
    RouterStorage storage s = _loadRouterSlot();

    return
      amountIn.mulDivDown(s.protocolFeeNumerator, s.protocolFeeDenominator);
  }

  function getLiquidatorFee(uint256 amountIn) external view returns (uint256) {
    RouterStorage storage s = _loadRouterSlot();

    return
      amountIn.mulDivDown(
        s.liquidationFeeNumerator,
        s.liquidationFeeDenominator
      );
  }

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
   * @notice Returns whether a given address is that of a Vault.
   * @param vault The Vault address.
   * @return A boolean representing whether the address exists as a Vault.
   */
  function isValidVault(address vault) public view returns (bool) {
    return _loadRouterSlot().vaults[vault] != address(0);
  }

  function isValidRefinance(
    ILienToken.Lien calldata newLien,
    uint8 position,
    ILienToken.Stack[] calldata stack
  ) public view returns (bool) {
    RouterStorage storage s = _loadRouterSlot();
    uint256 maxNewRate = uint256(stack[position].lien.details.rate) -
      s.minInterestBPS;

    if (newLien.collateralId != stack[0].lien.collateralId) {
      revert InvalidRefinanceCollateral(newLien.collateralId);
    }
    return
      (newLien.details.rate < maxNewRate &&
        newLien.details.duration + block.timestamp >=
        stack[position].point.end) ||
      (block.timestamp + newLien.details.duration - stack[position].point.end >=
        s.minDurationIncrease &&
        newLien.details.rate <= stack[position].lien.details.rate);
  }

  /**
   * @dev Deploys a new Vault.
   * @param epochLength The length of each epoch for a new PublicVault. If 0, deploys a PrivateVault.
   * @param delegate The address of the Vault delegate.
   * @param allowListEnabled Whether or not the Vault has an LP whitelist.
   * @return vaultAddr The address for the new Vault.
   */
  function _newVault(
    RouterStorage storage s,
    uint256 epochLength,
    address delegate,
    uint256 vaultFee,
    bool allowListEnabled,
    address[] memory allowList,
    uint256 depositCap
  ) internal returns (address vaultAddr) {
    uint8 vaultType;

    if (epochLength > uint256(0)) {
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
    IVaultImplementation(vaultAddr).init(
      IVaultImplementation.InitParams({
        delegate: delegate,
        allowListEnabled: allowListEnabled,
        allowList: allowList,
        depositCap: depositCap
      })
    );

    s.vaults[vaultAddr] = msg.sender;

    emit NewVault(msg.sender, delegate, vaultAddr, vaultType);

    return vaultAddr;
  }

  function _executeCommitment(
    RouterStorage storage s,
    IAstariaRouter.Commitment memory c
  ) internal returns (uint256, ILienToken.Stack[] memory stack) {
    uint256 collateralId = c.tokenContract.computeId(c.tokenId);

    if (msg.sender != s.COLLATERAL_TOKEN.ownerOf(collateralId)) {
      revert InvalidSenderForCollateral(msg.sender, collateralId);
    }
    if (s.vaults[c.lienRequest.strategy.vault] == address(0)) {
      revert InvalidVault();
    }
    //router must be approved for the collateral to take a loan,
    return
      IVaultImplementation(c.lienRequest.strategy.vault).commitToLien(
        c,
        address(this)
      );
  }

  function _transferAndDepositAssetIfAble(
    RouterStorage storage s,
    address tokenContract,
    uint256 tokenId
  ) internal {
    ERC721 token = ERC721(tokenContract);
    if (token.ownerOf(tokenId) == address(msg.sender)) {
      token.safeTransferFrom(
        address(msg.sender),
        address(s.COLLATERAL_TOKEN),
        tokenId,
        ""
      );
    }
  }
}
