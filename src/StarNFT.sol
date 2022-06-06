// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
pragma experimental ABIEncoderV2;

import {Auth, Authority} from "solmate/auth/Auth.sol";
import {ECDSA} from "openzeppelin/utils/cryptography/ECDSA.sol";
import {IERC721} from "openzeppelin/token/ERC721/IERC721.sol";
import {ERC721} from "openzeppelin/token/ERC721/ERC721.sol";
import {IERC721Receiver} from "openzeppelin/token/ERC721/IERC721Receiver.sol";
import {MerkleProof} from "openzeppelin/utils/cryptography/MerkleProof.sol";
import {IERC1271} from "openzeppelin/interfaces/IERC1271.sol";
import {IAuctionHouse} from "gpl/interfaces/IAuctionHouse.sol";
import "./BrokerRouter.sol";

interface IFlashAction {
    function onFlashAction(bytes calldata data) external returns (bytes32);
}

interface ISecurityHook {
    function getState(address, uint256) external view returns (bytes memory);
}

//return the state this corresponses to
//interface IResolver {
//    function resolve() external returns (bytes32);
//}
//
//contract Resolver is IResolver {}

/*
 TODO: registry proxies for selling across the different networks(opensea)
    - setup the wrapper contract to verify erc1271 signatures so that it can work with looks rare
    - setup cancel auction flow(owner must repay reserve of auction)
 */
contract StarNFT is Auth, ERC721, IERC721Receiver, IStarNFT {
    //    enum LienAction {
    //        ENCUMBER,
    //        UN_ENCUMBER,
    //        SWAP_VAULT
    //    }
    //
    //    //what about a notion of a resolver address that settles lien(external contract)?
    //    struct Lien {
    //        //        address broker;
    //        //        uint256 index;
    //        uint256 lienId;
    //        uint256 amount;
    //        uint256 rate;
    //        uint256 start;
    //        uint256 duration;
    //        //        uint256 resolution; //if 0, unresolved lien, set to resolved 1
    //        //        address resolver; //IResolver contract, interface for sending to beacon proxy
    //        //        interfaceID: bytes4; support for many token types, 777 1155 etc, imagine fractional art being a currency for loans ??
    //        //interfaceId: btyes4; could just be emitted when lien is created, what the interface needed to call this this vs storage
    //    }

    struct Asset {
        address tokenContract;
        uint256 tokenId;
    }

    uint256 lienCounter;
    mapping(uint256 => Asset) starToUnderlying;
    mapping(address => address) public securityHooks;
    mapping(uint256 => Lien[]) liens; // tokenId to bondvaults hash only can move up and down.
    mapping(uint256 => uint256) public starIdToAuctionId;

    bytes32 SUPPORTED_ASSETS_ROOT;

    IAuctionHouse AUCTION_HOUSE;
    BrokerRouter BOND_CONTROLLER;

    event DepositERC721(
        address indexed from,
        address indexed tokenContract,
        uint256 tokenId
    );
    event ReleaseTo(
        address indexed underlyingAsset,
        uint256 assetId,
        address indexed to
    );

    event LienUpdated(LienAction action, bytes lienData);

    error AssetNotSupported(address);
    error AuctionStartedForCollateral(uint256);

    constructor(Authority AUTHORITY_)
        Auth(msg.sender, Authority(AUTHORITY_))
        ERC721("Astaria NFT Wrapper", "Star NFT")
    {
        lienCounter = 1;
    }

    modifier releaseCheck(uint256 assetId) {
        require(
            uint256(0) == liens[assetId].length &&
                starIdToAuctionId[assetId] == uint256(0),
            "must be no liens to call this"
        );
        _;
    }

    modifier onlySupportedAssets(
        address tokenContract_,
        bytes32[] calldata proof_
    ) {
        bytes32 leaf = keccak256(abi.encodePacked(tokenContract_));
        bool isValidLeaf = MerkleProof.verify(
            proof_,
            SUPPORTED_ASSETS_ROOT,
            leaf
        );
        if (!isValidLeaf) revert AssetNotSupported(tokenContract_);
        _;
    }

    modifier onlyOwner(uint256 starId) {
        require(ownerOf(starId) == msg.sender, "onlyOwner: only the owner");
        _;
    }

    // needs reentrancyGuard
    function flashAction(
        IFlashAction receiver,
        uint256 starId,
        bytes calldata data
    ) external onlyOwner(starId) {
        address addr;
        uint256 tokenId;
        (addr, tokenId) = getUnderlyingFromStar(starId);
        IERC721 nft = IERC721(addr);
        // transfer the NFT to the desitnation optimistically

        //look to see if we have a security handler for this asset

        bytes memory preTransferState;

        if (securityHooks[addr] != address(0))
            preTransferState = ISecurityHook(securityHooks[addr]).getState(
                addr,
                tokenId
            );

        nft.transferFrom(address(this), address(receiver), tokenId);
        // invoke the call passed by the msg.sender
        require(
            receiver.onFlashAction(data) ==
                keccak256("FlashAction.onFlashAction"),
            "flashAction: callback failed"
        );

        if (securityHooks[addr] != address(0)) {
            bytes memory postTransferState = ISecurityHook(securityHooks[addr])
                .getState(addr, tokenId);
            require(
                keccak256(preTransferState) == keccak256(postTransferState),
                "flashAction: Data must be the same"
            );
        }

        // validate that the NFT returned after the call
        require(
            nft.ownerOf(tokenId) == address(this),
            "flashAction: NFT not returned"
        );
    }

    function setBondController(address _bondController) external requiresAuth {
        BOND_CONTROLLER = BrokerRouter(_bondController);
    }

    function setSupportedRoot(bytes32 _supportedAssetsRoot)
        external
        requiresAuth
    {
        SUPPORTED_ASSETS_ROOT = _supportedAssetsRoot;
    }

    function setAuctionHouse(address _AUCTION_HOUSE) external requiresAuth {
        AUCTION_HOUSE = IAuctionHouse(_AUCTION_HOUSE);
    }

    function setSecurityHook(address _hookTarget, address _securityHook)
        external
        requiresAuth
    {
        securityHooks[_hookTarget] = _securityHook;
    }

    //LIQUIDATION Operator is a server that runs an EOA to sign messages for auction
    //    function isValidSignature(bytes32 hash_, bytes calldata signature_)
    //        external
    //        view
    //        override
    //        returns (bytes4)
    //    {
    //        // Validate signatures
    //        address recovered = ECDSA.recover(hash_, signature_);
    //        //needs a check to ensure the asset isn't in liquidation(if the order coming through is a buy now order)
    //        if (
    //            recovered == ownerOf(listHashes[hash_]) ||
    //            recovered == liquidationOperator
    //        ) {
    //            return 0x1626ba7e;
    //        } else {
    //            return 0xffffffff;
    //        }
    //    }

    //    function _beforeTokenTransfer(
    //        address from,
    //        address to,
    //        uint256 tokenId
    //    ) internal virtual override {
    //        if (starIdToAuctionId[tokenId] > 0)
    //            revert AuctionStartedForCollateral(tokenId);
    //    }

    function getTotalLiens(uint256 _starId) public view returns (uint256) {
        return liens[_starId].length;
    }

    function getInterest(uint256 collateralVault, uint256 position)
        public
        view
        returns (uint256)
    {
        uint256 delta_t = block.timestamp -
            liens[collateralVault][position].start;
        return (delta_t *
            liens[collateralVault][position].rate *
            liens[collateralVault][position].amount);
    }

    //    function getLiens(uint256 _starId) public view returns (Lien[] memory) {
    //        uint256 lienLength = getTotalLiens(_starId);
    //        address[] memory vaults = new address[](lienLength);
    //        uint256[] memory amounts = new uint256[](lienLength);
    //        uint256[] memory indexes = new uint256[](lienLength);
    //        for (uint256 i = 0; i < lienLength; ++i) {
    //            Lien memory lien = liens[_starId][i];
    //            vaults[i] = ownerOf(lien.lienId);
    //            amounts[i] = lien.amount + getInterest(_starId, i);
    //            indexes[i] = i;
    //        }
    //        return (vaults, amounts, indexes);
    //    }
    function getLiens(uint256 _starId) public view returns (Lien[] memory) {
        return liens[_starId];
    }

    function getLien(uint256 _starId, uint256 position)
        external
        view
        returns (Lien memory)
    {
        return liens[_starId][position];
    }

    function manageLien(LienAction _action, bytes calldata _lienData)
        external
        requiresAuth
    {
        if (_action == LienAction.ENCUMBER) {
            //            address broker;
            //            uint256 position;
            //            uint256 index;
            //            uint256 amount;

            LienActionEncumber memory params = abi.decode(
                _lienData,
                (LienActionEncumber)
            );
            require(
                liens[params.collateralVault].length == params.position,
                "Invalid Lien Position"
            );
            uint256 lienId = uint256(
                keccak256(
                    abi.encodePacked(
                        params.collateralVault,
                        params.position,
                        lienCounter++
                    )
                )
            );
            _mint(params.broker, lienId);
            liens[params.collateralVault].push(
                Lien({
                    lienId: lienId,
                    amount: params.amount,
                    start: block.timestamp,
                    rate: params.rate,
                    duration: params.duration,
                    schedule: params.schedule,
                    buyoutRate: params.buyoutRate
                })
            );
            //            liens[_tokenId].push(
            //                Lien({broker: broker, index: index, amount: amount})
            //            );
        } else if (_action == LienAction.UN_ENCUMBER) {
            LienActionUnEncumber memory params = abi.decode(
                _lienData,
                (LienActionUnEncumber)
            );
            require(
                liens[params.collateralVault][params.position].lienId !=
                    uint256(0),
                "this lien position is not set"
            );
            _burn(liens[params.collateralVault][params.position].lienId);
            delete liens[params.collateralVault][params.position];
        } else if (_action == LienAction.SWAP_VAULT) {
            //            uint256 position;
            //            address broker;
            //            address brokerNew;
            //            uint256 newIndex;
            LienActionSwap memory params = abi.decode(
                _lienData,
                (LienActionSwap)
            );
            //            require(
            //                liens[_tokenId][position].broker == broker,
            //                "this lien position is not set"
            //            );
            //            liens[_tokenId][position].broker = brokerNew;
            //            liens[_tokenId][position].index = newIndex;

            uint256 lienId = liens[params.collateralVault][
                params.outgoing.position
            ].lienId;
            _transfer(ownerOf(lienId), params.incoming.broker, lienId);
        } else {
            revert("Invalid Action");
        }
        emit LienUpdated(_action, _lienData);
    }

    function releaseToAddress(uint256 starTokenId, address releaseTo)
        public
        releaseCheck(starTokenId)
    {
        //check liens
        require(
            msg.sender == ownerOf(starTokenId) ||
                (msg.sender == address(this) &&
                    starIdToAuctionId[starTokenId] == uint256(0)),
            "You don't have permission to call this"
        );
        (address underlyingAsset, uint256 assetId) = getUnderlyingFromStar(
            starTokenId
        );
        IERC721(underlyingAsset).transferFrom(
            address(this),
            releaseTo,
            assetId
        );
        emit ReleaseTo(underlyingAsset, assetId, releaseTo);
    }

    function getUnderlyingFromStar(uint256 starId_)
        public
        view
        returns (address, uint256)
    {
        Asset memory underlying = starToUnderlying[starId_];
        return (underlying.tokenContract, underlying.tokenId);
    }

    function tokenURI(uint256 starTokenId)
        public
        view
        virtual
        override
        returns (string memory)
    {
        (address underlyingAsset, uint256 assetId) = getUnderlyingFromStar(
            starTokenId
        );
        return ERC721(underlyingAsset).tokenURI(assetId);
    }

    function onERC721Received(
        address operator_,
        address from_,
        uint256 tokenId_,
        bytes calldata data_
    ) external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    function depositERC721(
        address depositFor_,
        address tokenContract_,
        uint256 tokenId_,
        bytes32[] calldata proof_
    ) external onlySupportedAssets(tokenContract_, proof_) {
        ERC721(tokenContract_).transferFrom(
            depositFor_,
            address(this),
            tokenId_
        );
        uint256 starId = uint256(
            keccak256(abi.encodePacked(tokenContract_, tokenId_))
        );
        _mint(depositFor_, starId);
        starToUnderlying[starId] = Asset({
            tokenContract: tokenContract_,
            tokenId: tokenId_
        });

        emit DepositERC721(depositFor_, tokenContract_, tokenId_);
    }

    function auctionVault(
        uint256 _tokenId,
        uint256 _reservePrice,
        address liquidator,
        uint256 liquidationFee
    ) external requiresAuth {
        require(
            starIdToAuctionId[_tokenId] == uint256(0),
            "auctionVault: auction already exists"
        );

        (address[] memory vaults, uint256[] memory amounts, ) = getLiens(
            _tokenId
        );

        uint256 auctionId = AUCTION_HOUSE.createAuction(
            _tokenId,
            uint256(7 days),
            _reservePrice,
            vaults,
            amounts,
            liquidator,
            liquidationFee
        );
        starIdToAuctionId[_tokenId] = auctionId;
    }

    function cancelAuction(uint256 _starTokenId)
        external
        onlyOwner(_starTokenId)
    {
        require(
            starIdToAuctionId[_starTokenId] > uint256(0),
            "Auction doesn't exist"
        );
        uint256 auctionId = starIdToAuctionId[_starTokenId];
        (, , , , uint256 reservePrice, ) = AUCTION_HOUSE.getAuctionData(
            auctionId
        );

        AUCTION_HOUSE.cancelAuction(auctionId, msg.sender);
        delete liens[_starTokenId];
        delete starIdToAuctionId[_starTokenId];
    }

    function endAuction(uint256 _tokenId) external {
        require(
            starIdToAuctionId[_tokenId] > uint256(0),
            "Auction doesn't exist"
        );

        address winner = AUCTION_HOUSE.endAuction(starIdToAuctionId[_tokenId]);
        delete liens[_tokenId];
        delete starIdToAuctionId[_tokenId];
        _transfer(ownerOf(_tokenId), winner, _tokenId);
    }
}
