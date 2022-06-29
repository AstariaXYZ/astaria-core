pragma solidity ^0.8.13;
import {IERC721} from "openzeppelin/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "openzeppelin/token/ERC721/IERC721Receiver.sol";
import {ICollateralVault} from "./interfaces/ICollateralVault.sol";
import {ILienToken} from "./interfaces/ILienToken.sol";
import {IBrokerRouter} from "./interfaces/IBrokerRouter.sol";
import {IAuctionHouse} from "gpl/interfaces/IAuctionHouse.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {Base} from "gpl/ERC4626-Cloned.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {MerkleProof} from "openzeppelin/utils/cryptography/MerkleProof.sol";
import {ValidateTerms} from "./libraries/ValidateTerms.sol";

contract BrokerImplementation is IERC721Receiver, Base {
    using SafeTransferLib for ERC20;
    using ValidateTerms for IBrokerRouter.Terms;
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

    function onERC721Received(
        address operator_,
        address from_,
        uint256 tokenId_,
        bytes calldata data_
    ) external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    function _validateTerms(IBrokerRouter.Terms memory params, uint256 amount)
        internal
        view
    {
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
            params.validateTerms(vaultHash()),
            "Broker._validateLoanTerms(): Verification of provided merkle branch failed for the bondVault and parameters"
        );
    }

    //move this to a lib so we can reuse on star nft
    function validateTerms(IBrokerRouter.Terms memory params)
        public
        pure
        returns (bool)
    {
        return params.validateTerms(vaultHash());
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

        _validateTerms(params, amount);

        _requestLienAndIssuePayout(params, receiver, amount);

        emit NewTermCommitment(vaultHash(), params.collateralVault, amount);
    }

    function canLiquidate(uint256 collateralVault, uint256 position)
        public
        view
        returns (bool)
    {
        return IBrokerRouter(router()).canLiquidate(collateralVault, position);
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
            (uint256 owed, uint256 buyout) = IBrokerRouter(router())
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
            _validateTerms(
                incomingTerms,
                owed //amount
            );

            IBrokerRouter(router()).LIEN_TOKEN().buyoutLien(
                ILienToken.LienActionBuyout(incomingTerms, address(this))
            );
        }
    }

    function _requestLienAndIssuePayout(
        IBrokerRouter.Terms memory params, //        uint256 collateralVault, //        uint256 amount, //        uint256 interestRate, //        uint256 duration, //        uint256 lienPosition, //        uint256 schedule
        address recipient,
        uint256 amount
    ) internal {
        require(
            IBrokerRouter(router()).requestLienPosition(
                ILienToken.LienActionEncumber(params, amount)
            ),
            "lien position not available"
        );
        address feeTo = IBrokerRouter(router()).feeTo();
        bool feeOn = feeTo != address(0);
        if (feeOn) {
            uint256 rake = (amount * 997) / 1000;
            ERC20(asset()).safeTransfer(feeTo, rake);
            unchecked {
                amount -= rake;
            }
        }
        ERC20(asset()).safeTransfer(recipient, amount);
    }
}

interface IBroker {
    function deposit(uint256 assets, address receiver)
        external
        virtual
        returns (uint256 shares);
}

contract SoloBroker is BrokerImplementation, IBroker {
    using SafeTransferLib for ERC20;

    function deposit(uint256 amount, address)
        external
        virtual
        returns (uint256)
    {
        require(
            msg.sender == appraiser(),
            "only the appraiser can fund this vault"
        );
        ERC20(asset()).safeTransferFrom(
            address(msg.sender),
            address(this),
            amount
        );
        return amount;
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
