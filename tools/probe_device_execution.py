#!/usr/bin/env python3
"""Run our host-owned arm64 sample on an installed iPad host; never execute an imported application.

A debugger-assisted run uses Apple's LLDB; options control when it detaches. Probe logs
are copied from the app container and tagged to reject stale results. Exit 0 means
both execution and rewriting were proven; exit 1 means denied or inconclusive.
"""
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


def run(args, **kwargs):
    return subprocess.run(args, text=True, capture_output=True, timeout=60, **kwargs)


def attach_and_detach(device, pid, binary, log_path, after_resume=None, publish=False, publication_count=2, detach_after_publish=False):
    # CoreDevice attach completes asynchronously even when LLDB's command returns.
    # Wait for the actual stopped event before detaching; batch -o commands race it.
    process = subprocess.Popen(['xcrun', 'lldb', '--no-lldbinit'], stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT, bufsize=0)
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    transcript = bytearray()

    def send(command):
        process.stdin.write((command + '\n').encode())
        process.stdin.flush()

    def expect(pattern, timeout=40):
        deadline = time.monotonic() + timeout
        start = len(transcript)
        while time.monotonic() < deadline:
            if selector.select(timeout=0.5):
                chunk = os.read(process.stdout.fileno(), 65536)
                if not chunk:
                    break
                transcript.extend(chunk)
                log_path.write_bytes(transcript)
                if re.search(pattern, transcript[start:]):
                    return
                if b'stop reason = EXC_BAD_ACCESS' in transcript[start:]:
                    raise RuntimeError('Host sample stopped with an execution access fault')
            if process.poll() is not None:
                break
        raise RuntimeError('LLDB did not report ' + pattern.decode())

    try:
        send('target create ' + json.dumps(str(binary)))
        if publish:
            helper = Path(__file__).with_name('lldb_code_publish.py').resolve()
            send('command script import ' + json.dumps(str(helper)))
            send('breakpoint set --name host_debugger_publish_code')
        send('device select ' + device)
        send('device process attach --pid ' + str(pid))
        expect(rb'Process ' + str(pid).encode() + rb' stopped')
        if after_resume:
            if publish:
                # iPadOS 27 requires waiting for each full breakpoint stop before
                # issuing the next resume; do not use auto-continue callbacks.
                for _ in range(publication_count):
                    send('process continue')
                    expect(rb'stop reason = breakpoint[\s\S]*Target \d+:.*stopped\.')
                    send('script lldb_code_publish.publish(lldb.debugger)')
                    expect(rb'PUBLISH_OK: [^\n]+\n')
            if detach_after_publish:
                send('process detach --keep-stopped false')
                expect(rb'Process ' + str(pid).encode() + rb' detached')
            else:
                send('process continue')
                expect(rb'Process ' + str(pid).encode() + rb' resuming')
            after_resume()
        if not detach_after_publish:
            send('process detach --keep-stopped false')
            expect(rb'Process ' + str(pid).encode() + rb' detached')
        send('quit')
        process.wait(timeout=5)
        return True
    except (RuntimeError, subprocess.TimeoutExpired) as error:
        transcript.extend(('\n' + str(error) + '\n').encode())
        return False
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        selector.close()
        process.stdin.close()
        process.stdout.close()
        log_path.write_bytes(transcript)
        print(transcript.decode(errors='replace'))


def collect_report(device, output, run_id):
    local_log = output / 'execution-probe.log'
    deadline = time.monotonic() + 15
    report = ''
    while time.monotonic() < deadline:
        copy = run(['xcrun', 'devicectl', 'device', 'copy', 'from', '--device', device,
                    '--domain-type', 'appDataContainer', '--domain-identifier', BUNDLE_ID,
                    '--source', 'Documents/execution-probe.log', '--destination', str(local_log)])
        if copy.returncode == 0:
            candidate = local_log.read_text()
            if '--probe-run-id=' + run_id in candidate:
                report = candidate
                if '[execution] result ' in report or 'anonymous allocation failed' in report:
                    break
        time.sleep(0.5)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device', required=True)
    parser.add_argument('--mode', choices=['wx', 'rwx', 'dual'], default='wx')
    parser.add_argument('--debugger', action='store_true')
    parser.add_argument('--keep-attached', action='store_true', help='Keep LLDB attached during the sample; implies --debugger')
    parser.add_argument('--publish-code', action='store_true', help='Initialize a zero page or republish identical host sample bytes; implies --keep-attached')
    parser.add_argument('--detach-after-publish', action='store_true', help='Detach after initializing the dual-mapped page, before any generated code executes')
    parser.add_argument('--app', type=Path, default=Path('build/emulation-dd/Build/Products/Debug-iphoneos/TolkaraDiagnostics.app'))
    args = parser.parse_args()
    if args.detach_after_publish and args.mode != 'dual':
        parser.error('--detach-after-publish requires --mode dual')
    args.publish_code = args.publish_code or args.detach_after_publish
    args.keep_attached = args.keep_attached or args.publish_code
    args.debugger = args.debugger or args.keep_attached
    os.environ.setdefault('DEVELOPER_DIR', '/Applications/Xcode.app/Contents/Developer')
    run_id = uuid.uuid4().hex
    output = Path('logs') / ('execution-' + run_id)
    output.mkdir(parents=True)
    launch_json = output / 'launch.json'
    command = ['xcrun', 'devicectl', 'device', 'process', 'launch', '--terminate-existing',
               '--device', args.device, '--json-output', str(launch_json)]
    if args.debugger:
        command.append('--start-stopped')
    command += [BUNDLE_ID, '--execution-probe=' + args.mode, '--probe-run-id=' + run_id]
    launch = run(command)
    (output / 'launch.log').write_text(launch.stdout + launch.stderr)
    if launch.returncode:
        print(launch.stdout + launch.stderr)
        return 1
    result = json.loads(launch_json.read_text())['result']
    reports = []
    if args.debugger:
        pid = result['process']['processIdentifier']
        binary = (args.app / 'Host').resolve()
        callback = (lambda: reports.append(collect_report(args.device, output, run_id))) if args.keep_attached else None
        count = 1 if args.mode == 'dual' else 2
        if not attach_and_detach(result['deviceIdentifier'], pid, binary, output / 'debugger.log', callback, args.publish_code, count, args.detach_after_publish):
            report = collect_report(args.device, output, run_id)
            print(report or 'No fresh execution log.')
            print('Debugger session or sample execution failed. Logs:', output)
            return 1
    report = reports[0] if reports else collect_report(args.device, output, run_id)
    print(report or 'No fresh execution log; result is inconclusive.')
    passed = '[execution] result execute=PASS rewrite=PASS' in report
    summary = {'run_id': run_id, 'mode': args.mode,
               'debugger_assisted': args.debugger,
               'debugger_attached_during_execution': args.keep_attached and not args.detach_after_publish, 'passed': passed,
               'debugger_published_code': args.publish_code,
               'detached_before_execution': args.detach_after_publish,
               'device': args.device}
    (output / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print('Evidence:', output)
    return 0 if passed else 1


if __name__ == '__main__':
    raise SystemExit(main())
