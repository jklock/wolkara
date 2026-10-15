import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('package_guest', Path(__file__).resolve().parents[1] / 'tools/package_guest.py')
package_guest = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package_guest)


class PackageTests(unittest.TestCase):
    def test_bytes_and_manifest(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / 'Original'
            original = bytes(range(256)) * 513
            source.write_bytes(original)
            output = root / 'app/Guest'
            package_guest.package(source, output)
            self.assertEqual(source.read_bytes(), original)
            self.assertEqual((output / 'OriginalExecutable.bin').read_bytes(), original)
            manifest = json.loads((output / 'manifest.json').read_text())
            self.assertEqual(manifest['sha256'], hashlib.sha256(original).hexdigest())
            self.assertEqual(manifest['size'], len(original))
            self.assertFalse(manifest['modified'])
            self.assertEqual(manifest['format'], 2)
            for suffix in ['.app', '.framework', '.appex']:
                with self.assertRaises(ValueError):
                    package_guest.package(source, root / ('Host' + suffix) / 'Guest')
            with self.assertRaises(ValueError):
                package_guest.package(output / 'OriginalExecutable.bin', output)
            # Rebuild is repeatable and cannot depend on timestamps or stale copies.
            source.write_bytes(b'new original')
            package_guest.package(source, output)
            self.assertEqual((output / 'OriginalExecutable.bin').read_bytes(), b'new original')


if __name__ == '__main__':
    unittest.main()
