pragma solidity ^0.8.16;

import "forge-std/Test.sol";

import {Authority} from "solmate/auth/Auth.sol";
import {MultiRolesAuthority} from "solmate/auth/authorities/MultiRolesAuthority.sol";
// import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
import {IERC1155Receiver} from "openzeppelin/token/ERC1155/IERC1155Receiver.sol";
// import {ERC721} from "solmate/tokens/ERC721.sol";
import {ERC721} from "gpl/ERC721.sol";
import {Strings} from "openzeppelin/utils/Strings.sol";
import {CollateralToken, IFlashAction} from "../CollateralToken.sol";
import {LienToken} from "../LienToken.sol";
import {ILienToken} from "../interfaces/ILienToken.sol";
import {ICollateralToken} from "../interfaces/ICollateralToken.sol";
import {MockERC721} from "solmate/test/utils/mocks/MockERC721.sol";
import {IAstariaRouter, AstariaRouter} from "../AstariaRouter.sol";
import {AuctionHouse} from "gpl/AuctionHouse.sol";
import {IAuctionHouse} from "gpl/interfaces/IAuctionHouse.sol";
import {Strings2} from "./utils/Strings2.sol";
import {IVault, VaultImplementation} from "../VaultImplementation.sol";
import {TransferProxy} from "../TransferProxy.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {PublicVault} from "../PublicVault.sol";
import {WithdrawProxy} from "../WithdrawProxy.sol";

import "./TestHelpers2.t.sol";

contract RevertTesting is TestHelpers {
    using FixedPointMathLib for uint256;
    using CollateralLookup for address;
}
