pragma solidity ^0.8.0;
import {IERC721} from "openzeppelin/token/ERC721/IERC721.sol";

interface IStarNFT is IERC721 {
    struct Lien {
        //        address broker;
        //        uint256 index;
        uint256 lienId;
        uint256 amount;
        uint32 last;
        uint32 end;
        uint32 rate;
        //        uint16 buyout;
        //        address appraiser;
        bytes32 root;
        //        uint256 rate;
        //        uint256 duration;
        //        uint256 schedule;
        //        uint256 buyoutRate;
        //        uint256 resolution; //if 0, unresolved lien, set to resolved 1
        //        address resolver; //IResolver contract, interface for sending to beacon proxy
        //        interfaceID: bytes4; support for many token types, 777 1155 etc, imagine fractional art being a currency for loans ??
        //interfaceId: btyes4; could just be emitted when lien is created, what the interface needed to call this this vs storage
    }

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

    function getTotalLiens(uint256) external returns (uint256);

    function validateTerms(IStarNFT.Terms memory params)
        external
        view
        returns (bool);

    function validateTerms(
        bytes32[] memory proof,
        uint256 collateralVault,
        uint256 maxAmount,
        uint256 interestRate,
        uint256 duration,
        uint256 position,
        uint256 schedule
    ) external view returns (bool);

    function getInterest(uint256 collateralVault, uint256 position)
        external
        view
        returns (uint256);

    function getLien(uint256 _starId, uint256 _position)
        external
        view
        returns (Lien memory);

    function burnLien(uint256 _lienId) external;

    function getLiens(uint256 _starId) external view returns (Lien[] memory);

    function manageLien(LienAction _action, bytes calldata _lienData) external;

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
