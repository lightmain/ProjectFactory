#!/usr/bin/env python3
"""Compile and check the backend in isolated Godot projects."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def run(command, name, logs, environment, expected=0, marker=None, timeout=600):
    path = logs / (name + ".log")
    print(f"Checking {name}: {path}", flush=True)
    with path.open("w") as output:
        result = subprocess.run(command, cwd=ROOT, env=environment,
                                stdout=output, stderr=subprocess.STDOUT, timeout=timeout)
    text = path.read_text()
    if result.returncode != expected:
        raise RuntimeError(f"{name} exited {result.returncode}; see {path}")
    if "SCRIPT ERROR:" in text or "\nERROR:" in text:
        raise RuntimeError(f"{name} reported an engine error; see {path}")
    if marker and marker not in text.splitlines():
        raise RuntimeError(f"{name} did not report {marker}; see {path}")
    return text


def validate_engine_independence(metadata):
    packages = {package["id"]: package for package in metadata["packages"]}
    nodes = {node["id"]: node for node in metadata["resolve"]["nodes"]}
    for root_name in ["factory_core", "factory_cli"]:
        pending = [package["id"] for package in packages.values()
                   if package["name"] == root_name]
        seen = set()
        while pending:
            identity = pending.pop()
            if identity in seen:
                continue
            seen.add(identity)
            name = packages[identity]["name"]
            if name == "godot" or name.startswith("godot-") or name == "gdextension-api":
                raise RuntimeError(f"{root_name} has an engine dependency: {name}")
            pending.extend(nodes[identity]["dependencies"])


def validate_installation(destination, metadata):
    manifest = json.loads((destination / "build.json").read_text())
    from build import artifact_hash
    if artifact_hash(destination / manifest["binary"]) != manifest["binary_sha256"]:
        raise RuntimeError("installed library hash differs from the manifest")
    if artifact_hash(destination / "factory_backend.gdextension") != manifest["descriptor_sha256"]:
        raise RuntimeError("installed descriptor hash differs from the manifest")
    inventory = json.loads((destination / "THIRD_PARTY.json").read_text())
    packages = {package["name"]: package for package in metadata["packages"]}
    for package in inventory:
        for name in package["notices"]:
            if not (destination / name).is_file():
                raise RuntimeError(f"missing dependency notice: {name}")
        if package["license"] != "MPL-2.0":
            continue
        source = Path(packages[package["name"]]["manifest_path"]).parent
        archive_name = f'{package["name"]}-{package["version"]}'
        with tarfile.open(destination / "sources" / (archive_name + ".tar.gz")) as archive:
            members = {member.name: member for member in archive.getmembers()}
            for path in source.rglob("*"):
                if not path.is_file():
                    continue
                name = archive_name + "/" + path.relative_to(source).as_posix()
                if name not in members:
                    raise RuntimeError(f"incomplete MPL source: {name}")
                archived = archive.extractfile(members[name])
                if archived is None or archived.read() != path.read_bytes():
                    raise RuntimeError(f"modified MPL source: {name}")


def main():
    if sys.argv[1:] not in [[], ["--legacy"]]:
        raise ValueError("Usage: python3 rust/verify.py [--legacy]")
    logs = Path(tempfile.mkdtemp(prefix="factory-backend-check-"))
    environment = dict(os.environ, PYTHONDONTWRITEBYTECODE="1")
    environment.setdefault("CARGO_TARGET_DIR", str(logs / "cargo-target"))
    engine = environment.get("GODOT_BIN", "godot")
    print(f"Backend verification logs: {logs}", flush=True)
    manifest = str(ROOT / "rust/Cargo.toml")
    run(["cargo", "fmt", "--manifest-path", manifest, "--all", "--", "--check"],
        "format", logs, environment)
    run(["cargo", "test", "--locked", "--manifest-path", manifest, "--workspace"],
        "rust_tests", logs, environment)
    run(["cargo", "clippy", "--locked", "--manifest-path", manifest,
         "--workspace", "--all-targets", "--all-features", "--", "-D", "warnings"], "clippy", logs, environment)
    run([sys.executable, "-B", str(ROOT / "rust/test_install.py")],
        "install_boundaries", logs, environment)
    run([sys.executable, "-B", str(ROOT / "rust/test_compiled_identity.py")],
        "compiled_identity", logs, environment)
    metadata = json.loads(run(
        ["cargo", "metadata", "--locked", "--manifest-path", manifest, "--format-version", "1"],
        "metadata", logs, environment))
    validate_engine_independence(metadata)
    project = logs / "independent-project"
    project.mkdir()
    (project / "project.godot").write_text(
        '[application]\nconfig/name="FactoryBackend contract"\n'
        '[rendering]\nrenderer/rendering_method="gl_compatibility"\n')
    shutil.copy2(ROOT / "rust/tests/handshake.gd", project / "handshake.gd")

    def godot(name, arguments, expected=0, marker=None):
        return run([engine, "--headless", "--disable-crash-handler", "--path", str(project), *arguments],
                   name, logs, environment, expected, marker, timeout=90)

    godot("missing_import", ["--import"])
    godot("missing_library", ["-s", "res://handshake.gd", "--quit-after", "10"], 3,
          "FACTORY_BACKEND_MISSING_LIBRARY")
    run(["bash", str(ROOT / "rust/install.sh"), str(project), "debug"],
        "native_install", logs, environment)
    validate_installation(project / "native/factory_backend", metadata)
    # Godot 4.7.2 can crash when a newly discovered GDExtension is followed
    # immediately by editor shutdown. Exercise a normal editor lifetime first;
    # the subsequent --import must still succeed, with no ignored exit codes.
    godot("native_editor", ["--editor", "--quit-after", "120", "--max-fps", "60"])
    godot("native_import", ["--import"])
    godot("independent_handshake", ["-s", "res://handshake.gd", "--quit-after", "10"],
          marker="FACTORY_BACKEND_HANDSHAKE_PASS")
    shutil.copy2(ROOT / "rust/tests/synchronous.gd", project / "synchronous.gd")
    godot("synchronous_factory", ["-s", "res://synchronous.gd", "--quit-after", "600"],
          marker="FACTORY_SYNCHRONOUS_PASS")
    shutil.copy2(ROOT / "rust/tests/runtime.gd", project / "runtime.gd")
    godot("runtime_bridge", ["-s", "res://runtime.gd", "--quit-after", "600"],
          marker="FACTORY_RUNTIME_BRIDGE_PASS")
    shutil.copy2(ROOT / "rust/tests/runtime_queries.gd", project / "runtime_queries.gd")
    godot("runtime_queries_bridge", ["-s", "res://runtime_queries.gd", "--quit-after", "600"],
        marker="FACTORY_RUNTIME_QUERIES_PASS")
    shutil.copy2(ROOT / "rust/tests/runtime_display.gd", project / "runtime_display.gd")
    godot("runtime_display_bridge", ["-s", "res://runtime_display.gd", "--quit-after", "600"],
         marker="FACTORY_RUNTIME_DISPLAY_PASS")
    shutil.copy2(ROOT / "rust/tests/runtime_meshing.gd", project / "runtime_meshing.gd")
    godot("runtime_meshing_bridge", ["-s", "res://runtime_meshing.gd", "--quit-after", "600"],
          marker="FACTORY_RUNTIME_MESHING_PASS")
    old_addon = ROOT / "addons/rust_conveyor"
    if (old_addon / "rust_conveyor.gdextension").is_file():
        shutil.copytree(old_addon, project / "addons/rust_conveyor")
        godot("coexist_editor", ["--editor", "--quit-after", "120", "--max-fps", "60"])
        godot("coexist_import", ["--import"])
        godot("coexist_handshake", ["-s", "res://handshake.gd", "--quit-after", "10", "--", "--coexist"],
              marker="FACTORY_BACKEND_HANDSHAKE_PASS")
    else:
        print("Coexistence check unavailable: RustConveyor is not installed.", flush=True)
    # Use current Godot rules as an independent oracle, never ported Rust output.
    for name in ["voxel_world_data.gd", "snapshot_values.gd", "voxel_hit.gd", "voxel_raycast.gd"]:
        shutil.copy2(ROOT / "scripts/core" / name, project / name)
    shutil.copy2(ROOT / "rust/tests/world_oracle.gd", project / "world_oracle.gd")
    godot("world_import", ["--import"])
    observations = logs / "world-observations.txt"
    godot("world_oracle", ["-s", "res://world_oracle.gd", "--", str(observations)],
          marker="WORLD_ORACLE_PASS")
    oracle_environment = dict(environment, FACTORY_WORLD_ORACLE=str(observations))
    run(["cargo", "test", "--locked", "--manifest-path", manifest, "-p", "factory_core",
         "--features", "godot_oracle", "--test", "world_oracle"],
        "world_comparison", logs, oracle_environment)
    run([sys.executable, "-B", str(ROOT / "rust/check_world_acceptance.py"),
         str(observations), str(logs)], "world_acceptance_probes", logs, environment,
        marker="WORLD_ACCEPTANCE_PROBES_PASS")
    shutil.copy2(ROOT / "rust/tests/queries_oracle.gd", project / "queries_oracle.gd")
    godot("queries_import", ["--import"])
    ray_observations = logs / "queries-observations.txt"
    godot("queries_oracle", ["-s", "res://queries_oracle.gd", "--", str(ray_observations)],
          marker="QUERIES_ORACLE_PASS")
    run(["cargo", "test", "--locked", "--manifest-path", manifest, "-p", "factory_core",
         "--features", "godot_oracle", "--test", "queries_oracle"],
        "queries_comparison", logs, dict(environment, FACTORY_QUERIES_ORACLE=str(ray_observations)))
    run([sys.executable, "-B", str(ROOT / "rust/check_queries_acceptance.py"),
         str(ray_observations), str(logs)], "queries_acceptance_probes", logs, environment,
        marker="QUERIES_ACCEPTANCE_PROBES_PASS")
    shutil.copy2(ROOT / "scripts/core/orthogonal_route.gd", project / "orthogonal_route.gd")
    shutil.copy2(ROOT / "rust/tests/route_oracle.gd", project / "route_oracle.gd")
    godot("route_import", ["--import"])
    route_observations = logs / "route-observations.txt"
    godot("route_oracle", ["-s", "res://route_oracle.gd", "--", str(route_observations)],
          marker="ROUTE_ORACLE_PASS")
    run(["cargo", "test", "--locked", "--manifest-path", manifest, "-p", "factory_core",
         "--features", "godot_oracle", "--test", "route_oracle"],
        "route_comparison", logs, dict(environment, FACTORY_ROUTE_ORACLE=str(route_observations)))
    sys.path.insert(0, str(ROOT / "scripts"))
    from verification_project import copy_project
    planning_project = logs / "planning-project"
    copy_project(ROOT, planning_project)
    shutil.copytree(project / "native/factory_backend",
                    planning_project / "native/factory_backend", dirs_exist_ok=True)
    run([engine, "--headless", "--disable-crash-handler", "--path", str(planning_project),
         "--editor", "--quit-after", "120", "--max-fps", "60"],
        "planning_editor", logs, environment)
    run([engine, "--headless", "--disable-crash-handler", "--path", str(planning_project), "--import"],
        "planning_import", logs, environment)
    run([engine, "--headless", "--disable-crash-handler", "--path", str(planning_project), "-s",
         "res://rust/tests/runtime_mesh_oracle.gd", "--quit-after", "1200"],
        "runtime_mesh_oracle", logs, environment, marker="FACTORY_RUNTIME_MESH_ORACLE_PASS")
    meshes = logs / "meshing-observations.txt"
    run([engine, "--headless", "--disable-crash-handler", "--path", str(planning_project), "-s",
         "res://rust/tests/meshing_oracle.gd", "--", str(meshes)],
        "meshing_oracle", logs, environment, marker="MESHING_ORACLE_PASS")
    run(["cargo", "test", "--locked", "--manifest-path", manifest, "-p", "factory_core",
         "--features", "godot_oracle", "--test", "meshing_oracle"],
        "meshing_comparison", logs, dict(environment, FACTORY_MESHING_ORACLE=str(meshes)))
    run([sys.executable, "-B", str(ROOT / "rust/check_meshing_acceptance.py"),
         str(meshes), str(logs)], "meshing_acceptance_probes", logs, environment,
        marker="MESHING_ACCEPTANCE_PROBES_PASS")
    run([engine, "--headless", "--disable-crash-handler", "--path", str(planning_project), "-s",
         "res://rust/tests/playground.gd", "--quit-after", "600"],
        "playground", logs, environment, marker="FACTORY_PLAYGROUND_PASS")
    plans = logs / "belt-placement-observations.txt"
    run([engine, "--headless", "--disable-crash-handler", "--path", str(planning_project), "-s",
         "res://rust/tests/belt_placement_oracle.gd", "--", str(plans)],
        "belt_placement_oracle", logs, environment, marker="BELT_PLACEMENT_ORACLE_PASS")
    run(["cargo", "test", "--locked", "--manifest-path", manifest, "-p", "factory_core",
         "--features", "godot_oracle", "--test", "belt_placement_oracle"],
        "belt_placement_comparison", logs, dict(environment, FACTORY_BELT_PLACEMENT_ORACLE=str(plans)))
    run([sys.executable, "-B", str(ROOT / "rust/check_belt_placement_acceptance.py"),
         str(plans), str(logs)], "belt_placement_acceptance_probes", logs, environment,
        marker="BELT_PLACEMENT_ACCEPTANCE_PROBES_PASS")
    logistics = logs / "logistics-observations.txt"
    run([engine, "--headless", "--disable-crash-handler", "--path", str(planning_project), "-s",
         "res://rust/tests/logistics_oracle.gd", "--", str(logistics)],
        "logistics_oracle", logs, environment, marker="LOGISTICS_ORACLE_PASS")
    run(["cargo", "test", "--locked", "--manifest-path", manifest, "-p", "factory_core",
         "--features", "godot_oracle", "--test", "logistics_oracle"],
        "logistics_comparison", logs, dict(environment, FACTORY_LOGISTICS_ORACLE=str(logistics)))
    run([sys.executable, "-B", str(ROOT / "rust/check_logistics_acceptance.py"),
         str(logistics), str(logs)], "logistics_acceptance_probes", logs, environment,
        marker="LOGISTICS_ACCEPTANCE_PROBES_PASS")
    complex_logistics = logs / "logistics-complex-observations.txt"
    run([engine, "--headless", "--disable-crash-handler", "--path", str(planning_project), "-s",
         "res://rust/tests/logistics_complex_oracle.gd", "--", str(complex_logistics)],
        "logistics_complex_oracle", logs, environment, marker="LOGISTICS_COMPLEX_ORACLE_PASS")
    run(["cargo", "test", "--locked", "--manifest-path", manifest, "-p", "factory_core",
         "--features", "godot_oracle", "--test", "logistics_oracle"],
        "logistics_complex_comparison", logs,
        dict(environment, FACTORY_LOGISTICS_COMPLEX_ORACLE=str(complex_logistics)))
    if sys.argv[1:] == ["--legacy"]:
        run([sys.executable, "-B", str(ROOT / "rust/test_legacy_fixtures.py")],
            "legacy_byte_checks", logs, environment)
        sys.path.insert(0, str(ROOT / "scripts"))
        from verification_project import copy_project
        legacy_project = logs / "legacy-project"
        copy_project(ROOT, legacy_project)
        run([engine, "--headless", "--disable-crash-handler", "--path", str(legacy_project), "--import"],
            "legacy_import", logs, environment)
        run([engine, "--headless", "--disable-crash-handler", "--path", str(legacy_project), "-s",
             "res://rust/tests/legacy_oracle.gd", "--quit-after", "10", "--", "verify",
             str(ROOT / "rust/fixtures/legacy")], "legacy_replay", logs, environment,
            marker="LEGACY_ORACLE_VERIFY_PASS")
    print("FACTORY_BACKEND_VERIFY_PASS", flush=True)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, ValueError, subprocess.TimeoutExpired) as error:
        raise SystemExit(str(error)) from error
