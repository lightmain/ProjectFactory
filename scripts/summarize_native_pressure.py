#!/usr/bin/env python3
"""Summarize all accepted runs, retaining each distribution and failed status."""
import collections
import hashlib
import json
from pathlib import Path
import statistics
import sys
from native_pressure_metrics import evidence_limits


def native_source_verified(provenance):
    build = provenance.get("native_build")
    if not isinstance(build, dict):
        return False
    binary = provenance.get("loaded_binary_sha256")
    descriptor = provenance.get("loaded_descriptor_sha256")
    source = build.get("source")
    return (
        isinstance(binary, str) and len(binary) == 64
        and binary == build.get("binary_sha256")
        and isinstance(descriptor, str) and len(descriptor) == 64
        and descriptor == build.get("descriptor_sha256")
        and bool(provenance.get("validated_library_entries"))
        and isinstance(source, dict)
        and isinstance(source.get("build_inputs_sha256"), str)
        and len(source["build_inputs_sha256"]) == 64
    )


root = Path(sys.argv[1])
groups = collections.defaultdict(list)
runs = json.loads((root / "runs.json").read_text())
for run in runs:
    mode = run.get("mode", "generate_save_load" if run["prefix"].endswith("-generate") else "independent_load")
    groups[(run["backend"], run["case"], mode, run["track"])]
    if run["status"]:
        continue
    directory = root / run["prefix"] / run["case"]
    report = json.loads((directory / "performance.json").read_text())
    phases = json.loads((directory / "phases.json").read_text())
    work = json.loads((directory / "work_samples.json").read_text())
    provenance = json.loads((root / run["prefix"] / "provenance.json").read_text())
    archive = provenance.get("input_save", {})
    if report["mode"] == "generate_save_load":
        certificate = directory / "fixture_manifest.json"
        archive = json.loads(certificate.read_text()).get("files", {}) if certificate.is_file() else {}
    lifecycle_required = report["mode"] == "independent_load" and run["track"] == "fixed"
    focused = {sample.get("window_focused") for sample in work}
    focus_state = "headless" if report["display"] == "headless" else (
        "focused" if focused == {True} else "unfocused" if focused == {False} else "mixed_or_unknown")
    workload = [archive, provenance.get("alternate_save", {}),
                report["route"], report["window_start"], report["window_end"],
                report["native_transactions_during_window"],
                [[sample["camera_position"], sample["view"].get("candidates"),
                  sample["view"].get("display_requested_rows"),
                  sample["view"].get("visible_items")] for sample in work]]
    workload_digest = hashlib.sha256(json.dumps(workload, sort_keys=True).encode()).hexdigest()
    # The first lifecycle save belongs to this group's measured world. Later
    # saves alternate worlds and clocks; never average them into this metric.
    player_save = report["switches"][0]["save_seconds"] if report["switches"] else None
    row = {
        "prefix": run["prefix"], "window_start": report["window_start"],
        "window_end": report["window_end"], "transactions": report["native_transactions_during_window"],
        "route": report["route"], "stages_ms": report["stages_ms"],
        "incoming_initial_entries": report["incoming_initial_entries"],
        "incoming_end_entries": report["last_work"].get("rust_incoming_entries"),
        "load_seconds": report["load_to_first_actionable_seconds"],
        "decode_seconds": report["disk_load_decode_seconds"],
        "mount_seconds": report["mount_seconds"],
        "save_seconds": report.get("save_operation_seconds"),
        "checkpoint_seconds": report.get("checkpoint_seconds"),
        "peak_rss_bytes": phases["operation_peak_rss_bytes"],
        "steady_rss_bytes": phases["steady_rss_bytes"],
        "phase_stages": phases["stages"], "disk_files": phases["disk_files"],
        "switches": report["switches"],
        "player_save_seconds": player_save,
        "player_save_peak_rss_bytes": phases["operation_peak_rss_bytes"].get("switch_1_save"),
        "archive_identified": bool(archive) and (
            not lifecycle_required or bool(provenance.get("alternate_save"))),
        "lifecycle_complete": not lifecycle_required or (
            run.get("lifecycle_expected") is True
            and report["requested_switch_count"] == 3 and len(report["switches"]) == 3),
        "source": [provenance["execution_project"]["inputs_sha256"],
                   provenance.get("loaded_binary_sha256", "unavailable")],
        "native_source_verified": native_source_verified(provenance),
        "workload_sha256": workload_digest, "focus_state": focus_state,
    }
    groups[(run["backend"], run["case"], report["mode"], run["track"])].append(row)

summary = {}
for key, rows in groups.items():
    values = {}
    for metric, getter in [
        ("load_seconds", lambda r: r["load_seconds"]),
        ("decode_seconds", lambda r: r["decode_seconds"]),
        ("mount_seconds", lambda r: r["mount_seconds"]),
        ("save_seconds", lambda r: r["save_seconds"]),
        ("checkpoint_seconds", lambda r: r["checkpoint_seconds"]),
        ("player_save_seconds", lambda r: r["player_save_seconds"]),
        ("player_save_peak_rss_bytes", lambda r: r["player_save_peak_rss_bytes"]),
        ("steady_rss_bytes", lambda r: r["steady_rss_bytes"]["p50"]),
        ("save_peak_rss_bytes", lambda r: r["peak_rss_bytes"].get("save_operation")),
        ("load_peak_rss_bytes", lambda r: r["peak_rss_bytes"].get("load_operation")),
        ("frame_p95_ms", lambda r: r["stages_ms"]["frame"]["p95"]),
        ("interval_p95_ms", lambda r: r["stages_ms"]["process_interval"]["p95"]),
    ]:
        samples = [getter(row) for row in rows if getter(row) is not None]
        values[metric] = {"samples": samples, "median": statistics.median(samples),
                          "min": min(samples), "max": max(samples)} if samples else None
    expected = [run for run in runs if (
        run["backend"], run["case"],
        run.get("mode", "generate_save_load" if run["prefix"].endswith("-generate") else "independent_load"),
        run["track"]) == key]
    reasons = []
    reasons.extend(evidence_limits(key[2], key[3], values, rows, len(expected)))
    if len(rows) < 3 or len(rows) != len(expected) or len({run["prefix"] for run in expected}) != len(expected):
        reasons.append("fewer than three unique successful independent runs or missing requested runs")
    if any(not row["lifecycle_complete"] for row in rows):
        reasons.append("required three-round player lifecycle missing")
    if any(not row["archive_identified"] for row in rows):
        reasons.append("actual input archive identity missing")
    if key[0] == "rust" and any(not row["native_source_verified"] for row in rows):
        reasons.append("validated native binary and build source missing")
    status = "incomplete" if reasons else "complete"
    if rows:
        for name in ["source", "workload_sha256", "focus_state"]:
            if any(row[name] != rows[0][name] for row in rows):
                reasons.append("unmatched " + name)
        if any(row["focus_state"] == "mixed_or_unknown" for row in rows):
            reasons.append("mixed or unknown graphical focus during measurement")
        if status == "complete" and reasons:
            status = "conditions_unmatched"
    summary["/".join(key)] = {"independent_runs": len(rows), "expected_runs": len(expected),
                             "comparison_status": status, "comparison_limits": reasons,
                             "metrics": values, "runs": rows}
result = {"groups": summary, "failed_runs": [run for run in runs if run["status"]],
          "cache_status": "OS cache uncontrolled; no eviction; sequential fresh processes"}
(root / "summary.json").write_text(json.dumps(result, indent=2) + "\n")
for key, group in summary.items():
    print(key, group["comparison_status"], group["comparison_limits"],
          json.dumps({metric: value["median"] if value else None
                           for metric, value in group["metrics"].items()}))
