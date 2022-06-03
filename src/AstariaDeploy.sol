pragma solidity ^0.8.13;

import {Authority} from "solmate/auth/Auth.sol";
import {MultiRolesAuthority} from "solmate/auth/authorities/MultiRolesAuthority.sol";
import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
import {ERC721} from "openzeppelin/token/ERC721/ERC721.sol";
import {StarNFT} from "./StarNFT.sol";
import {BrokerRouter} from "./BrokerRouter.sol";
import {AuctionHouse} from "gpl/AuctionHouse.sol";
import {BrokerImplementation} from "./BrokerImplementation.sol";
import {TransferProxy} from "./TransferProxy.sol";
import "../lib/foundry_eip-4626/src/WEth.sol";

interface IWETH9 is IERC20 {
    function deposit() external payable;

    function withdraw(uint256) external;
}

//TODO:
// - setup helpers that let us put a loan into default
// - setup helpers to repay loans
// - setup helpers to pay loans at their schedule
// - test for interest
// - test auction flow
// - create/cancel/end
contract AstariaDeploy {
    enum UserRoles {
        ADMIN,
        BOND_CONTROLLER,
        WRAPPER,
        AUCTION_HOUSE,
        TRANSFER_PROXY
    }
    event Deployed(address);

    constructor() {
        WEth WETH9 = new WEth("Wrapped Ether Test", "WETH", uint8(18));
        emit Deployed(address(WETH9));
        MultiRolesAuthority MRA = new MultiRolesAuthority(
            address(this),
            Authority(address(0))
        );
        emit Deployed(address(MRA));

        StarNFT STAR_NFT = new StarNFT(MRA);
        emit Deployed(address(STAR_NFT));

        TransferProxy TRANSFER_PROXY = new TransferProxy(MRA);
        emit Deployed(address(TRANSFER_PROXY));

        BrokerImplementation implementation = new BrokerImplementation();
        BrokerRouter BOND_CONTROLLER = new BrokerRouter(
            address(WETH9),
            address(STAR_NFT),
            address(TRANSFER_PROXY),
            address(implementation)
        );
        //
        AuctionHouse AUCTION_HOUSE = new AuctionHouse(
            address(WETH9),
            address(MRA),
            address(STAR_NFT),
            address(TRANSFER_PROXY)
        );
        STAR_NFT.setBondController(address(BOND_CONTROLLER));
        STAR_NFT.setAuctionHouse(address(AUCTION_HOUSE));
        MRA.setRoleCapability(
            uint8(UserRoles.WRAPPER),
            AuctionHouse.createAuction.selector,
            true
        );
        MRA.setRoleCapability(
            uint8(UserRoles.WRAPPER),
            AuctionHouse.endAuction.selector,
            true
        );
        MRA.setRoleCapability(
            uint8(UserRoles.WRAPPER),
            AuctionHouse.cancelAuction.selector,
            true
        );

        MRA.setRoleCapability(
            uint8(UserRoles.BOND_CONTROLLER),
            StarNFT.manageLien.selector,
            true
        );
        MRA.setRoleCapability(
            uint8(UserRoles.BOND_CONTROLLER),
            StarNFT.auctionVault.selector,
            true
        );
        MRA.setRoleCapability(
            uint8(UserRoles.BOND_CONTROLLER),
            TRANSFER_PROXY.tokenTransferFrom.selector,
            true
        );
        MRA.setRoleCapability(
            uint8(UserRoles.AUCTION_HOUSE),
            TRANSFER_PROXY.tokenTransferFrom.selector,
            true
        );
        MRA.setUserRole(
            address(BOND_CONTROLLER),
            uint8(UserRoles.BOND_CONTROLLER),
            true
        );
        MRA.setUserRole(address(STAR_NFT), uint8(UserRoles.WRAPPER), true);
        MRA.setUserRole(
            address(AUCTION_HOUSE),
            uint8(UserRoles.AUCTION_HOUSE),
            true
        );

        MRA.setOwner(address(msg.sender));
    }
}
