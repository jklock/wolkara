#!/usr/bin/env python3
"""Copy your own installed Cyberpunk 2077 (GOG, macOS) into the Tolkara app's Documents.

The application bundle, including the libraries it ships in Contents/Frameworks,
and the game data are copied unchanged. Saved games and settings are not copied.
devicectl skips unchanged files on subsequent runs.
"""
import argparse
import hashlib
import os
from pathlib import Path
import subprocess
import sys
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'tools'))
import localenv
BUNDLE_ID=localenv.bundle_id()
APP=Path('Cyberpunk2077.app')
EXECUTABLE=APP/'Contents/MacOS/Cyberpunk2077'
DATA=['archive','engine','r6']
# GOG Galaxy metadata beside the bundle; the game refuses to start without it.
METADATA=[Path('Contents')]


def sha256(path):
    digest=hashlib.sha256()
    with path.open('rb') as file:
        for chunk in iter(lambda:file.read(1024*1024),b''): digest.update(chunk)
    return digest.hexdigest()


def code(source):
    """The executable and every library the bundle ships: original code, verified around the copy."""
    return [EXECUTABLE,*sorted(path.relative_to(source) for path in (source/APP/'Contents/Frameworks').glob('*.dylib'))]


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device',default=localenv.load().get('DEVICE'),help='iPad UDID (default: DEVICE in local.env)')
    parser.add_argument('--source',type=Path,default=Path('/Applications/Cyberpunk 2077'))
    parser.add_argument('--skip-data',action='store_true',help='copy only the application bundle')
    args=parser.parse_args()
    if not args.device: parser.error('set DEVICE in local.env or pass --device')
    os.chdir(localenv.ROOT)
    os.environ.setdefault('DEVELOPER_DIR','/Applications/Xcode.app/Contents/Developer')
    source=args.source.resolve()
    if not (source/EXECUTABLE).is_file(): parser.error(f'original executable not found under {source}')
    missing=[name for name in DATA if not (source/name).is_dir()]
    if not args.skip_data and missing: parser.error('game data not found: '+', '.join(missing))
    before={path:sha256(source/path) for path in code(source)}
    def transfer(path,destination):
        subprocess.run(['xcrun','devicectl','device','copy','to','--device',args.device,
            '--domain-type','appDataContainer','--domain-identifier',BUNDLE_ID,
            '--source',str(path),'--destination',destination],check=True)
    transfer(source/APP,f'Documents/Cyberpunk 2077/{APP}')
    for name in METADATA:
        if (source/name).is_dir(): transfer(source/name,f'Documents/Cyberpunk 2077/{name}')
    if not args.skip_data:
        for name in DATA: transfer(source/name,f'Documents/Cyberpunk 2077/{name}')
    if {path:sha256(source/path) for path in code(source)}!=before:
        raise RuntimeError('original code changed while copying (was the game updated?); run again')
    for path,digest in before.items(): print(f'{path}: SHA-256 {digest}')
    print('Copied the application bundle'+(' and game data' if not args.skip_data else '')+' into the iPad app container.')

if __name__=='__main__': main()
