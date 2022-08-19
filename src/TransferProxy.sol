pragma solidity ^0.8.16;

import {Auth, Authority} from "solmate/auth/Auth.sol";
import {SafeTransferLib, ERC20} from "solmate/utils/SafeTransferLib.sol";
import {ITransferProxy} from "gpl/interfaces/ITransferProxy.sol";

contract TransferProxy is Auth, ITransferProxy {
    using SafeTransferLib for ERC20;

    constructor(Authority _AUTHORITY) Auth(address(msg.sender), _AUTHORITY) {}

    function tokenTransferFrom(address token, address from, address to, uint256 amount) external requiresAuth {
        ERC20(token).safeTransferFrom(from, to, amount);
    }
}
