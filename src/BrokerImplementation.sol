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
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

abstract contract BrokerImplementation is IERC721Receiver, Base {
    using SafeTransferLib for ERC20;
    using ValidateTerms for IBrokerRouter.Terms;
    using FixedPointMathLib for uint256;

    event NewTermCommitment(
        bytes32 bondVault, uint256 collateralVault, uint256 amount
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
        bytes32 bondVault, uint256 amount, address indexed redeemer
    );

    function onERC721Received(
        address operator_,
        address from_,
        uint256 tokenId_,
        bytes calldata data_
    )
        external
        pure
        override
        returns (bytes4)
    {
        return IERC721Receiver.onERC721Received.selector;
    }

    function _handleAppraiserReward(uint256) internal virtual {}

    function _validateTerms(IBrokerRouter.Terms memory params, uint256 amount)
        internal
        view
    {
        require(
            appraiser() != address(0),
            "BrokerImplementation._validateTerms(): Attempting to instantiate an unitialized vault"
        );
        require(
            params.maxAmount >= amount,
            "Broker._validateTerms(): Attempting to borrow more than maxAmount"
        );
        require(
            amount <= ERC20(asset()).balanceOf(address(this)),
            "Broker._validateTerms():  Attempting to borrow more than available in the specified vault"
        );

        require(
            params.validateTerms(vaultHash()),
            "Broker._validateTerms(): Verification of provided merkle branch failed for the bondVault and parameters"
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
    )
        public
        virtual
    {
        address operator =
            IERC721(COLLATERAL_VAULT()).getApproved(params.collateralVault);
        address owner =
            IERC721(COLLATERAL_VAULT()).ownerOf(params.collateralVault);
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

        uint256 lienId = _requestLienAndIssuePayout(params, receiver, amount); // TODO fix

        // uint256 lienId = 0;

        _handleAppraiserReward(amount);

        emit NewTermCommitment(vaultHash(), params.collateralVault, amount);
        _afterCommitToLoan(lienId, amount);
    }

    function _afterCommitToLoan(uint256 lienId, uint256 amount)
        internal
        virtual
    {}

    function canLiquidate(uint256 collateralVault, uint256 position)
        public
        view
        returns (bool)
    {
        return IBrokerRouter(router()).canLiquidate(collateralVault, position);
    }

    function buyoutLien(
        uint256 collateralVault,
        uint256 position,
        IBrokerRouter.Terms memory incomingTerms
    )
        external
    {
        (uint256 owed, uint256 buyout) = IBrokerRouter(router()).LIEN_TOKEN()
            .getBuyout(collateralVault, position);

        require(
            buyout <= ERC20(asset()).balanceOf(address(this)),
            "not enough balance to buy out loan"
        );

        _validateTerms(
            incomingTerms,
            owed //amount
        );

        ERC20(asset()).safeApprove(
            address(IBrokerRouter(router()).TRANSFER_PROXY()), owed
        );
        IBrokerRouter(router()).LIEN_TOKEN().buyoutLien(
            ILienToken.LienActionBuyout(incomingTerms, position, recipient())
        );
    }

    function recipient() public view returns (address) {
        if (BROKER_TYPE() == uint256(1)) {
            return address(this);
        } else {
            return appraiser();
        }
    }

    function _requestLienAndIssuePayout(
        IBrokerRouter.Terms memory params,
        address receiver,
        uint256 amount
    )
        internal
        returns (uint256 lienId)
    {
        lienId = IBrokerRouter(router()).requestLienPosition(
            ILienToken.LienActionEncumber(params, amount)
        );

        // require(
        //     IBrokerRouter(router()).requestLienPosition(
        //         ILienToken.LienActionEncumber(params, amount)
        //     ),
        //     "lien position not available"
        // );

        require(lienId != 0, "lien position not available");

        address feeTo = IBrokerRouter(router()).feeTo();
        bool feeOn = feeTo != address(0);
        if (feeOn) {
            // uint256 rake = (amount * 997) / 1000;
            uint256 rake = amount.mulDivDown(997, 1000);
            ERC20(asset()).safeTransfer(feeTo, rake);
            unchecked {
                amount -= rake;
            }
        }
        ERC20(asset()).safeTransfer(receiver, amount);
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

    function _handleAppraiserReward(uint256 shares) internal virtual override {}

    function deposit(uint256 amount, address)
        external
        virtual
        returns (uint256)
    {
        require(
            msg.sender == appraiser(), "only the appraiser can fund this vault"
        );
        ERC20(asset()).safeTransferFrom(
            address(msg.sender), address(this), amount
        );
        return amount;
    }

    function withdraw(uint256 amount) external {
        require(
            msg.sender == appraiser(), "only the appraiser can exit this vault"
        );
        ERC20(asset()).safeTransferFrom(
            address(this), address(msg.sender), amount
        );
    }
}
