pragma solidity ^0.8.17;

import {Auth, Authority} from "solmate/auth/Auth.sol";
import {VaultImplementation} from "./VaultImplementation.sol";
import {IVault, ERC4626Cloned, ITokenBase, ERC4626Base, AstariaVaultBase} from "gpl/ERC4626-Cloned.sol";
import {ERC4626} from "solmate/mixins/ERC4626.sol";
import {IERC721, IERC165} from "gpl/interfaces/IERC721.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {IAstariaRouter} from "./interfaces/IAstariaRouter.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {ILienToken} from "./interfaces/ILienToken.sol";
import {LienToken} from "./LienToken.sol";
import {WithdrawProxy} from "./WithdrawProxy.sol";
import {ClonesWithImmutableArgs} from "clones-with-immutable-args/ClonesWithImmutableArgs.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {LiquidationAccountant} from "./LiquidationAccountant.sol";
import {Pausable} from "./utils/Pausable.sol";

interface IPublicVault is IERC165 {
    function beforePayment(uint256 escrowId, uint256 amount) external;

    function afterPayment(uint256 lienId) external;
}

/**
 * @title Vault
 * @author androolloyd
 */
contract Vault is AstariaVaultBase, VaultImplementation, IVault {
    using SafeTransferLib for ERC20;

    function name() public view override returns (string memory) {
        return string(abi.encodePacked("AST-Vault-", ERC20(underlying()).symbol()));
    }

    function symbol() public view override returns (string memory) {
        return string(abi.encodePacked("AST-V", owner(), "-", ERC20(underlying()).symbol()));
    }

    function _handleStrategistInterestReward(uint256 lienId, uint256 shares) internal virtual override {}

    function deposit(uint256 amount, address) public virtual override returns (uint256) {
        require(msg.sender == owner(), "only the appraiser can fund this vault");
        ERC20(underlying()).safeTransferFrom(address(msg.sender), address(this), amount);
        return amount;
    }

    function withdraw(uint256 amount) external {
        require(msg.sender == owner(), "only the appraiser can exit this vault");
        ERC20(underlying()).safeTransferFrom(address(this), address(msg.sender), amount);
    }
}

/*
 * @title PublicVault
 * @author androolloyd
 * @notice
 */
contract PublicVault is Vault, IPublicVault, ERC4626Cloned {
    using FixedPointMathLib for uint256;
    using SafeTransferLib for ERC20;

    // epoch seconds when yIntercept was calculated last
    uint256 last;
    // sum of all LienToken amounts
    uint256 yIntercept;
    // sum of all slopes of each LienToken
    uint256 slope;

    // block.timestamp of first epoch
    uint256 withdrawReserve = 0;
    uint256 liquidationWithdrawRatio = 0;
    uint256 strategistUnclaimedShares = 0;
    uint64 public currentEpoch = 0;

    //mapping of epoch to number of open liens
    mapping(uint64 => uint256) public liensOpenForEpoch;
    // WithdrawProxies and LiquidationAccountants for each epoch.
    // The first possible WithdrawProxy and LiquidationAccountant starts at index 0, i.e. an LP that marks a withdraw in epoch 0 to collect by the end of epoch *1* would use the 0th WithdrawProxy.
    mapping(uint64 => address) public withdrawProxies;
    mapping(uint64 => address) public liquidationAccountants;

    event YInterceptChanged(uint256 newYintercept);
    event WithdrawReserveTransferred(uint256 amount);

    function underlying() public view virtual override (ERC4626Base, AstariaVaultBase) returns (address) {
        return super.underlying();
    }

    /**
     * @notice Signal a withdrawal of funds (redeeming for underlying asset) in the next epoch.
     * @param shares The number of VaultToken shares to redeem.
     * @param receiver The receiver of the WithdrawTokens (and eventual underlying asset)
     * @param owner The owner of the VaultTokens.
     * @return assets The amount of the underlying asset redeemed.
     */
    function redeem(uint256 shares, address receiver, address owner) public virtual override returns (uint256 assets) {
        assets = redeemFutureEpoch(shares, receiver, owner, currentEpoch);
    }

    function withdraw(uint256 assets, address receiver, address owner)
        public
        virtual
        override
        returns (uint256 shares)
    {
        shares = previewWithdraw(assets);
        redeemFutureEpoch(shares, receiver, owner, currentEpoch);
    }

    /**
     * @notice Signal a withdrawal of funds (redeeming for underlying asset) in an arbitrary future epoch.
     * @param shares The number of VaultToken shares to redeem.
     * @param receiver The receiver of the WithdrawTokens (and eventual underlying asset)
     * @param owner The owner of the VaultTokens.
     * @param epoch The epoch to withdraw for.
     * @return assets The amount of the underlying asset redeemed.
     */
    function redeemFutureEpoch(uint256 shares, address receiver, address owner, uint64 epoch)
        public
        virtual
        returns (uint256 assets)
    {
        // check to ensure that the requested epoch is not the current epoch or in the past
        require(epoch >= currentEpoch, "Exit epoch too low");

        // check for rounding error since we round down in previewRedeem.
        // require((assets = previewRedeem(shares)) != 0, "ZERO_ASSETS");

        beforeWithdraw(assets, shares);

        //todo: should we burn them? or do we need their supply to be maintained?
        //        transferFrom(owner, address(this), shares);
        _burn(owner, shares);
        // Deploy WithdrawProxy if no WithdrawProxy exists for the specified epoch
        if (withdrawProxies[epoch] == address(0)) {
            address proxy = ClonesWithImmutableArgs.clone(
                IAstariaRouter(ROUTER()).WITHDRAW_IMPLEMENTATION(),
                abi.encodePacked(
                    address(this), //owner
                    underlying() //token
                )
            );
            withdrawProxies[epoch] = proxy;
        }

        emit Withdraw(msg.sender, receiver, owner, assets, shares);

        // WithdrawProxy shares are minted 1:1 with PublicVault shares
        WithdrawProxy(withdrawProxies[epoch]).mint(receiver, shares); // was withdrawProxies[withdrawEpoch]
    }

    /**
     * @notice Deposit funds into the PublicVault.
     * @param amount The amount of funds to deposit.
     * @param receiver The receiver of the resulting VaultToken shares.
     */
    function deposit(uint256 amount, address receiver)
        public
        override (Vault, ERC4626Cloned)
        whenNotPaused
        returns (uint256)
    {
        return super.deposit(amount, receiver);
    }

    /**
     * @notice Retrieve the domain separator.
     * @return The domain separator.
     */
    function computeDomainSeparator() internal view override returns (bytes32) {
        return super.domainSeparator();
    }

    // needs to be called in the epoch boundary before the next epoch can start
    //TODO: well need to expand this to be able to be run across a number of txns
    /**
     * @notice Roate epoch boundary. This must be called before the next epoch can begin.
     */
    function processEpoch() external {
        // check to make sure epoch is over
        require(START() + ((currentEpoch + 1) * EPOCH_LENGTH()) < block.timestamp, "Epoch has not ended");
        if (liquidationAccountants[currentEpoch] != address(0)) {
            require(
                LiquidationAccountant(liquidationAccountants[currentEpoch]).finalAuctionEnd() < block.timestamp,
                "Final auction not ended"
            );
        }
        // clear out any remaining withdrawReserve balance
        transferWithdrawReserve();

        //TODO: check this
        require(liensOpenForEpoch[currentEpoch] == uint256(0), "loans are still open for this epoch");
        // increment epoch
        currentEpoch++;

        // reset liquidationWithdrawRatio to prepare for recalcualtion
        liquidationWithdrawRatio = 0;

        // reset withdrawReserve to prepare for recalcualtion
        withdrawReserve = 0;

        // check if there are LPs withdrawing this epoch
        if (withdrawProxies[currentEpoch] != address(0)) {
            uint256 proxySupply = WithdrawProxy(withdrawProxies[currentEpoch]).totalSupply();


            // TODO when to claim()?
            if (liquidationAccountants[currentEpoch] != address(0)) {
                LiquidationAccountant(liquidationAccountants[currentEpoch]).calculateWithdrawRatio();
            }

            // compute the withdrawReserve
            withdrawReserve = convertToAssets(proxySupply);

            // burn the tokens of the LPs withdrawing
            _burn(address(this), proxySupply);
        }
    }

    /**
     * @notice Deploys a LiquidationAccountant for the WithdrawProxy for the upcoming epoch boundary.
     * @return The address of the deployed LiquidationAccountant.
     */
    function deployLiquidationAccountant() public returns (address accountant) {
        require(
            liquidationAccountants[currentEpoch] == address(0),
            "cannot deploy two liquidation accountants for the same epoch"
        );

        accountant = ClonesWithImmutableArgs.clone(
            IAstariaRouter(ROUTER()).LIQUIDATION_IMPLEMENTATION(),
            abi.encodePacked(underlying(), ROUTER(), address(this), address(LIEN_TOKEN()))
        );
        liquidationAccountants[currentEpoch] = accountant;
    }

    function supportsInterface(bytes4 interfaceId) public pure override (IERC165) returns (bool) {
        return interfaceId == type(IPublicVault).interfaceId || interfaceId == type(IVault).interfaceId
            || interfaceId == type(ERC4626Cloned).interfaceId || interfaceId == type(ERC4626).interfaceId
            || interfaceId == type(ERC20).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    /**
     * @notice Transfers funds from the PublicVault to the WithdrawProxy.
     */
    function transferWithdrawReserve() public {
        // check the available balance to be withdrawn
        uint256 withdraw = ERC20(underlying()).balanceOf(address(this));

        // prevent transfer of more assets then are available
        if (withdrawReserve <= withdraw) {
            withdraw = withdrawReserve;
            withdrawReserve = 0;
        } else {
            withdrawReserve -= withdraw;
        }

        address currentWithdrawProxy = withdrawProxies[currentEpoch]; //
        // prevents transfer to a non-existent WithdrawProxy
        // withdrawProxies are indexed by the epoch where they're deployed
        if (currentWithdrawProxy != address(0)) {
            ERC20(underlying()).safeTransfer(currentWithdrawProxy, withdraw);
            emit WithdrawReserveTransferred(withdraw);
        }
    }

    /**
     * @dev Hook for updating the slope of the PublicVault after a LienToken is issued.
     * @param lienId The ID of the lien.
     * @param amount TODO delete amount
     */
    function _afterCommitToLien(uint256 lienId, uint256 amount) internal virtual override {
        // increment slope for the new lien
        unchecked {
            slope += LIEN_TOKEN().calculateSlope(lienId);
        }

        liensOpenForEpoch[currentEpoch]++;
    }

    /**
     * @notice Retrieves the address of the LienToken contract for this PublicVault.
     * @return The LienToken address.
     */
    function LIEN_TOKEN() public view returns (ILienToken) {
        return IAstariaRouter(ROUTER()).LIEN_TOKEN();
    }

    /**
     * @notice Computes the implied value of this PublicVault. This includes interest payments that have not yet been made.
     * @return The implied value for this PublicVault.
     */
    function totalAssets() public view virtual override returns (uint256) {
        uint256 delta_t = block.timestamp - last;
        return slope.mulDivDown(delta_t, 1e18) + yIntercept;
    }
    /**
     * @notice Computes the value for a given amount of VaultToken shares in terms of the underlying asset.
     * @param shares The number of shares to compute for.
     * @return The underlying value of the shares, diluted by unclaimed strategist shares.
     */

    function convertToAssets(uint256 shares) public view virtual override returns (uint256) {
        uint256 supply = totalSupply; // Saves an extra SLOAD if totalSupply is non-zero.

        return supply == 0 ? shares : shares.mulDivDown(totalAssets(), supply + strategistUnclaimedShares);
    }

    /**
     * @notice Mints earned fees by the strategist to the strategist address.
     */
    function claim() external onlyOwner {
        _mint(owner(), strategistUnclaimedShares);
        strategistUnclaimedShares = 0;
    }

    /**
     * @notice Hook to update the slope and yIntercept of the PublicVault on payment.
     * The rate for the LienToken is subtracted from the total slope of the PublicVault, and recalculated in afterPayment().
     * @param lienId The ID of the lien.
     * @param amount The amount paid off to deduct from the yIntercept of the PublicVault.
     */
    function beforePayment(uint256 lienId, uint256 amount) public onlyLienToken {
        _handleStrategistInterestReward(lienId, amount);
        yIntercept = totalAssets() - amount;
        slope -= LIEN_TOKEN().calculateSlope(lienId);
        last = block.timestamp;
    }

    function decreaseOpenLiens() external onlyLienToken {
        liensOpenForEpoch[currentEpoch]--;
    }

    /**
     * @notice Hook to recalculate the slope of a lien after a payment has been made.
     * @param lienId The ID of the lien.
     */
    function afterPayment(uint256 lienId) public onlyLienToken {
        slope += LIEN_TOKEN().calculateSlope(lienId);
    }

    modifier onlyLienToken() {
        require(msg.sender == address(LIEN_TOKEN()));
        _;
    }

    /**
     * @notice After-deposit hook to update the yIntercept of the PublicVault to reflect a capital contribution.
     * @param assets The amount of assets deposited to the PublicVault.
     * @param shares The resulting amount of VaultToken shares that were issued.
     */
    function afterDeposit(uint256 assets, uint256 shares) internal virtual override whenNotPaused {
        yIntercept += assets;
    }

    /**
     * @dev Handles the dilutive fees (on lien repayments) for strategists in VaultTokens.
     * @param lienId The ID of the lien that received a payment.
     * @param amount The amount that was paid.
     */
    function _handleStrategistInterestReward(uint256 lienId, uint256 amount) internal virtual override {
        if (VAULT_FEE() != uint256(0)) {
            uint256 interestOwing = LIEN_TOKEN().getInterest(lienId);
            uint256 x = (amount > interestOwing) ? interestOwing : amount;
            uint256 fee = x.mulDivDown(VAULT_FEE(), 1000); //VAULT_FEE is a basis point
            strategistUnclaimedShares += convertToShares(fee);
        }
    }

    // TODO kill getters
    function getSlope() public view returns (uint256) {
        return slope;
    }

    function getYIntercept() public view returns (uint256) {
        return yIntercept;
    }

    function setYIntercept(uint256 _yIntercept) public {
        require(msg.sender == liquidationAccountants[currentEpoch]);
        yIntercept = _yIntercept;
        emit YInterceptChanged(_yIntercept);
    }

    function getLast() public view returns (uint256) {
        return last;
    }

    function getCurrentEpoch() public view returns (uint64) {
        return currentEpoch;
    }

    /**
     * @notice Computes the time until the current epoch is over.
     * @return Seconds until the current epoch ends.
     */
    function timeToEpochEnd() public view returns (uint256) {
        uint256 epochEnd = START() + ((currentEpoch + 1) * EPOCH_LENGTH());

        if (epochEnd >= block.timestamp) {
            return uint256(0);
        }

        return block.timestamp - epochEnd; //
    }

    // TODO kill
    function getLiquidationAccountant(uint64 epoch) public view returns (address) {
        return liquidationAccountants[epoch];
    }
}
