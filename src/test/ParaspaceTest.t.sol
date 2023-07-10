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

import {
  IERC1155Receiver
} from "openzeppelin/token/ERC1155/IERC1155Receiver.sol";
import {Strings} from "openzeppelin/utils/Strings.sol";

import {ERC721} from "gpl/ERC721.sol";
import {IV3PositionManager} from "core/interfaces/IV3PositionManager.sol";
import {IERC20} from "core/interfaces/IERC20.sol";
import {ICollateralToken} from "../interfaces/ICollateralToken.sol";
import {ILienToken} from "../interfaces/ILienToken.sol";
import {IPublicVault} from "../interfaces/IPublicVault.sol";
import {CollateralToken} from "../CollateralToken.sol";
import {IAstariaRouter, AstariaRouter} from "../AstariaRouter.sol";
import {VaultImplementation} from "../VaultImplementation.sol";
import {IVaultImplementation} from "../interfaces/IVaultImplementation.sol";
import {LienToken} from "../LienToken.sol";
import {PublicVault} from "../PublicVault.sol";
import {TransferProxy} from "../TransferProxy.sol";
import {WithdrawProxy} from "../WithdrawProxy.sol";
import {WETHGateway} from "paraspace/ui/WETHGateway.sol";
//import {WETHGateway} from "lib/paraspace-core/contracts/ui/WETHGateway.sol";
import {IWETHGateway} from "paraspace/ui/interfaces/IWETHGateway.sol";
import {IPool} from "paraspace/interfaces/IPool.sol";
import {PoolCore} from "paraspace/protocol/pool/PoolCore.sol";
import {Strings2} from "./utils/Strings2.sol";
import {ClaimFees} from "../actions/UNIV3/ClaimFees.sol";

import "./TestHelpers.t.sol";

contract ParaspaceTest is TestHelpers {
  using FixedPointMathLib for uint256;
  using CollateralLookup for address;

  address constant WETH_GATEWAY =
    address(0x92D6C316CdE81f6a179A60Ee4a3ea8A76D40508A); // wethgateway proxy
  address constant LOAN_HOLDER =
    address(0x0001BB2a72173F3a1aaAE96BD0Ddb1f8BE4f91B7);
  address constant PARASPACE_VDEBTWETH =
    address(0x87F92191e14d970f919268045A57f7bE84559CEA);
  address constant WETH = address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
  address constant POOL_ADDRESSES_PROVIDER =
    address(0x6cD30e716ADbE47dADf7319f6F2FB83d507c857d);
  address constant POOL_CORE =
    address(0x542ef16d4074a735DC475516F3E2d824F2b0B450);
  address constant BORROWER_TOKEN_ADDRESS =
    address(0x98da23b5D096747333B0ED6009229d89812dd24b); // probably
  uint256 constant BORROWER_TOKEN_ID = 25345;
  uint256 constant REPAY_BLOCK = 17369662;
  uint256 constant REPAY_AMOUNT = 2 ether;

  uint256 mainnetFork;

  function setUp() public override {
    mainnetFork = vm.createFork(
      "https://eth-mainnet.g.alchemy.com/v2/Zq7Fxle2NDGpJN9WxSE33NShHrdMUpcx"
    );
  }

  function testRepayActiveLoan() public {
    vm.selectFork(mainnetFork);
    vm.roll(REPAY_BLOCK);
    vm.startPrank(LOAN_HOLDER);

    address payable poolCore = payable(POOL_CORE);
    address payable holder = payable(LOAN_HOLDER);
    address payable gateway = payable(WETH_GATEWAY);

    emit log_named_uint(
      "balance",
      ERC20(PARASPACE_VDEBTWETH).balanceOf(LOAN_HOLDER)
    );
    vm.deal(LOAN_HOLDER, 3 ether);
    //        address debtToken = IPool(POOL_CORE).getReserveData(WETH).variableDebtTokenAddress;
    //        uint256 debt = IERC20(debtToken).balanceOf(LOAN_HOLDER);
    //        WETHGateway(gateway).repayETH{value: debt}(debt, holder);
    WETHGateway(gateway).repayETH{value: 1 ether}(1 ether, holder);
    vm.stopPrank();
  }

  function _repayParaspaceCommitToLienAstaria(address borrower) internal {
    uint256 currentDebt = ERC20(PARASPACE_VDEBTWETH).balanceOf(borrower);
    address publicVault = _createPublicVault({
      strategist: strategistOne,
      delegate: strategistTwo,
      epochLength: 14 days
    });

    _lendToVault(
      Lender({addr: address(1), amountToLend: 50 ether}),
      payable(publicVault)
    );

    ILienToken.Details memory details = standardLienDetails;
    standardLienDetails.maxAmount = currentDebt + 1 ether;
    //        (, ILienToken.Stack memory stack) = _commitToLien({
    //            vault: payable(publicVault),
    //            strategist: strategistOne,
    //            strategistPK: strategistOnePK,
    //            tokenContract: BORROWER_TOKEN_ADDRESS,
    //            tokenId: BORROWER_TOKEN_ID,
    //            lienDetails: standardLienDetails,
    //            amount: 1 ether
    //        });
  }

  struct LoanData {
    address tokenAddress;
    uint256 tokenId;
    uint256 debt;
  }

  //    function getUserLoanData(
  //        address borrower
  //    ) public view returns (LoanData[] memory) {
  //
  //
  //
  //    }
}
