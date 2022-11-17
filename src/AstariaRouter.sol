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

import {IAuctionHouse} from "gpl/interfaces/IAuctionHouse.sol";
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

/**
 * @title AstariaRouter
 * @notice This contract manages the deployment of Vaults and universal Astaria actions.
 */
contract AstariaRouter is Auth, ERC4626Router, Pausable, IAstariaRouter {
  using SafeTransferLib for ERC20;
  using SafeCastLib for uint256;
  using CollateralLookup for address;
  using FixedPointMathLib for uint256;

  bytes32 constant ROUTER_SLOT =
    keccak256("xyz.astaria.AstariaRouter.storage.location");

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
    address _BEACON_PROXY_IMPL
  ) Auth(address(msg.sender), _AUTHORITY) {
    RouterStorage storage s = _loadRouterSlot();

    s.WETH = ERC20(_WETH);
    s.COLLATERAL_TOKEN = _COLLATERAL_TOKEN;
    s.LIEN_TOKEN = _LIEN_TOKEN;
    s.TRANSFER_PROXY = _TRANSFER_PROXY;
    s.implementations[uint8(ImplementationType.PrivateVault)] = _SOLO_IMPL;
    s.implementations[uint8(ImplementationType.PublicVault)] = _VAULT_IMPL;
    s.implementations[uint8(ImplementationType.WithdrawProxy)] = _WITHDRAW_IMPL;
    s.BEACON_PROXY_IMPLEMENTATION = _BEACON_PROXY_IMPL;
    s.auctionWindow = uint32(2 days);
    s.auctionWindowBuffer = uint32(1 days);

    s.liquidationFeeNumerator = uint32(130);
    s.liquidationFeeDenominator = uint32(1000);
    s.minInterestBPS = uint32((uint256(1e15) * 5) / (365 days));
    s.minEpochLength = uint32(7 days);
    s.maxEpochLength = uint32(45 days);
    s.maxInterestRate = ((uint256(1e16) * 200) / (365 days)).safeCastTo88(); //63419583966; // 200% apy / second
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
    bytes32 slot = ROUTER_SLOT;
    assembly {
      rs.slot := slot
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

  function AUCTION_HOUSE() public view returns (IAuctionHouse) {
    RouterStorage storage s = _loadRouterSlot();
    return s.AUCTION_HOUSE;
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

  /* @notice specially guarded file
   * @param file incoming data to file
   */
  function fileGuardian(File[] calldata file) external {
    RouterStorage storage s = _loadRouterSlot();
    require(address(msg.sender) == address(s.guardian)); //only the guardian can call this
    for (uint256 i = 0; i < file.length; i++) {
      FileType what = file[i].what;
      bytes memory data = file[i].data;
      if (what == FileType.Implementation) {
        (uint8 implType, address addr) = abi.decode(data, (uint8, address));
        s.implementations[implType] = addr;
      } else if (what == FileType.AuctionHouse) {
        address addr = abi.decode(data, (address));
        s.AUCTION_HOUSE = IAuctionHouse(addr);
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

  function validateCommitment(IAstariaRouter.Commitment calldata commitment)
    external
    view
    returns (ILienToken.Lien memory lien)
  {
    return _validateCommitment(_loadRouterSlot(), commitment, 5 weeks);
  }

  function _validateCommitment(
    RouterStorage storage s,
    IAstariaRouter.Commitment calldata commitment,
    uint256 timeToSecondEpochEnd
  ) internal view returns (ILienToken.Lien memory lien) {
    if (block.timestamp > commitment.lienRequest.strategy.deadline) {
      revert InvalidCommitmentState(CommitmentState.EXPIRED);
    }

    uint256 strategyLength = 5;
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

    if (details.duration > timeToSecondEpochEnd) {
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
    external
    whenNotPaused
    returns (uint256[] memory lienIds, ILienToken.Stack[] memory stack)
  {
    RouterStorage storage s = _loadRouterSlot();

    uint256 totalBorrowed = 0;
    lienIds = new uint256[](commitments.length);
    _transferAndDepositAssetIfAble(
      s,
      commitments[0].tokenContract,
      commitments[0].tokenId
    );
    for (uint256 i = 0; i < commitments.length; ++i) {
      if (i != 0) {
        commitments[i].lienRequest.stack = stack;
      }
      (lienIds[i], stack) = _executeCommitment(s, commitments[i]);
      totalBorrowed += commitments[i].lienRequest.amount;
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

    return
      _newVault(uint256(0), delegate, uint256(0), true, allowList, uint256(0));
  }

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

    uint256 timeToSecondEpochEnd = 0;

    if(IPublicVault(msg.sender).supportsInterface(type(IPublicVault).interfaceId)) {
      timeToSecondEpochEnd = IPublicVault(msg.sender).timeToEpochEnd() + IPublicVault(msg.sender).EPOCH_LENGTH();
    }

    return
      s.LIEN_TOKEN.createLien(
        ILienToken.LienActionEncumber({
          collateralId: params.tokenContract.computeId(params.tokenId),
          lien: _validateCommitment(s, params, timeToSecondEpochEnd),
          amount: params.lienRequest.amount,
          stack: params.lienRequest.stack,
          receiver: receiver
        })
      );
  }

  /**
   * @notice Returns whether a specific lien can be liquidated.
   * @return A boolean value indicating whether the specified lien can be liquidated.
   */
  function canLiquidate(ILienToken.Stack memory stack)
    public
    view
    returns (bool)
  {
    RouterStorage storage s = _loadRouterSlot();
    return (stack.point.end <= block.timestamp ||
      msg.sender == s.COLLATERAL_TOKEN.ownerOf(stack.lien.collateralId));
  }

  function liquidate(
    uint256 collateralId,
    uint8 position,
    ILienToken.Stack[] memory stack
  ) external returns (uint256 reserve) {
    if (!canLiquidate(stack[position])) {
      revert InvalidLienState(LienState.HEALTHY);
    }

    RouterStorage storage s = _loadRouterSlot();
    uint256 auctionWindowMax = s.auctionWindow + s.auctionWindowBuffer;
    ILienToken.AuctionStack[]
      memory stackAtLiquidation = new ILienToken.AuctionStack[](stack.length);
    (reserve, stackAtLiquidation) = s.LIEN_TOKEN.stopLiens(
      collateralId,
      auctionWindowMax,
      stack
    );

    reserve += reserve.mulDivDown(
      s.liquidationFeeNumerator,
      s.liquidationFeeDenominator
    );

    s.AUCTION_HOUSE.createAuction(
      collateralId,
      s.auctionWindow,
      auctionWindowMax,
      msg.sender,
      s.liquidationFeeNumerator,
      s.liquidationFeeDenominator,
      reserve,
      stackAtLiquidation
    );

    uint256[] memory fees = new uint256[](2);
    fees[0] = s.liquidationFeeNumerator;
    fees[1] = s.liquidationFeeDenominator;

    emit Liquidation(collateralId, position, reserve, fees);
  }

  function cancelAuction(uint256 collateralId) external {
    RouterStorage storage s = _loadRouterSlot();

    require(msg.sender == s.COLLATERAL_TOKEN.ownerOf(collateralId));

    s.AUCTION_HOUSE.cancelAuction(collateralId, msg.sender);
    s.COLLATERAL_TOKEN.releaseToAddress(collateralId, msg.sender);
  }

  function endAuction(uint256 collateralId) external {
    RouterStorage storage s = _loadRouterSlot();

    if (!s.AUCTION_HOUSE.auctionExists(collateralId)) {
      revert InvalidCollateralState(CollateralStates.NO_AUCTION);
    }

    address winner = s.AUCTION_HOUSE.endAuction(collateralId);
    s.COLLATERAL_TOKEN.releaseToAddress(collateralId, winner);
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
   * @notice Returns whether a given address is that of a Vault.
   * @param vault The Vault address.
   * @return A boolean representing whether the address exists as a Vault.
   */
  function isValidVault(address vault) external view returns (bool) {
    return _loadRouterSlot().vaults[vault] != address(0);
  }

  /**
   * @notice Determines whether a potential refinance meets the minimum requirements for replacing a lien.
   * @param newLien The new Lien to replace the existing one.
   * @param newLien The new Lien to replace the existing one.
   * @return A boolean representing whether the potential refinance is valid.
   */
  function isValidRefinance(
    ILienToken.Lien calldata newLien,
    uint8 position,
    ILienToken.Stack[] calldata stack
  ) external view returns (bool) {
    RouterStorage storage s = _loadRouterSlot();
    uint256 minNewRate = uint256(stack[position].lien.details.rate) -
      s.minInterestBPS;

    return
      !((newLien.details.rate < minNewRate) ||
        (block.timestamp +
          newLien.details.duration -
          stack[position].point.end <
          s.minDurationIncrease));
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

  /**
   * @dev validates msg sender is owner
   * @param c The commitment Data
   * @return the amount borrowed
   */
  function _executeCommitment(
    RouterStorage storage s,
    IAstariaRouter.Commitment memory c
  ) internal returns (uint256, ILienToken.Stack[] memory stack) {
    uint256 collateralId = c.tokenContract.computeId(c.tokenId);

    if (msg.sender != s.COLLATERAL_TOKEN.ownerOf(collateralId)) {
      revert InvalidSenderForCollateral(msg.sender, collateralId);
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
      ERC721(tokenContract).safeTransferFrom(
        address(msg.sender),
        address(s.COLLATERAL_TOKEN),
        tokenId,
        ""
      );
    }
  }
}
