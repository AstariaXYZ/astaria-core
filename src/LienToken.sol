// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
pragma experimental ABIEncoderV2;

import {Auth, Authority} from "solmate/auth/Auth.sol";
import {IERC721} from "openzeppelin/token/ERC721/IERC721.sol";
import {ERC721} from "openzeppelin/token/ERC721/ERC721.sol";
import {IERC721Receiver} from "openzeppelin/token/ERC721/IERC721Receiver.sol";
import {MerkleProof} from "openzeppelin/utils/cryptography/MerkleProof.sol";
import {IERC1271} from "openzeppelin/interfaces/IERC1271.sol";
import {IAuctionHouse} from "gpl/interfaces/IAuctionHouse.sol";
import {ITransferProxy} from "gpl/interfaces/ITransferProxy.sol";
import {ILienToken} from "./interfaces/ILienToken.sol";
import {IBrokerRouter} from "./interfaces/IBrokerRouter.sol";
import {BrokerImplementation} from "./BrokerImplementation.sol";
import {ValidateTerms} from "./libraries/ValidateTerms.sol";

contract TransferAgent {
    address public immutable WETH;
    ITransferProxy public immutable TRANSFER_PROXY;

    constructor(address _TRANSFER_PROXY, address _WETH) {
        TRANSFER_PROXY = ITransferProxy(_TRANSFER_PROXY);
        WETH = _WETH;
    }
}

contract LienToken is Auth, TransferAgent, ERC721, ILienToken {
    using ValidateTerms for IBrokerRouter.Terms;
    uint256 public lienCounter;
    IAuctionHouse public AUCTION_HOUSE;
    mapping(uint256 => Lien) public lienData;
    mapping(uint256 => uint256[]) public liens;
    event NewLien(uint256 lienId);
    event BuyoutLien(address indexed buyer, uint256 lienId, uint256 buyout);

    constructor(
        Authority _AUTHORITY,
        address _TRANSFER_PROXY,
        address _WETH
    )
        Auth(address(msg.sender), _AUTHORITY)
        TransferAgent(_TRANSFER_PROXY, _WETH)
        ERC721("Astaria Lien Token", "Lien")
    {
        lienCounter = 1;
    }

    function setAuctionHouse(address _AUCTION_HOUSE) external requiresAuth {
        AUCTION_HOUSE = IAuctionHouse(_AUCTION_HOUSE);
    }

    function buyoutLien(ILienToken.LienActionBuyout calldata params) external {
        (uint256 owed, uint256 buyout) = getBuyout(
            params.incoming.collateralVault,
            params.incoming.position
        );

        uint256 lienId = liens[params.incoming.collateralVault][
            params.incoming.position
        ];
        TRANSFER_PROXY.tokenTransferFrom(
            address(WETH),
            address(msg.sender),
            ownerOf(lienId),
            uint256(owed + buyout)
        );

        validateBuyoutTerms(params.incoming);
        //todo: ensure rates and duration is better;
        require(params.incoming.rate <= lienData[lienId].rate, "Invalid Rate");
        require(
            params.incoming.duration <= type(uint256).max,
            "Invalid Duration"
        ); //TODO: set this check to be proper with a min DURATION
        lienData[lienId].last = uint32(block.timestamp);
        lienData[lienId].rate = uint32(params.incoming.rate);
        lienData[lienId].duration = uint32(params.incoming.duration);
        //so, something about brokers
        lienData[lienId].broker = params.incoming.broker;

        //TODO: emit event, should we send to sender or broker on buyout?
        _transfer(ownerOf(lienId), address(params.receiver), lienId);
    }

    function validateTerms(IBrokerRouter.Terms memory params)
        public
        view
        returns (bool)
    {
        uint256 lienId = liens[params.collateralVault][params.position];

        return
            params.validateTerms(
                BrokerImplementation(lienData[lienId].broker).vaultHash()
            );
    }

    function validateBuyoutTerms(IBrokerRouter.Terms memory params)
        public
        pure
        returns (bool)
    {
        return
            params.validateTerms(
                BrokerImplementation(params.broker).vaultHash()
            );
    }

    function _verifyMerkleBranch(
        bytes32[] memory proof,
        bytes32 leaf,
        bytes32 root
    ) internal pure returns (bool) {
        bool isValidLeaf = MerkleProof.verify(proof, root, leaf);
        return isValidLeaf;
    }

    function getInterest(uint256 collateralVault, uint256 position)
        public
        view
        returns (uint256)
    {
        uint256 lien = liens[collateralVault][position];
        if (!lienData[lien].active) return uint256(0);
        return _getInterest(lienData[lien]);
    }

    function _getOwed(Lien memory lien) internal view returns (uint256) {
        return lien.amount += _getInterest(lien);
    }

    function _getInterest(Lien memory lien) internal view returns (uint256) {
        uint256 delta_t = uint32(block.timestamp) - lien.last;
        return (delta_t * uint256(lien.rate) * lien.amount);
    }

    function stopLiens(uint256 collateralVault)
        external
        requiresAuth
        returns (
            uint256 reserve,
            uint256[] memory amounts,
            uint256[] memory lienIds
        )
    {
        reserve = 0;
        lienIds = liens[collateralVault];
        amounts = new uint256[](liens[collateralVault].length);
        for (uint256 i = 0; i < lienIds.length; ++i) {
            ILienToken.Lien storage lien = lienData[lienIds[i]];
            unchecked {
                lien.amount += _getInterest(lien);
                reserve += lien.amount;
            }
            amounts[i] = lien.amount;
            lien.active = false;
        }
    }

    function createLien(ILienToken.LienActionEncumber calldata params)
        external
        requiresAuth
        returns (uint256 lienId)
    {
        require(
            liens[params.terms.collateralVault].length == params.terms.position,
            "invalid position request"
        );

        // require that the auction is not under way
        //                require();
        lienId = uint256(
            keccak256(
                abi.encodePacked(
                    params.terms.collateralVault,
                    params.terms.position,
                    lienCounter++
                )
            )
        );
        uint256 buyout = BrokerImplementation(params.terms.broker).buyout();
        lienData[lienId] = Lien({
            amount: params.amount,
            broker: params.terms.broker,
            active: true,
            rate: uint32(params.amount),
            last: uint32(block.timestamp),
            start: uint32(block.timestamp),
            duration: uint32(params.terms.duration),
            schedule: uint32(params.terms.schedule)
        });

        liens[params.terms.collateralVault].push(lienId);
        _mint(params.terms.broker, lienId);
        emit NewLien(lienId);
    }

    function removeLiens(uint256 collateralVault) external requiresAuth {
        delete liens[collateralVault];
    }

    function getLiens(uint256 _starId) public view returns (uint256[] memory) {
        return liens[_starId];
    }

    function getLien(uint256 lienId) external view returns (Lien memory) {
        return lienData[lienId];
    }

    function getLien(uint256 collateralVault, uint256 position)
        public
        view
        returns (Lien memory)
    {
        uint256 lienId = liens[collateralVault][position];
        return lienData[lienId];
    }

    function getBuyout(uint256 collateralVault, uint256 index)
        public
        view
        returns (uint256, uint256)
    {
        Lien memory lien = getLien(collateralVault, index);
        uint256 owed = _getOwed(lien);

        return (
            owed,
            owed + (owed * BrokerImplementation(lien.broker).buyout()) / 100
        );
    }

    function makePayment(uint256 collateralVault, uint256 paymentAmount)
        external
    {
        // calculates interest here and apply it to the loan
        uint256[] memory openLiens = liens[collateralVault];
        for (uint256 i = 0; i < openLiens.length; ++i) {
            paymentAmount = _payment(collateralVault, i, paymentAmount);
            //            Lien storage l = lienData[openLiens[i]];
            //            uint256 maxPayment = _getOwed(l);
            //            if (maxPayment >= paymentAmount) {
            //                paymentAmount = maxPayment;
            //                delete liens[collateralVault][i];
            //            } else {
            //                l.amount -= paymentAmount;
            //                l.last = uint32(block.timestamp);
            //            }
            //            if (paymentAmount > 0) {
            //                address owner = ownerOf(openLiens[i]);
            //
            //                TRANSFER_PROXY.tokenTransferFrom(
            //                    address(WETH),
            //                    address(msg.sender),
            //                    owner,
            //                    paymentAmount
            //                );
            //            }
        }
    }

    function _payment(
        uint256 collateralVault,
        uint256 position,
        uint256 paymentAmount
    ) internal returns (uint256) {
        if (paymentAmount == uint256(0)) return uint256(0);
        Lien storage lien = lienData[liens[collateralVault][position]];
        uint256 maxPayment = _getOwed(lien);
        address owner = ownerOf(liens[collateralVault][position]);

        if (maxPayment < paymentAmount) {
            lien.amount -= paymentAmount;
            lien.last = uint32(block.timestamp);
        } else {
            paymentAmount = maxPayment;
            delete liens[collateralVault][position];
        }
        TRANSFER_PROXY.tokenTransferFrom(
            address(WETH),
            address(msg.sender),
            owner,
            paymentAmount
        );

        return paymentAmount;
    }
}
