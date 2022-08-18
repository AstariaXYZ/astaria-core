pragma solidity ^0.8.13;

import {VaultImplementation} from "./VaultImplementation.sol";
import {IVault, ERC4626Cloned, IBase} from "gpl/ERC4626-Cloned.sol";
import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
import {IERC721} from "openzeppelin/token/ERC721/IERC721.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {IAstariaRouter} from "./interfaces/IAstariaRouter.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {ILienToken} from "./interfaces/ILienToken.sol";
import {LienToken} from "./LienToken.sol";
import {WithdrawProxy} from "./WithdrawProxy.sol";
import {ClonesWithImmutableArgs} from
    "clones-with-immutable-args/ClonesWithImmutableArgs.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";

contract Vault is VaultImplementation, IVault {
    using SafeTransferLib for ERC20;

    function name() public view returns (string memory) {
        return string(abi.encodePacked("AST-Vault-", ERC20(underlying()).symbol()));
    }

    function symbol() public view returns (string memory) {
        return string(
            abi.encodePacked("AST-V", owner(), "-", ERC20(underlying()).symbol())
        );
    }

    function _handleAppraiserReward(uint256 shares) internal virtual override {}

    function deposit(uint256 amount, address)
        public
        virtual
        override
        returns (uint256)
    {
        require(msg.sender == owner(), "only the appraiser can fund this vault");
        ERC20(underlying()).safeTransferFrom(
            address(msg.sender), address(this), amount
        );
        return amount;
    }

    function withdraw(uint256 amount) external {
        require(msg.sender == owner(), "only the appraiser can exit this vault");
        ERC20(underlying()).safeTransferFrom(
            address(this), address(msg.sender), amount
        );
    }
}

contract PublicVault is ERC4626Cloned, Vault {
    using FixedPointMathLib for uint256;

    // epoch seconds when yintercept was calculated last
    uint256 last;
    // sum of all LienToken amounts
    uint256 yintercept;
    // sum of all slopes of each LienToken
    uint256 slope;

    // block.timestamp of first epoch
    //        uint256 immutable start; //-> add into Base
    //    uint256 immutable epoch_length(); add into Base
    uint64 currentEpoch = 0;
    uint256 withdrawReserve = 0;
    uint256 liquidationWithdrawRatio = 0;

    mapping(uint64 => address) withdrawProxies;

    //    constructor(
    //        uint256 _epoch_length(),
    //        address _LIEN_TOKEN,
    //        address _WETH
    //    ) {
    //        start() = block.timestamp;
    //        epoch_length() = _epoch_length();
    //        LIEN_TOKEN = ILienToken(_LIEN_TOKEN);
    //        WETH = IERC20(_WETH);
    //    }

    function redeem(uint256 shares, address receiver, address owner)
        public
        virtual
        override
        returns (uint256 assets)
    {
        assets = redeemFutureEpoch(shares, receiver, owner, currentEpoch + 1);
    }

    function redeemFutureEpoch(
        uint256 shares,
        address receiver,
        address owner,
        uint64 epoch
    )
        public
        virtual
        returns (uint256 assets)
    {
        if (msg.sender != owner) {
            uint256 allowed = allowance[owner][msg.sender]; // Saves gas for limited approvals.

            if (allowed != type(uint256).max) {
                allowance[owner][msg.sender] = allowed - shares;
            }
        }

        // check to ensure that the requested epoch is not the current epoch or in the past
        require(epoch >= currentEpoch + 1, "Exit epoch too low");

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
        returns (uint256)
    {
        return super.deposit(amount, receiver);
    }

    // needs to be called in the epoch boundary before the next epoch can start
    function processEpoch(
        uint256[] memory slipIds,
        uint256[] memory positions
    )
        external
    {
        // check to make sure epoch is over
        require(
            START() + ((currentEpoch + 1) * EPOCH_LENGTH()) < block.timestamp,
            "Epoch has not ended"
        );

        // clear out any remaining withdrawReserve balance
        transferWithdrawReserve();

        // check to make sure the amount of CollateralVaults were the same as the LienTokens held by the vault
        require(
            slipIds.length == LIEN_TOKEN().balanceOf(address(this)),
            "provided ids less than balance"
        );

        // incremement epoch
        currentEpoch++;

        // reset liquidationWithdrawRatio to prepare for recalcualtion
        liquidationWithdrawRatio = 0;

        // reset withdrawReserve to prepare for recalcualtion
        withdrawReserve = 0;

        // check if there are LPs withdrawing this epoch
        if (withdrawProxies[currentEpoch] != address(0)) {
            // check liquidations have been processed
            require(
                haveLiquidationsProcessed(slipIds, positions),
                "liquidations not processed"
            );

            uint256 proxySupply =
                WithdrawProxy(withdrawProxies[currentEpoch]).totalSupply();

            // recalculate liquidationWithdrawRatio for the new epoch
            liquidationWithdrawRatio = proxySupply.mulDivDown(1, totalSupply);

            // compute the withdrawReserve
            uint256 withdrawReserve = convertToAssets(proxySupply);

            // burn the tokens of the LPs withdrawing
            _burn(address(this), proxySupply);
        }
    }

    function transferWithdrawReserve() public {
        // check the available balance to be withdrawn
        uint256 withdraw = ERC20(underlying()).balanceOf(address(this));

        // prevent transfer of more assets then are available
        if (withdrawReserve <= withdraw) {
            withdraw = withdrawReserve;
        }

        // prevents transfer to a non-existent WithdrawProxy
        if (withdrawProxies[currentEpoch] != address(0)) {
            ERC20(underlying()).transfer(
                withdrawProxies[currentEpoch], withdraw
            );
        }

        // decrement the withdraw from the withdraw reserve
        withdrawReserve -= withdraw;
    }

    function _afterCommitToLoan(uint256 lienId, uint256 amount)
        internal
        virtual
        override
    {
        // increment slope for the new lien
        slope += LIEN_TOKEN().calculateSlope(lienId);
    }

    function haveLiquidationsProcessed(
        uint256[] memory slipIds,
        uint256[] memory positions
    )
        public
        virtual
        returns (bool)
    {
        // was returns (uint256 balance)
        for (uint256 i = 0; i < slipIds.length; i++) {
            // get lienId from LienToken

            // uint256 lienId = LienToken.liens[slipIds[i]][
            //     positions[i]
            // ];

            // uint256 lienId =
            //     LIEN_TOKEN().liens(slipIds[i], positions[i]);

            uint256 lienId = LIEN_TOKEN().getLiens(slipIds[i])[positions[i]];

            // TODO implement
            // check that the lien is owned by the vault, this check prevents the msg.sender from presenting an incorrect lien set
            // require(
            //     ILienToken.ownerOf(lienId) == address(this),
            //     "lien not owned by vault"
            // );

            require(
                LIEN_TOKEN().ownerOf(lienId) == address(this),
                "lien not owned by vault"
            );

            // check that the lien cannot be liquidated
            if (
                IAstariaRouter(ROUTER()).canLiquidate(slipIds[i], positions[i])
            ) {
                return false;
            }
        }
        return true;
    }

    function LIEN_TOKEN() public view returns (ILienToken) {
        return IAstariaRouter(ROUTER()).LIEN_TOKEN();
    }

    function completeLiquidation(uint256 lienId, uint256 amount) public {
        // get the lien amount the vault expected to get before liquidation
        uint256 expected = LIEN_TOKEN().getLien(lienId).amount; // was LienToken.getLien

        // compute the amount owed to the WithdrawProxy for the currentEpoch
        uint256 withdraw = amount.mulDivDown(liquidationWithdrawRatio, 1);

        // check to ensure that the WithdrawProxy was instantiated
        if (withdrawProxies[currentEpoch] != address(0)) {
            ERC20(underlying()).transfer(
                withdrawProxies[currentEpoch], withdraw
            );
        }

        // decrement the yintercept for the amount received on liquidatation vs the expected
        // TODO: unchecked?
        yintercept -=
            (expected - amount).mulDivDown(1 - liquidationWithdrawRatio, 1);
    }

    function totalAssets() public view virtual override returns (uint256) {
        uint256 delta_t = block.timestamp - last;
        return slope.mulDivDown(delta_t, 1) + yintercept;
    }

    function beforePayment(uint256 lienId, uint256 amount)
        public
        onlyLienToken
    {
        yintercept = totalAssets() - amount;
        slope -= LIEN_TOKEN().changeInSlope(lienId, amount);
        last = block.timestamp;
    }

    modifier onlyLienToken() {
        require(msg.sender == address(LIEN_TOKEN()));
        _;
    }

    function afterDeposit(uint256 assets, uint256 shares)
        internal
        virtual
        override
    {
        // increase yintercept for assets held
        if (BROKER_TYPE() == uint256(1)) {
            require(msg.sender == owner(), "only owner can deposit");
        }
        yintercept += assets;
        _handleAppraiserReward(shares);
    }

    function _handleAppraiserReward(uint256 amount) internal virtual override {
        (uint256 appraiserRate, uint256 appraiserBase) =
            IAstariaRouter(ROUTER()).getStrategistFee();
        _mint(
            owner(),
            convertToShares(amount).mulDivDown(appraiserRate, appraiserBase)
        );
    }
}
