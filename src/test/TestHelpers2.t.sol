pragma solidity ^0.8.16;

import "forge-std/Test.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {Authority} from "solmate/auth/Auth.sol";
import {MultiRolesAuthority} from "solmate/auth/authorities/MultiRolesAuthority.sol";
import {IERC20} from "../interfaces/IERC20.sol";

import {ERC721} from "gpl/ERC721.sol";
import {CollateralToken} from "../CollateralToken.sol";
import {LienToken} from "../LienToken.sol";
import {ICollateralToken} from "../interfaces/ICollateralToken.sol";
import {ILienToken} from "../interfaces/ILienToken.sol";
import {ITransferProxy} from "gpl/interfaces/ITransferProxy.sol";
import {IV3PositionManager} from "../interfaces/IV3PositionManager.sol";
import {CollateralLookup} from "../libraries/CollateralLookup.sol";
import {ILienToken} from "../interfaces/ILienToken.sol";
import {MockERC721} from "solmate/test/utils/mocks/MockERC721.sol";
import {IAstariaRouter, AstariaRouter} from "../AstariaRouter.sol";
import {UniqueValidator, IUniqueValidator} from "../strategies/UniqueValidator.sol";
import {ICollectionValidator, CollectionValidator} from "../strategies/CollectionValidator.sol";
import {UNI_V3Validator, IUNI_V3Validator} from "../strategies/UNI_V3Validator.sol";
import {AuctionHouse} from "gpl/AuctionHouse.sol";
import {Strings2} from "./utils/Strings2.sol";
import {IVault, VaultImplementation} from "../VaultImplementation.sol";
import {Vault, PublicVault} from "../PublicVault.sol";
import {TransferProxy} from "../TransferProxy.sol";
import {IStrategyValidator} from "../interfaces/IStrategyValidator.sol";
import {SafeCastLib} from "gpl/utils/SafeCastLib.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {WithdrawProxy} from "../WithdrawProxy.sol";

string constant weth9Artifact = "src/tests/WETH9.json";

interface IWETH9 is IERC20 {
    function deposit() external payable;

    function withdraw(uint256) external;
}

contract Dummy721 is MockERC721 {
    constructor() MockERC721("TEST NFT", "TEST") {
        _mint(msg.sender, 1);
        _mint(msg.sender, 2);
    }
}

contract V3SecurityHook {
    address positionManager;

    constructor(address nftManager_) {
        positionManager = nftManager_;
    }

    function getState(address tokenContract, uint256 tokenId) external view returns (bytes memory) {
        (uint96 nonce, address operator,,,,,, uint128 liquidity,,,,) =
            IV3PositionManager(positionManager).positions(tokenId);
        return abi.encode(nonce, operator, liquidity);
    }
}

contract TestHelpers is Test {
    using CollateralLookup for address;
    using Strings2 for bytes;
    using SafeCastLib for uint256;
    using SafeTransferLib for ERC20;

    uint256 strategistOnePK = uint256(0x1339);
    uint256 strategistTwoPK = uint256(0x1344); // strategistTwo is delegate for PublicVault created by strategistOne
    address strategistOne = vm.addr(strategistOnePK);
    address strategistTwo = vm.addr(strategistTwoPK);

    // address lender = vm.addr(0x1340);
    address borrower = vm.addr(0x1341);
    address bidderOne = vm.addr(0x1342);
    address bidderTwo = vm.addr(0x1343);

    IAstariaRouter.LienDetails standardLien = IAstariaRouter.LienDetails({
        maxAmount: 10 ether,
        rate: uint32(((uint256(0.05 ether)) / 365) * 1 days),
        duration: 10 days, // TODO check if should be block.timestamp + duration
        maxPotentialDebt: 50 ether
    });

    enum UserRoles {
        ADMIN,
        ASTARIA_ROUTER,
        WRAPPER,
        AUCTION_HOUSE,
        TRANSFER_PROXY,
        LIEN_TOKEN
    }

    enum StrategyTypes {
        STANDARD,
        COLLECTION,
        UNIV3_LIQUIDITY
    }

    event NewTermCommitment(bytes32 vault, uint256 collateralId, uint256 amount);
    event Repayment(bytes32 vault, uint256 collateralId, uint256 amount);
    event Liquidation(bytes32 vault, uint256 collateralId);
    event NewVault(address strategist, bytes32 vault, bytes32 contentHash, uint256 expiration);
    event RedeemVault(bytes32 vault, uint256 amount, address indexed redeemer);

    CollateralToken COLLATERAL_TOKEN;
    LienToken LIEN_TOKEN;
    AstariaRouter ASTARIA_ROUTER;
    PublicVault PUBLIC_VAULT;
    WithdrawProxy WITHDRAW_PROXY;
    Vault SOLO_VAULT;
    TransferProxy TRANSFER_PROXY;
    IWETH9 WETH9;
    MultiRolesAuthority MRA;
    AuctionHouse AUCTION_HOUSE;
    bytes32 public whiteListRoot;
    bytes32[] public nftProof;

    function setUp() public virtual {
        WETH9 = IWETH9(deployCode(weth9Artifact));

        MRA = new MultiRolesAuthority(address(this), Authority(address(0)));

        TRANSFER_PROXY = new TransferProxy(MRA);
        LIEN_TOKEN = new LienToken(
            MRA,
            TRANSFER_PROXY,
            address(WETH9)
        );
        COLLATERAL_TOKEN = new CollateralToken(
            MRA,
            TRANSFER_PROXY,
            ILienToken(address(LIEN_TOKEN))
        );

        PUBLIC_VAULT = new PublicVault();
        SOLO_VAULT = new Vault();
        WITHDRAW_PROXY = new WithdrawProxy();

        ASTARIA_ROUTER = new AstariaRouter(
            MRA,
            address(WETH9),
            ICollateralToken(address(COLLATERAL_TOKEN)),
            ILienToken(address(LIEN_TOKEN)),
            ITransferProxy(address(TRANSFER_PROXY)),
            address(PUBLIC_VAULT),
            address(SOLO_VAULT)
        );

        AUCTION_HOUSE = new AuctionHouse(
            address(WETH9),
                MRA,
                ICollateralToken(address(COLLATERAL_TOKEN)),
                ILienToken(address(LIEN_TOKEN)),
                TRANSFER_PROXY
        );

        COLLATERAL_TOKEN.file(bytes32("setAstariaRouter"), abi.encode(address(ASTARIA_ROUTER)));
        COLLATERAL_TOKEN.file(bytes32("setAuctionHouse"), abi.encode(address(AUCTION_HOUSE)));
        V3SecurityHook V3_SECURITY_HOOK = new V3SecurityHook(
            address(0xC36442b4a4522E871399CD717aBDD847Ab11FE88)
        );

        //strategy unique
        UniqueValidator UNIQUE_STRATEGY_VALIDATOR = new UniqueValidator();
        //strategy collection
        CollectionValidator COLLECTION_STRATEGY_VALIDATOR = new CollectionValidator();
        //strategy univ3
        UNI_V3Validator UNIV3_LIQUIDITY_STRATEGY_VALIDATOR = new UNI_V3Validator();

        ASTARIA_ROUTER.file("setStrategyValidator", abi.encode(uint8(0), address(UNIQUE_STRATEGY_VALIDATOR)));
        ASTARIA_ROUTER.file("setStrategyValidator", abi.encode(uint8(1), address(COLLECTION_STRATEGY_VALIDATOR)));
        ASTARIA_ROUTER.file("setStrategyValidator", abi.encode(uint8(2), address(UNIV3_LIQUIDITY_STRATEGY_VALIDATOR)));
        ASTARIA_ROUTER.file("WITHDRAW_IMPLEMENTATION", abi.encode(WITHDRAW_PROXY));
        COLLATERAL_TOKEN.file(
            bytes32("setSecurityHook"),
            abi.encode(address(0xC36442b4a4522E871399CD717aBDD847Ab11FE88), address(V3_SECURITY_HOOK))
        );
        //v3 NFT manager address

        LIEN_TOKEN.file(bytes32("setAuctionHouse"), abi.encode(address(AUCTION_HOUSE)));
        LIEN_TOKEN.file(bytes32("setCollateralToken"), abi.encode(address(COLLATERAL_TOKEN)));
        LIEN_TOKEN.file(bytes32("setAstariaRouter"), abi.encode(address(ASTARIA_ROUTER)));

        _setupRolesAndCapabilities();
    }

    function _setupRolesAndCapabilities() internal {
        MRA.setRoleCapability(uint8(UserRoles.WRAPPER), AuctionHouse.createAuction.selector, true);
        MRA.setRoleCapability(uint8(UserRoles.WRAPPER), AuctionHouse.endAuction.selector, true);
        MRA.setRoleCapability(uint8(UserRoles.ASTARIA_ROUTER), LienToken.createLien.selector, true);
        MRA.setRoleCapability(uint8(UserRoles.WRAPPER), AuctionHouse.cancelAuction.selector, true);
        MRA.setRoleCapability(uint8(UserRoles.ASTARIA_ROUTER), CollateralToken.auctionVault.selector, true);
        MRA.setRoleCapability(uint8(UserRoles.ASTARIA_ROUTER), TRANSFER_PROXY.tokenTransferFrom.selector, true);
        MRA.setRoleCapability(uint8(UserRoles.AUCTION_HOUSE), LienToken.removeLiens.selector, true);
        MRA.setRoleCapability(uint8(UserRoles.AUCTION_HOUSE), LienToken.stopLiens.selector, true);
        MRA.setRoleCapability(uint8(UserRoles.AUCTION_HOUSE), TRANSFER_PROXY.tokenTransferFrom.selector, true);
        MRA.setUserRole(address(ASTARIA_ROUTER), uint8(UserRoles.ASTARIA_ROUTER), true);
        MRA.setUserRole(address(COLLATERAL_TOKEN), uint8(UserRoles.WRAPPER), true);
        MRA.setUserRole(address(AUCTION_HOUSE), uint8(UserRoles.AUCTION_HOUSE), true);

        // TODO add to AstariaDeploy(?)
        MRA.setRoleCapability(uint8(UserRoles.LIEN_TOKEN), TRANSFER_PROXY.tokenTransferFrom.selector, true);
        MRA.setUserRole(address(LIEN_TOKEN), uint8(UserRoles.LIEN_TOKEN), true);
    }

    // wrap NFT in a CollateralToken
    function _depositNFT(address tokenContract, uint256 tokenId) internal {
        ERC721(tokenContract).safeTransferFrom(address(this), address(COLLATERAL_TOKEN), uint256(tokenId), "");
    }

    function _createPrivateVault(address strategist, address delegate) internal returns (address privateVault) {
        vm.startPrank(strategist);
        privateVault = ASTARIA_ROUTER.newVault(delegate);
        vm.stopPrank();
    }

    function _createPublicVault(address strategist, address delegate, uint256 epochLength)
        internal
        returns (address publicVault)
    {
        vm.startPrank(strategist);
        //bps
        publicVault = ASTARIA_ROUTER.newPublicVault(epochLength, delegate, uint256(5000));
        vm.stopPrank();
    }

    function _generateLoanMerkleProof(
        address strategist,
        address tokenContract,
        uint256 tokenId,
        IAstariaRouter.LienRequestType requestType,
        bytes memory data,
        address vault
    ) internal returns (bytes32 rootHash, bytes32[] memory merkleProof) {
        uint256 collateralId = uint256(keccak256(abi.encodePacked(tokenContract, tokenId)));

        string[] memory inputs;
        if (requestType == IAstariaRouter.LienRequestType.UNIV3_LIQUIDITY) {
            inputs = new string[](13);
        } else {
            inputs = new string[](10);
        }

        // TODO make readable
        inputs[0] = "node";
        inputs[1] = "scripts/loanProofGenerator.js";
        inputs[2] = abi.encodePacked(tokenContract).toHexString(); //tokenContract
        if (requestType == IAstariaRouter.LienRequestType.UNIQUE) {
            inputs[3] = abi.encodePacked(tokenId).toHexString(); //tokenId
            inputs[4] = abi.encodePacked(strategist).toHexString(); //appraiserOne
            inputs[5] = abi.encodePacked(block.timestamp + 2 days).toHexString(); //fixed for 2 days atm
            inputs[6] = abi.encodePacked(vault).toHexString(); //vault

            IUniqueValidator.Details memory terms = abi.decode(data, (IUniqueValidator.Details));

            //vault details
            inputs[7] = abi.encodePacked(uint8(StrategyTypes.STANDARD)).toHexString(); //type
            inputs[8] = abi.encodePacked(address(0)).toHexString(); //borrower
            inputs[9] = abi.encode(terms.lien).toHexString(); //lien details
        } else {
            inputs[3] = abi.encodePacked(strategist).toHexString(); //appraiserOne
            inputs[4] = abi.encodePacked(block.timestamp + 2 days).toHexString(); //fixed for 2 days atm
            inputs[5] = abi.encodePacked(vault).toHexString(); //vault
            if (requestType == IAstariaRouter.LienRequestType.COLLECTION) {
                ICollectionValidator.Details memory terms = abi.decode(data, (ICollectionValidator.Details));

                inputs[6] = abi.encodePacked(uint8(StrategyTypes.COLLECTION)).toHexString(); //type
                inputs[7] = abi.encodePacked(address(0)).toHexString(); //borrower
                inputs[8] = abi.encode(terms.lien).toHexString(); //lien details
            } else {
                // LienRequestType.UNIV3_LIQUIDITY
                IUNI_V3Validator.Details memory terms = abi.decode(data, (IUNI_V3Validator.Details));

                inputs[6] = abi.encodePacked(uint8(IAstariaRouter.LienRequestType.UNIV3_LIQUIDITY)).toHexString(); //type
                inputs[7] = abi.encodePacked(terms.assets).toHexString(); // [token0, token1]
                inputs[8] = abi.encodePacked(terms.fee).toHexString(); //lien details
                inputs[9] = abi.encodePacked(terms.tickLower).toHexString(); //lien details
                inputs[10] = abi.encodePacked(terms.tickUpper).toHexString(); //lien details
                inputs[11] = abi.encodePacked(address(0)).toHexString(); //borrower
                inputs[12] = abi.encode(terms.lien).toHexString(); //lien details
            }
        }

        bytes memory res = vm.ffi(inputs);
        (rootHash, merkleProof) = abi.decode(res, (bytes32, bytes32[]));
    }

    function _generateLoanMerkleProof2(IAstariaRouter.LienRequestType requestType, bytes memory data)
        internal
        returns (bytes32 rootHash, bytes32[] memory merkleProof)
    {
        string[] memory inputs = new string[](4);
        inputs[0] = "node";
        inputs[1] = "scripts/loanProofGenerator2.js";

        if (requestType == IAstariaRouter.LienRequestType.UNIQUE) {
            IUniqueValidator.Details memory terms = abi.decode(data, (IUniqueValidator.Details));
            inputs[2] = abi.encodePacked(uint8(0)).toHexString(); //type
            inputs[3] = abi.encode(terms).toHexString();
        } else if (requestType == IAstariaRouter.LienRequestType.COLLECTION) {
            ICollectionValidator.Details memory terms = abi.decode(data, (ICollectionValidator.Details));
            inputs[2] = abi.encodePacked(uint8(1)).toHexString(); //type
            inputs[3] = abi.encode(terms).toHexString();
        } else if (requestType == IAstariaRouter.LienRequestType.UNIV3_LIQUIDITY) {
            IUNI_V3Validator.Details memory terms = abi.decode(data, (IUNI_V3Validator.Details));
            inputs[2] = abi.encodePacked(uint8(2)).toHexString(); //type
            inputs[3] = abi.encode(terms).toHexString();
        } else {
            revert("unsupported");
        }

        bytes memory res = vm.ffi(inputs);
        (rootHash, merkleProof) = abi.decode(res, (bytes32, bytes32[]));
    }

    function _commitToLien(
        address vault, // address of deployed Vault
        address strategist,
        uint256 strategistPK,
        address tokenContract, // original NFT address
        uint256 tokenId, // original NFT id
        IAstariaRouter.LienDetails memory lienDetails, // loan information
        uint256 amount // requested amount
    ) internal {
        ERC721(tokenContract).safeTransferFrom(address(this), address(COLLATERAL_TOKEN), uint256(tokenId), ""); // deposit NFT in CollateralToken

        uint256 collateralTokenId = tokenContract.computeId(tokenId);

        // address vault = _createPublicVault({strategist: strategistOne, delegate: strategistTwo, epochLength: 14 days});

        bytes memory validatorDetails = abi.encode(
            IUniqueValidator.Details({
                version: uint8(1),
                token: tokenContract,
                tokenId: tokenId,
                borrower: address(0),
                lien: lienDetails
            })
        );

        (bytes32 rootHash, bytes32[] memory merkleProof) =
            _generateLoanMerkleProof2({requestType: IAstariaRouter.LienRequestType.UNIQUE, data: validatorDetails});

        // setup 712 signature

        IAstariaRouter.StrategyDetails memory strategyDetails = IAstariaRouter.StrategyDetails({
            version: uint8(0),
            strategist: strategist,
            deadline: block.timestamp + 10 days,
            vault: vault
        });

        bytes32 termHash = keccak256(VaultImplementation(vault).encodeStrategyData(strategyDetails, rootHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(strategistPK, termHash);

        IAstariaRouter.Commitment memory terms = IAstariaRouter.Commitment({
            tokenContract: tokenContract,
            tokenId: tokenId,
            lienRequest: IAstariaRouter.NewLienRequest({
                strategy: strategyDetails,
                nlrType: uint8(IAstariaRouter.LienRequestType.UNIQUE), // TODO support others?
                nlrDetails: validatorDetails,
                merkle: IAstariaRouter.MerkleData({root: rootHash, proof: merkleProof}),
                amount: amount,
                v: v,
                r: r,
                s: s
            })
        });

        VaultImplementation(vault).commitToLien(terms, address(this));
    }

    struct Lender {
        address addr;
        uint256 amountToLend;
    }

    function _lendToVault(Lender memory lender, address vault) internal {
        vm.deal(lender.addr, lender.amountToLend);
        vm.startPrank(lender.addr);
        WETH9.deposit{value: lender.amountToLend}();
        WETH9.approve(vault, lender.amountToLend);
        PublicVault(vault).deposit(lender.amountToLend, lender.addr);
        vm.stopPrank();
    }

    struct Borrow {
        address borrower;
        uint256 amount; // TODO allow custom LienDetails too
        uint256 repayAmount; // if less than amount, then auction initiated with a bid of bidAmount
        uint256 bidAmount;
        uint256 timestamp;
    }

    // withdrawEpoch is epoch when lender signals a withdraw, not when they collect funds
    // function _lendWithWithdraw(Lender memory lender, address vault, uint64 withdrawEpoch) {
    //     require(withdrawEpoch >= PublicVault(vault).currentEpoch, "withdraw epoch must be at least current epoch");
    //     _lendToVault(lender, vault);

    // }

    function _lendToVault(Lender[] memory lenders, address vault) internal {
        for (uint256 i = 0; i < lenders.length; i++) {
            _lendToVault(lenders[i], vault);
        }
    }

    function _bid(address bidder, uint256 tokenId, uint256 amount) internal {
        vm.deal(bidder, amount * 2); // TODO check amount multiplier, was 1.5 in old testhelpers
        vm.startPrank(bidder);
        WETH9.deposit{value: amount}();
        WETH9.approve(address(TRANSFER_PROXY), amount);
        vm.stopPrank();
    }

    // Redeem VaultTokens for WithdrawTokens redeemable by the end of the next epoch.
    function _signalWithdraw(address lender, address publicVault) internal {
        uint256 vaultTokenBalance = IERC20(publicVault).balanceOf(lender);
        ERC20(publicVault).safeApprove(publicVault, vaultTokenBalance);
        PublicVault(publicVault).redeemFutureEpoch({
            shares: vaultTokenBalance,
            receiver: lender,
            owner: lender,
            epoch: PublicVault(publicVault).currentEpoch()
        });
    }
    // Redeem VaultTokens for WithdrawTokens redeemable by the end of the next epoch.

    function _signalWithdrawAtFutureEpoch(address lender, address publicVault, uint64 epoch) internal {
        uint256 vaultTokenBalance = IERC20(publicVault).balanceOf(lender);
        ERC20(publicVault).safeApprove(publicVault, vaultTokenBalance);
        PublicVault(publicVault).redeemFutureEpoch({
            shares: vaultTokenBalance,
            receiver: lender,
            owner: lender,
            epoch: epoch
        });
    }
}
