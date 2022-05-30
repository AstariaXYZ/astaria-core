pragma solidity ^0.8.13;

import "openzeppelin/token/ERC1155/ERC1155.sol";
import "openzeppelin/token/ERC721/IERC721.sol";
import "openzeppelin/token/ERC20/IERC20.sol";
import "openzeppelin/utils/cryptography/MerkleProof.sol";
import "./interfaces/IAuctionHouse.sol";
import "openzeppelin/proxy/Clones.sol";
import "./interfaces/IStarNFT.sol";
import "./TransferProxy.sol";
import "./BrokerImplementation.sol";
import "../lib/solmate/src/utils/FixedPointMathLib.sol";

//import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

contract NFTBondController is ERC1155 {
    bytes32 public immutable DOMAIN_SEPARATOR;
    mapping(address => uint256) public tokenNonces;
    using FixedPointMathLib for uint256;

    string public constant name = "Astaria NFT Bond Vault";
    IERC20 immutable WETH;
    IStarNFT immutable COLLATERAL_VAULT;
    TransferProxy immutable TRANSFER_PROXY;
    address BEACON_CLONE;

    uint256 LIQUIDATION_FEE; // a percent(13) then mul by 100

    mapping(bytes32 => BondVault) bondVaults;
    mapping(address => uint256) public appraiserNonces;

    event NewLoan(bytes32 bondVault, uint256 collateralVault, uint256 amount);
    event Repayment(
        bytes32 bondVault,
        uint256 collateralVault,
        uint256 index,
        uint256 amount
    );
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

    error InvalidAddress(address);

    struct BondVault {
        // bytes32 root; // root for the appraisal merkle tree provided by the appraiser
        address appraiser; // address of the appraiser for the BondVault
        uint256 totalSupply;
        uint256 balance; // WETH balance of vault=
        mapping(uint256 => Loan[]) loans; // all open borrows in vault
        uint256 loanCount;
        uint256 expiration; // expiration for lenders to add assets and expiration when borrowers cannot create new borrows
        uint256 maturity; // epoch when the loan becomes due
        address broker; //cloned proxy
    }

    // could be replaced with a single byte32 value, pass in merkle proof to liquidate
    struct Loan {
        //        uint256 collateralVault; // ERC721, 1155 will be wrapped to create a singular tokenId
        uint256 amount; // loans are only in wETH
        uint256 interestRate; // rate of interest accruing on the borrow (should be in seconds to make calculations easy)
        uint256 start; // epoch time of last interest accrual
        uint256 end; // epoch time at which the loan must be repaid
        // lienPosition should be managed on the CollateralVault
        bytes32 bondVault;
        //        uint8 lienPosition; // position of repayment, borrower can take out multiple loans on the same NFT, if the NFT becomes liquidated the lowest lien psoition is repaid first
        uint256 schedule; // percentage margin before the borrower needs to repay
    }

    constructor(
        string memory _uri,
        address _WETH,
        address _COLLATERAL_VAULT,
        address _TRANSFER_PROXY,
        address _BEACON_CLONE
    ) ERC1155(_uri) {
        WETH = IERC20(_WETH);
        COLLATERAL_VAULT = IStarNFT(_COLLATERAL_VAULT);
        TRANSFER_PROXY = TransferProxy(_TRANSFER_PROXY);
        BEACON_CLONE = _BEACON_CLONE;
        LIQUIDATION_FEE = 3;
        uint256 chainId;
        assembly {
            chainId := chainid()
        }
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256("NFTBondController"),
                keccak256("1"),
                chainId,
                address(this)
            )
        );
        WETH.approve(address(TRANSFER_PROXY), type(uint256).max);
    }

    function getBondData(bytes32 bondVault, uint256 collateralVault)
        public
        view
        returns (
            address,
            uint256,
            uint256,
            Loan[] memory,
            uint256,
            uint256, // expiration for lenders to add assets and expiration when borrowers cannot create new borrows
            uint256
        )
    {
        BondVault storage vault = bondVaults[bondVault];
        Loan[] memory loans = vault.loans[collateralVault];
        return (
            vault.appraiser,
            vault.totalSupply,
            vault.balance,
            loans,
            vault.loanCount,
            vault.expiration,
            vault.maturity
        );
    }

    // See https://eips.ethereum.org/EIPS/eip-191
    string private constant EIP191_PREFIX_FOR_EIP712_STRUCTURED_DATA =
        "\x19\x01";
    // keccak256("Permit(address owner,address spender,bool approved,uint256 nonce,uint256 deadline)");
    bytes32 private constant PERMIT_SIGNATURE_HASH =
        keccak256(
            "Permit(address owner,address spender,bool approved,uint256 nonce,uint256 deadline)"
        );
    bytes32 private constant NEW_VAULT_SIGNATURE_HASH =
        keccak256(
            "NewBondVault(address appraiser,bytes32 root,uint256 expiration,uint256 nonce,uint256 deadline,uint256 maturity)"
        );

    function permit(
        address owner_,
        address spender,
        bool approved,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        require(owner_ != address(0), "ERC1155: Owner cannot be 0");
        require(block.timestamp < deadline, "ERC1155: Expired");
        bytes32 digest = keccak256(
            abi.encodePacked(
                EIP191_PREFIX_FOR_EIP712_STRUCTURED_DATA,
                DOMAIN_SEPARATOR,
                keccak256(
                    abi.encode(
                        PERMIT_SIGNATURE_HASH,
                        owner_,
                        spender,
                        approved,
                        tokenNonces[owner_]++,
                        deadline
                    )
                )
            )
        );
        address recoveredAddress = ecrecover(digest, v, r, s);
        require(recoveredAddress == owner_, "ERC1155: Invalid Signature");
        _setApprovalForAll(owner_, spender, approved);
    }

    // _verify() internal
    // merkle tree verifier

    // verifies the signature on the root of the merkle tree to be the appraiser
    // we need an additional method to prevent a griefing attack where the signature is stripped off and reserrved by an attacker
    function newBondVault(
        address appraiser,
        bytes32 root,
        uint256 expiration,
        uint256 deadline,
        uint256 maturity,
        bytes32 contentHash,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        require(
            appraiser != address(0),
            "NFTBondController.newBondVault(): Appraiser address cannot be zero"
        );
        require(
            bondVaults[root].appraiser == address(0),
            "NFTBondController.newBondVault(): Root of BondVault already instantiated"
        );
        require(
            block.timestamp < deadline,
            "NFTBondController.newBondVault(): Expired"
        );
        bytes32 digest = keccak256(
            encodeBondVaultHash(
                appraiser,
                root,
                expiration,
                deadline,
                maturity,
                appraiserNonces[msg.sender]++
            )
        );

        address recoveredAddress = ecrecover(digest, v, r, s);
        require(
            recoveredAddress == appraiser,
            "newBondVault: Invalid Signature"
        );

        _newBondVault(appraiser, root, contentHash, expiration);
    }

    function encodeBondVaultHash(
        address appraiser,
        bytes32 root,
        uint256 expiration,
        uint256 deadline,
        uint256 maturity,
        uint256 appraiserNonce
    ) public view returns (bytes memory) {
        return
            abi.encodePacked(
                EIP191_PREFIX_FOR_EIP712_STRUCTURED_DATA,
                DOMAIN_SEPARATOR,
                keccak256(
                    abi.encode(
                        NEW_VAULT_SIGNATURE_HASH,
                        appraiser,
                        root,
                        expiration,
                        appraiserNonce,
                        deadline,
                        maturity
                    )
                )
            );
    }

    function refinanceLoan(
        bytes32 bondVaultOutgoing,
        bytes32 bondVaultIncoming,
        uint256 collateralVault,
        uint256 index,
        uint256 interestRate,
        uint256 end
    ) external {
        Loan memory loan = bondVaults[bondVaultOutgoing].loans[collateralVault][
            index
        ];
        uint256 interestOwed = getInterest(
            bondVaultOutgoing,
            index,
            collateralVault
        );
        uint256 amountOwed = interestOwed + loan.amount;
        require(interestRate <= (loan.interestRate * 500) / 1000); //TODO: min "beat price"

        //transfer proxy in the weth from sender to the bondvault
        TRANSFER_PROXY.tokenTransferFrom(
            address(WETH),
            address(msg.sender),
            address(this),
            amountOwed
        );
        bondVaults[bondVaultOutgoing].balance += amountOwed;
        bondVaults[bondVaultOutgoing].loanCount--;
        //if we dont create here perhaps we require that a bondvault is created before you can refinance,
        _newBondVault(
            address(msg.sender),
            bondVaultIncoming,
            bytes32(0),
            uint256(block.timestamp + 30 days)
        );

        bondVaults[bondVaultIncoming].loans[collateralVault].push(
            Loan(
                loan.amount,
                interestRate,
                block.timestamp,
                loan.end,
                bondVaultIncoming,
                loan.schedule
            )
        );

        _swapLien(bondVaultOutgoing, bondVaultIncoming, collateralVault, index);
        delete bondVaults[bondVaultOutgoing].loans[collateralVault][index];
    }

    function _newBondVault(
        address appraiser,
        bytes32 root,
        bytes32 contentHash,
        uint256 expiration
    ) internal {
        //        address proxy = Clones.cloneDeterministic(BEACON_CLONE, root);
        //        address[] memory tokens = new address[](1);
        //        tokens[0] = address(WETH);
        //        BrokerImplementation(proxy).initialize(tokens, address(TRANSFER_PROXY));

        address proxy = Clones.predictDeterministicAddress(
            BEACON_CLONE,
            root,
            address(this)
        );
        BondVault storage bondVault = bondVaults[root];
        bondVault.appraiser = appraiser;
        bondVault.expiration = expiration;
        bondVault.broker = proxy;

        emit NewBondVault(appraiser, proxy, root, contentHash, expiration);
    }

    // maxAmount so the borrower has the option to borrow less
    // collateralVault is a tokenId that is precomputed off chain using the elements from the request
    function commitToLoan(
        bytes32[] calldata proof,
        bytes32 bondVault,
        uint256 collateralVault,
        uint256 maxAmount,
        uint256 interestRate,
        uint256 start,
        uint256 end,
        uint256 amount,
        uint8 lienPosition,
        uint256 schedule
    ) external {
        require(
            msg.sender == COLLATERAL_VAULT.ownerOf(collateralVault),
            "NFTBondController.commitToLoan(): Owner of the collateral vault must be msg.sender"
        );
        require(
            bondVaults[bondVault].appraiser != address(0),
            "NFTBondController.commitToLoan(): Attempting to instantiate an unitialized vault"
        );
        require(
            maxAmount >= amount,
            "NFTBondController.commitToLoan(): Attempting to borrow more than maxAmount"
        );
        require(
            amount <= bondVaults[bondVault].balance,
            "NFTBondController.commitToLoan():  Attempting to borrow more than available in the specified vault"
        );
        // filler hashing schema for merkle tree
        bytes32 leaf = keccak256(
            abi.encodePacked(
                keccak256(
                    abi.encode(
                        collateralVault,
                        maxAmount,
                        interestRate,
                        start,
                        end,
                        lienPosition,
                        schedule
                    )
                )
            )
        );
        require(
            verifyMerkleBranch(proof, leaf, bondVault),
            "NFTBondController.commitToLoan(): Verification of provided merkle branch failed for the bondVault and parameters"
        );

        //ensure that we have space left in our appraisal value to take on more debt or refactor so each collateral
        //can only have one loan per bondvault associated to it

        bondVaults[bondVault].loans[collateralVault].push(
            Loan(amount, interestRate, start, end, bondVault, schedule)
        );
        _addLien(bondVault, lienPosition, collateralVault);

        //        WETH.transfer(msg.sender, amount);
        TRANSFER_PROXY.tokenTransferFrom(
            address(WETH),
            address(this),
            address(msg.sender),
            amount
        );
        //        TRANSFER_PROXY.tokenTransferFrom(
        //            address(WETH),
        //            bondVaults[bondVault].broker,
        //            address(msg.sender),
        //            amount
        //        );
        bondVaults[bondVault].loanCount++;
        bondVaults[bondVault].balance -= amount;
        emit NewLoan(bondVault, collateralVault, amount);
    }

    function _addLien(
        bytes32 bondVault,
        uint256 position,
        uint256 collateralVault
    ) internal {
        COLLATERAL_VAULT.manageLien(
            collateralVault,
            IStarNFT.LienAction.ENCUMBER,
            abi.encodePacked(
                bondVault,
                position,
                bondVaults[bondVault].loans[collateralVault].length - 1 //loan index
            )
        );
    }

    function _removeLien(
        bytes32 bondVault,
        uint256 collateralVault,
        uint256 index
    ) internal {
        COLLATERAL_VAULT.manageLien(
            collateralVault,
            IStarNFT.LienAction.UN_ENCUMBER,
            abi.encodePacked(bondVault, index)
        );
    }

    function _swapLien(
        bytes32 bondVaultOld,
        bytes32 bondVaultNew,
        uint256 collateralVault,
        uint256 index
    ) internal {
        COLLATERAL_VAULT.manageLien(
            collateralVault,
            IStarNFT.LienAction.SWAP_VAULT,
            abi.encodePacked(bondVaultOld, bondVaultNew, index)
        );
    }

    // stubbed for now
    function verifyMerkleBranch(
        bytes32[] calldata proof,
        bytes32 leaf,
        bytes32 root
    ) public view returns (bool) {
        return true;
    }

    function lendToVault(bytes32 bondVault, uint256 amount) external {
        //        require(
        //            WETH.transferFrom(msg.sender, address(this), amount),
        //            "lendToVault: transfer failed"
        //        );

        TRANSFER_PROXY.tokenTransferFrom(
            address(WETH),
            address(msg.sender),
            address(this),
            amount
        );
        require(
            bondVaults[bondVault].appraiser != address(0),
            "lendToVault: vault doesn't exist"
        );
        require(
            block.timestamp < bondVaults[bondVault].expiration,
            "lendToVault: expiration exceeded"
        );
        bondVaults[bondVault].totalSupply += amount;
        bondVaults[bondVault].balance += amount;
        _mint(msg.sender, uint256(bondVault), amount, "");
    }

    function repayLoan(
        bytes32 bondVault,
        uint256 collateralVault,
        uint256 index,
        uint256 amount
    ) external {
        // calculates interest here and apply it to the loan
        bondVaults[bondVault]
        .loans[collateralVault][index].amount += getInterest(
            bondVault,
            index,
            collateralVault
        );
        amount = (bondVaults[bondVault].loans[collateralVault][index].amount >=
            amount)
            ? amount
            : bondVaults[bondVault].loans[collateralVault][index].amount;
        //        require(
        //            WETH.transferFrom(msg.sender, address(this), amount),
        //            "repayLoan: transfer failed"
        //        );
        TRANSFER_PROXY.tokenTransferFrom(
            address(WETH),
            address(msg.sender),
            address(this),
            amount
        );
        bondVaults[bondVault].loans[collateralVault][index].amount -= amount;
        bondVaults[bondVault].loans[collateralVault][index].start = block
            .timestamp;

        if (bondVaults[bondVault].loans[collateralVault][index].amount == 0) {
            _removeLien(bondVault, collateralVault, index);
        }
    }

    function getInterest(
        bytes32 bondVault,
        uint256 index,
        uint256 collateralVault
    ) public view returns (uint256) {
        uint256 delta_t = block.timestamp -
            bondVaults[bondVault].loans[collateralVault][index].start;
        return (delta_t *
            bondVaults[bondVault].loans[collateralVault][index].interestRate *
            bondVaults[bondVault].loans[collateralVault][index].amount);
    }

    function canLiquidate(
        bytes32 bondVault,
        uint256 index,
        uint256 collateralVault
    ) public view returns (bool) {
        //        uint256 delta_t = block.timestamp -
        //            bondVaults[bondVault].loans[collateralVault][index].start;
        //        uint256 interest = delta_t *
        //            bondVaults[bondVault].loans[collateralVault][index].interestRate *
        //            bondVaults[bondVault].loans[collateralVault][index].amount;
        uint256 interest = getInterest(bondVault, index, collateralVault);
        uint256 maxInterest = bondVaults[bondVault]
        .loans[collateralVault][index].amount *
            bondVaults[bondVault].loans[collateralVault][index].schedule;
        return
            maxInterest > interest ||
            (bondVaults[bondVault].loans[collateralVault][index].end >=
                block.timestamp &&
                bondVaults[bondVault].loans[collateralVault][index].amount >
                0) ||
            (bondVaults[bondVault].maturity >= block.timestamp &&
                bondVaults[bondVault].loans[collateralVault][index].amount > 0);
    }

    // person calling liquidate should get some incentive from the auction
    function liquidate(
        bytes32 bondVault,
        uint256 index,
        uint256 collateralVault
    ) external returns (uint256 reserve) {
        require(
            canLiquidate(bondVault, index, collateralVault),
            "liquidate: borrow is healthy"
        );
        //grab all lien positions compute all outstanding
        (
            bytes32[] memory vaults,
            //            uint256[] amounts,
            uint256[] memory indexes
        ) = COLLATERAL_VAULT.getLiens(collateralVault);
        //        Loan[] storage loans = bondVaults[bondVault].loans[collateralVault];

        for (uint256 i = 0; i < vaults.length; i++) {
            Loan memory loan = bondVaults[vaults[i]].loans[collateralVault][
                indexes[i]
            ];
            reserve += loan.amount;
            delete bondVaults[bondVault].loans[collateralVault][indexes[i]];
        }

        reserve += ((reserve * LIQUIDATION_FEE) / 100);

        COLLATERAL_VAULT.auctionVault(bondVault, collateralVault, reserve);
    }

    // called by the collateral wrapper when the auction is complete
    //do we need index? since we have to liquidation everything from ground up
    function complete(
        uint256 collateralVault,
        bytes32[] memory vaults,
        uint256[] memory indexes,
        uint256 recovered,
        bool liquidation
    ) external {
        require(
            msg.sender == address(COLLATERAL_VAULT),
            "completeLiquidation: must be collateral wrapper to call this"
        );
        uint256 remaining = _bulkRepay(
            collateralVault,
            vaults,
            indexes,
            recovered
        );

        if (liquidation) {
            if (remaining > uint256(0)) {
                //pay remaining to the token holder
                TRANSFER_PROXY.tokenTransferFrom(
                    address(WETH),
                    address(this),
                    address(COLLATERAL_VAULT.ownerOf(collateralVault)),
                    remaining
                );
            }
            emit Liquidation(collateralVault, vaults, indexes, recovered);
        }
    }

    function _bulkRepay(
        uint256 collateralVault,
        bytes32[] memory vaults,
        uint256[] memory indexes,
        uint256 payout
    ) internal returns (uint256) {
        unchecked {
            for (uint256 i = 0; i < vaults.length; ++i) {
                bytes32 vaultHash = vaults[i];
                uint256 index = indexes[i];
                Loan storage loan = bondVaults[vaultHash].loans[
                    collateralVault
                ][indexes[i]];
                uint256 payment = loan.amount +
                    getInterest(vaultHash, index, collateralVault);
                if (payout >= payment) {
                    payout -= payment;
                    bondVaults[vaults[i]].balance += payment;
                    emit Repayment(vaultHash, collateralVault, index, payment);
                } else {
                    payment = payout;
                    payout = uint256(0);
                }
                bondVaults[vaultHash].loanCount--;
                delete bondVaults[vaultHash].loans[collateralVault][indexes[i]];
            }
        }
        return payout;
    }

    function redeemBond(bytes32 bondVault, uint256 amount) external {
        require(
            block.timestamp >= bondVaults[bondVault].maturity,
            "redeemBond: maturity not reached"
        );

        require(
            bondVaults[bondVault].loanCount == 0,
            "redeemBond: loans outstanding"
        );

        require(balanceOf(msg.sender, uint256(bondVault)) >= amount);

        _burn(msg.sender, uint256(bondVault), amount);

        uint256 yield = amount
            .divWadDown(bondVaults[bondVault].totalSupply)
            .mulWadDown(bondVaults[bondVault].balance);

        unchecked {
            bondVaults[bondVault].totalSupply -= amount;
        }
        TRANSFER_PROXY.tokenTransferFrom(
            address(WETH),
            address(this),
            address(msg.sender),
            yield
        );
        emit RedeemBond(bondVault, amount, address(msg.sender));
    }
}
