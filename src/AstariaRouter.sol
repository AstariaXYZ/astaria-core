pragma solidity ^0.8.16;

import {Auth, Authority} from "solmate/auth/Auth.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {IERC721} from "gpl/interfaces/IERC721.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {IAuctionHouse} from "gpl/interfaces/IAuctionHouse.sol";
import {ClonesWithImmutableArgs} from "clones-with-immutable-args/ClonesWithImmutableArgs.sol";
import {ICollateralToken} from "./interfaces/ICollateralToken.sol";
import {ClonesWithImmutableArgs} from "clones-with-immutable-args/ClonesWithImmutableArgs.sol";
import {ILienBase, ILienToken} from "./interfaces/ILienToken.sol";
import {CollateralLookup} from "./libraries/CollateralLookup.sol";
import {LiquidationAccountant} from "./LiquidationAccountant.sol";
import {ITransferProxy} from "./interfaces/ITransferProxy.sol";
import {IAstariaRouter} from "./interfaces/IAstariaRouter.sol";
import {IVault, VaultImplementation} from "./VaultImplementation.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {Pausable} from "./utils/Pausable.sol";
import {ValidateTerms} from "./libraries/ValidateTerms.sol";
import {PublicVault} from "./PublicVault.sol";

interface IInvoker {
    function onBorrowAndBuy(bytes calldata data, address token, uint256 amount, address payable recipient)
        external
        returns (bool);
}

/**
 * @title AstariaRouter
 * @notice This contract manages the deployment of Vaults and universal Astaria actions.
 */
contract AstariaRouter is Auth, Pausable, IAstariaRouter {
    using SafeTransferLib for ERC20;
    using CollateralLookup for address;
    using FixedPointMathLib for uint256;
    using ValidateTerms for NewLienRequest;

    ERC20 public immutable WETH;
    ICollateralToken public immutable COLLATERAL_TOKEN;
    ILienToken public immutable LIEN_TOKEN;
    ITransferProxy public immutable TRANSFER_PROXY;
    address public VAULT_IMPLEMENTATION;
    address public SOLO_IMPLEMENTATION;
    address public WITHDRAW_IMPLEMENTATION;
    address public LIQUIDATION_IMPLEMENTATION;

    address public feeTo;

    uint256 public LIQUIDATION_FEE_PERCENT;
    uint256 public STRATEGIST_ORIGINATION_FEE_NUMERATOR;
    uint256 public STRATEGIST_ORIGINATION_FEE_BASE;
    uint256 public MIN_INTEREST_BPS; // was uint64
    uint64 public MIN_DURATION_INCREASE;
    uint256 public MIN_EPOCH_LENGTH;
    uint256 public MAX_EPOCH_LENGTH;

    //public vault contract => appraiser
    mapping(address => address) public vaults;
    mapping(address => uint256) public appraiserNonce;

    // See https://eips.ethereum.org/EIPS/eip-191

    /**
     * @dev Setup transfer authority and set up addresses for deployed CollateralToken, LienToken, TransferProxy contracts, as well as PublicVault and SoloVault implementations to clone.
     * @param _AUTHORITY The authority manager.
     * @param _WETH The WETH address to use for transfers.
     * @param _COLLATERAL_TOKEN The address of the deployed CollateralToken contract.
     * @param _LIEN_TOKEN The address of the deployed LienToken contract.
     * @param _TRANSFER_PROXY The address of the deployed TransferProxy contract.
     * @param _VAULT_IMPL The address of a base implementation of VaultImplementation for cloning.
     * @param _SOLO_IMPL The address of a base implementation of a PrivateVault for cloning.
     */
    constructor(
        Authority _AUTHORITY,
        address _WETH,
        address _COLLATERAL_TOKEN,
        address _LIEN_TOKEN,
        address _TRANSFER_PROXY,
        address _VAULT_IMPL,
        address _SOLO_IMPL
    )
        Auth(address(msg.sender), _AUTHORITY)
    {
        WETH = ERC20(_WETH);
        COLLATERAL_TOKEN = ICollateralToken(_COLLATERAL_TOKEN);
        LIEN_TOKEN = ILienToken(_LIEN_TOKEN);
        TRANSFER_PROXY = ITransferProxy(_TRANSFER_PROXY);
        VAULT_IMPLEMENTATION = _VAULT_IMPL;
        SOLO_IMPLEMENTATION = _SOLO_IMPL;
        LIQUIDATION_FEE_PERCENT = 13;
        MIN_INTEREST_BPS = uint256(0.0005 ether) / uint256(365 * 1 days); //5 bips / second
        STRATEGIST_ORIGINATION_FEE_NUMERATOR = 200;
        STRATEGIST_ORIGINATION_FEE_BASE = 1000;
        MIN_DURATION_INCREASE = 14 days;
    }

    /**
     * @dev Enables _pause, freezing functions with the whenNotPaused modifier. TODO specify affected contracts?
     */
    function __emergencyPause() external requiresAuth whenNotPaused {
        _pause();
    }

    /**
     * @dev Disables _pause, un-freezing functions with the whenNotPaused modifier.
     */
    function __emergencyUnpause() external requiresAuth whenPaused {
        _unpause();
    }

    /**
     * @notice Sets universal protocol parameters or changes the addresses for deployed contracts.
     * @param what The identifier for what is being filed.
     * @param data The encoded address data to be decoded and filed.
     */
    function file(bytes32 what, bytes calldata data) public requiresAuth {
        if (what == "LIQUIDATION_FEE_PERCENT") {
            uint256 value = abi.decode(data, (uint256));
            LIQUIDATION_FEE_PERCENT = value;
        } else if (what == "MIN_INTEREST_BPS") {
            uint256 value = abi.decode(data, (uint256));
            MIN_INTEREST_BPS = uint256(value);
        } else if (what == "APPRAISER_NUMERATOR") {
            uint256 value = abi.decode(data, (uint256));
            STRATEGIST_ORIGINATION_FEE_NUMERATOR = value;
        } else if (what == "APPRAISER_ORIGINATION_FEE_BASE") {
            uint256 value = abi.decode(data, (uint256));
            STRATEGIST_ORIGINATION_FEE_BASE = value;
        } else if (what == "MIN_DURATION_INCREASE") {
            uint256 value = abi.decode(data, (uint256));
            MIN_DURATION_INCREASE = uint64(value);
        } else if (what == "feeTo") {
            address addr = abi.decode(data, (address));
            feeTo = addr;
        } else if (what == "WITHDRAW_IMPLEMENTATION") {
            address addr = abi.decode(data, (address));
            WITHDRAW_IMPLEMENTATION = addr;
        } else if (what == "LIQUIDATION_IMPLEMENTATION") {
            address addr = abi.decode(data, (address));
            LIQUIDATION_IMPLEMENTATION = addr;
        } else if (what == "VAULT_IMPLEMENTATION") {
            address addr = abi.decode(data, (address));
            VAULT_IMPLEMENTATION = addr;
        } else if (what == "SOLO_IMPLEMENTATION") {
            address addr = abi.decode(data, (address));
            SOLO_IMPLEMENTATION = addr;
        } else if (what == "MIN_EPOCH_LENGTH") {
            MIN_EPOCH_LENGTH = abi.decode(data, (uint256));
        } else if (what == "MAX_EPOCH_LENGTH") {
            MAX_EPOCH_LENGTH = abi.decode(data, (uint256));
        } else {
            revert("unsupported/file");
        }
    }

    /**
     * @notice Files multiple parameters and/or addresses at once.
     * @param what The identifiers for what is being filed.
     * @param data The encoded address data to be decoded and filed.
     */
    function file(bytes32[] memory what, bytes[] calldata data) external requiresAuth {
        require(what.length == data.length, "data length mismatch");
        for (uint256 i = 0; i < what.length; i++) {
            file(what[i], data[i]);
        }
    }

    // MODIFIERS
    modifier onlyVaults() {
        require(vaults[msg.sender] != address(0), "this vault has not been initialized");
        _;
    }

    //PUBLIC

    //todo: check all incoming obligations for validity
    /**
     * @notice Deposits collateral and requests loans for multiple NFTs at once.
     * @param commitments The commitment proofs and requested loan data for each loan.
     * @return totalBorrowed The total amount borrowed by the requested loans.
     */
    function commitToLiens(IAstariaRouter.Commitment[] calldata commitments)
        external
        whenNotPaused
        returns (uint256 totalBorrowed)
    {
        totalBorrowed = 0;
        for (uint256 i = 0; i < commitments.length; ++i) {
            _transferAndDepositAsset(commitments[i].tokenContract, commitments[i].tokenId);
            totalBorrowed += _executeCommitment(commitments[i]);

            uint256 collateralId = commitments[i].tokenContract.computeId(commitments[i].tokenId);
            _returnCollateral(collateralId, address(msg.sender));
        }
        WETH.safeApprove(address(TRANSFER_PROXY), totalBorrowed);
        TRANSFER_PROXY.tokenTransferFrom(address(WETH), address(this), address(msg.sender), totalBorrowed);
    }

    // verifies the signature on the root of the merkle tree to be the appraiser
    // we need an additional method to prevent a griefing attack where the signature is stripped off and reserrved by an attacker

    /**
     * @notice Deploys a new PrivateVault.
     * @return The address of the new PrivateVault.
     */
    function newVault() external whenNotPaused returns (address) {
        return _newVault(uint256(0));
    }

    /**
     * @notice Deploys a new PublicVault.
     * @param epochLength The length of each epoch for the new PublicVault.
     */
    function newPublicVault(uint256 epochLength) external whenNotPaused returns (address) {
        return _newVault(epochLength);
    }

    //    function borrowAndBuy(BorrowAndBuyParams memory params) external {
    //        uint256 spendableBalance;
    //        for (uint256 i = 0; i < params.commitments.length; ++i) {
    //            _executeCommitment(params.commitments[i]);
    //            spendableBalance += params.commitments[i].amount; //amount borrowed
    //        }
    //        require(
    //            params.purchasePrice <= spendableBalance,
    //            "purchase price cannot be for more than your aggregate loan"
    //        );
    //
    //        WETH.safeApprove(params.invoker, params.purchasePrice);
    //        require(
    //            IInvoker(params.invoker).onBorrowAndBuy(
    //                params.purchaseData, // calldata for the invoker
    //                address(WETH), // token
    //                params.purchasePrice, //max approval
    //                payable(msg.sender) // recipient
    //            ),
    //            "borrow and buy failed"
    //        );
    //        if (spendableBalance - params.purchasePrice > uint256(0)) {
    //            WETH.safeTransfer(
    //                msg.sender,
    //                spendableBalance - params.purchasePrice
    //            );
    //        }
    //    }

    /**
     * @notice Buy out a lien to replace it with new terms.
     * @param position The position of the lien to be replaced.
     * @param incomingTerms The terms of the new lien.
     */
    function buyoutLien(
        uint256 position,
        IAstariaRouter.Commitment memory incomingTerms //        onlyNetworkBrokers( //            outgoingTerms.collateralId, //            outgoingTerms.position //        )
    )
        external
        whenNotPaused
    {
        VaultImplementation(incomingTerms.lienRequest.strategy.vault).buyoutLien(
            incomingTerms.tokenContract.computeId(incomingTerms.tokenId), position, incomingTerms
        );
    }

    /**
     * @notice Create a new lien against a CollateralToken.
     * @param params The valid proof and lien details for the new loan.
     * @return The ID of the created lien.
     */
    function requestLienPosition(ILienBase.LienActionEncumber calldata params)
        external
        whenNotPaused
        onlyVaults
        returns (uint256)
    {
        return LIEN_TOKEN.createLien(params);
    }

    /**
     * @notice Lend to a PublicVault.
     * @param vault The address of the PublicVault.
     * @param amount The amount to lend.
     */
    function lendToVault(address vault, uint256 amount) external whenNotPaused {
        TRANSFER_PROXY.tokenTransferFrom(address(WETH), address(msg.sender), address(this), amount);

        require(vaults[vault] != address(0), "lendToVault: vault doesn't exist");
        WETH.safeApprove(vault, amount);
        IVault(vault).deposit(amount, address(msg.sender));
    }

    /**
     * @notice Returns whether a specific lien can be liquidated.
     * @param collateralId The ID of the underlying CollateralToken.
     * @param position The specified lien position.
     * @return A boolean value indicating whether the specified lien can be liquidated.
     */
    function canLiquidate(uint256 collateralId, uint256 position) public view returns (bool) {
        ILienToken.Lien memory lien = LIEN_TOKEN.getLien(collateralId, position);

        // uint256 interestAccrued = LIEN_TOKEN.getInterest(collateralId, position);
        // uint256 maxInterest = (lien.amount * lien.schedule) / 100

        return (lien.start + lien.duration <= block.timestamp && lien.amount > 0);
    }

    // person calling liquidate should get some incentive from the auction
    /**
     * @notice Liquidate a CollateralToken that has defaulted on one of its liens.
     * @param collateralId The ID of the CollateralToken.
     * @param position The position of the defaulted lien.
     * @return reserve The amount owed on all liens for against the collateral being liquidated, including accrued interest.
     */
    function liquidate(uint256 collateralId, uint256 position) external returns (uint256 reserve) {
        require(canLiquidate(collateralId, position), "liquidate: borrow is healthy");

        // if expiration will be past epoch boundary, then create a LiquidationAccountant

        uint256[] memory liens = LIEN_TOKEN.getLiens(collateralId);

        for (uint256 i = 0; i < liens.length; ++i) {
            uint256 currentLien = liens[i];

            ILienToken.Lien memory lien = LIEN_TOKEN.getLien(currentLien);

            if (
                VaultImplementation(lien.vault).VAULT_TYPE() == uint256(2)
                    && PublicVault(lien.vault).timeToEpochEnd() <= COLLATERAL_TOKEN.AUCTION_WINDOW()
            ) {
                uint64 currentEpoch = PublicVault(lien.vault).getCurrentEpoch();

                address accountant = PublicVault(lien.vault).getLiquidationAccountant(currentEpoch);

                if (accountant == address(0)) {
                    accountant = PublicVault(lien.vault).deployLiquidationAccountant();
                }
                LIEN_TOKEN.setPayee(currentLien, accountant);
                LiquidationAccountant(accountant).handleNewLiquidation(
                    lien.amount, COLLATERAL_TOKEN.AUCTION_WINDOW() + 1 days
                );
            }
        }

        reserve = COLLATERAL_TOKEN.auctionVault(collateralId, address(msg.sender), LIQUIDATION_FEE_PERCENT);

        emit Liquidation(collateralId, position, reserve);
    }

    /**
     * @notice Retrieves the fee PublicVault strategists earn on loan origination.
     * @return The numerator and denominator used to compute the percentage fee strategists earn by receiving minted vault shares. TODO reword
     */
    function getStrategistFee() external view returns (uint256, uint256) {
        return (STRATEGIST_ORIGINATION_FEE_NUMERATOR, STRATEGIST_ORIGINATION_FEE_BASE);
    }

    /**
     * @notice Returns whether a given address is that of a Vault.
     * @param vault The Vault address.
     * @return A boolean representing whether the address exists as a Vault.
     */
    function isValidVault(address vault) external view returns (bool) {
        return vaults[vault] != address(0);
    }

    event Data(uint256 rate, uint256 bps);

    /**
     * @notice Determines whether a potential refinance meets the minimum requirements for replacing a lien.
     * @param lien The Lien to be refinanced.
     * @param newLien The new Lien to replace the existing one.
     * @return A boolean representing whether the potential refinance is valid.
     */
    function isValidRefinance(ILienToken.Lien memory lien, LienDetails memory newLien) external returns (bool) {
        uint256 minNewRate = uint256(lien.rate) - MIN_INTEREST_BPS;

        return (
            newLien.rate <= minNewRate
                && ((block.timestamp + newLien.duration - lien.start + lien.duration) > MIN_DURATION_INCREASE)
        );
    }

    //INTERNAL FUNCS

    /**
     * @dev Deploys a new PublicVault.
     * @param epochLength The length of each epoch for the new PublicVault.
     * @return The address for the new PublicVault.
     */
    function _newVault(uint256 epochLength) internal returns (address) {
        uint256 brokerType;

        address implementation;
        if (epochLength > uint256(0)) {
            require(
                epochLength >= MIN_EPOCH_LENGTH || epochLength <= MAX_EPOCH_LENGTH,
                "epochLength must be greater than or equal to MIN_EPOCH_LENGTH and less than MAX_EPOCH_LENGTH"
            );
            implementation = VAULT_IMPLEMENTATION;
            brokerType = 2;
        } else {
            implementation = SOLO_IMPLEMENTATION;
            brokerType = 1;
        }

        address vaultAddr = ClonesWithImmutableArgs.clone(
            implementation,
            abi.encodePacked(
                address(msg.sender),
                address(WETH),
                address(COLLATERAL_TOKEN),
                address(this),
                address(COLLATERAL_TOKEN.AUCTION_HOUSE()),
                block.timestamp,
                epochLength,
                brokerType
            )
        );

        vaults[vaultAddr] = msg.sender;

        emit NewVault(msg.sender, vaultAddr);

        return vaultAddr;
    }

    /**
     * @dev validates msg sender is owner
     * @param c The commitment Data
     * @return the amount borrowed
     */
    function _executeCommitment(IAstariaRouter.Commitment memory c) internal returns (uint256) {
        uint256 collateralId = c.tokenContract.computeId(c.tokenId);
        require(msg.sender == COLLATERAL_TOKEN.ownerOf(collateralId), "invalid sender for collateralId");
        return _borrow(c, address(this));
    }

    function _borrow(IAstariaRouter.Commitment memory c, address receiver) internal returns (uint256) {
        //router must be approved for the collateral to take a loan,
        VaultImplementation(c.lienRequest.strategy.vault).commitToLien(c, receiver);
        if (receiver == address(this)) {
            return c.lienRequest.amount;
        }
        return uint256(0);
    }

    function _transferAndDepositAsset(address tokenContract, uint256 tokenId) internal {
        IERC721(tokenContract).safeTransferFrom(address(msg.sender), address(COLLATERAL_TOKEN), tokenId, "");
    }

    function _returnCollateral(uint256 collateralId, address receiver) internal {
        COLLATERAL_TOKEN.transferFrom(address(this), receiver, collateralId);
    }
}
