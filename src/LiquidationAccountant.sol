pragma solidity ^0.8.16;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";

import {WithdrawProxy} from "./WithdrawProxy.sol";
import {PublicVault} from "./PublicVault.sol";
import {ILienToken} from "./interfaces/ILienToken.sol";

import {ILienToken} from "./interfaces/ILienToken.sol";
import {Clone} from "clones-with-immutable-args/Clone.sol";

abstract contract LiquidationBase is Clone {
    function underlying() public view returns (address) {
        return _getArgAddress(0);
    }

    function ROUTER() public view returns (address) {
        return _getArgAddress(20);
    }

    function VAULT() public view returns (address) {
        return _getArgAddress(40);
    }

    function LIEN_TOKEN() public view returns (address) {
        return _getArgAddress(60);
    }
}

contract LiquidationAccountant is LiquidationBase {
    using FixedPointMathLib for uint256;
    using SafeTransferLib for ERC20;

    uint256 withdrawProxyAmount;

    uint256 finalAuctionEnd;
    uint256 expected;
    uint256 finalLienId; // when this is deleted, we know the final auction is over

    address withdrawProxy;

    function claim() public {
        require(ILienToken(LIEN_TOKEN()).getLiens(finalLienId).length == 0);

        require(withdrawProxy != address(0), "calculateWithdrawAmount not called at epoch boundary");

        // TODO require liquidation is over?

        uint256 balance = ERC20(underlying()).balanceOf(address(this));
        // would happen if there was no WithdrawProxy for current epoch
        if (withdrawProxyAmount == uint256(0)) {
            ERC20(underlying()).safeTransfer(VAULT(), balance);
        } else {
            ERC20(underlying()).safeTransfer(withdrawProxy, withdrawProxyAmount);

            unchecked {
                balance -= withdrawProxyAmount;
            }

            ERC20(underlying()).safeTransfer(VAULT(), balance);
        }

        uint256 oldYIntercept = PublicVault(VAULT()).getYIntercept();
        PublicVault(VAULT()).setYIntercept(
            oldYIntercept - (expected - ERC20(underlying()).balanceOf(address(this))).mulDivDown(1 - withdrawProxyAmount, 1)
        ); // TODO check, definitely looks wrong
    }

    // pass in withdrawproxy address here instead of constructor in case liquidation called before first marked withdraw
    // called on epoch boundary (maybe rename)
    function calculateWithdrawAmount(address proxy) public {
        withdrawProxy = proxy;
        withdrawProxyAmount =
            WithdrawProxy(withdrawProxy).totalSupply().mulDivDown(1, PublicVault(VAULT()).totalSupply()); // TODO check
    }

    function handleNewLiquidation(uint256 newLienExpectedValue, uint256 id) public {
        require(msg.sender == ROUTER());
        expected += newLienExpectedValue;
        finalLienId = id;
    }
}
