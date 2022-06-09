pragma solidity ^0.8.13;
import {BrokerImplementation, IBroker} from "./BrokerImplementation.sol";
import {ERC4626Cloned} from "gpl/ERC4626-Cloned.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";

contract BrokerVault is ERC4626Cloned, BrokerImplementation {
    //    bytes32 internal constant BROKER_SLOT = bytes32(uint256(9999) - 1);
    //
    //            bytes32(uint256(keccak256("broker.implementation")) - 1);
    //
    //    function broker() external view returns (BrokerImplementation) {
    //        return BrokerImplementation(_getBrokerSlot(BROKER_SLOT));
    //    }

    struct AddressSlot {
        address value;
    }

    function _getBrokerSlot(bytes32 bSlot) internal view returns (address) {
        AddressSlot storage b;
        assembly {
            b.slot := bSlot
        }

        return b.value;
    }

    function afterDeposit(uint256 assets, uint256 shares) internal override {
        require(block.timestamp < expiration(), "deposit: expiration exceeded");
        _mint(appraiser(), (shares * 2) / 100);
    }

    function totalAssets() public view virtual override returns (uint256) {
        return ERC20(asset()).balanceOf(address(this));
    }
}
