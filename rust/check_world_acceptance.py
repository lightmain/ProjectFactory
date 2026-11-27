#!/usr/bin/env python3
"""Observe the dedicated structure process and reject damaged oracle coverage."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys


def run(command, log, environment=None):
    with log.open("w") as output:
        result = subprocess.run(command, stdout=output, stderr=subprocess.STDOUT,
                                env=environment, timeout=90)
    return result.returncode, log.read_text()


def main():
    observations, logs = map(Path, sys.argv[1:])
    manifest = Path(__file__).resolve().parent / "Cargo.toml"
    code, output = run(["cargo", "test", "--locked", "--manifest-path", str(manifest),
                        "-p", "factory_core", "--features", "godot_oracle",
                        "--no-run", "--message-format=json"], logs / "world_test_artifacts.log")
    if code:
        raise RuntimeError("building world acceptance failed")
    artifacts = {}
    for line in output.splitlines():
        if not line.startswith("{"):
            continue
        artifact = json.loads(line)
        if artifact.get("reason") == "compiler-artifact" and artifact.get("executable"):
            artifacts[artifact["target"]["name"]] = artifact["executable"]
    code, output = run(["/usr/bin/time", "-l", artifacts["world"],
                        "thousands_of_structures_keep_exact_owners_across_chunks", "--exact", "--nocapture"],
                       logs / "structure_process.log")
    rss = re.search(r"^\s*(\d+)\s+maximum resident set size\s*$", output, re.MULTILINE)
    payload = re.search(r"M02_STRUCTURE_DATA records=(\d+) owners=(\d+) structure_payload_bytes=(\d+) "
                        r"owner_payload_bytes=(\d+) block_page_bytes=(\d+)", output)
    if code or rss is None or payload is None:
        raise RuntimeError("dedicated structure process did not provide memory observations")
    values = list(map(int, payload.groups()))
    if values[:2] != [4096, 110592]:
        raise RuntimeError("structure population differs from acceptance")
    report = dict(zip(["structures", "owners", "structure_payload_bytes",
                       "owner_payload_bytes", "block_page_bytes"], values))
    report["process_max_rss_bytes"] = int(rss[1])
    report["scope"] = "dedicated Rust test process; payload excludes BTree node overhead"
    (logs / "structure_memory.json").write_text(json.dumps(report, indent=2) + "\n")
    lines = observations.read_text().splitlines()
    variants = {}
    duplicate = lines.copy()
    world_rows = [index for index, line in enumerate(lines) if line.startswith("world ")]
    duplicate[world_rows[1]] = duplicate[world_rows[0]]
    variants["duplicate"] = (duplicate, "duplicate oracle observation")
    absent = lines.copy()
    index = next(index for index, line in enumerate(lines) if line.startswith("world edited "))
    fields = absent[index].split()
    position = fields[4].index("01")
    fields[4] = fields[4][:position] + "00" + fields[4][position + 2:]
    absent[index] = " ".join(fields)
    variants["missing_owner"] = (absent, "owner presence edited")
    elevation = lines.copy()
    index = next(index for index, line in enumerate(lines) if line.startswith("elevation "))
    fields = elevation[index].split()
    fields[4] = str(float(fields[4]) + 0.25)
    elevation[index] = " ".join(fields)
    variants["wrong_elevation"] = (elevation, "elevation ")
    for name, (rows, reason) in variants.items():
        path = logs / f"world-{name}.txt"
        path.write_text("\n".join(rows) + "\n")
        environment = dict(os.environ, FACTORY_WORLD_ORACLE=str(path))
        code, output = run([artifacts["world_oracle"]], logs / f"world-{name}.log", environment)
        if code != 101 or reason not in output:
            raise RuntimeError(f"world oracle did not correctly reject {name}")
    print("WORLD_ACCEPTANCE_PROBES_PASS")


if __name__ == "__main__":
    main()
