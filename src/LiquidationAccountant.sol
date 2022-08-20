pragma solidity ^0.8.16;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";

import {WithdrawProxy} from "./WithdrawProxy.sol";
import {PublicVault} from "./PublicVault.sol";

import {ILienToken} from "./interfaces/ILienToken.sol";

contract LiquidationAccountant {
    using FixedPointMathLib for uint256;
    using SafeTransferLib for ERC20;

    address public immutable WETH;
    // address public immutable WITHDRAW_PROXY;
    address public immutable PUBLIC_VAULT;
    address public immutable LIEN_TOKEN;

    uint256 withdrawProxyAmount;

    constructor(address _WETH, address _PUBLIC_VAULT, address _LIEN_TOKEN) {
        WETH = _WETH;
        // WITHDRAW_PROXY = _WITHDRAW_PROXY;
        PUBLIC_VAULT = _PUBLIC_VAULT;
        LIEN_TOKEN = _LIEN_TOKEN;
    }

    // TODO lienId and amount checks? (to make sure no one over-withdraws)
    function claim(uint256 lienId, uint256 amount, address withdrawProxy) public {
        // TODO require liquidation is over?

        uint256 balance = ERC20(WETH).balanceOf(address(this));
        // would happen if there was no WithdrawProxy for current epoch
        if (withdrawProxyAmount == uint256(0)) {
            ERC20(WETH).safeTransfer(PUBLIC_VAULT, balance);
        } else {
            ERC20(WETH).safeTransfer(withdrawProxy, withdrawProxyAmount);

            // TODO fix?
            balance -= withdrawProxyAmount;

            ERC20(WETH).safeTransfer(PUBLIC_VAULT, balance);
        }

        // update y-intercept (old completeLiquidation() flow)
        uint256 expected = ILienToken(LIEN_TOKEN).getLien(lienId).amount; // was LienToken.getLien

        uint256 oldYIntercept = PublicVault(PUBLIC_VAULT).getYIntercept();
        PublicVault(PUBLIC_VAULT).setYIntercept((expected - amount).mulDivDown(1 - withdrawProxyAmount, 1)); // TODO check, definitely wrong
    }

    // pass in withdrawproxy address here instead of constructor in case liquidation called before first marked withdraw
    function calculateWithdrawAmount(address withdrawProxy) public {
        withdrawProxyAmount =
            WithdrawProxy(withdrawProxy).totalSupply().mulDivDown(1, PublicVault(PUBLIC_VAULT).totalSupply()); // TODO check
    }
}
