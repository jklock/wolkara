#!/usr/bin/env python3
"""Build and sign a Local signing page container for a macOS executable you own.

The container is a minimal arm64 MH_DYLIB. Its first 16 KiB page holds its own
header; its __TEXT,__text section, at offset 0x4000, holds the guest's final
__TEXT pages byte for byte. The exported markers tolkara_container_v1 and
tolkara_container_final mark the start of that image. Before any guest code
runs, runtime/SignedImage.c checks this layout and binds the image to the
executable: same __TEXT size, same header and load commands (LC_UUID included).

Final pages: without --capture, the on-disk __TEXT bytes. That is right only
for applications that do not rewrite their own code at launch. For those that
do, pass --capture: the application's __TEXT exactly as it is after its
unpacking initializer ran (Tolkara cannot produce such a capture on the iPad
yet). Everything is derived from the executable's own Mach-O headers.
Defaults come from the environment, then local.env: GUEST_EXE, TOLKARA_CAPTURE
(only with GUEST_EXE's executable), DEVELOPMENT_TEAM and SIGN_IDENTITY.

The output is signed with your developer identity (--sign identity, default for
iOS) or ad hoc (--sign adhoc, default for the simulator and macOS) by
tools/sign_guest_local.m, and verified. --sign none leaves it unsigned. The
executable is only read. The output is local build output: never commit it.
"""
import argparse
import hashlib
import os
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import localenv  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
PAGE = 0x4000
CPU_ARM64, CPU_SUBTYPE_ARM64E = 0x0100000C, 2
MH_MAGIC_64, MH_EXECUTE, MH_DYLIB = 0xFEEDFACF, 2, 6
LC_SEGMENT_64, LC_SYMTAB, LC_DYSYMTAB, LC_ID_DYLIB, LC_UUID, LC_BUILD_VERSION = 0x19, 0x2, 0xB, 0xD, 0x1B, 0x32
LC_DYLD_CHAINED_FIXUPS = 0x80000034
S_MOD_INIT_FUNC_POINTERS, SECTION_TYPE = 0x9, 0xFF
PLATFORMS = {'ios': (2, 0x110000), 'iossimulator': (7, 0x110000), 'macos': (1, 0x0E0000)}
TEXT_LIMIT = 1 << 31   # the runtime's per-segment budget (runtime/GuestImage.c)


class BuildError(Exception):
    pass


def u32(data, offset): return struct.unpack_from('<I', data, offset)[0]
def u64(data, offset): return struct.unpack_from('<Q', data, offset)[0]
def name16(raw): return raw.split(b'\0', 1)[0].decode('ascii', 'replace')


def within(offset, size, total): return 0 <= offset <= total and 0 <= size <= total - offset


def arm64_slice(data):
    """The thin arm64 (not arm64e) Mach-O inside a thin or fat file."""
    if len(data) < 8: raise BuildError('file too small for a Mach-O header')
    magic = struct.unpack_from('>I', data, 0)[0]
    if magic not in (0xCAFEBABE, 0xCAFEBABF): return data
    count, wide = struct.unpack_from('>I', data, 4)[0], magic == 0xCAFEBABF
    entry = 32 if wide else 20
    if count > 64 or not within(8, count * entry, len(data)): raise BuildError('malformed fat header')
    for i in range(count):
        at = 8 + i * entry
        if wide: cpu, sub, offset, size = struct.unpack_from('>iiQQ', data, at)
        else: cpu, sub, offset, size = struct.unpack_from('>iiII', data, at)
        if cpu == CPU_ARM64 and (sub & 0xFF) != CPU_SUBTYPE_ARM64E:
            if not within(offset, size, len(data)): raise BuildError('fat arm64 slice lies outside the file')
            return data[offset:offset + size]
    raise BuildError('no arm64 slice in the fat file')


def parse_guest(path):
    data = arm64_slice(Path(path).read_bytes())
    if len(data) < 32: raise BuildError('truncated Mach-O header')
    magic, cpu, _, filetype, ncmds, sizeofcmds = struct.unpack_from('<IiiIII', data, 0)
    if magic != MH_MAGIC_64 or cpu != CPU_ARM64: raise BuildError('not an arm64 Mach-O')
    if filetype != MH_EXECUTE: raise BuildError('not an executable (MH_EXECUTE)')
    if not within(32, sizeofcmds, len(data)): raise BuildError('load commands extend past the end of the file')
    segments, symtab, initializers, cursor, end = [], None, [], 32, 32 + sizeofcmds
    for index in range(ncmds):
        if not within(cursor, 8, end): raise BuildError(f'load command {index} lies past sizeofcmds')
        cmd, cmdsize = u32(data, cursor), u32(data, cursor + 4)
        if cmdsize < 8 or cmdsize % 8 or not within(cursor, cmdsize, end):
            raise BuildError(f'invalid load command {index} (cmdsize {cmdsize})')
        if cmd == LC_DYLD_CHAINED_FIXUPS:
            raise BuildError("the executable uses chained fixups; Tolkara's loader applies classic dyld info only")
        if cmd == LC_SEGMENT_64:
            if cmdsize < 72: raise BuildError(f'truncated segment command {index}')
            name = name16(data[cursor + 8:cursor + 24])
            vmaddr, vmsize, fileoff, filesize = struct.unpack_from('<QQQQ', data, cursor + 24)
            initprot, nsects = u32(data, cursor + 60), u32(data, cursor + 64)
            if nsects > (cmdsize - 72) // 80: raise BuildError(f'segment {name} sections exceed its command')
            if not within(fileoff, filesize, len(data)): raise BuildError(f'segment {name} lies outside the file')
            segments.append({'name': name, 'vmaddr': vmaddr, 'vmsize': vmsize, 'fileoff': fileoff,
                             'filesize': filesize, 'initprot': initprot})
            for j in range(nsects):
                at = cursor + 72 + 80 * j
                addr, size, offset = struct.unpack_from('<QQI', data, at + 32)
                if u32(data, at + 64) & SECTION_TYPE == S_MOD_INIT_FUNC_POINTERS:
                    initializers.append((addr, size, offset))
        elif cmd == LC_SYMTAB:
            if cmdsize < 24: raise BuildError('truncated LC_SYMTAB')
            symtab = struct.unpack_from('<IIII', data, cursor + 8)
        cursor += cmdsize
    if cursor != end: raise BuildError('sizeofcmds disagrees with the load commands')
    executable = [s for s in segments if s['initprot'] & 4]
    if len(executable) != 1 or executable[0]['name'] != '__TEXT':
        raise BuildError('Local signing supports executables whose only executable segment is __TEXT')
    text = executable[0]
    if (text['fileoff'] or not text['vmsize'] or text['vmsize'] % PAGE or text['vmaddr'] % PAGE or
            text['filesize'] > text['vmsize']):
        raise BuildError('__TEXT must start at file offset 0 and span whole 16 KiB pages')
    if text['vmsize'] > TEXT_LIMIT: raise BuildError(f"__TEXT is {text['vmsize']:#x} bytes, more than the runtime accepts")
    header_size = 32 + sizeofcmds
    if header_size > min(PAGE, text['filesize']):
        raise BuildError('header and load commands exceed the first 16 KiB page')
    if len(initializers) != 1 or initializers[0][1] < 8 or initializers[0][1] % 8 or not within(initializers[0][2], 8, len(data)):
        raise BuildError('expected one __mod_init_func section with at least one initializer')
    first = u64(data, initializers[0][2]) - text['vmaddr']
    if not 0 <= first < text['vmsize']: raise BuildError('the first initializer lies outside __TEXT')
    return {'data': data, 'text': text, 'header_size': header_size, 'initializer': first, 'symtab': symtab}


def resolve_symbol(guest, name):
    data, text = guest['data'], guest['text']
    if not guest['symtab']: raise BuildError('the executable has no symbol table')
    symoff, nsyms, stroff, strsize = guest['symtab']
    if not within(symoff, nsyms * 16, len(data)) or not within(stroff, strsize, len(data)):
        raise BuildError('symbol table lies outside the file')
    wanted = name.encode()
    for i in range(nsyms):
        strx, kind, _, _, value = struct.unpack_from('<IBBHQ', data, symoff + 16 * i)
        if kind & 0xE0 or kind & 0x0E != 0x0E or strx >= strsize: continue
        start = stroff + strx
        stop = data.find(b'\0', start, stroff + strsize)
        if stop >= 0 and data[start:stop] == wanted: return value - text['vmaddr']
    raise BuildError(f'symbol {name} is not defined in the executable')


def final_image(guest, capture):
    data, text, header = guest['data'], guest['text'], guest['header_size']
    on_disk = data[:text['filesize']] + bytes(text['vmsize'] - text['filesize'])
    if capture is None: return on_disk, on_disk
    image = Path(capture).read_bytes()
    if len(image) != text['vmsize']:
        raise BuildError(f"capture is {len(image):#x} bytes but __TEXT is {text['vmsize']:#x} bytes")
    if image[:header] != data[:header]: raise BuildError('capture belongs to a different build of this executable')
    return image, on_disk


def rewritten_end(image, on_disk):
    end = 0
    for offset in range(0, len(image), PAGE):
        if image[offset:offset + PAGE] != on_disk[offset:offset + PAGE]: end = offset + PAGE
    return end


def container(image, platform, probe):
    """Unsigned MH_DYLIB carrying image at 0x4000; symbols sorted by name."""
    size = len(image)
    symbols = sorted([(b'_tolkara_container_final', PAGE), (b'_tolkara_container_v1', PAGE)] +
                     ([(b'_guest_test', PAGE + probe)] if probe is not None else []))
    name = b'/tolkara/page-container.dylib\0'
    id_size = (24 + len(name) + 7) & ~7
    sizeofcmds = (72 + 80) + 72 + id_size + 24 + 24 + 80 + 24
    text_end = PAGE + size
    symoff = text_end
    strings = b'\0' + b''.join(s + b'\0' for s, _ in symbols)
    stroff = symoff + 16 * len(symbols)
    strsize = (len(strings) + 7) & ~7
    end = (stroff + strsize + 15) & ~15
    linkedit_size = end - text_end
    platform_id, minos = PLATFORMS[platform]
    commands = struct.pack('<II16sQQQQiiII', LC_SEGMENT_64, 72 + 80, b'__TEXT', 0, text_end, 0, text_end, 5, 5, 1, 0)
    commands += struct.pack('<16s16sQQIIIIIIII', b'__text', b'__TEXT', PAGE, size, PAGE, 14, 0, 0, 0x80000400, 0, 0, 0)
    commands += struct.pack('<II16sQQQQiiII', LC_SEGMENT_64, 72, b'__LINKEDIT', text_end,
                            (linkedit_size + PAGE - 1) & ~(PAGE - 1), text_end, linkedit_size, 1, 1, 0, 0)
    commands += struct.pack('<IIIIII', LC_ID_DYLIB, id_size, 24, 0, 0x10000, 0x10000) + name.ljust(id_size - 24, b'\0')
    commands += struct.pack('<IIIIII', LC_BUILD_VERSION, 24, platform_id, minos, minos, 0)
    commands += struct.pack('<IIIIII', LC_SYMTAB, 24, symoff, len(symbols), stroff, strsize)
    commands += struct.pack('<II18I', LC_DYSYMTAB, 80, 0, 0, 0, len(symbols), len(symbols), 0, *([0] * 12))
    commands += struct.pack('<II', LC_UUID, 24) + hashlib.sha256(image).digest()[:16]
    assert len(commands) == sizeofcmds
    header = struct.pack('<IiiIIIII', MH_MAGIC_64, CPU_ARM64, 0, MH_DYLIB, 7, sizeofcmds, 0x00100085, 0)
    out = bytearray(header + commands)
    out += bytes(PAGE - len(out))
    out += image
    offset = 1
    for symbol, value in symbols:
        out += struct.pack('<IBBHQ', offset, 0x0F, 1, 0, value)
        offset += len(symbol) + 1
    out += strings.ljust(strsize, b'\0')
    out += bytes(end - len(out))
    return bytes(out)


def signer(path):
    """build/sign-local/sign_guest_local, rebuilt when missing or older than its source."""
    if path: return Path(path)
    tool, source = ROOT / 'build/sign-local/sign_guest_local', ROOT / 'tools/sign_guest_local.m'
    if not tool.exists() or tool.stat().st_mtime < source.stat().st_mtime:
        tool.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-O1', '-Wall', '-Wextra', '-Werror', '-framework', 'Foundation',
                        '-framework', 'Security', str(source), '-o', str(tool)], check=True)
    return tool


def shown(path):
    try: return str(Path(path).resolve().relative_to(ROOT))
    except ValueError: return Path(path).name


def main(argv=None):
    env = localenv.load()
    def setting(key): return os.environ.get(key) or env.get(key) or None
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0],
                                     epilog='Without --capture the on-disk __TEXT is used: right only for applications '
                                            'that do not rewrite their own code at launch.')
    parser.add_argument('--guest', help='macOS executable (default: GUEST_EXE)')
    parser.add_argument('--capture', help="the executable's final __TEXT, for applications that rewrite their code at launch "
                                          '(default with GUEST_EXE: TOLKARA_CAPTURE)')
    parser.add_argument('--platform', choices=sorted(PLATFORMS), default='ios')
    parser.add_argument('--sign', choices=('identity', 'adhoc', 'none'))
    parser.add_argument('--identity', default=setting('SIGN_IDENTITY') or 'Apple Development',
                        help='signing identity: CN substring, CN or SHA-1 (default: SIGN_IDENTITY or "Apple Development")')
    parser.add_argument('--team', default=setting('DEVELOPMENT_TEAM'), help='only identities of this team (default: DEVELOPMENT_TEAM)')
    parser.add_argument('--identifier', default='tolkara.page-container')
    probe = parser.add_mutually_exclusive_group()
    probe.add_argument('--probe-symbol', help="export this guest function as guest_test for tools/probe_signed_file.sh's "
                                              'dlopen and remap modes')
    probe.add_argument('--probe-offset', type=lambda v: int(v, 0), help='same, as an offset from the start of __TEXT')
    parser.add_argument('--output', default='build/signed-image/page-container.dylib', help='relative to the repository')
    parser.add_argument('--signer', help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    if not args.guest:
        # A capture belongs to GUEST_EXE's executable, never to one named with --guest.
        args.guest = setting('GUEST_EXE')
        if args.capture is None: args.capture = setting('TOLKARA_CAPTURE')
    if not args.guest: parser.error('no executable: pass --guest or set GUEST_EXE in local.env')
    sign = args.sign or ('identity' if args.platform == 'ios' else 'adhoc')
    output = Path(args.output) if Path(args.output).is_absolute() else ROOT / args.output
    try:
        guest = parse_guest(args.guest)
        image, on_disk = final_image(guest, args.capture)
        rewritten = rewritten_end(image, on_disk)
        if guest['initializer'] < rewritten:
            raise BuildError(f"the first initializer (__TEXT+{guest['initializer']:#x}) lies inside the rewritten range "
                             f"(ends at +{rewritten:#x}); Local signing cannot run this executable")
        offset = resolve_symbol(guest, args.probe_symbol) if args.probe_symbol else args.probe_offset
        if offset is not None and (offset < 0 or offset % 4 or offset + 4 > len(image)):
            raise BuildError(f'probe offset {offset:#x} is outside __TEXT or not 4-byte aligned')
        unsigned = container(image, args.platform, offset)
        output.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(dir=output.parent, prefix='.unsigned-', delete=False) as handle:
            handle.write(unsigned)
        temporary = Path(handle.name)
        try:
            if sign == 'none':
                os.replace(temporary, output)
            else:
                tool = signer(args.signer)
                command = [str(tool), '--adhoc'] if sign == 'adhoc' else [str(tool), '-s', args.identity]
                if sign == 'identity' and args.team: command += ['--team', args.team]
                result = subprocess.run(command + ['-i', args.identifier, str(temporary), str(output)])
                if result.returncode == 3:
                    raise BuildError('the keychain denied access to the signing key: run this from a terminal and '
                                     'choose "Always Allow" in the approval dialog')
                if result.returncode: raise BuildError(f'signing failed (sign_guest_local exit {result.returncode})')
                if subprocess.run([str(tool), '--verify', str(output)], stdout=subprocess.DEVNULL).returncode:
                    output.unlink(missing_ok=True)
                    raise BuildError('the signed container failed verification')
        finally:
            temporary.unlink(missing_ok=True)
    except (OSError, BuildError, subprocess.CalledProcessError, struct.error, MemoryError) as error:
        sys.exit(f'build_signed_container: {error}')
    pages = len(image) // PAGE
    print(f"{shown(output)}: {pages} __TEXT pages, {rewritten // PAGE} rewritten at launch "
          f"({'from capture ' + shown(args.capture) if args.capture else 'on-disk bytes'}), first initializer at +{guest['initializer']:#x}"
          + (f', guest_test at +{offset:#x}' if offset is not None else '')
          + (', unsigned' if sign == 'none' else f', signed {sign}'))


if __name__ == '__main__':
    main()
