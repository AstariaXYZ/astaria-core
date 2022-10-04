pragma solidity ^0.8.17;

import {Auth, Authority} from "solmate/auth/Auth.sol";
import {VaultImplementation} from "./VaultImplementation.sol";
import {IVault, ERC4626Cloned, IBase} from "gpl/ERC4626-Cloned.sol";
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
}

/**
 * @title Vault
 * @author androolloyd
 */
contract Vault is VaultImplementation, IVault {
    using SafeTransferLib for ERC20;

    function name() public view returns (string memory) {
        return string(abi.encodePacked("AST-Vault-", ERC20(underlying()).symbol()));
    }

    function symbol() public view returns (string memory) {
        return string(abi.encodePacked("AST-V", owner(), "-", ERC20(underlying()).symbol()));
    }

    function _handleStrategistOriginationReward(uint256 shares) internal virtual override {}

    function _handleStrategistInterestReward(uint256 shares) internal virtual override {}

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
    uint64 currentEpoch = 0;
    uint256 withdrawReserve = 0;
    uint256 liquidationWithdrawRatio = 0;

    mapping(uint64 => address) withdrawProxies;
    mapping(uint64 => address) liquidationAccountants;

    function redeem(uint256 shares, address receiver, address owner) public virtual override returns (uint256 assets) {
        assets = redeemFutureEpoch(shares, receiver, owner, currentEpoch + 1);
    }

    function redeemFutureEpoch(uint256 shares, address receiver, address owner, uint64 epoch)
        public
        virtual
        returns (uint256 assets)
    {
        // check to ensure that the requested epoch is not the current epoch or in the past
        require(epoch >= currentEpoch, "Exit epoch too low");

        // check for rounding error since we round down in previewRedeem.
        require((assets = previewRedeem(shares)) != 0, "ZERO_ASSETS");

        beforeWithdraw(assets, shares);

        transferFrom(owner, address(this), shares);
        // Deploy WithdrawProxy if no WithdrawProxy exists for the specified epoch
        if (withdrawProxies[epoch] == address(0)) {
            address proxy = ClonesWithImmutableArgs.clone(
                IAstariaRouter(ROUTER()).WITHDRAW_IMPLEMENTATION(),
                abi.encodePacked(
                    address(this), //owner
                    underlying() //token
                )
            );
            withdrawProxies[epoch] = address(proxy);
        }

        emit Withdraw(msg.sender, receiver, owner, assets, shares);

        // WithdrawProxy shares are minted 1:1 with PublicVault shares
        WithdrawProxy(withdrawProxies[epoch]).mint(receiver, shares); // was withdrawProxies[withdrawEpoch]
    }

    function deposit(uint256 amount, address receiver)
        public
        override (Vault, ERC4626Cloned)
        whenNotPaused
        returns (uint256)
    {
        return super.deposit(amount, receiver);
    }

    // needs to be called in the epoch boundary before the next epoch can start
    function processEpoch(uint256[] memory collateralIds, uint256[] memory positions) external {
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

        // check to make sure the amount of CollateralTokens were the same as the LienTokens held by the vault
        require(collateralIds.length == LIEN_TOKEN().balanceOf(address(this)), "provided ids less than balance");

        // increment epoch
        currentEpoch++;

        // reset liquidationWithdrawRatio to prepare for recalcualtion
        liquidationWithdrawRatio = 0;

        // reset withdrawReserve to prepare for recalcualtion
        withdrawReserve = 0;

        // check if there are LPs withdrawing this epoch
        if (withdrawProxies[currentEpoch] != address(0)) {
            // check liquidations have been processed
            require(haveLiquidationsProcessed(collateralIds, positions), "liquidations not processed");

            uint256 proxySupply = WithdrawProxy(withdrawProxies[currentEpoch]).totalSupply();

            // recalculate liquidationWithdrawRatio for the new epoch
            // liquidationWithdrawRatio = proxySupply.mulDivDown(1, totalSupply);

            // TODO when to claim()?
            if (liquidationAccountants[currentEpoch] != address(0)) {
                LiquidationAccountant(liquidationAccountants[currentEpoch]).calculateWithdrawRatio(
                    withdrawProxies[currentEpoch]
                );
            }

            // compute the withdrawReserve
            withdrawReserve = convertToAssets(proxySupply);

            // burn the tokens of the LPs withdrawing
            _burn(address(this), proxySupply);
        }
    }

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

    function supportsInterface(bytes4 interfaceId) public view override (IERC165) returns (bool) {
        return interfaceId == type(IPublicVault).interfaceId || interfaceId == type(IVault).interfaceId
            || interfaceId == type(ERC4626Cloned).interfaceId || interfaceId == type(ERC4626).interfaceId
            || interfaceId == type(ERC20).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    function transferWithdrawReserve() public {
        // check the available balance to be withdrawn
        uint256 withdraw = ERC20(underlying()).balanceOf(address(this));

        // prevent transfer of more assets then are available
        if (withdrawReserve <= withdraw) {
            withdraw = withdrawReserve;
        }

        // prevents transfer to a non-existent WithdrawProxy
        // withdrawProxies are indexed by the epoch where they're deployed
        if (withdrawProxies[currentEpoch + 1] != address(0)) {
            ERC20(underlying()).safeTransfer(withdrawProxies[currentEpoch + 1], withdraw);
        }

        // decrement the withdraw from the withdraw reserve
        withdrawReserve -= withdraw;
    }

    function _afterCommitToLien(uint256 lienId, uint256 amount) internal virtual override {
        // increment slope for the new lien
        unchecked {
            slope += LIEN_TOKEN().calculateSlope(lienId);
        }
    }

    function haveLiquidationsProcessed(uint256[] memory collateralIds, uint256[] memory positions)
        public
        virtual
        returns (bool)
    {
        // was returns (uint256 balance)
        for (uint256 i = 0; i < collateralIds.length; i++) {
            uint256 lienId = LIEN_TOKEN().getLiens(collateralIds[i])[positions[i]];

            require(LIEN_TOKEN().ownerOf(lienId) == address(this), "lien not owned by vault");

            // check that the lien cannot be liquidated
            if (IAstariaRouter(ROUTER()).canLiquidate(collateralIds[i], positions[i])) {
                return false;
            }
        }
        return true;
    }

    function LIEN_TOKEN() public view returns (ILienToken) {
        return IAstariaRouter(ROUTER()).LIEN_TOKEN();
    }

    function totalAssets() public view virtual override returns (uint256) {
        uint256 delta_t = block.timestamp - last;
        return slope.mulDivDown(delta_t, 1) + yIntercept;
    }

    function beforePayment(uint256 lienId, uint256 amount) public onlyLienToken {
        yIntercept = totalAssets() - amount;
        slope -= LIEN_TOKEN().changeInSlope(lienId, amount);
        last = block.timestamp;
    }

    modifier onlyLienToken() {
        require(msg.sender == address(LIEN_TOKEN()));
        _;
    }

    function afterDeposit(uint256 assets, uint256 shares) internal virtual override whenNotPaused {
        yIntercept += assets;
    }

    function _handleStrategistOriginationReward(uint256 amount) internal virtual override {
        uint256 fee = IAstariaRouter(ROUTER()).getStrategistFee(amount);
        _mint(owner(), convertToShares(fee));
    }

    function getSlope() public view returns (uint256) {
        return slope;
    }

    function getYIntercept() public view returns (uint256) {
        return yIntercept;
    }

    function setYIntercept(uint256 _yIntercept) public {
        require(msg.sender == liquidationAccountants[currentEpoch]);
        yIntercept = _yIntercept;
    }

    function getLast() public view returns (uint256) {
        return last;
    }

    function getCurrentEpoch() public view returns (uint64) {
        return currentEpoch;
    }

    function timeToEpochEnd() public view returns (uint256) {
        uint256 epochEnd = START() + ((currentEpoch + 1) * EPOCH_LENGTH());

        if (epochEnd >= block.timestamp) {
            return uint256(0);
        }

        return block.timestamp - epochEnd; //
    }

    function getLiquidationAccountant(uint64 epoch) public view returns (address) {
        return liquidationAccountants[epoch];
    }
}
