#!/usr/bin/env python3
"""M00 acceptance: stop excessive measurements and preserve their evidence."""
import contextlib
import io
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

from pressure_phases import run


class PhaseLimitTests(unittest.TestCase):
    def test_observed_memory_excess_is_failure_even_if_child_has_exited(self):
        launch = subprocess.Popen

        def launch_completed_child(*args, **kwargs):
            child = launch(*args, **kwargs)
            child.wait(timeout=2)
            return child

        with tempfile.TemporaryDirectory() as directory:
            output = pathlib.Path(directory) / "phases.json"
            with mock.patch("pressure_phases.subprocess.Popen", side_effect=launch_completed_child):
                with mock.patch("pressure_phases.process_rss", return_value=8192):
                    with contextlib.redirect_stdout(io.StringIO()):
                        status = run(
                            output, [sys.executable, "-c", "print('done')"],
                            timeout_seconds=2, max_rss_bytes=4096,
                        )
            result = json.loads(output.read_text())
        self.assertEqual(result["exit_code"], 0)
        self.assertTrue(result["rss_samples"])
        self.assertNotEqual(status, 0)
        self.assertTrue(result["rss_limit_exceeded"])
        self.assertEqual(result["stop_reason"], "rss_limit")

    def test_memory_limit_stops_child_and_retains_failure_report(self):
        with tempfile.TemporaryDirectory() as directory:
            output = pathlib.Path(directory) / "phases.json"
            with mock.patch("pressure_phases.process_rss", return_value=8192):
                with contextlib.redirect_stdout(io.StringIO()):
                    status = run(
                        output,
                        [sys.executable, "-c", "import time; time.sleep(5)"],
                        timeout_seconds=2,
                        max_rss_bytes=4096,
                    )
            result = json.loads(output.read_text())
        self.assertNotEqual(status, 0)
        self.assertTrue(result["rss_limit_exceeded"])
        self.assertFalse(result["timed_out"])
        self.assertEqual(result["stop_reason"], "rss_limit")
        self.assertEqual(result["max_rss_bytes"], 4096)
        self.assertTrue(result["rss_samples"])
        self.assertGreater(result["rss_samples"][0]["rss_bytes"], 4096)

    def test_timeout_is_explicit_and_keeps_partial_phase_trace(self):
        code = (
            "import time; "
            "print('PRESSURE_PHASE "
            "{\"phase\":\"build\",\"entering\":true,\"usec\":1}', flush=True); "
            "time.sleep(5)"
        )
        with tempfile.TemporaryDirectory() as directory:
            output = pathlib.Path(directory) / "phases.json"
            with contextlib.redirect_stdout(io.StringIO()):
                status = run(output, [sys.executable, "-c", code], timeout_seconds=0.5)
            result = json.loads(output.read_text())
        self.assertNotEqual(status, 0)
        self.assertTrue(result["timed_out"])
        self.assertEqual(result["stop_reason"], "timeout")
        self.assertEqual(result["timeout_seconds"], 0.5)
        self.assertFalse(result["trace_complete"])
        self.assertEqual(result["boundaries"][0]["phase"], "build")

    def test_invalid_limits_are_rejected_before_launching_child(self):
        with tempfile.TemporaryDirectory() as directory:
            output = pathlib.Path(directory) / "phases.json"
            for options in [
                {"timeout_seconds": 0},
                {"timeout_seconds": float("nan")},
                {"timeout_seconds": float("inf")},
                {"max_rss_bytes": 0},
                {"max_rss_bytes": -1},
                {"max_rss_bytes": 1.5},
            ]:
                with self.subTest(options=options):
                    with mock.patch(
                        "pressure_phases.subprocess.Popen",
                        side_effect=AssertionError("invalid limits launched a child"),
                    ) as popen:
                        with self.assertRaises(ValueError):
                            run(output, [sys.executable, "-c", "pass"], **options)
                        popen.assert_not_called()
            self.assertFalse(output.exists())

    def test_cli_applies_limits_and_preserves_engine_arguments(self):
        script = pathlib.Path(__file__).with_name("pressure_phases.py")
        with tempfile.TemporaryDirectory() as directory:
            output = pathlib.Path(directory) / "phases.json"
            process = subprocess.run(
                [
                    sys.executable, str(script), "--timeout-seconds", "0.5",
                    "--max-rss-bytes", str(1024 ** 3), str(output), "--",
                    sys.executable, "-c", "import time; time.sleep(5)", "--engine-flag",
                ],
                capture_output=True, text=True, timeout=5,
            )
            result = json.loads(output.read_text())
        self.assertNotEqual(process.returncode, 0)
        self.assertTrue(result["timed_out"])
        self.assertEqual(result["max_rss_bytes"], 1024 ** 3)
        self.assertEqual(result["command"][-1], "--engine-flag")


if __name__ == "__main__":
    unittest.main()
