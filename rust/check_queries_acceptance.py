#!/usr/bin/env python3
"""Require ray coverage, fixed inputs and observed hit faces to fail closed."""
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
                       "--test", "queries_oracle", "--no-run", "--message-format=json"],
                      logs / "queries_test_artifacts.log")
    if code:
        raise RuntimeError("building ray acceptance failed")
    artifacts = [json.loads(line) for line in output.splitlines() if line.startswith("{")]
    executables = [artifact["executable"] for artifact in artifacts
                   if artifact.get("reason") == "compiler-artifact"
                   and artifact.get("executable") and artifact["target"]["name"] == "queries_oracle"]
    if len(executables) != 1:
        raise RuntimeError("expected one ray test executable")
    lines = observations.read_text().splitlines()
    variants = {
        "zero_inputs": ([line.split()[0] + " 0 0 0 0 0 0 5 none" for line in lines], "oracle input"),
        "missing": (lines[:-1], "missing oracle samples"),
        "duplicate": (lines + lines[:1], "duplicate sample"),
    }
    wrong_face = lines.copy()
    index = next(index for index, line in enumerate(lines) if len(line.split()) == 18)
    fields = wrong_face[index].split()
    fields[11] = str(int(fields[11]) + 1)
    wrong_face[index] = " ".join(fields)
    variants["wrong_face"] = (wrong_face, "left == right")
    for name, (rows, reason) in variants.items():
        path = logs / f"queries-{name}.txt"
        path.write_text("\n".join(rows) + "\n")
        code, output = run([executables[0]], logs / f"queries-{name}.log",
                           dict(os.environ, FACTORY_QUERIES_ORACLE=str(path)))
        if code != 101 or reason not in output:
            raise RuntimeError(f"ray oracle did not correctly reject {name}; exited {code}")
    print("QUERIES_ACCEPTANCE_PROBES_PASS")


if __name__ == "__main__":
    main()
