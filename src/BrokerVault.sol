pragma solidity ^0.8.13;
import {BrokerImplementation} from "./BrokerImplementation.sol";
import {ERC4626Cloned} from "gpl/ERC4626-Cloned.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {IBrokerRouter} from "./interfaces/IBrokerRouter.sol";

contract BrokerVault is BrokerImplementation, ERC4626Cloned {
    function afterDeposit(uint256 assets, uint256 shares) internal override {
        require(
            block.timestamp < expiration(),
            "afterDeposit: expiration exceeded"
        );
    }

    function totalAssets() public view virtual override returns (uint256) {
        return ERC20(asset()).balanceOf(address(this));
    }

    function _handleAppraiserReward(uint256 amount) internal virtual override {
        (uint256 appraiserRate, uint256 appraiserBase) = IBrokerRouter(router())
            .getAppraiserFee();
        _mint(
            appraiser(),
            ((convertToShares(amount) * appraiserRate) / appraiserBase)
        );
    }
}
