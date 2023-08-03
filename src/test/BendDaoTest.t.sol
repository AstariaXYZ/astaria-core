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
  address constant LOAN_HOLDER = 0x221856C687333A29BBF5c8F29E7e0247436CCF7D;
  uint256 constant REPAY_BLOCK = 17636704;

  address constant BEND_ADDRESSES_PROVIDER =
    0x24451F47CaF13B24f4b5034e1dF6c0E401ec0e46;
  address payable constant BEND_WETH_GATEWAY =
    payable(0x3B968D2D299B895A5Fcf3BBa7A64ad0F566e6F88); // TODO make changeable?
  address payable constant BEND_PUNK_GATEWAY =
    payable(0xeD01f8A737813F0bDA2D4340d191DBF8c2Cbcf30);

  address constant BEND_PROTOCOL_DATA_PROVIDER =
    0x3811DA50f55CCF75376C5535562F5b4797822480;

  address constant BALANCER_VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8; // TODO verify
  address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

  // goerli
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
  //  address constant WETH = 0xB4FBF271143F4FBf7B91A5ded31805e42b2208d6;

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
    vm.selectFork(mainnetFork);
    vm.roll(REPAY_BLOCK);
    //    _dealWeth(BALANCER_VAULT, 48123908081253539840000 * 2);

    ExternalRefinancing refinancing = new ExternalRefinancing({
      //      router: address(ASTARIA_ROUTER),
      router: address(0),
      bendAddressesProvider: BEND_ADDRESSES_PROVIDER,
      bendDataProvider: BEND_PROTOCOL_DATA_PROVIDER,
      bendPunkGateway: BEND_PUNK_GATEWAY,
      balancerVault: BALANCER_VAULT,
      weth: WETH
    });

    //    address payable publicVault = _createPublicVault({
    //      strategist: strategistOne,
    //      delegate: strategistTwo,
    //      epochLength: 14 days
    //    });
    //
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

    vm.startPrank(LOAN_HOLDER);
    refinancing.refinance(
      LOAN_HOLDER,
      0xBC4CA0EdA7647A8aB7C2061c2E118A18a936f13D,
      122,
      48123908081253539840000
    );

    vm.stopPrank();
  }

  function testRefinancePOC() public {
    vm.selectFork(mainnetFork);
    vm.roll(REPAY_BLOCK);
    address pool = LendPoolAddressesProvider(BEND_ADDRESSES_PROVIDER)
      .getLendPool();

    vm.startPrank(LOAN_HOLDER);
    address[] memory nfts = new address[](1);
    nfts[0] = 0xBC4CA0EdA7647A8aB7C2061c2E118A18a936f13D;
    uint256[] memory ids = new uint256[](1);
    ids[0] = 122;
    uint256[] memory amounts = new uint256[](1);
    amounts[0] = 48123908081253539840000;
    vm.deal(LOAN_HOLDER, 48123908081253539840000);
    //    WETHGateway(payable(WETH_GATEWAY)).batchRepayETH{
    //      value: 48123908081253539840000
    //    }(nfts, ids, amounts);
    LendPool(pool).batchRepay(nfts, ids, amounts);
    vm.stopPrank();
  }
}
