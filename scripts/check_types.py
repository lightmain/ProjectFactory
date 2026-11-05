#!/usr/bin/env python3
"""Compile first-party scripts with type warnings as errors in a disposable editor project."""

from pathlib import Path
import re
import subprocess
import sys
import tempfile
from verification_project import copy_project

TYPE_WARNINGS = (
    "untyped_declaration", "inferred_declaration", "unsafe_property_access",
    "unsafe_method_access", "unsafe_cast", "unsafe_call_argument",
)
ERROR_PATTERN = re.compile(r"(?:SCRIPT ERROR:|ERROR:|Shader compilation failed)")


def main() -> int:
    project_root = Path(__file__).resolve().parent.parent
    godot_bin = sys.argv[1]
    with tempfile.TemporaryDirectory(prefix="project-factory-types-") as temporary:
        check_root = Path(temporary)
        copy_project(project_root, check_root)
        configuration = (project_root / "project.godot").read_text(encoding="utf-8")
        for warning in TYPE_WARNINGS:
            configuration = configuration.replace(
                f"gdscript/warnings/{warning}=1",
                f"gdscript/warnings/{warning}=2",
            )
        configuration, replacements = re.subn(
            r"(?m)^run/main_scene=.*$",
            'run/main_scene="res://type_check.tscn"', configuration,
        )
        if replacements != 1:
            raise ValueError("Expected exactly one application startup scene.")
        (check_root / "project.godot").write_text(configuration, encoding="utf-8")
        scripts = sorted((check_root / "scripts").rglob("*.gd"))
        preloads = ",\n".join(
            f'\tpreload("res://{script.relative_to(check_root).as_posix()}")'
            for script in scripts
        )
        (check_root / "type_check.gd").write_text(
            f"@tool\nextends Node\n\nconst CHECKED_SCRIPTS: Array[Script] = [\n{preloads}\n]\n",
            encoding="utf-8",
        )
        (check_root / "type_check.tscn").write_text(
            '[gd_scene load_steps=2 format=3]\n'
            '[ext_resource type="Script" path="res://type_check.gd" id="1"]\n'
            '[node name="TypeCheck" type="Node"]\nscript = ExtResource("1")\n',
            encoding="utf-8",
        )
        result = subprocess.run(
            [godot_bin, "--headless", "--log-file", str(check_root / "type_check.log"),
             "--path", str(check_root), "--import", "type_check.tscn"],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, check=False,
        )
        print(result.stdout, end="")
        if result.returncode or ERROR_PATTERN.search(result.stdout):
            print("First-party GDScript type-safety check failed.", file=sys.stderr)
            return 1
        print(f"First-party GDScript type-safety checks passed ({len(scripts)} scripts).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
