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
import {ICollateralVault} from "./interfaces/ICollateralVault.sol";
import {ILienToken} from "./interfaces/ILienToken.sol";
import {IBrokerRouter, BrokerRouter} from "./BrokerRouter.sol";
import {BrokerImplementation} from "./BrokerImplementation.sol";

contract TransferAgent {
    address public immutable WETH;
    ITransferProxy public immutable TRANSFER_PROXY;

    constructor(address _TRANSFER_PROXY, address _WETH) {
        TRANSFER_PROXY = ITransferProxy(_TRANSFER_PROXY);
        WETH = _WETH;
    }
}

contract LienToken is Auth, TransferAgent, ERC721, ILienToken {
    uint256 lienCounter;

    enum LienAction {
        ADD,
        REMOVE,
        UPDATED
    }

    mapping(uint256 => Lien) lienData;
    mapping(uint256 => uint256[]) liens;
    event NewLien(uint256 lienId);
    event LienUpdated(LienAction action);

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

    function buyoutLien(ILienToken.LienActionBuyout calldata params) external {
        (uint256 owed, uint256 buyout) = getBuyout(
            params.incoming.collateralVault,
            params.incoming.position
        );

        TRANSFER_PROXY.tokenTransferFrom(
            address(WETH),
            address(msg.sender),
            address(this),
            uint256(buyout)
        );
        //        WETH.safeApprove(params.incoming.broker, uint256(buyout));
        uint256 lienId = liens[params.incoming.collateralVault][
            params.incoming.position
        ];
        lienData[lienId].last = uint32(block.timestamp);
        lienData[lienId].rate = uint32(params.incoming.rate);
        lienData[lienId].duration = uint32(params.incoming.duration);
        //so, something about brokers
        lienData[lienId].root = BrokerImplementation(params.incoming.broker)
            .vaultHash();
        lienData[lienId].buyout = uint32(
            BrokerImplementation(params.incoming.broker).buyout()
        );
        //TODO: emit event, should we send to sender or broker on buyout?
        //        _transfer(ownerOf(lienId), address(msg.sender), lienId);
        _transfer(ownerOf(lienId), address(params.receiver), lienId);
        //        _mint(
        //            address(msg.sender),
        //            uint256(
        //                keccak256(
        //                    abi.encodePacked(
        //                        params.incoming.collateralVault,
        //                        params.incoming.position,
        //                        lienCounter++
        //                    )
        //                )
        //            )
        //        );
    }

    function validateTerms(
        bytes32[] memory proof,
        uint256 collateralVault,
        uint256 maxAmount,
        uint256 interestRate,
        uint256 duration,
        uint256 position,
        uint256 schedule
    ) public view returns (bool) {
        // filler hashing schema for merkle tree
        bytes32 leaf = keccak256(
            abi.encode(
                bytes32(collateralVault),
                maxAmount,
                interestRate,
                duration,
                position,
                schedule
            )
        );
        uint256 lienId = liens[collateralVault][position];
        return verifyMerkleBranch(proof, leaf, lienData[lienId].root);
    }

    function validateTerms(IBrokerRouter.Terms memory params)
        public
        view
        returns (bool)
    {
        return
            validateTerms(
                params.proof,
                params.collateralVault,
                params.maxAmount,
                params.rate,
                params.duration,
                params.position,
                params.schedule
            );
    }

    function verifyMerkleBranch(
        bytes32[] memory proof,
        bytes32 leaf,
        bytes32 root
    ) public pure returns (bool) {
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

    function _getInterest(Lien memory lien) internal view returns (uint256) {
        uint256 delta_t = block.timestamp - lien.last;
        return (delta_t * lien.rate * lien.amount);
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
            ILienToken.Lien storage l = lienData[lienIds[i]];
            unchecked {
                l.amount += _getInterest(l);
                reserve += l.amount;
            }
            amounts[i] = l.amount;
            l.active = false;
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
        lienData[lienId] = Lien({
            active: true,
            amount: params.amount,
            rate: uint32(params.amount),
            last: uint32(block.timestamp),
            start: uint32(block.timestamp),
            buyout: uint32(BrokerImplementation(params.terms.broker).buyout()),
            duration: uint32(params.terms.duration),
            root: BrokerImplementation(params.terms.broker).vaultHash()
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
        external
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
        uint256 lienId = liens[collateralVault][index];
        Lien storage lien = lienData[lienId];
        uint256 owed = lien.amount + _getInterest(lien);

        uint256 premium = lien.buyout;

        //        return owed += (owed * premium) / 100;
        return (owed, owed + (owed * premium) / 100);
    }

    function makePayment(uint256 collateralVault, uint256 paymentAmount)
        external
    {
        // calculates interest here and apply it to the loan
        uint256[] storage openLiens = liens[collateralVault];
        for (uint256 i = 0; i < openLiens.length; ++i) {
            Lien storage l = lienData[openLiens[i]];
            uint256 maxLienPayment = l.amount + _getInterest(l);
            if (maxLienPayment >= paymentAmount) {
                paymentAmount = maxLienPayment;
                delete liens[collateralVault][i];
            } else {
                l.amount -= paymentAmount;
                l.last = uint32(block.timestamp);
            }
            if (paymentAmount > 0) {
                address owner = ownerOf(openLiens[i]);

                TRANSFER_PROXY.tokenTransferFrom(
                    address(WETH),
                    address(msg.sender),
                    owner,
                    paymentAmount
                );
            }
        }
    }
}
