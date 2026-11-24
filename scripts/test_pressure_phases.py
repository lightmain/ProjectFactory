#!/usr/bin/env python3
"""Check nested accounting without Godot or retaining a world snapshot."""
import unittest
import os
import contextlib
import io
import json
import pathlib
import sys
import tempfile
from unittest import mock

from pressure_phases import PhaseAccounting, process_rss, run


class PhaseTests(unittest.TestCase):
    def test_truncated_performance_report_preserves_phase_failure_evidence(self):
        with tempfile.TemporaryDirectory() as directory, contextlib.redirect_stdout(io.StringIO()):
            output = pathlib.Path(directory) / "phases.json"
            (output.parent / "performance.json").write_text("{truncated")
            status = run(output, [sys.executable, "-c", "print('done')"], 5)
            result = json.loads(output.read_text())
        self.assertNotEqual(status, 0)
        self.assertEqual(result["exit_code"], 0)
        self.assertIn("metadata_error", result)

    def test_rss_exit_race_is_unavailable_instead_of_aborting_report(self):
        import subprocess
        for error in [subprocess.CalledProcessError(1, "ps"), OSError("process exited")]:
            with mock.patch("pressure_phases.sys.platform", "linux"), mock.patch(
                    "pressure_phases.subprocess.check_output", side_effect=error):
                self.assertIsNone(process_rss(42))

    def test_live_process_rss_is_positive_not_a_false_zero_measurement(self):
        self.assertGreater(process_rss(os.getpid()), 0)

    def test_nested_cost_is_not_counted_twice_and_rss_belongs_to_operation(self):
        phases = PhaseAccounting()
        for name, entering, usec in [
            ("save", True, 10), ("decode", True, 20),
            ("world", True, 25), ("world", False, 35),
            ("decode", False, 50), ("save", False, 80),
        ]:
            phases.observe({"phase": name, "entering": entering, "usec": usec,
                            "static_bytes": 100, "objects": 3})
            phases.sample_rss(4096)
        result = phases.finish()
        self.assertEqual(result["stages"]["save"]["inclusive_usec"], 70)
        self.assertEqual(result["stages"]["save"]["exclusive_usec"], 40)
        self.assertEqual(result["stages"]["save/decode"]["exclusive_usec"], 20)
        self.assertEqual(result["operation_peak_rss_bytes"]["save"], 4096)
        self.assertEqual(result["stages"]["save"]["calls"], 1)

    def test_repeated_stages_accumulate_and_incomplete_trace_is_rejected(self):
        phases = PhaseAccounting()
        phases.observe({"phase": "load", "entering": True, "usec": 0})
        for start in [1, 4]:
            phases.observe({"phase": "disk", "entering": True, "usec": start})
            phases.observe({"phase": "disk", "entering": False, "usec": start + 2})
        with self.assertRaises(ValueError):
            phases.finish()
        phases.observe({"phase": "load", "entering": False, "usec": 7})
        self.assertEqual(phases.finish()["stages"]["load/disk"]["calls"], 2)

    def test_mismatched_or_reversed_events_are_rejected(self):
        phases = PhaseAccounting()
        phases.observe({"phase": "load", "entering": True, "usec": 10})
        with self.assertRaises(ValueError):
            phases.observe({"phase": "save", "entering": False, "usec": 12})
        with self.assertRaises(ValueError):
            phases.observe({"phase": "load", "entering": False, "usec": 9})

    def test_malformed_trace_still_writes_partial_failure_report(self):
        with tempfile.TemporaryDirectory() as directory, contextlib.redirect_stdout(io.StringIO()):
            output = pathlib.Path(directory) / "phases.json"
            status = run(output, [sys.executable, "-c", "print('PRESSURE_PHASE {bad}')"], 5)
            result = json.loads(output.read_text())
        self.assertNotEqual(status, 0)
        self.assertFalse(result["trace_complete"])
        self.assertIn("error", result)


if __name__ == "__main__":
    unittest.main()
