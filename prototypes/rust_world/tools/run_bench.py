#!/usr/bin/env python3
"""Darwin-only A experiment driver. No compilation or cache manipulation."""

import argparse
from contextlib import contextmanager
import ctypes
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import re
import selectors
import signal
import statistics
import subprocess
import sys
import time


SCALES = ((32, 16, 32), (64, 32, 64), (128, 64, 128))
SEED = 20261125
WARMUP = 100
SAMPLES = 1000
COUNTERS = ("entered", "updated", "left", "visited_chunks", "read_cells", "output_bytes")
MAX_LINE_BYTES = 1024 * 1024


class BenchFailure(Exception):
    def __init__(self, message, status="correctness_failed"):
        super().__init__(message)
        self.status = status


def require(condition, message):
    if not condition:
        raise BenchFailure(message)


def integer(value, name):
    require(type(value) is int and value >= 0, f"{name}: expected nonnegative integer")
    return value


def distribution(samples):
    require(isinstance(samples, list) and bool(samples), "missing integer timing samples")
    for value in samples:
        integer(value, "sample_ns")
    ordered = sorted(samples)
    return {"p50_ns": ordered[math.ceil(len(ordered) * 0.50) - 1],
            "p95_ns": ordered[math.ceil(len(ordered) * 0.95) - 1],
            "max_ns": ordered[-1], "count": len(ordered)}


def parse_loaded_rss(text):
    if not re.fullmatch(r"\s*[0-9]+\s*", text):
        return None
    value = int(text)
    return value * 1024 if value > 0 else None


def parse_peak_rss(text):
    matches = re.findall(r"^[ \t]*([0-9]+)[ \t]+maximum resident set size[ \t]*$",
                         text, flags=re.MULTILINE)
    return int(matches[0]) if len(matches) == 1 and int(matches[0]) > 0 else None


class Deadline:
    def __init__(self, seconds, process_seconds=30):
        self.expires = time.monotonic() + seconds
        self.process_seconds = process_seconds

    def remaining(self):
        remaining = self.expires - time.monotonic()
        if remaining <= 0:
            raise BenchFailure("entire batch timed out", "measurement_incomplete")
        return remaining

    def process_end(self):
        return time.monotonic() + min(self.process_seconds, self.remaining())


@contextmanager
def batch_alarm(deadline):
    # Also bounds Python-side hashing, directory traversal and source metadata.
    def expired(_signum, _frame):
        raise BenchFailure("entire batch timed out", "measurement_incomplete")
    old_handler = signal.getsignal(signal.SIGALRM)
    old_timer = signal.getitimer(signal.ITIMER_REAL)
    started = time.monotonic()
    signal.signal(signal.SIGALRM, expired)
    signal.setitimer(signal.ITIMER_REAL, deadline.remaining())
    try:
        yield
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, old_handler)
        if old_timer[0]:
            signal.setitimer(signal.ITIMER_REAL,
                             max(0.000001, old_timer[0] - (time.monotonic() - started)),
                             old_timer[1])


def kill_group(process):
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=1)
    except subprocess.TimeoutExpired:
        pass


def run_process(command, stdout_path, stderr_path, deadline, on_line=None, record=None):
    """Drain both streams concurrently; the callback handles the loaded handshake."""
    end = deadline.process_end()
    process = None
    pending = bytearray()
    if record is not None:
        record["command"] = [str(part) for part in command]
    with stdout_path.open("xb") as stdout_log, stderr_path.open("xb") as stderr_log:
        with selectors.DefaultSelector() as selector:
            try:
                process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                           stderr=subprocess.PIPE, start_new_session=True)
                if record is not None:
                    record["wrapper_pid"] = process.pid
                for pipe, log in ((process.stdout, stdout_log), (process.stderr, stderr_log)):
                    os.set_blocking(pipe.fileno(), False)
                    selector.register(pipe, selectors.EVENT_READ, log)
                while selector.get_map():
                    remaining = min(end - time.monotonic(), deadline.remaining())
                    if remaining <= 0:
                        raise BenchFailure("subprocess timed out", "measurement_incomplete")
                    ready = selector.select(remaining)
                    if not ready:
                        raise BenchFailure("subprocess timed out", "measurement_incomplete")
                    for key, _events in ready:
                        chunk = os.read(key.fileobj.fileno(), 65536)
                        if not chunk:
                            selector.unregister(key.fileobj)
                            continue
                        key.data.write(chunk)
                        key.data.flush()
                        if key.fileobj is process.stdout and on_line is not None:
                            pending.extend(chunk)
                            while b"\n" in pending:
                                line, _, tail = pending.partition(b"\n")
                                pending = bytearray(tail)
                                require(len(line) <= MAX_LINE_BYTES, "oversized protocol line")
                                on_line(line, process, end)
                            require(len(pending) <= MAX_LINE_BYTES, "oversized protocol line")
                require(not pending, "unterminated NDJSON event")
                remaining = min(end - time.monotonic(), deadline.remaining())
                if remaining <= 0:
                    raise BenchFailure("subprocess timed out", "measurement_incomplete")
                returncode = process.wait(timeout=remaining)
                if record is not None:
                    record["returncode"] = returncode
                require(returncode == 0, f"subprocess exited {returncode}")
            except subprocess.TimeoutExpired as error:
                raise BenchFailure("subprocess timed out", "measurement_incomplete") from error
            finally:
                if process is not None:
                    # Includes a probe child even if its /usr/bin/time parent exited.
                    kill_group(process)
                    drain_end = time.monotonic() + 1
                    for pipe, log in ((process.stdout, stdout_log), (process.stderr, stderr_log)):
                        if pipe is not None:
                            # Retain already-written pipe data after an early protocol failure.
                            while time.monotonic() < drain_end:
                                try:
                                    chunk = os.read(pipe.fileno(), 65536)
                                except BlockingIOError:
                                    break
                                if not chunk:
                                    break
                                log.write(chunk)
                            pipe.close()
                    process.stdin.close()
                    if record is not None:
                        record["returncode"] = process.returncode


def bounded_output(command, deadline, end=None):
    limit = min(deadline.process_end(), end if end is not None else deadline.expires)
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               start_new_session=True)
    try:
        timeout = min(limit - time.monotonic(), deadline.remaining())
        if timeout <= 0:
            raise BenchFailure("metadata/RSS timeout", "measurement_incomplete")
        stdout, stderr = process.communicate(timeout=timeout)
        if process.returncode != 0:
            raise BenchFailure(f"{command[0]} exited {process.returncode}: "
                               f"{stderr.decode(errors='replace').strip()}",
                               "measurement_incomplete")
        return stdout.decode("utf-8").strip()
    except subprocess.TimeoutExpired as error:
        raise BenchFailure("metadata/RSS timeout", "measurement_incomplete") from error
    finally:
        kill_group(process)
        process.stdout.close()
        process.stderr.close()


class ProcTaskInfo(ctypes.Structure):
    # Darwin sys/proc_info.h: PROC_PIDTASKINFO=4, resident size is bytes.
    _fields_ = [
        (name, ctypes.c_uint64) for name in (
            "virtual_size", "resident_size", "total_user", "total_system",
            "threads_user", "threads_system")
    ] + [("counters", ctypes.c_int32 * 12)]


def proc_task_rss(pid):
    if sys.platform != "darwin":
        return None
    try:
        library = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
        library.proc_pidinfo.argtypes = [
            ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
        library.proc_pidinfo.restype = ctypes.c_int
        info = ProcTaskInfo()
        received = library.proc_pidinfo(pid, 4, 0, ctypes.byref(info), ctypes.sizeof(info))
        if received != ctypes.sizeof(info) or info.resident_size == 0:
            return None
        return info.resident_size
    except (OSError, AttributeError):
        return None


def sample_loaded_rss(pid, deadline, end, record=None):
    details = record if record is not None else {}
    try:
        text = bounded_output(["ps", "-o", "rss=", "-p", str(pid)], deadline, end)
        details["loaded_rss_ps_stdout"] = text
        rss = parse_loaded_rss(text)
        if rss is not None:
            details["loaded_rss_method"] = "ps.rss_kib"
            return rss
        deadline.remaining()
        if time.monotonic() >= end:
            raise BenchFailure("loaded RSS timeout", "measurement_incomplete")
        rss = proc_task_rss(pid)
        if rss is not None:
            details["loaded_rss_method"] = "proc_pidinfo.pti_resident_size_bytes"
        return rss
    except (OSError, UnicodeError):
        return None


def validate_identity(event, size):
    require(isinstance(event, dict), "event is not an object")
    reported_size = event.get("size")
    require(isinstance(reported_size, list) and len(reported_size) == 3
            and all(type(axis) is int for axis in reported_size)
            and reported_size == list(size), "world size mismatch")
    require(integer(event.get("population"), "population") == math.prod(size),
            "initial population mismatch")
    require(integer(event.get("revision"), "revision") == 0, "initial revision mismatch")


def validate_generated(event, size):
    validate_identity(event, size)
    require(event.get("event") == "generated", "missing generated marker")
    integer(event.get("generate_ns"), "generate_ns")
    integer(event.get("save_ns"), "save_ns")


def validate_counters(report, calls, expected=None):
    require(isinstance(report, dict), "missing work counters")
    values = {name: integer(report.get(name), name) for name in COUNTERS}
    require(values["read_cells"] == (values["entered"] + values["updated"]) * 4096,
            "read_cells disagrees with chunk records")
    require(values["output_bytes"] == calls * 76
            + (values["entered"] + values["updated"]) * 8196 + values["left"] * 4,
            "output_bytes disagrees with measured packet records")
    if expected is not None:
        for name, value in expected.items():
            require(values[name] == value, f"{name}: measured work mismatch")


def validate_complete(event, size):
    require(isinstance(event, dict) and event.get("event") == "complete", "missing complete marker")
    require(event.get("audit") is True, "complete audit did not pass")
    require(integer(event.get("revision"), "revision") == SAMPLES, "final revision mismatch")
    require(integer(event.get("population"), "population") == math.prod(size) - 334,
            "edited population mismatch")
    counts = event.get("counts")
    require(isinstance(counts, list) and len(counts) == 5, "missing five type counts")
    for value in counts:
        integer(value, "type count")
    require(counts[0] == 334 and sum(counts) == math.prod(size)
            and sum(counts[1:]) == event["population"], "type counts/population mismatch")
    integer(event.get("first_ns"), "first_ns")
    validate_counters(event.get("first"), 1,
                      {"entered": 4, "updated": 0, "left": 0, "visited_chunks": 4})
    for name, updated in (("unchanged", 0), ("edit", SAMPLES)):
        report = event.get(name)
        validate_counters(report, SAMPLES,
                          {"entered": 0, "updated": updated, "left": 0,
                           "visited_chunks": 4 * SAMPLES})
        require(isinstance(report.get("samples_ns"), list)
                and len(report["samples_ns"]) == SAMPLES, f"{name}: missing measured samples")
        for value in report["samples_ns"]:
            integer(value, f"{name} sample_ns")
    require(integer(event["edit"].get("modifications"), "modifications") == SAMPLES,
            "edit modifications mismatch")
    if size == SCALES[-1]:
        moving = event.get("moving")
        # Fixed one-cell bounce, measured ordinals 100..1099; excludes warmup.
        validate_counters(moving, SAMPLES,
                          {"entered": 124, "updated": 0, "left": 124, "visited_chunks": 5876})
        require(isinstance(moving.get("samples_ns"), list)
                and len(moving["samples_ns"]) == SAMPLES, "moving: missing measured samples")
        for value in moving["samples_ns"]:
            integer(value, "moving sample_ns")
    else:
        require("moving" in event and event["moving"] is None, "unexpected moving workload")


def decode_event(line):
    def invalid_constant(value):
        raise BenchFailure(f"invalid JSON constant: {value}")

    def unique_object(pairs):
        result = {}
        for key, value in pairs:
            require(key not in result, f"duplicate event field: {key}")
            result[key] = value
        return result
    try:
        event = json.loads(line, object_pairs_hook=unique_object, parse_constant=invalid_constant)
    except (ValueError, UnicodeError) as error:
        raise BenchFailure("invalid NDJSON event") from error
    require(isinstance(event, dict), "event is not an object")
    return event


def protocol_callback(kind, size, record, deadline):
    def receive(line, process, end):
        event = decode_event(line)
        record["events"].append(event)
        ordinal = len(record["events"])
        if kind == "generate":
            require(ordinal == 1, "extra generate event")
            validate_generated(event, size)
            return
        if ordinal == 1:
            require(event.get("event") == "loaded", "missing loaded marker")
            validate_identity(event, size)
            integer(event.get("load_ns"), "load_ns")
            pid = integer(event.get("pid"), "pid")
            require(pid > 0 and pid not in (os.getpid(), process.pid), "invalid loaded PID")
            try:
                require(os.getpgid(pid) == process.pid, "loaded PID is not in probe process group")
            except ProcessLookupError as error:
                raise BenchFailure("loaded PID already exited") from error
            record["loaded_rss_bytes"] = sample_loaded_rss(pid, deadline, end, record)
            if record["loaded_rss_bytes"] is None:
                raise BenchFailure("loaded RSS unavailable", "measurement_incomplete")
            process.stdin.write(b"continue\n")
            process.stdin.flush()
        elif ordinal in (2, 3):
            stage = "loaded" if ordinal == 2 else "edited"
            require(event.get("event") == "audit" and event.get("stage") == stage,
                    f"missing {stage} audit marker")
            require("audit" not in event or event["audit"] is True, f"{stage} audit failed")
        elif ordinal == 4:
            validate_complete(event, size)
        else:
            raise BenchFailure("extra probe event")
    return receive


def sha256_file(path, deadline):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while True:
            deadline.remaining()
            chunk = source.read(1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
    deadline.remaining()
    return digest.hexdigest()


def source_metadata(deadline):
    root = Path(__file__).resolve().parents[1]
    files = [root / name for name in ("Cargo.toml", "Cargo.lock")]
    for directory in ("src", "tests", "tools"):
        for path in (root / directory).rglob("*"):
            deadline.remaining()
            if path.is_file() and path.suffix in (".rs", ".py"):
                files.append(path)
    hashes = {str(path.relative_to(root)): sha256_file(path, deadline) for path in sorted(files)}
    digest = hashlib.sha256(json.dumps(hashes, sort_keys=True).encode("utf-8")).hexdigest()
    return {"sha256": digest, "files": hashes}


def metadata(binary, deadline):
    return {
        "os": platform.platform(), "cpu": bounded_output(
            ["sysctl", "-n", "machdep.cpu.brand_string"], deadline),
        "rustc": bounded_output(["rustc", "--version"], deadline),
        "binary": {"path": str(binary), "sha256": sha256_file(binary, deadline)},
        "source": source_metadata(deadline),
        "build": {
            "expected_command": "cargo build --release --manifest-path prototypes/rust_world/Cargo.toml",
            "profile": "release",
            "flags": "expected Cargo release defaults; no driver-added flags; actual build unattested",
            "binary_build_provenance": "unattested; supplied binary is not built by this driver",
            "environment": {key: value for key, value in sorted(os.environ.items())
                            if key in ("RUSTFLAGS", "CARGO_ENCODED_RUSTFLAGS", "CARGO_BUILD_TARGET")
                            or key.startswith("CARGO_PROFILE_RELEASE_")},
        },
        "file_cache": "uncontrolled; independent-process loads, not cold-disk measurements",
    }


def new_record(kind, size, index=None):
    label = "x".join(map(str, size))
    stem = f"{label}-{kind}" + (f"-{index}" if index is not None else "")
    return {"kind": kind, "size": list(size), "run": index, "status": "measurement_incomplete",
            "stdout": stem + ".stdout.log", "stderr": stem + ".stderr.log",
            "events": [], "loaded_rss_bytes": None, "peak_rss_bytes": None}


def write_json(path, value):
    with path.open("w", encoding="utf-8") as output:
        json.dump(value, output, indent=2, allow_nan=False)
        output.write("\n")


def execute_record(record, command, output, deadline):
    try:
        callback = protocol_callback(record["kind"], tuple(record["size"]), record, deadline)
        run_process(command, output / record["stdout"], output / record["stderr"],
                    deadline, callback, record)
        expected = 1 if record["kind"] == "generate" else 4
        require(len(record["events"]) == expected, "missing success/audit marker")
        if record["kind"] == "probe":
            record["peak_rss_bytes"] = parse_peak_rss((output / record["stderr"]).read_text())
            if record["peak_rss_bytes"] is None:
                raise BenchFailure("Darwin peak RSS unavailable", "measurement_incomplete")
        record["status"] = "ok"
    except BenchFailure as error:
        record["status"] = error.status
        record["error"] = str(error)
        raise
    except (OSError, UnicodeError) as error:
        record["error"] = str(error)
        record["status"] = "measurement_incomplete"
        raise BenchFailure(str(error), "measurement_incomplete") from error


def append_record(output, record):
    with (output / "runs.jsonl").open("a", encoding="utf-8") as log:
        log.write(json.dumps(record, allow_nan=False) + "\n")
        log.flush()


def finish_distributions(summary):
    for scale in summary["scales"]:
        probes = scale["probes"]
        if len(probes) == 3 and all(run["status"] == "ok" for run in probes):
            loads = [run["events"][0]["load_ns"] for run in probes]
            scale["load_ns"] = {"per_run": loads, "min": min(loads),
                                "median": statistics.median(loads), "max": max(loads)}
        for run in probes:
            if run["status"] == "ok":
                final = run["events"][-1]
                run["distributions"] = {
                    name: distribution(final[name]["samples_ns"])
                    for name in ("unchanged", "edit", "moving") if final[name] is not None}


def budget_failures(summary):
    million = summary["scales"][-1]
    failures = []
    if million["generated"]["events"][0]["save_ns"] > 1000000000:
        failures.append("million: diagnostic save_ns > 1000000000")
    for run in million["probes"]:
        label = f"million run {run['run']}"
        for name, value, limit in (
            ("load_ns", run["events"][0]["load_ns"], 1000000000),
            ("first_ns", run["events"][-1]["first_ns"], 2000000),
            ("edit_p95_ns", run["distributions"]["edit"]["p95_ns"], 2000000),
            ("moving_p95_ns", run["distributions"]["moving"]["p95_ns"], 2000000),
            ("peak_rss_bytes", run["peak_rss_bytes"], 256 * 1024 ** 2),
        ):
            if value > limit:
                failures.append(f"{label}: {name}={value} > {limit}")
    return failures


def run_batch(binary, output, deadline, summary):
    summary["metadata_before"] = metadata(binary, deadline)
    binary_digest = summary["metadata_before"]["binary"]["sha256"]
    for size in SCALES:
        deadline.remaining()
        world = output / ("x".join(map(str, size)) + ".world")
        scale = {"size": list(size), "population": math.prod(size),
                 "input": {"path": world.name}, "probes": []}
        summary["scales"].append(scale)
        generated = new_record("generate", size)
        scale["generated"] = generated
        try:
            require(sha256_file(binary, deadline) == binary_digest, "binary identity changed")
            execute_record(generated, [str(binary), "generate", "--size", ",".join(map(str, size)),
                                      "--seed", str(SEED), "--output", str(world)], output, deadline)
            require(world.is_file(), "generated input file missing")
            digest = sha256_file(world, deadline)
            scale["input"].update(sha256_before=digest, bytes=world.stat().st_size)
        except BenchFailure as error:
            generated.update(status=error.status, error=str(error))
            raise
        finally:
            append_record(output, generated)
        for index in range(1, 4):
            deadline.remaining()
            run = new_record("probe", size, index)
            scale["probes"].append(run)
            try:
                require(sha256_file(world, deadline) == digest, "input identity changed before probe")
                require(sha256_file(binary, deadline) == binary_digest, "binary identity changed")
                run["input_sha256_before"] = digest
                execute_record(run, ["/usr/bin/time", "-l", str(binary), "probe", "--input",
                                     str(world), "--warmup", str(WARMUP), "--samples", str(SAMPLES)],
                               output, deadline)
                run["input_sha256_after"] = sha256_file(world, deadline)
                require(run["input_sha256_after"] == digest, "input identity changed after probe")
                require(sha256_file(binary, deadline) == binary_digest, "binary identity changed")
            except BenchFailure as error:
                run.update(status=error.status, error=str(error))
                raise
            finally:
                append_record(output, run)
        scale["input"]["sha256_after"] = sha256_file(world, deadline)
        require(scale["input"]["sha256_after"] == digest, "input identity changed")
    summary["metadata_after"] = metadata(binary, deadline)
    require(summary["metadata_before"]["binary"] == summary["metadata_after"]["binary"],
            "binary identity changed during batch")
    require(summary["metadata_before"]["source"] == summary["metadata_after"]["source"],
            "source identity changed during batch")
    # Recheck earlier scales as well, after all runs.
    for scale in summary["scales"]:
        after = sha256_file(output / scale["input"]["path"], deadline)
        scale["input"]["sha256_after"] = after
        require(after == scale["input"]["sha256_before"], "input identity changed during batch")
    finish_distributions(summary)
    summary["budget_failures"] = budget_failures(summary)
    summary["status"] = "budget_not_met" if summary["budget_failures"] else "a_passed"
    deadline.remaining()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--timeout-seconds", type=float, default=30)
    parser.add_argument("--total-timeout-seconds", type=float, default=300)
    arguments = parser.parse_args(argv)
    if arguments.runs != 3:
        parser.error("--runs must be 3 for the formal A experiment")
    for name, value, maximum in (("--timeout-seconds", arguments.timeout_seconds, 30),
                                 ("--total-timeout-seconds", arguments.total_timeout_seconds, 300)):
        if not math.isfinite(value) or not 0 < value <= maximum:
            parser.error(f"{name} must be positive and <= {maximum}")
    deadline = Deadline(arguments.total_timeout_seconds, arguments.timeout_seconds)
    summary = {"status": "measurement_incomplete", "seed": SEED, "warmup": WARMUP,
               "samples": SAMPLES, "runs": 3, "scales": [], "budget_failures": [],
               "timeout_seconds": arguments.timeout_seconds,
               "total_timeout_seconds": arguments.total_timeout_seconds}
    try:
        arguments.output.mkdir(parents=True, exist_ok=False)
    except OSError as error:
        print(f"output directory must be new: {error}", file=sys.stderr)
        return 1
    (arguments.output / "runs.jsonl").touch(exist_ok=False)
    try:
        with batch_alarm(deadline):
            if sys.platform != "darwin":
                raise BenchFailure("formal RSS collection requires Darwin", "measurement_incomplete")
            binary = arguments.binary.resolve(strict=True)
            if not binary.is_file() or not os.access(binary, os.X_OK):
                raise BenchFailure("binary is not executable", "measurement_incomplete")
            run_batch(binary, arguments.output, deadline, summary)
    except BenchFailure as error:
        summary.update(status=error.status, error=str(error))
    except (OSError, UnicodeError, ValueError) as error:
        summary.update(status="measurement_incomplete", error=str(error))
    except KeyboardInterrupt:
        summary.update(status="measurement_incomplete", error="batch interrupted")
    finally:
        summary["elapsed_seconds"] = arguments.total_timeout_seconds - (
            deadline.expires - time.monotonic())
        write_json(arguments.output / "summary.json", summary)
    print(f"{summary['status']}: {arguments.output / 'summary.json'}")
    return 0 if summary["status"] == "a_passed" else 1


if __name__ == "__main__":
    sys.exit(main())
