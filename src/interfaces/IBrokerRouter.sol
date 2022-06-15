pragma solidity ^0.8.0;
import {IERC721} from "openzeppelin/token/ERC721/IERC721.sol";
import {ILienToken} from "./ILienToken.sol";
import {ICollateralVault} from "./ICollateralVault.sol";

interface IBrokerRouter {
    struct Terms {
        address broker;
        bytes32[] proof;
        uint256 collateralVault;
        uint256 maxAmount;
        uint256 rate;
        uint256 duration;
        uint256 position;
        uint256 schedule;
    }
    struct BrokerParams {
        address appraiser;
        bytes32 root;
        uint256 expiration;
        uint256 deadline;
        uint256 buyout;
        bytes32 contentHash;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    struct BuyoutLienParams {
        Terms outgoing;
        Terms incoming;
    }

    struct RefinanceCheckParams {
        Terms outgoing;
        Terms incoming;
    }

    struct BorrowAndBuyParams {
        ILienToken.LienActionEncumber[] commitments;
        address invoker;
        uint256 purchasePrice;
        bytes purchaseData;
        address receiver;
    }

    struct BondVault {
        address appraiser; // address of the appraiser for the BondVault
        uint256 expiration; // expiration for lenders to add assets and expiration when borrowers cannot create new borrows
        address broker; //cloned proxy
    }

    function newBondVault(BrokerParams memory params) external;

    function feeTo() external returns (address);

    function encodeBondVaultHash(
        address appraiser,
        bytes32 root,
        uint256 expiration,
        uint256 appraiserNonce,
        uint256 deadline,
        uint256 buyout
    ) external view returns (bytes memory);

    //    function buyoutLienPosition(BuyoutLienParams memory params) external;

    function commitToLoans(ILienToken.LienActionEncumber[] calldata commitments)
        external;

    function requestLienPosition(ILienToken.LienActionEncumber calldata params)
        external
        returns (bool);

    function LIEN_TOKEN() external returns (ILienToken);

    function COLLATERAL_VAULT() external returns (ICollateralVault);

    function lendToVault(bytes32 bondVault, uint256 amount) external;

    function getBroker(bytes32 bondVault) external view returns (address);

    function liquidate(uint256 collateralVault, uint256 position)
        external
        returns (uint256 reserve);

    function canLiquidate(uint256 collateralVault, uint256 position)
        external
        view
        returns (bool);

    function isValidRefinance(RefinanceCheckParams memory params)
        external
        view
        returns (bool);

    event Liquidation(
        uint256 collateralVault,
        uint256 position,
        uint256 reserve
    );
    event NewBondVault(
        address appraiser,
        address broker,
        bytes32 bondVault,
        bytes32 contentHash,
        uint256 expiration
    );

    error InvalidAddress(address);
    error InvalidRefinanceRate(uint256);
    error InvalidRefinanceDuration(uint256);
}
