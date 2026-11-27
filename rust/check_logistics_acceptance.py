#!/usr/bin/env python3
"""Check that missing or corrupted committed logistics observations fail."""
import json
import os
from pathlib import Path
import sys

from check_world_acceptance import run


def main():
    observations, logs = map(Path, sys.argv[1:])
    manifest = Path(__file__).resolve().parent / "Cargo.toml"
    code, output = run(
        ["cargo", "test", "--locked", "--manifest-path", str(manifest),
         "-p", "factory_core", "--features", "godot_oracle",
         "--test", "logistics_oracle", "--no-run", "--message-format=json"],
        logs / "logistics_test_artifacts.log")
    if code:
        raise RuntimeError("building logistics acceptance failed")
    artifacts = [json.loads(line) for line in output.splitlines() if line.startswith("{")]
    executables = [
        artifact["executable"] for artifact in artifacts
        if artifact.get("reason") == "compiler-artifact"
        and artifact.get("executable") and artifact["target"]["name"] == "logistics_oracle"
    ]
    if len(executables) != 1:
        raise RuntimeError("expected one logistics test executable")
    lines = observations.read_text().splitlines()
    variants = {
        "missing": lines[:-1],
        "duplicate": lines[:1] + lines,
    }
    changes = [
        ("clock", "S", 5, lambda value: str(int(value) + 1), lambda fields: True),
        ("inventory", "M", 5, lambda value: str(int(value) + 1), lambda fields: int(fields[5]) > 0),
        ("phase", "M", 13, lambda value: str(int(value) + 1), lambda fields: int(fields[13]) > 0),
        ("pending", "S", 8, lambda value: "0", lambda fields: fields[2] == "301"),
        ("edge", "M", 14, lambda value: "-", lambda fields: fields[14] != "-"),
        ("identity", "O", 1, lambda value: str(int(value) + 1), lambda fields: True),
        ("incoming", "O", 2, lambda value: str((int(value) + 1) % 4), lambda fields: True),
        ("progress", "O", 3, lambda value: "0000000000000000",
         lambda fields: fields[3] != "0000000000000000"),
    ]
    for name, kind, field, mutate, predicate in changes:
        rows = lines.copy()
        index = next(index for index, line in enumerate(rows)
                     if line.split()[0] == kind and predicate(line.split()))
        fields = rows[index].split()
        fields[field] = mutate(fields[field])
        rows[index] = " ".join(fields)
        variants[name] = rows
    for name, rows in variants.items():
        path = logs / f"logistics-{name}.txt"
        path.write_text("\n".join(rows) + "\n")
        code, output = run([executables[0]], logs / f"logistics-{name}.log",
                           dict(os.environ, FACTORY_LOGISTICS_ORACLE=str(path)))
        if code != 101 or "panicked at" not in output:
            raise RuntimeError(f"logistics oracle did not reject {name}; exited {code}")
    print("LOGISTICS_ACCEPTANCE_PROBES_PASS")


if __name__ == "__main__":
    main()
