"""Explicit compiler integration test; run only outside performance measurements."""
import json
import os
from pathlib import Path
import subprocess
import unittest

from build import source_identity


class CompiledIdentityTests(unittest.TestCase):
    def test_identity_matches_actual_workspace_inputs_and_lock(self):
        root = Path(__file__).resolve().parent.parent
        expected = source_identity(root)
        output = subprocess.run(
            ["cargo", "run", "--locked", "--quiet", "--manifest-path",
             str(root / "rust/Cargo.toml"), "-p", "factory_cli", "--", "build-info"],
            cwd=root, text=True, capture_output=True, check=True,
        )
        actual = json.loads(output.stdout)
        for name in ["inputs_sha256", "lock_sha256", "commit", "dirty"]:
            self.assertEqual(actual[name], expected[name])
        rustc = subprocess.check_output([os.environ.get("RUSTC", "rustc"), "-vV"], text=True).strip()
        self.assertEqual(actual["rustc"], rustc.replace("\n", " | "))
        self.assertEqual(actual["target"], rustc.split("host: ", 1)[1].splitlines()[0])
        self.assertEqual(actual["opt_level"], "0")
        self.assertTrue(actual["debug_assertions"])
        self.assertEqual(len(actual["rustflags_sha256"]), 64)


if __name__ == "__main__":
    unittest.main()
