// SPDX-License-Identifier: UNLICENSED

/**
 *       __  ___       __
 *  /\  /__'  |   /\  |__) |  /\
 * /~~\ .__/  |  /~~\ |  \ | /~~\
 *
 * Copyright (c) Astaria Labs, Inc
 */

pragma solidity ^0.8.17;

import "forge-std/Test.sol";

import {Authority} from "solmate/auth/Auth.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {MockERC721} from "solmate/test/utils/mocks/MockERC721.sol";
import {
  MultiRolesAuthority
} from "solmate/auth/authorities/MultiRolesAuthority.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";

import {AuctionHouse} from "gpl/AuctionHouse.sol";
import {ERC721} from "gpl/ERC721.sol";
import {ITransferProxy} from "core/interfaces/ITransferProxy.sol";
import {SafeCastLib} from "gpl/utils/SafeCastLib.sol";

import {ICollateralToken} from "core/interfaces/ICollateralToken.sol";
import {IERC20} from "core/interfaces/IERC20.sol";
import {ILienToken} from "core/interfaces/ILienToken.sol";
import {IStrategyValidator} from "core/interfaces/IStrategyValidator.sol";

import {CollateralLookup} from "core/libraries/CollateralLookup.sol";

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
import {IVault, VaultImplementation} from "../VaultImplementation.sol";
import {LienToken} from "../LienToken.sol";
import {LiquidationAccountant} from "../LiquidationAccountant.sol";
import {TransferProxy} from "../TransferProxy.sol";
import {Vault, PublicVault} from "../PublicVault.sol";
import {WithdrawProxy} from "../WithdrawProxy.sol";

import {Strings2} from "./utils/Strings2.sol";
import {BeaconProxy} from "../BeaconProxy.sol";

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

contract TestHelpers is Test {
  using CollateralLookup for address;
  using Strings2 for bytes;
  using SafeCastLib for uint256;
  using SafeTransferLib for ERC20;

  uint256 strategistOnePK = uint256(0x1339);
  uint256 strategistTwoPK = uint256(0x1344); // strategistTwo is delegate for PublicVault created by strategistOne
  address strategistOne = vm.addr(strategistOnePK);
  address strategistTwo = vm.addr(strategistTwoPK);

  address borrower = vm.addr(0x1341);
  address bidderOne = vm.addr(0x1342);
  address bidderTwo = vm.addr(0x1343);

  string private checkpointLabel;
  uint256 private checkpointGasLeft = 1; // Start the slot warm.

  ILienToken.Details public standardLienDetails =
    ILienToken.Details({
      maxAmount: 50 ether,
      rate: (uint256(1e16) * 150) / (365 days),
      duration: 10 days,
      maxPotentialDebt: 0 ether
    });

  ILienToken.Details public refinanceLienDetails5 =
    ILienToken.Details({
      maxAmount: 50 ether,
      rate: (uint256(1e16) * 150) / (365 days),
      duration: 25 days,
      maxPotentialDebt: 54 ether
    });
  ILienToken.Details public refinanceLienDetails =
    ILienToken.Details({
      maxAmount: 50 ether,
      rate: (uint256(1e16) * 150) / (365 days),
      duration: 25 days,
      maxPotentialDebt: 53 ether
    });
  ILienToken.Details public refinanceLienDetails2 =
    ILienToken.Details({
      maxAmount: 50 ether,
      rate: (uint256(1e16) * 150) / (365 days),
      duration: 25 days,
      maxPotentialDebt: 52 ether
    });

  ILienToken.Details public refinanceLienDetails3 =
    ILienToken.Details({
      maxAmount: 50 ether,
      rate: (uint256(1e16) * 150) / (365 days),
      duration: 25 days,
      maxPotentialDebt: 51 ether
    });
  ILienToken.Details public refinanceLienDetails4 =
    ILienToken.Details({
      maxAmount: 50 ether,
      rate: (uint256(1e16) * 150) / (365 days),
      duration: 25 days,
      maxPotentialDebt: 55 ether
    });

  enum UserRoles {
    ADMIN,
    ASTARIA_ROUTER,
    WRAPPER,
    AUCTION_HOUSE,
    TRANSFER_PROXY,
    LIEN_TOKEN
  }

  enum StrategyTypes {
    STANDARD,
    COLLECTION,
    UNIV3_LIQUIDITY
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

  CollateralToken COLLATERAL_TOKEN;
  LienToken LIEN_TOKEN;
  AstariaRouter ASTARIA_ROUTER;
  PublicVault PUBLIC_VAULT;
  WithdrawProxy WITHDRAW_PROXY;
  LiquidationAccountant LIQUIDATION_IMPLEMENTATION;
  Vault SOLO_VAULT;
  TransferProxy TRANSFER_PROXY;
  IWETH9 WETH9;
  MultiRolesAuthority MRA;
  AuctionHouse AUCTION_HOUSE;

  function setUp() public virtual {
    WETH9 = IWETH9(deployCode(weth9Artifact));

    MRA = new MultiRolesAuthority(address(this), Authority(address(0)));

    TRANSFER_PROXY = new TransferProxy(MRA);
    LIEN_TOKEN = new LienToken(MRA, TRANSFER_PROXY, address(WETH9));
    COLLATERAL_TOKEN = new CollateralToken(
      MRA,
      TRANSFER_PROXY,
      ILienToken(address(LIEN_TOKEN))
    );

    PUBLIC_VAULT = new PublicVault();
    SOLO_VAULT = new Vault();
    WITHDRAW_PROXY = new WithdrawProxy();
    LIQUIDATION_IMPLEMENTATION = new LiquidationAccountant();
    BeaconProxy BEACON_PROXY = new BeaconProxy();

    ASTARIA_ROUTER = new AstariaRouter(
      MRA,
      address(WETH9),
      ICollateralToken(address(COLLATERAL_TOKEN)),
      ILienToken(address(LIEN_TOKEN)),
      ITransferProxy(address(TRANSFER_PROXY)),
      address(PUBLIC_VAULT),
      address(SOLO_VAULT),
      address(LIQUIDATION_IMPLEMENTATION),
      address(WITHDRAW_PROXY),
      address(BEACON_PROXY)
    );

    AUCTION_HOUSE = new AuctionHouse(
      address(WETH9),
      MRA,
      ICollateralToken(address(COLLATERAL_TOKEN)),
      ILienToken(address(LIEN_TOKEN)),
      TRANSFER_PROXY,
      ASTARIA_ROUTER
    );
    V3SecurityHook V3_SECURITY_HOOK = new V3SecurityHook(
      address(0xC36442b4a4522E871399CD717aBDD847Ab11FE88)
    );

    CollateralToken.File[] memory ctfiles = new CollateralToken.File[](2);

    ctfiles[0] = ICollateralToken.File({
      what: "setAstariaRouter",
      data: abi.encode(address(ASTARIA_ROUTER))
    });

    address UNI_V3_NFT = address(0xC36442b4a4522E871399CD717aBDD847Ab11FE88);
    ctfiles[1] = ICollateralToken.File({
      what: bytes32("setSecurityHook"),
      data: abi.encode(UNI_V3_NFT, address(V3_SECURITY_HOOK))
    });

    COLLATERAL_TOKEN.fileBatch(ctfiles);

    //strategy unique
    UniqueValidator UNIQUE_STRATEGY_VALIDATOR = new UniqueValidator();
    //strategy collection
    CollectionValidator COLLECTION_STRATEGY_VALIDATOR = new CollectionValidator();
    //strategy univ3
    UNI_V3Validator UNIV3_LIQUIDITY_STRATEGY_VALIDATOR = new UNI_V3Validator();

    AstariaRouter.File[] memory files = new AstariaRouter.File[](3);

    files[0] = AstariaRouter.File(
      bytes32("setStrategyValidator"),
      abi.encode(uint8(0), address(UNIQUE_STRATEGY_VALIDATOR))
    );
    files[1] = AstariaRouter.File(
      bytes32("setStrategyValidator"),
      abi.encode(uint8(1), address(COLLECTION_STRATEGY_VALIDATOR))
    );
    files[2] = AstariaRouter.File(
      bytes32("setStrategyValidator"),
      abi.encode(uint8(2), address(UNIV3_LIQUIDITY_STRATEGY_VALIDATOR))
    );

    ASTARIA_ROUTER.fileBatch(files);
    files = new AstariaRouter.File[](1);

    files[0] = AstariaRouter.File(
      bytes32("setAuctionHouse"),
      abi.encode(address(AUCTION_HOUSE))
    );
    ASTARIA_ROUTER.fileGuardian(files);

    LIEN_TOKEN.file(
      bytes32("setAuctionHouse"),
      abi.encode(address(AUCTION_HOUSE))
    );
    LIEN_TOKEN.file(
      bytes32("setCollateralToken"),
      abi.encode(address(COLLATERAL_TOKEN))
    );
    LIEN_TOKEN.file(
      bytes32("setAstariaRouter"),
      abi.encode(address(ASTARIA_ROUTER))
    );

    _setupRolesAndCapabilities();
  }

  function _setupRolesAndCapabilities() internal {
    MRA.setRoleCapability(
      uint8(UserRoles.ASTARIA_ROUTER),
      AuctionHouse.createAuction.selector,
      true
    );
    MRA.setRoleCapability(
      uint8(UserRoles.ASTARIA_ROUTER),
      AuctionHouse.endAuction.selector,
      true
    );
    MRA.setRoleCapability(
      uint8(UserRoles.ASTARIA_ROUTER),
      AuctionHouse.cancelAuction.selector,
      true
    );
    MRA.setRoleCapability(
      uint8(UserRoles.ASTARIA_ROUTER),
      LienToken.createLien.selector,
      true
    );
    //    MRA.setRoleCapability(
    //      uint8(UserRoles.ASTARIA_ROUTER),
    //      CollateralToken.auctionVault.selector,
    //      true
    //    );
    MRA.setRoleCapability(
      uint8(UserRoles.ASTARIA_ROUTER),
      TRANSFER_PROXY.tokenTransferFrom.selector,
      true
    );
    MRA.setRoleCapability(
      uint8(UserRoles.AUCTION_HOUSE),
      LienToken.removeLiens.selector,
      true
    );
    MRA.setRoleCapability(
      uint8(UserRoles.ASTARIA_ROUTER),
      LienToken.stopLiens.selector,
      true
    );
    MRA.setRoleCapability(
      uint8(UserRoles.AUCTION_HOUSE),
      TRANSFER_PROXY.tokenTransferFrom.selector,
      true
    );
    MRA.setRoleCapability(
      uint8(UserRoles.AUCTION_HOUSE),
      ILienToken.makePaymentAuctionHouse.selector, //bytes4(keccak256(bytes("makePayment(uint256,uint256,uint8,address)"))),
      true
    );
    MRA.setUserRole(
      address(ASTARIA_ROUTER),
      uint8(UserRoles.ASTARIA_ROUTER),
      true
    );
    MRA.setUserRole(address(COLLATERAL_TOKEN), uint8(UserRoles.WRAPPER), true);
    MRA.setUserRole(
      address(AUCTION_HOUSE),
      uint8(UserRoles.AUCTION_HOUSE),
      true
    );

    MRA.setRoleCapability(
      uint8(UserRoles.LIEN_TOKEN),
      TRANSFER_PROXY.tokenTransferFrom.selector,
      true
    );
    MRA.setUserRole(address(LIEN_TOKEN), uint8(UserRoles.LIEN_TOKEN), true);
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
    inputs[0] = "ts-node";
    inputs[1] = "./scripts/loanProofGenerator.ts";

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
        stack: new ILienToken.Stack[](0)
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

    COLLATERAL_TOKEN.setApprovalForAll(address(ASTARIA_ROUTER), true);
    return ASTARIA_ROUTER.commitToLiens(commitments);
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

    IAstariaRouter.StrategyDetails memory strategyDetails = IAstariaRouter
      .StrategyDetails({
        version: uint8(0),
        strategist: strategist,
        deadline: block.timestamp + 10 days,
        vault: vault
      });

    bytes32 termHash = keccak256(
      VaultImplementation(vault).encodeStrategyData(strategyDetails, rootHash)
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
    IAstariaRouter.StrategyDetails strategyDetails;
    ILienToken.Stack[] stack;
    bytes validatorDetails;
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
          nlrType: uint8(IAstariaRouter.LienRequestType.UNIQUE), // TODO support others?
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

  function startMeasuringGas(string memory label) internal virtual {
    checkpointLabel = label;

    checkpointGasLeft = gasleft();
  }

  function stopMeasuringGas() internal virtual {
    uint256 checkpointGasLeft2 = gasleft();

    // Subtract 100 to account for the warm SLOAD in startMeasuringGas.
    uint256 gasDelta = checkpointGasLeft - checkpointGasLeft2 - 100;

    emit log_named_uint(
      string(abi.encodePacked(checkpointLabel, " Gas")),
      gasDelta
    );
  }

  struct Lender {
    address addr;
    uint256 amountToLend;
  }

  function _lendToVault(Lender memory lender, address vault) internal {
    vm.deal(lender.addr, lender.amountToLend);
    vm.startPrank(lender.addr);
    WETH9.deposit{value: lender.amountToLend}();
    WETH9.approve(vault, lender.amountToLend);
    IVault(vault).deposit(lender.amountToLend, lender.addr);
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
  ) internal {
    vm.deal(payer, amount * 3);
    vm.startPrank(payer);
    WETH9.deposit{value: amount * 2}();
    WETH9.approve(address(TRANSFER_PROXY), amount * 2);
    WETH9.approve(address(LIEN_TOKEN), amount * 2);
    LIEN_TOKEN.makePayment(stack, position, amount * 2);
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
    newStack = LIEN_TOKEN.makePayment(stack, position, amount);
    vm.stopPrank();
  }

  function _bid(
    address bidder,
    uint256 tokenId,
    uint256 amount
  ) internal {
    vm.deal(bidder, amount * 2); // TODO check amount multiplier, was 1.5 in old testhelpers
    vm.startPrank(bidder);
    WETH9.deposit{value: amount}();
    WETH9.approve(address(TRANSFER_PROXY), amount);
    emit log_named_uint("bidder balance", WETH9.balanceOf(bidder));
    AUCTION_HOUSE.createBid(tokenId, amount);
    vm.stopPrank();
  }

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
    ERC20(publicVault).safeApprove(publicVault, type(uint256).max);
    PublicVault(publicVault).redeemFutureEpoch({
      shares: vaultTokenBalance,
      receiver: lender,
      owner: lender,
      epoch: epoch
    });

    address withdrawProxy = PublicVault(publicVault).getWithdrawProxy(epoch);
    assertEq(
      IERC20(withdrawProxy).balanceOf(lender),
      vaultTokenBalance,
      "Incorrect number of WithdrawTokens minted"
    );
    ERC20(withdrawProxy).safeApprove(address(this), type(uint256).max);
    vm.stopPrank();
  }

  function _commitToLiensSameCollateral(
    address[] memory vaults, // address of deployed Vault
    address strategist,
    uint256 strategistPK,
    address tokenContract, // original NFT address
    uint256 tokenId, // original NFT id
    ILienToken.Details[] memory lienDetails, // loan information
    uint256 amount // requested amount
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
        amount: amount,
        stack: stack
      });
    }

    ERC721(tokenContract).setApprovalForAll(address(ASTARIA_ROUTER), true);
    COLLATERAL_TOKEN.setApprovalForAll(address(ASTARIA_ROUTER), true);
    return ASTARIA_ROUTER.commitToLiens(commitments);
  }
}
