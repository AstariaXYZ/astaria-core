pragma solidity ^0.8.16;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";

import {WithdrawProxy} from "./WithdrawProxy.sol";
import {PublicVault} from "./PublicVault.sol";
import {ILienToken} from "./interfaces/ILienToken.sol";

import {ILienToken} from "./interfaces/ILienToken.sol";

contract LiquidationAccountant {
    using FixedPointMathLib for uint256;
    using SafeTransferLib for ERC20;

    address public immutable WETH;
    // address public immutable WITHDRAW_PROXY;
    address public immutable ASTARIA_ROUTER;
    address public immutable PUBLIC_VAULT;
    address public immutable LIEN_TOKEN;

    uint256 withdrawProxyAmount;

    uint256 finalAuctionEnd;
    uint256 expected;
    uint256 finalLienId; // when this is deleted, we know the final auction is over

    address withdrawProxy;

    constructor(
        address _WETH,
        address _ASTARIA_ROUTER,
        address _PUBLIC_VAULT,
        address _LIEN_TOKEN,
        uint256 AUCTION_WINDOW
    ) {
        WETH = _WETH;
        // WITHDRAW_PROXY = _WITHDRAW_PROXY;
        ASTARIA_ROUTER = _ASTARIA_ROUTER;
        PUBLIC_VAULT = _PUBLIC_VAULT;
        LIEN_TOKEN = _LIEN_TOKEN;
        finalAuctionEnd = block.timestamp + AUCTION_WINDOW;
    }

    // TODO lienId and amount checks? (to make sure no one over-withdraws)
    function claim() public {
        require(block.timestamp > finalAuctionEnd);
        require(ILienToken(LIEN_TOKEN).getLiens(finalLienId).length == 0);


        require(withdrawProxy != address(0), "calculateWithdrawAmount not called at epoch boundary");

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
        // uint256 expected = ILienToken(LIEN_TOKEN).getLien(lienId).amount; // was LienToken.getLien

        uint256 oldYIntercept = PublicVault(PUBLIC_VAULT).getYIntercept();
        PublicVault(PUBLIC_VAULT).setYIntercept(
            oldYIntercept - (expected - ERC20(WETH).balanceOf(address(this))).mulDivDown(1 - withdrawProxyAmount, 1)
        ); // TODO check, definitely wrong
    }

    // pass in withdrawproxy address here instead of constructor in case liquidation called before first marked withdraw
    // called on epoch boundary (maybe rename)
    function calculateWithdrawAmount(address proxy) public {
        withdrawProxy = proxy;
        withdrawProxyAmount =
            WithdrawProxy(withdrawProxy).totalSupply().mulDivDown(1, PublicVault(PUBLIC_VAULT).totalSupply()); // TODO check
    }

    // // TODO if auction windows are universal, track only in immutable uint?
    // function updateAuctionEnd(uint256 auctionWindow) public {
    //     require(msg.sender == ASTARIA_ROUTER);
    //     finalAuctionEnd = block.timestamp + auctionWindow;
    // }

    function handleNewLiquidation(uint256 newLienExpectedValue, uint256 id) public {
        require(msg.sender == ASTARIA_ROUTER);
        expected += newLienExpectedValue;
        finalLienId = id;
    }
}
