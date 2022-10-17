pragma solidity ^0.8.16;

import "forge-std/Test.sol";

import {Authority} from "solmate/auth/Auth.sol";
import {MultiRolesAuthority} from "solmate/auth/authorities/MultiRolesAuthority.sol";
import {ERC721} from "gpl/ERC721.sol";
import {MockERC721} from "solmate/test/utils/mocks/MockERC721.sol";
import {IAstariaRouter, AstariaRouter} from "../AstariaRouter.sol";
import {AuctionHouse} from "gpl/AuctionHouse.sol";
import {IAuctionHouse} from "gpl/interfaces/IAuctionHouse.sol";
import {Strings2} from "./utils/Strings2.sol";
import {IVault, VaultImplementation} from "../VaultImplementation.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {SafeCastLib} from "gpl/utils/SafeCastLib.sol";
import {TransferProxy} from "../TransferProxy.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {PublicVault} from "../PublicVault.sol";
import {WithdrawProxy} from "../WithdrawProxy.sol";
import {LiquidationAccountant} from "../LiquidationAccountant.sol";

import "./TestHelpers.t.sol";

contract FuzzTest is TestHelpers {
    using FixedPointMathLib for uint256;
    using CollateralLookup for address;
    using SafeCastLib for uint256;

    // check that lien slope and aggregate PublicVault slope is correctly
    function testFuzzSlopeUpdates() public {}

    function testFuzzWithdrawProxy() public {}

    // test that maxPotentialDebt checks are always enforced
    function testFuzzMaxPotentialDebt() public {}

    function testFuzzLiquidationAccountantSplit() public {}
}
