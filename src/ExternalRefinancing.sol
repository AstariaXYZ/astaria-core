// SPDX-License-Identifier: BUSL-1.1

/**
 *  █████╗ ███████╗████████╗ █████╗ ██████╗ ██╗ █████╗
 * ██╔══██╗██╔════╝╚══██╔══╝██╔══██╗██╔══██╗██║██╔══██╗
 * ███████║███████╗   ██║   ███████║██████╔╝██║███████║
 * ██╔══██║╚════██║   ██║   ██╔══██║██╔══██╗██║██╔══██║
 * ██║  ██║███████║   ██║   ██║  ██║██║  ██║██║██║  ██║
 * ╚═╝  ╚═╝╚══════╝   ╚═╝   ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝╚═╝  ╚═╝
 *
 * Astaria Labs, Inc
 */

pragma solidity =0.8.17;

import "forge-std/Test.sol";

import {Authority} from "solmate/auth/Auth.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {MockERC721} from "solmate/test/utils/mocks/MockERC721.sol";
import {
  MultiRolesAuthority
} from "solmate/auth/authorities/MultiRolesAuthority.sol";

import {ERC721} from "gpl/ERC721.sol";
import {SafeCastLib} from "gpl/utils/SafeCastLib.sol";

import {IFlashLoanRecipient} from "core/interfaces/IFlashLoanRecipient.sol";
import {IERC20} from "core/interfaces/IERC20.sol";
import {IBalancerVault} from "core/interfaces/IBalancerVault.sol";
import {IERC721Enumerable} from "core/interfaces/IERC721Enumerable.sol";
import {IWETH9} from "gpl/interfaces/IWETH9.sol";

import {
  LendPoolAddressesProvider
} from "bend-protocol/protocol/LendPoolAddressesProvider.sol";
import {LendPool} from "bend-protocol/protocol/LendPool.sol";
import {WETHGateway} from "bend-protocol/protocol/WETHGateway.sol";
import {PunkGateway} from "bend-protocol/protocol/PunkGateway.sol";
import {BNFTRegistry} from "bend-protocol/mock/BNFT/BNFTRegistry.sol";
import {
  BendProtocolDataProvider
} from "bend-protocol/misc/BendProtocolDataProvider.sol";

import {IAstariaRouter, AstariaRouter} from "core/AstariaRouter.sol";
import {VaultImplementation} from "core/VaultImplementation.sol";
import {PublicVault} from "core/PublicVault.sol";
import {TransferProxy} from "core/TransferProxy.sol";
import {WithdrawProxy} from "core/WithdrawProxy.sol";

import {Strings2} from "./test/utils/Strings2.sol";

import "./test/TestHelpers.t.sol";

contract ExternalRefinancing is IFlashLoanRecipient {
  AstariaRouter ASTARIA_ROUTER;
  address public BEND_ADDRESSES_PROVIDER;
  address public BEND_DATA_PROVIDER;
  address payable public BEND_PUNK_GATEWAY;
  address payable public BEND_WETH_GATEWAY;

  address public BALANCER_VAULT;
  address public WETH;

  address public COLLATERAL_TOKEN;
  event BendRefinance(uint256 lienId);

  constructor(
    address router,
    address bendAddressesProvider,
    address bendDataProvider,
    address payable bendPunkGateway,
    address balancerVault,
    address weth,
    address payable bendWethGateway,
    address collateralToken
  ) {
    ASTARIA_ROUTER = AstariaRouter(router);
    BEND_ADDRESSES_PROVIDER = bendAddressesProvider;
    BEND_DATA_PROVIDER = bendDataProvider;
    BEND_PUNK_GATEWAY = bendPunkGateway;
    BALANCER_VAULT = balancerVault;
    WETH = weth;
    BEND_WETH_GATEWAY = bendWethGateway;
    COLLATERAL_TOKEN = collateralToken;
  }

  struct BendLoanData {
    address bnftAddress;
    uint256 tokenId; // or have an array of tokenIds for each unique bNft collection?
  }

  function getBendUserLoanData(
    address borrower
  ) public view returns (BendLoanData[] memory) {
    BendProtocolDataProvider.NftTokenData[]
      memory data = BendProtocolDataProvider(BEND_DATA_PROVIDER)
        .getAllNftsTokenDatas();

    uint256 totalOwnedNFTs = 0;
    for (uint256 i = 0; i < data.length; i++) {
      address bnftAddress = data[i].bNftAddress;
      totalOwnedNFTs += ERC721(bnftAddress).balanceOf(borrower);
    }

    BendLoanData[] memory tempBalancesArray = new BendLoanData[](
      totalOwnedNFTs
    );
    uint256 count = 0;

    for (uint256 i = 0; i < data.length; i++) {
      address bnftAddress = data[i].bNftAddress;
      uint256 numBnfts = ERC721(bnftAddress).balanceOf(borrower);

      for (uint256 j = 0; j < numBnfts; j++) {
        uint256 tokenId = IERC721Enumerable(bnftAddress).tokenOfOwnerByIndex(
          borrower,
          j
        );
        tempBalancesArray[count] = BendLoanData(bnftAddress, tokenId);
        count++;
      }
    }

    BendLoanData[] memory balancesArray = new BendLoanData[](count);
    for (uint256 i = 0; i < count; i++) {
      balancesArray[i] = tempBalancesArray[i];
    }

    return balancesArray;
  }

  function _decodeData(
    bytes memory data
  )
    internal
    pure
    returns (
      address borrower,
      address tokenAddress,
      uint256 tokenId,
      uint256 debt,
      IAstariaRouter.Commitment memory commitment
    )
  {
    (borrower, tokenAddress, tokenId, debt, commitment) = _decodeCommitment(
      data
    );
  }

  function _decodeCommitment(
    bytes memory data
  )
    internal
    pure
    returns (
      address borrower,
      address tokenAddress,
      uint256 tokenId,
      uint256 debt,
      IAstariaRouter.Commitment memory commitment
    )
  {
    bytes memory encodedCommitment;
    (borrower, tokenAddress, tokenId, debt, encodedCommitment) = abi.decode(
      data,
      (address, address, uint256, uint256, bytes)
    );

    (
      address commitmentTokenContract,
      uint256 commitmentTokenId,
      bytes memory encodedStrategy,
      bytes memory nlrDetails,
      bytes32 root,
      bytes32[] memory proof,
      uint256 amount,
      uint8 v,
      bytes32 r,
      bytes32 s
    ) = abi.decode(
        encodedCommitment,
        (
          address,
          uint256,
          bytes,
          bytes,
          bytes32,
          bytes32[],
          uint256,
          uint8,
          bytes32,
          bytes32
        )
      );

    IAstariaRouter.NewLienRequest memory lienRequest = _constructLienRequest(
      encodedStrategy,
      nlrDetails,
      root,
      proof,
      amount,
      v,
      r,
      s
    );
    commitment = IAstariaRouter.Commitment(
      commitmentTokenContract,
      commitmentTokenId,
      lienRequest
    );
  }

  function _constructLienRequest(
    bytes memory encodedStrategy,
    bytes memory nlrDetails,
    bytes32 root,
    bytes32[] memory proof,
    uint256 amount,
    uint8 v,
    bytes32 r,
    bytes32 s
  ) internal pure returns (IAstariaRouter.NewLienRequest memory lienRequest) {
    (uint8 version, uint256 deadline, address payable vault) = abi.decode(
      encodedStrategy,
      (uint8, uint256, address)
    );

    IAstariaRouter.StrategyDetailsParam memory strategy = IAstariaRouter
      .StrategyDetailsParam(version, deadline, vault);
    lienRequest = IAstariaRouter.NewLienRequest(
      strategy,
      nlrDetails,
      root,
      proof,
      amount,
      v,
      r,
      s
    );
  }

  function receiveFlashLoan(
    IERC20[] memory tokens,
    uint256[] memory amounts,
    uint256[] memory feeAmounts,
    bytes memory userData
  ) external override {
    (
      address borrower,
      address tokenAddress,
      uint256 tokenId,
      uint256 debt,
      IAstariaRouter.Commitment memory commitment
    ) = _decodeData(userData);

    uint256[] memory ids = new uint256[](1);
    ids[0] = tokenId;
    uint256[] memory amounts = new uint256[](1);
    amounts[0] = debt;

    require(
      IERC20(WETH).balanceOf(address(this)) >= debt,
      "ExternalRefinancing: not enough WETH"
    );
    if (tokenAddress != address(0)) {
      address[] memory nfts = new address[](1);
      nfts[0] = tokenAddress;

      address pool = LendPoolAddressesProvider(BEND_ADDRESSES_PROVIDER)
        .getLendPool();

      //            LendPool(pool).batchRepay(nfts, ids, amounts);
      IWETH9(WETH).withdraw(debt);
      WETHGateway(payable(BEND_WETH_GATEWAY)).batchRepayETH{value: debt}(
        nfts,
        ids,
        amounts
      );
      require(
        ERC721(tokenAddress).ownerOf(tokenId) == borrower,
        "Loan unsuccessfully repaid"
      );
    } else {
      PunkGateway(payable(BEND_PUNK_GATEWAY)).batchRepayETH{value: debt}(
        ids,
        amounts
      );
    }

    ERC721(tokenAddress).transferFrom(borrower, address(this), tokenId);
    ERC721(tokenAddress).setApprovalForAll(address(ASTARIA_ROUTER), true);
    (uint256 lienId, ILienToken.Stack memory stack) = ASTARIA_ROUTER
      .commitToLien(commitment);
    emit BendRefinance(lienId);
    ERC721(COLLATERAL_TOKEN).transferFrom(
      address(this),
      borrower,
      stack.lien.collateralId
    );

    require(
      ERC721(COLLATERAL_TOKEN).ownerOf(stack.lien.collateralId) == borrower,
      "CollateralToken not returned to borrower"
    );
    IWETH9(WETH).deposit{value: debt}();

    IERC20(WETH).transfer(BALANCER_VAULT, debt);
  }

  function refinance(
    address borrower,
    address tokenAddress, // use 0 address for punks
    uint256 tokenId,
    uint256 debt,
    IAstariaRouter.Commitment calldata commitment
  ) external {
    IERC20[] memory tokens = new IERC20[](1);
    tokens[0] = IERC20(WETH);
    uint256[] memory amounts = new uint256[](1);
    amounts[0] = debt;
    IBalancerVault(BALANCER_VAULT).flashLoan(
      IFlashLoanRecipient(address(this)),
      tokens,
      amounts,
      abi.encode(
        borrower,
        tokenAddress,
        tokenId,
        debt,
        _encodeCommitment(commitment)
      )
    );
  }

  function _encodeCommitment(
    IAstariaRouter.Commitment calldata commitment
  ) internal pure returns (bytes memory) {
    return
      abi.encode(
        commitment.tokenContract,
        commitment.tokenId,
        abi.encode(
          commitment.lienRequest.strategy.version,
          commitment.lienRequest.strategy.deadline,
          commitment.lienRequest.strategy.vault
        ),
        commitment.lienRequest.nlrDetails,
        commitment.lienRequest.root,
        commitment.lienRequest.proof,
        commitment.lienRequest.amount,
        commitment.lienRequest.v,
        commitment.lienRequest.r,
        commitment.lienRequest.s
      );
  }

  receive() external payable {}

  function _isInArray(
    address[] memory array,
    address addrToCheck
  ) internal view returns (bool) {
    for (uint256 i = 0; i < array.length; i++) {
      if (array[i] == addrToCheck) {
        return true;
      }
    }
    return false;
  }
}
