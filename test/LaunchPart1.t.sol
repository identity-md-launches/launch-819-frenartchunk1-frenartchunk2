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
        assertEq(c1.codehash, 0xf86a2decc7ef9279e69b3204890ef49c0099ea7a3b8b1a471019e23638fe2d4b);
        assertEq(c2.codehash, 0x8579d215b59ec2dbbae55d5dd85ebf64a69e529049a26e66401679b8666c650e);
        _assertInert(c1);
        _assertInert(c2);
    }

    function test_ConstructorsRejectValue() public {
        Part1FactoryProbe factory = new Part1FactoryProbe();
        vm.deal(address(this), 2);
        assertEq(factory.deploy{value: 1}(type(FrenArtChunk1).creationCode, bytes32(uint256(1))), address(0));
        assertEq(factory.deploy{value: 1}(type(FrenArtChunk2).creationCode, bytes32(uint256(2))), address(0));
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
