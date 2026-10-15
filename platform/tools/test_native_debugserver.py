#!/usr/bin/env python3
"""Attach only Apple's macOS debugserver to our freshly spawned zero-arena fixture.
No iPad, existing processes, game binaries or authentication data are involved.
"""
import selectors
import socket
import subprocess
import tempfile
import time
from pathlib import Path

def main():
    debugserver='/Applications/Xcode.app/Contents/SharedFrameworks/LLDB.framework/Versions/A/Resources/debugserver'
    with socket.socket() as s:s.bind(('127.0.0.1',0));port=s.getsockname()[1]
    target=subprocess.Popen(['build/emulation/debug_arena_target'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True)
    server=None
    try:
        with selectors.DefaultSelector() as selector:
            selector.register(target.stdout,selectors.EVENT_READ)
            if not selector.select(3):raise TimeoutError('own target startup')
        descriptor=target.stdout.readline()
        with tempfile.TemporaryFile() as server_log:
            # Isolate debugger job-control/termination from the orchestrator's
            # process group. The first manual run passed the exchange but its
            # cleanup stopped the shared group until explicitly resumed.
            server=subprocess.Popen([debugserver,f'127.0.0.1:{port}'],stdout=server_log,stderr=server_log,start_new_session=True)
            # Do not probe with a TCP connection: debugserver accepts one client.
            time.sleep(.3)
            result=subprocess.run(['build/probe_native_debugserver',str(port)],input=descriptor,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=25,start_new_session=True)
            if result.returncode:
                server_log.seek(0)
                evidence='Own-fixture debugserver interoperability did not pass.\n'+result.stdout.decode()+result.stderr.decode()+server_log.read().decode(errors='replace')
                Path('build/native-debugserver-tests.log').write_text(evidence)
                print(evidence);return result.returncode
            target.stdin.close();target.stdin=None
            target.wait(timeout=3)
            assert target.returncode==0,'fixture changed or failed to detach'
            evidence=result.stdout.decode()
            Path('build/native-debugserver-tests.log').write_text(evidence);print(evidence,end='');return 0
    finally:
        if server is not None and server.poll() is None:
            server.terminate()
            try:server.wait(timeout=3)
            except subprocess.TimeoutExpired:server.kill();server.wait()
        if target.poll() is None:
            target.kill();target.wait()

if __name__=='__main__':raise SystemExit(main())
