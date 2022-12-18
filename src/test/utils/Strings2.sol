pragma solidity =0.8.17;

library Strings2 {
  function toHexString(bytes memory input) public pure returns (string memory) {
    require(input.length < type(uint256).max / 2 - 1);
    bytes16 symbols = "0123456789abcdef";
    bytes memory hex_buffer = new bytes(2 * input.length + 2);
    hex_buffer[0] = "0";
    hex_buffer[1] = "x";

    uint256 pos = 2;
    uint256 length = input.length;
    for (uint256 i = 0; i < length; ++i) {
      uint256 _byte = uint8(input[i]);
      hex_buffer[pos++] = symbols[_byte >> 4];
      hex_buffer[pos++] = symbols[_byte & 0xf];
    }
    return string(hex_buffer);
  }
}
