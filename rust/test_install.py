"""Installation boundary tests; runs without invoking a compiler."""
import importlib.util
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("factory_build", Path(__file__).with_name("build.py"))
build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build)


class InstallBoundaryTests(unittest.TestCase):
    def test_source_identity_hashes_inputs_and_ignores_build_outputs(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "rust").mkdir()
            source = root / "rust/factory_core/src/lib.rs"
            source.parent.mkdir(parents=True)
            source.write_bytes(b"initial rules")
            (root / "rust/Cargo.lock").write_bytes(b"lock")
            initial = build.source_identity(root)
            digest = hashlib.sha256()
            for path in [root / "rust/Cargo.lock", source]:
                name = path.relative_to(root).as_posix().encode()
                digest.update(name + b"\0" + hashlib.sha256(path.read_bytes()).digest())
            self.assertEqual(initial["inputs_sha256"], digest.hexdigest())
            self.assertEqual(initial["lock_sha256"], hashlib.sha256(b"lock").hexdigest())
            ignored = root / "rust/target"
            ignored.mkdir()
            (ignored / "artifact").write_bytes(b"generated")
            self.assertEqual(build.source_identity(root)["inputs_sha256"], initial["inputs_sha256"])
            source.write_bytes(b"changed rules")
            self.assertNotEqual(build.source_identity(root)["inputs_sha256"], initial["inputs_sha256"])

    def test_install_requires_a_godot_project_and_does_not_create_paths(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "not a project"
            with self.assertRaisesRegex(ValueError, "project.godot"):
                build.install_destination(root)
            self.assertFalse(root.exists())

    def test_existing_installation_is_preserved(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "project.godot").write_text("[application]\n")
            installed = root / "native/factory_backend"
            installed.mkdir(parents=True)
            payload = installed / "user_file"
            payload.write_bytes(b"keep unchanged")
            with self.assertRaisesRegex(ValueError, "already exists"):
                build.install_destination(root)
            self.assertEqual(payload.read_bytes(), b"keep unchanged")

    def test_native_parent_links_cannot_redirect_installation(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            project = root / "project"
            project.mkdir()
            (project / "project.godot").write_text("[application]\n")
            outside = root / "outside"
            outside.mkdir()
            (project / "native").symlink_to(outside, target_is_directory=True)
            with self.assertRaisesRegex(ValueError, "symbolic link"):
                build.install_destination(project)
            self.assertEqual(list(outside.iterdir()), [])

    def test_only_the_initial_native_platform_is_accepted(self):
        self.assertEqual(build.validate_target("aarch64-apple-darwin"), "aarch64-apple-darwin")
        for target in ["x86_64-apple-darwin", "x86_64-unknown-linux-gnu",
                       "x86_64-pc-windows-msvc", "unknown"]:
            with self.subTest(target=target), self.assertRaisesRegex(ValueError, "unsupported"):
                build.validate_target(target)

    def test_artifact_selection_requires_a_single_reported_cdylib(self):
        with tempfile.TemporaryDirectory() as temporary:
            library = Path(temporary) / "libfactory_godot.dylib"
            library.write_bytes(b"reported artifact")
            row = {"reason": "compiler-artifact",
                   "target": {"name": "factory_godot", "crate_types": ["cdylib"]},
                   "filenames": [str(library)]}
            messages = json.dumps(row)
            self.assertEqual(build.native_artifact(messages), library)
            for invalid in [
                "", messages + "\n" + messages,
                json.dumps({**row, "filenames": [str(library) + ".missing"]}),
                json.dumps({**row, "target": {"name": "other", "crate_types": ["cdylib"]}}),
                json.dumps({**row, "target": {"name": "factory_godot", "crate_types": ["rlib"]}}),
            ]:
                with self.subTest(messages=invalid), self.assertRaises(ValueError):
                    build.native_artifact(invalid)

    def test_staged_library_identity_does_not_follow_changed_cargo_output(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            cargo = root / "cargo.dylib"
            cargo.write_bytes(b"copied library")
            staged = root / "stage.dylib"
            staged.write_bytes(cargo.read_bytes())
            cargo.write_bytes(b"another concurrent build")
            self.assertEqual(build.artifact_hash(staged),
                             hashlib.sha256(b"copied library").hexdigest())
            self.assertNotEqual(build.artifact_hash(staged), build.artifact_hash(cargo))


if __name__ == "__main__":
    unittest.main()
