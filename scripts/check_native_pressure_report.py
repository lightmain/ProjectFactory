#!/usr/bin/env python3
"""Validate measurement boundaries and the timing-to-workload association."""
import json
import math
import pathlib
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
    assert report["route"]["belts"] == report["route"]["visited_belts"]
    if report["display"] != "headless":
        assert report["drawn_frames_during_window"] > 0
        assert (directory / "run.png").is_file()
    assert all("candidates" in row["view"] and "sample_return_ores" in row["work"] for row in rows)
    if report["backend"] == "rust":
        for counter, delta in report["native_transactions_during_window"].items():
            assert delta == rows[-1]["work"][counter] - report["window_start_work"][counter]
    print(f"NATIVE_PRESSURE_ACCOUNTING_PASS {directory} ({count} samples)")


if __name__ == "__main__":
    check(sys.argv[1])
