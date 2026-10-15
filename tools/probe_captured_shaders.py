#!/usr/bin/env python3
"""Compile every shader library a game left on the iPad with the iPad's own Metal.

Launches the installed Tolkara app with --captured-shader-probe: it reads the
libraries under Documents/ShaderRequests (written whenever the runtime needed a
Mac translation), rewraps each for iOS as the Metal adapter does, loads it on the
device, creates its functions and builds its compute pipelines, then writes
Documents/captured-shader-probe.txt. No application code runs. The report is
copied under logs/ and printed; exit 0 means every library loaded.
"""
import argparse
import os
from pathlib import Path
import subprocess
import sys
import time
import uuid
sys.path.insert(0,str(Path(__file__).resolve().parent))
import localenv


def main():
    parser=argparse.ArgumentParser(description=__doc__,formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--device',help='iPad UDID (default: DEVICE from local.env)')
    parser.add_argument('--seconds',type=int,default=300,help='how long to wait for the report')
    args=parser.parse_args()
    os.environ.setdefault('DEVELOPER_DIR','/Applications/Xcode.app/Contents/Developer')
    settings=localenv.load();device=args.device or settings.get('DEVICE');bundle=settings['TOLKARA_BUNDLE_ID']
    if not device: parser.error('set DEVICE in local.env or pass --device')
    run_id=uuid.uuid4().hex
    output=Path('logs')/('captured-shaders-'+time.strftime('%Y%m%d-%H%M%S'));output.mkdir(parents=True,exist_ok=True)
    launch=subprocess.run(['xcrun','devicectl','device','process','launch','--terminate-existing','--device',device,
        bundle,'--captured-shader-probe','--probe-run-id='+run_id],capture_output=True,text=True,timeout=120)
    (output/'launch.log').write_text(launch.stdout+launch.stderr)
    if launch.returncode: print(launch.stdout+launch.stderr);print('Launch failed; is the app installed (tools/install.sh) and the iPad unlocked?');return 2
    report=output/'captured-shader-probe.txt';deadline=time.monotonic()+args.seconds
    while time.monotonic()<deadline:
        time.sleep(2)
        report.unlink(missing_ok=True)   # a fresh read each time, even for an equal-size file
        copy=subprocess.run(['xcrun','devicectl','device','copy','from','--device',device,'--domain-type','appDataContainer',
            '--domain-identifier',bundle,'--source','Documents/captured-shader-probe.txt','--destination',str(report)],
            capture_output=True,text=True,timeout=60)
        if copy.returncode or not report.exists(): continue
        text=report.read_text()
        if not text.startswith('run '+run_id+'\n'): continue   # a report of an earlier run
        print(text,end='');print('Report:',report)
        return 0 if '\nRESULT: PASS' in text else 1
    print('No report tagged with this run within',args.seconds,'seconds; see',output)
    return 1


if __name__=='__main__': raise SystemExit(main())
