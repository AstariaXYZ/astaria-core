pragma solidity ^0.8.13;
import "../lib/solmate/src/mixins/ERC4626.sol";
import "../lib/clones-with-immutable-args/src/Clone.sol";
import "../lib/solmate/src/mixins/ERC4626-Cloned.sol";
import "openzeppelin/token/ERC721/IERC721.sol";
import "./NFTBondController.sol";

abstract contract Impl {
    function version() public pure virtual returns (string memory);
}

//contract BrokerImplementation is Initializable, Impl {
//    ITransferProxy TRANSFER_PROXY;
//    using SafeERC20 for IERC20;
//
//    function initialize(address[] memory tokens, address _transferProxy)
//        public
//        initializer
//        onlyInitializing
//    {
//        TRANSFER_PROXY = ITransferProxy(_transferProxy);
//        _transferProxyApprove(tokens);
//    }
//
//    function _transferProxyApprove(address[] memory tokens) internal {
//        for (uint256 i = 0; i < tokens.length; ++i) {
//            IERC20(tokens[i]).safeApprove(
//                address(TRANSFER_PROXY),
//                type(uint256).max
//            );
//        }
//    }
//
//    function setupApprovals(address[] memory tokens) external reinitializer(0) {
//        _transferProxyApprove(tokens);
//    }
//
//    function version() public pure virtual override returns (string memory) {
//        return "V1";
//    }
//}

contract BrokerImplementation is ERC4626Cloned {
    struct Loan {
        //        uint256 collateralVault; // ERC721, 1155 will be wrapped to create a singular tokenId
        uint256 amount; // loans are only in wETH
        uint256 interestRate; // rate of interest accruing on the borrow (should be in seconds to make calculations easy)
        uint256 start; // epoch time of last interest accrual
        uint256 duration; // epoch time at which the loan must be repaid
        // lienPosition should be managed on the CollateralVault
        //        bytes32 bondVault;
        //        uint8 lienPosition; // position of repayment, borrower can take out multiple loans on the same NFT, if the NFT becomes liquidated the lowest lien psoition is repaid first
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

    function issueLoan(
        uint256 collateralVault,
        uint256 amount,
        uint256 interestRate,
        uint256 end,
        uint256 schedule
    ) external returns (uint256 newIndex) {
        require(
            address(msg.sender) == factory(),
            "issueLoan, can only be called by the factory"
        );

        loans[collateralVault].push(
            Loan(amount, interestRate, block.timestamp, end, schedule)
        );
        uint256 newIndex = loans[collateralVault].length - 1;
        address borrower = IERC721(
            NFTBondController(factory()).COLLATERAL_VAULT()
        ).ownerOf(collateralVault);
        ERC20(asset()).transfer(borrower, amount);
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
            delete loans[collateralVault][index];
            NFTBondController(factory()).removeLien(collateralVault, index);
        }
    }

    function totalAssets() public view virtual override returns (uint256) {
        return ERC20(asset()).balanceOf(address(this));
    }
}
