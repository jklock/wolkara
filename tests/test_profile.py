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

    def test_case_aliases(self):
        good = {'id': 'a', 'name': 'A', 'workingDirectory': 'A', 'executable': 'A.app/Contents/MacOS/A'}
        check(self.write({**good, 'caseAliases': {'archive/mac': 'Mac', 'Data': 'data'}}))
        check(self.write({**good, 'caseAliases': {}}))
        for aliases in ([], 'archive/mac', {'archive/mac': 1}, {'archive/mac': None}, {'archive/mac': ['Mac']},
                        {'/archive/mac': 'Mac'}, {'../mac': 'Mac'}, {'archive/../mac': 'Mac'}, {'': 'Mac'},
                        {'archive//mac': 'Mac'}, {'archive/mac/': 'Mac'}, {'archive/mac': ''},
                        {'archive/mac': '../Mac'}, {'archive/mac': 'archive/Mac'}, {'archive/mac': 'mac'},
                        {'archive/mac': 'Other'}):
            with self.assertRaises(ValueError, msg=repr(aliases)): check(self.write({**good, 'caseAliases': aliases}))


if __name__ == '__main__': unittest.main()
