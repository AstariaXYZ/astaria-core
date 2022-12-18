// SPDX-License-Identifier: UNLICENSED

/**
 *       __  ___       __
 *  /\  /__'  |   /\  |__) |  /\
 * /~~\ .__/  |  /~~\ |  \ | /~~\
 *
 * Copyright (c) Astaria Labs, Inc
 */

pragma solidity =0.8.17;

import "forge-std/Test.sol";

import {Authority} from "solmate/auth/Auth.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {MockERC721} from "solmate/test/utils/mocks/MockERC721.sol";
import {
  MultiRolesAuthority
} from "solmate/auth/authorities/MultiRolesAuthority.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";

import {ERC721} from "gpl/ERC721.sol";
import {ITransferProxy} from "core/interfaces/ITransferProxy.sol";
import {SafeCastLib} from "gpl/utils/SafeCastLib.sol";

import {ICollateralToken} from "core/interfaces/ICollateralToken.sol";
import {IERC20} from "core/interfaces/IERC20.sol";
import {ILienToken} from "core/interfaces/ILienToken.sol";
import {IStrategyValidator} from "core/interfaces/IStrategyValidator.sol";
import {IRoyaltyEngine} from "core/interfaces/IRoyaltyEngine.sol";
import {CollateralLookup} from "core/libraries/CollateralLookup.sol";
import {
  ConduitControllerInterface
} from "seaport/interfaces/ConduitControllerInterface.sol";
import {
  ICollectionValidator,
  CollectionValidator
} from "../strategies/CollectionValidator.sol";
import {
  UNI_V3Validator,
  IUNI_V3Validator
} from "../strategies/UNI_V3Validator.sol";
import {
  UniqueValidator,
  IUniqueValidator
} from "../strategies/UniqueValidator.sol";
import {V3SecurityHook} from "../security/V3SecurityHook.sol";
import {CollateralToken} from "../CollateralToken.sol";
import {IAstariaRouter, AstariaRouter} from "../AstariaRouter.sol";
import {IPublicVault} from "core/interfaces/IPublicVault.sol";
import {VaultImplementation} from "../VaultImplementation.sol";
import {LienToken} from "../LienToken.sol";
import {TransferProxy} from "../TransferProxy.sol";
import {PublicVault} from "../PublicVault.sol";
import {Vault} from "../Vault.sol";
import {WithdrawProxy} from "../WithdrawProxy.sol";

import {Strings2} from "./utils/Strings2.sol";
import {BeaconProxy} from "../BeaconProxy.sol";
import {Bytes32AddressLib} from "solmate/utils/Bytes32AddressLib.sol";

import {IERC4626} from "core/interfaces/IERC4626.sol";
import {
  ConsiderationInterface
} from "seaport/interfaces/ConsiderationInterface.sol";
import {
  OrderParameters,
  OrderComponents,
  Order,
  CriteriaResolver,
  AdvancedOrder,
  OfferItem,
  ConsiderationItem,
  OrderType,
  Fulfillment,
  FulfillmentComponent
} from "seaport/lib/ConsiderationStructs.sol";
import {ClearingHouse} from "core/ClearingHouse.sol";
import {RoyaltyEngineMock} from "./utils/RoyaltyEngineMock.sol";
import {ConduitController} from "seaport/conduit/ConduitController.sol";
import {Conduit} from "seaport/conduit/Conduit.sol";
import {Consideration} from "seaport/lib/Consideration.sol";
string constant weth9Artifact = "src/test/WETH9.json";

interface IWETH9 is IERC20 {
  function deposit() external payable;

  function withdraw(uint256) external;
}

contract TestNFT is MockERC721 {
  constructor(uint256 size) MockERC721("TestNFT", "TestNFT") {
    for (uint256 i = 0; i < size; ++i) {
      _mint(msg.sender, i);
    }
  }
}
import {BaseOrderTest} from "lib/seaport/test/foundry/utils/BaseOrderTest.sol";

contract ConsiderationTester is BaseOrderTest {
  function _deployAndConfigureConsideration() public {
    conduitController = new ConduitController();
    consideration = new Consideration(address(conduitController));

    //create conduit, update channel
    conduit = Conduit(
      conduitController.createConduit(conduitKeyOne, address(this))
    );
    conduitController.updateChannel(
      address(conduit),
      address(consideration),
      true
    );
  }

  function setUp() public virtual override(BaseOrderTest) {
    conduitKeyOne = bytes32(uint256(uint160(address(this))) << 96);
    _deployAndConfigureConsideration();

    vm.label(address(conduitController), "conduitController");
    vm.label(address(consideration), "consideration");
    vm.label(address(conduit), "conduit");
    vm.label(address(this), "testContract");
  }
}

contract TestHelpers is ConsiderationTester {
  using CollateralLookup for address;
  using Strings2 for bytes;
  using SafeCastLib for uint256;
  using SafeTransferLib for ERC20;
  using FixedPointMathLib for uint256;
  uint256 strategistOnePK = uint256(0x1339);
  uint256 strategistTwoPK = uint256(0x1344); // strategistTwo is delegate for PublicVault created by strategistOne
  uint256 strategistRoguePK = uint256(0x1559); // strategist who doesn't have a vault
  address strategistOne = vm.addr(strategistOnePK);
  address strategistTwo = vm.addr(strategistTwoPK);
  address strategistRogue = vm.addr(strategistRoguePK);

  address borrower = vm.addr(0x1341);
  uint256 bidderPK = uint256(2566);
  uint256 bidderTwoPK = uint256(2567);
  address bidder = vm.addr(bidderPK);
  address bidderOne = vm.addr(0x1342);
  address bidderTwo = vm.addr(bidderTwoPK);

  string private checkpointLabel;
  uint256 private checkpointGasLeft = 1; // Start the slot warm.

  ILienToken.Details public blueChipDetails =
    ILienToken.Details({
      maxAmount: 150 ether,
      rate: (uint256(1e16) * 150) / (365 days),
      duration: 10 days,
      maxPotentialDebt: 0 ether,
      liquidationInitialAsk: 500 ether
    });
  ILienToken.Details public rogueBuyoutLien =
    ILienToken.Details({
      maxAmount: 50 ether,
      rate: (uint256(1e16) * 150) / (365 days),
      duration: 10 days,
      maxPotentialDebt: 50 ether,
      liquidationInitialAsk: 500 ether
    });
  ILienToken.Details public standardLienDetails =
    ILienToken.Details({
      maxAmount: 50 ether,
      rate: (uint256(1e16) * 150) / (365 days),
      duration: 10 days,
      maxPotentialDebt: 0 ether,
      liquidationInitialAsk: 500 ether
    });
  ILienToken.Details public standardLienDetails2 =
    ILienToken.Details({
      maxAmount: 50 ether,
      rate: (uint256(1e16) * 150) / (365 days),
      duration: 11 days,
      maxPotentialDebt: 0 ether,
      liquidationInitialAsk: 500 ether
    });

  ILienToken.Details public refinanceLienDetails =
    ILienToken.Details({
      maxAmount: 50 ether,
      rate: (uint256(1e16) * 150) / (365 days),
      duration: 25 days,
      maxPotentialDebt: 53 ether,
      liquidationInitialAsk: 500 ether
    });
  ILienToken.Details public refinanceLienDetails2 =
    ILienToken.Details({
      maxAmount: 50 ether,
      rate: (uint256(1e16) * 150) / (365 days),
      duration: 25 days,
      maxPotentialDebt: 52 ether,
      liquidationInitialAsk: 500 ether
    });

  ILienToken.Details public refinanceLienDetails3 =
    ILienToken.Details({
      maxAmount: 50 ether,
      rate: (uint256(1e16) * 150) / (365 days),
      duration: 25 days,
      maxPotentialDebt: 51 ether,
      liquidationInitialAsk: 500 ether
    });

  ILienToken.Details public refinanceLienDetails4 =
    ILienToken.Details({
      maxAmount: 50 ether,
      rate: (uint256(1e16) * 150) / (365 days),
      duration: 25 days,
      maxPotentialDebt: 55 ether,
      liquidationInitialAsk: 500 ether
    });

  enum UserRoles {
    ADMIN,
    ASTARIA_ROUTER,
    WRAPPER,
    AUCTION_HOUSE,
    TRANSFER_PROXY,
    LIEN_TOKEN,
    SEAPORT,
    AUCTION_VALIDATOR
  }

  enum StrategyTypes {
    STANDARD,
    COLLECTION,
    UNIV3_LIQUIDITY
  }

  struct Fees {
    uint256 opensea;
    uint256 royalties;
    uint256 liquidator;
    uint256 lender;
    uint256 borrower;
  }

  event NewTermCommitment(bytes32 vault, uint256 collateralId, uint256 amount);
  event Repayment(bytes32 vault, uint256 collateralId, uint256 amount);
  event Liquidation(bytes32 vault, uint256 collateralId);
  event NewVault(
    address strategist,
    bytes32 vault,
    bytes32 contentHash,
    uint256 expiration
  );
  event RedeemVault(bytes32 vault, uint256 amount, address indexed redeemer);
  mapping(uint256 => OrderParameters) seaportOrders;

  CollateralToken COLLATERAL_TOKEN;
  LienToken LIEN_TOKEN;
  AstariaRouter ASTARIA_ROUTER;
  PublicVault PUBLIC_VAULT;
  WithdrawProxy WITHDRAW_PROXY;
  Vault SOLO_VAULT;
  TransferProxy TRANSFER_PROXY;
  IWETH9 WETH9;
  MultiRolesAuthority MRA;
  ConsiderationInterface SEAPORT;

  address bidderConduit;
  bytes32 bidderConduitKey;

  function setUp() public virtual override {
    super.setUp();
    WETH9 = IWETH9(deployCode(weth9Artifact));
    vm.label(address(WETH9), "WETH9");
    MRA = new MultiRolesAuthority(address(this), Authority(address(0)));
    vm.label(address(MRA), "MRA");
    TRANSFER_PROXY = new TransferProxy(MRA);
    vm.label(address(TRANSFER_PROXY), "TRANSFER_PROXY");

    LIEN_TOKEN = new LienToken(MRA, TRANSFER_PROXY, address(WETH9));
    vm.label(address(LIEN_TOKEN), "LIEN_TOKEN");

    SEAPORT = ConsiderationInterface(address(consideration));

    RoyaltyEngineMock royaltyEngine = new RoyaltyEngineMock();
    IRoyaltyEngine ROYALTY_REGISTRY = IRoyaltyEngine(address(royaltyEngine));

    ClearingHouse CLEARING_HOUSE_IMPL = new ClearingHouse();
    COLLATERAL_TOKEN = new CollateralToken(
      MRA,
      TRANSFER_PROXY,
      ILienToken(address(LIEN_TOKEN)),
      SEAPORT,
      ROYALTY_REGISTRY
    );
    vm.label(address(COLLATERAL_TOKEN), "COLLATERAL_TOKEN");

    vm.label(COLLATERAL_TOKEN.getConduit(), "collateral conduit");

    PUBLIC_VAULT = new PublicVault();
    SOLO_VAULT = new Vault();
    WITHDRAW_PROXY = new WithdrawProxy();
    BeaconProxy BEACON_PROXY = new BeaconProxy();

    ASTARIA_ROUTER = new AstariaRouter(
      MRA,
      address(WETH9),
      ICollateralToken(address(COLLATERAL_TOKEN)),
      ILienToken(address(LIEN_TOKEN)),
      ITransferProxy(address(TRANSFER_PROXY)),
      address(PUBLIC_VAULT),
      address(SOLO_VAULT),
      address(WITHDRAW_PROXY),
      address(BEACON_PROXY),
      address(CLEARING_HOUSE_IMPL)
    );

    vm.label(address(ASTARIA_ROUTER), "ASTARIA_ROUTER");

    V3SecurityHook V3_SECURITY_HOOK = new V3SecurityHook(
      address(0xC36442b4a4522E871399CD717aBDD847Ab11FE88)
    );

    CollateralToken.File[] memory ctfiles = new CollateralToken.File[](2);

    ctfiles[0] = ICollateralToken.File({
      what: ICollateralToken.FileType.AstariaRouter,
      data: abi.encode(address(ASTARIA_ROUTER))
    });

    address UNI_V3_NFT = address(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);
    ctfiles[1] = ICollateralToken.File({
      what: ICollateralToken.FileType.SecurityHook,
      data: abi.encode(UNI_V3_NFT, address(V3_SECURITY_HOOK))
    });

    COLLATERAL_TOKEN.fileBatch(ctfiles);

    //strategy unique
    UniqueValidator UNIQUE_STRATEGY_VALIDATOR = new UniqueValidator();
    //strategy collection
    CollectionValidator COLLECTION_STRATEGY_VALIDATOR = new CollectionValidator();
    //strategy univ3
    UNI_V3Validator UNIV3_LIQUIDITY_STRATEGY_VALIDATOR = new UNI_V3Validator();

    IAstariaRouter.File[] memory files = new IAstariaRouter.File[](3);

    files[0] = IAstariaRouter.File(
      IAstariaRouter.FileType.StrategyValidator,
      abi.encode(uint8(1), address(UNIQUE_STRATEGY_VALIDATOR))
    );
    files[1] = IAstariaRouter.File(
      IAstariaRouter.FileType.StrategyValidator,
      abi.encode(uint8(2), address(COLLECTION_STRATEGY_VALIDATOR))
    );
    files[2] = IAstariaRouter.File(
      IAstariaRouter.FileType.StrategyValidator,
      abi.encode(uint8(3), address(UNIV3_LIQUIDITY_STRATEGY_VALIDATOR))
    );

    ASTARIA_ROUTER.fileBatch(files);

    LIEN_TOKEN.file(
      ILienToken.File(
        ILienToken.FileType.CollateralToken,
        abi.encode(address(COLLATERAL_TOKEN))
      )
    );
    LIEN_TOKEN.file(
      ILienToken.File(
        ILienToken.FileType.AstariaRouter,
        abi.encode(address(ASTARIA_ROUTER))
      )
    );

    _setupRolesAndCapabilities();
  }

  function _setupRolesAndCapabilities() internal {
    // ROUTER CAPABILITIES
    MRA.setRoleCapability(
      uint8(UserRoles.ASTARIA_ROUTER),
      LienToken.createLien.selector,
      true
    );
    MRA.setRoleCapability(
      uint8(UserRoles.ASTARIA_ROUTER),
      TRANSFER_PROXY.tokenTransferFrom.selector,
      true
    );

    MRA.setRoleCapability(
      uint8(UserRoles.ASTARIA_ROUTER),
      CollateralToken.auctionVault.selector,
      true
    );

    // LIEN TOKEN CAPABILITIES
    MRA.setRoleCapability(
      uint8(UserRoles.ASTARIA_ROUTER),
      LienToken.stopLiens.selector,
      true
    );

    MRA.setRoleCapability(
      uint8(UserRoles.LIEN_TOKEN),
      CollateralToken.settleAuction.selector,
      true
    );

    MRA.setRoleCapability(
      uint8(UserRoles.LIEN_TOKEN),
      TRANSFER_PROXY.tokenTransferFrom.selector,
      true
    );

    // SEAPORT CAPABILITIES

    MRA.setUserRole(
      address(ASTARIA_ROUTER),
      uint8(UserRoles.ASTARIA_ROUTER),
      true
    );
    MRA.setUserRole(address(COLLATERAL_TOKEN), uint8(UserRoles.WRAPPER), true);
    MRA.setUserRole(address(SEAPORT), uint8(UserRoles.SEAPORT), true);
    MRA.setUserRole(address(LIEN_TOKEN), uint8(UserRoles.LIEN_TOKEN), true);
  }

  function getAmountOwedToLender(
    uint256 rate,
    uint256 amount,
    uint256 duration
  ) public pure returns (uint256) {
    return
      amount +
      (rate * amount * duration).mulDivDown(1, 365 days).mulDivDown(1, 1e18);
  }

  function setupLiquidation(address borrower)
    public
    returns (address publicVault, ILienToken.Stack[] memory stack)
  {
    TestNFT nft = new TestNFT(0);
    _mintNoDepositApproveRouterSpecific(borrower, address(nft), 99);
    address tokenContract = address(nft);
    uint256 tokenId = uint256(99);

    // create a PublicVault with a 14-day epoch
    publicVault = _createPublicVault({
      strategist: strategistOne,
      delegate: strategistTwo,
      epochLength: 14 days
    });

    // lend 50 ether to the PublicVault as address(1)
    _lendToVault(
      Lender({addr: address(1), amountToLend: 50 ether}),
      publicVault
    );

    _signalWithdraw(address(1), publicVault);

    ILienToken.Details memory lien = standardLienDetails;
    lien.duration = 14 days;

    // borrow 10 eth against the dummy NFT
    vm.startPrank(borrower);
    (, stack) = _commitToLien({
      vault: publicVault,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: lien,
      amount: 50 ether,
      isFirstLien: true
    });
    vm.stopPrank();

    vm.warp(block.timestamp + lien.duration);
  }

  function getFeesForLiquidation(
    uint256 bid,
    uint256 openseaPercentage,
    uint256 royaltyPercentage,
    uint256 liquidatorPercentage,
    uint256 lenderAmountOwed
  ) public returns (Fees memory fees) {
    uint256 remainder = bid;
    fees = Fees({
      opensea: bid.mulDivDown(openseaPercentage, 1e18),
      royalties: bid.mulDivDown(royaltyPercentage, 1e18),
      liquidator: bid.mulDivDown(liquidatorPercentage, 1e18),
      lender: 0,
      borrower: 0
    });
    remainder -= fees.liquidator;
    if (remainder <= lenderAmountOwed) {
      fees.lender = remainder;
    } else {
      fees.lender = lenderAmountOwed;
    }
    remainder -= fees.lender;
    fees.borrower = remainder;
  }

  event FeesCalculated(Fees fees);

  function testFeesExample() public {
    uint256 amountOwedToLender = getAmountOwedToLender(15e17, 10e18, 14 days);
    Fees memory fees = getFeesForLiquidation(
      20e18,
      25e15,
      10e16,
      13e16,
      amountOwedToLender
    );
    emit FeesCalculated(fees);
  }

  // wrap NFT in a CollateralToken
  function _depositNFT(address tokenContract, uint256 tokenId) internal {
    ERC721(tokenContract).safeTransferFrom(
      address(this),
      address(COLLATERAL_TOKEN),
      uint256(tokenId),
      ""
    );
  }

  function _warpToEpochEnd(address vault) internal {
    //warps to the first second after the epoch end
    assertTrue(
      block.timestamp <
        PublicVault(vault).getEpochEnd(PublicVault(vault).getCurrentEpoch()) + 1
    );
    vm.warp(
      PublicVault(vault).getEpochEnd(PublicVault(vault).getCurrentEpoch()) + 1
    );
  }

  function _mintNoDepositApproveRouter(address tokenContract, uint256 tokenId)
    internal
  {
    TestNFT(tokenContract).mint(address(this), tokenId);
    TestNFT(tokenContract).approve(address(ASTARIA_ROUTER), tokenId);
  }

  function _mintNoDepositApproveRouterSpecific(
    address mintTo,
    address tokenContract,
    uint256 tokenId
  ) internal {
    TestNFT(tokenContract).mint(mintTo, tokenId);
    vm.startPrank(mintTo);
    TestNFT(tokenContract).approve(address(ASTARIA_ROUTER), tokenId);
    vm.stopPrank();
  }

  function _mintAndDeposit(address tokenContract, uint256 tokenId) internal {
    _mintAndDeposit(tokenContract, tokenId, address(this));
  }

  function _mintAndDeposit(
    address tokenContract,
    uint256 tokenId,
    address to
  ) internal {
    TestNFT(tokenContract).mint(address(this), tokenId);
    ERC721(tokenContract).safeTransferFrom(
      to,
      address(COLLATERAL_TOKEN),
      tokenId,
      ""
    );
  }

  function _createPrivateVault(address strategist, address delegate)
    internal
    returns (address privateVault)
  {
    vm.startPrank(strategist);
    privateVault = ASTARIA_ROUTER.newVault(delegate);
    vm.stopPrank();
  }

  function _createPublicVault(
    address strategist,
    address delegate,
    uint256 epochLength
  ) internal returns (address publicVault) {
    vm.startPrank(strategist);
    //bps
    publicVault = ASTARIA_ROUTER.newPublicVault(
      epochLength,
      delegate,
      uint256(0),
      false,
      new address[](0),
      uint256(0)
    );
    vm.stopPrank();
  }

  function _generateLoanMerkleProof2(
    IAstariaRouter.LienRequestType requestType,
    bytes memory data
  ) internal returns (bytes32 rootHash, bytes32[] memory merkleProof) {
    string[] memory inputs = new string[](4);
    inputs[0] = "node";
    inputs[1] = "./dist/loanProofGenerator.js";

    if (requestType == IAstariaRouter.LienRequestType.UNIQUE) {
      IUniqueValidator.Details memory terms = abi.decode(
        data,
        (IUniqueValidator.Details)
      );
      inputs[2] = abi.encodePacked(uint8(0)).toHexString(); //type
      inputs[3] = abi.encode(terms).toHexString();
    } else if (requestType == IAstariaRouter.LienRequestType.COLLECTION) {
      ICollectionValidator.Details memory terms = abi.decode(
        data,
        (ICollectionValidator.Details)
      );
      inputs[2] = abi.encodePacked(uint8(1)).toHexString(); //type
      inputs[3] = abi.encode(terms).toHexString();
    } else if (requestType == IAstariaRouter.LienRequestType.UNIV3_LIQUIDITY) {
      IUNI_V3Validator.Details memory terms = abi.decode(
        data,
        (IUNI_V3Validator.Details)
      );
      inputs[2] = abi.encodePacked(uint8(2)).toHexString(); //type
      inputs[3] = abi.encode(terms).toHexString();
    } else {
      revert("unsupported");
    }

    bytes memory res = vm.ffi(inputs);
    (rootHash, merkleProof) = abi.decode(res, (bytes32, bytes32[]));
  }

  function _commitToLien(
    address vault, // address of deployed Vault
    address strategist,
    uint256 strategistPK,
    address tokenContract, // original NFT address
    uint256 tokenId, // original NFT id
    ILienToken.Details memory lienDetails, // loan information
    uint256 amount, // requested amount
    bool isFirstLien
  ) internal returns (uint256[] memory, ILienToken.Stack[] memory stack) {
    return
      _commitToLien({
        vault: vault,
        strategist: strategist,
        strategistPK: strategistPK,
        tokenContract: tokenContract,
        tokenId: tokenId,
        lienDetails: lienDetails,
        amount: amount,
        isFirstLien: isFirstLien,
        stack: new ILienToken.Stack[](0),
        revertMessage: new bytes(0)
      });
  }

  function _executeCommitments(
    IAstariaRouter.Commitment[] memory commitments,
    bytes memory revertMessage
  )
    internal
    returns (uint256[] memory lienIds, ILienToken.Stack[] memory newStack)
  {
    COLLATERAL_TOKEN.setApprovalForAll(address(ASTARIA_ROUTER), true);
    if (revertMessage.length > 0) {
      vm.expectRevert(revertMessage);
    }
    return ASTARIA_ROUTER.commitToLiens(commitments);
  }

  struct V3LienParams {
    address strategist;
    uint256 strategistPK;
    address tokenContract;
    uint256 tokenId;
    address borrower;
    address[] assets;
    uint24 fee;
    int24 tickLower;
    int24 tickUpper;
    uint128 liquidity;
    uint256 amount0Min;
    uint256 amount1Min;
    ILienToken.Details details;
  }

  function _commitToV3Lien(
    V3LienParams memory params,
    address vault,
    uint256 amount,
    ILienToken.Stack[] memory stack,
    bool isFirstLien
  )
    internal
    returns (uint256[] memory lienIds, ILienToken.Stack[] memory newStack)
  {
    IAstariaRouter.Commitment memory terms = _generateValidV3Terms({
      params: params,
      amount: amount,
      vault: vault,
      stack: stack
    });

    if (isFirstLien) {
      ERC721(params.tokenContract).setApprovalForAll(
        address(ASTARIA_ROUTER),
        true
      );
    }
    IAstariaRouter.Commitment[]
      memory commitments = new IAstariaRouter.Commitment[](1);
    commitments[0] = terms;
    return
      _executeCommitments({
        commitments: commitments,
        revertMessage: new bytes(0)
      });
  }

  function _commitToLien(
    address vault, // address of deployed Vault
    address strategist,
    uint256 strategistPK,
    address tokenContract, // original NFT address
    uint256 tokenId, // original NFT id
    ILienToken.Details memory lienDetails, // loan information
    uint256 amount, // requested amount
    bool isFirstLien,
    ILienToken.Stack[] memory stack
  )
    internal
    returns (uint256[] memory lienIds, ILienToken.Stack[] memory newStack)
  {
    return
      _commitToLien({
        vault: vault,
        strategist: strategist,
        strategistPK: strategistPK,
        tokenContract: tokenContract,
        tokenId: tokenId,
        lienDetails: lienDetails,
        amount: amount,
        isFirstLien: isFirstLien,
        stack: stack,
        revertMessage: new bytes(0)
      });
  }

  function _commitToLien(
    address vault, // address of deployed Vault
    address strategist,
    uint256 strategistPK,
    address tokenContract, // original NFT address
    uint256 tokenId, // original NFT id
    ILienToken.Details memory lienDetails, // loan information
    uint256 amount, // requested amount
    bool isFirstLien,
    ILienToken.Stack[] memory stack,
    bytes memory revertMessage
  )
    internal
    returns (uint256[] memory lienIds, ILienToken.Stack[] memory newStack)
  {
    IAstariaRouter.Commitment memory terms = _generateValidTerms({
      vault: vault,
      strategist: strategist,
      strategistPK: strategistPK,
      tokenContract: tokenContract,
      tokenId: tokenId,
      lienDetails: lienDetails,
      amount: amount,
      stack: stack
    });

    if (isFirstLien) {
      ERC721(tokenContract).setApprovalForAll(address(ASTARIA_ROUTER), true);
    }
    IAstariaRouter.Commitment[]
      memory commitments = new IAstariaRouter.Commitment[](1);
    commitments[0] = terms;
    return
      _executeCommitments({
        commitments: commitments,
        revertMessage: revertMessage
      });
  }

  function _generateEncodedStrategyData(
    address vault,
    uint256 deadline,
    bytes32 root
  ) internal view returns (bytes memory) {
    bytes32 hash = keccak256(
      abi.encode(
        VaultImplementation(vault).STRATEGY_TYPEHASH(),
        VaultImplementation(vault).getStrategistNonce(),
        deadline,
        root
      )
    );
    return
      abi.encodePacked(
        bytes1(0x19),
        bytes1(0x01),
        VaultImplementation(vault).domainSeparator(),
        hash
      );
  }

  function _generateValidV3Terms(
    V3LienParams memory params,
    uint256 amount, // requested amount
    address vault,
    ILienToken.Stack[] memory stack
  ) internal returns (IAstariaRouter.Commitment memory) {
    bytes memory validatorDetails = abi.encode(
      IUNI_V3Validator.Details({
        version: uint8(3),
        lp: params.tokenContract,
        token0: params.assets[0],
        token1: params.assets[1],
        fee: params.fee,
        tickLower: params.tickLower,
        tickUpper: params.tickUpper,
        amount0Min: params.amount0Min,
        amount1Min: params.amount1Min,
        minLiquidity: params.liquidity,
        borrower: params.borrower,
        lien: params.details
      })
    );

    (
      bytes32 rootHash,
      bytes32[] memory merkleProof
    ) = _generateLoanMerkleProof2({
        requestType: IAstariaRouter.LienRequestType.UNIV3_LIQUIDITY,
        data: validatorDetails
      });

    // setup 712 signature

    IAstariaRouter.StrategyDetailsParam memory strategyDetails = IAstariaRouter
      .StrategyDetailsParam({
        version: uint8(0),
        deadline: block.timestamp + 10 days,
        vault: vault
      });

    bytes32 termHash = keccak256(
      _generateEncodedStrategyData(vault, strategyDetails.deadline, rootHash)
    );
    return
      _generateTerms(
        GenTerms({
          nlrType: uint8(IAstariaRouter.LienRequestType.UNIV3_LIQUIDITY),
          tokenContract: params.tokenContract,
          tokenId: params.tokenId,
          termHash: termHash,
          rootHash: rootHash,
          pk: params.strategistPK,
          strategyDetails: strategyDetails,
          validatorDetails: validatorDetails,
          amount: amount,
          merkleProof: merkleProof,
          stack: stack
        })
      );
  }

  function _generateValidTerms(
    address vault, // address of deployed Vault
    address strategist,
    uint256 strategistPK,
    address tokenContract, // original NFT address
    uint256 tokenId, // original NFT id
    ILienToken.Details memory lienDetails, // loan information
    uint256 amount, // requested amount
    ILienToken.Stack[] memory stack
  ) internal returns (IAstariaRouter.Commitment memory) {
    bytes memory validatorDetails = abi.encode(
      IUniqueValidator.Details({
        version: uint8(1),
        token: tokenContract,
        tokenId: tokenId,
        borrower: address(0),
        lien: lienDetails
      })
    );

    (
      bytes32 rootHash,
      bytes32[] memory merkleProof
    ) = _generateLoanMerkleProof2({
        requestType: IAstariaRouter.LienRequestType.UNIQUE,
        data: validatorDetails
      });

    // setup 712 signature

    IAstariaRouter.StrategyDetailsParam memory strategyDetails = IAstariaRouter
      .StrategyDetailsParam({
        version: uint8(0),
        deadline: block.timestamp + 10 days,
        vault: vault
      });

    bytes32 termHash = keccak256(
      _generateEncodedStrategyData(vault, strategyDetails.deadline, rootHash)
    );
    return
      _generateTerms(
        GenTerms({
          tokenContract: tokenContract,
          tokenId: tokenId,
          termHash: termHash,
          rootHash: rootHash,
          pk: strategistPK,
          strategyDetails: strategyDetails,
          validatorDetails: validatorDetails,
          nlrType: uint8(IAstariaRouter.LienRequestType.UNIQUE),
          amount: amount,
          merkleProof: merkleProof,
          stack: stack
        })
      );
  }

  struct GenTerms {
    address tokenContract;
    uint256 tokenId;
    bytes32 termHash;
    bytes32 rootHash;
    uint256 pk;
    IAstariaRouter.StrategyDetailsParam strategyDetails;
    ILienToken.Stack[] stack;
    bytes validatorDetails;
    uint8 nlrType;
    bytes32[] merkleProof;
    uint256 amount;
  }

  function _generateTerms(GenTerms memory params)
    internal
    returns (IAstariaRouter.Commitment memory terms)
  {
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(params.pk, params.termHash);

    return
      IAstariaRouter.Commitment({
        tokenContract: params.tokenContract,
        tokenId: params.tokenId,
        lienRequest: IAstariaRouter.NewLienRequest({
          strategy: params.strategyDetails,
          nlrDetails: params.validatorDetails,
          merkle: IAstariaRouter.MerkleData({
            root: params.rootHash,
            proof: params.merkleProof
          }),
          stack: params.stack,
          amount: params.amount,
          v: v,
          r: r,
          s: s
        })
      });
  }

  struct Lender {
    address addr;
    uint256 amountToLend;
  }

  function _lendToVault(Lender memory lender, address vault) internal {
    vm.deal(lender.addr, lender.amountToLend);
    vm.startPrank(lender.addr);
    WETH9.deposit{value: lender.amountToLend}();
    WETH9.approve(address(TRANSFER_PROXY), lender.amountToLend);
    //min slippage on the deposit
    ASTARIA_ROUTER.depositToVault(
      IERC4626(vault),
      lender.addr,
      lender.amountToLend,
      uint256(0)
    );
    vm.stopPrank();
  }

  function _lendToPrivateVault(Lender memory lender, address vault) internal {
    vm.deal(lender.addr, lender.amountToLend);
    vm.startPrank(lender.addr);
    WETH9.deposit{value: lender.amountToLend}();
    WETH9.approve(vault, lender.amountToLend);
    //min slippage on the deposit
    Vault(vault).deposit(lender.amountToLend, lender.addr);

    vm.stopPrank();
  }

  struct Borrow {
    address borrower;
    uint256 amount; // TODO allow custom LienDetails too
    uint256 repayAmount; // if less than amount, then auction initiated with a bid of bidAmount
    uint256 bidAmount;
    uint256 timestamp;
  }

  function _lendToVault(Lender[] memory lenders, address vault) internal {
    for (uint256 i = 0; i < lenders.length; i++) {
      _lendToVault(lenders[i], vault);
    }
  }

  function _repay(
    ILienToken.Stack[] memory stack,
    uint8 position,
    uint256 amount,
    address payer
  ) internal returns (ILienToken.Stack[] memory newStack) {
    vm.deal(payer, amount * 3);
    vm.startPrank(payer);
    WETH9.deposit{value: amount * 2}();
    WETH9.approve(address(TRANSFER_PROXY), amount * 2);
    WETH9.approve(address(LIEN_TOKEN), amount * 2);

    newStack = LIEN_TOKEN.makePayment(
      stack[position].lien.collateralId,
      stack,
      position,
      amount
    );
    vm.stopPrank();
  }

  function _pay(
    ILienToken.Stack[] memory stack,
    uint8 position,
    uint256 amount,
    address payer
  ) internal returns (ILienToken.Stack[] memory newStack) {
    vm.deal(payer, amount);
    vm.startPrank(payer);
    WETH9.deposit{value: amount}();
    WETH9.approve(address(TRANSFER_PROXY), amount);
    WETH9.approve(address(LIEN_TOKEN), amount);
    newStack = LIEN_TOKEN.makePayment(
      stack[0].lien.collateralId,
      stack,
      position,
      amount
    );
    vm.stopPrank();
  }

  struct Bidder {
    address bidder;
    uint256 bidderPK;
  }

  struct Conduit {
    bytes32 conduitKey;
    address conduit;
  }

  mapping(address => Conduit) bidderConduits;

  function _bid(
    Bidder memory incomingBidder,
    OrderParameters memory params,
    uint256 bidAmount
  ) internal {
    vm.deal(incomingBidder.bidder, bidAmount * 3); // TODO check amount multiplier, was 1.5 in old testhelpers
    vm.startPrank(incomingBidder.bidder);

    if (bidderConduits[incomingBidder.bidder].conduitKey == bytes32(0)) {
      (, , address conduitController) = SEAPORT.information();
      bidderConduits[incomingBidder.bidder].conduitKey = Bytes32AddressLib
        .fillLast12Bytes(address(incomingBidder.bidder));

      bidderConduits[incomingBidder.bidder]
        .conduit = ConduitControllerInterface(conduitController).createConduit(
        bidderConduits[incomingBidder.bidder].conduitKey,
        address(incomingBidder.bidder)
      );

      ConduitControllerInterface(conduitController).updateChannel(
        address(bidderConduits[incomingBidder.bidder].conduit),
        address(SEAPORT),
        true
      );
      vm.label(
        address(bidderConduits[incomingBidder.bidder].conduit),
        "bidder conduit"
      );
    }

    OrderParameters memory mirror = _createMirrorOrderParameters(
      params,
      payable(incomingBidder.bidder),
      params.zone,
      bidderConduits[incomingBidder.bidder].conduitKey
    );
    mirror.offer[0].startAmount = bidAmount + 1 ether;
    mirror.offer[0].endAmount = bidAmount + 1 ether;
    mirror.offer[1].startAmount = (bidAmount + 1 ether + 200 wei).mulDivDown(
      25,
      1000
    );
    mirror.offer[1].endAmount = (bidAmount + 1 ether + 200 wei).mulDivDown(
      25,
      1000
    );

    Order[] memory orders = new Order[](2);
    orders[0] = Order(params, new bytes(0));

    OrderComponents memory matchOrderComponents = getOrderComponents(
      mirror,
      consideration.getCounter(incomingBidder.bidder)
    );

    emit log_order(mirror);

    bytes memory mirrorSignature = signOrder(
      SEAPORT,
      incomingBidder.bidderPK,
      consideration.getOrderHash(matchOrderComponents)
    );
    orders[1] = Order(mirror, mirrorSignature);

    //order 0 - 1 offer 3 consideration

    // order 1 - 3 offer 1 consideration

    //offers    fulfillments
    // 0,0      1,0
    // 1,0      0,0
    // 1,1      0,1
    // 1,2      0,2

    // offer 0,0
    delete fulfillmentComponents;
    fulfillmentComponent = FulfillmentComponent(0, 0);
    fulfillmentComponents.push(fulfillmentComponent);

    //for each fulfillment we need to match them up
    firstFulfillment.offerComponents = fulfillmentComponents;
    delete fulfillmentComponents;
    fulfillmentComponent = FulfillmentComponent(1, 0);
    fulfillmentComponents.push(fulfillmentComponent);
    firstFulfillment.considerationComponents = fulfillmentComponents;
    fulfillments.push(firstFulfillment); // 0,0

    // offer 1,0
    delete fulfillmentComponents;
    fulfillmentComponent = FulfillmentComponent(1, 0);
    fulfillmentComponents.push(fulfillmentComponent);
    secondFulfillment.offerComponents = fulfillmentComponents;

    delete fulfillmentComponents;
    fulfillmentComponent = FulfillmentComponent(0, 0);
    fulfillmentComponents.push(fulfillmentComponent);
    secondFulfillment.considerationComponents = fulfillmentComponents;
    fulfillments.push(secondFulfillment); // 1,0

    // offer 1,1
    delete fulfillmentComponents;
    fulfillmentComponent = FulfillmentComponent(1, 1);
    fulfillmentComponents.push(fulfillmentComponent);
    thirdFulfillment.offerComponents = fulfillmentComponents;

    delete fulfillmentComponents;
    fulfillmentComponent = FulfillmentComponent(0, 1);
    fulfillmentComponents.push(fulfillmentComponent);

    //for each fulfillment we need to match them up
    thirdFulfillment.considerationComponents = fulfillmentComponents;
    fulfillments.push(thirdFulfillment); // 1,1

    //offer 1,2
    delete fulfillmentComponents;

    //royalty stuff, setup :TODO:
    fulfillmentComponent = FulfillmentComponent(1, 2);
    fulfillmentComponents.push(fulfillmentComponent);
    fourthFulfillment.offerComponents = fulfillmentComponents;
    delete fulfillmentComponents;
    fulfillmentComponent = FulfillmentComponent(0, 2);
    fulfillmentComponents.push(fulfillmentComponent);
    fourthFulfillment.considerationComponents = fulfillmentComponents;

    if (params.consideration.length == uint8(3)) {
      fulfillments.push(fourthFulfillment); // 1,2
    }

    delete fulfillmentComponents;

    uint256 currentPrice = _locateCurrentAmount(
      params.consideration[0].startAmount,
      params.consideration[0].endAmount,
      params.startTime,
      params.endTime,
      false
    );
    if (bidAmount < currentPrice) {
      uint256 warp = _computeWarp(
        currentPrice,
        bidAmount,
        params.startTime,
        params.endTime
      );
      emit log_named_uint("start", params.consideration[0].startAmount);
      emit log_named_uint("amount", bidAmount);
      emit log_named_uint("warping", warp);
      skip(warp + 1000); //TODO: figure this slope thing out
      uint256 currentAmount = _locateCurrentAmount(
        orders[0].parameters.consideration[0].startAmount,
        orders[0].parameters.consideration[0].endAmount,
        orders[0].parameters.startTime,
        orders[0].parameters.endTime,
        false
      );
      emit log_named_uint("currentAmount asset", currentAmount);
      uint256 currentAmountFee = _locateCurrentAmount(
        orders[0].parameters.consideration[1].startAmount,
        orders[0].parameters.consideration[1].endAmount,
        orders[0].parameters.startTime,
        orders[0].parameters.endTime,
        false
      );
      emit log_named_uint("currentAmount fee", currentAmountFee);
      emit log_fills(fulfillments);
      emit log_named_uint("length", fulfillments.length);
      consideration.matchOrders{value: bidAmount + 5 ether}(
        orders,
        fulfillments
      );
    } else {
      consideration.fulfillOrder{value: bidAmount * 2}(
        orders[0],
        bidderConduits[incomingBidder.bidder].conduitKey
      );
    }
    delete fulfillments;
    vm.stopPrank();
  }

  event log_fills(Fulfillment[] fulfillments);

  function _computeWarp(
    uint256 currentPrice,
    uint256 bidAmount,
    uint256 startTime,
    uint256 endTime
  ) internal returns (uint256) {
    emit log_named_uint("currentPrice", currentPrice);
    emit log_named_uint("bidAmount", bidAmount);
    emit log_named_uint("startTime", startTime);
    emit log_named_uint("endTime", endTime);
    uint256 m = ((currentPrice - 1000 wei - 25 wei - 80 wei) /
      (endTime - startTime));
    uint256 x = ((currentPrice - bidAmount) / m);
    emit log_named_uint("m", m);
    emit log_named_uint("x", x);
    return x;
  }

  function _createMirrorOrderParameters(
    OrderParameters memory orderParameters,
    address payable offerer,
    address zone,
    bytes32 conduitKey
  ) public pure returns (OrderParameters memory) {
    OfferItem[] memory _offerItems = _toOfferItems(
      orderParameters.consideration
    );
    ConsiderationItem[] memory _considerationItems = toConsiderationItems(
      orderParameters.offer,
      offerer
    );

    OrderParameters memory _mirrorOrderParameters = OrderParameters(
      offerer,
      zone,
      _offerItems,
      _considerationItems,
      orderParameters.orderType,
      orderParameters.startTime,
      orderParameters.endTime,
      orderParameters.zoneHash,
      orderParameters.salt,
      conduitKey,
      _considerationItems.length
    );
    return _mirrorOrderParameters;
  }

  function _toOfferItems(ConsiderationItem[] memory _considerationItems)
    internal
    pure
    returns (OfferItem[] memory)
  {
    OfferItem[] memory _offerItems = new OfferItem[](
      _considerationItems.length
    );
    for (uint256 i = 0; i < _offerItems.length; i++) {
      _offerItems[i] = OfferItem(
        _considerationItems[i].itemType,
        _considerationItems[i].token,
        _considerationItems[i].identifierOrCriteria,
        _considerationItems[i].startAmount + 1,
        _considerationItems[i].endAmount + 1
      );
    }
    return _offerItems;
  }

  event log_order(OrderParameters);

  // Redeem VaultTokens for WithdrawTokens redeemable by the end of the next epoch.
  function _signalWithdraw(address lender, address publicVault) internal {
    _signalWithdrawAtFutureEpoch(
      lender,
      publicVault,
      PublicVault(publicVault).getCurrentEpoch()
    );
  }

  // Redeem VaultTokens for WithdrawTokens redeemable by the end of the next epoch.

  function _signalWithdrawAtFutureEpoch(
    address lender,
    address publicVault,
    uint64 epoch
  ) internal {
    uint256 vaultTokenBalance = IERC20(publicVault).balanceOf(lender);

    vm.startPrank(lender);
    ERC20(publicVault).safeApprove(address(ASTARIA_ROUTER), vaultTokenBalance);
    ASTARIA_ROUTER.redeemFutureEpoch({
      vault: IPublicVault(publicVault),
      shares: vaultTokenBalance,
      receiver: lender,
      epoch: epoch
    });

    WithdrawProxy withdrawProxy = PublicVault(publicVault).getWithdrawProxy(
      epoch
    );
    assertEq(
      withdrawProxy.balanceOf(lender),
      vaultTokenBalance,
      "Incorrect number of WithdrawTokens minted"
    );
    ERC20(address(withdrawProxy)).safeApprove(address(this), type(uint256).max);
    vm.stopPrank();
  }

  function _commitToLiensSameCollateral(
    address[] memory vaults, // address of deployed Vault
    address strategist,
    uint256 strategistPK,
    address tokenContract, // original NFT address
    uint256 tokenId, // original NFT id
    ILienToken.Details[] memory lienDetails // loan information
  )
    internal
    returns (uint256[] memory lienIds, ILienToken.Stack[] memory newStack)
  {
    require(vaults.length == lienDetails.length, "vaults not equal to liens");

    IAstariaRouter.Commitment[]
      memory commitments = new IAstariaRouter.Commitment[](vaults.length);
    ILienToken.Stack[] memory stack = new ILienToken.Stack[](0);
    for (uint256 i; i < vaults.length; i++) {
      commitments[i] = _generateValidTerms({
        vault: vaults[i],
        strategist: strategist,
        strategistPK: strategistPK,
        tokenContract: tokenContract,
        tokenId: tokenId,
        lienDetails: lienDetails[i],
        amount: (i + 1) * 1 ether,
        stack: stack
      });
    }

    ERC721(tokenContract).setApprovalForAll(address(ASTARIA_ROUTER), true);
    COLLATERAL_TOKEN.setApprovalForAll(address(ASTARIA_ROUTER), true);
    return ASTARIA_ROUTER.commitToLiens(commitments);
  }
}
