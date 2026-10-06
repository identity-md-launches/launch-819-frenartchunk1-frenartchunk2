"""Offline generator regression tests: python3 -m unittest discover -s script/art."""
import unittest

from chunks import forbidden_offsets, prepare_chunk


class ChunkPackingTest(unittest.TestCase):
    def test_scanner_matches_floor(self):
        self.assertEqual(forbidden_offsets(bytes.fromhex("00f2f4ff")), [1, 2, 3])
        self.assertEqual(forbidden_offsets(bytes.fromhex("0062f2f4ffff")), [5])
        self.assertEqual(forbidden_offsets(bytes.fromhex("007fff")), [])
        self.assertEqual(forbidden_offsets(bytes.fromhex("005fff")), [2])

    def test_passing_chunks_are_unchanged(self):
        for art in (b"", bytes(range(0xf2)), bytes.fromhex("62f2f4ff")):
            self.assertEqual(prepare_chunk(art), (art, False))

    def test_encoded_chunks_round_trip_at_every_final_group_size(self):
        for remainder in range(32):
            art = b"\xff" + bytes(range(256)) * 3 + b"\xf4" * remainder
            stored, encoded = prepare_chunk(art)
            self.assertTrue(encoded)
            self.assertEqual(forbidden_offsets(b"\0" + stored), [])
            decoded = bytearray()
            for i in range(0, len(stored), 33):
                count = stored[i] - 0x5f
                self.assertEqual(count, min(32, len(art) - len(decoded)))
                decoded.extend(stored[i + 1:i + 1 + count])
            self.assertEqual(decoded, art)

    def test_expansion_cannot_exceed_runtime_limit(self):
        self.assertEqual(len(prepare_chunk(b"\x00" * 24575)[0]), 24575)
        self.assertEqual(len(prepare_chunk(b"\xff" * 23830)[0]), 24575)
        for art in (b"\x00" * 24576, b"\xff" * 23831):
            with self.assertRaises(ValueError):
                prepare_chunk(art)


if __name__ == "__main__":
    unittest.main()
