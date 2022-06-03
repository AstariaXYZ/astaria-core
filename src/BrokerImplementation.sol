pragma solidity ^0.8.13;

import "gpl/ERC4626-Cloned.sol";
import "openzeppelin/token/ERC721/IERC721.sol";
import "./BrokerRouter.sol";
import "../lib/solmate/src/utils/SafeTransferLib.sol";
import "../lib/openzeppelin-contracts/contracts/utils/cryptography/MerkleProof.sol";

contract BrokerImplementation is ERC4626Cloned {
    event NewLoan(bytes32 bondVault, uint256 collateralVault, uint256 amount);

    using SafeTransferLib for ERC20;
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

    function _validateLoanTerms(
        bytes32[] calldata proof,
        uint256 collateralVault,
        uint256 maxAmount,
        uint256 interestRate,
        uint256 duration,
        uint256 amount,
        uint256 lienPosition,
        uint256 schedule
    ) internal {
        emit LogStuff(vaultHash(), appraiser(), expiration());
        require(
            appraiser() != address(0),
            "BrokerImplementation.commitToLoan(): Attempting to instantiate an unitialized vault"
        );
        require(
            maxAmount >= amount,
            "BrokerRouter.commitToLoan(): Attempting to borrow more than maxAmount"
        );
        require(
            amount <= ERC20(asset()).balanceOf(address(this)),
            "BrokerRouter.commitToLoan():  Attempting to borrow more than available in the specified vault"
        );
        // filler hashing schema for merkle tree
        bytes32 leaf = keccak256(
            abi.encode(
                bytes32(collateralVault),
                maxAmount,
                interestRate,
                duration,
                lienPosition,
                schedule
            )
        );
        require(
            verifyMerkleBranch(proof, leaf, vaultHash()),
            "BrokerRouter.commitToLoan(): Verification of provided merkle branch failed for the bondVault and parameters"
        );
    }

    event LogStuff(bytes32, address, uint256);

    function commitToLoan(
        bytes32[] calldata proof,
        uint256 collateralVault,
        uint256 maxAmount,
        uint256 interestRate,
        uint256 duration,
        uint256 amount,
        uint256 lienPosition,
        uint256 schedule,
        address receiver
    ) public {
        address owner = IERC721(COLLATERAL_VAULT()).ownerOf(collateralVault);
        address operator = IERC721(COLLATERAL_VAULT()).getApproved(
            collateralVault
        );
        require(
            msg.sender == owner || msg.sender == operator,
            "BrokerImplementation.commitToLoan(): Owner of the collateral vault must be msg.sender"
        );
        if (receiver != owner) {
            require(
                receiver == operator,
                "can only issue funds to an operator that is approved by the owner"
            );
        }
        _validateLoanTerms(
            proof,
            collateralVault,
            maxAmount,
            interestRate,
            duration,
            amount,
            lienPosition,
            schedule
        );

        //ensure that we have space left in our appraisal value to take on more debt or refactor so each collateral
        //can only have one loan per bondvault associated to it

        //reach out to the bond vault and send loan to user

        uint256 newIndex = _issueLoan(
            receiver,
            collateralVault,
            amount,
            interestRate,
            duration,
            schedule,
            lienPosition
        );

        BrokerRouter(factory()).addLien(
            collateralVault,
            vaultHash(),
            lienPosition,
            newIndex,
            amount
        );

        emit NewLoan(vaultHash(), collateralVault, amount);
    }

    function verifyMerkleBranch(
        bytes32[] calldata proof,
        bytes32 leaf,
        bytes32 root
    ) public view returns (bool) {
        bool isValidLeaf = MerkleProof.verify(proof, root, leaf);
        return isValidLeaf;
    }

    function deposit(uint256 assets, address receiver)
        public
        virtual
        override
        returns (uint256 shares)
    {
        require(block.timestamp < expiration(), "deposit: expiration exceeded");

        // Check for rounding error since we round down in previewDeposit.
        require((shares = previewDeposit(assets)) != 0, "ZERO_SHARES");

        // Need to transfer before minting or ERC777s could reenter.
        ERC20(asset()).safeTransferFrom(msg.sender, address(this), assets);

        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);

        afterDeposit(assets, shares);
    }

    function liquidateLoan(uint256 collateralVault, uint256 index)
        external
        returns (uint256 amountOwed)
    {
        require(msg.sender == factory(), "factory only call");
        amountOwed = (loans[collateralVault][index].amount +
            getInterest(index, collateralVault));
        delete loans[collateralVault][index];
    }

    function getLoan(uint256 collateralVault, uint256 index)
        public
        view
        returns (
            uint256 amount,
            uint256 interestRate,
            uint256 start,
            uint256 end,
            uint256 lienPosition,
            uint256 schedule,
            uint256 buyersPremium
        )
    {
        amount = loans[collateralVault][index].amount;
        interestRate = loans[collateralVault][index].interestRate;
        start = loans[collateralVault][index].start;
        end = loans[collateralVault][index].end;
        lienPosition = loans[collateralVault][index].lienPosition;
        schedule = loans[collateralVault][index].schedule;
        buyersPremium =
            loans[collateralVault][index].amount +
            (loans[collateralVault][index].amount * buyout()) /
            100;
    }

    function getLoanCount(uint256 collateralVault) public returns (uint256) {
        return loans[collateralVault].length;
    }

    function getBuyout(uint256 collateralVault, uint256 index)
        public
        view
        returns (uint256, uint256)
    {
        uint256 owed = loans[collateralVault][index].amount +
            getInterest(index, collateralVault);

        uint256 premium = buyout();

        //        return owed += (owed * premium) / 100;
        return (owed, owed + (owed * premium) / 100);
    }

    function buyoutLoan(
        address broker,
        uint256 collateralVault,
        uint256 outgoingIndex,
        uint256 buyout,
        uint256 amount,
        uint256 newInterestRate,
        uint256 newDuration,
        uint256 schedule, // keep old or can be changed?
        uint256 lienPosition
    ) external returns (uint256 newIndex) {
        require(
            address(msg.sender) == factory(),
            "issueLoan, can only be called by the factory"
        );
        ERC20(asset()).safeApprove(broker, buyout);

        newIndex = _addLoan(
            collateralVault,
            amount,
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

    function _issueLoan(
        address recipient,
        uint256 collateralVault,
        uint256 amount,
        uint256 interestRate,
        uint256 duration,
        uint256 schedule,
        uint256 lienPosition
    ) internal returns (uint256 newIndex) {
        //        require(
        //            address(msg.sender) == factory(),
        //            "issueLoan, can only be called by the factory"
        //        );

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
        address borrower = IERC721(BrokerRouter(factory()).COLLATERAL_VAULT())
            .ownerOf(collateralVault);
        ERC20(asset()).safeTransfer(borrower, amount);
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
        ERC20(asset()).safeTransferFrom(
            address(msg.sender),
            address(this),
            amount
        );
        unchecked {
            loans[collateralVault][index].amount -= amount;
        }
        loans[collateralVault][index].start = uint64(block.timestamp);

        if (loans[collateralVault][index].amount == 0) {
            BrokerRouter(factory()).updateLien(
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
