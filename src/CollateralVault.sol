// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

pragma experimental ABIEncoderV2;

import {Auth, Authority} from "solmate/auth/Auth.sol";
import {IERC721} from "openzeppelin/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "openzeppelin/token/ERC721/IERC721Receiver.sol";
import {ERC721} from "openzeppelin/token/ERC721/ERC721.sol";
import {MerkleProof} from "openzeppelin/utils/cryptography/MerkleProof.sol";
import {IERC1271} from "openzeppelin/interfaces/IERC1271.sol";
import {IAuctionHouse} from "gpl/interfaces/IAuctionHouse.sol";
import {ITransferProxy} from "gpl/interfaces/ITransferProxy.sol";
import {ICollateralVault} from "./interfaces/ICollateralVault.sol";
import {IBrokerRouter} from "./interfaces/IBrokerRouter.sol";
import {ILienToken} from "./interfaces/ILienToken.sol";
import {BrokerImplementation} from "./BrokerImplementation.sol";
import {
    SeaportInterface, Order
} from "seaport/interfaces/SeaportInterface.sol";
import {ConduitControllerInterface} from
    "seaport/interfaces/ConduitControllerInterface.sol";
import {IERC1155Receiver} from "openzeppelin/token/ERC1155/IERC1155Receiver.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {Bytes32AddressLib} from "solmate/utils/Bytes32AddressLib.sol";

interface IFlashAction {
    function onFlashAction(bytes calldata data) external returns (bytes32);
}

interface ISecurityHook {
    function getState(address, uint256) external view returns (bytes memory);
}

contract CollateralVault is
    Auth,
    ERC721,
    IERC721Receiver,
    ICollateralVault,
    IERC1155Receiver
{
    using SafeTransferLib for ERC20;

    struct Asset {
        address tokenContract;
        uint256 tokenId;
    }

    mapping(uint256 => Asset) idToUnderlying;
    mapping(address => address) public securityHooks;

    ITransferProxy public TRANSFER_PROXY;
    ILienToken public LIEN_TOKEN;
    IAuctionHouse public AUCTION_HOUSE;
    IBrokerRouter public BROKER_ROUTER;
    SeaportInterface public SEAPORT;
    ConduitControllerInterface public CONDUIT_CONTROLLER;
    address public CONDUIT;
    bytes32 public CONDUIT_KEY;

    event DepositERC721(
        address indexed from, address indexed tokenContract, uint256 tokenId
    );
    event ReleaseTo(
        address indexed underlyingAsset, uint256 assetId, address indexed to
    );

    error AssetNotSupported(address);
    error AuctionStartedForCollateral(uint256);

    constructor(
        Authority AUTHORITY_,
        address TRANSFER_PROXY_,
        address LIEN_TOKEN_
    )
        Auth(msg.sender, Authority(AUTHORITY_))
        ERC721("Astaria Collateral Vault", "VAULT")
    {
        TRANSFER_PROXY = ITransferProxy(TRANSFER_PROXY_);
        LIEN_TOKEN = ILienToken(LIEN_TOKEN_);
    }

    function file(bytes32 what, bytes calldata data) external requiresAuth {
        if (what == "CONDUIT") {
            address addr = abi.decode(data, (address));
            CONDUIT = addr;
        } else if (what == "CONDUIT_KEY") {
            bytes32 value = abi.decode(data, (bytes32));
            CONDUIT_KEY = value;
        } else if (what == "setupSeaport") {
            // or SEAPORT
            address addr = abi.decode(data, (address));
            SEAPORT = SeaportInterface(addr);
            (,, address conduitController) = SEAPORT.information();
            CONDUIT_KEY = Bytes32AddressLib.fillLast12Bytes(address(this));
            CONDUIT_CONTROLLER = ConduitControllerInterface(conduitController);
            CONDUIT =
                CONDUIT_CONTROLLER.createConduit(CONDUIT_KEY, address(this));
        } else if (what == "setBondController") {
            address addr = abi.decode(data, (address));
            BROKER_ROUTER = IBrokerRouter(addr);
        } else if (what == "setAuctionHouse") {
            address addr = abi.decode(data, (address));
            AUCTION_HOUSE = IAuctionHouse(addr);
        } else if (what == "setSecurityHook") {
            (address target, address hook) =
                abi.decode(data, (address, address));
            securityHooks[target] = hook;
        } else {
            revert("unsupported/file");
        }
    }

    modifier releaseCheck(uint256 collateralVault) {
        require(
            uint256(0) == LIEN_TOKEN.getLiens(collateralVault).length
                && !AUCTION_HOUSE.auctionExists(collateralVault),
            "must be no liens or auctions to call this"
        );
        _;
    }

    modifier onlyOwner(uint256 collateralVault) {
        require(
            ownerOf(collateralVault) == msg.sender, "onlyOwner: only the owner"
        );
        _;
    }

    //TODO: scrap this for now
    function listUnderlyingOnSeaport(
        uint256 collateralVault,
        Order memory listingOrder
    )
        external
        onlyOwner(collateralVault)
    {
        //    ItemType itemType;
        //    address token;
        //    uint256 identifierOrCriteria;
        //    uint256 startAmount;
        //    uint256 endAmount;
        //    address payable recipient;
        (address underlyingTokenContract, uint256 underlyingId) =
            getUnderlying(collateralVault);
        //ItemType itemType;
        //    address token;
        //    uint256 identifierOrCriteria;
        //    uint256 startAmount;
        //    uint256 endAmount;
        //}

        //2 is ERC721
        require(
            uint8(listingOrder.parameters.offer[0].itemType) == uint8(2),
            "must be type 2"
        );
        require(
            listingOrder.parameters.offer[0].token == underlyingTokenContract,
            "must be the correct token type"
        );
        require(
            listingOrder.parameters.offer[0].identifierOrCriteria == underlyingId,
            "must be the correct token type"
        );
        require(
            isValidatorAsset(listingOrder.parameters.consideration[2].token),
            "must be a validator asset"
        );
        require(
            listingOrder.parameters.offer.length == 1,
            "can only list one item at a time"
        );

        require(
            address(this) == listingOrder.parameters.consideration[2].recipient
        );
        //get total Debt and ensure its being sold for more than that
        uint256 totalDebt = LIEN_TOKEN.getTotalDebtForCollateralVault(
            collateralVault, listingOrder.parameters.endTime
        );

        require(
            listingOrder.parameters.offer[0].startAmount >= totalDebt
                && listingOrder.parameters.offer[0].startAmount
                    == listingOrder.parameters.offer[0].endAmount,
            "startAmount and endAmount must match"
        );

        require(
            listingOrder.parameters.conduitKey == CONDUIT_KEY,
            "must use our conduit for transfers"
        );
        require(
            listingOrder.parameters.zone == address(this),
            "must use our conduit for transfers"
        );
        //    address offerer; // 0x00
        //    address zone; // 0x20
        //    OfferItem[] offer; // 0x40
        //    ConsiderationItem[] consideration; // 0x60
        //    OrderType orderType; // 0x80
        //    uint256 startTime; // 0xa0
        //    uint256 endTime; // 0xc0
        //    bytes32 zoneHash; // 0xe0
        //    uint256 salt; // 0x100
        //    bytes32 conduitKey; // 0x120
        //    uint256 totalOriginalConsiderationItems;

        IERC721(underlyingTokenContract).approve(CONDUIT, underlyingId);
        Order[] memory listings = new Order[](1);
        listings[0] = listingOrder;
        SEAPORT.validate(listings);
    }

    function flashAction(
        IFlashAction receiver,
        uint256 collateralVault,
        bytes calldata data
    )
        external
        onlyOwner(collateralVault)
    {
        address addr;
        uint256 tokenId;
        (addr, tokenId) = getUnderlying(collateralVault);
        IERC721 nft = IERC721(addr);
        // transfer the NFT to the desitnation optimistically

        //look to see if we have a security handler for this asset

        bytes memory preTransferState;

        if (securityHooks[addr] != address(0)) {
            preTransferState =
                ISecurityHook(securityHooks[addr]).getState(addr, tokenId);
        }

        nft.transferFrom(address(this), address(receiver), tokenId);
        // invoke the call passed by the msg.sender
        require(
            receiver.onFlashAction(data) == keccak256("FlashAction.onFlashAction"),
            "flashAction: callback failed"
        );

        if (securityHooks[addr] != address(0)) {
            bytes memory postTransferState =
                ISecurityHook(securityHooks[addr]).getState(addr, tokenId);
            require(
                keccak256(preTransferState) == keccak256(postTransferState),
                "flashAction: Data must be the same"
            );
        }

        // validate that the NFT returned after the call
        require(
            nft.ownerOf(tokenId) == address(this), "flashAction: NFT not returned"
        );
    }

    function isValidatorAsset(address incomingAsset)
        public
        view
        returns (bool)
    {
        //todo setup handling validator assets
        return true;
    }

    function onERC1155BatchReceived(
        address operator,
        address from,
        uint256[] calldata ids,
        uint256[] calldata values,
        bytes calldata data
    )
        external
        returns (bytes4)
    {
        require(ids.length == values.length);
        for (uint256 i = 0; i < ids.length; ++i) {
            _onERC1155Received(operator, from, ids[i], values[i], data);
        }
        return IERC1155Receiver.onERC1155BatchReceived.selector;
    }

    function _onERC1155Received(
        address operator,
        address from,
        uint256 id,
        uint256 value,
        bytes calldata data
    )
        internal
    {
        require(
            isValidatorAsset(msg.sender),
            "address must be from a validator contract we care about"
        );
        ILienToken.Lien memory lien = LIEN_TOKEN.getLien(id, uint256(0));

        require(
            ERC20(lien.token).balanceOf(address(this)) >= value,
            "not enough balance to make this payment"
        );
        uint256 totalDebt = LIEN_TOKEN.getTotalDebtForCollateralVault(id);

        require(value >= totalDebt, "cannot be less than total obligation");
        ERC20(lien.token).safeApprove(address(TRANSFER_PROXY), totalDebt);
        LIEN_TOKEN.makePayment(id, value);

        if (value > totalDebt) {
            ERC20(lien.token).safeTransfer(ownerOf(id), value - totalDebt);
        }

        delete idToUnderlying[id];
        _burn(id);
    }

    function onERC1155Received(
        address operator,
        address from,
        uint256 id,
        uint256 value,
        bytes calldata data
    )
        external
        returns (bytes4)
    {
        _onERC1155Received(operator, from, id, value, data);
        return IERC1155Receiver.onERC1155Received.selector;
    }

    function releaseToAddress(uint256 collateralVault, address releaseTo)
        public
        releaseCheck(collateralVault)
    {
        //check liens
        require(
            msg.sender == ownerOf(collateralVault),
            "You don't have permission to call this"
        );
        _releaseToAddress(collateralVault, releaseTo);
    }

    function _releaseToAddress(uint256 collateralVault, address releaseTo)
        internal
    {
        (address underlyingAsset, uint256 assetId) =
            getUnderlying(collateralVault);
        IERC721(underlyingAsset).transferFrom(address(this), releaseTo, assetId);
        delete idToUnderlying[collateralVault];
        emit ReleaseTo(underlyingAsset, assetId, releaseTo);
    }

    function getUnderlying(uint256 collateralVault)
        public
        view
        returns (address, uint256)
    {
        Asset memory underlying = idToUnderlying[collateralVault];
        return (underlying.tokenContract, underlying.tokenId);
    }

    function tokenURI(uint256 collateralVault)
        public
        view
        virtual
        override
        returns (string memory)
    {
        (address underlyingAsset, uint256 assetId) =
            getUnderlying(collateralVault);
        return ERC721(underlyingAsset).tokenURI(assetId);
    }

    function onERC721Received(
        address operator_,
        address from_,
        uint256 tokenId_,
        bytes calldata data_
    )
        external
        pure
        override
        returns (bytes4)
    {
        return IERC721Receiver.onERC721Received.selector;
    }

    function depositERC721(
        address depositFor_,
        address tokenContract_,
        uint256 tokenId_
    )
        external
    {
        uint256 collateralVault =
            uint256(keccak256(abi.encodePacked(tokenContract_, tokenId_)));

        ERC721(tokenContract_).safeTransferFrom(
            depositFor_, address(this), tokenId_, ""
        );

        _mint(depositFor_, collateralVault);
        idToUnderlying[collateralVault] =
            Asset({tokenContract: tokenContract_, tokenId: tokenId_});

        emit DepositERC721(depositFor_, tokenContract_, tokenId_);
    }

    function auctionVault(
        uint256 collateralVault,
        address liquidator,
        uint256 liquidationFee
    )
        external
        requiresAuth
        returns (uint256 reserve)
    {
        require(
            !AUCTION_HOUSE.auctionExists(collateralVault),
            "auctionVault: auction already exists"
        );
        reserve = AUCTION_HOUSE.createAuction(
            collateralVault,
            uint256(7 days), //todo make htis a param we can change
            liquidator,
            liquidationFee
        );
    }

    function cancelAuction(uint256 tokenId) external onlyOwner(tokenId) {
        require(AUCTION_HOUSE.auctionExists(tokenId), "Auction doesn't exist");

        AUCTION_HOUSE.cancelAuction(tokenId, msg.sender);
    }

    function endAuction(uint256 tokenId) external {
        require(AUCTION_HOUSE.auctionExists(tokenId), "Auction doesn't exist");

        address winner = AUCTION_HOUSE.endAuction(tokenId);
        //        _transfer(ownerOf(tokenId), winner, tokenId);
        _releaseToAddress(tokenId, winner);
    }
}
