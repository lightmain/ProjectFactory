#!/usr/bin/env python3
"""Check the external certificate-to-bank binding without loading a world."""
import pathlib
import tempfile
import unittest
from unittest import mock

import native_pressure_provenance as provenance


class FixtureTests(unittest.TestCase):
    def test_fixture_rejects_changed_bank_or_mismatched_certificate(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            save = root / "save"
            bank = save / "bank_a"
            bank.mkdir(parents=True)
            (save / "current").write_text("bank_a")
            data = bank / "world.bin"
            data.write_bytes(b"checkpoint")
            route = root / "route.bin"
            route.write_bytes(b"certificate")
            self.assertTrue(hasattr(provenance, "bind_fixture"))
            if not hasattr(provenance, "bind_fixture"):
                return
            provenance.bind_fixture(save)
            before = provenance.verify_fixture(save)
            self.assertIn("bank_a/world.bin", before)
            # Python 3.10 has no file_digest. The public Python 3 prerequisite
            # must still support streaming fixture hashes on older interpreters.
            with mock.patch.object(provenance.hashlib, "file_digest",
                                   side_effect=AttributeError("not available"), create=True):
                self.assertEqual(provenance.verify_fixture(save), before)
            data.write_bytes(b"changed checkpoint")
            with self.assertRaises(ValueError):
                provenance.verify_fixture(save)
            data.write_bytes(b"checkpoint")
            route.write_bytes(b"another certificate")
            with self.assertRaises(ValueError):
                provenance.verify_fixture(save)


if __name__ == "__main__":
    unittest.main()
