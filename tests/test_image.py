"""Synthetic Mach-O inputs: no game bytes or extracted proprietary code."""
import hashlib
import pathlib
import struct
import subprocess
import sys
import tempfile
import unittest

PROBE = pathlib.Path(sys.argv.pop(1)).resolve()
BASE = 0x100000000
PAGE = 16384


def segment(name, address, size, fileoff, filesize, maxprot, prot, sections=b''):
    return struct.pack('<II16sQQQQiiII', 0x19, 72 + len(sections), name.encode(),
                       address, size, fileoff, filesize, maxprot, prot, len(sections) // 80, 0) + sections


def fixture():
    section = struct.pack('<16s16sQQIIIIIIII', b'__mod_init_func', b'__DATA',
                          BASE + PAGE, 8, PAGE, 3, 0, 0, 9, 0, 0, 0)
    commands = [segment('__PAGEZERO', 0, BASE, 0, 0, 0, 0),
                segment('__TEXT', BASE, PAGE, 0, PAGE, 7, 5),
                segment('__DATA', BASE + PAGE, PAGE, PAGE, 8, 3, 3, section),
                struct.pack('<IIQQ', 0x80000028, 24, 0x1000, 0)]
    header = struct.pack('<IiiIIIII', 0xfeedfacf, 0x100000c, 0, 2, len(commands),
                         sum(map(len, commands)), 0x200000, 0)
    data = bytearray(PAGE + 8)
    data[:len(header)] = header
    blob = b''.join(commands)
    data[32:32 + len(blob)] = blob
    struct.pack_into('<I', data, 0x1000, 0xd65f03c0)
    struct.pack_into('<Q', data, PAGE, BASE + 0x1000)
    return data


def library_fixture(trie=None, modern=False, base=0):
    if trie is None:
        trie = b'\0\1_sample\0\x0b\3\0\x80\x20\0'
    export = (struct.pack('<IIII', 0x80000033, 16, 0x2000, len(trie)) if modern else
              struct.pack('<12I', 0x80000022, 48, 0, 0, 0, 0, 0, 0, 0, 0, 0x2000, len(trie)))
    commands = [segment('__TEXT', base, PAGE, 0, PAGE, 5, 5), export]
    data = bytearray(PAGE)
    struct.pack_into('<8I', data, 0, 0xfeedfacf, 0x100000c, 0, 6,
                     len(commands), sum(map(len, commands)), 0, 0)
    blob = b''.join(commands)
    data[32:32 + len(blob)] = blob
    struct.pack_into('<I', data, 0x1000, 0xd65f03c0)
    data[0x2000:0x2000 + len(trie)] = trie
    return data


class ImageTests(unittest.TestCase):
    def probe(self, data, valid=True, options=()):
        with tempfile.TemporaryDirectory() as tmp:
            path = pathlib.Path(tmp) / 'OriginalExecutable'
            path.write_bytes(data)
            before = hashlib.sha256(data).digest()
            result = subprocess.run([str(PROBE), str(path), *options], text=True, capture_output=True, timeout=10)
            self.assertEqual(hashlib.sha256(path.read_bytes()).digest(), before)
            self.assertEqual(result.returncode, 0 if valid else 1, result.stdout + result.stderr)
            self.assertNotIn('AddressSanitizer', result.stderr)
            self.assertNotIn('runtime error:', result.stderr)
            return result.stdout

    def test_thin_and_fat(self):
        data = fixture()
        self.assertIn('first=0x100001000', self.probe(data))
        for magic, record in [(0xcafebabe, struct.pack('>IIIII', 0x100000c, 0, PAGE, len(data), 14)),
                              (0xcafebabf, struct.pack('>IIQQII', 0x100000c, 0, PAGE, len(data), 14, 0))]:
            fat = struct.pack('>II', magic, 1) + record
            fat += bytes(PAGE - len(fat)) + data
            self.assertIn('slice offset=0x4000', self.probe(fat))

    def test_truncation(self):
        data = fixture()
        for size in [0, 4, 31, 32, 80, PAGE, len(data) - 1]:
            self.probe(data[:size], False)

    def test_invalid_commands_and_arch(self):
        for offset, value in [(12, 6), (4, 0x1000007), (8, 2), (20, 0xffffffff),
                              (36, 0), (36, 9), (36, 0xfffffff8), (16, 0xffffffff)]:
            data = fixture()
            struct.pack_into('<I', data, offset, value)
            self.probe(data, False)

    def test_invalid_segments_and_entry(self):
        for offset, value in [(32 + 72 + 24, 0),  # overlaps PAGEZERO
                              (32 + 72 + 32, 0xffffffffffffc000),  # wraps VA
                              (32 + 72 + 48, PAGE * 2),  # file size exceeds VM size
                              (32 + 72 + 72 + 152 + 8, PAGE),  # entry points into RW data
                              (PAGE, BASE + PAGE)]:  # initializer is not executable
            data = fixture()
            struct.pack_into('<Q', data, offset, value)
            self.probe(data, False)

    def test_bad_fat(self):
        data = fixture()
        for offset, size, align in [(PAGE, len(data) + 1, 14), (1, 32, 0), (PAGE, len(data), 64)]:
            header = struct.pack('>IIIIIII', 0xcafebabe, 1, 0x100000c, 0, offset, size, align)
            self.probe(header + bytes(PAGE - len(header)) + data, False)

    def test_library_is_explicit_and_exports_are_relative_to_header(self):
        self.probe(library_fixture(), False)
        self.probe(fixture(), False, ('--library',))
        for modern in (False, True):
            for base in (0, BASE):
                output = self.probe(library_fixture(modern=modern, base=base), options=(
                    '--library', '--validate-fixups', '--export', '_sample'))
                self.assertIn('MH_DYLIB', output)
                self.assertIn(f'_sample={base + 0x1000:#x} absolute=0', output)
        self.probe(library_fixture(), False, ('--library', '--export', '_missing'))
        self.probe(library_fixture(), False, ('--library', '--export', '_sam'))
        self.probe(library_fixture(), False, ('--library', '--export', '_sample_suffix'))

    def test_absolute_and_weak_exports(self):
        for flag in (2, 4):
            trie = b'\0\1_sample\0\x0b\3' + bytes([flag]) + b'\x80\x20\0'
            output = self.probe(library_fixture(trie, base=BASE), options=(
                '--library', '--export', '_sample'))
            self.assertIn('_sample=0x1000 absolute=1' if flag == 2 else
                          '_sample=0x100001000 absolute=0', output)
        # Apple linkers may represent a symbol that prefixes another symbol by
        # giving its node an empty edge to the terminal.
        trie = b'\0\1_sample\0\x0b\0\1\0\x0f\3\0\x80\x20\0'
        self.assertIn('_sample=0x1000 absolute=0', self.probe(
            library_fixture(trie), options=('--library', '--export', '_sample')))

    def test_malformed_and_unsupported_exports(self):
        root = b'\0\1_sample\0\x0b'
        for trie in [b'\x80', b'\0', b'\0\1', b'\0\1_sample',
                     b'\0\1_sample\0\x7f', b'\0\1\0\0',
                     root + b'\x7f\0', root + b'\3\0\x80',
                     root + b'\3\0\x80\x80\0',  # truncated ULEB
                     root + b'\3\0\x80\x80\1\0',  # wrong terminal size
                     root + b'\4\0\x80\x80\1\0',  # address beyond mapping
                     root + b'\x0b\0' + b'\xff' * 9 + b'\2\0',
                     *[root + b'\3' + bytes([flag]) + b'\x80\x20\0' for flag in (1, 3, 8, 16, 32)]]:
            self.probe(library_fixture(trie), False, ('--library', '--export', '_sample'))
        # A cycle consumes the query, then returns missing rather than looping.
        self.probe(library_fixture(b'\0\1a\0\0'), False, ('--library', '--export', 'aaaa'))


if __name__ == '__main__':
    unittest.main()
