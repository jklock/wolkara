#!/usr/bin/env python3
"""Check our system TLS configuration against an independent local OpenSSL peer.

Uses public fixture keys only. No iPad/device service or real pairing record is
accessed. OpenSSL is a host-side test dependency, never bundled with the app.
Build build/probe_system_psk first (see docs/LOCAL_AUTHORIZATION.md).
"""
import shutil
import socket
import subprocess
import tempfile
import time
from pathlib import Path


def main():
    openssl = shutil.which('openssl')
    if not openssl:
        raise SystemExit('OpenSSL is required for this optional host interoperability test')
    client = Path('build/probe_system_psk').resolve()
    fixture = bytes(range(32)).hex()
    evidence = []
    for cipher, code in [('PSK-AES256-CBC-SHA384', '00af'), ('PSK-AES128-CBC-SHA', '008c')]:
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            port = sock.getsockname()[1]
        with tempfile.TemporaryFile() as server_log:
            server = subprocess.Popen([
                openssl, 's_server', '-accept', f'127.0.0.1:{port}', '-nocert',
                '-psk', fixture, '-tls1_2', '-cipher', cipher, '-www'],
                stdout=server_log, stderr=subprocess.STDOUT)
            try:
                for _ in range(100):
                    if server.poll() is not None:
                        raise RuntimeError('Local TLS fixture server stopped')
                    try:
                        with socket.create_connection(('127.0.0.1', port), timeout=.1):
                            break
                    except OSError:
                        time.sleep(.03)
                else:
                    raise RuntimeError('Local TLS fixture server did not listen')
                for wrong in (False, True):
                    args = [str(client), str(port)] + (['--wrong-key'] if wrong else [])
                    result = subprocess.run(args, capture_output=True, text=True, timeout=15)
                    label = f'{cipher}: ' + ('mismatched key' if wrong else 'matching key')
                    if wrong:
                        assert result.returncode == 1, (label, result.returncode, result.stdout, result.stderr)
                        assert 'System TLS failure' in result.stdout, (label, result.stdout)
                        assert 'Authenticated application data' not in result.stdout
                    else:
                        assert result.returncode == 0, (label, result.returncode, result.stdout, result.stderr)
                        assert f'TLS version=0303 cipher={code}' in result.stdout
                        assert 'Authenticated application data received' in result.stdout
                    evidence.append(f'PASS {label}\n{result.stdout.rstrip()}')
            finally:
                server.terminate()
                try:
                    server.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    server.kill()
                    server.wait()
    text = 'macOS system TLS interoperability; synthetic loopback peers only\n' + '\n'.join(evidence) + '\n'
    Path('build/system-psk-probe.log').write_text(text)
    print(text, end='')


if __name__ == '__main__':
    main()
