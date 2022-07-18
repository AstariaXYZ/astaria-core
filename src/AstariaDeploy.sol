pragma solidity ^0.8.13;

import {Authority} from "solmate/auth/Auth.sol";
import {MultiRolesAuthority} from "solmate/auth/authorities/MultiRolesAuthority.sol";
import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
import {ERC721} from "openzeppelin/token/ERC721/ERC721.sol";
import {CollateralVault} from "./CollateralVault.sol";
import {LienToken} from "./LienToken.sol";
import {BrokerRouter} from "./BrokerRouter.sol";
import {AuctionHouse} from "gpl/AuctionHouse.sol";
import {SoloBroker} from "./BrokerImplementation.sol";
import {BrokerVault} from "./BrokerVault.sol";
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
        BROKER_ROUTER,
        COLLATERAL_VAULT,
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
        CollateralVault COLLATERAL_VAULT = new CollateralVault(
            MRA,
            address(TRANSFER_PROXY),
            address(LIEN_TOKEN)
        );
        emit Deployed(address(COLLATERAL_VAULT));

        SoloBroker soloImpl = new SoloBroker();
        BrokerVault vaultImpl = new BrokerVault();
        BrokerRouter BROKER_ROUTER = new BrokerRouter(
            MRA,
            address(WETH9),
            address(COLLATERAL_VAULT),
            address(LIEN_TOKEN),
            address(TRANSFER_PROXY),
            address(vaultImpl),
            address(soloImpl)
        );
        //
        AuctionHouse AUCTION_HOUSE = new AuctionHouse(
            address(WETH9),
            address(MRA),
            address(COLLATERAL_VAULT),
            address(LIEN_TOKEN),
            address(TRANSFER_PROXY)
        );
        COLLATERAL_VAULT.file(bytes32("setBondController"), abi.encode(address(BROKER_ROUTER)));
        COLLATERAL_VAULT.file(bytes32("setAuctionHouse"), abi.encode(address(AUCTION_HOUSE)));
        LIEN_TOKEN.file(bytes32("setAuctionHouse"), abi.encode(address(AUCTION_HOUSE)));
        MRA.setRoleCapability(
            uint8(UserRoles.COLLATERAL_VAULT),
            AuctionHouse.createAuction.selector,
            true
        );
        MRA.setRoleCapability(
            uint8(UserRoles.COLLATERAL_VAULT),
            AuctionHouse.endAuction.selector,
            true
        );
        MRA.setRoleCapability(
            uint8(UserRoles.COLLATERAL_VAULT),
            AuctionHouse.cancelAuction.selector,
            true
        );
        MRA.setRoleCapability(
            uint8(UserRoles.BROKER_ROUTER),
            CollateralVault.auctionVault.selector,
            true
        );
        MRA.setRoleCapability(
            uint8(UserRoles.BROKER_ROUTER),
            TRANSFER_PROXY.tokenTransferFrom.selector,
            true
        );
        MRA.setRoleCapability(
            uint8(UserRoles.BROKER_ROUTER),
            TRANSFER_PROXY.tokenTransferFrom.selector,
            true
        );
        MRA.setRoleCapability(
            uint8(UserRoles.AUCTION_HOUSE),
            TRANSFER_PROXY.tokenTransferFrom.selector,
            true
        );
        MRA.setRoleCapability(
            uint8(UserRoles.AUCTION_HOUSE),
            LienToken.stopLiens.selector,
            true
        );
        MRA.setUserRole(
            address(BROKER_ROUTER),
            uint8(UserRoles.BROKER_ROUTER),
            true
        );
        MRA.setUserRole(
            address(COLLATERAL_VAULT),
            uint8(UserRoles.COLLATERAL_VAULT),
            true
        );
        MRA.setUserRole(
            address(AUCTION_HOUSE),
            uint8(UserRoles.AUCTION_HOUSE),
            true
        );

        MRA.setOwner(address(msg.sender));
        BROKER_ROUTER.setOwner(address(msg.sender));
        LIEN_TOKEN.setOwner(address(msg.sender));
        COLLATERAL_VAULT.setOwner(address(msg.sender));
    }
}
