pragma solidity =0.8.17;

import "forge-std/Test.sol";
import "src/test/TestHelpers.t.sol";

interface IBeacon {
  /**
   * @dev Must return an address that can be used as a delegate call target.
   *
   * {BeaconProxy} will check that this address is a contract.
   */
  function getImpl(uint8) external view returns (address);
}

contract FakeBeacon is IBeacon {
  function getImpl(uint8) external view returns (address) {
    console.log("!getImpl!");
    return address(this);
  }

  function selfdes() public {
    console.log("!selfdes!");
    console.log("this?", address(this));
    selfdestruct(payable(msg.sender));
    console.log("self destructed .... ?");
  }
}

contract TestMeteor is TestHelpers {
  uint256 mainnetFork;

  address victim;
  IBeacon beacon;

  function setUp() public override(TestHelpers) {
    mainnetFork = vm.createFork(
      "https://eth-mainnet.g.alchemy.com/v2/8Y3jfuGSi2hhlsYLt6BqQRBcsfiDMGvU"
    );
    vm.selectFork(mainnetFork);

    super.setUp();
    victim = address(BEACON_PROXY);
    beacon = new FakeBeacon();
    vm.makePersistent(address(beacon));
  }

  function testCannotMeteorBeaconProxy() public {
    if (isContract(victim)) console.log("Victim is contract");
    else console.log("Victim is not contract");

    bytes memory cd = abi.encodeWithSignature("selfdes()");
    bytes memory cda = abi.encodePacked(cd, beacon, uint8(0), uint16(21));

    vm.expectRevert(abi.encodeWithSelector(BeaconProxy.InvalidSender.selector));
    address(victim).call{gas: 1000000, value: 1000}(cda);
    if (isContract(victim)) console.log("Victim is contract");
    else console.log("Victim is not contract");
    vm.expectRevert(abi.encodeWithSelector(BeaconProxy.InvalidSender.selector));
    address(victim).call{gas: 1000000}(cda);
    if (isContract(victim)) console.log("Victim is contract");
    else console.log("Victim is not contract");
  }

  function isContract(address _addr) private returns (bool isContract) {
    uint32 size;
    assembly {
      size := extcodesize(_addr)
    }
    return (size > 0);
  }
}
