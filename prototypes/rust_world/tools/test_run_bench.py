"""Small protocol fixtures only; these tests never run the Rust benchmark."""

import copy
from contextlib import ExitStack
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import time
import unittest
from unittest import mock


DRIVER = Path(__file__).resolve().parent / "run_bench.py"
spec = importlib.util.spec_from_file_location("run_bench", DRIVER)
bench = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bench)


def counters(entered=0, updated=0, left=0, visited=4, calls=1):
    return {
        "entered": entered, "updated": updated, "left": left,
        "visited_chunks": visited, "read_cells": (entered + updated) * 4096,
        "output_bytes": calls * 76 + (entered + updated) * 8196 + left * 4,
    }


def complete(size=(32, 16, 32)):
    population = size[0] * size[1] * size[2]
    edit = counters(updated=1000, visited=4000, calls=1000)
    edit.update(samples_ns=list(range(1, 1001)), modifications=1000)
    unchanged = counters(visited=4000, calls=1000)
    unchanged["samples_ns"] = [7] * 1000
    moving = None
    if size == (128, 64, 128):
        moving = counters(entered=124, left=124, visited=5876, calls=1000)
        moving["samples_ns"] = [9] * 1000
    return {
        "event": "complete", "audit": True, "first_ns": 10,
        "first": counters(entered=4), "unchanged": unchanged, "edit": edit,
        "moving": moving, "revision": 1000, "population": population - 334,
        "counts": [334, population - 334, 0, 0, 0],
    }


FAKE = r'''
import json, os, pathlib, subprocess, sys, time
mode = MODE
command = sys.argv[1]
def option(name):
    return sys.argv[sys.argv.index(name) + 1]
def emit(event):
    print(json.dumps(event), flush=True)
if command == "generate":
    size = [int(v) for v in option("--size").split(",")]
    pathlib.Path(option("--output")).write_text(json.dumps(size))
    emit(dict(event="generated", generate_ns=2, save_ns=3,
              population=size[0]*size[1]*size[2], revision=0, size=size))
    sys.exit(0)
size = json.loads(pathlib.Path(option("--input")).read_text())
population = size[0]*size[1]*size[2]
emit(dict(event="loaded", pid=os.getpid(), load_ns=4,
          population=population, revision=0, size=size))
assert sys.stdin.readline() == "continue\n"
if mode == "noisy":
    sys.stderr.write("stderr fixture\n" * 20000)
    sys.stderr.flush()
if mode == "hang":
    child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(20)"])
    pathlib.Path(CHILD_PID).write_text(str(child.pid))
    print("child ready", file=sys.stderr, flush=True)
    time.sleep(20)
if mode == "nonzero":
    print("fixture exit", file=sys.stderr, flush=True)
    sys.exit(7)
emit(dict(event="audit", stage="loaded"))
emit(dict(event="audit", stage="edited"))
if mode == "missing":
    sys.exit(0)
def counters(entered=0, updated=0, left=0, visited=4, calls=1):
    return dict(entered=entered, updated=updated, left=left,
                visited_chunks=visited, read_cells=(entered+updated)*4096,
                output_bytes=calls*76+(entered+updated)*8196+left*4)
unchanged = counters(visited=4000, calls=1000)
unchanged["samples_ns"] = [7]*1000
edit = counters(updated=1000, visited=4000, calls=1000)
edit.update(samples_ns=list(range(1,1001)), modifications=1000)
moving = None
if size == [128,64,128]:
    moving = counters(entered=124, left=124, visited=5876, calls=1000)
    moving["samples_ns"] = [9]*1000
emit(dict(event="complete", audit=True, first_ns=10, first=counters(entered=4),
          unchanged=unchanged, edit=edit, moving=moving, revision=1000,
          counts=[334,population-334,0,0,0], population=population-334))
if mode == "mutate":
    pathlib.Path(option("--input")).write_text("modified")
'''


class StatisticsTests(unittest.TestCase):
    def test_nearest_rank_preserves_integer_samples(self):
        samples = [9, 1, 5, 3]
        self.assertEqual(bench.distribution(samples),
                         {"p50_ns": 3, "p95_ns": 9, "max_ns": 9, "count": 4})
        self.assertEqual(samples, [9, 1, 5, 3])
        self.assertEqual(bench.distribution(list(range(1, 1001)))["p95_ns"], 950)
        for invalid in ([], [True], [1.0], [-1]):
            with self.subTest(invalid=invalid), self.assertRaises(bench.BenchFailure):
                bench.distribution(invalid)

    def test_darwin_peak_is_bytes_but_ps_is_kib(self):
        self.assertEqual(bench.parse_peak_rss("  12345  maximum resident set size\n"), 12345)
        self.assertEqual(bench.parse_loaded_rss(" 12345\n"), 12345 * 1024)
        for value in ("", "0", "-1", "1.5", "42 43"):
            with self.subTest(value=value):
                self.assertIsNone(bench.parse_loaded_rss(value))
        for value in ("", "0 maximum resident set size", "42 Maximum resident set size",
                      "42 maximum resident set size\n43 maximum resident set size"):
            self.assertIsNone(bench.parse_peak_rss(value))

    @unittest.skipUnless(sys.platform == "darwin", "Darwin resident-memory API")
    def test_zero_ps_uses_live_resident_bytes_and_records_method(self):
        import os
        record = {}
        with mock.patch.object(bench, "bounded_output", return_value="0"):
            before = bench.sample_loaded_rss(os.getpid(), bench.Deadline(5), time.monotonic() + 5,
                                            record)
            allocation = bytearray(32 * 1024 * 1024)
            after = bench.sample_loaded_rss(os.getpid(), bench.Deadline(5), time.monotonic() + 5,
                                           record)
        self.assertGreater(before, 0)
        self.assertGreaterEqual(after - before, 16 * 1024 * 1024)
        self.assertEqual(len(allocation), 32 * 1024 * 1024)
        self.assertEqual(record["loaded_rss_method"], "proc_pidinfo.pti_resident_size_bytes")
        self.assertEqual(record["loaded_rss_ps_stdout"], "0")

    def test_failed_system_fallback_remains_missing(self):
        with mock.patch.object(bench, "bounded_output", return_value="0"), \
                mock.patch.object(bench, "proc_task_rss", return_value=None):
            self.assertIsNone(bench.sample_loaded_rss(123, bench.Deadline(5),
                                                     time.monotonic() + 5, {}))

    def test_valid_ps_retains_kib_conversion_without_fallback(self):
        record = {}
        with mock.patch.object(bench, "bounded_output", return_value="123"), \
                mock.patch.object(bench, "proc_task_rss") as fallback:
            self.assertEqual(bench.sample_loaded_rss(123, bench.Deadline(5),
                                                    time.monotonic() + 5, record), 123 * 1024)
        fallback.assert_not_called()
        self.assertEqual(record["loaded_rss_method"], "ps.rss_kib")

    def test_loaded_rss_command_converts_kib_and_rejects_zero(self):
        deadline = bench.Deadline(2)
        with mock.patch.object(bench, "bounded_output", return_value="8192") as output:
            self.assertEqual(bench.sample_loaded_rss(123, deadline, deadline.expires), 8388608)
            self.assertEqual(output.call_args.args[0], ["ps", "-o", "rss=", "-p", "123"])
        with mock.patch.object(bench, "bounded_output", return_value="0"):
            self.assertIsNone(bench.sample_loaded_rss(123, deadline, deadline.expires))


class ValidationTests(unittest.TestCase):
    def test_ndjson_rejects_duplicate_fields_non_objects_and_nan(self):
        self.assertEqual(bench.decode_event(b'{"event":"audit","stage":"loaded"}')["stage"], "loaded")
        for line in (b'{"event":"audit","event":"complete"}', b'{"extra":NaN}',
                     b'{"extra":Infinity}', b'[]', b'\xff', b'{'):
            with self.subTest(line=line), self.assertRaises(bench.BenchFailure):
                bench.decode_event(line)

    def test_protocol_rejects_wrong_order_and_missing_loaded_identity(self):
        deadline = bench.Deadline(2)
        for event in ({"event": "complete"}, {"event": "audit", "stage": "loaded"},
                      {"event": "loaded", "pid": 1}):
            record = bench.new_record("probe", (32, 16, 32))
            callback = bench.protocol_callback("probe", (32, 16, 32), record, deadline)
            with self.assertRaises(bench.BenchFailure):
                callback(json.dumps(event).encode(), mock.Mock(pid=os.getpid()), deadline.expires)
        record = bench.new_record("probe", (32, 16, 32))
        record["events"] = [{"event": "loaded"}]
        callback = bench.protocol_callback("probe", (32, 16, 32), record, deadline)
        with self.assertRaises(bench.BenchFailure):
            callback(b'{"event":"audit","stage":"edited"}', mock.Mock(), deadline.expires)

    def test_source_digest_includes_every_rust_source(self):
        metadata = bench.source_metadata(bench.Deadline(2))
        root = DRIVER.parent.parent
        for source in (root / "src").rglob("*.rs"):
            self.assertIn(str(source.relative_to(root)), metadata["files"])
        self.assertIn("src/probe.rs", metadata["files"])
        self.assertIn("src/audit.rs", metadata["files"])
        self.assertEqual(len(metadata["sha256"]), 64)

    def test_complete_checks_samples_population_audit_and_work(self):
        result = complete()
        bench.validate_complete(result, (32, 16, 32))
        invalid = []
        for key, value in (("audit", False), ("revision", 999), ("population", 16384),
                           ("counts", [334, 1, 2, 3, 4]), ("moving", {})):
            changed = copy.deepcopy(result)
            changed[key] = value
            invalid.append(changed)
        for field, value in (("samples_ns", [1] * 999), ("samples_ns", [1.0] * 1000),
                             ("updated", 1100), ("read_cells", 0),
                             ("output_bytes", 0), ("modifications", 999)):
            changed = copy.deepcopy(result)
            changed["edit"][field] = value
            invalid.append(changed)
        changed = copy.deepcopy(result)
        changed["unchanged"]["visited_chunks"] = 4400
        invalid.append(changed)
        for event in invalid:
            with self.subTest(event=event), self.assertRaises(bench.BenchFailure):
                bench.validate_complete(event, (32, 16, 32))

    def test_million_requires_moving_integer_samples(self):
        bench.validate_complete(complete((128, 64, 128)), (128, 64, 128))
        changed = complete((128, 64, 128))
        changed["moving"] = None
        with self.assertRaises(bench.BenchFailure):
            bench.validate_complete(changed, (128, 64, 128))
        changed = complete((128, 64, 128))
        changed["moving"]["visited_chunks"] += 588
        with self.assertRaises(bench.BenchFailure):
            bench.validate_complete(changed, (128, 64, 128))

    def test_all_million_budgets_are_inclusive_and_independent(self):
        probe = {
            "run": 1, "peak_rss_bytes": 256 * 1024 ** 2,
            "events": [{"load_ns": 1000000000}, {"first_ns": 2000000}],
            "distributions": {"edit": {"p95_ns": 2000000}, "moving": {"p95_ns": 2000000}},
        }
        summary = {"scales": [{"generated": {"events": [{"save_ns": 1000000000}]},
                                "probes": [probe]}]}
        self.assertEqual(bench.budget_failures(summary), [])
        for target in ("save", "load", "first", "edit", "moving", "peak"):
            changed = copy.deepcopy(summary)
            scale = changed["scales"][0]
            run = scale["probes"][0]
            if target == "save":
                scale["generated"]["events"][0]["save_ns"] += 1
            elif target == "load":
                run["events"][0]["load_ns"] += 1
            elif target == "first":
                run["events"][-1]["first_ns"] += 1
            elif target == "peak":
                run["peak_rss_bytes"] += 1
            else:
                run["distributions"][target]["p95_ns"] += 1
            with self.subTest(target=target):
                self.assertEqual(len(bench.budget_failures(changed)), 1)

    def test_generated_checks_identity_and_revision(self):
        event = dict(event="generated", size=[32, 16, 32], population=16384,
                     revision=0, generate_ns=2, save_ns=3)
        bench.validate_generated(event, (32, 16, 32))
        for field, value in (("size", [64, 32, 64]), ("revision", 1),
                             ("population", 1), ("save_ns", True)):
            changed = dict(event, **{field: value})
            with self.assertRaises(bench.BenchFailure):
                bench.validate_generated(changed, (32, 16, 32))


@unittest.skipUnless(sys.platform == "darwin", "Darwin process/RSS contract")
class DriverFixtureTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="factory-driver-test-")
        self.root = Path(self.temporary.name)
        self.child_pid = self.root / "child.pid"
        self.binary = self.root / "fake-probe"
        self.output = self.root / "report"

    def tearDown(self):
        self.temporary.cleanup()

    def fixture(self, mode):
        script = FAKE.replace("MODE", repr(mode)).replace("CHILD_PID", repr(str(self.child_pid)))
        self.binary.write_text("#!" + sys.executable + "\n" + script)
        self.binary.chmod(0o700)

    def run_fixture(self, mode="normal", timeout=3, **patches):
        self.fixture(mode)
        real_output = bench.bounded_output
        def fixture_output(command, deadline, end=None):
            # Restricted macOS runners may expose zero RSS through real ps.
            if command[0] == "ps":
                return "8192"
            return real_output(command, deadline, end)
        with mock.patch.object(bench, "source_metadata", return_value={"sha256": "fixture"}):
            with ExitStack() as stack:
                stack.enter_context(mock.patch.object(bench, "bounded_output", fixture_output))
                for name, value in patches.items():
                    stack.enter_context(mock.patch.object(bench, name, value))
                return bench.main(["--binary", str(self.binary), "--output", str(self.output),
                                   "--timeout-seconds", str(timeout),
                                   "--total-timeout-seconds", "20"])

    def summary(self):
        return json.loads((self.output / "summary.json").read_text())

    def test_three_generations_nine_sequential_probes_and_raw_samples(self):
        self.assertEqual(self.run_fixture("noisy"), 0, self.summary().get("error"))
        summary = self.summary()
        self.assertEqual(summary["status"], "a_passed")
        records = [json.loads(line) for line in (self.output / "runs.jsonl").read_text().splitlines()]
        self.assertEqual([r["kind"] for r in records],
                         ["generate", "probe", "probe", "probe"] * 3)
        self.assertEqual(len(list(self.output.glob("*.world"))), 3)
        pids = []
        for scale in summary["scales"]:
            self.assertEqual(scale["load_ns"], {"per_run": [4, 4, 4], "min": 4, "median": 4, "max": 4})
            self.assertEqual(scale["input"]["sha256_before"], scale["input"]["sha256_after"])
            self.assertEqual(len(scale["probes"]), 3)
            for run in scale["probes"]:
                pids.append(run["events"][0]["pid"])
                self.assertGreater(run["loaded_rss_bytes"], 0)
                self.assertGreater(run["peak_rss_bytes"], 0)
                self.assertEqual(run["events"][-1]["edit"]["samples_ns"], list(range(1, 1001)))
                self.assertIn("stderr fixture", (self.output / run["stderr"]).read_text())
        self.assertEqual(len(set(pids)), 9)

    def test_missing_loaded_rss_stops_without_inventing_samples(self):
        self.assertNotEqual(self.run_fixture(sample_loaded_rss=mock.Mock(return_value=None)), 0)
        summary = self.summary()
        self.assertEqual(summary["status"], "measurement_incomplete")
        self.assertEqual(len(summary["scales"][0]["probes"]), 1)
        run = summary["scales"][0]["probes"][0]
        self.assertIsNone(run["loaded_rss_bytes"])
        self.assertNotIn("distributions", run)
        self.assertEqual([event["event"] for event in run["events"]], ["loaded"])

    def test_missing_peak_rss_is_not_zero_or_pass(self):
        self.assertNotEqual(self.run_fixture(parse_peak_rss=mock.Mock(return_value=None)), 0)
        self.assertEqual(self.summary()["status"], "measurement_incomplete")
        self.assertIsNone(self.summary()["scales"][0]["probes"][0]["peak_rss_bytes"])

    def test_missing_marker_and_nonzero_stop_later_runs(self):
        for mode in ("missing", "nonzero"):
            with self.subTest(mode=mode):
                self.output = self.root / mode
                self.assertNotEqual(self.run_fixture(mode), 0)
                summary = self.summary()
                self.assertEqual(summary["status"], "correctness_failed")
                self.assertEqual(len(summary["scales"]), 1)
                run = summary["scales"][0]["probes"][0]
                self.assertNotIn("distributions", run)
                self.assertNotIn("samples_ns", run)
                self.assertTrue((self.output / run["stderr"]).exists())

    def test_timeout_kills_probe_descendant_and_preserves_logs(self):
        started = time.monotonic()
        self.assertNotEqual(self.run_fixture("hang", timeout=0.8), 0)
        self.assertLess(time.monotonic() - started, 5)
        self.assertEqual(self.summary()["status"], "measurement_incomplete")
        self.assertTrue(self.child_pid.exists())
        pid = int(self.child_pid.read_text())
        # A killed orphan may remain a zombie briefly; it must not be running.
        import subprocess
        state = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)],
                               capture_output=True, text=True, timeout=2).stdout.strip()
        self.assertTrue(not state or state.startswith("Z"), state)
        run = self.summary()["scales"][0]["probes"][0]
        self.assertIn("child ready", (self.output / run["stderr"]).read_text())

    def test_changed_input_is_correctness_failure(self):
        self.assertNotEqual(self.run_fixture("mutate"), 0)
        self.assertEqual(self.summary()["status"], "correctness_failed")
        self.assertEqual(len(self.summary()["scales"][0]["probes"]), 1)

    def test_batch_deadline_includes_source_metadata(self):
        self.fixture("normal")
        def slow_metadata(_deadline):
            time.sleep(3)
        started = time.monotonic()
        with mock.patch.object(bench, "source_metadata", side_effect=slow_metadata):
            result = bench.main(["--binary", str(self.binary), "--output", str(self.output),
                                 "--total-timeout-seconds", "0.1"])
        self.assertNotEqual(result, 0)
        self.assertLess(time.monotonic() - started, 2)
        self.assertEqual(self.summary()["status"], "measurement_incomplete")
        self.assertEqual(self.summary()["scales"], [])

    def test_output_is_exclusive_and_non_three_runs_rejected(self):
        self.output.mkdir()
        sentinel = self.output / "keep"
        sentinel.write_text("untouched")
        self.fixture("normal")
        self.assertNotEqual(bench.main(["--binary", str(self.binary), "--output", str(self.output)]), 0)
        self.assertEqual(sentinel.read_text(), "untouched")
        with self.assertRaises(SystemExit) as raised:
            bench.main(["--binary", str(self.binary), "--output", str(self.root / "other"),
                        "--runs", "2"])
        self.assertEqual(raised.exception.code, 2)
        self.assertFalse((self.root / "other").exists())

    def test_budget_failure_only_after_all_runs(self):
        def slow_distribution(samples):
            return {"p50_ns": 1, "p95_ns": 2000001, "max_ns": 2000001, "count": len(samples)}
        self.assertNotEqual(self.run_fixture(distribution=mock.Mock(side_effect=slow_distribution)), 0)
        summary = self.summary()
        self.assertEqual(summary["status"], "budget_not_met", summary.get("error"))
        self.assertEqual(len(summary["scales"][-1]["probes"]), 3)
        self.assertTrue(summary["budget_failures"])


if __name__ == "__main__":
    unittest.main()
