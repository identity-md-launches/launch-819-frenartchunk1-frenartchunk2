// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {FrenArtIndex} from "./FrenArtIndex.sol";

/// @title FrenRenderer - draws an IMD6900 fren on chain
/// @notice The art lives in seven data contracts, FrenArtChunk1..7 (FrenArtIndex says what is where), each checked by
///         its code hash when this is deployed:
///  - a 256-colour palette;
///  - each character's 13 faces (each distinct face kept once; a table points each character's faces at them);
///  - 3 lab coats, one fitted to each character;
///  - 2 hats;
///  - 15 items, held in the right hand;
///  - 10 backgrounds.
///
///  A fren is drawn on an 84x84 canvas: its background through a window picked by its seed, then its face, coat, hat and
///  item. The lens, coat shades and shirt are palette slots filled from its combo. Out comes an 8-bit bitmap inside an
///  SVG, and metadata with its traits. Nothing here changes after deploy. The reference the tests check against byte for
///  byte is export_v2.py in the art kit; its output is `script/frens/art/`.
/// @dev Layer format: x0 y0 w h, then per row (count, index) runs over w pixels; index 0 is see-through.
///      A combo (24 bits): character 0-1 | face 2-5 | eye 6-7 | coat 8-9 | shirt 10-12 | hat 13-14 | background 15-18 |
///      item 19-22. Layers: the faces, then coat0..2, hat0..1, item0..14, bg0..9.
contract FrenRenderer {
    using Strings for uint256;

    uint256 internal constant N = 84; // the canvas
    uint256 internal constant CX = 18; // where the canvas sits in the layers' 120x120 space (3px right of centre: room for the held item)
    uint256 internal constant CY = 26;
    uint256 internal constant SLOT0 = 244; // 244..248 coat shades, 249 shirt, 250..251 lens
    uint256 internal constant FACES = 13; // per character
    uint256 internal constant REST = 30; // the layers after the faces: 3 coats, 2 hats, 15 items, 10 backgrounds

    uint256 internal constant PENDING_BG = 7; // an unrevealed fren is a silhouette in the terminal

    uint256 public constant faceLayers = FrenArtIndex.FACE_LAYERS;
    uint8 public constant shadow = FrenArtIndex.SHADOW; // the palette's dark lens green: an unrevealed fren's silhouette

    address public immutable chunk1;
    address public immutable chunk2;
    address public immutable chunk3;
    address public immutable chunk4;
    address public immutable chunk5;
    address public immutable chunk6;
    address public immutable chunk7;

    error Missing();
    error BadArt();

    /// @dev Static arguments only (IMD's launch): the seven FrenArtChunk contracts, in order. Each must hold exactly the
    ///      art FrenArtIndex was generated from (its code hash), so this can only ever draw this art.
    constructor(address c1, address c2, address c3, address c4, address c5, address c6, address c7) {
        address[7] memory cs = [c1, c2, c3, c4, c5, c6, c7];
        bytes memory hashes = FrenArtIndex.CHUNK_HASHES;
        for (uint256 k; k < 7; ++k) {
            bytes32 want;
            assembly ("memory-safe") {
                want := mload(add(add(hashes, 32), mul(k, 32)))
            }
            if (cs[k].codehash != want) revert BadArt();
        }
        (chunk1, chunk2, chunk3, chunk4, chunk5, chunk6, chunk7) = (c1, c2, c3, c4, c5, c6, c7);
    }

    /* ── metadata ─────────────────────────────────────────────────── */

    function tokenURI(uint256 tokenId, uint24 combo, uint256 seed) external view returns (string memory) {
        string memory image = _svg(bmp(combo, seed));
        string memory json = string.concat(
            '{"name":"IMD6900 Fren #',
            tokenId.toString(),
            '","description":"One of 2222 IMD6900 frens, built layer by layer by five agents in the IMD swarm and backed by a floor of IMD6900. Drawn on chain.","image":"',
            image,
            '","attributes":',
            attributes(combo),
            "}"
        );
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    /// @notice A fren minted but not revealed yet: its silhouette in the terminal, until the agents' job lands
    function pendingURI(uint256 tokenId) external view returns (string memory) {
        string memory json = string.concat(
            '{"name":"IMD6900 Fren #',
            tokenId.toString(),
            '","description":"Minted, not revealed yet: five agents in the IMD swarm are building this fren, and it reveals on chain when their job lands. Backed by the floor all along.","image":"',
            _svg(_bmp(silhouette(tokenId))),
            '","attributes":[{"trait_type":"Status","value":"Unrevealed"}]}'
        );
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    /// @notice An unrevealed fren's pixels: the classic pepe and its coat in one flat green, on the terminal background
    ///         through a window its token id picks
    function silhouette(uint256 tokenId) public view returns (bytes memory cv) {
        uint8[8] memory slot;
        uint256 seed = uint256(keccak256(abi.encode(tokenId)));
        uint256 f = faceLayers;
        cv = new bytes(N * N);
        _draw(cv, _entry(f + 20 + PENDING_BG), -int256(seed % 37), -int256((seed >> 8) % 37), slot, 0);
        _draw(cv, _entry(uint8(FrenArtIndex.FACE_TABLE[0])), -int256(CX), -int256(CY), slot, shadow);
        _draw(cv, _entry(f), -int256(CX), -int256(CY), slot, shadow);
    }

    function attributes(uint24 combo) public pure returns (string memory) {
        return string.concat(
            '[{"trait_type":"Character","value":"',
            _name(combo & 3, "Cyborg Pepe|Mumu|Bobo"),
            '"},{"trait_type":"Face","value":"',
            _name(
                (combo >> 2) & 15,
                "Classic|Happy|Angry|Feels Bad|Grinding|Chill|Grumpy|Giga Happy|Cooked|Comfy|Special|Scientist|Laser Eyes"
            ),
            '"},{"trait_type":"Eye","value":"',
            _name((combo >> 6) & 3, "Green|Red|Cyan|Gold"),
            '"},{"trait_type":"Coat","value":"',
            _name((combo >> 8) & 3, "White|Black|Gold"),
            '"},{"trait_type":"Shirt","value":"',
            _name((combo >> 10) & 7, "Blue|Red|Green|Black|Orange|Purple"),
            '"},{"trait_type":"Hat","value":"',
            _name((combo >> 13) & 3, "None|Mumu Hat|Bobo Hat"),
            string.concat(
                '"},{"trait_type":"Item","value":"',
                _name(
                    (combo >> 19) & 15,
                    "None|Flask|Ray Gun|Magnet|Magnifier|Dynamite|Extinguisher|Bomb|10 Paddle|0 Paddle|Drink|Wrench|Green Lightsaber|Red Lightsaber|Light Bulb|Bunsen Burner"
                ),
                '"},{"trait_type":"Background","value":"',
                _name(
                    (combo >> 15) & 15,
                    "Matrix Green|Matrix Red|Matrix Gold|Machine Wall|Machine Wall Dark|Machine Wall Lit|Machine Wall II|Terminal|Circuit Board|Lab Goo"
                ),
                '"}]'
            )
        );
    }

    /// @dev The i-th name of a |-separated list.
    function _name(uint256 i, string memory list) internal pure returns (string memory) {
        bytes memory b = bytes(list);
        uint256 start;
        uint256 k;
        for (uint256 j; j <= b.length; ++j) {
            if (j == b.length || b[j] == "|") {
                if (k == i) {
                    bytes memory out = new bytes(j - start);
                    for (uint256 m; m < out.length; ++m) {
                        out[m] = b[start + m];
                    }
                    return string(out);
                }
                ++k;
                start = j + 1;
            }
        }
        return "";
    }

    /* ── the bitmap ──────────────────────────────────────────────── */

    /// @dev A bitmap as the pixelated SVG data URI a token's image is.
    function _svg(bytes memory bitmap) internal pure returns (string memory) {
        return string.concat(
            "data:image/svg+xml;base64,",
            Base64.encode(
                bytes(
                    string.concat(
                        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 84 84" width="840" height="840">',
                        '<image width="84" height="84" style="image-rendering:pixelated" href="data:image/bmp;base64,',
                        Base64.encode(bitmap),
                        '"/></svg>'
                    )
                )
            )
        );
    }

    /// @notice The fren as an 84x84 8-bit bitmap (the palette's colours), rows bottom-up as BMP has them.
    function bmp(uint24 combo, uint256 seed) public view returns (bytes memory) {
        return _bmp(canvas(combo, seed));
    }

    function _bmp(bytes memory cv) internal view returns (bytes memory out) {
        bytes memory pal = _entry(FrenArtIndex.LAYERS); // the palette: the entry after the layers
        out = new bytes(54 + 1024 + N * N);
        // BITMAPFILEHEADER + BITMAPINFOHEADER, little endian
        _le(out, 0, 0x4d42, 2); // "BM"
        _le(out, 2, out.length, 4);
        _le(out, 10, 54 + 1024, 4);
        _le(out, 14, 40, 4);
        _le(out, 18, N, 4);
        _le(out, 22, N, 4);
        _le(out, 26, 1, 2);
        _le(out, 28, 8, 2);
        _le(out, 34, N * N, 4);
        _le(out, 46, 256, 4);
        for (uint256 i; i < 1024; ++i) {
            out[54 + i] = pal[i];
        }
        for (uint256 y; y < N; ++y) {
            uint256 src = (N - 1 - y) * N;
            uint256 dst = 54 + 1024 + y * N;
            for (uint256 x; x < N; ++x) {
                out[dst + x] = cv[src + x];
            }
        }
    }

    /// @notice The fren's pixels, palette indices, top row first.
    function canvas(uint24 combo, uint256 seed) public view returns (bytes memory cv) {
        uint256 ch = combo & 3;
        uint256 face = (combo >> 2) & 15;
        uint256 bg = (combo >> 15) & 15;
        if (ch > 2 || face >= FACES || bg >= 10) revert Missing();
        bytes memory t = FrenArtIndex.TABLES;
        // the slots: coat shades (5), shirt, lens (2)
        uint8[8] memory slot;
        uint256 coat = (combo >> 8) & 3;
        uint256 shirt = (combo >> 10) & 7;
        uint256 eye = (combo >> 6) & 3;
        if (coat > 2 || shirt > 5) revert Missing();
        for (uint256 i; i < 5; ++i) {
            slot[i] = uint8(t[8 + coat * 5 + i]);
        }
        slot[5] = uint8(t[23 + shirt]);
        slot[6] = uint8(t[eye * 2]);
        slot[7] = uint8(t[eye * 2 + 1]);

        uint256 f = faceLayers;
        cv = new bytes(N * N);
        _draw(cv, _entry(f + 20 + bg), -int256(seed % 37), -int256((seed >> 8) % 37), slot, 0);
        _draw(cv, _entry(uint8(FrenArtIndex.FACE_TABLE[ch * FACES + face])), -int256(CX), -int256(CY), slot, 0);
        _draw(cv, _entry(f + ch), -int256(CX), -int256(CY), slot, 0);
        uint256 hat = (combo >> 13) & 3;
        if (hat > 2) revert Missing();
        if (hat != 0) _draw(cv, _entry(f + 2 + hat), -int256(CX), -int256(CY), slot, 0);
        uint256 item = (combo >> 19) & 15;
        if (item != 0) _draw(cv, _entry(f + 4 + item), -int256(CX), -int256(CY), slot, 0);
    }

    /// @dev `mono`: when not 0, every pixel the layer covers takes that one colour (a silhouette)
    function _draw(bytes memory cv, bytes memory d, int256 dx, int256 dy, uint8[8] memory slot, uint8 mono)
        internal
        pure
    {
        uint256 x0 = uint8(d[0]);
        uint256 y0 = uint8(d[1]);
        uint256 w = uint8(d[2]);
        uint256 h = uint8(d[3]);
        uint256 i = 4;
        for (uint256 y = y0; y < y0 + h; ++y) {
            int256 yy = int256(y) + dy;
            bool row = yy >= 0 && yy < int256(N);
            for (uint256 x = x0; x < x0 + w;) {
                uint256 n = uint8(d[i]);
                uint256 c = uint8(d[i + 1]);
                i += 2;
                if (c != 0 && row) {
                    if (mono != 0) c = mono;
                    else if (c >= SLOT0 && c < SLOT0 + 8) c = slot[c - SLOT0];
                    int256 a = int256(x) + dx;
                    int256 b = a + int256(n);
                    if (a < 0) a = 0;
                    if (b > int256(N)) b = int256(N);
                    uint256 base = uint256(yy) * N;
                    for (int256 xx = a; xx < b; ++xx) {
                        cv[base + uint256(xx)] = bytes1(uint8(c));
                    }
                }
                x += n;
            }
        }
    }

    function _le(bytes memory b, uint256 at, uint256 v, uint256 n) internal pure {
        for (uint256 i; i < n; ++i) {
            b[at + i] = bytes1(uint8(v >> (8 * i)));
        }
    }

    /* ── reading the art back (see FrenArtIndex) ── */

    /// @dev Entry `i` (a layer, or the palette after them): its bytes, cut from its chunk's code
    function _entry(uint256 i) internal view returns (bytes memory data) {
        bytes memory ix = FrenArtIndex.INDEX;
        uint256 c;
        uint256 off;
        uint256 len;
        assembly ("memory-safe") {
            let w := mload(add(add(ix, 32), mul(i, 5)))
            c := byte(0, w)
            off := and(shr(232, w), 0xffff) // bytes 1-2
            len := and(shr(216, w), 0xffff) // bytes 3-4
        }
        address p = [chunk1, chunk2, chunk3, chunk4, chunk5, chunk6, chunk7][c];
        if (FrenArtIndex.PUSH_ENCODED & (1 << c) != 0) {
            // STOP, then groups of PUSHn + n original bytes (n = 32 except the last group).
            // INDEX offsets refer to decoded bytes, so reads may start or end inside a group.
            if (len != 0 && p.code.length < 2 + off + len + (off + len - 1) / 32) revert Missing();
            data = new bytes(len);
            uint256 written;
            while (written < len) {
                uint256 at = off + written;
                uint256 n = 32 - at % 32;
                if (n > len - written) n = len - written;
                uint256 source = 2 + at + at / 32;
                assembly ("memory-safe") {
                    extcodecopy(p, add(add(data, 32), written), source, n)
                }
                written += n;
            }
            return data;
        }
        if (p.code.length < 1 + off + len) revert Missing();
        data = new bytes(len);
        assembly ("memory-safe") {
            extcodecopy(p, add(data, 32), add(1, off), len)
        }
    }
}
