pragma solidity ^0.8.13;

import "gpl/ERC4626-Cloned.sol";
import "openzeppelin/token/ERC721/IERC721.sol";
import "./BrokerRouter.sol";
import "../lib/solmate/src/utils/SafeTransferLib.sol";
import "../lib/openzeppelin-contracts/contracts/utils/cryptography/MerkleProof.sol";

contract BrokerImplementation is ERC4626Cloned {
    event NewLoan(bytes32 bondVault, uint256 collateralVault, uint256 amount);

    event Repayment(uint256 collateralVault, uint256 index, uint256 amount);
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
    using SafeTransferLib for ERC20;
    struct Loan {
        uint256 amount; // loans are only in wETH
        uint32 interestRate; // rate of interest accruing on the borrow (should be in seconds to make calculations easy)
        uint64 start; // epoch time of last interest accrual
        uint64 duration; // duration of the loan
        //        uint64 duration; // epoch time at which the loan must be repaid
        uint8 lienPosition; // position of repayment, borrower can take out multiple loans on the same NFT, if the NFT becomes liquidated the lowest lien psoition is repaid first
        uint32 schedule; // percentage margin before the borrower needs to repay
    }

    mapping(uint256 => Loan[]) public loans;

    function _validateLoanTerms(
        bytes32[] memory proof,
        uint256 collateralVault,
        uint256 maxAmount,
        uint256 interestRate,
        uint256 duration,
        uint256 amount,
        uint256 lienPosition,
        uint256 schedule
    ) internal view {
        require(
            appraiser() != address(0),
            "BrokerImplementation.commitToLoan(): Attempting to instantiate an unitialized vault"
        );
        require(
            maxAmount >= amount,
            "Broker.commitToLoan(): Attempting to borrow more than maxAmount"
        );
        require(
            amount <= ERC20(asset()).balanceOf(address(this)),
            "Broker.commitToLoan():  Attempting to borrow more than available in the specified vault"
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
            "Broker.commitToLoan(): Verification of provided merkle branch failed for the bondVault and parameters"
        );
    }

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
            lienPosition,
            schedule
        );

        BrokerRouter(router()).requestLienPosition(
            collateralVault,
            vaultHash(),
            lienPosition,
            newIndex,
            amount
        );

        emit NewLoan(vaultHash(), collateralVault, amount);
    }

    function verifyMerkleBranch(
        bytes32[] memory proof,
        bytes32 leaf,
        bytes32 root
    ) public pure returns (bool) {
        bool isValidLeaf = MerkleProof.verify(proof, root, leaf);
        return isValidLeaf;
    }

    function afterDeposit(uint256 assets, uint256 shares) internal override {
        require(block.timestamp < expiration(), "deposit: expiration exceeded");
        _mint(appraiser(), (shares * 2) / 100);
    }

    function canLiquidate(uint256 collateralVault, uint256 index)
        public
        view
        returns (bool)
    {
        Loan memory loan = loans[collateralVault][index];
        uint256 interestAccrued = getInterest(index, collateralVault);
        //        (
        //            uint256 amount,
        //            uint256 interest,
        //            uint256 start,
        //            uint256 duration,
        //            uint256 lienPosition,
        //            uint256 schedule,
        //            uint256 buyout
        //        ) = getLoan(broker, collateralVault, index);
        uint256 maxInterest = loan.amount * loan.schedule; //TODO: if schedule is 0, then this is a bug

        return
            (maxInterest > interestAccrued) ||
            (((loan.start + loan.duration) >= block.timestamp) &&
                loan.amount > 0);
    }

    function moveToReceivership(uint256 collateralVault, uint256 index)
        external
        returns (uint256 amountOwed)
    {
        require(msg.sender == router(), "router only call");
        //out lien has been sent to auction, how much are we claiming
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
            uint256 duration,
            uint256 lienPosition,
            uint256 schedule,
            uint256 buyersPremium
        )
    {
        amount =
            loans[collateralVault][index].amount +
            getInterest(index, collateralVault);
        interestRate = loans[collateralVault][index].interestRate;
        start = loans[collateralVault][index].start;
        duration = loans[collateralVault][index].duration;
        lienPosition = loans[collateralVault][index].lienPosition;
        schedule = loans[collateralVault][index].schedule;
        buyersPremium =
            loans[collateralVault][index].amount +
            (loans[collateralVault][index].amount * buyout()) /
            100;
    }

    function getLoanCount(uint256 collateralVault)
        public
        view
        returns (uint256)
    {
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

    modifier onlyNetworkBrokers(address broker) {
        require(
            BrokerRouter(router()).isActiveBroker(broker),
            "only active broker's can use this feature"
        );
        _;
    }

    function buyoutLoan(
        BrokerImplementation outgoing,
        uint256 collateralVault,
        uint256 outgoingIndex,
        bytes32[] memory incomingProof,
        uint256[] memory incomingLoanDetails
    )
        external
        onlyNetworkBrokers(address(outgoing))
        returns (uint256 newIndex)
    {
        {
            (
                uint256 amount,
                uint256 interestRate,
                uint256 start,
                uint256 duration,
                uint256 lienPosition,
                uint256 schedule,
                uint256 buyout
            ) = outgoing.getLoan(collateralVault, outgoingIndex);

            require(
                amount + buyout <= ERC20(asset()).balanceOf(address(this)),
                "not enough balance to buy out loan"
            );

            //TODO: require interest rate is better and duration is better
            //payout appraiser their premium
            ERC20(asset()).safeTransfer(outgoing.appraiser(), buyout);

            ERC20(asset()).safeApprove(address(outgoing), amount);
            //add the new loan
            require(
                lienPosition <= incomingLoanDetails[4],
                "Invalid Lien Position"
            );
            {
                _validateLoanTerms(
                    incomingProof,
                    collateralVault,
                    incomingLoanDetails[0], //maxAmount
                    incomingLoanDetails[1], //interestRate
                    incomingLoanDetails[2], // duration
                    amount, //amount
                    lienPosition, // lienPosition
                    schedule //schedule
                );
            }
            newIndex = _addLoan(
                collateralVault,
                incomingLoanDetails[3],
                incomingLoanDetails[2],
                amount,
                lienPosition, //lienP
                schedule
            );

            outgoing.repayLoan(collateralVault, outgoingIndex, amount);
        }
    }

    function _addLoan(
        uint256 collateralVault,
        uint256 amount,
        uint256 interestRate,
        uint256 duration,
        uint256 lienPosition,
        uint256 schedule
    ) internal returns (uint256 newIndex) {
        loans[collateralVault].push(
            Loan({
                amount: amount,
                interestRate: uint32(interestRate),
                start: uint64(block.timestamp),
                duration: uint64(duration),
                lienPosition: uint8(lienPosition),
                schedule: uint32(schedule)
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
        uint256 lienPosition,
        uint256 schedule
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
            lienPosition,
            schedule
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
        address borrower = IERC721(BrokerRouter(router()).COLLATERAL_VAULT())
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
        uint256 interestRate = getInterest(index, collateralVault);

        uint256 appraiserRake = (20 * convertToShares(interestRate)) / 100;
        _mint(appraiser(), appraiserRake);

        unchecked {
            amount -= appraiserRake;

            loans[collateralVault][index].amount += getInterest(
                index,
                collateralVault
            );
            amount = (loans[collateralVault][index].amount >= amount)
                ? amount
                : loans[collateralVault][index].amount;

            loans[collateralVault][index].amount -= amount;
        }
        ERC20(asset()).safeTransferFrom(
            address(msg.sender),
            address(this),
            amount
        );
        emit Repayment(collateralVault, index, amount);

        if (loans[collateralVault][index].amount == 0) {
            BrokerRouter(router()).updateLien(
                collateralVault,
                index,
                msg.sender
            );
            delete loans[collateralVault][index];
        } else {
            loans[collateralVault][index].start = uint64(block.timestamp);
        }
    }

    function totalAssets() public view virtual override returns (uint256) {
        return ERC20(asset()).balanceOf(address(this));
    }
}
