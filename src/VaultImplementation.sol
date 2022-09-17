pragma solidity ^0.8.16;

import {ERC721, ERC721TokenReceiver} from "solmate/tokens/ERC721.sol";
import {ILienBase, ILienToken} from "./interfaces/ILienToken.sol";
import {ICollateralToken} from "./interfaces/ICollateralToken.sol";
import {ILienToken} from "./interfaces/ILienToken.sol";
import {IAstariaRouter} from "./interfaces/IAstariaRouter.sol";
import {IAuctionHouse} from "gpl/interfaces/IAuctionHouse.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {IVault, VaultBase} from "gpl/ERC4626-Cloned.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {MerkleProof} from "openzeppelin/utils/cryptography/MerkleProof.sol";
import {ValidateTerms} from "./libraries/ValidateTerms.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {CollateralLookup} from "./libraries/CollateralLookup.sol";

/**
 * @title VaultImplementation
 * @author androolloyd
 * @notice A base implementation for the minimal features of an Astaria Vault.
 */
abstract contract VaultImplementation is ERC721TokenReceiver, VaultBase {
    using SafeTransferLib for ERC20;
    using CollateralLookup for address;
    using ValidateTerms for IAstariaRouter.NewLienRequest;
    using FixedPointMathLib for uint256;

    address public delegate; //account connected to the daemon

    event NewObligation(bytes32 strategyRoot, address tokenContract, uint256 tokenId, uint256 amount);

    event Payment(uint256 collateralId, uint256 index, uint256 amount);
    event NewVault(address appraiser, address vault);

    //    event RedeemBond(bytes32 bondVault, uint256 amount, address indexed redeemer);

    /**
     * @notice receive hook for ERC721 tokens, nothing special done
     */
    function onERC721Received(address operator_, address from_, uint256 tokenId_, bytes calldata data_)
        external
        pure
        override
        returns (bytes4)
    {
        return ERC721TokenReceiver.onERC721Received.selector;
    }

    modifier whenNotPaused() {
        if (IAstariaRouter(ROUTER()).paused()) {
            revert("protocol is paused");
        }
        _;
    }

    /**
     * @dev hook to allow inheriting contracts to perform payout for strategist
     */
    function _handleStrategistReward(uint256) internal virtual {}

    /**
     * @dev Decodes loan obligation data into structs.
     * @param obligationType The type of the obligation (STANDARD or COLLECTION)
     * @param obligationData The loan obligation data to decode.
     * @return The decoded Lien data.
     */
    function _decodeObligationData(uint8 obligationType, bytes memory obligationData)
        internal
        pure
        returns (IAstariaRouter.LienDetails memory)
    {
        if (obligationType == uint8(IAstariaRouter.LienRequestType.STANDARD)) {
            IAstariaRouter.CollateralDetails memory cd = abi.decode(obligationData, (IAstariaRouter.CollateralDetails));
            return (cd.lien);
        } else if (obligationType == uint8(IAstariaRouter.LienRequestType.COLLECTION)) {
            IAstariaRouter.CollectionDetails memory cd = abi.decode(obligationData, (IAstariaRouter.CollectionDetails));
            return (cd.lien);
        } else if (obligationType == uint8(IAstariaRouter.LienRequestType.UNIV3_LIQUIDITY)) {
            IAstariaRouter.UNIV3LiquidityDetails memory cd =
                abi.decode(obligationData, (IAstariaRouter.UNIV3LiquidityDetails));
            return (cd.lien);
        } else {
            revert("unknown obligation type");
        }
    }

    struct InitParams {
        address delegate;
    }

    function init(InitParams calldata params) external virtual {
        require(msg.sender == address(ROUTER()), "only router");

        if (params.delegate != address(0)) {
            delegate = params.delegate;
        }
    }

    modifier onlyOwner() {
        require(msg.sender == owner(), "only strategist");
        _;
    }

    function setDelegate(address delegate_) public onlyOwner {
        delegate = delegate_;
    }

    /**
     * @dev Validates the terms for a requested loan.
     * Who is requesting the borrow, is it a smart contract? or is it a user?
     * if a smart contract, then ensure that the contract is approved to borrow and is also receiving the funds.
     * if a user, then ensure that the user is approved to borrow and is also receiving the funds.
     * The terms are hashed and signed by the borrower, and the signature validated against the strategist's address
     * lien details are decoded from the obligation data and validated the collateral
     *
     * @param params The Commitment information containing the loan parameters and the merkle proof for the strategy supporting the requested loan.
     * @param receiver The address of the prospective borrower.
     */
    function _validateCommitment(IAstariaRouter.Commitment memory params, address receiver) internal {
        uint256 collateralId = params.tokenContract.computeId(params.tokenId);

        address operator = ERC721(COLLATERAL_TOKEN()).getApproved(collateralId);

        address holder = ERC721(COLLATERAL_TOKEN()).ownerOf(collateralId);

        if (msg.sender != holder) {
            require(msg.sender == operator, "invalid request");
        }

        if (receiver != holder) {
            require(
                receiver == operator || IAstariaRouter(ROUTER()).isValidVault(receiver),
                "can only issue funds to an operator that is approved by the owner"
            );
        }

        require(
            owner() != address(0),
            "VaultImplementation._validateTerms(): Attempting to instantiate an unitialized vault"
        );

        address recovered = ecrecover(
            params.lienRequest.obligationRoot, params.lienRequest.v, params.lienRequest.r, params.lienRequest.s
        );
        require(recovered == owner() || recovered == delegate, "invalid signature");

        (bool valid, IAstariaRouter.LienDetails memory ld) =
            params.lienRequest.validateTerms(holder, params.tokenContract, params.tokenId);

        require(
            valid, "Vault._validateTerms(): Verification of provided merkle branch failed for the vault and parameters"
        );

        require(
            ld.maxAmount >= params.lienRequest.amount,
            "Vault._validateTerms(): Attempting to borrow more than maxAmount available for this asset"
        );

        uint256 seniorDebt = IAstariaRouter(ROUTER()).LIEN_TOKEN().getTotalDebtForCollateralToken(
            params.tokenContract.computeId(params.tokenId)
        );
        require(seniorDebt <= ld.maxSeniorDebt, "Vault._validateTerms(): too much debt already for this loan");
        require(
            params.lienRequest.amount <= ERC20(underlying()).balanceOf(address(this)),
            "Vault._validateTerms():  Attempting to borrow more than available in the specified vault"
        );

        //check that we aren't paused from reserves being too low
    }

    function _afterCommitToLien(uint256 lienId, uint256 amount) internal virtual {}

    /**
     * @notice Pipeline for lifecycle of new loan origination.
     * Origination consists of a few phases: pre-commitment validation, lien token issuance, strategist reward, and after commitment actions
     * Starts by depositing collateral and take out a lien against it. Next, verifies the merkle proof for a loan commitment. Vault owners are then rewarded fees for successful loan origination.
     * @param params Commitment data for the incoming lien request
     * @param receiver The borrower receiving the loan.
     */
    function commitToLien(IAstariaRouter.Commitment memory params, address receiver) external whenNotPaused {
        _validateCommitment(params, receiver);
        uint256 lienId = _requestLienAndIssuePayout(params, receiver);
        _handleStrategistReward(params.lienRequest.amount);
        _afterCommitToLien(lienId, params.lienRequest.amount);
        emit NewObligation(
            params.lienRequest.obligationRoot, params.tokenContract, params.tokenId, params.lienRequest.amount
            );
    }

    /**
     * @notice Returns whether a specific lien can be liquidated.
     * @param collateralId The ID of the underlying CollateralToken.
     * @param position The specified lien position.
     * @return A boolean value indicating whether the specified lien can be liquidated.
     */
    function canLiquidate(uint256 collateralId, uint256 position) public view returns (bool) {
        return IAstariaRouter(ROUTER()).canLiquidate(collateralId, position);
    }

    /**
     * @notice Buy out a lien to replace it with new terms.
     * @param collateralId The ID of the underlying CollateralToken.
     * @param position The position of the specified lien.
     * @param incomingTerms The loan terms of the new lien.
     */
    function buyoutLien(uint256 collateralId, uint256 position, IAstariaRouter.Commitment memory incomingTerms)
        external
        whenNotPaused
    {
        (uint256 owed, uint256 buyout) = IAstariaRouter(ROUTER()).LIEN_TOKEN().getBuyout(collateralId, position);

        require(buyout <= ERC20(underlying()).balanceOf(address(this)), "not enough balance to buy out loan");
        incomingTerms.lienRequest.amount = owed;

        _validateCommitment(incomingTerms, recipient());

        ERC20(underlying()).safeApprove(address(IAstariaRouter(ROUTER()).TRANSFER_PROXY()), buyout);
        IAstariaRouter(ROUTER()).LIEN_TOKEN().buyoutLien(
            ILienBase.LienActionBuyout(incomingTerms, position, recipient())
        );
    }

    /**
     * @notice Retrieves the recipient of loan repayments. For PublicVaults (VAULT_TYPE 2), this is always the vault address. For PrivateVaults, retrieves the owner() of the vault.
     * @return The address of the recipient.
     */
    function recipient() public view returns (address) {
        if (VAULT_TYPE() == uint256(2)) {
            return address(this);
        } else {
            return owner();
        }
    }

    /**
     * @dev Generates a Lien for a valid loan commitment proof and sends the loan amount to the borrower.
     * @param c The Commitment information containing the loan parameters and the merkle proof for the strategy supporting the requested loan.
     * @param receiver The borrower requesting the loan.
     * @return The ID of the created Lien.
     */
    function _requestLienAndIssuePayout(IAstariaRouter.Commitment memory c, address receiver)
        internal
        returns (uint256)
    {
        IAstariaRouter.LienDetails memory terms = c.lienRequest.getLienDetails();

        uint256 newLienId = IAstariaRouter(ROUTER()).requestLienPosition(
            ILienBase.LienActionEncumber(
                c.tokenContract,
                c.tokenId,
                terms,
                c.lienRequest.obligationRoot,
                c.lienRequest.amount,
                c.lienRequest.strategy.vault,
                true
            )
        );
        address feeTo = IAstariaRouter(ROUTER()).feeTo();
        bool feeOn = feeTo != address(0);
        if (feeOn) {
            // uint256 rake = (amount * 997) / 1000;
            uint256 rake = c.lienRequest.amount.mulDivDown(997, 1000); // TODO don't hardcode
            ERC20(underlying()).safeTransfer(feeTo, rake);
            unchecked {
                c.lienRequest.amount -= rake;
            }
        }
        ERC20(underlying()).safeTransfer(receiver, c.lienRequest.amount);
        return newLienId;
    }
}
