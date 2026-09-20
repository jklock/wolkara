import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
from check_profile import check


class ProfileTests(unittest.TestCase):
    def write(self, value):
        handle = tempfile.NamedTemporaryFile('w', suffix='.json', delete=False)
        json.dump(value, handle); handle.close(); self.addCleanup(Path(handle.name).unlink)
        return handle.name

    def test_shipped_profiles(self):
        paths = list((ROOT / 'profiles').glob('*/profile.json'))
        self.assertTrue(paths)
        for path in paths: check(path)

    def test_rejects_escape_and_unknown_keys(self):
        good = {'id': 'a', 'name': 'A', 'workingDirectory': 'A', 'executable': 'A.app/Contents/MacOS/A'}
        check(self.write(good))
        for change in ({'executable': '/bin/sh'}, {'workingDirectory': '../x'}, {'command': 'x'}, {'name': ''}):
            with self.assertRaises(ValueError): check(self.write({**good, **change}))


if __name__ == '__main__': unittest.main()
