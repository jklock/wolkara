#!/usr/bin/env python3
"""Independent encrypted peer with dynamic ports and a dropped first SYN.
Pairing is a synthetic offer; this tests the production connection lifecycle,
not on-device enrollment, actual device identity proof or debug authorization.
"""
import json
import shutil
import socket
import struct
import subprocess
import tempfile
import time
from pathlib import Path
from test_tcp_over_tunnel import load

def main():
    cd = load('cd_fixture','tools/test_cd_tunnel_transport.py')
    tcp = load('tcp_fixture','tests/test_tunnel_tcp_peer.py')
    rsd = load('rsd_fixture','tests/test_remote_discovery_peer.py')
    with socket.socket() as bound:
        bound.bind(('127.0.0.1',0)); port = bound.getsockname()[1]
    with tempfile.TemporaryFile() as errors:
        server = subprocess.Popen([shutil.which('openssl'),'s_server','-quiet','-no_ign_eof','-accept',f'127.0.0.1:{port}',
            '-nocert','-psk',bytes(range(32)).hex(),'-tls1_2','-cipher','PSK-AES256-CBC-SHA384'],
            stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=errors,bufsize=0)
        client = None
        try:
            for _ in range(100):
                if server.poll() is not None: raise RuntimeError('TLS fixture stopped')
                try:
                    with socket.create_connection(('127.0.0.1',port),timeout=.1): break
                except OSError: time.sleep(.03)
            else: raise TimeoutError('TLS fixture startup')
            client = subprocess.Popen(['build/probe_managed_tunnel',str(port)],stdout=subprocess.PIPE,stderr=subprocess.PIPE)
            deadline = time.monotonic()+10
            header = cd.read_exact(server.stdout,10,deadline); assert header[:8] == b'CDTunnel'
            assert json.loads(cd.read_exact(server.stdout,int.from_bytes(header[8:],'big'),deadline)) == {'type':'clientHandshakeRequest','mtu':16000}
            server.stdin.write(cd.frame({'clientParameters':{'address':'fd00::1','netmask':'ffff:ffff:ffff:ffff::','mtu':16000},
                'serverAddress':'fd00::2','serverRSDPort':58783})); server.stdin.flush()
            streams = {}; first_syn = None; syn_count = 0
            def send(remote, data=b'', flags=16, sequence=None):
                s = streams[remote]
                options = b'\x02\x04\x04\xc4' if flags & 2 else b''
                body = struct.pack('!HHIIBBHHH',remote,s['local'],s['peer'] if sequence is None else sequence,
                    s['host'],((20+len(options))//4)<<4,flags,32768,0,0)+options+data
                pseudo = tcp.REMOTE+tcp.LOCAL+struct.pack('!I3xB',len(body),6)
                body = body[:16]+struct.pack('!H',tcp.checksum(pseudo+body))+body[18:]
                server.stdin.write(struct.pack('!IHBB',6<<28,len(body),6,64)+tcp.REMOTE+tcp.LOCAL+body); server.stdin.flush()
            def receive():
                nonlocal first_syn,syn_count
                h = cd.read_exact(server.stdout,40,deadline)
                body = cd.read_exact(server.stdout,int.from_bytes(h[4:6],'big'),deadline)
                assert h[0]>>4 == 6 and h[6] == 6 and h[8:24] == tcp.LOCAL and h[24:40] == tcp.REMOTE
                assert tcp.checksum(tcp.LOCAL+tcp.REMOTE+struct.pack('!I3xB',len(body),6)+body) == 0
                local,remote,seq,ack,off,flags,window,_,_ = struct.unpack('!HHIIBBHHH',body[:20])
                payload = body[(off>>4)*4:]
                assert remote in (58783,12345) and 49152 <= local <= 65535
                if flags & 2:
                    assert flags == 2 and not payload
                    if remote == 58783:
                        syn_count += 1
                        if syn_count == 1:
                            first_syn = body; return remote,ack
                        assert syn_count == 2 and first_syn == body
                    assert remote not in streams
                    assert all(s['local'] != local for s in streams.values())
                    streams[remote] = {'host':(seq+1)&tcp.MASK,'peer':7001+remote,'local':local,'data':bytearray()}
                    send(remote,flags=18,sequence=streams[remote]['peer']-1)
                else:
                    s = streams[remote]; assert local == s['local'] and seq == s['host']
                    assert not flags & 7
                    if payload:
                        s['data'].extend(payload); s['host'] = (s['host']+len(payload))&tcp.MASK; send(remote)
                return remote,ack
            def take(remote,count):
                while remote not in streams or len(streams[remote]['data']) < count: receive()
                b = bytes(streams[remote]['data'][:count]); del streams[remote]['data'][:count]; return b
            def frame(remote=58783):
                h = take(remote,9); return rsd.frames(h+take(remote,int.from_bytes(h[:3],'big')))[0]
            assert take(58783,24) == b'PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n'
            initial = [frame() for _ in range(7)]
            assert [(f[0],f[2]) for f in initial] == [(4,0),(8,0),(1,1),(0,1),(1,3),(0,1),(0,3)]
            def send_stream(remote,data):
                for i in range(0,len(data),1177):
                    chunk = data[i:i+1177]; send(remote,chunk,24)
                    streams[remote]['peer'] += len(chunk)
                    while True:
                        target,ack = receive()
                        if target == remote and ack == streams[remote]['peer']: break
            send_stream(58783,rsd.h2(4)+rsd.h2(4,flags=1))
            ack,modern = frame(),frame()
            rsd.check_handshake(rsd.h2(ack[0],ack[3],ack[2],ack[1])+rsd.h2(modern[0],modern[3],modern[2],modern[1]))
            value = rsd.catalog()
            for i in range(700): value['Services'][f'fixture.service.{i:04d}'] = {'Port':str(30000+i),'Properties':{'UsesRemoteXPC':True}}
            wire = rsd.wrap(value,message=17)
            send_stream(58783,b''.join(rsd.h2(0,wire[i:i+8000],3) for i in range(0,len(wire),8000)))
            assert take(12345,len(b'second-stream')) == b'second-stream'
            # Drain every discovery credit while a second service connection is
            # live; both use the same TLS tunnel and different random local ports.
            credits = [frame() for _ in range(2*((len(wire)+7999)//8000))]
            for stream in (0,3): assert sum(int.from_bytes(f[3],'big') for f in credits if f[0] == 8 and f[2] == stream) == len(wire)
            send(12345,b'stream-two-ready',24)
            stdout,stderr = client.communicate(timeout=5)
            assert client.returncode == 0,(client.returncode,stdout.decode(),stderr.decode())
            assert syn_count == 2 and len(streams) == 2
            evidence = 'PASS: production manager recovered a lost SYN automatically, discovered 702 services, opened a second stream with a new ephemeral tuple, and cancelled the complete session\n'+stdout.decode()
            Path('build/managed-tunnel-tests.log').write_text(evidence); print(evidence,end='')
        finally:
            if client is not None and client.poll() is None: client.kill(); client.wait()
            server.terminate()
            try: server.wait(timeout=2)
            except subprocess.TimeoutExpired: server.kill(); server.wait()
            for pipe in (server.stdin,server.stdout):
                if pipe and not pipe.closed: pipe.close()

if __name__ == '__main__': main()
