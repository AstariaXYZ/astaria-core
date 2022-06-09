pragma solidity ^0.8.0;
import {IERC721} from "openzeppelin/token/ERC721/IERC721.sol";

interface ICollateralVault is IERC721 {
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

    enum LienAction {
        ENCUMBER,
        UN_ENCUMBER,
        SWAP_VAULT,
        UPDATE_LIEN
    }

    struct LienActionEncumber {
        Terms terms;
        uint256 amount;
    }
    struct LienActionUnEncumber {
        uint256 collateralVault;
        uint256 position;
    }

    struct LienActionSwap {
        uint256 collateralVault;
        LienActionUnEncumber outgoing;
        LienActionEncumber incoming;
    }

    function auctionVault(
        Terms memory params,
        address initiator,
        uint256 initiatorFee
    ) external returns (uint256);

    function getUnderlyingFromStar(uint256 starId_)
        external
        view
        returns (address, uint256);
}
