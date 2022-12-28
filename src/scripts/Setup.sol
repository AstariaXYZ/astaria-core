pragma solidity ^0.8.17;

import {Script} from "forge-std/Script.sol";
import {AstariaStack} from "core/scripts/deployments/AstariaStack.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import "core/test/TestHelpers.t.sol";
import {IERC4626} from "core/interfaces/IERC4626.sol";
import {ILienToken} from "core/interfaces/ILienToken.sol";

contract Setup is AstariaStack, TestHelpers {
  function setUp() public override(TestHelpers) {}

  function run() public override(Deploy) {
    MockERC20 astariaWETH = MockERC20(
      0x508f2c434E66Df1706CBa7Ae137976C814B5633E
    );
    //    astariaWETH.mint(msg.sender, 500e18);
    TestNFT nft = TestNFT(address(0xd6eF92fA2eF2Cb702f0bFfF54b111b076aC0237D));

    ASTARIA_ROUTER = AstariaRouter(ASTARIA_ROUTER_ADDR);
    COLLATERAL_TOKEN = CollateralToken(COLLATERAL_TOKEN_ADDR);
    LIEN_TOKEN = LienToken(LIEN_TOKEN_ADDR);
    address vault = address(0x459043EA157003b59cD7F666aa73Ee664E051250);
    //    address vault = ASTARIA_ROUTER.newPublicVault(
    //      10 days,
    //      address(msg.sender),
    //      address(astariaWETH),
    //      0,
    //      false,
    //      new address[](0),
    //      0
    //    );

    //    astariaWETH.approve(TRANSFER_PROXY_ADDR, type(uint256).max);
    // IERC4626 vault,
    //    address to,
    //    uint256 amount,
    //    uint256 minSharesOut
    //    vm.startBroadcast(msg.sender);
    //    nft.mint(msg.sender, 13);
    //    nft.mint(msg.sender, 14);
    //    nft.mint(msg.sender, 15);
    //    ASTARIA_ROUTER.depositToVault(IERC4626(vault), msg.sender, 100e18, 0);
    //    vm.stopBroadcast();
    //    nft.safeTransferFrom(msg.sender, COLLATERAL_TOKEN_ADDR, 11, "");
    //    CollateralToken(COLLATERAL_TOKEN_ADDR).ownerOf(
    //      uint256(
    //        61211627665129443869230057847673450818728251913281569209261074430012401530002
    //      )
    //    );
    //    vm.startBroadcast(msg.sender);
    //
    //    (, ILienToken.Stack[] memory stack) = _commitToLien({
    //      vault: vault,
    //      strategist: msg.sender,
    //      strategistPK: vm.envUint("PRIVATE_KEY"),
    //      tokenContract: address(nft),
    //      tokenId: uint256(13),
    //      lienDetails: standardLienDetails,
    //      amount: 10 ether,
    //      isFirstLien: true,
    //      stack: new ILienToken.Stack[](0),
    //      revertMessage: new bytes(0),
    //      broadcast: true
    //    });
    //    bytes32 hash1 = keccak256(abi.encode(stack));
    //
    ILienToken.Stack[] memory stack2 = new ILienToken.Stack[](1);

    stack2[0] = ILienToken.Stack(
      ILienToken.Lien(
        1,
        0x508f2c434E66Df1706CBa7Ae137976C814B5633E,
        0x459043EA157003b59cD7F666aa73Ee664E051250,
        0x95267f9c01f12bfd3e299338b0a7ff51deba28757a5c6a30c8661df971248ab2,
        43594583166590812179707933275182557302881131184420798783129118581376014344133,
        ILienToken.Details(
          50000000000000000000,
          47564687975,
          864000,
          0,
          500000000000000000000
        )
      ),
      ILienToken.Point(
        10000000000000000000,
        1670233392,
        1671097392,
        100589098951435887827741419285363633068566536542347938918567981420175971628953
      )
    );

    vm.startBroadcast(msg.sender);
    LIEN_TOKEN.makePayment(
      uint256(
        43594583166590812179707933275182557302881131184420798783129118581376014344133
      ),
      stack2,
      uint256(5e18)
    );

    vm.stopBroadcast();
    //
    //    vm.startBroadcast(msg.sender);
    //    ASTARIA_ROUTER.liquidate(stack2, uint8(0));
    //    vm.stopBroadcast();
  }

  event LogStack(ILienToken.Stack[] stack);
}
