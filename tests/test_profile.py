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

    def test_runtime_command_line(self):
        # A compatibility runtime elsewhere in Documents, with its command line: data only.
        good = {'id': 'w', 'name': 'W', 'workingDirectory': 'W/game', 'runtime': 'W/Runtime', 'executable': 'bin/run',
                'arguments': ['game.exe', '--windowed'], 'environment': {'PREFIX': '${Documents}/W/prefix', '_X1': ''},
                'libraries': ['lib/core.so'], 'codePool': 64}
        check(self.write(good))
        for change in ({'runtime': '../R'}, {'runtime': '/R'}, {'runtime': 'R/'}, {'runtime': ''}, {'runtime': 'R/./bin'},
                       {'arguments': 'game.exe'}, {'arguments': [1]}, {'arguments': ['x'] * 65}, {'arguments': ['y' * 4097]},
                       {'environment': ['A=1']}, {'environment': {'1X': 'a'}}, {'environment': {'A B': 'a'}},
                       {'environment': {'A': 1}}, {'environment': {'A': 'y' * 4097}}, {'environment': {f'V{i}': '' for i in range(65)}},
                       {'libraries': 'lib/core.so'}, {'libraries': ['../core.so']}, {'libraries': ['/lib/core.so']},
                       {'libraries': ['lib/./core.so']}, {'libraries': [1]}, {'libraries': [f'l{i}.so' for i in range(65)]},
                       {'codePool': 0}, {'codePool': 1025}, {'codePool': '64'}, {'codePool': 1.5}, {'codePool': True}):
            with self.assertRaises(ValueError): check(self.write({**good, **change}))
        # A runtime's libraries only come with a runtime.
        without = {k: v for k, v in good.items() if k != 'runtime'}
        with self.assertRaises(ValueError): check(self.write(without))
        without = {k: v for k, v in good.items() if k not in ('runtime', 'libraries')}
        with self.assertRaises(ValueError): check(self.write(without))

    def test_heroes3_hd_settings(self):
        # The staged copy's HD mod settings: pinned keys replaced in place, CRLF kept, defaults used on a fresh copy.
        sys.path.insert(0, str(ROOT / 'profiles' / 'heroes3-hota'))
        import install
        with tempfile.TemporaryDirectory() as directory:
            game = Path(directory)
            folder = game / '_HD3_Data' / 'Settings'
            folder.mkdir(parents=True)
            (folder / '#default#hota.ini').write_bytes(b'<Version> = 1\r\n<Update.CheckAtStart> = 1\r\n<Graphics.RenderingMode> = -1\r\n')
            install.hd_settings(game)
            lines = (folder / 'hota.ini').read_bytes().split(b'\r\n')
            self.assertEqual(lines, [b'<Version> = 1', b'<Update.CheckAtStart> = 0', b'<Graphics.RenderingMode> = 2', b''])
            (folder / 'hota.ini').write_bytes(b'<Version> = 2\r\n<Update.CheckAtStart> = 1\r\n')
            install.hd_settings(game)
            self.assertEqual((folder / 'hota.ini').read_bytes(),
                             b'<Graphics.RenderingMode> = 2\r\n<Version> = 2\r\n<Update.CheckAtStart> = 0\r\n')
            (folder / 'hota.ini').unlink(); (folder / '#default#hota.ini').unlink()
            install.hd_settings(game)
            self.assertFalse((folder / 'hota.ini').exists())


if __name__ == '__main__': unittest.main()
