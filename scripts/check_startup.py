#!/usr/bin/env python3
"""Check real game startup before/after validation without sharing editor caches."""

import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys


ERROR_PATTERN = re.compile(r"SCRIPT ERROR:|ERROR:|Shader compilation failed|Script check failed:")
SUCCESS_PATTERN = re.compile(r"(?m)^PROJECT_STARTUP_OK\s*$")


def check_editor_classes(project_root: Path) -> None:
    registry = project_root / ".godot" / "global_script_class_cache.cfg"
    if not registry.is_file():
        return  # A fresh checkout has no editor cache to validate.
    registered = {}
    for entry in re.findall(r"\{([^{}]*)\}", registry.read_text(encoding="utf-8"), re.DOTALL):
        name = re.search(r'^"class": &"([^"]+)"', entry, re.MULTILINE)
        path = re.search(r'^"path": "([^"]+)"', entry, re.MULTILINE)
        if name and path:
            if name[1] in registered:
                raise RuntimeError("Original editor cache has duplicate class registration: " + name[1])
            registered[name[1]] = path[1]
    missing = []
    for script in (project_root / "scripts").rglob("*.gd"):
        declaration = re.search(r"(?m)^class_name\s+(\w+)", script.read_text(encoding="utf-8"))
        if declaration:
            name = declaration[1]
            path = f"res://{script.relative_to(project_root).as_posix()}"
            if registered.get(name) != path:
                missing.append(f"{name} ({path})")
    if missing:
        raise RuntimeError("Original editor cache lacks current class registrations: " + ", ".join(sorted(missing)))


def editor_cache_state(project_root: Path) -> dict:
    cache_root = project_root / ".godot"
    paths = [cache_root / "global_script_class_cache.cfg"]
    paths.extend((cache_root / "editor").glob("filesystem_cache*"))
    return {
        path.relative_to(cache_root).as_posix(): {
            "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            "mtime_ns": path.stat().st_mtime_ns,
        }
        for path in paths if path.is_file()
    }


def record_cache(project_root: Path, log_directory: Path) -> None:
    check_editor_classes(project_root)
    (log_directory / "editor_cache_before.json").write_text(
        json.dumps(editor_cache_state(project_root), sort_keys=True), encoding="utf-8",
    )


def check_cache(project_root: Path, log_directory: Path) -> None:
    check_editor_classes(project_root)
    expected = json.loads((log_directory / "editor_cache_before.json").read_text(encoding="utf-8"))
    if editor_cache_state(project_root) != expected:
        raise RuntimeError("The original editor class/filesystem cache changed during verification.")


def check_startup(godot_bin: str, check_root: Path, log_directory: Path, phase: str) -> None:
    configuration_path = check_root / "project.godot"
    configuration = configuration_path.read_text(encoding="utf-8")
    autoload = '_startup_probe="*res://tests/integration/project_startup_probe.gd"\n'
    if "[autoload]" in configuration:
        checked_configuration = configuration.replace("[autoload]", "[autoload]\n" + autoload, 1)
    else:
        checked_configuration = configuration + "\n[autoload]\n" + autoload
    output_path = log_directory / f"startup_{phase}.log"
    configuration_path.write_text(checked_configuration, encoding="utf-8")
    try:
        result = subprocess.run(
            [godot_bin, "--headless", "--path", str(check_root),
             "--log-file", str(log_directory / f"startup_{phase}.engine.log"), "--quit-after", "240"],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=60, check=False,
        )
        output_path.write_text(result.stdout, encoding="utf-8")
        print(result.stdout, end="")
        if result.returncode or ERROR_PATTERN.search(result.stdout) or not SUCCESS_PATTERN.search(result.stdout):
            raise RuntimeError(f"Configured project startup failed ({phase}); see {output_path}")
    except subprocess.TimeoutExpired as error:
        output = error.stdout or b""
        output_path.write_bytes(output if isinstance(output, bytes) else output.encode("utf-8"))
        raise RuntimeError(f"Configured project startup timed out ({phase}); see {output_path}") from error
    finally:
        configuration_path.write_text(configuration, encoding="utf-8")


def main() -> None:
    phase = sys.argv[1]
    if phase == "record":
        record_cache(Path(sys.argv[2]), Path(sys.argv[3]))
        return
    godot_bin, check_root, project_root, log_directory = sys.argv[2:]
    if phase not in ("before", "after", "check"):
        raise ValueError("Expected before, after or check startup phase.")
    if Path(check_root).samefile(project_root):
        raise ValueError("Startup checks require a separate disposable project.")
    check_cache(Path(project_root), Path(log_directory))
    if phase == "check":
        return
    check_startup(godot_bin, Path(check_root), Path(log_directory), phase)
    check_cache(Path(project_root), Path(log_directory))
    print(f"Real startup integration passed ({phase}); original editor caches unchanged.")


if __name__ == "__main__":
    main()
