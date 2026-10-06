// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {FrenArtChunk1, FrenArtChunk2} from "../src/FrenArtChunks.sol";

contract Part1FactoryProbe {
    function deploy(bytes memory init, bytes32 salt) external payable returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create2(callvalue(), add(init, 32), mload(init), salt)
        }
    }
}

contract LaunchPart1Test is Test {
    bytes32 constant HASH1 = 0xf86a2decc7ef9279e69b3204890ef49c0099ea7a3b8b1a471019e23638fe2d4b;
    bytes32 constant HASH2 = 0x8579d215b59ec2dbbae55d5dd85ebf64a69e529049a26e66401679b8666c650e;

    function test_FactoryDeploysExactChunksInOrderWithoutArguments() public {
        Part1FactoryProbe factory = new Part1FactoryProbe();
        bytes memory init1 = type(FrenArtChunk1).creationCode;
        bytes memory init2 = type(FrenArtChunk2).creationCode;
        assertLe(init1.length, 49_152);
        assertLe(init2.length, 49_152);
        address c1 = factory.deploy(init1, bytes32(uint256(1)));
        address c2 = factory.deploy(init2, bytes32(uint256(2)));
        assertEq(c1, _prediction(address(factory), init1, bytes32(uint256(1))));
        assertEq(c2, _prediction(address(factory), init2, bytes32(uint256(2))));
        assertEq(c1.code.length, 24_001);
        assertEq(c2.code.length, 24_139);
        // Pinned independently of the generated index: this launch must retain the original code.
        assertEq(c1.codehash, HASH1);
        assertEq(c2.codehash, HASH2);
        _assertInert(c1);
        _assertInert(c2);
    }

    function test_ConstructorsRejectValue() public {
        Part1FactoryProbe factory = new Part1FactoryProbe();
        vm.deal(address(this), 2);
        assertEq(factory.deploy{value: 1}(type(FrenArtChunk1).creationCode, bytes32(uint256(1))), address(0));
        assertEq(factory.deploy{value: 1}(type(FrenArtChunk2).creationCode, bytes32(uint256(2))), address(0));
    }

    /// @dev Both constructors are nonpayable for every nonzero endowment. A failed CREATE2 must not
    ///      occupy its predicted address or prevent retrying the same initcode and salt with zero ETH.
    /// forge-config: default.fuzz.runs = 256
    function testFuzz_ValueRejectionLeavesBothAddressesReusable(bytes32 salt, uint128 endowment) public {
        _assertValueRejectionAndRetry(salt, bound(uint256(endowment), 1, type(uint128).max));
    }

    function test_ValueRejectionEdgesLeaveBothAddressesReusable() public {
        _assertValueRejectionAndRetry(bytes32(0), 1);
        _assertValueRejectionAndRetry(bytes32(type(uint256).max), type(uint128).max);
    }

    function _assertValueRejectionAndRetry(bytes32 salt, uint256 endowment) internal {
        Part1FactoryProbe factory = new Part1FactoryProbe();
        vm.deal(address(this), endowment * 2);
        for (uint256 i; i < 2; ++i) {
            bytes memory init = i == 0 ? type(FrenArtChunk1).creationCode : type(FrenArtChunk2).creationCode;
            address predicted = _prediction(address(factory), init, salt);
            assertEq(factory.deploy{value: endowment}(init, salt), address(0), "nonpayable constructor accepted ETH");
            assertEq(predicted.code.length, 0, "failed deployment left code");
            assertEq(predicted.balance, 0, "failed deployment kept endowment");
            assertEq(vm.getNonce(predicted), 0, "failed deployment occupied address");
            // The probe deliberately returns CREATE2's failure status: the refunded endowment stays there.
            assertEq(address(factory).balance, endowment * (i + 1));
            address deployed = factory.deploy(init, salt);
            assertEq(deployed, predicted, "zero-value retry failed");
            assertEq(deployed.codehash, i == 0 ? HASH1 : HASH2, "retry changed art");
        }
    }

    function test_Create2CollisionCannotOverwriteEitherChunk() public {
        Part1FactoryProbe factory = new Part1FactoryProbe();
        bytes32 salt = bytes32(uint256(42));
        uint256 deploymentGas = 6_000_000;
        address c1 = factory.deploy{gas: deploymentGas}(type(FrenArtChunk1).creationCode, salt);
        address c2 = factory.deploy{gas: deploymentGas}(type(FrenArtChunk2).creationCode, salt);
        assertEq(c1.codehash, HASH1, "gas allowance must suffice for a fresh deployment");
        assertEq(c2.codehash, HASH2, "gas allowance must suffice for a fresh deployment");
        assertTrue(c1 != c2, "different initcode must have different CREATE2 addresses");
        vm.deal(address(this), 2);
        for (uint256 i; i < 2; ++i) {
            address chunk = i == 0 ? c1 : c2;
            (bool funded,) = chunk.call{value: 1}("");
            assertTrue(funded);
            bytes memory init = i == 0 ? type(FrenArtChunk1).creationCode : type(FrenArtChunk2).creationCode;
            // Reuse the successful deployment's gas allowance so failure cannot be insufficient gas.
            assertEq(factory.deploy{gas: deploymentGas}(init, salt), address(0), "collision unexpectedly deployed");
            assertEq(chunk.codehash, i == 0 ? HASH1 : HASH2, "collision altered original art");
            assertEq(chunk.balance, 1, "collision altered original balance");
        }
    }

    function test_PreFundedCreate2AddressesStillDeployWithZeroEndowment() public {
        Part1FactoryProbe factory = new Part1FactoryProbe();
        bytes32 salt = bytes32(0);
        vm.deal(address(this), 2);
        for (uint256 i; i < 2; ++i) {
            bytes memory init = i == 0 ? type(FrenArtChunk1).creationCode : type(FrenArtChunk2).creationCode;
            address predicted = _prediction(address(factory), init, salt);
            (bool funded,) = predicted.call{value: 1}("");
            assertTrue(funded);
            assertEq(predicted.code.length, 0);
            assertEq(factory.deploy(init, salt), predicted, "prefunding blocked zero-value constructor");
            assertEq(predicted.codehash, i == 0 ? HASH1 : HASH2);
            assertEq(predicted.balance, 1);
        }
    }

    function _prediction(address factory, bytes memory init, bytes32 salt) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), factory, salt, keccak256(init))))));
    }

    function _assertInert(address chunk) internal {
        assertEq(chunk.code[0], bytes1(0));
        bytes32 hash = chunk.codehash;
        vm.record();
        (bool ok, bytes memory result) = chunk.call(hex"deadbeef");
        (bytes32[] memory reads, bytes32[] memory writes) = vm.accesses(chunk);
        assertTrue(ok);
        assertEq(result.length, 0);
        assertEq(reads.length, 0);
        assertEq(writes.length, 0);
        assertEq(chunk.codehash, hash);
    }
}
