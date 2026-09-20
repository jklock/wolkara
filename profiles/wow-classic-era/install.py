#!/usr/bin/env python3
"""Copy your own installed WoW Classic Era files into the Tolkara app's Documents.

The executable and bundle resources are copied unchanged. Account settings and
credentials are not copied. devicectl skips unchanged files on subsequent runs.
"""
import argparse
import hashlib
import os
import re
from pathlib import Path
import shutil
import subprocess
import sys
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'tools'))
import localenv
BUNDLE_ID=localenv.bundle_id()


def sha256(path):
    digest=hashlib.sha256()
    with path.open('rb') as file:
        for chunk in iter(lambda:file.read(1024*1024),b''): digest.update(chunk)
    return digest.hexdigest()


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device',default=localenv.load().get('DEVICE'),help='iPad UDID (default: DEVICE in local.env)')
    parser.add_argument('--source',type=Path,default=Path('/Applications/World of Warcraft'))
    parser.add_argument('--skip-data',action='store_true')
    args=parser.parse_args()
    if not args.device: parser.error('set DEVICE in local.env or pass --device')
    os.chdir(localenv.ROOT)
    os.environ.setdefault('DEVELOPER_DIR','/Applications/Xcode.app/Contents/Developer')
    source=args.source.resolve(); stage=Path('build/game-data/World of Warcraft')
    app=Path('_classic_era_/World of Warcraft Classic.app/Contents')
    executable=app/'MacOS/World of Warcraft Classic'
    if not (source/executable).is_file(): parser.error('original Classic executable not found')
    if not args.skip_data and not (source/'Data').is_dir(): parser.error('game Data directory not found')
    (stage/app/'MacOS').mkdir(parents=True,exist_ok=True)
    for name in ['.build.info','.flavor.info']:
        for parent in [Path('.'),Path('_classic_era_')]:
            item=source/parent/name
            if item.is_file():
                (stage/parent).mkdir(parents=True,exist_ok=True); shutil.copy2(item,stage/parent/name)
    for name in ['Info.plist','PkgInfo']: shutil.copy2(source/app/name,stage/app/name)
    shutil.copytree(source/app/'Resources',stage/app/'Resources',dirs_exist_ok=True)
    before=sha256(source/executable)
    shutil.copy2(source/executable,stage/executable)
    if sha256(stage/executable)!=before or sha256(source/executable)!=before:
        raise RuntimeError('original executable changed while staging')
    for name in ['Logs','WTF','Cache']: (stage/'_classic_era_'/name).mkdir(exist_ok=True)
    configuration=source/'_classic_era_/WTF/Config.wtf'
    if configuration.is_file():
        allowed={'portal','textLocale','audioLocale'}
        lines=[]
        for line in configuration.read_text(errors='replace').splitlines():
            match=re.fullmatch(r'SET (\w+) "([A-Za-z0-9_-]+)"',line)
            if match and match[1] in allowed: lines.append(line)
        if lines: (stage/'_classic_era_/WTF/Config.wtf').write_text('\n'.join(lines)+'\n')
    def transfer(path,destination):
        subprocess.run(['xcrun','devicectl','device','copy','to','--device',args.device,
            '--domain-type','appDataContainer','--domain-identifier',BUNDLE_ID,
            '--source',str(path),'--destination',destination],check=True)
    transfer(stage,'Documents/World of Warcraft')
    nibs=Path('build/guest-module/Nibs')
    if nibs.is_dir(): transfer(nibs,'Documents/GuestCompatibility/Nibs')
    if not args.skip_data: transfer(source/'Data','Documents/World of Warcraft/Data')
    print('Original executable SHA-256:',before)
    print('Copied bundle resources'+(' and game Data' if not args.skip_data else '')+' into the iPad app container.')

if __name__=='__main__': main()
