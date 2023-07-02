// SPDX-License-Identifier: MIT
import "./TestHelpers.t.sol";
import "./FuzzTesting.t.sol";
import "./utils/SigUtils.sol";
import {Bound} from "./utils/Bound.sol";
import "murky/Merkle.sol";
import {IERC4626 as ERC4626} from "src/interfaces/IERC4626.sol";
import {ERC721TokenReceiver} from "solmate/tokens/ERC721.sol";
import {AstariaFuzzTest} from "./FuzzTesting.t.sol";
import {PublicVault} from "core/PublicVault.sol";

contract AstariaInvariantTest is Test, TestHelpers, SigUtils, Bound {
  PublicVault public vault;

  function setUp() public override {
    super.setUp();

    vm.warp(100_000);

    vm.startPrank(strategistOne);
    vault = PublicVault(
      payable(
        ASTARIA_ROUTER.newPublicVault(
          14 days,
          strategistTwo,
          address(WETH9),
          0,
          false,
          new address[](0),
          uint256(0)
        )
      )
    );

    vm.label(address(vault), "PublicVault");
    vm.label(address(TRANSFER_PROXY), "TransferProxy");

    //    AstariaFuzzTest.Contracts memory contracts =  AstariaFuzzTest.Contracts({
    //      PUBLIC_VAULT: vault,
    //      //SOLO_VAULT: address(soloVault),
    //      COLLATERAL_TOKEN: CollateralToken(address(COLLATERAL_TOKEN)),
    //      LIEN_TOKEN: LienToken(address(LIEN_TOKEN)),
    //      ASTARIA_ROUTER: AstariaRouter(address(ASTARIA_ROUTER)),
    //      WETH9: WETH9,
    //      WITHDRAW_PROXY: WithdrawProxy(address(WITHDRAW_PROXY)),
    //      TRANSFER_PROXY: TransferProxy(address(TRANSFER_PROXY))
    //    });
    //
    AstariaFuzzTest fuzz = new AstariaFuzzTest();
    //    fuzz.invariantHandlerSetUp(contracts);
    //
    targetContract(address(fuzz));
  }

  function invariant_canProcessEpoch() public {
    if (vault.timeToEpochEnd() > 0) {
      return;
    }

    (uint256 openLiens, ) = vault.getEpochData(vault.getCurrentEpoch());

    if (openLiens > 0) {
      console.log("openLiens", openLiens);
      return;
    }

    vault.processEpoch();
  }
}
