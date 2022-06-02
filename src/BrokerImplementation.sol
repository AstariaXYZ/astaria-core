pragma solidity ^0.8.13;

import "gpl/ERC4626-Cloned.sol";
import "openzeppelin/token/ERC721/IERC721.sol";
import "./NFTBondController.sol";

contract BrokerImplementation is ERC4626Cloned {
    struct Loan {
        uint256 amount; // loans are only in wETH
        uint32 interestRate; // rate of interest accruing on the borrow (should be in seconds to make calculations easy)
        uint64 start; // epoch time of last interest accrual
        uint64 end; // epoch time at which the loan must be repaid
        //        uint64 duration; // epoch time at which the loan must be repaid
        uint8 lienPosition; // position of repayment, borrower can take out multiple loans on the same NFT, if the NFT becomes liquidated the lowest lien psoition is repaid first
        uint32 schedule; // percentage margin before the borrower needs to repay
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

    function getLoanCount(uint256 collateralVault) public returns (uint256) {
        return loans[collateralVault].length;
    }

    function getBuyout(uint256 collateralVault, uint256 index)
        public
        view
        returns (uint256)
    {
        uint256 owed = loans[collateralVault][index].amount +
            getInterest(index, collateralVault);

        uint256 premium = buyout();

        //        return owed += (owed * premium) / 100;
        return owed;
    }

    function buyoutLoan(
        address broker,
        uint256 collateralVault,
        uint256 outgoingIndex,
        uint256 buyout,
        uint256 newInterestRate,
        uint256 newDuration,
        uint256 schedule, // keep old or can be changed?
        uint256 lienPosition
    ) external returns (uint256 newIndex) {
        require(
            address(msg.sender) == factory(),
            "issueLoan, can only be called by the factory"
        );
        ERC20(asset()).approve(broker, buyout);

        newIndex = _addLoan(
            collateralVault,
            buyout,
            newInterestRate,
            newDuration,
            schedule,
            lienPosition
        );
        BrokerImplementation(broker).repayLoan(
            collateralVault,
            outgoingIndex,
            buyout
        );
    }

    function _addLoan(
        uint256 collateralVault,
        uint256 amount,
        uint256 interestRate,
        uint256 duration,
        uint256 schedule,
        uint256 lienPosition
    ) internal returns (uint256 newIndex) {
        loans[collateralVault].push(
            Loan({
                amount: amount,
                interestRate: uint32(interestRate),
                start: uint64(block.timestamp),
                end: uint64(block.timestamp + duration),
                schedule: uint32(schedule),
                lienPosition: uint8(lienPosition)
            })
        );

        newIndex = loans[collateralVault].length - 1;
    }

    function issueLoan(
        address recipient,
        uint256 collateralVault,
        uint256 amount,
        uint256 interestRate,
        uint256 duration,
        uint256 schedule,
        uint256 lienPosition
    ) external returns (uint256 newIndex) {
        require(
            address(msg.sender) == factory(),
            "issueLoan, can only be called by the factory"
        );

        _addLoan(
            collateralVault,
            amount,
            interestRate,
            duration,
            schedule,
            lienPosition
        );
        //        loans[collateralVault].push(
        //            Loan({
        //                amount: amount,
        //                interestRate: uint32(interestRate),
        //                start: uint64(block.timestamp),
        //                end: uint64(block.timestamp + duration),
        //                schedule: uint32(schedule),
        //                lienPosition: uint8(lienPosition)
        //            })
        //        );
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
        loans[collateralVault][index].start = uint64(block.timestamp);

        if (loans[collateralVault][index].amount == 0) {
            NFTBondController(factory()).updateLien(
                collateralVault,
                index,
                msg.sender
            );
            delete loans[collateralVault][index];
        }
    }

    function totalAssets() public view virtual override returns (uint256) {
        return ERC20(asset()).balanceOf(address(this));
    }
}
