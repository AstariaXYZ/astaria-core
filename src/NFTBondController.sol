pragma solidity ^0.8.13;

import "openzeppelin/token/ERC1155/ERC1155.sol";
import "openzeppelin/token/ERC721/IERC721.sol";
import "openzeppelin/token/ERC20/IERC20.sol";
import "openzeppelin/utils/cryptography/MerkleProof.sol";
import "./interfaces/IAuctionHouse.sol";

interface IERC721Wrapper is IERC721 {
    enum LienAction {
        ENCUMBER,
        UN_ENCUMBER
    }

    function manageLien(
        uint256 tokenId_,
        bytes32 lienHash,
        LienAction action
    ) external;

    function auctionVault(
        bytes32 bondVault,
        uint256 tokenId,
        uint256 reservePrice
    ) external;

    //
    //    function getUnderlyingFromStar(uint256 starId_)
    //        external
    //        view
    //        returns (address, uint256);
}

contract NFTBondController is ERC1155 {
    bytes32 public immutable DOMAIN_SEPARATOR;
    mapping(address => uint256) public tokenNonces;

    string public name = "Astaria NFT Bond Vault";
    IERC20 immutable WETH;
    IERC721Wrapper immutable COLLATERAL_VAULT;
    IAuctionHouse immutable AUCTION_HOUSE;

    uint256 AUCTION_DURATION;
    uint256 LIQUIDATION_FEE; // a percent(13) then mul by 100

    mapping(bytes32 => BondVault) bondVaults;
    mapping(bytes32 => uint256) collateralAuctions;
    mapping(address => uint256) public appraiserNonces;

    event NewLoan(bytes32 bondVault, uint256 collateralVault, uint256 amount);
    event Repayment(bytes32 bondVault, uint256 collateralVault, uint256 amount);
    event Liquidation(bytes32 bondVault, uint256 collateralVault);
    event NewBondVault(
        address appraiser,
        bytes32 bondVault,
        bytes32 contentHash,
        uint256 expiration
    );

    struct BondVault {
        // bytes32 root; // root for the appraisal merkle tree provided by the appraiser
        address appraiser; // address of the appraiser for the BondVault
        uint256 totalSupply;
        uint256 balance; // WETH balance of vault=
        mapping(uint256 => Loan[]) loans; // all open borrows in vault
        uint256 loanCount;
        uint256 expiration; // expiration for lenders to add assets and expiration when borrowers cannot create new borrows
        uint256 maturity; // epoch when the loan becomes due
    }

    // could be replaced with a single byte32 value, pass in merkle proof to liquidate
    struct Loan {
        //        uint256 collateralVault; // ERC721, 1155 will be wrapped to create a singular tokenId
        uint256 amount; // loans are only in wETH
        uint256 interestRate; // rate of interest accruing on the borrow (should be in seconds to make calculations easy)
        uint256 start; // epoch time of last interest accrual
        uint256 end; // epoch time at which the loan must be repaid
        // lienPosition should be managed on the CollateralVault
        // uint8 lienPosition; // position of repayment, borrower can take out multiple loans on the same NFT, if the NFT becomes liquidated the lowest lien psoition is repaid first
        uint256 schedule; // percentage margin before the borrower needs to repay
    }

    constructor(
        string memory _uri,
        address _AUTHORITY,
        address _WETH,
        address _COLLATERAL_VAULT,
        address _AUCTION_HOUSE
    ) ERC1155(_uri) {
        WETH = IERC20(_WETH);
        COLLATERAL_VAULT = IERC721Wrapper(_COLLATERAL_VAULT);
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
        AUCTION_DURATION = 7 days;
        AUCTION_HOUSE = IAuctionHouse(_AUCTION_HOUSE);
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
            bondVaults[root].appraiser != address(0),
            "NFTBondController.newBondVault(): Root of BondVault already instantiated"
        );
        require(
            block.timestamp < deadline,
            "NFTBondController.newBondVault(): Expired"
        );
        bytes32 digest = keccak256(
            encodeBondVaultHash(appraiser, root, expiration, deadline, maturity)
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
        uint256 maturity
    ) internal returns (bytes memory) {
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
                        appraiserNonces[appraiser]++,
                        deadline,
                        maturity
                    )
                )
            );
    }

    function _newBondVault(
        address appraiser,
        bytes32 root,
        bytes32 contentHash,
        uint256 expiration
    ) internal {
        BondVault storage bondVault = bondVaults[root];
        bondVault.appraiser = appraiser;
        bondVault.expiration = expiration;
        emit NewBondVault(appraiser, root, contentHash, expiration);
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
        uint256 lienPosition,
        uint256 schedule
    ) external {
        require(
            msg.sender != COLLATERAL_VAULT.ownerOf(collateralVault),
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

        bondVaults[bondVault].loans[collateralVault].push(
            Loan(amount, interestRate, start, end, schedule)
        );
        //        COLLATERAL_VAULT.transferFrom( //dont need to transfer in the vault token, it holds the debt position
        //            msg.sender,
        //            address(this),
        //            collateralVault
        //        );
        // encumber vault with the proper lienPosition (needs a custom method on ERC721)
        COLLATERAL_VAULT.manageLien(
            collateralVault,
            bondVault,
            IERC721Wrapper.LienAction.ENCUMBER
        );
        WETH.transfer(msg.sender, amount); //TODO: transfer from the beacon proxy of the bond vault
        bondVaults[bondVault].loanCount++;
        emit NewLoan(bondVault, collateralVault, amount);
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
        require(
            WETH.transferFrom(msg.sender, address(this), amount),
            "lendToVault: transfer failed"
        );
        require(
            bondVaults[bondVault].appraiser != address(0),
            "lendToVault: vault doesn't exist"
        );
        require(
            bondVaults[bondVault].expiration != block.timestamp,
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
        require(
            WETH.transferFrom(msg.sender, address(this), amount),
            "repayLoan: transfer failed"
        );
        bondVaults[bondVault].loans[collateralVault][index].amount -= amount;
        bondVaults[bondVault].loans[collateralVault][index].start = block
            .timestamp;
        COLLATERAL_VAULT.manageLien(
            collateralVault,
            bondVault,
            IERC721Wrapper.LienAction.UN_ENCUMBER
        );
        if (bondVaults[bondVault].loans[collateralVault][index].amount == 0) {
            COLLATERAL_VAULT.safeTransferFrom(
                address(this),
                msg.sender,
                collateralVault,
                ""
            );
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
        uint256 delta_t = block.timestamp -
            bondVaults[bondVault].loans[collateralVault][index].start;
        uint256 interest = delta_t *
            bondVaults[bondVault].loans[collateralVault][index].interestRate *
            bondVaults[bondVault].loans[collateralVault][index].amount;
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
    ) external {
        require(
            canLiquidate(bondVault, index, collateralVault),
            "liquidate: borrow is healthy"
        );
        //        COLLATERAL_VAULT.auctionVault(bondVault, bondVaults[bondVault].loans[borrower][index].collateralVault);
        Loan[] storage loans = bondVaults[bondVault].loans[collateralVault];
        uint256 reserve;

        for (uint256 i = 0; i < loans.length; i++) {
            reserve += loans[i].amount;
            //            delete bondVaults[bondVault].loans[borrower][i];
        }
        delete bondVaults[bondVault].loans[collateralVault];

        reserve += ((reserve * LIQUIDATION_FEE) / 100);

        COLLATERAL_VAULT.auctionVault(bondVault, collateralVault, reserve);

        //        (address tokenContract, uint256 tokenId) = COLLATERAL_VAULT
        //        .getUnderlyingFromStar(loans[0].collateralVault);
        //        uint256 auctionId = AUCTION_HOUSE.createAuction(
        //            tokenId,
        //            tokenContract,
        //            AUCTION_DURATION,
        //            reserve,
        //            bondVault
        //        );
        //        collateralAuctions[bondVault] = auctionId;
    }

    // called by the collateral wrapper when the auction is complete
    //do we need index? since we have to liquidation everything from ground up
    function completeLiquidation(bytes32 bondVault, uint256 collateralVault)
        external
    {
        emit Liquidation(bondVault, collateralVault);
    }

    function redeemBond(bytes32 bondVault, uint256 amount) external {
        require(
            bondVaults[bondVault].maturity <= block.timestamp,
            "redeemBond: maturity not reached"
        );
        require(
            bondVaults[bondVault].loanCount == 0,
            "redeemBond: loans not returned"
        );
        require(balanceOf(msg.sender, uint256(bondVault)) >= amount);

        _burn(msg.sender, uint256(bondVault), amount);

        uint256 yield = (amount / bondVaults[bondVault].totalSupply) *
            bondVaults[bondVault].balance;

        WETH.transfer(msg.sender, yield);
        // need event
    }
}
