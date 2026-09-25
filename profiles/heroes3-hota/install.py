#!/usr/bin/env python3
"""Stage your own Heroes III: Horn of the Abyss (GOG, Windows) with the arm64
macOS Wine + FEX runtime, and copy both into the Tolkara app's Documents.

The game's files come from your GOG installer (unpacked with innoextract, no
Wine involved) or from a folder you already installed, and are copied unchanged:
every .exe and .dll is hash-verified before and after. The Wine prefix is
created on the Mac by the same arm64 runtime that runs on the iPad, so the
prefix and the runtime match (build it first: tools/build_windows_runtime.sh).
Nothing of the game, Wine or FEX is included in the repository.
"""
import argparse
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'tools'))
import localenv
BUNDLE_ID=localenv.bundle_id()
FOLDER='Heroes 3 HotA'
GAME='GOG Games/Heroes of Might and Magic III - Horn of the Abyss'
EXECUTABLE='h3hota HD.exe'
CODE_SUFFIXES={'.exe','.dll','.asi'}
# FEX as the emulator for x86 (WoW64) and x86-64 (ARM64EC) code in this prefix,
# the keys Wine's wow64 layer reads (docs/WINDOWS.md).
EMULATOR_KEYS={r'HKLM\Software\Microsoft\Wow64\x86':'libwow64fex.dll',r'HKLM\Software\Microsoft\Wow64\amd64':'libarm64ecfex.dll'}


def sha256(path):
    digest=hashlib.sha256()
    with path.open('rb') as file:
        for chunk in iter(lambda:file.read(1024*1024),b''): digest.update(chunk)
    return digest.hexdigest()


def code_hashes(game):
    """Every executable or library the game ships, by relative path."""
    return {str(p.relative_to(game)):sha256(p) for p in sorted(game.rglob('*')) if p.is_file() and p.suffix.lower() in CODE_SUFFIXES}


def unpack(installer,game,language):
    if game.exists(): shutil.rmtree(game)
    game.mkdir(parents=True)
    subprocess.run(['innoextract','--extract','--exclude-temp','--language',language,'--output-dir',str(game),str(installer)],check=True)
    # innoextract puts {app} at the output root; GOG's redistributables and
    # temporary files are not part of the game.
    for name in ['__redist','tmp','commonappdata']:
        if (game/name).exists(): shutil.rmtree(game/name)
    nested=game/'app'
    if nested.is_dir():
        for item in nested.iterdir():
            target=game/item.name
            if target.exists(): shutil.copytree(item,target,dirs_exist_ok=True) if item.is_dir() else shutil.copy2(item,target)
            else: shutil.move(str(item),str(target))
        shutil.rmtree(nested,ignore_errors=True)
    if not (game/EXECUTABLE).is_file(): sys.exit(f'{EXECUTABLE} not found after unpacking; is this the GOG HotA installer?')


def wine(runtime,prefix,*command,check=True):
    environment={**os.environ,'WINEPREFIX':str(prefix),'WINEDEBUG':'-all','WINEDLLOVERRIDES':'mscoree,mshtml='}
    return subprocess.run([str(runtime/'bin/wine'),*command],env=environment,check=check)


def create_prefix(runtime,prefix):
    if prefix.exists(): shutil.rmtree(prefix)
    prefix.parent.mkdir(parents=True,exist_ok=True)
    wine(runtime,prefix,'wineboot','-u')
    for key,value in EMULATOR_KEYS.items(): wine(runtime,prefix,'reg','add',key,'/ve','/d',value,'/f')
    subprocess.run([str(runtime/'bin/wineserver'),'-w'],env={**os.environ,'WINEPREFIX':str(prefix)},check=False)
    if not (prefix/'drive_c/windows/system32').is_dir(): sys.exit('the Wine prefix was not created; does the runtime start on this Mac?')


def main():
    parser=argparse.ArgumentParser(description=__doc__,formatter_class=argparse.RawDescriptionHelpFormatter)
    origin=parser.add_mutually_exclusive_group(required=True)
    origin.add_argument('--installer',type=Path,help='your GOG installer (setup_heroes_of_might_and_magic_iii_horn_of_the_abyss_*.exe)')
    origin.add_argument('--source',type=Path,help='a folder where the GOG build is already installed')
    parser.add_argument('--language',default='en-US',help='installer language to unpack (default: en-US)')
    parser.add_argument('--runtime',type=Path,default=Path('build/windows-runtime/Wine'),help='arm64 macOS Wine + FEX runtime (default: the build script output)')
    parser.add_argument('--device',default=localenv.load().get('DEVICE'),help='iPad UDID (default: DEVICE in local.env)')
    parser.add_argument('--stage-only',action='store_true',help='prepare build/game-data and print the Mac command; copy nothing to a device')
    parser.add_argument('--skip-runtime',action='store_true',help='do not copy the runtime again')
    parser.add_argument('--keep-prefix',action='store_true',help='reuse the staged prefix instead of creating it again')
    args=parser.parse_args()
    os.chdir(localenv.ROOT)
    os.environ.setdefault('DEVELOPER_DIR','/Applications/Xcode.app/Contents/Developer')
    runtime=args.runtime.resolve()
    if not (runtime/'bin/wine').is_file(): parser.error(f'no Wine runtime at {runtime}; run tools/build_windows_runtime.sh or pass --runtime')
    for name in ['libwow64fex.dll','libarm64ecfex.dll']:
        if not list(runtime.rglob(name)): parser.error(f'{name} is missing from the runtime; FEX was not built into it')
    if not args.stage_only and not args.device: parser.error('set DEVICE in local.env, pass --device, or use --stage-only')
    stage=Path('build/game-data')/FOLDER
    game=stage/'game'
    if args.installer:
        if not shutil.which('innoextract'): parser.error('innoextract is required to unpack the installer (brew install innoextract)')
        unpack(args.installer.resolve(),game,args.language)
    else:
        source=args.source.resolve()
        if not (source/EXECUTABLE).is_file(): parser.error(f'{EXECUTABLE} not found under {source}')
        if game.exists(): shutil.rmtree(game)
        shutil.copytree(source,game,symlinks=True)
    before=code_hashes(game)
    prefix=stage/'prefix'
    if not (args.keep_prefix and (prefix/'drive_c').is_dir()): create_prefix(runtime,prefix.resolve())
    installed=prefix/'drive_c'/GAME
    if installed.exists(): shutil.rmtree(installed)
    installed.parent.mkdir(parents=True,exist_ok=True)
    shutil.copytree(game,installed,symlinks=True)
    if code_hashes(installed)!=before or code_hashes(game)!=before: raise RuntimeError('game code changed while staging; run again')
    for name in [EXECUTABLE,'HotA.dll','_HD3_.dll']:
        if name in before: print(f'{name}: SHA-256 {before[name]}')
    print(f'Staged {len(before)} game executables and libraries unchanged into {installed}')
    print('Try it on this Mac first (no Rosetta involved):')
    print(f'  cd "{installed.resolve()}" && WINEPREFIX="{prefix.resolve()}" "{runtime/"bin/wine"}" "{EXECUTABLE}"')
    if args.stage_only: return
    def transfer(path,destination):
        subprocess.run(['xcrun','devicectl','device','copy','to','--device',args.device,
            '--domain-type','appDataContainer','--domain-identifier',BUNDLE_ID,
            '--source',str(path),'--destination',destination],check=True)
    if not args.skip_runtime: transfer(runtime,f'Documents/{FOLDER}/Wine')
    transfer(prefix,f'Documents/{FOLDER}/prefix')
    if code_hashes(installed)!=before: raise RuntimeError('game code changed while copying; run again')
    print('Copied the runtime and the prefix with the game into the iPad app container.')

if __name__=='__main__': main()
