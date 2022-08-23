pragma solidity ^0.8.16;

import {Auth, Authority} from "solmate/auth/Auth.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {ERC20Cloned, IBase} from "gpl/ERC4626-Cloned.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {ITransferProxy} from "gpl/interfaces/ITransferProxy.sol";

contract WithdrawProxy is ERC20Cloned {
    using SafeTransferLib for ERC20;

    function name() public view override (IBase) returns (string memory) {
        return string(abi.encodePacked("AST-WithdrawVault-", ERC20(underlying()).symbol()));
    }

    function symbol() public view override (IBase) returns (string memory) {
        return string(abi.encodePacked("AST-W", owner(), "-", ERC20(underlying()).symbol()));
    }

    function withdraw(uint256 amount) public {
        require(balanceOf[msg.sender] >= amount, "insufficient balance");
        _burn(msg.sender, amount);
        ERC20(underlying()).safeTransfer(
            msg.sender, (amount / totalSupply) * ERC20(underlying()).balanceOf(address(this))
        );
    }

    function mint(address receiver, uint256 shares) public virtual {
        require(msg.sender == owner(), "only owner can mint");
        _mint(receiver, shares);
    }
}
