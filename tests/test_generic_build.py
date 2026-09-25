"""A build made for no particular application: adapters, no map."""
import os
import pathlib
import shutil
import subprocess
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
OUT = ROOT / 'build/emulation/generic-app'


def written():
    # Hand-written frameworks with sources, as build_shims.py counts them.
    for directory in sorted((ROOT / 'translation').iterdir()):
        if directory.name != 'AKSupport' and directory.is_dir() and any(
                source.suffix in ('.c', '.m') for source in directory.iterdir()):
            yield directory.name


class GenericBuildTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        shutil.rmtree(OUT, ignore_errors=True)
        # What an earlier build for one executable leaves behind in the same place.
        (OUT / 'Guest').mkdir(parents=True)
        (OUT / 'Guest/libraries.json').write_text('{}')
        # The build phase's own step, with no executable named.
        env = dict(os.environ, NATIVE_GUEST_SHIMS='GENERIC', PLATFORM_NAME='iphoneos')
        # The iOS SDK comes with Xcode, as for tools/run.sh and tools/install.sh.
        env.setdefault('DEVELOPER_DIR', '/Applications/Xcode.app/Contents/Developer')
        result = subprocess.run([str(ROOT / 'tools/build_emulated_guest.sh'), str(OUT), ''],
                                cwd=ROOT, env=env, capture_output=True, text=True)
        if result.returncode:
            raise RuntimeError('generic build failed:\n' + result.stdout + result.stderr)

    def test_one_adapter_per_written_framework(self):
        expected = {'ak%s.dylib' % leaf for leaf in written()}
        self.assertTrue(expected)
        present = {path.name for path in (OUT / 'Frameworks').glob('*.dylib')}
        self.assertEqual(present, expected | {'libAKSupport.dylib'})

    def test_no_library_map(self):
        self.assertFalse((OUT / 'Guest/libraries.json').exists())


if __name__ == '__main__':
    unittest.main()
