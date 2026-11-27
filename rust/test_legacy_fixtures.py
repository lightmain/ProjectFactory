"""Validate the checked-in Godot oracle bytes, independently of Godot."""
import hashlib
import json
from pathlib import Path
import struct
import unittest
import zlib
from fixture_variant import Reader, decode, native_checkpoint_counts

ROOT = Path(__file__).parent / "fixtures/legacy"


class LegacyGoldenTests(unittest.TestCase):
    def test_recorded_version_layout_and_state_are_bound_to_the_actual_payload(self):
        manifest = json.loads((ROOT / "manifest.json").read_text())
        for row in manifest["fixtures"]:
            with self.subTest(fixture=row["name"]):
                data = (ROOT / row["name"] / "a/session.bin").read_bytes()
                state = decode(zlib.decompress(data[40:]))
                self.assertEqual(state["version"], row["version"])
                self.assertEqual(state["world_name"], "黄金夹具")
                self.assertEqual(state["inventory"], [None] * 24)
                self.assertEqual(state["player"]["position"][0], "vector3")
                for actual, expected in zip(state["player"]["position"][1:], [-0.5, 0.01, 2.25]):
                    self.assertAlmostEqual(actual, expected, places=7)
                logistics = state["logistics"]
                if row["layout"] == "dictionary":
                    self.assertIsInstance(logistics["machines"], list)
                    machines = logistics["machines"]
                    quantity = sum(machine["quantity"] for machine in machines)
                    blocks = [machine["block"] for machine in machines]
                else:
                    self.assertEqual(logistics["packed"], 1)
                    payload = logistics["machines"]
                    self.assertIsInstance(payload, bytes)
                    self.assertEqual(len(payload) % 136, 0)
                    machines = [payload[offset:offset + 136] for offset in range(0, len(payload), 136)]
                    quantity = sum(struct.unpack_from("<q", machine, 16)[0] for machine in machines)
                    blocks = [machine[12] for machine in machines]
                self.assertEqual(len(machines), row["machines"])
                native_counts = None
                if row["layout"] == "continuous":
                    native_counts = native_checkpoint_counts(logistics["native"])
                    quantity += native_counts["items"]
                self.assertEqual(quantity, row["ores"])
                self.assertAlmostEqual(logistics["time"] - logistics["tick"] / 60,
                                       row["time_remainder"], places=12)
                self.assertAlmostEqual(logistics["compensation"], row["compensation"], delta=1e-20)
                self.assertEqual(logistics.get("backend", "gdscript"),
                                 "rust" if row["layout"] == "continuous" else "gdscript")
                if row["version"] < 4:
                    self.assertEqual(state["minimum"], ("vector3i", -32, -4, -32))
                    self.assertEqual(state["maximum"], ("vector3i", 32, 60, 32))
                if row["version"] == 1:
                    self.assertNotIn("structures", state)
                    self.assertNotIn(8, blocks)
                if row["scenario"] == "running" and row["version"] >= 2:
                    self.assertEqual(len(state["structures"]), 1)
                if row["scenario"] == "running" and row["version"] >= 3:
                    self.assertTrue(any(9 <= block <= 16 for block in blocks))
                if row["layout"] == "continuous":
                    self.assertGreater(len(logistics["native"]), 16)
                    self.assertEqual(logistics["binding"]["pending"][0], "int64s")
                    pending_count = len(logistics["binding"]["pending"][1]) // 4
                    self.assertEqual(pending_count, row["pending_links"])
                    self.assertGreater(pending_count, 0)
                    self.assertEqual(logistics["native"][:4], b"RCNV")
                    self.assertEqual(struct.unpack_from("<I", logistics["native"], 4)[0], row["native_version"])
                    self.assertEqual(struct.unpack_from("<Q", logistics["native"], 32)[0], logistics["tick"])
                    self.assertEqual(native_counts["frame"], logistics["tick"])
                    self.assertEqual(native_counts["transactions"], row["native_transactions"])
                    if row["phase"] == "native_run":
                        self.assertEqual(row["native_version"], 2)
                        self.assertGreater(row["native_transactions"], 0)
                if row["phase"] == "boundary_flush":
                    self.assertEqual(logistics["flushed"], logistics["tick"])
                self.assertEqual(len(row["continuation_sha256"]), 121)
                self.assertTrue(all(len(value) == 64 for value in row["continuation_sha256"]))

    def test_rejection_evidence_contains_the_actual_mutated_bytes(self):
        manifest = json.loads((ROOT / "manifest.json").read_text())
        files = manifest["rejection_files"]
        self.assertEqual(set(files), set(manifest["rejections"]))
        for name, record in files.items():
            path = ROOT / record["file"]
            self.assertTrue(path.resolve().is_relative_to(ROOT.resolve()))
            data = path.read_bytes()
            self.assertEqual(len(data), record["bytes"])
            self.assertEqual(hashlib.sha256(data).hexdigest(), record["sha256"])
            if record["kind"] == "blob":
                source = bytearray((ROOT / "v4_packed_running/a/session.bin").read_bytes())
                source[8 if name == "corrupt_sha" else 0] ^= 1
                self.assertEqual(data, source)
                continue
            self.assertEqual(data[:4], b"PFS1")
            raw = zlib.decompress(data[40:])
            self.assertEqual(hashlib.sha256(raw).digest(), data[8:40])
            state = decode(raw)
            logistics = state["logistics"]
            if name == "unsupported_version":
                self.assertEqual(state["version"], 5)
            elif name == "bad_tick":
                self.assertNotEqual(logistics["tick"], int((logistics["time"] + 1e-9) * 60))
            elif name == "packed_truncation":
                self.assertNotEqual(len(logistics["machines"]) % 136, 0)
            elif name == "unknown_backend":
                self.assertEqual(logistics["backend"], "unknown")
            elif name == "v1_structure":
                self.assertEqual(state["version"], 1)
                self.assertTrue(any(8 in records[2::3] for records in state["chunks"].values()))
            elif name == "v2_slope":
                self.assertEqual(state["version"], 2)
                self.assertTrue(any(any(9 <= value <= 16 for value in records[2::3])
                                    for records in state["chunks"].values()))
            else:
                self.fail("unverified rejection " + name)

    def test_old_formats_cover_empty_and_running_factories(self):
        manifest = json.loads((ROOT / "manifest.json").read_text())
        self.assertEqual(manifest["engine"], "4.7.2-stable (official)")
        self.assertEqual(manifest["synthetic_player_data"], True)
        self.assertTrue(
            {(1, "dictionary", "running"), (2, "dictionary", "running"),
             (3, "dictionary", "running"), (4, "dictionary", "running"),
             (4, "packed", "running"), (4, "continuous", "running"),
             (1, "dictionary", "empty"), (2, "dictionary", "empty"),
             (3, "dictionary", "empty"), (4, "packed", "empty")}.issubset(
                {(row["version"], row["layout"], row["scenario"])
                 for row in manifest["fixtures"]}),
        )
        self.assertTrue(
            {("dictionary", "boundary_flush"), ("continuous", "native_run")}.issubset(
                {(row["layout"], row["phase"]) for row in manifest["fixtures"]}),
        )
        for row in manifest["fixtures"]:
            with self.subTest(fixture=row["name"]):
                self.assertTrue(row["oracle_load_accepted"])
                self.assertTrue(row["oracle_continuation_equal"])
                self.assertEqual(row["replay_ticks"], 120)
                if row["scenario"] == "running":
                    self.assertGreaterEqual(row["machines"], 6)
                    self.assertGreater(row["ores"], 0)
                    self.assertGreater(row["time_remainder"], 0)
                    self.assertNotEqual(row["compensation"], 0)
                else:
                    self.assertEqual(row["machines"], 0)
                    self.assertEqual(row["ores"], 0)
                self.assertEqual(row["inventory_slots"], 24)
                self.assertEqual(row["world_name"], "黄金夹具")

    def test_every_recorded_payload_matches_hash_and_actual_deflate_layout(self):
        manifest = json.loads((ROOT / "manifest.json").read_text())
        for row in manifest["fixtures"]:
            self.assertIn("current", row["files"])
            self.assertIn("a/session.bin", row["files"])
            self.assertEqual((ROOT / row["name"] / "current").read_bytes(), b"a")
            for name, info in row["files"].items():
                with self.subTest(fixture=row["name"], file=name):
                    path = ROOT / row["name"] / name
                    self.assertTrue(path.resolve().is_relative_to(ROOT.resolve()))
                    data = path.read_bytes()
                    self.assertEqual(len(data), info["bytes"])
                    self.assertEqual(hashlib.sha256(data).hexdigest(), info["sha256"])
                    if not name.endswith(".bin"):
                        continue
                    self.assertEqual(data[:4], b"PFS1")
                    length = struct.unpack_from("<I", data, 4)[0]
                    self.assertGreater(length, 0)
                    self.assertLess(length, 384 * 1024 * 1024)
                    self.assertIn(info["deflate_wrapper"], ["raw", "zlib"])
                    decompressor = zlib.decompressobj(
                        -15 if info["deflate_wrapper"] == "raw" else 15)
                    raw = decompressor.decompress(data[40:], length + 1)
                    self.assertTrue(decompressor.eof)
                    self.assertFalse(decompressor.unused_data)
                    self.assertEqual(len(raw), length)
                    self.assertEqual(hashlib.sha256(raw).digest(), data[8:40])
                    self.assertEqual(hashlib.sha256(raw).hexdigest(), info["raw_sha256"])
                    if name.endswith("session.bin"):
                        # Variant dictionary header, not a Rust memory dump.
                        self.assertEqual(struct.unpack_from("<I", raw)[0] & 0xFFFF, 27)

    def test_oracle_includes_the_version_and_semantic_rejections(self):
        manifest = json.loads((ROOT / "manifest.json").read_text())
        rejected = manifest["rejections"]
        for name in [
            "unsupported_version", "v1_structure", "v2_slope", "bad_tick",
            "packed_truncation", "unknown_backend", "corrupt_sha", "corrupt_magic",
        ]:
            self.assertIs(rejected[name], True)
        probes = manifest["variant_probes"]
        for name in ["null", "bool", "integer", "wide_integer", "float", "wide_float",
                     "chinese", "vector3", "vector3i", "array", "dictionary",
                     "bytes", "int32s", "int64s", "float64s"]:
            data = bytes.fromhex(probes[name])
            self.assertGreaterEqual(len(data), 4)
            self.assertEqual(len(data) % 4, 0)
        self.assertEqual(bytes.fromhex(probes["null"]), struct.pack("<I", 0))
        self.assertEqual(bytes.fromhex(probes["bool"]), struct.pack("<II", 1, 1))
        self.assertEqual(bytes.fromhex(probes["integer"]), struct.pack("<Ii", 2, -7))
        self.assertEqual(bytes.fromhex(probes["wide_integer"]), struct.pack("<Iq", 0x10002, 1 << 40))
        self.assertEqual(bytes.fromhex(probes["float"]), struct.pack("<If", 3, 1.5))
        self.assertEqual(bytes.fromhex(probes["wide_float"]), struct.pack("<Id", 0x10003, 1.1))
        text = "黄金夹具".encode()
        self.assertEqual(bytes.fromhex(probes["chinese"]), struct.pack("<II", 4, len(text)) + text)
        self.assertEqual(bytes.fromhex(probes["vector3"]), struct.pack("<Ifff", 9, -0.5, 1.25, 2.0))
        self.assertEqual(bytes.fromhex(probes["vector3i"]), struct.pack("<Iiii", 10, -1, 2, 3))
        self.assertEqual(bytes.fromhex(probes["bytes"]), struct.pack("<II", 29, 3) + b"\x00\x7f\xff\x00")
        self.assertEqual(bytes.fromhex(probes["int32s"]), struct.pack("<IIii", 30, 2, -1, 2))
        self.assertEqual(bytes.fromhex(probes["int64s"]), struct.pack("<IIqq", 31, 2, -1, 1 << 40))
        self.assertEqual(bytes.fromhex(probes["float64s"]), struct.pack("<IIdd", 33, 2, 1.1, -2.0))
        self.assertEqual(
            bytes.fromhex(probes["array"]),
            struct.pack("<II", 28, 2) + struct.pack("<Ii", 2, -7) + struct.pack("<I", 0),
        )
        self.assertEqual(
            bytes.fromhex(probes["dictionary"]),
            struct.pack("<II", 27, 1) + struct.pack("<II", 4, 1) + b"a\0\0\0" + struct.pack("<Ii", 2, -7),
        )
        typed_array = Reader(bytes.fromhex(probes["typed_array"]))
        self.assertEqual(typed_array.value(), [-7, 0])
        self.assertIn(("array", 2), typed_array.typed_containers)
        typed_dictionary = Reader(bytes.fromhex(probes["typed_dictionary"]))
        self.assertEqual(typed_dictionary.value(), {("vector3i", -1, 2, 3): b"\0\x7f\xff"})
        self.assertIn(("dictionary", 10, 29), typed_dictionary.typed_containers)


if __name__ == "__main__":
    unittest.main()
