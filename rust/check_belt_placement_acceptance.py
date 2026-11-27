#!/usr/bin/env python3
"""Prove missing, duplicate and corrupted planner observations fail closed."""
import json
import os
from pathlib import Path
import sys

from check_world_acceptance import run


def main():
    observations, logs = map(Path, sys.argv[1:])
    manifest = Path(__file__).resolve().parent / "Cargo.toml"
    code, output = run(["cargo", "test", "--locked", "--manifest-path", str(manifest),
                       "-p", "factory_core", "--features", "godot_oracle",
                       "--test", "belt_placement_oracle", "--no-run", "--message-format=json"],
                      logs / "belt_placement_test_artifacts.log")
    if code:
        raise RuntimeError("building belt planning acceptance failed")
    artifacts = [json.loads(line) for line in output.splitlines() if line.startswith("{")]
    executables = [artifact["executable"] for artifact in artifacts
                   if artifact.get("reason") == "compiler-artifact"
                   and artifact.get("executable")
                   and artifact["target"]["name"] == "belt_placement_oracle"]
    if len(executables) != 1:
        raise RuntimeError("expected one belt planning executable")
    lines = observations.read_text().splitlines()
    if len(lines) != 6592:
        raise RuntimeError("incomplete planner observations")
    variants = {
        "missing": (lines[:-1], "missing plans"),
        "duplicate": (lines + lines[:1], "duplicate plan"),
        "unknown": (["unknown " + lines[0].split(" ", 1)[1]] + lines[1:], "plan: unknown"),
    }
    for field, name in [(1, "status"), (2, "path"), (3, "locked"), (4, "active")]:
        changed = lines.copy()
        index = next(index for index, line in enumerate(lines)
                     if line.split()[1] == "ok" and line.split()[2] != "_")
        values = changed[index].split()
        values[field] = {"status": "Occupied", "path": "_", "locked": "_", "active": "0"}[name]
        changed[index] = " ".join(values)
        variants[name] = (changed, "left == right")
    for name, (rows, reason) in variants.items():
        path = logs / f"belt-placement-{name}.txt"
        path.write_text("\n".join(rows) + "\n")
        code, output = run([executables[0]], logs / f"belt-placement-{name}.log",
                           dict(os.environ, FACTORY_BELT_PLACEMENT_ORACLE=str(path)))
        if code != 101 or reason not in output:
            raise RuntimeError(f"planner oracle did not reject {name}; exited {code}")
    print("BELT_PLACEMENT_ACCEPTANCE_PROBES_PASS")


if __name__ == "__main__":
    main()
