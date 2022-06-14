pragma solidity ^0.8.13;
import {BrokerImplementation} from "./BrokerImplementation.sol";
import {ERC4626Cloned} from "gpl/ERC4626-Cloned.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";

contract BrokerVault is ERC4626Cloned, BrokerImplementation {
    function afterDeposit(uint256 assets, uint256 shares) internal override {
        require(block.timestamp < expiration(), "deposit: expiration exceeded");
        _mint(appraiser(), (shares * 2) / 100);
    }

    function totalAssets() public view virtual override returns (uint256) {
        return ERC20(asset()).balanceOf(address(this));
    }
}
