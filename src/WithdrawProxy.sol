pragma solidity ^0.8.13;

import {Auth, Authority} from "solmate/auth/Auth.sol";
// import {SafeTransferLib, ERC20} from "solmate/utils/SafeTransferLib.sol";
// import {ERC20} from "solmate/tokens/ERC20.sol";
// import {ERC20} from "openzeppelin/token/ERC20/ERC20.sol";

import {ERC20Cloned} from "gpl/ERC4626-Cloned.sol";

import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
import {ITransferProxy} from "gpl/interfaces/ITransferProxy.sol";

contract WithdrawProxy is ERC20Cloned {
    // IERC20 public immutable WETH;

    // constructor(address _WETH) {
    //     WETH = IERC20(_WETH);
    // }

    // constructor(string memory name_, string memory symbol_) {

    // }

    function withdraw(uint256 amount) public {
        require(balanceOf[msg.sender] >= amount, "insufficient balance");
        _burn(msg.sender, amount);
        // WETH.transfer(
        //     msg.sender,
        //     (amount / totalSupply) * WETH.balanceOf(address(this))
        // );
    }

    function mint(address receiver, uint256 shares)
        public
        virtual
        returns (uint256 assets)
    {
        // assets = previewMint(shares); // No need to check for rounding error, previewMint rounds up.

        // // Need to transfer before minting or ERC777s could reenter.
        // ERC20(asset()).safeTransferFrom(msg.sender, address(this), assets);

        _mint(receiver, shares);

        // emit Deposit(msg.sender, receiver, assets, shares);

        // afterDeposit(assets, shares);
    }
}
