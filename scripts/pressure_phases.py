#!/usr/bin/env python3
"""Run one Godot process with bounded phase accounting and external RSS samples."""
import argparse
import json
import ctypes
import functools
import math
import pathlib
import struct
import subprocess
import sys
import threading
import time

from native_pressure_provenance import bind_fixture


class PhaseAccounting:
    def __init__(self):
        self.stack = []
        self.stages = {}
        self.peaks = {}
        self.events = []
        self.last_usec = -1
        self.lock = threading.Lock()

    def observe(self, event):
        name, entering, usec = event["phase"], event["entering"], event["usec"]
        with self.lock:
            if usec < self.last_usec or (not entering and
                    (not self.stack or self.stack[-1]["name"] != name)):
                raise ValueError(f"Invalid phase boundary: {event}")
            self.last_usec = usec
            self.events.append(event)
            if entering:
                path = "/".join([entry["name"] for entry in self.stack] + [name])
                self.stack.append({"name": name, "path": path, "start": usec, "child": 0})
            else:
                entry = self.stack.pop()
                duration = usec - entry["start"]
                stage = self.stages.setdefault(entry["path"], {
                    "calls": 0, "inclusive_usec": 0, "exclusive_usec": 0})
                stage["calls"] += 1
                stage["inclusive_usec"] += duration
                stage["exclusive_usec"] += duration - entry["child"]
                if self.stack:
                    self.stack[-1]["child"] += duration

    def sample_rss(self, rss):
        with self.lock:
            operation = self.stack[0]["name"] if self.stack else "between_phases"
            self.peaks[operation] = max(self.peaks.get(operation, 0), rss)
            return "/".join(entry["name"] for entry in self.stack)

    def finish(self):
        with self.lock:
            if self.stack:
                raise ValueError("Incomplete phase trace")
            return {"stages": self.stages, "operation_peak_rss_bytes": self.peaks,
                    "boundaries": self.events}


@functools.lru_cache(maxsize=1)
def macos_libproc():
    library = ctypes.CDLL("/usr/lib/libproc.dylib")
    library.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64,
                                    ctypes.c_void_p, ctypes.c_int]
    library.proc_pidinfo.restype = ctypes.c_int
    return library


def process_rss(pid):
    try:
        return _process_rss(pid)
    except (subprocess.CalledProcessError, OSError, ValueError):
        return None  # The process can exit between an event and the RSS query.


def _process_rss(pid):
    if sys.platform == "darwin":
        # proc_taskinfo: six uint64 fields followed by twelve int32 fields.
        # Unlike ps in this environment, libproc exposes the resident size.
        buffer = ctypes.create_string_buffer(96)
        if macos_libproc().proc_pidinfo(pid, 4, 0, buffer, len(buffer)) != len(buffer):
            return None
        return ctypes.c_uint64.from_buffer(buffer, 8).value or None
    value = subprocess.check_output(["ps", "-o", "rss=", "-p", str(pid)],
                                    stderr=subprocess.DEVNULL, text=True).strip()
    return int(value) * 1024 or None if value else None


def run(output, command, timeout_seconds=1800, max_rss_bytes=None):
    if (not isinstance(timeout_seconds, (int, float)) or isinstance(timeout_seconds, bool)
            or not math.isfinite(timeout_seconds) or timeout_seconds <= 0):
        raise ValueError("timeout_seconds must be positive and finite")
    if max_rss_bytes is not None and (
            not isinstance(max_rss_bytes, int) or isinstance(max_rss_bytes, bool)
            or max_rss_bytes <= 0):
        raise ValueError("max_rss_bytes must be a positive integer")
    accounting = PhaseAccounting()
    samples = []
    stop = threading.Event()
    stop_lock = threading.Lock()
    stop_reason = None
    process = subprocess.Popen(command, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, text=True, bufsize=1)
    start = time.monotonic()

    def expire(reason):
        nonlocal stop_reason
        with stop_lock:
            if stop_reason is not None:
                return
            if reason == "timeout" and process.poll() is not None:
                return
            stop_reason = reason
            # An observed RSS excess remains a failed run even if the child
            # finished while the OS query was returning its sample.
            if process.poll() is not None:
                return
            try:
                process.kill()
            except ProcessLookupError:
                pass  # The child can finish between poll and kill.

    def sample():
        while not stop.is_set():
            try:
                rss = process_rss(process.pid)
                if rss is not None:
                    samples.append({"seconds": time.monotonic() - start, "rss_bytes": rss,
                                    "phase": accounting.sample_rss(rss)})
                    if max_rss_bytes is not None and rss > max_rss_bytes:
                        expire("rss_limit")
                        return
            except (subprocess.CalledProcessError, OSError, ValueError):
                pass  # Exit can race the final ps sample.
            stop.wait(0.2)

    sampler = threading.Thread(target=sample, daemon=True)
    timer = threading.Timer(timeout_seconds, expire, args=("timeout",))
    sampler.start()
    timer.start()
    trace_error = None
    try:
        for line in process.stdout:
            sys.stdout.write(line)
            if line.startswith("PRESSURE_PHASE "):
                event = json.loads(line[len("PRESSURE_PHASE "):])
                rss = process_rss(process.pid)
                if rss is not None and not event["entering"]:
                    accounting.sample_rss(rss)
                event["observed_rss_bytes"] = rss
                accounting.observe(event)
                if rss is not None and event["entering"]:
                    accounting.sample_rss(rss)
                if rss is not None and max_rss_bytes is not None and rss > max_rss_bytes:
                    expire("rss_limit")
        status = process.wait()
    except (ValueError, KeyError, TypeError) as error:
        trace_error = str(error)
        if process.poll() is None:
            process.kill()
        status = process.wait()
    finally:
        timer.cancel()
        stop.set()
        sampler.join()
        process.stdout.close()
        if process.poll() is None:
            process.kill()
            process.wait()
    # Retain unsuccessful runs too, with an explicit incomplete trace marker.
    try:
        if trace_error is not None:
            raise ValueError(trace_error)
        result = accounting.finish()
        result["trace_complete"] = True
    except ValueError as error:
        result = {"trace_complete": False, "error": str(error),
                  "boundaries": accounting.events, "stages": accounting.stages,
                  "operation_peak_rss_bytes": accounting.peaks}
    result.update({"rss_samples": samples, "exit_code": status,
                   "timed_out": stop_reason == "timeout",
                   "rss_limit_exceeded": stop_reason == "rss_limit",
                   "stop_reason": stop_reason or (
                       "process_failed" if status else
                       "trace_invalid" if not result["trace_complete"] else "completed"),
                   "timeout_seconds": timeout_seconds, "max_rss_bytes": max_rss_bytes,
                   "command": command,
                   "sampling_interval_seconds": 0.2,
                   "cache_status": "OS cache uncontrolled; fresh process, no forced eviction",
                   "unobserved_rss_operations": sorted(
                       name for name in accounting.stages
                       if "/" not in name and name not in accounting.peaks),
                   "limits": [
                       "RSS sampling can miss peaks shorter than 200 ms.",
                       "The RSS limit stops a child after an observed over-limit sample; it is not an OS memory reservation.",
                       "Phase RSS is assigned by observed stdout boundaries.",
                       "static_bytes and objects are Godot monitors, not native allocation counts.",
                       "Inclusive child durations must not be added to parent durations.",
                   ]})
    steady = sorted(row["rss_bytes"] for row in samples if row["phase"] == "steady")
    result["steady_rss_bytes"] = {
        "samples": len(steady), "p50": steady[len(steady) // 2] if steady else None,
        "min": min(steady) if steady else None, "max": max(steady) if steady else None}
    performance = output.parent / "performance.json"
    try:
        if performance.is_file():
            report = json.loads(performance.read_text())
            save = pathlib.Path(report["save_directory"])
            pointer = save / "current"
            if pointer.is_file():
                bank = save / pointer.read_text()
                result["disk_files"] = []
                for path in sorted(bank.glob("*.bin")):
                    with path.open("rb") as stream:
                        header = stream.read(8)
                    result["disk_files"].append({
                        "file": path.name, "disk_bytes": path.stat().st_size,
                        "uncompressed_bytes": struct.unpack("<II", header)[1] if len(header) == 8 else None})
            if report["mode"] == "generate_save_load" and status == 0 and result["trace_complete"]:
                # External process, after engine exit; no extra full world or
                # checksum buffers inflate the player's save/load RSS.
                bind_fixture(save)
    except (OSError, ValueError, KeyError, TypeError) as error:
        result["metadata_error"] = str(error)
    if result["stop_reason"] == "completed":
        if "metadata_error" in result:
            result["stop_reason"] = "metadata_invalid"
        elif not samples:
            result["stop_reason"] = "rss_unavailable"
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(result, indent=2) + "\n")
    return status or (1 if result["stop_reason"] != "completed" else 0)


def main(arguments=None):
    arguments = list(sys.argv[1:] if arguments is None else arguments)
    parser = argparse.ArgumentParser(
        description=__doc__, usage="%(prog)s [OPTIONS] REPORT -- ENGINE [ARGS...]",
        allow_abbrev=False)
    parser.add_argument("--timeout-seconds", type=float, default=1800)
    parser.add_argument("--max-rss-bytes", type=int)
    parser.add_argument("report", type=pathlib.Path)
    if "--" not in arguments:
        parser.error("REPORT must be followed by -- ENGINE [ARGS...]")
    boundary = arguments.index("--")
    options = parser.parse_args(arguments[:boundary])
    command = arguments[boundary + 1:]
    if not command:
        parser.error("an engine command is required after --")
    try:
        return run(options.report, command, options.timeout_seconds, options.max_rss_bytes)
    except ValueError as error:
        parser.error(str(error))


if __name__ == "__main__":
    raise SystemExit(main())
