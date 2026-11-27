#!/usr/bin/env python3
"""Validate measurement boundaries and the timing-to-workload association."""
import json
import math
import pathlib
import re
import sys


def check(directory):
    directory = pathlib.Path(directory)
    report = json.loads((directory / "performance.json").read_text())
    times = json.loads((directory / "samples.json").read_text())
    rows = json.loads((directory / "work_samples.json").read_text())
    count = report["logic_ticks"]
    assert count > 0 and len(rows) == count
    assert all(len(values) == count for values in times.values())
    assert len(set(row["tick"] for row in rows)) == count
    assert all(rows[i + 1]["tick"] == rows[i]["tick"] + 1 for i in range(count - 1))
    for frame, interval in zip(times["frame"], times["process_interval"]):
        assert interval >= frame, (frame, interval)
    assert math.isclose(sum(times["process_interval"]) / 1000, report["wall_seconds"], abs_tol=0.000002)
    for population in [report["window_start"], report["window_end"]]:
        assert population["total"] == population["inventory"] + population["on_belt"]
    assert report["consumed_during_window"] == report["window_end"]["sink"] - report["window_start"]["sink"]
    assert report["generated_inventory_during_window"] == report["window_end"]["total"] - report["window_start"]["total"]
    if report["route"].get("fixture") == "complex_v1":
        assert report["route"]["belts"] == 34 and report["route"]["seed"] == 0
        assert re.fullmatch("[0-9a-f]{64}", report["route"]["topology_sha256"])
        assert report["route"]["loops"] == 3 and report["route"]["merges"] == 2
        assert report["route"]["miners"] == 3 and report["route"]["chests"] == 4
    else:
        assert report["route"]["belts"] == report["route"]["visited_belts"]
    if report["display"] != "headless":
        assert all(isinstance(row.get("window_focused"), bool) for row in rows)
        assert report["drawn_frames_during_window"] > 0
        assert (directory / "run.png").is_file()
        assert report["load_to_first_draw_seconds"] >= report["load_to_first_actionable_seconds"]
    assert report["load_to_first_actionable_seconds"] >= (
        report["disk_load_decode_seconds"] + report["mount_seconds"])
    phases = json.loads((directory / "phases.json").read_text())
    assert phases["trace_complete"] and phases["exit_code"] == 0 and not phases["timed_out"]
    assert not phases.get("rss_limit_exceeded", False)
    assert phases.get("stop_reason", "completed") == "completed"
    assert phases["rss_samples"] and all(row["rss_bytes"] > 0 for row in phases["rss_samples"])
    resource_fields = {"timeout_seconds", "max_rss_bytes", "stop_reason", "rss_limit_exceeded"}
    if resource_fields.intersection(phases):
        assert resource_fields.issubset(phases), "Incomplete resource limit metadata"
        assert phases["timed_out"] is False and phases["rss_limit_exceeded"] is False
        timeout = phases["timeout_seconds"]
        assert (isinstance(timeout, (int, float)) and not isinstance(timeout, bool)
                and math.isfinite(timeout) and timeout > 0)
        limit = phases["max_rss_bytes"]
        if limit is not None:
            assert isinstance(limit, int) and not isinstance(limit, bool) and limit > 0
            observed = [row["rss_bytes"] for row in phases["rss_samples"]]
            observed.extend(phases["operation_peak_rss_bytes"].values())
            observed.extend(event["observed_rss_bytes"] for event in phases.get("boundaries", [])
                            if event.get("observed_rss_bytes") is not None)
            assert all(rss <= limit for rss in observed), "Observed RSS exceeds declared limit"
    for stage in phases["stages"].values():
        assert 0 <= stage["exclusive_usec"] <= stage["inclusive_usec"]
    for name, seconds in [("load_operation/load", report["disk_load_decode_seconds"]),
                          ("load_operation/mount", report["mount_seconds"]),
                          ("load_operation", report["load_to_first_actionable_seconds"])]:
        assert phases["stages"][name]["inclusive_usec"] >= seconds * 1_000_000 - 1
    peaks = phases["operation_peak_rss_bytes"]
    assert peaks.get("steady", 0) > 0 and peaks.get("load_operation", 0) > 0
    if report["mode"] == "independent_load":
        assert "build" not in phases["stages"] and "save_operation" not in phases["stages"]
        assert "route_audit" not in phases["stages"]
    else:
        assert peaks.get("save_operation", 0) > 0
        assert phases["stages"]["save_operation"]["inclusive_usec"] >= (
            report["save_operation_seconds"] * 1_000_000 - 1)
    switches = report["switches"]
    assert len(switches) == report["requested_switch_count"]
    previous_world = report["route"]["world_id"]
    for index, switch in enumerate(switches, 1):
        assert switch["different_world"] and switch["save_seconds"] > 0
        assert re.fullmatch("[0-9a-f]{32}", switch["world_id"])
        assert switch["world_id"] != previous_world
        previous_world = switch["world_id"]
        assert switch["objects"] > 0 and switch["static_bytes"] > 0
        assert isinstance(switch["work"], dict) and isinstance(switch["view"], dict)
        assert switch["settle_frames"] == 12
        assert switch["to_first_actionable_seconds"] >= (
            switch["decode_seconds"] + switch["mount_seconds"])
        for operation in ["save", "load", "settle"]:
            name = f"switch_{index}_{operation}"
            assert name in phases["stages"] and peaks.get(name, 0) > 0
    assert all("candidates" in row["view"] and "sample_return_ores" in row["work"] for row in rows)
    if report["backend"] == "rust":
        for counter, delta in report["native_transactions_during_window"].items():
            assert delta == rows[-1]["work"][counter] - report["window_start_work"][counter]
    print(f"NATIVE_PRESSURE_ACCOUNTING_PASS {directory} ({count} samples)")


if __name__ == "__main__":
    check(sys.argv[1])
