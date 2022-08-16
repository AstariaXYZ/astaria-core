// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

pragma experimental ABIEncoderV2;

import {Auth, Authority} from "solmate/auth/Auth.sol";
import {IERC721} from "openzeppelin/token/ERC721/IERC721.sol";
import {ERC721} from "openzeppelin/token/ERC721/ERC721.sol";
import {MerkleProof} from "openzeppelin/utils/cryptography/MerkleProof.sol";
import {IAuctionHouse} from "gpl/interfaces/IAuctionHouse.sol";
import {ITransferProxy} from "gpl/interfaces/ITransferProxy.sol";
import {ILienToken, IERC721, IERC165} from "./interfaces/ILienToken.sol";
import {IEscrowToken} from "./interfaces/IEscrowToken.sol";
import {IBrokerRouter} from "./interfaces/IBrokerRouter.sol";
import {VaultImplementation} from "./VaultImplementation.sol";
import {ValidateTerms} from "./libraries/ValidateTerms.sol";
import {CollateralLookup} from "./libraries/CollateralLookup.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

contract TransferAgent {
    address public immutable WETH;
    ITransferProxy public immutable TRANSFER_PROXY;

    constructor(address _TRANSFER_PROXY, address _WETH) {
        TRANSFER_PROXY = ITransferProxy(_TRANSFER_PROXY);
        WETH = _WETH;
    }
}

contract LienToken is ILienToken, Auth, TransferAgent, ERC721 {
    using ValidateTerms for IBrokerRouter.NewObligationRequest;
    using FixedPointMathLib for uint256;
    using CollateralLookup for address;

    IAuctionHouse public AUCTION_HOUSE;
    IEscrowToken public ESCROW_TOKEN;

    bytes32 public immutable DOMAIN_SEPARATOR;

    string private constant EIP191_PREFIX_FOR_EIP712_STRUCTURED_DATA =
        "\x19\x01";

    uint256 public lienCounter;
    uint256 public buyoutNumerator;
    uint256 public buyoutDenominator;

    mapping(uint256 => Lien) public lienData;
    mapping(uint256 => uint256[]) public liens;

    event NewLien(uint256 lienId, uint256, uint8, bytes32 rootHash);
    event RemovedLiens(uint256 lienId);
    event BuyoutLien(address indexed buyer, uint256 lienId, uint256 buyout);

    constructor(Authority _AUTHORITY, address _TRANSFER_PROXY, address _WETH)
        Auth(address(msg.sender), _AUTHORITY)
        TransferAgent(_TRANSFER_PROXY, _WETH)
        ERC721("Astaria Lien Token", "Lien")
    {
        lienCounter = 1;
        buyoutNumerator = 10;
        buyoutDenominator = 100;
        uint256 chainId;
        assembly {
            chainId := chainid()
        }
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
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
        } else if (what == "setCollateralVault") {
            address addr = abi.decode(data, (address));
            ESCROW_TOKEN = IEscrowToken(addr);
        } else {
            revert("unsupported/file");
        }
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override (ERC721, IERC165)
        returns (bool)
    {
        return interfaceId == type(IERC721).interfaceId
            || interfaceId == type(ILienToken).interfaceId
            || super.supportsInterface(interfaceId);
    }

    function buyoutLien(ILienToken.LienActionBuyout calldata params) external {
        uint256 escrowId =
            params.incoming.tokenContract.computeId(params.incoming.tokenId);
        (uint256 owed, uint256 buyout) = getBuyout(escrowId, params.position);

        uint256 lienId = liens[escrowId][params.position];
        TRANSFER_PROXY.tokenTransferFrom(
            lienData[lienId].token,
            address(msg.sender),
            ownerOf(lienId),
            uint256(buyout)
        );

        (bool valid, IBrokerRouter.LienDetails memory ld) =
            params.incoming.nor.validateTerms(ESCROW_TOKEN.ownerOf(escrowId));

        if (!valid) {
            revert("invalid incoming terms");
        }
        require(ld.rate <= lienData[lienId].rate, "Invalid Rate");
        require(ld.duration <= type(uint256).max, "Invalid Duration"); //TODO: set this check to be proper with a min DURATION
        lienData[lienId].last = uint32(block.timestamp);
        lienData[lienId].start = uint32(block.timestamp);
        lienData[lienId].rate = uint32(ld.rate);
        lienData[lienId].duration = uint32(ld.duration);
        //so, something about brokers
        lienData[lienId].vault = params.incoming.nor.strategy.vault;

        //TODO: emit event, should we send to sender or broker on buyout?
        safeTransferFrom(ownerOf(lienId), address(params.receiver), lienId);
    }

    //    function validateTerms(IBrokerRouter.Terms memory params)
    //        public
    //        view
    //        returns (bool)
    //    {
    //        uint256 lienId = liens[params.escrowId][params.position];
    //
    //        return
    //            params.validateTerms(
    //                VaultImplementation(lienData[lienId].broker).vaultHash()
    //            );
    //    }

    function getInterest(uint256 escrowId, uint256 position)
        public
        view
        returns (uint256)
    {
        uint256 lien = liens[escrowId][position];
        if (!lienData[lien].active) {
            return uint256(0);
        }
        return _getInterest(lienData[lien], block.timestamp);
    }

    function _getInterest(Lien memory lien, uint256 timestamp)
        internal
        view
        returns (uint256)
    {
        uint256 delta_t = uint256(uint32(timestamp) - lien.last);

        return delta_t.mulDivDown(lien.rate, 1).mulDivDown(lien.amount, 1);
    }

    function stopLiens(uint256 escrowId)
        external
        requiresAuth
        returns (
            uint256 reserve,
            uint256[] memory amounts,
            uint256[] memory lienIds
        )
    {
        reserve = 0;
        lienIds = liens[escrowId];
        amounts = new uint256[](liens[escrowId].length);
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

    function createLien(ILienToken.LienActionEncumber memory params)
        external
        requiresAuth
        returns (uint256 lienId)
    {
        // require that the auction is not under way

        uint256 escrowId = params.tokenContract.computeId(params.tokenId);

        require(
            !AUCTION_HOUSE.auctionExists(escrowId),
            "escrowId is being liquidated, cannot open new liens"
        );

        if (params.validateEscrow == true) {
            (address tokenContract,) = ESCROW_TOKEN.getUnderlying(escrowId);
            require(
                tokenContract != address(0),
                "Collateral must be deposited before you can request a lien"
            );
        }

        uint256 totalDebt = getTotalDebtForCollateralVault(escrowId);
        uint256 impliedRate = getImpliedRate(escrowId);

        require(
            params.terms.maxSeniorDebt >= totalDebt,
            "too much debt to take this loan"
        );

        require(
            params.terms.maxInterestRate >= impliedRate,
            "current implied rate is too high"
        );

        lienId = uint256(
            keccak256(
                abi.encodePacked(
                    abi.encode(
                        bytes32(escrowId),
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

        uint8 newPosition = uint8(liens[escrowId].length);

        _mint(VaultImplementation(params.vault).recipient(), lienId);
        lienData[lienId] = Lien({
            token: WETH,
            escrowId: escrowId,
            position: newPosition,
            amount: params.amount,
            active: true,
            rate: uint32(params.terms.rate),
            vault: params.vault,
            last: uint32(block.timestamp),
            start: uint32(block.timestamp),
            duration: uint32(params.terms.duration)
        });

        liens[escrowId].push(lienId);

        emit NewLien(lienId, escrowId, newPosition, params.obligationRoot);
    }

    function removeLiens(uint256 escrowId) external requiresAuth {
        delete liens[escrowId];
        emit RemovedLiens(escrowId);
    }

    function getLiens(uint256 escrowId)
        public
        view
        returns (uint256[] memory)
    {
        return liens[escrowId];
    }

    function getLien(uint256 lienId) external view returns (Lien memory) {
        return lienData[lienId];
    }

    function getLien(uint256 escrowId, uint256 position)
        public
        view
        returns (Lien memory)
    {
        uint256 lienId = liens[escrowId][position];
        return lienData[lienId];
    }

    function getBuyout(uint256 escrowId, uint256 index)
        public
        view
        returns (uint256, uint256)
    {
        Lien memory lien = getLien(escrowId, index);
        uint256 owed = _getOwed(lien);
        uint256 remainingInterest = _getRemainingInterest(lien);
        return (
            owed,
            // owed + (remainingInterest * buyoutNumerator) / buyoutDenominator
            owed + remainingInterest.mulDivDown(buyoutNumerator, buyoutDenominator)
        );
    }

    function makePayment(uint256 escrowId, uint256 paymentAmount) public {
        uint256[] memory openLiens = liens[escrowId];
        for (uint256 i = 0; i < openLiens.length; ++i) {
            paymentAmount = _payment(escrowId, i, paymentAmount);
        }
    }

    function makePayment(uint256 escrowId, uint256 paymentAmount, uint256 index)
        external
    {
        address lienOwner = ownerOf(liens[escrowId][index]);
        if (supportsInterface(lienOwner, escrowId)) {
            // was lienOwner.supportsinterface(PublicVault)
            beforePayment(lienOwner, paymentAmount); // was lienOwner.beforePayment(paymentAmount)
        }
        _payment(escrowId, index, paymentAmount);
    }

    function supportsInterface(address lienOwner, uint256 escrowId)
        internal
        returns (bool)
    {
        return true;
    }

    function beforePayment(address lienOwner, uint256 paymentAmount) internal {}

    // TODO change to (aggregate) rate?

    function calculateSlope(uint256 lienId) public returns (uint256) {
        Lien memory lien = lienData[lienId];
        uint256 end = (lien.start + lien.duration);
        // return (end - lien.last) / (lien.amount * lien.rate * end - lien.amount); // TODO check

        return (lien.amount * lien.rate * end - lien.amount).mulDivDown(
            1, end - lien.last
        );
    }

    function changeInSlope(uint256 lienId, uint256 paymentAmount)
        public
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

        uint256 newSlope = ((newAmount * lien.rate * end) - newAmount)
            .mulDivDown(1, end - block.timestamp);

        slope = oldSlope - newSlope;
    }

    function _afterPayment(uint256 lienId, uint256 amount) internal virtual {}

    function getTotalDebtForCollateralVault(uint256 escrowId)
        public
        view
        returns (uint256 totalDebt)
    {
        uint256[] memory openLiens = getLiens(escrowId);
        totalDebt = 0;
        for (uint256 i = 0; i < openLiens.length; ++i) {
            totalDebt += _getOwed(lienData[openLiens[i]]);
        }
    }

    function getTotalDebtForCollateralVault(uint256 escrowId, uint256 timestamp)
        public
        view
        returns (uint256 totalDebt)
    {
        uint256[] memory openLiens = getLiens(escrowId);
        totalDebt = 0;

        for (uint256 i = 0; i < openLiens.length; ++i) {
            totalDebt += _getOwed(lienData[openLiens[i]], timestamp);
        }
    }

    function getImpliedRate(uint256 escrowId)
        public
        view
        returns (uint256 impliedRate)
    {
        uint256 totalDebt = getTotalDebtForCollateralVault(escrowId);
        uint256[] memory openLiens = getLiens(escrowId);
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

    function _getOwed(Lien memory lien, uint256 timestamp)
        internal
        view
        returns (uint256)
    {
        return lien.amount += _getInterest(lien, timestamp);
    }

    function _getRemainingInterest(Lien memory lien)
        internal
        pure
        returns (uint256)
    {
        uint256 delta_t =
            uint256(uint32(lien.start + lien.duration) - lien.last);

        // return (delta_t * uint256(lien.rate) * lien.amount);

        return delta_t.mulDivDown(lien.rate, 1).mulDivDown(lien.amount, 1);
    }

    function _payment(uint256 escrowId, uint256 position, uint256 paymentAmount)
        internal
        returns (uint256)
    {
        if (paymentAmount == uint256(0)) {
            return uint256(0);
        }
        Lien storage lien = lienData[liens[escrowId][position]];
        uint256 maxPayment = _getOwed(lien);
        address owner = ownerOf(liens[escrowId][position]);

        if (maxPayment < paymentAmount) {
            lien.amount -= paymentAmount;
            lien.last = uint32(block.timestamp);
        } else {
            paymentAmount = maxPayment;
            delete liens[escrowId][position];
        }
        TRANSFER_PROXY.tokenTransferFrom(
            address(WETH), address(msg.sender), owner, paymentAmount
        );

        return paymentAmount;
    }
}
