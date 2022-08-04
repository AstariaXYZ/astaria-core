pragma solidity ^0.8.13;
import {BrokerImplementation} from "./BrokerImplementation.sol";
import {ERC4626Cloned} from "gpl/ERC4626-Cloned.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {IBrokerRouter} from "./interfaces/IBrokerRouter.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {ILienToken} from "./interfaces/ILienToken.sol";

contract PublicVault is BrokerImplementation, ERC4626Cloned  {
    using FixedPointMathLib for uint256;
    address immutable lienToken;

    // epoch seconds when yintercept was calculated last
    uint256 last;
    // sum of all LienToken amounts
    uint256 yintercept;
    // sum of all slopes of each LienToken
    uint256 slope;

    // block.timestamp of first epoch
    uin256 immutable start;
    uint256 immutable epochLength; // in epoch seconds
    uint64 currentEpoch = 0;
    uint256 withdrawReserve = 0;
    uint256 liquidationWithdrawRatio = 0;

    mapping(uint64 => address) withdrawProxies;

    constructor(uint256 _epochLength, address _lienToken){
        start = block.timestamp;
        epochLength = _epochLength;
        lienToken = _lienToken;
    }

    function redeem(
    uint256 shares,
    address receiver,
    address owner
    ) public virtual override returns (uint256 assets) {
        assets = redeemFutureEpoch(shares, receiver, owner, currentEpoch + 1);
    }

    function redeemFutureEpoch(
    uint256 shares,
    address receiver,
    address owner,
    uint64 epoch
    ) public virtual returns (uint256 assets) {
        if (msg.sender != owner) {
            uint256 allowed = allowance[owner][msg.sender]; // Saves gas for limited approvals.

            if (allowed != type(uint256).max)
                allowance[owner][msg.sender] = allowed - shares;
        }

        // check to ensure that the requested epoch is not the current epoch or in the past
        require(epoch >= currentEpoch + 1, "Exit epoch too low");

        // check for rounding error since we round down in previewRedeem.
        require((assets = previewRedeem(shares)) != 0, "ZERO_ASSETS");

        beforeWithdraw(assets, shares);

        transferFrom(owner, address(this), shares);
        // Deploy WithdrawProxy if no WithdrawProxy exists for the specified epoch
        if(withdrawProxies[epoch] == address(0)) withdrawProxies[epoch] = new WithdrawProxy();

        emit Withdraw(msg.sender, receiver, owner, assets, shares);

        // WithdrawProxy shares are minted 1:1 with PublicVault shares
        withdrawProxies[withdrawEpoch].mint(receiver, shares);
    }

    // needs to be called in the epoch boundary before the next epoch can start
    function processEpoch(uint256[] memory collateralVaults, uint256[] memory positions) external returns() {
        // check to make sure epoch is over
        require(start + ((currentEpoch + 1) * epochLength)) < block.timestamp, "Epoch has not ended");

        // clear out any remaining withdrawReserve balance
        transferWithdrawReserve();

        // check to make sure the amount of CollateralVaults were the same as the LienTokens held by the vault 
        require(collateralVaults.length == ILienToken.balanceOf(address(this)), "provided ids less than balance");

        // incremement epoch
        currentEpoch ++;

        // reset liquidationWithdrawRatio to prepare for recalcualtion
        liquidationWithdrawRatio = 0;

        // reset withdrawReserve to prepare for recalcualtion
        withdrawReserve = 0;

        // check if there are LPs withdrawing this epoch
        if(withdrawProxies[currentEpoch] != address(0)){
            // check liquidations have been processed
            require(haveLiquidationsProcessed(collateralVaults, positions), "liquidations not processed");

            // recalculate liquidationWithdrawRatio for the new epoch
            liquidationWithdrawRatio = withdrawProxies[currentEpoch].totalSupply / totalSupply;

            // compute the withdrawReserve
            uint256 withdrawReserve = convertToAssets(withdrawProxies[currentEpoch].totalSupply());

            // burn the tokens of the LPs withdrawing
            _burn(address(this), withdrawProxies[currentEpoch].totalSupply());
        }
    }

    function transferWithdrawReserve() public returns() {
        // check the available balance to be withdrawn
        uint256 withdraw = ERC20(asset()).balanceOf(address(this));

        // prevent transfer of more assets then are available 
        if(withdrawReserve <= withdraw)withdraw = withdrawReserve;

        // decrement the withdraw from the withdraw reserve
        withdrawReserve -= withdraw;

        // prevents transfer to a non-existent WithdrawProxy
        if(withdrawProxies[currentEpoch] != address(0)) ERC20(asset()).transfer(withdrawProxies[currentEpoch], withdraw);

    }

    function _afterCommitToLoan(uint256 lienId, uint256 amount)
        internal virtual override {
        // increment slope for the new lien
        slope += ILienToken.calculateSlope(lienId);
    }

    function haveLiquidationsProcessed(uint256[] memory collateralVaults, uint256[] memory positions) public virtual returns (uint256 balance) {
        for(uint256 i = 0; i < collateralVaults.length; i++){
            // get lienId from LienToken
            uint256 lienId = ILienToken.liens[collateralVaults[i]][positions[i]];

            // check that the lien is owned by the vault, this check prevents the msg.sender from presenting an incorrect lien set
            require(ILienToken.ownerOf(lienId) == address(this), "lien not owned by vault");

            // check that the lien cannot be liquidated
            if(IBrokerRouter(router()).canLiquidate(collateralVaults[i], positions[i])) return false;
        }
        return true;
    }

    function completeLiqudiation(uint256 lienId, uint256 amount) {
        // get the lien amount the vault expected to get before liquidation
        uint256 expected = LienToken.getLien(lienId).amount;

        // compute the amount owed to the WithdrawProxy for the currentEpoch
        uint256 withdraw = amount * liquidationWithdrawRatio;

        // check to ensure that the WithdrawProxy was instantiated
        if(withdrawProxies[currentEpoch] != address(0)) ERC20(asset()).transfer(withdrawProxies[currentEpoch], withdraw);

        // decrement the yintercept for the amount received on liquidatation vs the expected
        yintercept -= (expected - amount) * (1 - liquidationWithdrawRatio);
    }

    function totalAssets() public view override virtual returns (uint256){
        uint256 delta_t = block.timestamp - last;
        return (slope * delta_t) + principle;
    }

    function beforePayment(uint256 lienId, uint256 amount) public onlyLienToken returns() {
        principle = totalAssets() - amount;
        slope -= ILienToken.changeInSlope(lienId, amount);
        last = block.timestamp;
    }

    modifier onlyLienToken() public returns(bool) {
        require(msg.sender == lienToken);
        _;
    }

    function afterDeposit(uint256 assets, uint256 shares) internal override virtual {
        // increase yintercept for assets held
        yintercept += assets;
        _handleAppraiserReward(shares);
    }

    function _handleAppraiserReward(uint256 amount) internal virtual override {
        (uint256 appraiserRate, uint256 appraiserBase) = IBrokerRouter(router())
            .getAppraiserFee();
        _mint(
            appraiser(),
            // ((convertToShares(amount) * appraiserRate) / appraiserBase)
            convertToShares(amount).mulDivDown(appraiserRate, appraiserBase)
        );
    }
}
