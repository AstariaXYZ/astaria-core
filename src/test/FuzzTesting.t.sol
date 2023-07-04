// SPDX-License-Identifier: MIT
import "./TestHelpers.t.sol";
import "./utils/SigUtils.sol";
import {Bound} from "./utils/Bound.sol";
import "murky/Merkle.sol";
import {IERC4626 as ERC4626} from "src/interfaces/IERC4626.sol";
import {ERC721TokenReceiver} from "solmate/tokens/ERC721.sol";

//import {CollateralLookup} from "src/libraries/CollateralLookup.sol";

contract AstariaFuzzTest is TestHelpers, SigUtils, Bound {
  PublicVault public vault;
  bytes32 constant NEW_LIEN_SIG =
    0xd03fcb98c0b64b239ccfeed4d62fcf721b2cf2c8ded60319cd2230f80dd2536c;

  function setUp() public override {
    super.setUp();

    vm.warp(100_000);

    vm.startPrank(strategistOne);
    vault = PublicVault(
      payable(
        ASTARIA_ROUTER.newPublicVault(
          14 days,
          strategistTwo,
          address(WETH9),
          0,
          false,
          new address[](0),
          uint256(0)
        )
      )
    );
    vm.stopPrank();

    vm.label(address(vault), "PublicVault");
    vm.label(address(TRANSFER_PROXY), "TransferProxy");
  }

  function onERC721Received(
    address operator, // operator_
    address from, // from_
    uint256 tokenId, // tokenId_
    bytes calldata data // data_
  ) public virtual override returns (bytes4) {
    return ERC721TokenReceiver.onERC721Received.selector;
  }

  struct FuzzCommit {
    address borrower;
    address lender;
    uint256 amount;
    uint40 duration;
    uint40 strategyDuration;
    FuzzTerm[] terms;
    uint256 termIndex;
  }

  struct FuzzTerm {
    uint256 tokenId;
    uint256 maxAmount;
    uint256 rate;
    uint256 liquidationInitialAsk;
    address borrower;
    uint40 duration;
    bool isBorrowerSpecific;
    bool isUnique;
  }

  struct LoanAssertions {
    uint256 borrowerBalance;
    uint256 vaultBalance;
    uint256 slope;
    uint256 liensOpen;
    uint256 shares;
  }

  function boundFuzzTerm(
    FuzzTerm memory term
  ) internal view returns (FuzzTerm memory) {
    term.tokenId = _boundNonZero(term.tokenId);

    if (term.isBorrowerSpecific) {
      term.borrower = _toAddress(_boundMin(_toUint(term.borrower), 100));
    } else {
      term.borrower = address(0);
    }

    //term.duration  = 3 days;
    term.duration = uint40(_bound(term.duration, 1 hours, 365 days));
    term.maxAmount = _boundMin(term.maxAmount, vault.minDepositAmount() + 1);
    term.rate = _bound(term.rate, 1, ((uint256(1e16) * 200) / (365 days)));
    //TODO: bound lia
    term.liquidationInitialAsk = type(uint256).max;

    return term;
  }

  function willArithmeticOverflow(
    FuzzCommit memory commit,
    FuzzTerm memory term
  ) internal pure returns (bool) {
    // mulDivWad requirements
    unchecked {
      //calculateSlope
      if (term.rate > type(uint256).max / commit.amount) {
        return true;
      }

      //getOwed()
      if (
        term.duration > type(uint256).max / term.rate ||
        term.duration * term.rate > type(uint256).max / commit.amount
      ) {
        return true;
      }
    }

    return false;
  }

  function testFuzzCommitToLien(FuzzCommit memory params) public {
    vm.assume(params.terms.length > 1);

    //BOUND PARAMS
    params.termIndex = _bound(
      params.termIndex,
      0,
      params.terms.length > 100_000 ? 99_999 : params.terms.length - 1
    );

    params.terms[params.termIndex] = boundFuzzTerm(
      params.terms[params.termIndex]
    );

    params.strategyDuration = uint40(
      _boundNonZero(uint256(params.strategyDuration))
    );

    FuzzTerm memory term = params.terms[params.termIndex];
    params.amount = _bound(params.amount, 1, term.maxAmount);

    if (term.isBorrowerSpecific) {
      params.borrower = term.borrower;
    } else {
      params.borrower = _toAddress(_boundMin(_toUint(params.borrower), 100));
    }

    vm.assume(params.borrower != COLLATERAL_TOKEN.getConduit());
    vm.assume(!willArithmeticOverflow(params, term));

    //BORROWER MINT & APPROVE NFT
    vm.startPrank(params.borrower);

    TestNFT tokenContract = new TestNFT(0);
    tokenContract.mint(address(params.borrower), term.tokenId);

    tokenContract.approve(address(ASTARIA_ROUTER), term.tokenId);

    vm.stopPrank();

    //LEND
    vm.deal(address(params.lender), term.maxAmount);

    vm.startPrank(address(params.lender));

    WETH9.deposit{value: term.maxAmount}();
    WETH9.approve(address(ASTARIA_ROUTER), term.maxAmount);
    WETH9.approve(address(TRANSFER_PROXY), term.maxAmount);

    ASTARIA_ROUTER.depositToVault(
      ERC4626(address(vault)),
      address(params.lender),
      term.maxAmount,
      0
    );

    vm.stopPrank();
    LoanAssertions memory before;
    ILienToken.Stack memory stack;

    {
      //GET STRATEGY DETAILS
      IAstariaRouter.StrategyDetailsParam
        memory strategyDetails = IAstariaRouter.StrategyDetailsParam({
          version: uint8(0),
          deadline: block.timestamp + params.strategyDuration,
          vault: payable(address(vault))
        });

      //MERKLEIZE
      bytes32[] memory data = new bytes32[](
        params.terms.length > 100_000 ? 100_000 : params.terms.length
      );

      bytes memory nlrDetails;
      for (uint256 i = 0; i < data.length; i++) {
        //TODO: include other validators
        IUniqueValidator.Details memory validatorDetails = IUniqueValidator
          .Details({
            version: uint8(1),
            token: address(tokenContract),
            tokenId: params.terms[i].tokenId,
            borrower: params.terms[i].borrower,
            lien: ILienToken.Details({
              maxAmount: params.terms[i].maxAmount,
              rate: params.terms[i].rate,
              duration: params.terms[i].duration,
              maxPotentialDebt: 0,
              liquidationInitialAsk: params.terms[i].liquidationInitialAsk
            })
          });
        if (i == params.termIndex) {
          nlrDetails = abi.encode(validatorDetails);
        }

        data[i] = keccak256(abi.encode(validatorDetails));
      }

      Merkle m = new Merkle();
      //bytes32 root = m.getRoot(data);
      bytes32 strategyHash = getTypedDataHash(
        vault.domainSeparator(),
        EIP712Message({
          nonce: vault.getStrategistNonce(),
          root: m.getRoot(data),
          deadline: block.timestamp + params.strategyDuration
        })
      );

      IAstariaRouter.NewLienRequest memory lienRequest = IAstariaRouter
        .NewLienRequest({
          strategy: strategyDetails,
          nlrDetails: nlrDetails,
          root: m.getRoot(data),
          proof: m.getProof(data, params.termIndex),
          amount: params.amount,
          v: 0,
          r: 0,
          s: 0
        });

      (lienRequest.v, lienRequest.r, lienRequest.s) = vm.sign(
        strategistOnePK,
        strategyHash
      );

      before = LoanAssertions({
        borrowerBalance: params.borrower.balance,
        vaultBalance: WETH9.balanceOf(address(vault)),
        slope: vault.getSlope(),
        liensOpen: 0,
        shares: 0
      });

      (before.liensOpen, ) = vault.getEpochData(
        vault.getLienEpoch(uint64(block.timestamp + term.duration))
      );
      (, , , , , , before.shares) = vault.getPublicVaultState();

      vm.prank(params.borrower);
      (, stack) = ASTARIA_ROUTER.commitToLien(
        IAstariaRouter.Commitment({
          tokenContract: address(tokenContract),
          tokenId: term.tokenId,
          lienRequest: lienRequest
        })
      );
    }

    assertEq(tokenContract.ownerOf(term.tokenId), address(COLLATERAL_TOKEN));

    assertEq(params.borrower.balance, before.borrowerBalance + params.amount);

    assertEq(
      WETH9.balanceOf(address(vault)),
      before.vaultBalance - params.amount,
      "vault balance did not decrease as expected"
    );

    assertEq(
      vault.getSlope(),
      before.slope + LIEN_TOKEN.calculateSlope(stack),
      "slope did not increase as expected"
    );

    (uint256 liensAfter, ) = vault.getEpochData(
      vault.getLienEpoch(stack.point.end)
    );

    assertEq(liensAfter, before.liensOpen + 1, "no lien opened for epoch");

    assertEq(
      COLLATERAL_TOKEN.ownerOf(
        CollateralLookup.computeId(address(tokenContract), term.tokenId)
      ),
      params.borrower,
      "CT not transferred"
    );

    assertEq(
      LIEN_TOKEN.ownerOf(uint256(keccak256(abi.encode(stack)))),
      vault.recipient(),
      "LT not issued"
    );
  }
}
//Test invalid conditions
