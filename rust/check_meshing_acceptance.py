#!/usr/bin/env python3
"""Require complete independent mesh observations and reject corrupt attributes."""
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
                       "--test", "meshing_oracle", "--no-run", "--message-format=json"],
                      logs / "meshing_test_artifacts.log")
    if code:
        raise RuntimeError("building mesh acceptance failed")
    artifacts = [json.loads(line) for line in output.splitlines() if line.startswith("{")]
    executables = [artifact["executable"] for artifact in artifacts
                   if artifact.get("reason") == "compiler-artifact"
                   and artifact.get("executable") and artifact["target"]["name"] == "meshing_oracle"]
    if len(executables) != 1:
        raise RuntimeError("expected one mesh test executable")
    lines = observations.read_text().splitlines()
    headers = [i for i, line in enumerate(lines) if line.startswith("mesh ")]
    vertices = [i for i, line in enumerate(lines) if line.startswith("vertex ")]
    if len(headers) != 123 or not vertices:
        raise RuntimeError("incomplete mesh observations")
    variants = {
        "missing_mesh": ([line for i, line in enumerate(lines) if i != headers[0]],
                         "missing oracle meshes"),
        "missing_vertex": ([line for i, line in enumerate(lines) if i != vertices[0]],
                           "missing oracle vertices"),
        "duplicate_mesh": (lines + [lines[headers[0]]], "duplicate mesh header"),
        "duplicate_vertex": (lines + [lines[vertices[0]]], "duplicate mesh vertex"),
    }
    unknown = lines.copy()
    fields = unknown[headers[0]].split()
    fields[1] = "unknown"
    unknown[headers[0]] = " ".join(fields)
    variants["unknown"] = (unknown, "unknown oracle fixture")
    # Position, normal, color, UV and CUSTOM0 must each be observed independently.
    for name, field in [("position", 6), ("normal", 9), ("color", 12),
                        ("uv", 16), ("custom", 18)]:
        changed = lines.copy()
        fields = changed[vertices[0]].split()
        fields[field] = str(float(fields[field]) + 0.25)
        changed[vertices[0]] = " ".join(fields)
        variants[name] = (changed, "expected")
    for name, (rows, reason) in variants.items():
        path = logs / f"meshing-{name}.txt"
        path.write_text("\n".join(rows) + "\n")
        code, output = run([executables[0]], logs / f"meshing-{name}.log",
                           dict(os.environ, FACTORY_MESHING_ORACLE=str(path)))
        if code != 101 or reason not in output:
            raise RuntimeError(f"mesh oracle did not correctly reject {name}; exited {code}")
    print("MESHING_ACCEPTANCE_PROBES_PASS")


if __name__ == "__main__":
    main()
