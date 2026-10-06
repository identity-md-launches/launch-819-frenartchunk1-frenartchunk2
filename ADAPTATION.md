# Launch adaptation

This assignment prepares part 1 only: `FrenArtChunk1`, then `FrenArtChunk2`, each with an empty argument list and zero deployment value. Their existing nonpayable constructors already work through the factory. Their source and runtime bytes are unchanged. No deployment was broadcast; the manifest belongs to the subsequent assignment.

The independently pinned runtime identities are:

| Contract | Runtime bytes | keccak256 |
| --- | ---: | --- |
| FrenArtChunk1 | 24,001 | `0xf86a2decc7ef9279e69b3204890ef49c0099ea7a3b8b1a471019e23638fe2d4b` |
| FrenArtChunk2 | 24,139 | `0x8579d215b59ec2dbbae55d5dd85ebf64a69e529049a26e66401679b8666c650e` |

## Changes and reproduced findings

- **Opcode-scan incompatibility, `4a2a7a94de12325b7e4cdd4588ac68a209bcf21225cf07872b3c352774985ca3`: reproduced and fixed.** The supplied proof failed on the original chunk 4 with 234 hits. Scanning the original runtime literals also found 14 hits in chunk 7, first at offsets 3,912 and 7,671 respectively. These are unreachable art bytes after STOP, but the supplied floor rejects them. To fix the requested audit finding without changing launch 1, `script/art/chunks.py` now preserves passing chunks and frames only failing chunks as groups of PUSHn plus up to 32 original bytes, still behind STOP. It checks every resulting runtime against the exact floor algorithm and EIP-170 before writing outputs, and asserts the original launch-1 hashes. Regeneration changes only chunks 4 and 7 in `src/FrenArtChunks.sol`; chunks 1, 2, 3, 5 and 6 remain byte-identical. The new runtimes of chunks 4 and 7 are 21,181 and 8,930 bytes.
- **Corresponding reader/index changes:** `src/FrenArtIndex.sol` records the framing mask and updated sizes/hashes for chunks 4 and 7. Layer offsets, lengths, palette, tables and decoded art remain unchanged. `src/FrenRenderer.sol` removes framing while reading those two chunks, including reads across group boundaries. Its constructor still requires every exact code hash. These changes concern launches 2 and 3 solely to resolve the reproduced finding; part 1 still deploys only the original two contracts.
- **Gas-test undercount, `79add4f5888b357dbe1c62717de596ec51bae0183f320e53951ac41b2fe99592`: reproduced and fixed.** The original test logged 1,000,622 / 940,916 / 1,267,983 gas and passed on local Forge 1.8.3, despite launch 1 requiring 9,628,000 gas just for runtime deposit. A scratch probe also undercounted with `--isolate`. `test/FrenRenderer.t.sol` therefore replaces the unreliable measurements with explicit estimates: 200 gas per runtime byte, CREATE2 base and word charges, worst-case calldata, an additional 16 gas per initcode byte for these constructors' execution/memory, and 100,000 gas for factory/ABI overhead. Tests require deposit costs to be included and estimates to remain below 95% of 2^24; a negative regression case exceeds the cap through code deposit alone. These are conservative estimates for the reviewed constructors, not transaction receipts or proof of an unspecified factory's policy ceiling. The deployment service must still simulate its actual transaction.
- **Size-table comment, `525f61c1362fe47965c9e940c3d6ce4ebf6b7533640ad3820ada634fa903ee23`: reproduced and fixed.** Originally only the declaration referenced `CHUNK_SIZES`; the renderer validates hashes. The generator and generated index now describe sizes as informational. The new regression test verifies the table against deployed runtimes without adding redundant renderer checks.
- **Coverage note, `373136aad34df14ac284996c7ffd20860f30af7ff940ea942949fe6bfd014672`: not a defect.** Its launch-1 claims are confirmed by `test/LaunchPart1.t.sol`: factory-style CREATE2 deployment in order, no arguments, initcode limits, pinned runtime sizes/hashes, rejection of constructor ETH, and inert calls with no storage accesses. No ownership, token, initialization or application behavior change was necessary for these contracts. All actionable imported findings reproduced; none was dismissed as unreproducible.

## Supporting files and verification

- `script/art/chunks.py` is importable for tests and uses the already-required Foundry `cast keccak` instead of the unavailable, unvendored PyCryptodome import. No dependency or build configuration was changed or installed.
- `script/art/test_chunks.py` tests the exact PUSH-skipping scan, unchanged passing data, lossless framing for every final-group length, and size overflow rejection. Run with `python3 -B -m unittest discover -s script/art`.
- `test/FrenRenderer.t.sol` additionally checks all 69 decoded layers and the palette against the original export, every chunk's size/hash and floor scan, and the renderer's floor scan and size. Existing bitmap, metadata, invalid-art and read-cost tests remain in place.
- `README.md` documents the encoding, offline regeneration/tests and the distinction between gas estimates and actual deployment simulation.

Verification commands: `forge build`, `forge test -vv`, and the Python unittest command above. Regeneration was also checked for determinism and unchanged source for chunks 1, 2, 3, 5 and 6. No network, keys, RPC deployment, Slither or Mythril were used. The external frens contract and the deployment service's policy were outside this local verification.

Results: build passed; all 11 deliverable Solidity tests plus the two scratch reproduction tests passed; all four Python tests passed. The original opcode-scan proof now passes. Estimated launch totals are 11,646,976 / 10,863,832 / 14,986,176 gas. The part-1 constructor ABIs are nonpayable with no inputs, and their initcode sizes remain 27,586 / 29,281 bytes.
