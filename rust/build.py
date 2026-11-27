#!/usr/bin/env python3
"""Install Cargo's native artifact and its exact build identity and notices."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import tomllib

ROOT = Path(__file__).resolve().parent.parent


def source_identity(root):
    root = Path(root)
    digest = hashlib.sha256()
    for path in sorted((root / "rust").rglob("*")):
        relative = path.relative_to(root)
        if any(part in {"target", "__pycache__", ".godot"} for part in relative.parts):
            continue
        if path.is_file():
            digest.update(relative.as_posix().encode() + b"\0"
                          + hashlib.sha256(path.read_bytes()).digest())
    # Match factory_core's explicit sibling-source dependency. Hash only
    # package inputs, so unrelated viewer builds do not invalidate this backend.
    manifest = root / "rust/factory_core/Cargo.toml"
    dependency = (tomllib.loads(manifest.read_text()).get("dependencies", {}).get("rust_conveyor")
                  if manifest.is_file() else None)
    if dependency:
        conveyor = (manifest.parent / dependency["path"]).resolve()
        for path in sorted([conveyor / "Cargo.toml", conveyor / "Cargo.lock", conveyor / "LICENSE",
                            *(conveyor / "src").rglob("*.rs")]):
            relative = "rust_conveyor/" + path.relative_to(conveyor).as_posix()
            digest.update(relative.encode() + b"\0" + hashlib.sha256(path.read_bytes()).digest())
    lock = root / "rust/Cargo.lock"
    git_environment = {key: value for key, value in os.environ.items()
                       if not key.startswith("GIT_")}
    git = subprocess.run(["git", "rev-parse", "HEAD"], cwd=root,
                         capture_output=True, text=True, env=git_environment)
    status = subprocess.run(["git", "status", "--porcelain"], cwd=root,
                            capture_output=True, text=True, env=git_environment)
    return {
        "inputs_sha256": digest.hexdigest(),
        "lock_sha256": hashlib.sha256(lock.read_bytes()).hexdigest(),
        "commit": git.stdout.strip() if git.returncode == 0 else "unknown",
        "dirty": bool(status.stdout) if status.returncode == 0 else False,
    }


def install_destination(project):
    project = Path(project).resolve()
    if not (project / "project.godot").is_file():
        raise ValueError("destination requires project.godot")
    destination = project / "native/factory_backend"
    if destination.parent.is_symlink():
        raise ValueError("native installation parent must not be a symbolic link")
    if destination.exists() or destination.is_symlink():
        raise ValueError(f"installation already exists: {destination}")
    return destination


def validate_target(target):
    if target != "aarch64-apple-darwin":
        raise ValueError(f"unsupported native target: {target}")
    return target


def checked_output(command):
    return subprocess.check_output(command, cwd=ROOT, text=True).strip()


def native_artifact(messages):
    artifacts = []
    for line in messages.splitlines():
        message = json.loads(line)
        target = message.get("target") or {}
        if (message.get("reason") == "compiler-artifact"
                and target.get("name") == "factory_godot"
                and "cdylib" in (target.get("crate_types") or [])):
            artifacts.extend(Path(name) for name in message.get("filenames", [])
                             if Path(name).suffix == ".dylib")
    if len(artifacts) != 1 or not artifacts[0].is_file():
        raise ValueError("Cargo did not report exactly one native shared library")
    return artifacts[0]


def artifact_hash(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def dependency_notices(metadata, destination):
    packages = {package["id"]: package for package in metadata["packages"]}
    nodes = {node["id"]: node for node in metadata["resolve"]["nodes"]}
    pending = [package["id"] for package in packages.values()
               if package["name"] == "factory_godot"]
    identities = set()
    while pending:
        identity = pending.pop()
        if identity not in identities:
            identities.add(identity)
            pending.extend(nodes[identity]["dependencies"])
    notices = destination / "notices"
    notices.mkdir()
    inventory = []
    for identity in sorted(identities):
        package = packages[identity]
        if package["name"] in {"factory_core", "factory_godot"}:
            continue
        source = Path(package["manifest_path"]).parent
        files = {path for path in source.iterdir() if path.is_file()
                 and path.name.upper().startswith(
                     ("LICENSE", "COPYING", "COPYRIGHT", "NOTICE", "ATTRIBUTION"))}
        if package.get("license_file"):
            files.add(source / package["license_file"])
        copied = []
        for path in sorted(files):
            name = f'{package["name"]}-{package["version"]}-{path.name}'
            shutil.copy2(path, notices / name)
            copied.append("notices/" + name)
        if package.get("license") == "MPL-2.0":
            sources = destination / "sources"
            sources.mkdir(exist_ok=True)
            archive_name = f'{package["name"]}-{package["version"]}.tar.gz'
            with tarfile.open(sources / archive_name, "w:gz") as archive:
                archive.add(source, arcname=f'{package["name"]}-{package["version"]}')
            name = f'{package["name"]}-{package["version"]}-NOTICE.txt'
            (notices / name).write_text(
                f'{package["name"]} {package["version"]} is licensed under MPL-2.0.\n'
                'This dependency is unmodified. Its complete corresponding source,\n'
                f'including copyright/license headers, is in sources/{archive_name}.\n'
                'License: https://www.mozilla.org/MPL/2.0/ .\n')
            copied.append("notices/" + name)
        elif not copied and package["name"] == "nanoserde-derive":
            parent = next(value for value in packages.values()
                          if value["name"] == "nanoserde")
            path = Path(parent["manifest_path"]).parent / "LICENSE-MIT"
            name = f'nanoserde-derive-{package["version"]}-LICENSE-MIT'
            shutil.copy2(path, notices / name)
            copied.append("notices/" + name)
        if not copied:
            raise ValueError(f'unresolved license notices: {package["name"]}')
        inventory.append({"name": package["name"], "version": package["version"],
                          "license": package.get("license"), "notices": copied})
    (destination / "THIRD_PARTY.json").write_text(
        json.dumps(inventory, indent=2) + "\n")


def install(project, profile):
    if profile not in {"debug", "release"}:
        raise ValueError("profile must be debug or release")
    destination = install_destination(project)
    rustc = checked_output([os.environ.get("RUSTC", "rustc"), "-vV"])
    target = validate_target(next(line[6:] for line in rustc.splitlines()
                                  if line.startswith("host: ")))
    identity = source_identity(ROOT)
    metadata = json.loads(checked_output([
        "cargo", "metadata", "--locked", "--manifest-path", str(ROOT / "rust/Cargo.toml"),
        "--format-version", "1", "--filter-platform", target]))
    command = ["cargo", "build", "--locked", "--manifest-path",
               str(ROOT / "rust/Cargo.toml"), "-p", "factory_godot", "-p", "factory_cli",
               "--target", target, "--profile", "dev" if profile == "debug" else "release",
               "--message-format=json-render-diagnostics"]
    # Keep complete compiler output, even if artifact validation subsequently fails.
    with tempfile.TemporaryDirectory(prefix="factory-build-stage-") as temporary:
        stage = Path(temporary)
        log_root = Path(tempfile.mkdtemp(prefix="factory-build-log-"))
        with (log_root / "cargo.stdout.jsonl").open("w") as stdout, (
                log_root / "cargo.stderr.log").open("w") as stderr:
            process = subprocess.run(command, cwd=ROOT, stdout=stdout, stderr=stderr)
        print(f"Compiler logs: {log_root}", flush=True)
        if process.returncode:
            raise ValueError(f"Cargo failed ({process.returncode}); see {log_root}")
        messages = (log_root / "cargo.stdout.jsonl").read_text()
        artifact = native_artifact(messages)
        executables = [Path(row["executable"]) for row in
                       (json.loads(line) for line in messages.splitlines())
                       if row.get("reason") == "compiler-artifact"
                       and (row.get("target") or {}).get("name") == "factory_cli"
                       and row.get("executable")]
        if len(executables) != 1:
            raise ValueError("Cargo did not report exactly one build identity executable")
        compiled = json.loads(checked_output([str(executables[0]), "build-info"]))
        for key, value in identity.items():
            if compiled.get(key) != value:
                raise ValueError(f"compiled build identity mismatch: {key}")
        if compiled.get("target") != target or compiled.get("profile") != profile:
            raise ValueError("compiled target/profile mismatch")
        if compiled.get("rustc") != rustc.replace("\n", " | "):
            raise ValueError("compiled rustc mismatch")
        if source_identity(ROOT) != identity:
            raise ValueError("source identity changed during compilation; retry")
        (stage / "bin").mkdir()
        staged_library = stage / "bin" / artifact.name
        shutil.copy2(artifact, staged_library)
        descriptor = stage / "factory_backend.gdextension"
        shutil.copy2(ROOT / "rust/factory_backend.gdextension.in", descriptor)
        dependency_notices(metadata, stage)
        manifest = {
            **compiled,
            "binary": "bin/" + artifact.name,
            "binary_sha256": artifact_hash(staged_library),
            "descriptor_sha256": artifact_hash(descriptor),
        }
        (stage / "build.json").write_text(json.dumps(manifest, indent=2) + "\n")
        # An exclusive directory reservation also protects an installation
        # created by someone else while Cargo was running.
        install_destination(destination.parent.parent)
        destination.parent.mkdir(parents=True, exist_ok=True)
        install_destination(destination.parent.parent)
        destination.mkdir()
        try:
            for path in stage.iterdir():
                shutil.move(str(path), str(destination / path.name))
        except BaseException:
            shutil.rmtree(destination)
            raise
    print(f"Installed FactoryBackend ({target}, {profile}): {destination}")


def main():
    if sys.argv[1:] == ["--identity-env"]:
        for name, value in source_identity(ROOT).items():
            if isinstance(value, bool):
                value = str(value).lower()
            print(f"FACTORY_{name.upper()}={value}")
        rustflags = os.environ.get("CARGO_ENCODED_RUSTFLAGS", "").encode()
        print("FACTORY_RUSTFLAGS_SHA256=" + hashlib.sha256(rustflags).hexdigest())
        print("FACTORY_RUSTFLAGS_UTF8_HEX=" + rustflags.hex())
        return
    if len(sys.argv) != 3:
        raise ValueError("Usage: build.py /path/to/godot/project debug|release")
    install(Path(sys.argv[1]), sys.argv[2])


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error)) from error
