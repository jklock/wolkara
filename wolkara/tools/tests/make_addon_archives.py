"""Deterministic small ZIP corpus; no downloaded add-ons or user files."""
import pathlib
import stat
import sys
import zipfile

root = pathlib.Path(sys.argv[1])
root.mkdir(parents=True, exist_ok=True)

def archive(name, entries, compression=zipfile.ZIP_DEFLATED):
    with zipfile.ZipFile(root / (name + '.zip'), 'w', compression=compression) as out:
        for path, data in entries:
            out.writestr(path, data)

toc = b'## Interface: 16001\n## Title: Wolkara Fixture\n## Version: 1\nmain.lua\n'
archive('valid', [('Fixture/', b''), ('Fixture/Fixture.toc', toc), ('Fixture/main.lua', b'-- fixture\n')])
archive('nested', [('Wrapper/Fixture/Fixture.toc', toc)])
for name, path in [('traversal', '../outside'), ('absolute', '/outside'), ('double', 'Fixture//file'),
                   ('dot', 'Fixture/./file'), ('colon', 'Fixture/a:b'), ('control', 'Fixture/a\nb')]:
    archive(name, [(path, b'bad')])
archive('case', [('Fixture/a', b'a'), ('Fixture/A', b'b')])
archive('unicode', [('Fixture/caf\u00e9', b'a'), ('Fixture/cafe\u0301', b'b')])
link = zipfile.ZipInfo('Fixture/link')
link.create_system = 3
link.external_attr = (stat.S_IFLNK | 0o777) << 16
archive('symlink', [(link, b'../../outside')])
archive('corrupt', [('Fixture/Fixture.toc', toc)], zipfile.ZIP_STORED)
path = root / 'corrupt.zip'
data = path.read_bytes()
path.write_bytes(data.replace(b'Wolkara Fixture', b'Broken! Fixture'))
(root / 'invalid.zip').write_bytes(b'not a zip')
archive('file-directory', [('Fixture/a', b'file'), ('Fixture/a/b', b'child')])

archive('oversized-file', [('Fixture/large', b'0' * (64 * 1024 * 1024 + 1))])
archive('too-many', [(f'Fixture/{i}', b'') for i in range(20_001)])
