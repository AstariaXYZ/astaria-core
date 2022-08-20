pragma solidity ^0.8.16;

import {Authority} from "solmate/auth/Auth.sol";
import {MultiRolesAuthority} from "solmate/auth/authorities/MultiRolesAuthority.sol";
import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
import {ERC721} from "solmate/tokens/ERC721.sol";
import {CollateralToken} from "./CollateralToken.sol";
import {LienToken} from "./LienToken.sol";
import {AstariaRouter} from "./AstariaRouter.sol";
import {AuctionHouse} from "gpl/AuctionHouse.sol";
import {Vault, PublicVault} from "./PublicVault.sol";
import {TransferProxy} from "./TransferProxy.sol";
import {WEth} from "foundry_eip-4626/WEth.sol";

// import {WEth} from "./WEth.sol";

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
        ASTARIA_ROUTER,
        COLLATERAL_TOKEN,
        LIEN_TOKEN,
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

        TransferProxy TRANSFER_PROXY = new TransferProxy(MRA);
        LienToken LIEN_TOKEN = new LienToken(
            MRA,
            address(TRANSFER_PROXY),
            address(WETH9)
        );
        emit Deployed(address(TRANSFER_PROXY));
        CollateralToken COLLATERAL_TOKEN = new CollateralToken(
            MRA,
            address(TRANSFER_PROXY),
            address(LIEN_TOKEN)
        );
        emit Deployed(address(COLLATERAL_TOKEN));

        Vault soloImpl = new Vault();
        PublicVault vaultImpl = new PublicVault();
        AstariaRouter ASTARIA_ROUTER = new AstariaRouter(
            MRA,
            address(WETH9),
            address(COLLATERAL_TOKEN),
            address(LIEN_TOKEN),
            address(TRANSFER_PROXY),
            address(vaultImpl),
            address(soloImpl)
        );
        //
        AuctionHouse AUCTION_HOUSE = new AuctionHouse(
            address(WETH9),
            address(MRA),
            address(COLLATERAL_TOKEN),
            address(LIEN_TOKEN),
            address(TRANSFER_PROXY)
        );
        COLLATERAL_TOKEN.file(bytes32("setAstariaRouter"), abi.encode(address(ASTARIA_ROUTER)));
        COLLATERAL_TOKEN.file(bytes32("setAuctionHouse"), abi.encode(address(AUCTION_HOUSE)));
        LIEN_TOKEN.file(bytes32("setAuctionHouse"), abi.encode(address(AUCTION_HOUSE)));
        MRA.setRoleCapability(uint8(UserRoles.COLLATERAL_TOKEN), AuctionHouse.createAuction.selector, true);
        MRA.setRoleCapability(uint8(UserRoles.COLLATERAL_TOKEN), AuctionHouse.endAuction.selector, true);
        MRA.setRoleCapability(uint8(UserRoles.COLLATERAL_TOKEN), AuctionHouse.cancelAuction.selector, true);
        MRA.setRoleCapability(uint8(UserRoles.ASTARIA_ROUTER), CollateralToken.auctionVault.selector, true);
        MRA.setRoleCapability(uint8(UserRoles.ASTARIA_ROUTER), TRANSFER_PROXY.tokenTransferFrom.selector, true);
        MRA.setRoleCapability(uint8(UserRoles.ASTARIA_ROUTER), TRANSFER_PROXY.tokenTransferFrom.selector, true);
        MRA.setRoleCapability(uint8(UserRoles.AUCTION_HOUSE), TRANSFER_PROXY.tokenTransferFrom.selector, true);
        MRA.setRoleCapability(uint8(UserRoles.AUCTION_HOUSE), LienToken.stopLiens.selector, true);
        MRA.setUserRole(address(ASTARIA_ROUTER), uint8(UserRoles.ASTARIA_ROUTER), true);
        MRA.setUserRole(address(COLLATERAL_TOKEN), uint8(UserRoles.COLLATERAL_TOKEN), true);
        MRA.setUserRole(address(AUCTION_HOUSE), uint8(UserRoles.AUCTION_HOUSE), true);

        MRA.setOwner(address(msg.sender));
        ASTARIA_ROUTER.setOwner(address(msg.sender));
        LIEN_TOKEN.setOwner(address(msg.sender));
        COLLATERAL_TOKEN.setOwner(address(msg.sender));
    }
}
