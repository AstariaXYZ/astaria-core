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

import "forge-std/Test.sol";

import {Authority} from "solmate/auth/Auth.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {MockERC721} from "solmate/test/utils/mocks/MockERC721.sol";
import {
  MultiRolesAuthority
} from "solmate/auth/authorities/MultiRolesAuthority.sol";

import {ERC721} from "gpl/ERC721.sol";
import {SafeCastLib} from "gpl/utils/SafeCastLib.sol";

import {
  LendPoolAddressesProvider
} from "bend-protocol/protocol/LendPoolAddressesProvider.sol";
//import {BendUpgradeableProxy} from "bend-protocol/libraries/proxy/BendUpgradeableProxy.sol";
import {WETHGateway} from "bend-protocol/protocol/WETHGateway.sol";
import {LendPool} from "bend-protocol/protocol/LendPool.sol";
import {BNFTRegistry} from "bend-protocol/mock/BNFT/BNFTRegistry.sol";
import {
  BendProtocolDataProvider
} from "bend-protocol/misc/BendProtocolDataProvider.sol";

import {IAstariaRouter, AstariaRouter} from "../AstariaRouter.sol";
import {VaultImplementation} from "../VaultImplementation.sol";
import {PublicVault} from "../PublicVault.sol";
import {TransferProxy} from "../TransferProxy.sol";
import {WithdrawProxy} from "../WithdrawProxy.sol";
import {ExternalRefinancing} from "../ExternalRefinancing.sol";
import {IWETH9} from "gpl/interfaces/IWETH9.sol";

import {Strings2} from "./utils/Strings2.sol";

import "./TestHelpers.t.sol";

contract BendDaoTest is TestHelpers {
  using FixedPointMathLib for uint256;
  using CollateralLookup for address;
  using SafeCastLib for uint256;

  uint256 mainnetFork;
  uint256 goerliFork;

  struct Loan {
    address tokenContract;
    uint256 tokenId;
    uint256 outstandingDebt;
  }

  // MAINNET
  //  address constant LOAN_HOLDER = 0x221856C687333A29BBF5c8F29E7e0247436CCF7D;
  //  uint256 constant REPAY_BLOCK = 17636704;
  //
  //  address constant BEND_ADDRESSES_PROVIDER =
  //    0x24451F47CaF13B24f4b5034e1dF6c0E401ec0e46;
  //  address payable constant BEND_WETH_GATEWAY =
  //    payable(0x3B968D2D299B895A5Fcf3BBa7A64ad0F566e6F88); // TODO make changeable?
  //  address payable constant BEND_PUNK_GATEWAY =
  //    payable(0xeD01f8A737813F0bDA2D4340d191DBF8c2Cbcf30);
  //
  //  address constant BEND_PROTOCOL_DATA_PROVIDER =
  //    0x3811DA50f55CCF75376C5535562F5b4797822480;
  //
  //  address constant BALANCER_VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8; // TODO verify
  //  address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

  //  address constant NFT_ADDRESS = 0xBC4CA0EdA7647A8aB7C2061c2E118A18a936f13D;
  //  uint256 constant NFT_ID = 122;
  //  uint256 constant LOAN_AMOUNT = 48123908081253539840000;

  // goerli
  address constant LOAN_HOLDER = 0xF354cc22B402a659B42be180f9947d8E38B4631f;
  uint256 constant REPAY_BLOCK = 9420976;

  address constant NFT_ADDRESS = 0x708c48AaA4Ea8B9E46Bd8DEb6470986842b9a16d;
  uint256 constant NFT_ID = 7712;
  uint256 constant LOAN_AMOUNT = 1000000000000000 * 10;

  address constant BEND_ADDRESSES_PROVIDER =
    0x1cba0A3e18be7f210713c9AC9FE17955359cC99B;
  address payable constant BEND_WETH_GATEWAY =
    payable(0xB926DD4A16c264F02986B575b546123D5D0bC607);
  address payable constant BEND_PUNK_GATEWAY =
    payable(0xa7076550Ee79DB0320BE98f89D775797D859140c);

  address constant BEND_PROTOCOL_DATA_PROVIDER =
    0xeFC513D24D2AC6dA4fF3C6429642DD6C497B0845;

  address constant BALANCER_VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8; // TODO verify
  address constant WETH = 0xB4FBF271143F4FBf7B91A5ded31805e42b2208d6;

  address constant GOERLI_ASTARIA_ROUTER =
    0x552b2ec897FAb8D769E9389B0582d948AbfEe0aE;
  address constant GOERLI_TRANSFER_PROXY =
    0x412A4AAb59B96Fef6037e59e61767019C008cE27;
  address constant GOERLI_COLLATERAL_TOKEN =
    0x4Fe2e8bf0DA8a4325DC37916B0b7f07239a17D14;

  function setUp() public override {
    mainnetFork = vm.createFork(
      "https://eth-mainnet.g.alchemy.com/v2/Zq7Fxle2NDGpJN9WxSE33NShHrdMUpcx"
    );

    goerliFork = vm.createFork(
      "https://eth-goerli.g.alchemy.com/v2/0XrLj8j5tgbjWxziyCrctDSALEG5TpUa"
    );
  }

  function _dealWeth(address addr, uint256 amount) internal {
    vm.deal(addr, amount);
    vm.startPrank(addr);
    IWETH9(WETH).deposit{value: amount}();
    vm.stopPrank();
  }

  function testExternalRefinancing() public {
    vm.selectFork(goerliFork);
    vm.roll(REPAY_BLOCK);

    ExternalRefinancing refinancing = new ExternalRefinancing({
      router: GOERLI_ASTARIA_ROUTER,
      bendAddressesProvider: BEND_ADDRESSES_PROVIDER,
      bendDataProvider: BEND_PROTOCOL_DATA_PROVIDER,
      bendPunkGateway: BEND_PUNK_GATEWAY,
      balancerVault: BALANCER_VAULT,
      weth: WETH,
      bendWethGateway: BEND_WETH_GATEWAY,
      collateralToken: GOERLI_COLLATERAL_TOKEN
    });

    //    address payable publicVault = _createPublicVault({
    //      strategist: strategistOne,
    //      delegate: strategistTwo,
    //      epochLength: 14 days
    //    });
    //    _lendToVault(
    //      Lender({addr: address(1), amountToLend: 50 ether}),
    //      payable(publicVault)
    //    );
    //
    //    ILienToken.Details memory details = ILienToken.Details({
    //      maxAmount: 48123908081253539840000,
    //      rate: (uint256(1e16) * 150) / (365 days),
    //      duration: 10 days,
    //      maxPotentialDebt: 0,
    //      liquidationInitialAsk: 48123908081253539840000 * 2
    //    });
    //
    //    IAstariaRouter.Commitment memory commitment = _generateValidTerms({
    //      vault: publicVault,
    //      strategist: strategistOne,
    //      strategistPK: strategistOnePK,
    //      tokenContract: 0xBC4CA0EdA7647A8aB7C2061c2E118A18a936f13D,
    //      tokenId: 122,
    //      lienDetails: details,
    //      amount: 48123908081253539840000
    //    });

    // goerli Astaria

    vm.startPrank(strategistOne);
    address payable publicVault = payable(
      AstariaRouter(GOERLI_ASTARIA_ROUTER).newPublicVault(
        14 days,
        strategistTwo,
        address(WETH),
        0,
        false,
        new address[](0),
        uint256(0)
      )
    );
    vm.stopPrank();
    _dealWeth(address(1), LOAN_AMOUNT * 2);
    vm.startPrank(address(1));
    IWETH9(WETH).approve(GOERLI_TRANSFER_PROXY, LOAN_AMOUNT * 2);
    AstariaRouter(GOERLI_ASTARIA_ROUTER).depositToVault(
      IERC4626(publicVault),
      address(1),
      LOAN_AMOUNT * 2,
      0
    );
    vm.stopPrank();

    ILienToken.Details memory details = ILienToken.Details({
      maxAmount: LOAN_AMOUNT,
      rate: (uint256(1e16) * 150) / (365 days),
      duration: 10 days,
      maxPotentialDebt: 0,
      liquidationInitialAsk: LOAN_AMOUNT * 10
    });

    IAstariaRouter.Commitment memory commitment = _generateValidTerms({
      vault: publicVault,
      strategist: strategistOne,
      strategistPK: strategistOnePK,
      tokenContract: NFT_ADDRESS,
      tokenId: NFT_ID,
      lienDetails: details,
      amount: LOAN_AMOUNT
    });

    vm.startPrank(LOAN_HOLDER);
    ERC721(NFT_ADDRESS).setApprovalForAll(GOERLI_ASTARIA_ROUTER, true);
    ERC721(NFT_ADDRESS).setApprovalForAll(address(refinancing), true);
    console.log("BOMB", address(refinancing));
    refinancing.refinance(
      LOAN_HOLDER,
      NFT_ADDRESS,
      NFT_ID,
      LOAN_AMOUNT,
      commitment
    );

    vm.stopPrank();
  }

  //  function testRefinancePOC() public {
  //    vm.selectFork(mainnetFork);
  //    vm.roll(REPAY_BLOCK);
  //    address pool = LendPoolAddressesProvider(BEND_ADDRESSES_PROVIDER)
  //      .getLendPool();
  //
  //    vm.startPrank(LOAN_HOLDER);
  //    address[] memory nfts = new address[](1);
  //    nfts[0] = 0xBC4CA0EdA7647A8aB7C2061c2E118A18a936f13D;
  //    uint256[] memory ids = new uint256[](1);
  //    ids[0] = 122;
  //    uint256[] memory amounts = new uint256[](1);
  //    amounts[0] = 48123908081253539840000;
  //    vm.deal(LOAN_HOLDER, 48123908081253539840000);
  //    //    WETHGateway(payable(WETH_GATEWAY)).batchRepayETH{
  //    //      value: 48123908081253539840000
  //    //    }(nfts, ids, amounts);
  //    LendPool(pool).batchRepay(nfts, ids, amounts);
  //    vm.stopPrank();
  //  }
}
