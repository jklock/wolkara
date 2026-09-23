#!/usr/bin/env python3
"""Launch the original-image native initializer diagnostic on a connected iPad."""
import argparse
import json
import os
from pathlib import Path
import re
import selectors
import subprocess
import time
import uuid
import sys
sys.path.insert(0,str(Path(__file__).resolve().parent))
import localenv
BUNDLE_ID=localenv.bundle_id()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device', required=True)
    parser.add_argument('--full-startup', action='store_true')
    parser.add_argument('--catch-exception', action='store_true')
    parser.add_argument('--catch-exit', action='store_true')
    parser.add_argument('--before-main', action='store_true')
    parser.add_argument('--detach-after-publish', action='store_true')
    parser.add_argument('--translate-shaders', action='store_true')
    parser.add_argument('--sample-native', action='store_true')
    parser.add_argument('--measure-native', action='store_true', help='Log frame timing without screenshots or memory samples')
    parser.add_argument('--seconds', type=int, default=20)
    args = parser.parse_args()
    os.environ.setdefault('DEVELOPER_DIR','/Applications/Xcode.app/Contents/Developer')
    run_id = uuid.uuid4().hex
    output = Path('logs') / ('native-' + run_id)
    output.mkdir(parents=True)
    result = subprocess.run(['xcrun','devicectl','device','process','launch','--terminate-existing',
        '--device',args.device,'--start-stopped','--json-output',str(output/'launch.json'),
        BUNDLE_ID,'--execution-mode=developer-service','--native-startup' if args.full_startup else '--native-initializer','--probe-run-id='+run_id, *(['--sample-native'] if args.sample_native else []), *(['--measure-native'] if args.measure_native else []), *(['--translate-shaders'] if args.translate_shaders else [])],capture_output=True,text=True,timeout=60)
    (output/'launch.log').write_text(result.stdout+result.stderr)
    if result.returncode: print(result.stdout+result.stderr); return 1
    data=json.loads((output/'launch.json').read_text())['result']; pid=data['process']['processIdentifier']
    process=subprocess.Popen(['xcrun','lldb','--no-lldbinit'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,bufsize=0)
    selector=selectors.DefaultSelector(); selector.register(process.stdout,selectors.EVENT_READ)
    transcript=bytearray()
    def send(command): process.stdin.write((command+'\n').encode()); process.stdin.flush()
    def expect(pattern,timeout=50):
        deadline=time.monotonic()+timeout; start=len(transcript)
        while time.monotonic()<deadline:
            if selector.select(.25):
                chunk=os.read(process.stdout.fileno(),65536)
                if not chunk: break
                transcript.extend(chunk); (output/'debugger.log').write_bytes(transcript)
                if re.search(pattern,transcript[start:]): return True
        return False
    try:
        send('target create '+json.dumps(str(Path('build/emulation-dd/Build/Products/Debug-iphoneos/TolkaraDiagnostics.app/TolkaraDiagnostics').resolve())))
        send('command script import '+json.dumps(str(Path('tools/lldb_arena_publish.py').resolve())))
        send('breakpoint set --name host_debugger_publish_arena')
        send('breakpoint set --name host_debugger_guest_complete')
        send('device select '+data['deviceIdentifier'])
        send('device process attach --pid '+str(pid))
        if not expect(rb'Process '+str(pid).encode()+rb' stopped'): raise RuntimeError('attach did not stop')
        send('process continue')
        if not expect(rb'stop reason = breakpoint[\s\S]*Target \d+:.*stopped\.'): raise RuntimeError('arena rendezvous not reached')
        send('script lldb_arena_publish.publish(lldb.debugger)')
        if not expect(rb'ARENA_OK: [^\n]+\n',120): raise RuntimeError('arena publication failed')
        if args.detach_after_publish:
            send('process detach --keep-stopped false')
            if not expect(rb'Process '+str(pid).encode()+rb' detached',15): raise RuntimeError('detach failed')
            send('quit'); process.wait(timeout=5)
            deadline=time.monotonic()+args.seconds
            while time.monotonic()<deadline:
                time.sleep(.5)
            copy=subprocess.run(['xcrun','devicectl','device','copy','from','--device',args.device,
                '--domain-type','appDataContainer','--domain-identifier',BUNDLE_ID,
                '--source','Documents/native-guest.log','--destination',str(output/'native-guest.log')],capture_output=True,text=True,timeout=45)
            if copy.returncode: print(copy.stdout+copy.stderr)
        else:
            if args.catch_exception: send('breakpoint set --name objc_exception_throw')
            if args.catch_exit: send('breakpoint set --name exit --name _exit --name _Exit')
            if args.before_main:
                line=next(i for i,s in enumerate(Path('runtime/NativeGuest.m').read_text().splitlines(),1) if 'int result=((int (*)' in s)
                send('breakpoint set --file NativeGuest.m --line '+str(line))
            send('process continue')
            if not expect(rb'stop reason = [^\n]+[\s\S]*Target \d+:.*stopped\.',args.seconds):
                send('process interrupt'); expect(rb'Process '+str(pid).encode()+rb' stopped',10)
            if args.catch_exception: send('po (id)$x0')
            send('register read'); send('bt 20'); send('disassemble --start-address `$pc-32` --count 24')
            send('disassemble --start-address `guest.image.entry+guest.slide` --count 32')
            send('frame select 1')
            send('disassemble --start-address `$pc-64` --count 32')
            send('script print("STATE_END")'); expect(rb'STATE_END\r?\n',15)
            # Keep the stopped process alive until logs have been copied.
            copy=subprocess.run(['xcrun','devicectl','device','copy','from','--device',args.device,
                '--domain-type','appDataContainer','--domain-identifier',BUNDLE_ID,
                '--source','Documents/native-guest.log','--destination',str(output/'native-guest.log')],capture_output=True,text=True,timeout=45)
            if copy.returncode: print(copy.stdout+copy.stderr)
            send('process detach --keep-stopped false'); expect(rb'Process '+str(pid).encode()+rb' detached',10)
            send('quit'); process.wait(timeout=5)
    except (RuntimeError,subprocess.TimeoutExpired) as error:
        print(error)
    finally:
        if process.poll() is None: process.terminate(); process.wait(timeout=5)
        selector.close(); process.stdin.close(); process.stdout.close()
        (output/'debugger.log').write_bytes(transcript)
    print(transcript.decode(errors='replace')[-14000:])
    report=(output/'native-guest.log').read_text() if (output/'native-guest.log').exists() else ''
    print(report if len(report)<10000 else report[:2500]+'\n... see full log ...\n'+report[-6000:]); print('Evidence:',output)
    fresh='--probe-run-id='+run_id in report
    passed=fresh and ('[native] result startup_return=PASS' if args.full_startup else '[native] result first_initializer=PASS') in report
    main_return=re.search(r'\[native\] original main returned (-?\d+)',report)
    (output/'summary.json').write_text(json.dumps({'run_id':run_id,'passed':passed,'device':args.device,'detached_before_guest_execution':args.detach_after_publish,
        'all_initializers_completed':fresh and 'initializers returned; entering original main=' in report,
        'main_return':int(main_return[1]) if fresh and main_return else None},indent=2)+'\n')
    return 0 if passed else 1

if __name__=='__main__': raise SystemExit(main())
