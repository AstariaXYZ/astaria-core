pragma solidity ^0.8.13;

import "gpl/ERC4626-Cloned.sol";
import "openzeppelin/token/ERC721/IERC721.sol";
import "./NFTBondController.sol";

contract BrokerImplementation is ERC4626Cloned {
    struct Loan {
        //        uint256 collateralVault; // ERC721, 1155 will be wrapped to create a singular tokenId
        uint256 amount; // loans are only in wETH
        uint256 interestRate; // rate of interest accruing on the borrow (should be in seconds to make calculations easy)
        uint256 start; // epoch time of last interest accrual
        uint256 duration; // epoch time at which the loan must be repaid
        // lienPosition should be managed on the CollateralVault
        //        bytes32 bondVault;
        uint256 lienPosition; // position of repayment, borrower can take out multiple loans on the same NFT, if the NFT becomes liquidated the lowest lien psoition is repaid first
        uint256 schedule; // percentage margin before the borrower needs to repay
    }

    mapping(uint256 => Loan[]) public loans;

    function liquidateLoan(uint256 collateralVault, uint256 index)
        external
        returns (uint256 amountOwed)
    {
        require(msg.sender == factory(), "factory only call");
        amountOwed = (loans[collateralVault][index].amount +
            getInterest(index, collateralVault));
        delete loans[collateralVault][index];
    }

    function getBuyout(uint256 collateralVault, uint256 index)
        public
        view
        returns (uint256)
    {
        uint256 owed = getInterest(index, collateralVault);

        uint256 premium = buyout();

        return owed += (owed * premium) / 1000;
    }

    function issueLoan(
        uint256 collateralVault,
        uint256 amount,
        uint256 interestRate,
        uint256 end,
        uint256 schedule,
        uint256 lienPosition
    ) external returns (uint256 newIndex) {
        require(
            address(msg.sender) == factory(),
            "issueLoan, can only be called by the factory"
        );

        loans[collateralVault].push(
            Loan({
                amount: amount,
                interestRate: interestRate,
                start: block.timestamp,
                duration: end,
                schedule: schedule,
                lienPosition: lienPosition
            })
        );
        address borrower = IERC721(
            NFTBondController(factory()).COLLATERAL_VAULT()
        ).ownerOf(collateralVault);
        ERC20(asset()).transfer(borrower, amount);
        newIndex = loans[collateralVault].length - 1;
    }

    function getInterest(uint256 index, uint256 collateralVault)
        public
        view
        returns (uint256)
    {
        uint256 delta_t = block.timestamp - loans[collateralVault][index].start;
        return (delta_t *
            loans[collateralVault][index].interestRate *
            loans[collateralVault][index].amount);
    }

    function repayLoan(
        uint256 collateralVault,
        uint256 index,
        uint256 amount
    ) external {
        // calculates interest here and apply it to the loan
        loans[collateralVault][index].amount += getInterest(
            index,
            collateralVault
        );
        amount = (loans[collateralVault][index].amount >= amount)
            ? amount
            : loans[collateralVault][index].amount;
        //        require(
        //            WETH.transferFrom(msg.sender, address(this), amount),
        //            "repayLoan: transfer failed"
        //        );
        address weth = address(NFTBondController(factory()).WETH());
        ERC20(weth).transferFrom(address(msg.sender), address(this), amount);
        unchecked {
            loans[collateralVault][index].amount -= amount;
        }
        loans[collateralVault][index].start = block.timestamp;

        if (loans[collateralVault][index].amount == 0) {
            NFTBondController(factory()).removeLien(collateralVault, index);
            delete loans[collateralVault][index];
        }
    }

    function totalAssets() public view virtual override returns (uint256) {
        return ERC20(asset()).balanceOf(address(this));
    }
}
