pragma solidity ^0.8.17;
import {IERC1155} from "core/interfaces/IERC1155.sol";
import {IERC1155Receiver} from "core/interfaces/IERC1155Receiver.sol";
import {Auth, Authority} from "solmate/auth/Auth.sol";

contract ValidatorAsset is Auth, IERC1155 {
  address public validatorRecipient;

  constructor(Authority _AUTHORITY, address _RECIPIENT)
    Auth(msg.sender, _AUTHORITY)
  {
    validatorRecipient = _RECIPIENT;
  }

  function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
    return interfaceId == type(IERC1155).interfaceId;
  }

  function balanceOf(address account, uint256 id)
    external
    pure
    returns (uint256)
  {
    return type(uint256).max;
  }

  /**
   * @dev xref:ROOT:erc1155.adoc#batch-operations[Batched] version of {balanceOf}.
   *
   * Requirements:
   *
   * - `accounts` and `ids` must have the same length.
   */
  function balanceOfBatch(address[] calldata accounts, uint256[] calldata ids)
    external
    pure
    returns (uint256[] memory output)
  {
    output = new uint256[](accounts.length);
    for (uint256 i = 0; i < output.length; ++i) {
      output[i] = type(uint256).max;
    }
  }

  /**
   * @dev Grants or revokes permission to `operator` to transfer the caller's tokens, according to `approved`,
   *
   * Emits an {ApprovalForAll} event.
   *
   * Requirements:
   *
   * - `operator` cannot be the caller.
   */
  function setApprovalForAll(address operator, bool approved) external {}

  /**
   * @dev Returns true if `operator` is approved to transfer ``account``'s tokens.
   *
   * See {setApprovalForAll}.
   */
  function isApprovedForAll(address account, address operator)
    external
    pure
    returns (bool)
  {
    return true;
  }

  /**
   * @dev Transfers `amount` tokens of token type `id` from `from` to `to`.
   *
   * Emits a {TransferSingle} event.
   *
   * Requirements:
   *
   * - `to` cannot be the zero address.
   * - If the caller is not `from`, it must have been approved to spend ``from``'s tokens via {setApprovalForAll}.
   * - `from` must have a balance of tokens of type `id` of at least `amount`.
   * - If `to` refers to a smart contract, it must implement {IERC1155Receiver-onERC1155Received} and return the
   * acceptance magic value.
   */

  function safeTransferFrom(
    address tokenContract,
    address to,
    uint256 collateralId,
    uint256 amountMinusFees,
    bytes calldata data //empty from seaport
  ) public {
    require(to == address(validatorRecipient));
    IERC1155Receiver(to).onERC1155Received(
      msg.sender, //seaport
      tokenContract, //can be the tokenContract, WETH, DAI etc whatever
      collateralId, //collateralId token id
      amountMinusFees, //purchase price - fee's
      abi.encode("0x") //can be anything we want
    );
  }

  /**
   * @dev xref:ROOT:erc1155.adoc#batch-operations[Batched] version of {safeTransferFrom}.
   *
   * Emits a {TransferBatch} event.
   *
   * Requirements:
   *
   * - `ids` and `amounts` must have the same length.
   * - If `to` refers to a smart contract, it must implement {IERC1155Receiver-onERC1155BatchReceived} and return the
   * acceptance magic value.
   */
  function safeBatchTransferFrom(
    address from,
    address to,
    uint256[] calldata ids,
    uint256[] calldata amounts,
    bytes calldata data
  ) public {
    for (uint256 i = 0; i < ids.length; ++i) {
      safeTransferFrom(from, to, ids[i], amounts[i], data);
    }
  }
}
