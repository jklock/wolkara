"""classify.py: what a build for one application plans, on our own fixtures."""
import contextlib
import io
import json
import os
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


@contextlib.contextmanager
def experimental(value):
    saved = os.environ.pop('TOLKARA_EXPERIMENTAL_ADAPTERS', None)
    if value is not None:
        os.environ['TOLKARA_EXPERIMENTAL_ADAPTERS'] = value
    try:
        yield
    finally:
        os.environ.pop('TOLKARA_EXPERIMENTAL_ADAPTERS', None)
        if saved is not None:
            os.environ['TOLKARA_EXPERIMENTAL_ADAPTERS'] = saved


def classify_run(directory, *images, translation=None, enabled=None, bundled=False):
    out, mp, raw = (pathlib.Path(directory) / n for n in ('SURFACE.md', 'map.json', 'surface.json'))
    argv, root, printed = sys.argv, classify.TRANSLATION, io.StringIO()
    sys.argv = ['classify.py', *(['--bundled'] if bundled else []), *map(str, images),
                '--out', str(out), '--map', str(mp), '--raw', str(raw)]
    classify.TRANSLATION = str(translation or root)
    try:
        with experimental(enabled), contextlib.redirect_stdout(printed):
            classify.main()
    finally:
        sys.argv, classify.TRANSLATION = argv, root
    return json.loads(mp.read_text()), json.loads(raw.read_text()), out.read_text(), printed.getvalue()


class ImageHintTests(unittest.TestCase):
    def test_chained_image_hints_are_data(self):
        with tempfile.TemporaryDirectory() as directory:
            d = pathlib.Path(directory)
            source, exe = d / 'hints.m', d / 'hints'
            source.write_text(
                '#import <AppKit/AppKit.h>\n'
                'int main(void) { @autoreleasepool {\n'
                '    NSLog(@"%@ %@ %@", NSImageHintCTM, NSImageHintInterpolation,\n'
                '          NSImageHintUserInterfaceLayoutDirection);\n'
                '    return 0;\n'
                '}}\n')
            compile_macos(source, exe, '-framework', 'AppKit', '-Wl,-fixup_chains')
            self.assertIsNone(classify.lazy_symbols(str(exe)))
            _, raw, _, _ = classify_run(d, exe)
            symbols = {entry[0]: entry[1] for entry in raw['translation']['AppKit']['symbols']}
            for name in ('CTM', 'Interpolation', 'UserInterfaceLayoutDirection'):
                self.assertEqual(symbols['_NSImageHint' + name], 'data')


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
        cls.mapping, cls.raw, cls.surface, _ = classify_run(d, exe)

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
        frameworks = contents / 'Frameworks'
        (contents / 'MacOS').mkdir(parents=True)
        (frameworks / 'Reach.framework').mkdir(parents=True)
        cls.library = frameworks / 'libextra.dylib'
        (d / 'extra.c').write_text(
            '#include <Carbon/Carbon.h>\n'
            'const void *extra(void) { return TISCopyCurrentKeyboardInputSource(); }\n')
        compile_macos(d / 'extra.c', cls.library, '-dynamiclib', '-install_name', '@rpath/libextra.dylib',
                      '-framework', 'Carbon')
        # A bundled framework, linking a framework iOS has.
        cls.framework = frameworks / 'Reach.framework/Reach'
        (d / 'reach.c').write_text(
            '#include <SystemConfiguration/SystemConfiguration.h>\n'
            'const void *reach(void) { return SCNetworkReachabilityCreateWithName(0, "localhost"); }\n')
        compile_macos(d / 'reach.c', cls.framework, '-dynamiclib', '-install_name',
                      '@rpath/Reach.framework/Reach', '-framework', 'SystemConfiguration')
        # A plugin-style library linked with -undefined dynamic_lookup: flat-namespace binds,
        # one to the executable, one to the system.
        (d / 'plugin.c').write_text(
            'int host_value(void);\nconst char *zlibVersion(void);\n'
            'int plugin(void) { return host_value() + (zlibVersion() != 0); }\n')
        compile_macos(d / 'plugin.c', frameworks / 'libplugin.dylib', '-dynamiclib', '-install_name',
                      '@rpath/libplugin.dylib', '-undefined', 'dynamic_lookup')
        (frameworks / 'notes.txt').write_text('not a library\n')
        (d / 'main.c').write_text('const void *extra(void);\nint host_value(void) { return 1; }\n'
                                  'int main(void) { return extra() != 0; }\n')
        cls.exe = exe = contents / 'MacOS/Fixture'
        compile_macos(d / 'main.c', exe, '-L', str(cls.library.parent), '-lextra',
                      '-Wl,-rpath,@executable_path/../Frameworks')
        cls.executable_only = classify_run(d, exe)[0]
        cls.mapping, cls.raw, cls.surface, _ = classify_run(d, exe, bundled=True)

    @classmethod
    def tearDownClass(cls):
        cls.directory.cleanup()

    def test_own_install_name_is_not_a_dependency(self):
        libs = classify.linked(str(self.library))
        self.assertNotIn('@rpath/libextra.dylib', libs)
        self.assertIn('/System/Library/Frameworks/Carbon.framework/Versions/A/Carbon', libs)

    def test_bundled_libraries_are_the_top_level_binaries(self):
        found = [pathlib.Path(p) for p in classify.bundled_libraries(str(self.exe))]
        self.assertEqual(found, [self.framework, self.library, self.library.parent / 'libplugin.dylib'])

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
        # The bundled framework's own dependency: on iOS, so the system library.
        configuration = '/System/Library/Frameworks/SystemConfiguration.framework/Versions/A/SystemConfiguration'
        self.assertEqual(self.mapping[configuration], '/System/Library/Frameworks/SystemConfiguration.framework/SystemConfiguration')

    def test_flat_namespace_is_not_a_library(self):
        self.assertNotIn('<flat-namespace>', self.mapping)
        self.assertNotIn('<flat-namespace>', self.raw['translation'])
        self.assertIn('| `<flat-namespace>` | flat |', self.surface)
        seen = self.raw['per_lib']['<flat-namespace>']
        self.assertIn('_zlibVersion', seen['present'])
        # The executable defines host_value: the application's own, never listed.
        self.assertNotIn('_host_value', {s for kind in seen.values() for s in kind})


GC = '/System/Library/Frameworks/GameController.framework/Versions/A/GameController'
CH = '/System/Library/Frameworks/CoreHaptics.framework/Versions/A/CoreHaptics'
FX = '/System/Library/Frameworks/MetalFX.framework/Versions/A/MetalFX'
LIBZ = '/usr/lib/libz.1.dylib'


class MarkerTests(unittest.TestCase):
    """translation/<Leaf>/standalone, absent and experimental, in a translation tree of our own."""

    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory()
        d = pathlib.Path(cls.directory.name)
        tree = d / 'translation'
        for leaf, files in {'GameController': ('standalone', 'experimental', 'Adapter.m'),
                            'MetalFX': ('absent', 'experimental'),
                            'libz.1': ('absent',)}.items():
            (tree / leaf).mkdir(parents=True)
            for name in files:
                (tree / leaf / name).write_text('// fixture\n')
        cls.tree = tree
        source = d / 'guest.m'
        source.write_text(
            '#import <GameController/GameController.h>\n#import <CoreHaptics/CoreHaptics.h>\n#include <zlib.h>\n'
            'int main(void) {\n'
            '    return (int)(long)GCControllerDidConnectNotification + (int)(long)CHHapticEventParameterIDAttackTime\n'
            '        + (int)(long)zlibVersion();\n'
            '}\n')
        exe = d / 'guest'
        # MetalFX is linked with no imported symbol, as a load command only.
        compile_macos(source, exe, '-framework', 'GameController', '-framework', 'CoreHaptics',
                      '-Wl,-needed_framework,MetalFX', '-lz')
        cls.default = classify_run(d, exe, translation=tree)
        cls.enabled = classify_run(d, exe, translation=tree, enabled='GameController:MetalFX')

    @classmethod
    def tearDownClass(cls):
        cls.directory.cleanup()

    def test_experimental_directories_need_opting_in(self):
        with experimental(None):
            self.assertEqual(classify.adapter_leaves(str(self.tree)), {'libz.1'})
            self.assertEqual(classify.translation_leaves('absent', str(self.tree)), {'libz.1'})
        with experimental('GameController, MetalFX'):
            self.assertEqual(classify.adapter_leaves(str(self.tree)), {'libz.1', 'GameController', 'MetalFX'})
            self.assertEqual(classify.translation_leaves('standalone', str(self.tree)), {'GameController'})

    def test_default_build_ignores_experimental_adapters(self):
        mapping, raw, _, _ = self.default
        self.assertTrue(mapping[GC].startswith('/System/Library/Frameworks/GameController.framework/'))
        self.assertTrue(mapping[FX].startswith('/System/Library/Frameworks/MetalFX.framework/'))
        self.assertNotIn('GameController', raw['translation'])

    def test_absent_library_is_an_empty_target(self):
        for mapping, raw, surface, printed in (self.default, self.enabled):
            # A .dylib's marker directory drops the suffix, like its adapter.
            self.assertEqual(mapping[LIBZ], '')
            self.assertIn('| `/usr/lib/libz.1.dylib` | absent |', surface)
            self.assertNotIn('libz.1.dylib', raw['translation'])
            self.assertIn('libz.1.dylib is presented as absent, but 1 imports from it are not weak', printed)
        mapping, raw, _, printed = self.enabled
        self.assertEqual(mapping[FX], '')
        self.assertNotIn('MetalFX', raw['translation'])
        self.assertNotIn('MetalFX', printed)   # linked, nothing imported

    def test_standalone_adapter_replaces_the_real_library(self):
        mapping, raw, _, _ = self.enabled
        plan = raw['translation']
        # No real library to re-export, and every import planned without a
        # provider, so the adapter or a generated stub defines each one.
        self.assertEqual(mapping[GC], '@rpath/akGameController.dylib')
        self.assertIsNone(plan['GameController']['real'])
        self.assertIsNone(plan['GameController']['real_tbd'])
        planned = {symbol: provider for symbol, _, provider in plan['GameController']['symbols']}
        self.assertIn('_GCControllerDidConnectNotification', planned)
        self.assertIsNone(planned['_GCControllerDidConnectNotification'])
        # A library with no marker still resolves to the real one.
        self.assertNotIn('CoreHaptics', plan)
        self.assertTrue(mapping[CH].startswith('/System/Library/Frameworks/CoreHaptics.framework/'))


if __name__ == '__main__':
    unittest.main()
