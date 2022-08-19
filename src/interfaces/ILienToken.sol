pragma solidity ^0.8.16;

import {IERC721} from "./IERC721.sol";
import {IAstariaRouter} from "./IAstariaRouter.sol";

interface ILienBase {
    struct Lien {
        uint256 amount; //32
        uint256 collateralId; //32
        address token; // 20
        uint32 rate; // 4
        uint32 start; // 4
        uint32 last; // 4
        address vault; // 20
        uint32 duration; // 4
        uint8 position; // 1
        bool active; // 1
    }

    struct LienActionEncumber {
        address tokenContract;
        uint256 tokenId;
        IAstariaRouter.LienDetails terms;
        bytes32 obligationRoot;
        uint256 amount;
        address vault;
        bool validateSlip;
    }

    struct LienActionBuyout {
        IAstariaRouter.Commitment incoming;
        uint256 position;
        address receiver;
    }

    function calculateSlope(uint256 lienId) external returns (uint256 slope);

    function changeInSlope(uint256 lienId, uint256 paymentAmount) external returns (uint256 slope);

    function stopLiens(uint256 collateralId)
        external
        returns (uint256 reserve, uint256[] memory amounts, uint256[] memory lienIds);

    function getBuyout(uint256 collateralId, uint256 index)
        external
        returns (uint256, uint256);

    function removeLiens(uint256 collateralId) external;

    function getInterest(uint256 collateralId, uint256 position)
        external
        view
        returns (uint256);

    function getLiens(uint256 _collateralId)
        external
        view
        returns (uint256[] memory);

    function getLien(uint256 lienId) external view returns (Lien memory);

    function getLien(uint256 collateralId, uint256 position)
        external
        view
        returns (Lien memory);

    function createLien(LienActionEncumber calldata params) external returns (uint256 lienId);

    function buyoutLien(LienActionBuyout calldata params) external;

    function makePayment(uint256 collateralId, uint256 paymentAmount) external;

    function getTotalDebtForCollateralToken(uint256 collateralId)
        external
        view
        returns (uint256 totalDebt);

    function getTotalDebtForCollateralToken(uint256 collateralId, uint256 timestamp)
        external
        view
        returns (uint256 totalDebt);
}

interface ILienToken is ILienBase, IERC721 {}
