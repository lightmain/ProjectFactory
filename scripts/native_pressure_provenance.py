#!/usr/bin/env python3
"""Capture source and loaded-library identities outside measured windows."""
import hashlib
import configparser
import json
import os
import pathlib
import platform
import subprocess
import sys


def fixture_files(save):
    save = pathlib.Path(save)
    bank = save / (save / "current").read_text()
    files = {}
    for path in sorted(bank.glob("*.bin")) + [save / "current", save.parent / "route.bin"]:
        with path.open("rb") as stream:
            digest = hashlib.sha256()
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(block)
        name = path.name if path == save.parent / "route.bin" else str(path.relative_to(save))
        files[name] = {"bytes": path.stat().st_size, "sha256": digest.hexdigest()}
    if not any(name.endswith(".bin") and "/" in name for name in files):
        raise ValueError("Fixture has no bank files")
    return files


def bind_fixture(save):
    save = pathlib.Path(save)
    (save.parent / "fixture_manifest.json").write_text(json.dumps(
        {"version": 1, "files": fixture_files(save)}, indent=2) + "\n")


def verify_fixture(save):
    save = pathlib.Path(save)
    manifest = json.loads((save.parent / "fixture_manifest.json").read_text())
    files = fixture_files(save)
    if manifest.get("version") != 1 or manifest.get("files") != files:
        raise ValueError("Factory certificate does not match the selected disk bank")
    return files


def source(root, roots, input_root=None):
    def git(*args):
        return subprocess.check_output(["git", *args], cwd=root)
    digest = hashlib.sha256()
    for raw in sorted(set(git("ls-files", "-z", "--cached", "--others", "--exclude-standard").split(b"\0"))):
        if not raw or raw.decode().split("/")[0] not in roots:
            continue
        path = (input_root or root) / raw.decode()
        if path.is_file():
            digest.update(raw + b"\0" + hashlib.sha256(path.read_bytes()).digest())
    return {"head": git("rev-parse", "HEAD").decode().strip(),
            "dirty": bool(git("status", "--porcelain")),
            "inputs_sha256": digest.hexdigest(), "included_roots": sorted(roots)}


def main():
    root = pathlib.Path(__file__).resolve().parent.parent
    output = pathlib.Path(sys.argv[1])
    execution_root = pathlib.Path(os.environ.get("BENCHMARK_PROJECT", root))
    addon = execution_root / "addons/rust_conveyor"
    build_path = addon / "build.json"
    manifest = {"project_factory": source(root, {"project.godot", "config", "scenes", "scripts", "assets", "addons"}),
                "native_build": "unavailable", "rust_conveyor_current_source": "unavailable",
                "invocations": json.loads(sys.argv[2])}
    manifest["execution_project"] = source(root, {"project.godot", "config", "scenes", "scripts", "assets", "addons"}, execution_root)
    if manifest["execution_project"]["inputs_sha256"] != manifest["project_factory"]["inputs_sha256"]:
        raise SystemExit("Benchmark project inputs differ from the recorded source")
    for environment_name, manifest_name in [("LOAD_SAVE", "input_save"),
                                            ("ALTERNATE_SAVE", "alternate_save")]:
        load_save = os.environ.get(environment_name)
        if not load_save:
            continue
        manifest[manifest_name] = verify_fixture(load_save)
    if build_path.is_file():
        build = json.loads(build_path.read_text())
        host_system = platform.system()
        host_arch = platform.machine().lower()
        targets = (
            {"aarch64-apple-darwin"} if host_system == "Darwin" and host_arch in {"arm64", "aarch64"} else
            {"x86_64-apple-darwin"} if host_system == "Darwin" and host_arch in {"x86_64", "amd64"} else
            {"x86_64-unknown-linux-gnu"} if host_system == "Linux" and host_arch in {"x86_64", "amd64"} else
            {"x86_64-pc-windows-msvc", "x86_64-pc-windows-gnu"} if host_system == "Windows" and host_arch in {"x86_64", "amd64"} else set()
        )
        if build["target"] not in targets:
            raise SystemExit("Native build target is incompatible with the executing host")
        descriptor = addon / "rust_conveyor.gdextension"
        descriptor_hash = hashlib.sha256(descriptor.read_bytes()).hexdigest()
        if descriptor_hash != build.get("descriptor_sha256"):
            raise SystemExit("Installed extension descriptor does not match its build manifest")
        godot_platform = ("macos" if host_system == "Darwin" else
                    "windows" if "windows" in build["target"] else "linux")
        suffix = "" if godot_platform == "macos" else ".x86_64"
        configuration = configparser.ConfigParser()
        configuration.read(descriptor)
        expected = "res://addons/rust_conveyor/" + build["binary"]
        for mode in ["debug", "release"]:
            if json.loads(configuration["libraries"][godot_platform + "." + mode + suffix]) != expected:
                raise SystemExit("Descriptor selects a library different from the recorded build")
        binary = addon / build["binary"]
        actual = hashlib.sha256(binary.read_bytes()).hexdigest()
        if actual != build["binary_sha256"]:
            raise SystemExit("Installed native binary does not match build manifest")
        manifest["native_build"] = build
        manifest["loaded_binary_sha256"] = actual
        manifest["loaded_descriptor_sha256"] = descriptor_hash
        manifest["validated_library_entries"] = [godot_platform + "." + mode + suffix for mode in ["debug", "release"]]
        manifest["execution_host"] = {"system": host_system, "arch": host_arch}
    elif addon.is_dir():
        manifest["unidentified_native_binaries"] = {
            path.name: hashlib.sha256(path.read_bytes()).hexdigest()
            for path in (addon / "bin").glob("*") if path.is_file()}
    rust_root = os.environ.get("RUST_CONVEYOR_SOURCE")
    if rust_root:
        manifest["rust_conveyor_current_source"] = source(
            pathlib.Path(rust_root), {"Cargo.toml", "Cargo.lock", "src", "godot"})
    output.write_text(json.dumps(manifest, indent=2) + "\n")


if __name__ == "__main__":
    main()
