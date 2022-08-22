// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

pragma experimental ABIEncoderV2;

import {Auth, Authority} from "solmate/auth/Auth.sol";
import {IERC721, IERC165} from "gpl/interfaces/IERC721.sol";
// import {ERC721} from "solmate/tokens/ERC721.sol";
import {ERC721} from "gpl/ERC721.sol";
import {MerkleProof} from "openzeppelin/utils/cryptography/MerkleProof.sol";
import {IAuctionHouse} from "gpl/interfaces/IAuctionHouse.sol";
import {ITransferProxy} from "gpl/interfaces/ITransferProxy.sol";
import {ILienBase, ILienToken} from "./interfaces/ILienToken.sol";
import {ICollateralToken} from "./interfaces/ICollateralToken.sol";
import {IAstariaRouter} from "./interfaces/IAstariaRouter.sol";
import {VaultImplementation} from "./VaultImplementation.sol";
import {ValidateTerms} from "./libraries/ValidateTerms.sol";
import {CollateralLookup} from "./libraries/CollateralLookup.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {IPublicVault} from "./PublicVault.sol";

contract TransferAgent {
    address public immutable WETH;
    ITransferProxy public immutable TRANSFER_PROXY;

    constructor(address _TRANSFER_PROXY, address _WETH) {
        TRANSFER_PROXY = ITransferProxy(_TRANSFER_PROXY);
        WETH = _WETH;
    }
}

contract LienToken is ERC721, ILienBase, Auth, TransferAgent {
    using ValidateTerms for IAstariaRouter.NewLienRequest;
    using FixedPointMathLib for uint256;
    using CollateralLookup for address;

    IAuctionHouse public AUCTION_HOUSE;
    ICollateralToken public COLLATERAL_TOKEN;

    bytes32 public immutable DOMAIN_SEPARATOR;

    uint256 public buyoutNumerator;
    uint256 public buyoutDenominator;

    mapping(uint256 => Lien) public lienData;
    mapping(uint256 => uint256[]) public liens;
    mapping(uint256 => address) public payees;

    event NewLien(uint256 lienId, uint256, uint8, bytes32 rootHash);
    event RemovedLiens(uint256 lienId);
    event BuyoutLien(address indexed buyer, uint256 lienId, uint256 buyout);

    constructor(Authority _AUTHORITY, address _TRANSFER_PROXY, address _WETH)
        Auth(address(msg.sender), _AUTHORITY)
        TransferAgent(_TRANSFER_PROXY, _WETH)
        ERC721("Astaria Lien Token", "Lien")
    {
        buyoutNumerator = 10;
        buyoutDenominator = 100;
        uint256 chainId;
        assembly {
            chainId := chainid()
        }
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("LienToken"),
                keccak256("1"),
                chainId,
                address(this)
            )
        );
    }

    function file(bytes32 what, bytes calldata data) external requiresAuth {
        if (what == "setAuctionHouse") {
            address addr = abi.decode(data, (address));
            AUCTION_HOUSE = IAuctionHouse(addr);
        } else if (what == "setCollateralToken") {
            address addr = abi.decode(data, (address));
            COLLATERAL_TOKEN = ICollateralToken(addr);
        } else {
            revert("unsupported/file");
        }
    }

    function supportsInterface(bytes4 interfaceId) public view override (ERC721) returns (bool) {
        return interfaceId == type(ILienToken).interfaceId || super.supportsInterface(interfaceId);
    }

    function buyoutLien(ILienToken.LienActionBuyout calldata params) external {
        uint256 collateralId = params.incoming.tokenContract.computeId(params.incoming.tokenId);
        (, uint256 buyout) = getBuyout(collateralId, params.position);

        uint256 lienId = liens[collateralId][params.position];
        TRANSFER_PROXY.tokenTransferFrom(lienData[lienId].token, address(msg.sender), payees[lienId], uint256(buyout)); // was ownerOf(lienId) before payees[lienId]

        (bool valid, IAstariaRouter.LienDetails memory ld) =
            params.incoming.nor.validateTerms(COLLATERAL_TOKEN.ownerOf(collateralId));

        if (!valid) {
            revert("invalid incoming terms");
        }

        //TODO: fix up min duration and min rate changes
        require(ld.rate < lienData[lienId].rate, "Invalid Rate");
        //        require(
        //            lienData[lienId].rate - ld.rate > IAstariaRouter(),
        //            "Invalid Rate delta"
        //        );
        require(block.timestamp + ld.duration >= lienData[lienId].start + lienData[lienId].duration, "Invalid Duration");
        lienData[lienId].last = uint32(block.timestamp);
        lienData[lienId].start = uint32(block.timestamp);
        lienData[lienId].rate = uint32(ld.rate);
        lienData[lienId].duration = uint32(ld.duration);
        //so, something about brokers
        lienData[lienId].vault = params.incoming.nor.strategy.vault;

        //should this be safe transfer from?
        getApproved[lienId] = address(this);
        transferFrom(ownerOf(lienId), address(params.receiver), lienId);
    }

    event RateData(uint256);

    //    function validateTerms(IAstariaRouter.Terms memory params)
    //        public
    //        view
    //        returns (bool)
    //    {
    //        uint256 lienId = liens[params.collateralId][params.position];
    //
    //        return
    //            params.validateTerms(
    //                VaultImplementation(lienData[lienId].broker).vaultHash()
    //            );
    //    }

    function getInterest(uint256 collateralId, uint256 position) public view returns (uint256) {
        uint256 lien = liens[collateralId][position];
        if (!lienData[lien].active) {
            return uint256(0);
        }
        return _getInterest(lienData[lien], block.timestamp);
    }

    function _getInterest(Lien memory lien, uint256 timestamp) internal pure returns (uint256) {
        uint256 delta_t = uint256(uint32(timestamp) - lien.last);

        //        return ((delta_t * lien.rate) / 100) * lien.amount;
        return ((delta_t * lien.rate) / 31556952 / 100) * lien.amount;
        //        return delta_t.mulDivDown(rps, 100).mulDivDown(lien.amount, 100);
    }

    function stopLiens(uint256 collateralId)
        external
        requiresAuth
        returns (uint256 reserve, uint256[] memory amounts, uint256[] memory lienIds)
    {
        reserve = 0;
        lienIds = liens[collateralId];
        amounts = new uint256[](liens[collateralId].length);
        for (uint256 i = 0; i < lienIds.length; ++i) {
            ILienToken.Lien storage lien = lienData[lienIds[i]];
            unchecked {
                lien.amount += _getInterest(lien, block.timestamp);
                reserve += lien.amount;
            }
            amounts[i] = lien.amount;
            lien.active = false;
        }
    }

    //undo solmate change for now

    function tokenURI(uint256) public view override returns (string memory) {
        return "";
    }

    function createLien(ILienBase.LienActionEncumber memory params) external requiresAuth returns (uint256 lienId) {
        // require that the auction is not under way

        uint256 collateralId = params.tokenContract.computeId(params.tokenId);

        require(!AUCTION_HOUSE.auctionExists(collateralId), "collateralId is being liquidated, cannot open new liens");

        if (params.validateSlip) {
            (address tokenContract,) = COLLATERAL_TOKEN.getUnderlying(collateralId);
            require(tokenContract != address(0), "Collateral must be deposited before you can request a lien");
        }

        uint256 totalDebt = getTotalDebtForCollateralToken(collateralId);
        uint256 impliedRate = getImpliedRate(collateralId);

        require(params.terms.maxSeniorDebt >= totalDebt, "too much debt to take this loan");

        require(params.terms.maxInterestRate >= impliedRate, "current implied rate is too high");

        lienId = uint256(
            keccak256(
                abi.encodePacked(
                    abi.encode(
                        bytes32(collateralId),
                        params.vault,
                        WETH,
                        params.terms.maxAmount,
                        params.terms.maxSeniorDebt,
                        params.terms.rate,
                        params.terms.maxInterestRate,
                        params.terms.duration
                    ),
                    params.obligationRoot
                )
            )
        );

        uint8 newPosition = uint8(liens[collateralId].length);

        _mint(VaultImplementation(params.vault).recipient(), lienId);
        lienData[lienId] = Lien({
            token: WETH,
            collateralId: collateralId,
            position: newPosition,
            amount: params.amount,
            active: true,
            rate: uint32(params.terms.rate),
            vault: params.vault,
            last: uint32(block.timestamp),
            start: uint32(block.timestamp),
            duration: uint32(params.terms.duration)
        });

        liens[collateralId].push(lienId);

        emit NewLien(lienId, collateralId, newPosition, params.obligationRoot);
    }

    function removeLiens(uint256 collateralId) external requiresAuth {
        delete liens[collateralId];
        emit RemovedLiens(collateralId);
    }

    function getLiens(uint256 collateralId) public view returns (uint256[] memory) {
        return liens[collateralId];
    }

    function getLien(uint256 lienId) external view returns (Lien memory) {
        return lienData[lienId];
    }

    function getLien(uint256 collateralId, uint256 position) public view returns (Lien memory) {
        uint256 lienId = liens[collateralId][position];
        return lienData[lienId];
    }

    event Data(uint256, uint256);

    function getBuyout(uint256 collateralId, uint256 index) public returns (uint256, uint256) {
        Lien memory lien = getLien(collateralId, index);
        uint256 owed = _getOwed(lien);
        uint256 remainingInterest = _getRemainingInterest(lien);

        emit Data(owed, remainingInterest);
        return (
            owed,
            // owed + (remainingInterest * buyoutNumerator) / buyoutDenominator
            owed + remainingInterest.mulDivDown(buyoutNumerator, buyoutDenominator)
        );
    }

    function makePayment(uint256 collateralId, uint256 paymentAmount) public {
        uint256[] memory openLiens = liens[collateralId];
        for (uint256 i = 0; i < openLiens.length; ++i) {
            paymentAmount = _payment(collateralId, i, paymentAmount, address(msg.sender));
        }
    }

    function makePayment(uint256 collateralId, uint256 paymentAmount, uint256 index) external {
        _payment(collateralId, index, paymentAmount, address(msg.sender));
    }

    function makePayment(uint256 collateralId, uint256 paymentAmount, address payer) external requiresAuth {
        uint256[] memory openLiens = liens[collateralId];
        for (uint256 i = 0; i < openLiens.length; ++i) {
            paymentAmount = _payment(collateralId, i, paymentAmount, payer);
        }
    }

    // TODO change to (aggregate) rate?

    function calculateSlope(uint256 lienId) public view returns (uint256) {
        Lien memory lien = lienData[lienId];
        uint256 end = (lien.start + lien.duration);
        // return (end - lien.last) / (lien.amount * lien.rate * end - lien.amount); // TODO check

        return (lien.amount * lien.rate * end - lien.amount).mulDivDown(1, end - lien.last);
    }

    function changeInSlope(uint256 lienId, uint256 paymentAmount)
        public
        view
        returns (
            // view
            uint256 slope
        )
    {
        Lien memory lien = lienData[lienId];
        uint256 end = (lien.start + lien.duration);
        uint256 oldSlope = calculateSlope(lienId);
        uint256 newAmount = (lien.amount - paymentAmount);
        // uint256 newSlope =
        //     (end - block.timestamp) / ((newAmount * lien.rate * end) - newAmount);

        uint256 newSlope = ((newAmount * lien.rate * end) - newAmount).mulDivDown(1, end - block.timestamp);

        slope = oldSlope - newSlope;
    }

    function _afterPayment(uint256 lienId, uint256 amount) internal virtual {}

    function getTotalDebtForCollateralToken(uint256 collateralId) public view returns (uint256 totalDebt) {
        uint256[] memory openLiens = getLiens(collateralId);
        totalDebt = 0;
        for (uint256 i = 0; i < openLiens.length; ++i) {
            totalDebt += _getOwed(lienData[openLiens[i]]);
        }
    }

    function getTotalDebtForCollateralToken(uint256 collateralId, uint256 timestamp)
        public
        view
        returns (uint256 totalDebt)
    {
        uint256[] memory openLiens = getLiens(collateralId);
        totalDebt = 0;

        for (uint256 i = 0; i < openLiens.length; ++i) {
            totalDebt += _getOwed(lienData[openLiens[i]], timestamp);
        }
    }

    function getImpliedRate(uint256 collateralId) public view returns (uint256 impliedRate) {
        uint256 totalDebt = getTotalDebtForCollateralToken(collateralId);
        uint256[] memory openLiens = getLiens(collateralId);
        impliedRate = 0;
        for (uint256 i = 0; i < openLiens.length; ++i) {
            Lien storage lien = lienData[openLiens[i]];

            // impliedRate += (lien.amount / totalDebt) * lien.rate;

            impliedRate += uint256(lien.rate).mulDivDown(lien.amount, totalDebt);
        }
    }

    function _getOwed(Lien memory lien) internal view returns (uint256) {
        return lien.amount += _getInterest(lien, block.timestamp);
    }

    function _getOwed(Lien memory lien, uint256 timestamp) internal pure returns (uint256) {
        return lien.amount += _getInterest(lien, timestamp);
    }

    function _getRemainingInterest(Lien memory lien) internal pure returns (uint256) {
        return _getInterest(lien, (lien.start + lien.duration - lien.last));
    }

    function _payment(uint256 collateralId, uint256 index, uint256 paymentAmount, address payer)
        internal
        returns (uint256)
    {
        if (paymentAmount == uint256(0)) {
            return uint256(0);
        }
        address lienOwner = ownerOf(liens[collateralId][index]);
        if (IPublicVault(lienOwner).supportsInterface(type(IPublicVault).interfaceId)) {
            // was lienOwner.supportsinterface(PublicVault)
            IPublicVault(lienOwner).beforePayment(liens[collateralId][index], paymentAmount);
        }
        Lien storage lien = lienData[liens[collateralId][index]];
        uint256 maxPayment = _getOwed(lien);
        // address owner = ownerOf(liens[collateralId][position]);

        if (maxPayment < paymentAmount) {
            lien.amount -= paymentAmount;
            lien.last = uint32(block.timestamp);
        } else {
            paymentAmount = maxPayment;
            _burn(liens[collateralId][index]);
            delete liens[collateralId][index];
        }

        TRANSFER_PROXY.tokenTransferFrom(lien.token, payer, payees[liens[collateralId][index]], paymentAmount); // was owner before payees[lienId]

        return paymentAmount;
    }

    function getPayee(uint256 lienId) public view returns (address) {
        return payees[lienId];
    }

    // TODO change what's passed in
    function setPayee(uint256 lienId, address newPayee) public {
        require(
            !AUCTION_HOUSE.auctionExists(lienData[lienId].collateralId),
            "collateralId is being liquidated, cannot change payee from LiquidationAccountant"
        );
        require(msg.sender == ownerOf(lienId));

        // if(payees[lienId] == address(0)) {
        //     require(msg.sender == ownerOf(lienId));
        // } else {
        //     require(msg.sender == payees[lienId]);
        // }

        payees[lienId] = newPayee;
        // uint256 collateralId = params.tokenContract.computeId(params.tokenId);

        // require(msg.sender == ownerOf(collateralId), "Must own lien to reassign payee");
        // require(
        //     !AUCTION_HOUSE.auctionExists(collateralId),
        //     "collateralId is being liquidated, cannot open new liens"
        // );
    }
}
