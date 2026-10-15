#!/usr/bin/env python3
"""Full local encrypted transport/discovery test with an independent wire peer."""
import json
import shutil
import socket
import subprocess
import tempfile
import time
from pathlib import Path
from test_tcp_over_tunnel import load

def main():
    cd = load('cd_fixture', 'tools/test_cd_tunnel_transport.py')
    tcp = load('tcp_fixture', 'tests/test_tunnel_tcp_peer.py')
    rsd = load('rsd_fixture', 'tests/test_remote_discovery_peer.py')
    openssl = shutil.which('openssl')
    assert openssl
    with socket.socket() as bound:
        bound.bind(('127.0.0.1', 0))
        port = bound.getsockname()[1]
    with tempfile.TemporaryFile() as errors:
        server = subprocess.Popen([openssl, 's_server', '-quiet', '-no_ign_eof', '-accept', f'127.0.0.1:{port}',
            '-nocert', '-psk', bytes(range(32)).hex(), '-tls1_2', '-cipher', 'PSK-AES256-CBC-SHA384'],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=errors, bufsize=0)
        client = None
        try:
            for _ in range(100):
                if server.poll() is not None:
                    raise RuntimeError('Fixture server stopped')
                try:
                    with socket.create_connection(('127.0.0.1', port), timeout=.1):
                        break
                except OSError:
                    time.sleep(.03)
            else:
                raise TimeoutError('Fixture startup')
            client = subprocess.Popen(['build/probe_rsd_over_tunnel', str(port)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            deadline = time.monotonic() + 12
            header = cd.read_exact(server.stdout, 10, deadline)
            assert header[:8] == b'CDTunnel'
            request = json.loads(cd.read_exact(server.stdout, int.from_bytes(header[8:], 'big'), deadline))
            assert request == {'type':'clientHandshakeRequest', 'mtu':16000}
            server.stdin.write(cd.frame({'clientParameters':{'address':'fd00::1','netmask':'ffff:ffff:ffff:ffff::','mtu':16000},
                'serverAddress':'fd00::2','serverRSDPort':58783}))
            server.stdin.flush()
            def raw_receive():
                h = cd.read_exact(server.stdout, 40, deadline)
                return tcp.decode(h + cd.read_exact(server.stdout, int.from_bytes(h[4:6], 'big'), deadline))
            syn = raw_receive()
            assert syn['flags'] == 2
            host, peer = syn['seq'] + 1, 7001
            received = bytearray()
            fin = False
            def send(data=b'', flags=16, sequence=None):
                server.stdin.write(tcp.packet(peer if sequence is None else sequence, host, payload=data, flags=flags, window=32768,
                                             mss=1220 if flags & 2 else None))
                server.stdin.flush()
            send(flags=18, sequence=peer-1)
            def receive():
                nonlocal host, fin
                p = raw_receive()
                assert p['seq'] == host, p
                if p['data']:
                    received.extend(p['data'])
                    host += len(p['data'])
                    send()
                if p['flags'] & 1:
                    host += 1
                    fin = True
                    send()
                return p
            def take(count):
                while len(received) < count:
                    receive()
                b = bytes(received[:count])
                del received[:count]
                return b
            def frame():
                h = take(9)
                return rsd.frames(h + take(int.from_bytes(h[:3], 'big')))[0]
            assert take(24) == b'PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n'
            initial = [frame() for _ in range(7)]
            assert [(f[0], f[2]) for f in initial] == [(4,0),(8,0),(1,1),(0,1),(1,3),(0,1),(0,3)]
            assert rsd.decode_wrapper(initial[3][3]) == (1,0,{})
            assert rsd.decode_wrapper(initial[5][3]) == (0x201,0,None)
            assert rsd.decode_wrapper(initial[6][3]) == (0x400001,0,None)
            def send_stream(data):
                nonlocal peer
                for i in range(0,len(data),1177):
                    chunk = data[i:i+1177]
                    send(chunk,flags=24)
                    peer += len(chunk)
                    while True:
                        p = receive()
                        if p['ack'] == peer:
                            break
            send_stream(rsd.h2(4) + rsd.h2(4,flags=1))
            ack, modern = frame(), frame()
            rsd.check_handshake(rsd.h2(ack[0],ack[3],ack[2],ack[1])+rsd.h2(modern[0],modern[3],modern[2],modern[1]))
            value = rsd.catalog()
            for i in range(700):
                value['Services'][f'fixture.service.{i:04d}'] = {'Port':str(30000+i),'Properties':{'UsesRemoteXPC':True}}
            wire = rsd.wrap(value, message=17)
            data = b''.join(rsd.h2(0,wire[i:i+8000],3) for i in range(0,len(wire),8000))
            send_stream(data)
            while not fin:
                receive()
            # The parser returns a credit for every consumed byte on both windows.
            updates = rsd.frames(bytes(received))
            for stream in (0,3):
                assert sum(int.from_bytes(f[3], 'big') for f in updates if f[0] == 8 and f[2] == stream) == len(wire)
            send(flags=17)
            stdout, stderr = client.communicate(timeout=5)
            assert client.returncode == 0, (client.returncode,stdout.decode(),stderr.decode())
            evidence = 'PASS: independent TLS/CDTunnel/IPv6/TCP/HTTP2/RemoteXPC peer, 702-service catalog and graceful close\n' + stdout.decode()
            Path('build/rsd-over-tunnel-tests.log').write_text(evidence)
            print(evidence,end='')
        finally:
            if client is not None and client.poll() is None:
                client.kill(); client.wait()
            server.terminate()
            try:
                server.wait(timeout=2)
            except subprocess.TimeoutExpired:
                server.kill(); server.wait()
            for pipe in (server.stdin, server.stdout):
                if pipe and not pipe.closed:
                    pipe.close()

if __name__ == '__main__':
    main()
