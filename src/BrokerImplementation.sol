pragma solidity ^0.8.15;
import {ERC721, ERC721TokenReceiver} from "solmate/tokens/ERC721.sol";
import {ICollateralVault} from "./interfaces/ICollateralVault.sol";
import {ILienToken} from "./interfaces/ILienToken.sol";
import {IBrokerRouter} from "./interfaces/IBrokerRouter.sol";
import {IAuctionHouse} from "gpl/interfaces/IAuctionHouse.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {Base} from "gpl/ERC4626-Cloned.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {MerkleProof} from "openzeppelin/utils/cryptography/MerkleProof.sol";
import {ValidateTerms} from "./libraries/ValidateTerms.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {CollateralLookup} from "./libraries/CollateralLookup.sol";

abstract contract BrokerImplementation is ERC721TokenReceiver, Base {
    using SafeTransferLib for ERC20;
    using CollateralLookup for address;
    using ValidateTerms for IBrokerRouter.NewObligationRequest;
    using FixedPointMathLib for uint256;

    event NewObligation(
        bytes32 bondVault,
        address tokenContract,
        uint256 tokenId,
        uint256 amount
    );

    event Payment(uint256 collateralVault, uint256 index, uint256 amount);
    event Liquidation(
        uint256 collateralVault,
        bytes32[] bondVaults,
        uint256[] indexes,
        uint256 recovered
    );
    event NewBondVault(
        address appraiser,
        address broker,
        bytes32 bondVault,
        bytes32 contentHash,
        uint256 expiration
    );
    event RedeemBond(
        bytes32 bondVault,
        uint256 amount,
        address indexed redeemer
    );

    function onERC721Received(
        address operator_,
        address from_,
        uint256 tokenId_,
        bytes calldata data_
    ) external pure override returns (bytes4) {
        return ERC721TokenReceiver.onERC721Received.selector;
    }

    function _handleAppraiserReward(uint256) internal virtual {}

    //decode obligationData into structs
    function _decodeObligationData(
        uint8 obligationType,
        bytes memory obligationData
    ) internal view returns (IBrokerRouter.LienDetails memory) {
        if (obligationType == uint8(IBrokerRouter.ObligationType.STANDARD)) {
            IBrokerRouter.CollateralDetails memory cd = abi.decode(
                obligationData,
                (IBrokerRouter.CollateralDetails)
            );
            return (cd.lien);
        } else if (
            obligationType == uint8(IBrokerRouter.ObligationType.COLLECTION)
        ) {
            IBrokerRouter.CollectionDetails memory cd = abi.decode(
                obligationData,
                (IBrokerRouter.CollectionDetails)
            );
            return (cd.lien);
        } else {
            revert("unknown obligation type");
        }
    }

    event LogNor(IBrokerRouter.NewObligationRequest);
    event LogLien(IBrokerRouter.LienDetails);

    function _validateCommitment(
        IBrokerRouter.Commitment memory params,
        address receiver
    ) internal {
        uint256 collateralVault = params.tokenContract.computeId(
            params.tokenId
        );

        address operator = ERC721(COLLATERAL_VAULT()).getApproved(
            collateralVault
        );

        address owner = ERC721(COLLATERAL_VAULT()).ownerOf(collateralVault);

        if (msg.sender != owner) {
            require(msg.sender == operator, "invalid request");
        }

        if (receiver != owner) {
            require(
                receiver == operator ||
                    IBrokerRouter(router()).isValidVault(receiver),
                "can only issue funds to an operator that is approved by the owner"
            );
        }

        require(
            appraiser() != address(0),
            "BrokerImplementation._validateTerms(): Attempting to instantiate an unitialized vault"
        );

        (bool valid, IBrokerRouter.LienDetails memory ld) = params
            .nor
            .validateTerms(owner);

        require(
            valid,
            "Vault._validateTerms(): Verification of provided merkle branch failed for the vault and parameters"
        );

        //        IBrokerRouter.LienDetails memory ld = _decodeObligationData(
        //            params.nor.obligationType,
        //            params.nor.obligationDetails
        //        );
        require(
            ld.maxAmount >= params.nor.amount,
            "Vault._validateTerms(): Attempting to borrow more than maxAmount available for this asset"
        );

        uint256 seniorDebt = IBrokerRouter(router())
            .LIEN_TOKEN()
            .getTotalDebtForCollateralVault(
                params.tokenContract.computeId(params.tokenId)
            );
        require(
            seniorDebt <= ld.maxSeniorDebt,
            "Vault._validateTerms(): too much debt already for this loan"
        );
        require(
            params.nor.amount <= ERC20(asset()).balanceOf(address(this)),
            "Vault._validateTerms():  Attempting to borrow more than available in the specified vault"
        );

        //check that we aren't paused from reserves being too low
    }

    function commitToLoan(
        IBrokerRouter.Commitment memory params,
        address receiver
    ) external {
        _validateCommitment(params, receiver);
        _requestLienAndIssuePayout(params, receiver);
        _handleAppraiserReward(params.nor.amount);

        emit NewObligation(
            params.nor.obligationRoot,
            params.tokenContract,
            params.tokenId,
            params.nor.amount
        );
    }

    function canLiquidate(uint256 collateralVault, uint256 position)
        public
        view
        returns (bool)
    {
        return IBrokerRouter(router()).canLiquidate(collateralVault, position);
    }

    function buyoutLien(
        uint256 collateralVault,
        uint256 position,
        IBrokerRouter.Commitment memory incomingTerms
    ) external {
        (uint256 owed, uint256 buyout) = IBrokerRouter(router())
            .LIEN_TOKEN()
            .getBuyout(collateralVault, position);

        require(
            buyout <= ERC20(asset()).balanceOf(address(this)),
            "not enough balance to buy out loan"
        );
        incomingTerms.nor.amount = owed;

        _validateCommitment(incomingTerms, recipient());

        ERC20(asset()).safeApprove(
            address(IBrokerRouter(router()).TRANSFER_PROXY()),
            owed
        );
        IBrokerRouter(router()).LIEN_TOKEN().buyoutLien(
            ILienToken.LienActionBuyout(incomingTerms, position, recipient())
        );
    }

    function recipient() public view returns (address) {
        if (BROKER_TYPE() == uint256(1)) {
            return address(this);
        } else {
            return appraiser();
        }
    }

    function _requestLienAndIssuePayout(
        IBrokerRouter.Commitment memory c,
        address receiver
    ) internal {
        //address tokenContract;
        //        uint256 tokenId;
        //        IBrokerRouter.LienDetails terms;
        //        bytes32 obligationRoot;
        //        uint256 amount;
        //        address vault;
        //        bool borrowAndBuy;

        IBrokerRouter.LienDetails memory terms = ValidateTerms.getLienDetails(
            c.nor.obligationType,
            c.nor.obligationDetails
        );

        uint256 newLienId = IBrokerRouter(router()).requestLienPosition(
            ILienToken.LienActionEncumber(
                c.tokenContract,
                c.tokenId,
                terms,
                c.nor.obligationRoot,
                c.nor.amount,
                c.nor.strategy.vault,
                true
            )
        );
        address feeTo = IBrokerRouter(router()).feeTo();
        bool feeOn = feeTo != address(0);
        if (feeOn) {
            // uint256 rake = (amount * 997) / 1000;
            uint256 rake = c.nor.amount.mulDivDown(997, 1000);
            ERC20(asset()).safeTransfer(feeTo, rake);
            unchecked {
                c.nor.amount -= rake;
            }
        }
        ERC20(asset()).safeTransfer(receiver, c.nor.amount);
    }
}

interface IBroker {
    function deposit(uint256 assets, address receiver)
        external
        virtual
        returns (uint256 shares);
}

contract SoloBroker is BrokerImplementation, IBroker {
    using SafeTransferLib for ERC20;

    function _handleAppraiserReward(uint256 shares) internal virtual override {}

    function deposit(uint256 amount, address)
        external
        virtual
        returns (uint256)
    {
        require(
            msg.sender == appraiser(),
            "only the appraiser can fund this vault"
        );
        ERC20(asset()).safeTransferFrom(
            address(msg.sender),
            address(this),
            amount
        );
        return amount;
    }

    function withdraw(uint256 amount) external {
        require(
            msg.sender == appraiser(),
            "only the appraiser can exit this vault"
        );
        ERC20(asset()).safeTransferFrom(
            address(this),
            address(msg.sender),
            amount
        );
    }
}
