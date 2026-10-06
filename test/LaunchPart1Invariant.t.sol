// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {FrenArtChunk1, FrenArtChunk2} from "src/FrenArtChunks.sol";

/// @dev The specified STOP runtimes have no functions or storage. They can nevertheless receive ETH.
///      Track real transfers from a fixed, funded actor set; never use deal/etch/store on the chunks.
contract LaunchPart1Handler is Test {
    uint256 public constant INITIAL_FUNDS = 100 ether;
    address[2] public chunks;
    address[4] public actors;
    uint256[2] public received;
    uint256[4] public spent;

    constructor(address c1, address c2) {
        chunks = [c1, c2];
        for (uint256 i; i < actors.length; ++i) {
            actors[i] = address(uint160(0xA1100 + i));
            vm.deal(actors[i], INITIAL_FUNDS);
        }
    }

    function callChunk(uint8 chunkSeed, uint8 actorSeed, uint256 amountSeed, bytes calldata payload) external {
        uint256 c = bound(uint256(chunkSeed), 0, 1);
        uint256 a = bound(uint256(actorSeed), 0, 3);
        uint256 amount = bound(amountSeed, 0, actors[a].balance);
        _call(c, a, amount, payload, 100_000);
    }

    function sendEther(uint8 chunkSeed, uint8 actorSeed, uint256 amountSeed) external {
        uint256 c = bound(uint256(chunkSeed), 0, 1);
        uint256 a = bound(uint256(actorSeed), 0, 3);
        uint256 amount = bound(amountSeed, 0, actors[a].balance);
        _call(c, a, amount, "", 2_300);
    }

    function readChunk(uint8 chunkSeed, uint8 actorSeed, bytes calldata payload) external {
        address chunk = chunks[bound(uint256(chunkSeed), 0, 1)];
        address actor = actors[bound(uint256(actorSeed), 0, 3)];
        vm.record();
        vm.recordLogs();
        vm.prank(actor);
        (bool ok, bytes memory result) = chunk.staticcall{gas: 100_000}(payload);
        _assertNoExecutionEffects(chunk, ok, result);
    }

    function _call(uint256 c, uint256 a, uint256 amount, bytes memory payload, uint256 gasLimit) internal {
        address chunk = chunks[c];
        vm.record();
        vm.recordLogs();
        vm.prank(actors[a]);
        (bool ok, bytes memory result) = chunk.call{value: amount, gas: gasLimit}(payload);
        _assertNoExecutionEffects(chunk, ok, result);
        received[c] += amount;
        spent[a] += amount;
    }

    function _assertNoExecutionEffects(address chunk, bool ok, bytes memory result) internal {
        (bytes32[] memory reads, bytes32[] memory writes) = vm.accesses(chunk);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(ok, "STOP call failed");
        assertEq(result.length, 0, "art bytes were executed or returned");
        assertEq(reads.length, 0, "data contract read storage");
        assertEq(writes.length, 0, "data contract wrote storage");
        assertEq(logs.length, 0, "data contract emitted logs");
    }
}

/// @dev ETH accounting here describes unsolicited transfers, not a deposit/withdrawal API. The
///      specification requires inert STOP data: calls cannot spend balances or mutate the art.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract LaunchPart1InvariantTest is Test {
    address[2] private chunks;
    LaunchPart1Handler private handler;

    function setUp() public {
        chunks[0] = address(new FrenArtChunk1());
        chunks[1] = address(new FrenArtChunk2());
        handler = new LaunchPart1Handler(chunks[0], chunks[1]);
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = handler.callChunk.selector;
        selectors[1] = handler.sendEther.selector;
        selectors[2] = handler.readChunk.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_ArtRemainsExactlyThePinnedLaunch1Data() public view {
        assertEq(chunks[0].code.length, 24_001);
        assertEq(chunks[1].code.length, 24_139);
        assertEq(chunks[0].code[0], bytes1(0));
        assertEq(chunks[1].code[0], bytes1(0));
        assertEq(chunks[0].codehash, 0xf86a2decc7ef9279e69b3204890ef49c0099ea7a3b8b1a471019e23638fe2d4b);
        assertEq(chunks[1].codehash, 0x8579d215b59ec2dbbae55d5dd85ebf64a69e529049a26e66401679b8666c650e);
    }

    function invariant_EtherIsConservedAcrossActorsAndChunks() public view {
        uint256 total;
        uint256 totalSpent;
        for (uint256 i; i < 2; ++i) {
            assertEq(chunks[i].balance, handler.received(i), "chunk balance differs from transfers");
            total += chunks[i].balance;
        }
        for (uint256 i; i < 4; ++i) {
            address actor = handler.actors(i);
            assertEq(actor.balance + handler.spent(i), handler.INITIAL_FUNDS(), "actor gained or lost extra ETH");
            total += actor.balance;
            totalSpent += handler.spent(i);
        }
        assertEq(totalSpent, handler.received(0) + handler.received(1), "transfer accounting diverged");
        assertEq(total, 4 * handler.INITIAL_FUNDS(), "ETH was created or lost");
    }

    /// @dev Pin the empty/short/long calldata and zero/one/full-balance cases beside random sequences.
    function test_CallEdgesAndRepeatedCallsKeepArtAndBalances() public {
        for (uint8 i; i < 2; ++i) {
            handler.callChunk(i, i, 0, "");
            handler.callChunk(i, i, 1, hex"ff");
            handler.callChunk(i, i, 0, abi.encodeWithSignature("withdraw(uint256)", type(uint256).max));
            handler.callChunk(i, i, 0, abi.encodeWithSignature("withdraw(uint256)", type(uint256).max));
            handler.readChunk(i, i, hex"ffffffff");
            handler.readChunk(i, i, new bytes(4_096));
            handler.sendEther(i, i, handler.INITIAL_FUNDS() - 1);
            handler.sendEther(i, i, 0);
            assertEq(chunks[i].balance, handler.INITIAL_FUNDS());
            assertEq(handler.actors(i).balance, 0);
        }
        invariant_ArtRemainsExactlyThePinnedLaunch1Data();
        invariant_EtherIsConservedAcrossActorsAndChunks();
    }
}
