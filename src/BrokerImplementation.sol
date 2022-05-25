pragma solidity ^0.8.13;
import {ITransferProxy} from "./interfaces/ITransferProxy.sol";
import {Initializable} from "openzeppelin/proxy/utils/Initializable.sol";

import {SafeERC20} from "openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";

abstract contract Impl {
    function version() public pure virtual returns (string memory);
}

contract BrokerImplementation is Initializable, Impl {
    ITransferProxy TRANSFER_PROXY;
    using SafeERC20 for IERC20;

    function initialize(address[] memory tokens, address _transferProxy)
        public
        initializer
        onlyInitializing
    {
        TRANSFER_PROXY = ITransferProxy(_transferProxy);
        _transferProxyApprove(tokens);
    }

    function _transferProxyApprove(address[] memory tokens) internal {
        for (uint256 i = 0; i < tokens.length; ++i) {
            IERC20(tokens[i]).safeApprove(
                address(TRANSFER_PROXY),
                type(uint256).max
            );
        }
    }

    function setupApprovals(address[] memory tokens) external reinitializer(0) {
        _transferProxyApprove(tokens);
    }

    function version() public pure virtual override returns (string memory) {
        return "V1";
    }
}
