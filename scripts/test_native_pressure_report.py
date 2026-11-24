#!/usr/bin/env python3
"""Reject incomplete benchmark evidence before it enters a comparison."""
import contextlib
import copy
import io
import json
import pathlib
import tempfile
import unittest

from check_native_pressure_report import check


class ReportTests(unittest.TestCase):
    def fixture(self):
        population = {"total": 10, "inventory": 2, "on_belt": 8, "sink": 0}
        return {
            "performance.json": {
                "logic_ticks": 2, "wall_seconds": .004,
                "window_start": population, "window_end": population,
                "consumed_during_window": 0, "generated_inventory_during_window": 0,
                "route": {"fixture": "complex_v1", "belts": 34, "loops": 3, "merges": 2,
                          "miners": 3, "chests": 4, "topology_sha256": "a" * 64, "seed": 0,
                          "world_id": "a" * 32},
                "display": "headless", "backend": "gdscript", "mode": "independent_load",
                "disk_load_decode_seconds": .001, "mount_seconds": .001,
                "load_to_first_actionable_seconds": .003,
                "requested_switch_count": 0, "switches": [],
            },
            "samples.json": {"frame": [1, 1], "process_interval": [2, 2]},
            "work_samples.json": [
                {"tick": tick, "view": {"candidates": 1}, "work": {"sample_return_ores": 2}}
                for tick in [1, 2]],
            "phases.json": {
                "trace_complete": True, "exit_code": 0, "timed_out": False,
                "rss_samples": [{"rss_bytes": 4096}],
                "operation_peak_rss_bytes": {"load_operation": 8192, "steady": 4096},
                "stages": {name: {"inclusive_usec": duration, "exclusive_usec": 0}
                           for name, duration in [
                               ("load_operation", 3001), ("load_operation/load", 1001),
                               ("load_operation/mount", 1001), ("steady", 4000)]},
            },
        }

    def verify(self, fixture):
        with tempfile.TemporaryDirectory() as directory, contextlib.redirect_stdout(io.StringIO()):
            for name, value in fixture.items():
                (pathlib.Path(directory) / name).write_text(json.dumps(value))
            check(directory)

    def test_complete_independent_load_evidence_is_accepted(self):
        self.verify(self.fixture())

    def test_graphical_evidence_requires_measured_focus_state(self):
        fixture = self.fixture()
        fixture["performance.json"].update({
            "display": "window", "drawn_frames_during_window": 2,
            "load_to_first_draw_seconds": .004,
        })
        fixture["run.png"] = None
        with tempfile.TemporaryDirectory() as directory:
            for name, value in fixture.items():
                path = pathlib.Path(directory) / name
                if name == "run.png":
                    path.write_bytes(b"png")
                else:
                    path.write_text(json.dumps(value))
            with self.assertRaises(AssertionError):
                check(directory)
            for row in fixture["work_samples.json"]:
                row["window_focused"] = True
            (pathlib.Path(directory) / "work_samples.json").write_text(
                json.dumps(fixture["work_samples.json"]))
            with contextlib.redirect_stdout(io.StringIO()):
                check(directory)

    def test_missing_memory_report_and_nonpositive_peaks_are_rejected(self):
        for change in ["missing", "zero", "missing_load"]:
            fixture = self.fixture()
            if change == "missing":
                del fixture["phases.json"]
            else:
                peaks = fixture["phases.json"]["operation_peak_rss_bytes"]
                if change == "zero":
                    peaks["load_operation"] = 0
                else:
                    del peaks["load_operation"]
            with self.subTest(change=change), self.assertRaises((AssertionError, FileNotFoundError)):
                self.verify(fixture)

    def test_incomplete_complex_certificate_is_rejected(self):
        for key, value in [("belts", 33), ("topology_sha256", "x"), ("seed", 1)]:
            fixture = self.fixture()
            fixture["performance.json"]["route"][key] = value
            with self.subTest(key=key), self.assertRaises(AssertionError):
                self.verify(fixture)

    def test_requested_lifecycle_rounds_cannot_silently_disappear(self):
        fixture = self.fixture()
        fixture["performance.json"]["requested_switch_count"] = 3
        with self.assertRaises(AssertionError):
            self.verify(fixture)

    def test_completed_round_requires_distinct_world_save_load_and_settle_evidence(self):
        fixture = self.fixture()
        report = fixture["performance.json"]
        report["requested_switch_count"] = 1
        report["switches"] = [{
            "different_world": True, "save_seconds": .002,
            "decode_seconds": .001, "mount_seconds": .001,
            "to_first_actionable_seconds": .003, "settle_frames": 12,
            "world_id": "b" * 32, "objects": 10, "static_bytes": 4096,
            "work": {"cache_rows": 0}, "view": {"candidates": 1},
        }]
        phases = fixture["phases.json"]
        for name in ["save", "load", "settle"]:
            phases["stages"]["switch_1_" + name] = {
                "inclusive_usec": 10000, "exclusive_usec": 0}
            phases["operation_peak_rss_bytes"]["switch_1_" + name] = 8192
        self.verify(fixture)
        for key in ["different_world", "save_seconds", "settle_frames"]:
            invalid = copy.deepcopy(fixture)
            invalid["performance.json"]["switches"][0][key] = 0
            with self.subTest(key=key), self.assertRaises(AssertionError):
                self.verify(invalid)
        invalid = copy.deepcopy(fixture)
        invalid["performance.json"]["switches"][0]["world_id"] = "a" * 32
        with self.assertRaises(AssertionError):
            self.verify(invalid)
        invalid = copy.deepcopy(fixture)
        del invalid["performance.json"]["switches"][0]["objects"]
        with self.assertRaises((AssertionError, KeyError)):
            self.verify(invalid)


if __name__ == "__main__":
    unittest.main()
