#!/usr/bin/env python3
"""Generate synthetic fixtures with a copied Godot oracle and known native library."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
from verification_project import copy_project
from verify import run


def main():
    destination = ROOT / "rust/fixtures/legacy"
    if destination.exists():
        raise ValueError("fixtures already exist; existing golden bytes are preserved")
    logs = Path(tempfile.mkdtemp(prefix="factory-legacy-oracle-"))
    project = logs / "project"
    copy_project(ROOT, project)
    environment = dict(os.environ, PYTHONDONTWRITEBYTECODE="1",
                       BENCHMARK_PROJECT=str(project))
    engine = environment.get("GODOT_BIN", "godot")
    run([sys.executable, "-B", str(ROOT / "scripts/native_pressure_provenance.py"),
         str(logs / "raw-provenance.json"), "[]"], "provenance", logs, environment)
    raw = json.loads((logs / "raw-provenance.json").read_text())
    if not isinstance(raw.get("native_build"), dict):
        raise ValueError("the continuous oracle requires a verified RustConveyor installation")
    native = raw["native_build"]
    provenance = {
        "project_factory": raw["project_factory"],
        "execution_project": raw["execution_project"],
        "oracle_sha256": hashlib.sha256((ROOT / "rust/tests/legacy_oracle.gd").read_bytes()).hexdigest(),
        "loaded_binary_sha256": raw["loaded_binary_sha256"],
        "loaded_descriptor_sha256": raw["loaded_descriptor_sha256"],
        "native_build": {key: native[key] for key in
                         ["target", "profile", "rustc", "cargo", "source", "cargo_lock_sha256"]},
    }
    provenance_path = logs / "oracle-provenance.json"
    provenance_path.write_text(json.dumps(provenance, indent=2) + "\n")
    environment["FACTORY_ORACLE_PROVENANCE"] = str(provenance_path)
    run([engine, "--headless", "--disable-crash-handler", "--path", str(project), "--import"],
        "import", logs, environment, timeout=90)
    generated = logs / "golden"
    for mode in ["generate", "verify"]:
        run([engine, "--headless", "--disable-crash-handler", "--path", str(project), "-s",
             "res://rust/tests/legacy_oracle.gd", "--quit-after", "10", "--", mode, str(generated)],
            mode, logs, environment,
            marker="LEGACY_ORACLE_VERIFY_PASS" if mode == "verify" else None, timeout=120)
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(generated, destination)
    print(f"Generated legacy fixtures: {destination}\nOracle logs: {logs}")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, ValueError, subprocess.TimeoutExpired) as error:
        raise SystemExit(str(error)) from error
