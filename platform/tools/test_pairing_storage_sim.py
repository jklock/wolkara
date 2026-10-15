#!/usr/bin/env python3
"""Synthetic Keychain integration test, restricted to our three simulator probes.
No real device, guest binary or existing user credential is touched. --build
rebuilds the three own-code variants; successful runs remove the fixture record
and all three test apps after copying their non-secret reports into build/.
"""
import argparse
import os
from pathlib import Path
import subprocess
import time

import sys
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tools'))
import localenv
CONFIG = localenv.load()
# Simulator name or UDID: SIMULATOR in local.env or the environment.
SIMULATOR = CONFIG.get('SIMULATOR','iPad Pro 13-inch (M5)')
PROBE = CONFIG['TOLKARA_BUNDLE_ID']+'.storageprobe'
BUNDLES = {'writer':PROBE, 'reader':PROBE+'.reader', 'denied':PROBE+'.denied'}
ENV = dict(os.environ, DEVELOPER_DIR='/Applications/Xcode.app/Contents/Developer')

def run(*args):
    return subprocess.run(args,cwd=ROOT,env=ENV,check=True,capture_output=True,text=True,timeout=60).stdout.strip()

def sim(*args): return run('xcrun','simctl',*args)

def probe(role,mode):
    bundle = BUNDLES[role]
    container = Path(sim('get_app_container',SIMULATOR,bundle,'data'))
    assert '/CoreSimulator/Devices/' in str(container) and '/data/Containers/Data/Application/' in str(container)
    report = container/'Documents/storage-probe.txt'
    report.unlink(missing_ok=True)
    sim('launch','--terminate-running-process',SIMULATOR,bundle,'--storage-'+mode)
    deadline = time.monotonic()+10
    while not report.exists():
        if time.monotonic() >= deadline: raise TimeoutError(f'{role}/{mode}: no probe report')
        time.sleep(.05)
    text = report.read_text().strip()
    assert text.startswith('PASS:'),(role,mode,text)
    return role+'/'+mode+' '+text

def main():
    parser = argparse.ArgumentParser(); parser.add_argument('--build',action='store_true'); args = parser.parse_args()
    if args.build:
        for role,bundle in BUNDLES.items():
            command = ['xcodebuild','-project','Tolkara.xcodeproj','-scheme','StorageProbe','-destination',f'platform=iOS Simulator,'+('id=' if len(SIMULATOR)==36 and SIMULATOR.count('-')==4 else 'name=')+SIMULATOR,
                       '-configuration','Debug','-derivedDataPath',f'build/storageprobe-{role}',f'PRODUCT_BUNDLE_IDENTIFIER={bundle}']
            if role == 'denied': command += ['STORAGE_PROBE_GROUP=$(AppIdentifierPrefix)'+CONFIG['TOLKARA_KEYCHAIN_GROUP']+'.probe.denied']
            command += ['build']
            with (ROOT/f'build/storageprobe-{role}-build.log').open('w') as log:
                subprocess.run(command,cwd=ROOT,env=ENV,check=True,stdout=log,stderr=subprocess.STDOUT,timeout=120)
    for role in BUNDLES:
        app = ROOT/f'build/storageprobe-{role}/Build/Products/Debug-iphonesimulator/StorageProbe.app'
        sim('install',SIMULATOR,str(app))
    evidence = []
    try:
        evidence.append(probe('writer','write'))
        evidence.append(probe('writer','read'))  # Forced process restart, same Keychain record.
        evidence.append(probe('reader','read'))
        evidence.append(probe('denied','denied'))
        evidence.append(probe('reader','delete'))
        evidence.append(probe('writer','empty'))
    finally:
        # Remove only the deterministic fixture in our isolated probe group.
        probe('writer','delete')
    for bundle in BUNDLES.values(): sim('uninstall',SIMULATOR,bundle)
    report = 'iOS 27 simulator, synthetic isolated Keychain group; no device/protection-at-rest claim\n'+'\n'.join(evidence)+'\nFixture record and all three probe apps removed\n'
    (ROOT/'build/pairing-storage-simulator-tests.log').write_text(report)
    print(report,end='')

if __name__ == '__main__': main()
