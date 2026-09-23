"""tools/build_signed_container.py: synthetic Mach-O guests, container layout,
signing, and a macOS end-to-end load of the in-repo TestGuest's container
through runtime/SignedImage.c (tests/signed_container_host.c). No keychain."""
import os
import pathlib
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
BASE, PAGE = 0x100000000, 0x4000
RET = struct.pack('<I', 0xD65F03C0)


def segment(name, vmaddr, vmsize, fileoff, filesize, prot, sections=()):
    body = b''.join(sections)
    return struct.pack('<II16sQQQQiiII', 0x19, 72 + len(body), name.encode(), vmaddr, vmsize, fileoff, filesize,
                       prot, prot, len(sections), 0) + body


def section(name, segname, addr, size, offset, flags=0):
    return struct.pack('<16s16sQQIIIIIIII', name.encode(), segname.encode(), addr, size, offset, 2, 0, 0, flags, 0, 0, 0)


def guest(exec_data=False, text_fileoff=0, extra=b'', initializer=BASE + PAGE, symtab=True, fat=False, text_vmsize=2 * PAGE):
    """MH_EXECUTE: __TEXT (2 pages, __text on page 1), __DATA (__mod_init_func), __LINKEDIT (one symbol _leaf)."""
    strings = b'\0_leaf\0'
    commands = [segment('__TEXT', BASE, text_vmsize, text_fileoff, 2 * PAGE, 5,
                        [section('__text', '__TEXT', BASE + PAGE, PAGE, PAGE, 0x80000400)]),
                segment('__DATA', BASE + 2 * PAGE, PAGE, 2 * PAGE, PAGE, 7 if exec_data else 3,
                        [section('__mod_init_func', '__DATA', BASE + 2 * PAGE, 8, 2 * PAGE, 9)]),
                segment('__LINKEDIT', BASE + 3 * PAGE, PAGE, 3 * PAGE, 16 + len(strings), 1)]
    if symtab: commands.append(struct.pack('<IIIIII', 0x2, 24, 3 * PAGE, 1, 3 * PAGE + 16, len(strings)))
    blob = b''.join(commands) + extra
    ncmds = len(commands) + (1 if extra else 0)
    data = bytearray(3 * PAGE + 16 + len(strings))
    data[:32] = struct.pack('<IiiIIIII', 0xFEEDFACF, 0x0100000C, 0, 2, ncmds, len(blob), 0x200085, 0)
    data[32:32 + len(blob)] = blob
    data[PAGE:2 * PAGE] = RET * (PAGE // 4)
    struct.pack_into('<Q', data, 2 * PAGE, initializer)
    struct.pack_into('<IBBHQ', data, 3 * PAGE, 1, 0x0F, 1, 0, BASE + PAGE + 8)
    data[3 * PAGE + 16:] = strings
    if not fat: return bytes(data)
    header = struct.pack('>IIiiIII', 0xCAFEBABE, 2, 0x01000007, 3, PAGE, 16, 14)
    header += struct.pack('>iiIII', 0x0100000C, 0, 2 * PAGE, len(data), 14)
    return header.ljust(PAGE, b'\0') + bytes(16).ljust(PAGE, b'\0') + bytes(data)


def parse_container(data):
    ncmds, sizeofcmds = struct.unpack_from('<II', data, 16)
    out, cursor = {'filetype': struct.unpack_from('<I', data, 12)[0], 'ncmds': ncmds, 'segments': []}, 32
    for _ in range(ncmds):
        cmd, size = struct.unpack_from('<II', data, cursor)
        if cmd == 0x19:
            name = data[cursor + 8:cursor + 24].rstrip(b'\0').decode()
            vmaddr, vmsize, fileoff, filesize = struct.unpack_from('<QQQQ', data, cursor + 24)
            sections = [struct.unpack_from('<QQI', data, cursor + 72 + 80 * j + 32)
                        for j in range(struct.unpack_from('<I', data, cursor + 64)[0])]
            out['segments'].append((name, vmaddr, vmsize, fileoff, filesize, sections))
        elif cmd == 0x32: out['platform'] = struct.unpack_from('<I', data, cursor + 8)[0]
        elif cmd == 0x2:
            symoff, nsyms, stroff, _ = struct.unpack_from('<IIII', data, cursor + 8)
            out['symbols'] = {}
            for i in range(nsyms):
                strx, _, _, _, value = struct.unpack_from('<IBBHQ', data, symoff + 16 * i)
                out['symbols'][data[stroff + strx:data.index(b'\0', stroff + strx)].decode()] = value
        cursor += size
    return out


class BuilderTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = pathlib.Path(tempfile.mkdtemp(prefix='bsc-test-'))
        cls.signer = cls.tmp / 'sign_guest_local'
        subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-O1', '-Wall', '-Wextra', '-Werror', '-framework', 'Foundation',
                        '-framework', 'Security', str(ROOT / 'tools/sign_guest_local.m'), '-o', str(cls.signer)], check=True)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def write(self, name, data):
        path = self.tmp / name
        path.write_bytes(data)
        return path

    def build(self, exe, *options, expect=0):
        out = self.tmp / (exe.name + '.dylib')
        out.unlink(missing_ok=True)
        result = subprocess.run([sys.executable, str(ROOT / 'tools/build_signed_container.py'), '--guest', str(exe),
                                 '--signer', str(self.signer), '--output', str(out), *options],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, expect, result.stdout + result.stderr)
        if expect: self.assertFalse(out.exists(), 'failed build left an output')
        return out, result.stdout + result.stderr

    def test_layout_and_markers(self):
        for fat in (False, True):
            exe = self.write(f'g-fat{fat}', guest(fat=fat))
            out, text = self.build(exe, '--platform', 'iossimulator', '--sign', 'none', '--probe-symbol', '_leaf')
            data = out.read_bytes()
            c = parse_container(data)
            self.assertEqual((c['filetype'], c['ncmds'], c['platform']), (6, 7, 7))
            text_seg, linkedit = c['segments']
            self.assertEqual(text_seg[:5], ('__TEXT', 0, PAGE + 2 * PAGE, 0, PAGE + 2 * PAGE))
            self.assertEqual(text_seg[5], [(PAGE, 2 * PAGE, PAGE)])
            self.assertEqual(data[PAGE:3 * PAGE], guest()[:2 * PAGE])
            self.assertEqual(linkedit[0], '__LINKEDIT')
            self.assertEqual(linkedit[3] + linkedit[4], len(data), '__LINKEDIT must end the file')
            self.assertTrue(linkedit[2] % PAGE == 0 and linkedit[2] >= linkedit[4])
            self.assertEqual(c['symbols'], {'_guest_test': PAGE + PAGE + 8, '_tolkara_container_final': PAGE,
                                            '_tolkara_container_v1': PAGE})
            self.assertEqual(list(c['symbols']), sorted(c['symbols']))
            self.assertIn('0 rewritten at launch', text)

    def test_platforms(self):
        exe = self.write('g-platform', guest())
        for platform, number in (('ios', 2), ('iossimulator', 7), ('macos', 1)):
            out, _ = self.build(exe, '--platform', platform, '--sign', 'none')
            self.assertEqual(parse_container(out.read_bytes())['platform'], number)

    def test_capture(self):
        exe = self.write('g-capture', guest())
        image = bytearray(guest()[:2 * PAGE])
        image[0x1000] ^= 0xFF      # page 0 rewritten, initializer on page 1 stays signed
        out, text = self.build(exe, '--capture', str(self.write('capture-ok', bytes(image))), '--sign', 'none',
                               '--platform', 'ios')
        self.assertEqual(out.read_bytes()[PAGE:3 * PAGE], bytes(image))
        self.assertIn('1 rewritten at launch (from capture capture-ok)', text)
        _, text = self.build(exe, '--capture', str(self.write('capture-short', bytes(image[:-1]))), '--sign', 'none', expect=1)
        self.assertIn('capture is', text)
        _, text = self.build(exe, '--capture', str(self.write('capture-long', bytes(image) + b'\0')), '--sign', 'none', expect=1)
        self.assertIn('capture is', text)
        other = bytearray(image); other[20] ^= 1
        _, text = self.build(exe, '--capture', str(self.write('capture-other', bytes(other))), '--sign', 'none', expect=1)
        self.assertIn('different build', text)
        inside = bytearray(guest()[:2 * PAGE]); inside[PAGE + 16] ^= 0xFF
        _, text = self.build(exe, '--capture', str(self.write('capture-init', bytes(inside))), '--sign', 'none', expect=1)
        self.assertIn('inside the rewritten range', text)

    def test_rejections(self):
        cases = {
            'only executable segment is __TEXT': guest(exec_data=True),
            'must start at file offset 0': guest(text_fileoff=PAGE),
            'exceed the first 16 KiB page': guest(extra=struct.pack('<II', 0x31, PAGE) + bytes(PAGE - 8)),
            'chained fixups': guest(extra=struct.pack('<IIII', 0x80000034, 16, 0, 0)),
            'first initializer lies outside __TEXT': guest(initializer=BASE + 2 * PAGE),
            'more than the runtime accepts': guest(text_vmsize=1 << 32),
            'not an arm64 Mach-O': b'\xcf\xfa\xed\xfe' + bytes(60),
            'too small for a Mach-O header': b'\xcf\xfa',
        }
        for message, data in cases.items():
            with self.subTest(message):
                _, text = self.build(self.write('bad', data), '--sign', 'none', expect=1)
                self.assertIn(message, text)

    def test_probe_validation(self):
        exe = self.write('g-probe', guest())
        _, text = self.build(exe, '--probe-symbol', '_missing', '--sign', 'none', expect=1)
        self.assertIn('not defined', text)
        for offset in ('0x8000', '0x2', '-4'):
            _, text = self.build(exe, '--probe-offset', offset, '--sign', 'none', expect=1)
            self.assertIn('probe offset', text)
        _, text = self.build(self.write('g-nosym', guest(symtab=False)), '--probe-symbol', '_leaf', '--sign', 'none', expect=1)
        self.assertIn('no symbol table', text)

    def test_capture_default_follows_guest_exe(self):
        exe, image = self.write('g-env', guest()), bytearray(guest()[:2 * PAGE])
        image[0x1000] ^= 0xFF
        capture = self.write('capture-env', bytes(image))
        env = dict(os.environ, GUEST_EXE=str(exe), TOLKARA_CAPTURE=str(capture))
        run = lambda *extra: subprocess.run([sys.executable, str(ROOT / 'tools/build_signed_container.py'), '--sign', 'none',
                                             '--output', str(self.tmp / 'env.dylib'), *extra],
                                            capture_output=True, text=True, env=env)
        result = run()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('1 rewritten at launch (from capture', result.stdout)
        result = run('--guest', str(exe))   # a capture never follows an explicitly named executable
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('0 rewritten at launch (on-disk bytes)', result.stdout)

    def test_adhoc_signature_verifies(self):
        out, text = self.build(self.write('g-sign', guest()), '--platform', 'macos', '--sign', 'adhoc')
        self.assertIn('signed adhoc', text)
        self.assertEqual(subprocess.run([str(self.signer), '--verify', str(out)], capture_output=True).returncode, 0)
        self.assertEqual(subprocess.run(['codesign', '-v', '--strict', str(out)], capture_output=True).returncode, 0)


class EndToEndTests(unittest.TestCase):
    """dyld-validated container pages, runtime contract checks, remap, native call."""
    @classmethod
    def setUpClass(cls):
        cls.tmp = pathlib.Path(tempfile.mkdtemp(prefix='bsc-e2e-'))
        cc = ['xcrun', '--sdk', 'macosx', 'clang', '-fobjc-arc', '-arch', 'arm64', '-mmacosx-version-min=14.0',
              '-Wl,-no_fixup_chains', str(ROOT / 'testguest/main.m'), '-framework', 'Cocoa', '-framework', 'Metal',
              '-framework', 'QuartzCore']
        subprocess.run(cc + ['-O1', '-o', str(cls.tmp / 'TestGuest')], check=True)
        subprocess.run(cc + ['-O0', '-o', str(cls.tmp / 'TestGuestOther')], check=True)
        subprocess.run(['xcrun', 'clang', '-std=c11', '-D_DARWIN_C_SOURCE', '-Wall', '-Wextra', '-Werror', '-O1', '-g',
                        '-fsanitize=address,undefined', '-I' + str(ROOT / 'runtime'),
                        *(str(ROOT / f) for f in ('runtime/GuestMemory.c', 'runtime/GuestImage.c', 'runtime/SignedImage.c',
                                                  'tests/signed_container_host.c')),
                        '-o', str(cls.tmp / 'host')], check=True)
        subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-O1', '-Wall', '-Wextra', '-Werror', '-framework', 'Foundation',
                        '-framework', 'Security', str(ROOT / 'tools/sign_guest_local.m'), '-o', str(cls.tmp / 'signer')],
                       check=True)
        cls.container = cls.tmp / 'container.dylib'
        subprocess.run([sys.executable, str(ROOT / 'tools/build_signed_container.py'), '--guest', str(cls.tmp / 'TestGuest'),
                        '--platform', 'macos', '--sign', 'adhoc', '--probe-symbol', '_tolkara_probe_leaf',
                        '--signer', str(cls.tmp / 'signer'), '--output', str(cls.container)], check=True, capture_output=True)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def host(self, exe, container):
        return subprocess.run([str(self.tmp / 'host'), str(exe), str(container)], capture_output=True, text=True, timeout=60)

    def test_remapped_probe_runs(self):
        result = self.host(self.tmp / 'TestGuest', self.container)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('shadow 0 pages', result.stdout)
        self.assertIn('probe=0x12345678', result.stdout)

    def test_other_build_is_rejected(self):
        result = self.host(self.tmp / 'TestGuestOther', self.container)
        self.assertEqual(result.returncode, 7, result.stdout + result.stderr)
        self.assertIn('different executable', result.stdout)

    def test_tampered_container_never_runs(self):
        # A byte no runtime check reads (zero pad after the container's own load
        # commands, inside the signed __TEXT): only code signing can catch it.
        data = bytearray(self.container.read_bytes())
        self.assertEqual(data[PAGE - 16], 0)
        data[PAGE - 16] = 0xFF
        tampered = self.tmp / 'tampered.dylib'
        tampered.write_bytes(bytes(data))
        result = self.host(self.tmp / 'TestGuest', tampered)
        self.assertEqual(result.returncode, -signal.SIGKILL, result.stdout + result.stderr)
        self.assertNotIn('probe=', result.stdout)


if __name__ == '__main__':
    unittest.main()
