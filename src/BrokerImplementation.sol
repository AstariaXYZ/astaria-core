pragma solidity ^0.8.13;
import {ERC20} from "solmate/tokens/ERC20.sol";
import {Base, ERC4626Cloned} from "gpl/ERC4626-Cloned.sol";
import "openzeppelin/token/ERC721/IERC721.sol";
import {BrokerRouter} from "./BrokerRouter.sol";
import {ICollateralVault} from "./interfaces/ICollateralVault.sol";
import {ILienToken} from "./CollateralVault.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {MerkleProof} from "openzeppelin/utils/cryptography/MerkleProof.sol";
import {IAuctionHouse} from "gpl/interfaces/IAuctionHouse.sol";

contract BrokerImplementation is Base {
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

    //    function deposit(uint256 amount, address receiver) external virtual {}

    function _validateLoanTerms(
        ICollateralVault.Terms memory params,
        uint256 amount
    ) internal view {
        require(
            appraiser() != address(0),
            "BrokerImplementation.commitToLoan(): Attempting to instantiate an unitialized vault"
        );
        require(
            params.maxAmount >= amount,
            "Broker.commitToLoan(): Attempting to borrow more than maxAmount"
        );
        require(
            amount <= ERC20(asset()).balanceOf(address(this)),
            "Broker.commitToLoan():  Attempting to borrow more than available in the specified vault"
        );

        require(
            validateTerms(params),
            "Broker.commitToLoan(): Verification of provided merkle branch failed for the bondVault and parameters"
        );
    }

    //move this to a lib so we can reuse on star nft
    function validateTerms(ICollateralVault.Terms memory params)
        public
        view
        returns (bool)
    {
        return
            validateTerms(
                params.proof,
                params.collateralVault,
                params.maxAmount,
                params.rate,
                params.duration,
                params.position,
                params.schedule
            );
    }

    function validateTerms(
        bytes32[] memory proof,
        uint256 collateralVault,
        uint256 maxAmount,
        uint256 interestRate,
        uint256 duration,
        uint256 lienPosition,
        uint256 schedule
    ) public view returns (bool) {
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
        return verifyMerkleBranch(proof, leaf, vaultHash());
    }

    function commitToLoan(
        ICollateralVault.Terms memory params,
        uint256 amount,
        address receiver
    ) public {
        address owner = IERC721(COLLATERAL_VAULT()).ownerOf(
            params.collateralVault
        );

        if (receiver != owner) {
            address operator = IERC721(COLLATERAL_VAULT()).getApproved(
                params.collateralVault
            );
            if (msg.sender != owner) {
                require(msg.sender == operator, "invalid request");
            }
            require(
                receiver == operator,
                "can only issue funds to an operator that is approved by the owner"
            );
        }

        _validateLoanTerms(params, amount);

        //ensure that we have space left in our appraisal value to take on more debt or refactor so each collateral
        //can only have one loan per bondvault associated to it

        //reach out to the bond vault and send loan to user

        _issueLoan(receiver, amount, params);

        emit NewLoan(vaultHash(), params.collateralVault, amount);
    }

    function verifyMerkleBranch(
        bytes32[] memory proof,
        bytes32 leaf,
        bytes32 root
    ) public pure returns (bool) {
        bool isValidLeaf = MerkleProof.verify(proof, root, leaf);
        return isValidLeaf;
    }

    function canLiquidate(ICollateralVault.Terms memory params)
        public
        view
        returns (bool)
    {
        return BrokerRouter(router()).canLiquidate(params);
    }

    //    modifier onlyNetworkBrokers(uint256 collateralVault, uint256 position) {
    //        (bool isOwner, ) = BrokerRouter(router()).brokerIsOwner(
    //            collateralVault,
    //            position
    //        );
    //        require(isOwner, "only active broker's can use this feature");
    //        _;
    //    }

    modifier checkSender(
        ICollateralVault.Terms memory outgoingTerms,
        ICollateralVault.Terms memory incomingTerms
    ) {
        if (outgoingTerms.collateralVault != incomingTerms.collateralVault) {
            require(
                address(msg.sender) ==
                    ICollateralVault(COLLATERAL_VAULT()).ownerOf(
                        incomingTerms.collateralVault
                    ),
                "Only the holder of the token can encumber it"
            );
        }
        _;
    }

    function buyoutLien(
        ICollateralVault.Terms memory outgoingTerms,
        ICollateralVault.Terms memory incomingTerms //        onlyNetworkBrokers( //            outgoingTerms.collateralVault, //            outgoingTerms.position //        )
    ) external {
        {
            (uint256 owed, uint256 buyout) = BrokerRouter(router())
                .LIEN_TOKEN()
                .getBuyout(
                    outgoingTerms.collateralVault,
                    outgoingTerms.position
                );

            require(
                buyout <= ERC20(asset()).balanceOf(address(this)),
                "not enough balance to buy out loan"
            );

            //TODO: require interest rate is better and duration is better
            //payout appraiser their premium
            //            ERC20(asset()).safeTransfer(
            //                BrokerImplementation(ICollateralVault.ownerOf(lien.lienId)).appraiser(),
            //                buyout
            //            );
            //
            //            ERC20(asset()).safeApprove(address(outgoing), amount);
            //add the new loan
            //can actually not do this and let you buy out one lien with a whole other asset

            require(
                outgoingTerms.position <= incomingTerms.position,
                "Invalid Lien Position"
            );
            {
                _validateLoanTerms(
                    incomingTerms,
                    owed //amount
                );
            }
            //broker still validates the terms, paves the way for updating the bond vault hashes after expiration
            //            newIndex = _addLoan(
            //                collateralVault,
            //                incomingTerms[3],
            //                incomingTerms[2],
            //                amount,
            //                lienPosition, //lienP
            //                schedule
            //            );

            //            outgoing.repayLoan(collateralVault, position, amount); //
            //            BrokerRouter(router()).repayLoan(collateralVault, amount);
        }
    }

    //    function _addLoan(
    //        uint256 collateralVault,
    //        uint256 amount,
    //        uint256 interestRate,
    //        uint256 duration,
    //        uint256 lienPosition,
    //        uint256 schedule
    //    ) internal returns (uint256 newIndex) {
    //        terms[collateralVault].push(
    //            Term({
    //                amount: amount,
    //                rate: uint32(interestRate),
    //                start: uint64(block.timestamp),
    //                duration: uint64(duration),
    //                lienPosition: uint8(lienPosition),
    //                schedule: uint32(schedule)
    //            })
    //        );
    //
    //        newIndex = terms[collateralVault].length - 1;
    //    }

    function _issueLoan(
        address recipient,
        uint256 amount,
        ICollateralVault.Terms memory params //        uint256 collateralVault, //        uint256 amount, //        uint256 interestRate, //        uint256 duration, //        uint256 lienPosition, //        uint256 schedule
    ) internal {
        require(
            BrokerRouter(router()).requestLienPosition(
                ILienToken.LienActionEncumber(params, amount)
            ),
            "lien position not available"
        );
        ERC20(asset()).safeTransfer(recipient, amount);
        //        newIndex = terms[collateralVault].length - 1;
    }

    //    function repayLoan(
    //        uint256 collateralVault,
    //        uint256 index,
    //        uint256 amount
    //    ) external {
    //        // calculates interest here and apply it to the loan
    //        uint256 interestRate = getInterest(index, collateralVault);
    //
    //        //TODO: ensure math is correct on calcs
    //        uint256 appraiserPayout = (20 * convertToShares(interestRate)) / 100;
    //        _mint(appraiser(), appraiserPayout);
    //
    //        unchecked {
    //            amount -= appraiserPayout;
    //
    //            terms[collateralVault][index].amount += getInterest(
    //                index,
    //                collateralVault
    //            );
    //            amount = (terms[collateralVault][index].amount >= amount)
    //                ? amount
    //                : terms[collateralVault][index].amount;
    //
    //            terms[collateralVault][index].amount -= amount;
    //        }
    //
    //        emit Repayment(collateralVault, index, amount);
    //
    //        if (terms[collateralVault][index].amount == 0) {
    //            //            BrokerRouter(router()).updateLien(
    //            //                collateralVault,
    //            //                index,
    //            //                msg.sender
    //            //            );
    //            delete terms[collateralVault][index];
    //        } else {
    //            terms[collateralVault][index].start = uint64(block.timestamp);
    //        }
    //        ERC20(asset()).safeTransferFrom(
    //            address(msg.sender),
    //            address(this),
    //            amount
    //        );
    //    }
}

interface IBroker {
    function deposit(uint256 amount, address receiver) external virtual;
}

contract SoloBroker is BrokerImplementation {
    using SafeTransferLib for ERC20;

    event LogAddress(address);

    function deposit(uint256 amount, address) external virtual {
        emit LogAddress(appraiser());
        require(
            msg.sender == appraiser(),
            "only the appraiser can fund this vault"
        );
        ERC20(asset()).safeTransferFrom(
            address(msg.sender),
            address(this),
            amount
        );
    }

    function withdraw(uint256 amount) external {
        require(
            msg.sender == appraiser(),
            "only the appraiser can exit this vault"
        );
        ERC20(asset()).safeTransferFrom(
            address(this),
            address(msg.sender),
            amount
        );
    }
}
struct BrokerSlot {
    address broker;
}
