"""classify.py: what a build for one application plans, on our own fixtures."""
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
import classify

MACSDK = subprocess.run(['xcrun', '--sdk', 'macosx', '--show-sdk-path'],
                        capture_output=True, text=True, check=True).stdout.strip()


def compile_macos(source, output, *flags, cxx=False):
    compiler = 'clang++' if cxx else 'clang'
    # macOS 13: chained fixups, which list weak binds as <weak-def-coalesce>.
    subprocess.run(['xcrun', '--sdk', 'macosx', compiler, '-target', 'arm64-apple-macos13', '-isysroot', MACSDK,
                    str(source), *flags, '-o', str(output)], check=True)


def classify_run(directory, *images):
    out, mp, raw = (pathlib.Path(directory) / n for n in ('SURFACE.md', 'map.json', 'surface.json'))
    argv = sys.argv
    sys.argv = ['classify.py', *map(str, images), '--out', str(out), '--map', str(mp), '--raw', str(raw)]
    try:
        classify.main()
    finally:
        sys.argv = argv
    return json.loads(mp.read_text()), json.loads(raw.read_text()), out.read_text()


class CoalesceTests(unittest.TestCase):
    """dyld_info lists chained weak binds as coming from <weak-def-coalesce>: not a library."""

    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory()
        d = pathlib.Path(cls.directory.name)
        source = d / 'coalesce.cpp'
        source.write_text(
            '#include <stdexcept>\n'
            'template <typename T> struct Box { static int count; };\n'
            'template <typename T> int Box<T>::count = 1;\n'
            'inline int shared_value() { static int value = 7; return value; }\n'
            'int main(int argc, char **argv) {\n'
            '    int *p = new int(argc);\n'
            '    int r = Box<int>::count + shared_value() + *p;\n'
            '    delete p;\n'
            '    if (argc > 5) throw std::runtime_error(argv[0]);\n'
            '    return r;\n'
            '}\n')
        exe = d / 'coalesce'
        compile_macos(source, exe, '-O0', cxx=True)
        cls.imports = classify.imports(str(exe))
        cls.mapping, cls.raw, cls.surface = classify_run(d, exe)

    @classmethod
    def tearDownClass(cls):
        cls.directory.cleanup()

    def test_fixture_has_coalesced_imports(self):
        coalesced = {s for s, frm, _ in self.imports if frm == classify.WEAK_COALESCE}
        self.assertIn('__Znwm', coalesced)                  # operator new: libc++'s, unless replaced
        self.assertIn('__ZN3BoxIiE5countE', coalesced)      # the executable's own template static

    def test_no_library_and_no_shim(self):
        self.assertNotIn(classify.WEAK_COALESCE, self.mapping)
        self.assertNotIn(classify.WEAK_COALESCE, self.raw['translation'])
        self.assertIn('| `<weak-def-coalesce>` | coalesced |', self.surface)

    def test_own_definitions_skipped_the_rest_checked_against_the_sdk(self):
        seen = self.raw['per_lib'][classify.WEAK_COALESCE]
        self.assertIn('__Znwm', seen['present'])
        self.assertIn('__ZdlPv', seen['present'])
        listed = {s for kind in seen.values() for s in kind}
        self.assertNotIn('__ZN3BoxIiE5countE', listed)
        self.assertNotIn('__ZZ12shared_valuevE5value', listed)


class BundledLibraryTests(unittest.TestCase):
    """A library in Contents/Frameworks brings the frameworks it alone links."""

    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory()
        d = pathlib.Path(cls.directory.name)
        contents = d / 'Fixture.app/Contents'
        (contents / 'MacOS').mkdir(parents=True)
        (contents / 'Frameworks').mkdir()
        cls.library = contents / 'Frameworks/libextra.dylib'
        (d / 'extra.c').write_text(
            '#include <Carbon/Carbon.h>\n'
            'const void *extra(void) { return TISCopyCurrentKeyboardInputSource(); }\n')
        compile_macos(d / 'extra.c', cls.library, '-dynamiclib', '-install_name', '@rpath/libextra.dylib',
                      '-framework', 'Carbon')
        (d / 'main.c').write_text('const void *extra(void);\nint main(void) { return extra() != 0; }\n')
        exe = contents / 'MacOS/Fixture'
        compile_macos(d / 'main.c', exe, '-L', str(cls.library.parent), '-lextra',
                      '-Wl,-rpath,@executable_path/../Frameworks')
        cls.executable_only = classify_run(d, exe)[0]
        cls.mapping, cls.raw, cls.surface = classify_run(d, exe, cls.library)

    @classmethod
    def tearDownClass(cls):
        cls.directory.cleanup()

    def test_own_install_name_is_not_a_dependency(self):
        libs = classify.linked(str(self.library))
        self.assertNotIn('@rpath/libextra.dylib', libs)
        self.assertIn('/System/Library/Frameworks/Carbon.framework/Versions/A/Carbon', libs)

    def test_frameworks_only_the_library_links_are_mapped(self):
        carbon = '/System/Library/Frameworks/Carbon.framework/Versions/A/Carbon'
        self.assertNotIn(carbon, self.executable_only)
        # Carbon does not exist on iOS: the hand-written adapter serves the library.
        self.assertEqual(self.mapping[carbon], '@rpath/akCarbon.dylib')
        self.assertIn('Carbon', self.raw['translation'])
        # The executable's view of the library is unchanged: bundled, never mapped.
        self.assertIn('| `@rpath/libextra.dylib` | bundled |', self.surface)
        self.assertNotIn('@rpath/libextra.dylib', self.mapping)
        self.assertEqual(self.surface.count('`@rpath/libextra.dylib`'), 1)


if __name__ == '__main__':
    unittest.main()
