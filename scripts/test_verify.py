#!/usr/bin/env python3
"""Regression checks for validation while the real project is open in an editor."""

from contextlib import redirect_stdout
import io
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from check_startup import check_editor_classes, check_startup
from verification_project import copy_project


SCRIPTS = Path(__file__).resolve().parent
FAKE_ENGINE = """#!/usr/bin/env python3
import os
from pathlib import Path
import sys

args = sys.argv[1:]
if "--version" in args:
    print("4.7.2.test")
    sys.exit(0)
root = Path(args[args.index("--path") + 1])
(root / ".godot").mkdir(exist_ok=True)
(root / ".godot" / "editor-cache").write_text("rewritten by engine")
if (root / "type_check.tscn").exists():
    if 'run/main_scene="res://type_check.tscn"' not in (root / "project.godot").read_text():
        print("ERROR: Type check still starts the game scene")
        sys.exit(1)
else:
    assert (root / "extra_resource.tres").read_text() == "uncommitted resource"
    assert not (root / ".git").exists()
if "-rd" in args:
    report_argument = args[args.index("-rd") + 1]
    # GdUnit qualifies a leading slash as res:/ rather than a system path.
    report_root = root / report_argument.lstrip("/")
    report_root.mkdir(parents=True, exist_ok=True)
    (report_root / "results.xml").write_text("<testsuites/>")
if "_startup_probe=" in (root / "project.godot").read_text():
    failure = os.environ.get("FAKE_STARTUP_FAILURE", "")
    if failure == "missing_marker":
        print("The game never mounted a world")
    else:
        print("PROJECT_STARTUP_OK")
    if failure == "script_error":
        print("SCRIPT ERROR: Missing game dependency")
    if failure == "nonzero":
        sys.exit(2)
else:
    print("Fake engine completed")
"""


class VerifyRegressionTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="verify-regression-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / "open project"
        self.root.mkdir()
        for name in ("scripts", "scenes", "assets", "config", "tests", ".godot"):
            (self.root / name).mkdir()
        for plugin, version in (("godot_ai", "4.2.3"), ("gdUnit4", "6.2.1")):
            directory = self.root / "addons" / plugin
            directory.mkdir(parents=True)
            (directory / "plugin.cfg").write_text(f'version="{version}"\n')
        for name in ("verify.sh", "check_types.py", "verification_project.py", "check_startup.py"):
            if (SCRIPTS / name).exists():
                shutil.copy2(SCRIPTS / name, self.root / "scripts" / name)
        # The fixture exercises orchestration; do not recursively launch this suite.
        (self.root / "scripts" / "test_verify.py").write_text("")
        (self.root / "project.godot").write_text(
            '[application]\nrun/main_scene="res://scenes/session.tscn"\n'
        )
        (self.root / "icon.svg").write_text("<svg/>")
        (self.root / "extra_resource.tres").write_text("uncommitted resource")
        self.cache = self.root / ".godot" / "editor-cache"
        self.cache.write_text("live editor cache")
        self.engine = Path(self.temporary.name) / "fake godot"
        self.engine.write_text(FAKE_ENGINE)
        self.engine.chmod(0o755)
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)

    def test_validation_preserves_editor_cache_and_uncommitted_resources(self) -> None:
        result = subprocess.run(
            ["bash", str(self.root / "scripts" / "verify.sh")],
            cwd=self.temporary.name,
            env={**os.environ, "GODOT_BIN": str(self.engine)},
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
        )
        self.assertEqual(self.cache.read_text(), "live editor cache", result.stdout)
        self.assertEqual(result.returncode, 0, result.stdout)
        log_line = next(line for line in result.stdout.splitlines() if line.startswith("验证日志："))
        log_directory = Path(log_line.removeprefix("验证日志：").strip())
        self.addCleanup(shutil.rmtree, log_directory)
        self.assertTrue((log_directory / "reports" / "results.xml").is_file(), result.stdout)
        self.assertFalse((log_directory / "project").exists())
        for phase in ("before", "after"):
            startup_log = log_directory / f"startup_{phase}.log"
            self.assertTrue(startup_log.is_file(), f"Missing real startup stage: {phase}")
            self.assertIn("PROJECT_STARTUP_OK", startup_log.read_text())

    def test_type_check_replaces_the_current_startup_scene(self) -> None:
        result = subprocess.run(
            ["python3", str(self.root / "scripts" / "check_types.py"), str(self.engine)],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
        )
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(self.cache.read_text(), "live editor cache")

    def test_startup_failure_preserves_logs_and_restores_configuration(self) -> None:
        check_root = Path(self.temporary.name) / "startup project"
        copy_project(self.root, check_root)
        configuration = (check_root / "project.godot").read_text()
        for failure in ("missing_marker", "script_error", "nonzero"):
            with self.subTest(failure=failure):
                with patch.dict(os.environ, {"FAKE_STARTUP_FAILURE": failure}), redirect_stdout(io.StringIO()):
                    with self.assertRaisesRegex(RuntimeError, "startup failed"):
                        check_startup(str(self.engine), check_root, Path(self.temporary.name), failure)
                self.assertEqual((check_root / "project.godot").read_text(), configuration)
                self.assertTrue((Path(self.temporary.name) / f"startup_{failure}.log").is_file())

    def test_preexisting_registry_must_match_current_class_name_and_path(self) -> None:
        # Synthetic fixture data, not an edit to any real editor's generated cache.
        (self.root / "scripts" / "dependency.gd").write_text(
            "class_name StartupDependency\nextends RefCounted\n"
        )
        registry = self.root / ".godot" / "global_script_class_cache.cfg"
        for entry in (
            '"class": &"OldDependency", "path": "res://scripts/dependency.gd"',
            '"class": &"StartupDependency", "path": "res://scripts/old_dependency.gd"',
        ):
            with self.subTest(entry=entry):
                registry.write_text("list=[{\n" + entry.replace(", ", ",\n") + "\n}]\n")
                with self.assertRaisesRegex(RuntimeError, "StartupDependency"):
                    check_editor_classes(self.root)
        registry.write_text(
            'list=[{\n"class": &"StartupDependency",\n'
            '"path": "res://scripts/dependency.gd"\n}]\n'
        )
        check_editor_classes(self.root)


if __name__ == "__main__":
    unittest.main()
