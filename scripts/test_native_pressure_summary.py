#!/usr/bin/env python3
"""Formal comparisons require independent matched runs and player operations."""
import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


class SummaryTests(unittest.TestCase):
    def fixture(self):
        return {
            "performance.json": {
                "mode": "independent_load", "window_start": {"on_belt": 8},
                "window_end": {"on_belt": 8}, "native_transactions_during_window": {},
                "route": {"world_id": "a" * 32, "belts": 10},
                "stages_ms": {name: dict(p50=1, p95=1, p99=1, max=1, over_budget=0)
                              for name in ["frame", "process_interval", "sample",
                                           "submission", "candidate", "decoration", "display_query"]},
                "incoming_initial_entries": 0, "last_work": {},
                "load_to_first_actionable_seconds": .003, "disk_load_decode_seconds": .001,
                "mount_seconds": .001, "requested_switch_count": 3,
                "switches": [{"save_seconds": value} for value in [.002, .001, .002]],
                "display": "window",
            },
            "phases.json": {
                "operation_peak_rss_bytes": {"load_operation": 8192, "switch_1_save": 24576,
                                             "switch_2_save": 16384, "switch_3_save": 24576},
                "steady_rss_bytes": {"p50": 4096}, "stages": {}, "disk_files": [],
            },
            "work_samples.json": [
                {"window_focused": True, "camera_position": [0, 1, 0],
                 "view": {"candidates": 10, "display_requested_rows": 8}} for _ in range(2)],
            "provenance.json": {
                "execution_project": {"inputs_sha256": "a" * 64},
                "loaded_binary_sha256": "b" * 64,
                "loaded_descriptor_sha256": "f" * 64,
                "validated_library_entries": ["macos.debug", "macos.release"],
                "native_build": {
                    "binary_sha256": "b" * 64, "descriptor_sha256": "f" * 64,
                    "source": {"build_inputs_sha256": "c" * 64},
                },
                "input_save": {"a/session.bin": {"bytes": 2048, "sha256": "d" * 64}},
                "alternate_save": {"a/session.bin": {"bytes": 1024, "sha256": "e" * 64}},
            },
        }

    def summarize(self, repetitions=3, mutation=None):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            runs = []
            for index in range(repetitions):
                prefix = "r%d-load-fixed" % (index + 1)
                entry = {"prefix": prefix, "backend": "rust", "case": "10k",
                         "track": "fixed", "mode": "independent_load", "status": 0,
                         "lifecycle_expected": True}
                fixture = copy.deepcopy(self.fixture())
                if mutation:
                    mutation(index, fixture, entry)
                directory = root / prefix / "10k"
                directory.mkdir(parents=True)
                for name, value in fixture.items():
                    destination = root / prefix / name if name == "provenance.json" else directory / name
                    destination.write_text(json.dumps(value))
                runs.append(entry)
            (root / "runs.json").write_text(json.dumps(runs))
            subprocess.run([sys.executable, str(Path(__file__).with_name("summarize_native_pressure.py")),
                            str(root)], check=True, capture_output=True, text=True)
            return json.loads((root / "summary.json").read_text())["groups"][
                "rust/10k/independent_load/fixed"]

    def test_player_save_uses_mounted_world_rounds_not_generator_save(self):
        group = self.summarize()
        self.assertEqual(group["comparison_status"], "complete")
        self.assertEqual(group["metrics"]["player_save_seconds"]["samples"], [.002] * 3)
        self.assertEqual(group["metrics"]["player_save_peak_rss_bytes"]["samples"], [24576] * 3)

    def test_missing_rounds_and_lifecycle_are_incomplete(self):
        self.assertEqual(self.summarize(2)["comparison_status"], "incomplete")
        def omit(index, fixture, entry):
            if index == 1:
                entry["status"] = 1
        self.assertEqual(self.summarize(mutation=omit)["comparison_status"], "incomplete")
        def no_lifecycle(index, fixture, entry):
            if index == 1:
                fixture["performance.json"]["requested_switch_count"] = 0
                fixture["performance.json"]["switches"] = []
        self.assertEqual(self.summarize(mutation=no_lifecycle)["comparison_status"], "incomplete")
        def undeclared(index, fixture, entry):
            if index == 1:
                entry.pop("lifecycle_expected")
        self.assertEqual(self.summarize(mutation=undeclared)["comparison_status"], "incomplete")

    def test_changed_source_load_and_focus_are_not_comparable(self):
        for kind in ["source", "load", "focus", "duplicate", "archive", "missing_archive"]:
            def change(index, fixture, entry):
                if index != 1:
                    return
                if kind == "source":
                    fixture["provenance.json"]["loaded_binary_sha256"] = "c" * 64
                elif kind == "load":
                    fixture["performance.json"]["window_start"]["on_belt"] = 7
                elif kind == "focus":
                    fixture["work_samples.json"][0]["window_focused"] = False
                elif kind == "archive":
                    fixture["provenance.json"]["input_save"]["a/session.bin"]["sha256"] = "f" * 64
                elif kind == "missing_archive":
                    fixture["provenance.json"].pop("input_save")
                else:
                    entry["prefix"] = "r1-load-fixed"
            with self.subTest(kind=kind):
                self.assertNotEqual(self.summarize(mutation=change)["comparison_status"], "complete")

    def test_lifecycle_requires_identified_alternate_archive_in_every_round(self):
        for missing_all in [False, True]:
            def omit(index, fixture, entry):
                if missing_all or index == 1:
                    fixture["provenance.json"].pop("alternate_save")
            with self.subTest(missing_all=missing_all):
                self.assertEqual(self.summarize(mutation=omit)["comparison_status"], "incomplete")

    def test_unknown_native_build_is_never_a_formal_comparison(self):
        for kind in ["all_missing", "unverified_descriptor", "wrong_binary", "missing_source",
                     "wrong_descriptor", "empty_build_inputs"]:
            def invalidate(index, fixture, entry):
                provenance = fixture["provenance.json"]
                if kind == "all_missing":
                    provenance.pop("loaded_binary_sha256", None)
                    provenance.pop("native_build", None)
                elif kind == "unverified_descriptor":
                    provenance.pop("validated_library_entries", None)
                elif kind == "wrong_binary":
                    provenance["native_build"]["binary_sha256"] = "c" * 64
                elif kind == "missing_source":
                    provenance["native_build"].pop("source")
                elif kind == "wrong_descriptor":
                    provenance["native_build"]["descriptor_sha256"] = "d" * 64
                else:
                    provenance["native_build"]["source"]["build_inputs_sha256"] = ""
            with self.subTest(kind=kind):
                self.assertNotEqual(self.summarize(mutation=invalidate)["comparison_status"], "complete")

    def test_missing_whole_metric_or_target_stage_is_incomplete(self):
        for kind in ["load_peak", "player_save_peak", "stage", "decoration"]:
            def omit(index, fixture, entry):
                if kind == "stage":
                    fixture["performance.json"]["stages_ms"].pop("sample")
                elif kind == "decoration":
                    if index == 1:
                        fixture["performance.json"]["stages_ms"].pop("decoration")
                else:
                    name = "load_operation" if kind == "load_peak" else "switch_1_save"
                    fixture["phases.json"]["operation_peak_rss_bytes"].pop(name)
            with self.subTest(kind=kind):
                self.assertEqual(self.summarize(mutation=omit)["comparison_status"], "incomplete")


if __name__ == "__main__":
    unittest.main()
