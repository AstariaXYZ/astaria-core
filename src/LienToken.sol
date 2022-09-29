// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

pragma experimental ABIEncoderV2;

import {Auth, Authority} from "solmate/auth/Auth.sol";
import {IERC721, IERC165} from "gpl/interfaces/IERC721.sol";
import {ERC721} from "gpl/ERC721.sol";
import {IAuctionHouse} from "gpl/interfaces/IAuctionHouse.sol";
import {ITransferProxy} from "gpl/interfaces/ITransferProxy.sol";
import {ILienBase, ILienToken} from "./interfaces/ILienToken.sol";
import {ICollateralToken} from "./interfaces/ICollateralToken.sol";
import {IAstariaRouter} from "./interfaces/IAstariaRouter.sol";
import {VaultImplementation} from "./VaultImplementation.sol";
import {CollateralLookup} from "./libraries/CollateralLookup.sol";
import {Base64} from "./libraries/Base64.sol";
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

/**
 * @title LienToken
 * @author androolloyd
 * @notice This contract handles the creation, payments, buyouts, and liquidations of tokenized NFT-collateralized debt (liens). Vaults which originate loans against supported collateral are issued a LienToken representing the right to loan repayments and auctioned funds on liquidation.
 */
contract LienToken is ERC721, ILienBase, Auth, TransferAgent {
    using FixedPointMathLib for uint256;
    using CollateralLookup for address;

    IAuctionHouse public AUCTION_HOUSE;
    IAstariaRouter public ASTARIA_ROUTER;
    ICollateralToken public COLLATERAL_TOKEN;

    uint256 public buyoutNumerator;
    uint256 public buyoutDenominator;

    mapping(uint256 => Lien) public lienData;
    mapping(uint256 => uint256[]) public liens;
    mapping(uint256 => address) public payees;

    event NewLien(uint256 lienId, Lien lien);
    event Payment(uint256 lienId, uint256 amount);
    event RemovedLiens(uint256 lienId);
    event BuyoutLien(address indexed buyer, uint256 lienId, uint256 buyout);

    /**
     * @dev Setup transfer authority and initialize the buyoutNumerator and buyoutDenominator for the lien buyout premium.
     * @param _AUTHORITY The authority manager.
     * @param _TRANSFER_PROXY The TransferProxy for balance transfers.
     * @param _WETH The WETH address to use for transfers.
     */
    constructor(Authority _AUTHORITY, address _TRANSFER_PROXY, address _WETH)
        Auth(address(msg.sender), _AUTHORITY)
        TransferAgent(_TRANSFER_PROXY, _WETH)
        ERC721("Astaria Lien Token", "ALT")
    {
        buyoutNumerator = 10;
        buyoutDenominator = 100;
    }

    /**
     * @notice Sets addresses for the AuctionHouse, CollateralToken, and AstariaRouter contracts to use.
     * @param what The identifier for what is being filed.
     * @param data The encoded address data to be decoded and filed.
     */
    function file(bytes32 what, bytes calldata data) external requiresAuth {
        if (what == "setAuctionHouse") {
            address addr = abi.decode(data, (address));
            AUCTION_HOUSE = IAuctionHouse(addr);
        } else if (what == "setCollateralToken") {
            address addr = abi.decode(data, (address));
            COLLATERAL_TOKEN = ICollateralToken(addr);
        } else if (what == "setAstariaRouter") {
            address addr = abi.decode(data, (address));
            ASTARIA_ROUTER = IAstariaRouter(addr);
        } else {
            revert("unsupported/file");
        }
    }

    // TODO plagiarism from seaport?
    /**
     * @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(bytes4 interfaceId) public view override (ERC721) returns (bool) {
        return interfaceId == type(ILienToken).interfaceId || super.supportsInterface(interfaceId);
    }

    /**
     * @notice Purchase a LienToken for its buyout price.
     * @param params The LienActionBuyout data specifying the lien position, receiver address, and underlying CollateralToken information of the lien.
     */
    function buyoutLien(ILienToken.LienActionBuyout calldata params) external {
        uint256 collateralId = params.incoming.tokenContract.computeId(params.incoming.tokenId);
        (uint256 owed, uint256 buyout) = getBuyout(collateralId, params.position);

        uint256 lienId = liens[collateralId][params.position];

        (bool valid, IAstariaRouter.LienDetails memory ld) = ASTARIA_ROUTER.validateCommitment(params.incoming);
        require(ld.maxAmount <= owed, "LienToken: buyout amount exceeds owed");

        if (!valid) {
            revert("invalid incoming terms");
        }

        require(ASTARIA_ROUTER.isValidRefinance(lienData[lienId], ld), "invalid refinance");

        TRANSFER_PROXY.tokenTransferFrom(lienData[lienId].token, address(msg.sender), getPayee(lienId), uint256(buyout));

        lienData[lienId].last = uint32(block.timestamp);
        lienData[lienId].start = uint32(block.timestamp);
        lienData[lienId].rate = uint32(ld.rate);
        lienData[lienId].duration = uint32(ld.duration);
        lienData[lienId].vault = params.incoming.lienRequest.strategy.vault;

        _transfer(ownerOf(lienId), address(params.receiver), lienId);
    }

    /**
     * @notice Public view function that computes the interest for a LienToken since its last payment.
     * @param collateralId The ID of the underlying CollateralToken
     * @param position The position of the lien to calculate interest for.
     */
    function getInterest(uint256 collateralId, uint256 position) public view returns (uint256) {
        uint256 lien = liens[collateralId][position];
        if (!lienData[lien].active) {
            return uint256(0);
        }
        return _getInterest(lienData[lien], block.timestamp);
    }

    /**
     * @dev Computes the interest accrued for a lien since its last payment.
     * @param lien The Lien for the loan to calculate interest for.
     * @param timestamp The timestamp at which to compute interest for.
     */
    function _getInterest(Lien memory lien, uint256 timestamp) internal pure returns (uint256) {
        uint256 delta_t = uint256(uint32(timestamp) - lien.last);

        return (delta_t * lien.rate * lien.amount) / 1e18;
    }

    // TODO improve this
    /**
     * @notice Stops accruing interest for all liens against a single CollateralToken.
     * @param collateralId The ID for the  CollateralToken of the NFT used as collateral for the liens.
     */
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

    // TODO check/seaport plagiarism?
    /**
     * @dev See {IERC721Metadata-tokenURI}.
     */
    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        return "";
    }

    /**
     * @notice Creates a new lien against a CollateralToken.
     * @param params LienActionEncumber data containing CollateralToken information and lien parameters (rate, duration, and amount, rate, and debt caps).
     */
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

        uint256 potentialDebt = totalDebt * (impliedRate + 1) * params.terms.duration;

        require(
            params.terms.maxPotentialDebt >= potentialDebt,
            "too much debt could potentially be accrued against this collateral"
        );

        lienId = uint256(
            keccak256(
                abi.encodePacked(
                    abi.encode(
                        bytes32(collateralId),
                        params.vault,
                        WETH,
                        params.terms.maxAmount,
                        params.terms.rate,
                        params.terms.duration,
                        params.terms.maxPotentialDebt
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

        emit NewLien(lienId, lienData[lienId]);
    }

    /**
     * @notice Removes all liens for a given CollateralToken.
     * @param collateralId The ID for the underlying CollateralToken.
     */
    function removeLiens(uint256 collateralId) external requiresAuth {
        delete liens[collateralId];
        emit RemovedLiens(collateralId);
    }

    /**
     * @notice Retrieves all liens taken out against the underlying NFT of a CollateralToken.
     * @param collateralId The ID for the underlying CollateralToken.
     * @return The IDs of the liens against the CollateralToken.
     */
    function getLiens(uint256 collateralId) public view returns (uint256[] memory) {
        return liens[collateralId];
    }

    /**
     * @notice Retrieves a specific Lien by its ID.
     * @param lienId The ID of the requested Lien.
     * @return The Lien for the lienId.
     */
    function getLien(uint256 lienId) external view returns (Lien memory) {
        return lienData[lienId];
    }

    /**
     * @notice Retrives a specific Lien from the ID of the CollateralToken for the underlying NFT and the lien position.
     * @param collateralId The ID for the underlying CollateralToken.
     * @param position The requested lien position.
     */
    function getLien(uint256 collateralId, uint256 position) public view returns (Lien memory) {
        uint256 lienId = liens[collateralId][position];
        return lienData[lienId];
    }

    /**
     * @notice Computes and returns the buyout amount for a Lien.
     * @param collateralId The ID for the underlying CollateralToken.
     * @param position The position of the Lien to compute the buyout amount for.
     * @return The outstanding debt for the lien and the buyout amount for the Lien.
     */
    function getBuyout(uint256 collateralId, uint256 position) public returns (uint256, uint256) {
        Lien memory lien = getLien(collateralId, position);

        uint256 owed = _getOwed(lien);
        uint256 remainingInterest = _getRemainingInterest(lien);

        return (owed, owed + remainingInterest.mulDivDown(buyoutNumerator, buyoutDenominator));
    }

    /**
     * @notice Make a payment for the debt against a CollateralToken.
     * @param collateralId The ID of the underlying CollateralToken.
     * @param paymentAmount The amount to pay against the debt. TODO reword?
     */
    function makePayment(uint256 collateralId, uint256 paymentAmount) public {
        uint256[] memory openLiens = liens[collateralId];
        for (uint256 i = 0; i < openLiens.length; ++i) {
            paymentAmount = _payment(collateralId, i, paymentAmount, address(msg.sender));
        }
    }

    /**
     * @notice Make a payment for the debt against a CollateralToken for a specific lien.
     * @param collateralId The ID of the underlying CollateralToken.
     * @param paymentAmount The amount to pay against the debt. TODO reword?
     * @param position The lien position to make a payment to.
     */
    function makePayment(uint256 collateralId, uint256 paymentAmount, uint256 position) external {
        _payment(collateralId, position, paymentAmount, address(msg.sender));
    }

    /**
     * @notice Have a specified paymer make a payment for the debt against a CollateralToken.
     * @param collateralId The ID of the underlying CollateralToken.
     * @param paymentAmount The amount to pay against the debt. TODO reword?
     * @param payer The account to make the payment.
     */
    function makePayment(uint256 collateralId, uint256 paymentAmount, address payer) external {
        uint256[] memory openLiens = liens[collateralId];
        for (uint256 i = 0; i < openLiens.length; ++i) {
            paymentAmount = _payment(collateralId, i, paymentAmount, payer);
        }
    }

    // TODO change to (aggregate) rate?

    /**
     * @notice Computes the rate for a specified lien.
     * @param lienId The ID for the lien.
     * @return The rate for the specified lien, in WETH per second. TODO check
     */
    function calculateSlope(uint256 lienId) public view returns (uint256) {
        Lien memory lien = lienData[lienId];
        uint256 end = (lien.start + lien.duration);
        // return (end - lien.last) / (lien.amount * lien.rate * end - lien.amount); // TODO check

        return (lien.amount * lien.rate * end - lien.amount).mulDivDown(1, end - lien.last);
    }

    /**
     * @notice Computes the change in rate for a lien if a specific payment amount was made.
     * @param lienId The ID for the lien.
     * @param paymentAmount The hypothetical payment amount that would be made to the lien.
     * @return slope The difference between the current lien rate and the lien rate if the payment was made.
     */
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

        uint256 newSlope = ((newAmount * lien.rate * end) - newAmount).mulDivDown(1, end - block.timestamp);

        slope = oldSlope - newSlope;
    }

    function _afterPayment(uint256 lienId, uint256 amount) internal virtual {}

    /**
     * @notice Computes the total amount owed on all liens against a CollateralToken.
     * @param collateralId The ID of the underlying CollateralToken.
     * @return totalDebt The aggregate debt for all loans against the collateral.
     */
    function getTotalDebtForCollateralToken(uint256 collateralId) public view returns (uint256 totalDebt) {
        uint256[] memory openLiens = getLiens(collateralId);
        totalDebt = 0;
        for (uint256 i = 0; i < openLiens.length; ++i) {
            totalDebt += _getOwed(lienData[openLiens[i]]);
        }
    }

    /**
     * @notice Computes the total amount owed on all liens against a CollateralToken at a specified timestamp.
     * @param collateralId The ID of the underlying CollateralToken.
     * @param timestamp The timestamp to use to calculate owed debt.
     * @return totalDebt The aggregate debt for all loans against the specified collateral at the specified timestamp.
     */
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

    // TODO maybe rename
    /**
     * @notice Computes the combined rate of all liens against a CollateralToken
     * @param collateralId The ID of the underlying CollateralToken.
     * @return impliedRate The aggregate rate for all loans against the specified collateral.
     */

    function getImpliedRate(uint256 collateralId) public view returns (uint256 impliedRate) {
        uint256 totalDebt = getTotalDebtForCollateralToken(collateralId);
        uint256[] memory openLiens = getLiens(collateralId);
        impliedRate = 0;
        for (uint256 i = 0; i < openLiens.length; ++i) {
            Lien memory lien = lienData[openLiens[i]];
            unchecked {
                impliedRate += uint256(lien.rate) * lien.amount;
            }
        }

        if (totalDebt > uint256(0)) {
            impliedRate = impliedRate.mulDivDown(1, totalDebt);
        }
    }

    /**
     * @dev Computes the debt owed to a Lien.
     * @param lien The specified Lien.
     * @return The amount owed to the specified Lien.
     */
    function _getOwed(Lien memory lien) internal view returns (uint256) {
        return lien.amount += _getInterest(lien, block.timestamp);
    }

    /**
     * @dev Computes the debt owed to a Lien at a specified timestamp.
     * @param lien The specified Lien.
     * @return The amount owed to the Lien at the specified timestamp.
     */
    function _getOwed(Lien memory lien, uint256 timestamp) internal pure returns (uint256) {
        return lien.amount += _getInterest(lien, timestamp);
    }

    /**
     * @dev Computes the interest still owed to a Lien.
     * @param lien The specified Lien.
     * @return The WETH still owed in interest to the Lien.
     */
    function _getRemainingInterest(Lien memory lien) internal view returns (uint256) {
        uint256 end = lien.start + lien.duration;
        if (lien.start + lien.duration > block.timestamp + 60 days) {
            end = block.timestamp + 60 days;
        }

        uint256 delta_t = uint256(uint32(end) - block.timestamp);

        return (delta_t * lien.rate * lien.amount) / 1e18;
    }

    /**
     * @dev Make a payment from a payer to a specific lien against a CollateralToken.
     * @param collateralId The ID of the underlying CollateralToken.
     * @param position The position of the lien to make a payment to.
     * @param paymentAmount The amount to pay against the debt.
     * @param payer The address to make the payment.
     * @return The paymentAmount for the payment.
     */
    function _payment(uint256 collateralId, uint256 position, uint256 paymentAmount, address payer)
        internal
        returns (uint256)
    {
        if (paymentAmount == uint256(0)) {
            return uint256(0);
        }
        address lienOwner = ownerOf(liens[collateralId][position]);
        if (IPublicVault(lienOwner).supportsInterface(type(IPublicVault).interfaceId)) {
            // was lienOwner.supportsinterface(PublicVault)
            IPublicVault(lienOwner).beforePayment(liens[collateralId][position], paymentAmount);
        }
        Lien storage lien = lienData[liens[collateralId][position]];
        uint256 maxPayment = _getOwed(lien);
        // address owner = ownerOf(liens[collateralId][position]);

        if (maxPayment < paymentAmount) {
            lien.amount -= paymentAmount;
            lien.last = uint32(block.timestamp);
        } else {
            paymentAmount = maxPayment;
            _burn(liens[collateralId][position]);
            delete liens[collateralId][position];
        }

        TRANSFER_PROXY.tokenTransferFrom(lien.token, payer, getPayee(liens[collateralId][position]), paymentAmount);
        emit Payment(liens[collateralId][position], paymentAmount);
        return paymentAmount;
    }

    /**
     * @notice Retrieve the payee (address that receives payments and auction funds) for a specified Lien.
     * @param lienId The ID of the Lien.
     * @return The address of the payee for the Lien.
     */
    function getPayee(uint256 lienId) public view returns (address) {
        return payees[lienId] != address(0) ? payees[lienId] : ownerOf(lienId);
    }

    // TODO change what's passed in
    /**
     * @notice Change the payee for a specified Lien.
     * @param lienId The ID of the Lien.
     * @param newPayee The new Lien payee.
     */
    function setPayee(uint256 lienId, address newPayee) public {
        require(
            !AUCTION_HOUSE.auctionExists(lienData[lienId].collateralId),
            "collateralId is being liquidated, cannot change payee from LiquidationAccountant"
        );
        require(msg.sender == ownerOf(lienId) || msg.sender == address(ASTARIA_ROUTER), "invalid owner");

        payees[lienId] = newPayee;
    }
}
