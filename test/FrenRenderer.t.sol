// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {FrenRenderer} from "../src/FrenRenderer.sol";
import {FrenArtIndex} from "../src/FrenArtIndex.sol";
import {
    FrenArtChunk1,
    FrenArtChunk2,
    FrenArtChunk3,
    FrenArtChunk4,
    FrenArtChunk5,
    FrenArtChunk6,
    FrenArtChunk7
} from "../src/FrenArtChunks.sol";
import {FrenArtRef, FrenRendererRef} from "./ref/FrenRendererRef.sol";

/// @dev What IMD's launch factory does with `evm_contracts`, three times: each launch's contracts in order, in one
///      transaction, constructors only. The third names the first two launches' chunks by address.
contract ImdStyleArtLaunches {
    function launch1() external returns (address c1, address c2) {
        c1 = address(new FrenArtChunk1());
        c2 = address(new FrenArtChunk2());
    }

    function launch2() external returns (address c3, address c4) {
        c3 = address(new FrenArtChunk3());
        c4 = address(new FrenArtChunk4());
    }

    function launch3(address c1, address c2, address c3, address c4)
        external
        returns (address c5, address c6, address c7, address r)
    {
        c5 = address(new FrenArtChunk5());
        c6 = address(new FrenArtChunk6());
        c7 = address(new FrenArtChunk7());
        r = address(new FrenRenderer(c1, c2, c3, c4, c5, c6, c7));
    }
}

contract FrenEntryProbe is FrenRenderer {
    constructor(address[7] memory cs) FrenRenderer(cs[0], cs[1], cs[2], cs[3], cs[4], cs[5], cs[6]) {}

    function entry(uint256 i) external view returns (bytes memory) {
        return _entry(i);
    }
}

/// @notice The chunk renderer, deployed as IMD would in three launches, draws exactly what the art kit's reference draws
///         and returns exactly the metadata of the renderer the frens launch with; it takes only this art.
contract FrenRendererTest is Test {
    string constant ART = "script/art/data/";
    uint256 constant TX_CAP = 1 << 24; // EIP-7825

    FrenRenderer r;
    FrenRendererRef ref;
    address[7] chunks;
    uint256[3] launchInitBytes;

    function setUp() public {
        ImdStyleArtLaunches f = new ImdStyleArtLaunches();
        (chunks[0], chunks[1]) = f.launch1();
        (chunks[2], chunks[3]) = f.launch2();
        address rr;
        (chunks[4], chunks[5], chunks[6], rr) = f.launch3(chunks[0], chunks[1], chunks[2], chunks[3]);
        r = FrenRenderer(rr);
        launchInitBytes[0] = type(FrenArtChunk1).creationCode.length + type(FrenArtChunk2).creationCode.length;
        launchInitBytes[1] = type(FrenArtChunk3).creationCode.length + type(FrenArtChunk4).creationCode.length;
        launchInitBytes[2] = type(FrenArtChunk5).creationCode.length + type(FrenArtChunk6).creationCode.length
            + type(FrenArtChunk7).creationCode.length + type(FrenRenderer).creationCode.length + 7 * 32;
        ref = _reference();
    }

    /// @dev The launch renderer, its art written as the frens' deploy script writes it
    function _reference() internal returns (FrenRendererRef) {
        FrenArtRef art = new FrenArtRef();
        string memory manifest = vm.readFile(string.concat(ART, "manifest.json"));
        string[] memory names = vm.parseJsonStringArray(manifest, ".layers");
        address[] memory ptrs = new address[](names.length);
        for (uint256 i; i < names.length; ++i) {
            bytes[] memory one = new bytes[](1);
            one[0] = vm.readFileBinary(string.concat(ART, "layers/", names[i], ".bin"));
            ptrs[i] = art.write(one)[0];
        }
        bytes[] memory pal = new bytes[](1);
        pal[0] = vm.readFileBinary(string.concat(ART, "palette.bin"));
        return new FrenRendererRef(
            art.write(pal)[0],
            ptrs,
            vm.readFileBinary(string.concat(ART, "tables.bin")),
            vm.readFileBinary(string.concat(ART, "facetable.bin")),
            uint8(vm.parseJsonUint(manifest, ".shadow"))
        );
    }

    /// @dev A random combo inside the art: every trait at one of its values
    function _combo(uint256 x) internal pure returns (uint24) {
        uint256[8] memory n = [uint256(3), 13, 4, 3, 6, 3, 10, 16];
        uint256[8] memory shift = [uint256(0), 2, 6, 8, 10, 13, 15, 19];
        uint256 c;
        for (uint256 t; t < 8; ++t) {
            c |= ((uint256(keccak256(abi.encode(x, t))) % n[t]) << shift[t]);
        }
        return uint24(c);
    }

    /* ── the art ─────────────────────────────────────────────────── */

    function test_MatchesTheReference() public view {
        string memory exp = vm.readFile(string.concat(ART, "expected.json"));
        uint256 i;
        for (; vm.keyExistsJson(exp, string.concat(".[", vm.toString(i), "]")); ++i) {
            string memory k = string.concat(".[", vm.toString(i), "]");
            uint24 combo = uint24(vm.parseJsonUint(exp, string.concat(k, ".combo")));
            uint256 seed = vm.parseUint(vm.parseJsonString(exp, string.concat(k, ".seed")));
            bytes32 want = vm.parseJsonBytes32(exp, string.concat(k, ".bmpSha256"));
            assertEq(sha256(r.bmp(combo, seed)), want, "the bitmap differs from the reference");
        }
        assertGe(i, 6);
    }

    /// @dev Byte for byte the launch renderer's tokenURI and pendingURI, over random frens and every background
    function test_SameAsTheLaunchRenderer() public view {
        for (uint256 i; i < 24; ++i) {
            uint24 combo = _combo(i);
            uint256 seed = uint256(keccak256(abi.encode("seed", i)));
            assertEq(
                keccak256(bytes(r.tokenURI(i + 1, combo, seed))),
                keccak256(bytes(ref.tokenURI(i + 1, combo, seed))),
                "tokenURI"
            );
        }
        for (uint256 bg; bg < 10; ++bg) {
            uint24 combo = uint24(_combo(100 + bg) & ~uint256(15 << 15) | bg << 15);
            assertEq(keccak256(r.canvas(combo, bg)), keccak256(ref.canvas(combo, bg)), "canvas");
        }
        for (uint256 id = 1; id < 2222; id += 317) {
            assertEq(keccak256(bytes(r.pendingURI(id))), keccak256(bytes(ref.pendingURI(id))), "pendingURI");
        }
        assertEq(r.attributes(_combo(7)), ref.attributes(_combo(7)));
    }

    function test_RejectsCombosOutsideTheArt() public {
        uint24[6] memory bad =
            [uint24(3), uint24(13 << 2), uint24(3 << 8), uint24(6 << 10), uint24(3 << 13), uint24(10 << 15)];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(); // Missing, or an out-of-range read of the index
            r.canvas(bad[i], 0);
        }
        r.canvas(uint24(2 | 12 << 2 | 3 << 6 | 2 << 8 | 5 << 10 | 2 << 13 | 9 << 15 | 15 << 19), 1); // every trait at its last value
    }

    function test_TokenURIIsCheapEnoughToRead() public {
        uint24 combo = uint24(1 | 3 << 2 | 1 << 6 | 2 << 8 | 2 << 10 | 5 << 15 | 13 << 19);
        uint256 g = gasleft();
        string memory uri = r.tokenURI(2222, combo, 424242);
        emit log_named_uint("tokenURI gas", g - gasleft());
        assertLt(g - gasleft(), 30_000_000);
        assertEq(bytes(uri)[0], "d");
    }

    /* ── the launches ────────────────────────────────────────────── */

    /// @dev Explicit estimate: gasleft() around CREATE omits creation costs in some Foundry builds.
    ///      These constructors only return constant data or validate seven hashes and set immutables.
    ///      Budget 16 gas per init byte for their execution/memory, in addition to calldata, code deposit,
    ///      CREATE2 (32,000 + 8 per init word), and 100,000 for factory/ABI overhead. This is not a receipt
    ///      or a guarantee about an unspecified factory's policy ceiling; the deployment service simulates it.
    function test_LaunchesFitTransactions() public {
        uint256[3] memory runtimeBytes = [
            chunks[0].code.length + chunks[1].code.length,
            chunks[2].code.length + chunks[3].code.length,
            chunks[4].code.length + chunks[5].code.length + chunks[6].code.length + address(r).code.length
        ];
        uint256[3] memory counts = [uint256(2), 2, 4];
        for (uint256 i; i < 3; ++i) {
            uint256 total = _launchGasEstimate(launchInitBytes[i], runtimeBytes[i], counts[i]);
            assertGe(total, 200 * runtimeBytes[i], "estimate omitted runtime code deposit");
            emit log_named_uint(string.concat("launch ", vm.toString(i + 1), " gas estimate (with calldata)"), total);
            assertLt(total, TX_CAP * 95 / 100);
        }
    }

    function _launchGasEstimate(uint256 initBytes, uint256 runtimeBytes, uint256 count)
        internal
        pure
        returns (uint256)
    {
        // Round each initcode length up conservatively before charging EIP-3860 and CREATE2 hashing.
        uint256 initWords = (initBytes + 31 * count) / 32;
        return 21_000 + 100_000 + 200 * runtimeBytes + 32_000 * count + 8 * initWords + 32 * initBytes;
    }

    function test_GasEstimateDetectsCodeDepositOverTransactionCap() public pure {
        // A regression to the former calldata-only estimate would accept this deployment.
        uint256 total = _launchGasEstimate(60_000, 84_000, 4);
        assertGt(total, TX_CAP);
    }

    function test_AllEntriesRetainOriginalBytes() public {
        FrenEntryProbe probe = new FrenEntryProbe(chunks);
        string[] memory names = vm.parseJsonStringArray(vm.readFile(string.concat(ART, "manifest.json")), ".layers");
        for (uint256 i; i < names.length; ++i) {
            assertEq(probe.entry(i), vm.readFileBinary(string.concat(ART, "layers/", names[i], ".bin")), names[i]);
        }
        assertEq(probe.entry(names.length), vm.readFileBinary(string.concat(ART, "palette.bin")), "palette");
    }

    function test_AllChunksPassFloorAndMatchIndex() public view {
        bytes memory sizes = FrenArtIndex.CHUNK_SIZES;
        bytes memory hashes = FrenArtIndex.CHUNK_HASHES;
        for (uint256 i; i < chunks.length; ++i) {
            bytes memory code = chunks[i].code;
            assertEq(code[0], bytes1(0));
            assertLe(code.length, 24_576);
            assertEq(code.length, uint256(uint8(sizes[2 * i])) * 256 + uint8(sizes[2 * i + 1]));
            bytes32 want;
            assembly ("memory-safe") {
                want := mload(add(add(hashes, 32), mul(i, 32)))
            }
            assertEq(chunks[i].codehash, want);
            _assertNoEscapeOpcodes(code);
        }
        _assertNoEscapeOpcodes(address(r).code);
        assertLe(address(r).code.length, 24_576);
    }

    function _assertNoEscapeOpcodes(bytes memory code) internal pure {
        // Exact scan used by Contracts.protected.t.sol, including data after STOP.
        for (uint256 j; j < code.length; ++j) {
            uint8 op = uint8(code[j]);
            if (op >= 0x60 && op <= 0x7f) {
                j += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden application opcode");
        }
    }

    /// @dev The renderer takes only these chunks, in this order
    function test_TakesOnlyThisArt() public {
        vm.expectRevert(FrenRenderer.BadArt.selector);
        new FrenRenderer(chunks[1], chunks[0], chunks[2], chunks[3], chunks[4], chunks[5], chunks[6]);
        vm.expectRevert(FrenRenderer.BadArt.selector);
        new FrenRenderer(chunks[0], chunks[1], chunks[2], chunks[3], chunks[4], chunks[5], address(0xBEEF));
        assertEq(r.chunk7(), chunks[6]);
    }
}
