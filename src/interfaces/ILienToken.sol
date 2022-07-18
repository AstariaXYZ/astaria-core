pragma solidity ^0.8.13;
import {IERC721} from "openzeppelin/token/ERC721/IERC721.sol";
import {IBrokerRouter} from "./IBrokerRouter.sol";

interface ILienToken is IERC721 {
    struct Lien {
        uint256 amount; //32
        //        uint256 maxDebt; //32
        address token; // 20
        //        address broker; // 20
        bool active; // 1
        uint32 rate; // 4
        //        uint32 maxRate; // 4
        uint32 duration; //4
        uint32 last; // 4
        uint32 start; // 4
        uint32 schedule; // 4
    }

    struct LienActionEncumber {
        IBrokerRouter.Terms terms;
        uint256 amount;
    }

    struct LienActionBuyout {
        IBrokerRouter.Terms incoming;
        uint256 position;
        address receiver;
    }

    struct SubjugationOffer {
        uint256 collateralVault;
        uint256 lien;
        uint256 currentPosition;
        uint256 lowestPosition;
        uint256 price;
        uint256 deadline;
        address token;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    struct LienActionSwap {
        SubjugationOffer offer;
        uint256 replacementLien;
        uint256 replacementPosition;
    }

    function stopLiens(uint256 collateralVault)
        external
        returns (
            uint256 reserve,
            uint256[] memory amounts,
            uint256[] memory lienIds
        );

    function getBuyout(uint256 collateralVault, uint256 index)
        external
        view
        returns (uint256, uint256);

    function removeLiens(uint256 collateralVault) external;

    function getInterest(uint256 collateralVault, uint256 position)
        external
        view
        returns (uint256);

    function getLiens(uint256 _starId) external view returns (uint256[] memory);

    function getLien(uint256 lienId) external view returns (Lien memory);

    function getLien(uint256 collateralVault, uint256 position)
        external
        view
        returns (Lien memory);

    function setAuctionHouse(address) external;

    function createLien(LienActionEncumber calldata params)
        external
        returns (uint256 lienId);

    function encodeSubjugationOffer(
        uint256 collateralVault,
        uint256 lien,
        uint256 currentPosition,
        uint256 lowestPosition,
        uint256 price,
        uint256 deadline
    ) external view returns (bytes memory);

    function buyoutLien(LienActionBuyout calldata params) external;

    function makePayment(uint256 collateralVault, uint256 paymentAmount)
        external;

    function getTotalDebtForCollateralVault(uint256 collateralVault)
        external
        view
        returns (uint256 totalDebt);

    function getTotalDebtForCollateralVault(
        uint256 collateralVault,
        uint256 timestamp
    ) external view returns (uint256 totalDebt);
}
