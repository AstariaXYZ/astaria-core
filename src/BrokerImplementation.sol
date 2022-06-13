pragma solidity ^0.8.13;
import {ERC20} from "solmate/tokens/ERC20.sol";
import {Base, ERC4626Cloned} from "gpl/ERC4626-Cloned.sol";
import "openzeppelin/token/ERC721/IERC721.sol";
import {IBrokerRouter, BrokerRouter} from "./BrokerRouter.sol";
import {ICollateralVault} from "./interfaces/ICollateralVault.sol";
import {ILienToken} from "./interfaces/ILienToken.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {MerkleProof} from "openzeppelin/utils/cryptography/MerkleProof.sol";
import {IAuctionHouse} from "gpl/interfaces/IAuctionHouse.sol";
import {IERC721Receiver} from "openzeppelin/token/ERC721/IERC721Receiver.sol";

contract BrokerImplementation is IERC721Receiver, Base {
    event NewTermCommitment(
        bytes32 bondVault,
        uint256 collateralVault,
        uint256 amount
    );

    event Payment(uint256 collateralVault, uint256 index, uint256 amount);
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

    function onERC721Received(
        address operator_,
        address from_,
        uint256 tokenId_,
        bytes calldata data_
    ) external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    function _validateLoanTerms(
        IBrokerRouter.Terms memory params,
        uint256 amount
    ) internal view {
        require(
            appraiser() != address(0),
            "BrokerImplementation._validateLoanTerms(): Attempting to instantiate an unitialized vault"
        );
        require(
            params.maxAmount >= amount,
            "Broker._validateLoanTerms(): Attempting to borrow more than maxAmount"
        );
        require(
            amount <= ERC20(asset()).balanceOf(address(this)),
            "Broker._validateLoanTerms():  Attempting to borrow more than available in the specified vault"
        );

        require(
            validateTerms(params),
            "Broker._validateLoanTerms(): Verification of provided merkle branch failed for the bondVault and parameters"
        );
    }

    //move this to a lib so we can reuse on star nft
    function validateTerms(IBrokerRouter.Terms memory params)
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
        IBrokerRouter.Terms memory params,
        uint256 amount,
        address receiver
    ) public {
        address operator = IERC721(COLLATERAL_VAULT()).getApproved(
            params.collateralVault
        );
        address owner = IERC721(COLLATERAL_VAULT()).ownerOf(
            params.collateralVault
        );
        if (msg.sender != owner) {
            require(msg.sender == operator, "invalid request");
        }
        if (receiver != owner) {
            require(
                receiver == operator,
                "can only issue funds to an operator that is approved by the owner"
            );
        }

        _validateLoanTerms(params, amount);

        //ensure that we have space left in our appraisal value to take on more debt or refactor so each collateral
        //can only have one loan per bondvault associated to it

        //reach out to the bond vault and send loan to user

        _encumberCollateralAndIssuePayout(receiver, amount, params);

        emit NewTermCommitment(vaultHash(), params.collateralVault, amount);
    }

    function verifyMerkleBranch(
        bytes32[] memory proof,
        bytes32 leaf,
        bytes32 root
    ) public pure returns (bool) {
        bool isValidLeaf = MerkleProof.verify(proof, root, leaf);
        return isValidLeaf;
    }

    function canLiquidate(uint256 collateralVault, uint256 position)
        public
        view
        returns (bool)
    {
        return BrokerRouter(router()).canLiquidate(collateralVault, position);
    }

    modifier checkSender(
        IBrokerRouter.Terms memory outgoingTerms,
        IBrokerRouter.Terms memory incomingTerms
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
        IBrokerRouter.Terms memory outgoingTerms,
        IBrokerRouter.Terms memory incomingTerms //        onlyNetworkBrokers( //            outgoingTerms.collateralVault, //            outgoingTerms.position //        )
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

            require(
                outgoingTerms.position <= incomingTerms.position,
                "Invalid Lien Position"
            );

            //also validated on the other end, is it needed here? since buyout is permissionless prob
            _validateLoanTerms(
                incomingTerms,
                owed //amount
            );

            BrokerRouter(router()).LIEN_TOKEN().buyoutLien(
                ILienToken.LienActionBuyout(incomingTerms, address(this))
            );
        }
    }

    function _encumberCollateralAndIssuePayout(
        address recipient,
        uint256 amount,
        IBrokerRouter.Terms memory params //        uint256 collateralVault, //        uint256 amount, //        uint256 interestRate, //        uint256 duration, //        uint256 lienPosition, //        uint256 schedule
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
