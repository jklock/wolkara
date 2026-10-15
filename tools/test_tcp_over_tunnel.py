#!/usr/bin/env python3
"""Independent TLS/CDTunnel/TCP peer for the combined original transport."""
import importlib.util
import ipaddress
import json
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import time


def load(name,path):
    spec=importlib.util.spec_from_file_location(name,path)
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);return module


def main():
    cd=load('cd_fixture','tools/test_cd_tunnel_transport.py')
    tcp=load('tcp_fixture','tests/test_tunnel_tcp_peer.py')
    openssl=shutil.which('openssl');assert openssl
    with socket.socket() as bound:
        bound.bind(('127.0.0.1',0));port=bound.getsockname()[1]
    with tempfile.TemporaryFile() as errors:
        server=subprocess.Popen([openssl,'s_server','-quiet','-no_ign_eof','-accept',f'127.0.0.1:{port}',
            '-nocert','-psk',bytes(range(32)).hex(),'-tls1_2','-cipher','PSK-AES256-CBC-SHA384'],
            stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=errors,bufsize=0)
        client=None
        try:
            for _ in range(100):
                if server.poll() is not None:raise RuntimeError('Fixture server stopped')
                try:
                    with socket.create_connection(('127.0.0.1',port),timeout=.1):break
                except OSError:time.sleep(.03)
            else:raise TimeoutError('Fixture server startup')
            client=subprocess.Popen(['build/probe_tcp_over_tunnel',str(port)],stdout=subprocess.PIPE,stderr=subprocess.PIPE)
            deadline=time.monotonic()+7
            header=cd.read_exact(server.stdout,10,deadline);assert header[:8]==b'CDTunnel'
            request=json.loads(cd.read_exact(server.stdout,int.from_bytes(header[8:],'big'),deadline))
            assert request=={'type':'clientHandshakeRequest','mtu':16000}
            server.stdin.write(cd.frame({'clientParameters':{'address':'fd00::1','netmask':'ffff:ffff:ffff:ffff::','mtu':16000},
                'serverAddress':'fd00::2','serverRSDPort':58783}));server.stdin.flush()
            def receive():
                h=cd.read_exact(server.stdout,40,deadline)
                return tcp.decode(h+cd.read_exact(server.stdout,int.from_bytes(h[4:6],'big'),deadline))
            def send(*args,**kwargs):server.stdin.write(tcp.packet(*args,**kwargs));server.stdin.flush()
            syn=receive();assert syn['flags']==2
            host=(syn['seq']+1)&tcp.MASK;peer=7001
            send(peer-1,host,flags=18,window=32768,mss=1220)
            ack=receive();assert ack['flags']==16 and ack['ack']==peer
            data=receive();assert data['seq']==host and data['data']==b'RSD transport fixture'
            host+=len(data['data'])
            send(peer,host,payload=b'service-ready',flags=24,window=32768);peer+=13
            for _ in range(5):
                response=receive();assert response['ack']==peer and response['seq']==host
                if response['flags']&1:break
                assert response['flags']==16 and not response['data']
            else:raise AssertionError('Client did not close its write stream')
            host+=1;send(peer,host,flags=17,window=32768)
            stdout,stderr=client.communicate(timeout=8)
            assert client.returncode==0,(client.returncode,stdout.decode(),stderr.decode())
            evidence='PASS: independent peer completed TLS, CDTunnel, TCP handshake, bidirectional byte stream and graceful close\n'+stdout.decode()
            Path('build/tcp-over-tunnel-tests.log').write_text(evidence);print(evidence,end='')
        finally:
            if client is not None and client.poll() is None:client.kill();client.wait()
            server.terminate()
            try:server.wait(timeout=2)
            except subprocess.TimeoutExpired:server.kill();server.wait()
            for pipe in (server.stdin,server.stdout):
                if pipe and not pipe.closed:pipe.close()

if __name__=='__main__':main()
