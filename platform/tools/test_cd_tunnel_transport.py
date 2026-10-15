#!/usr/bin/env python3
"""Independent local OpenSSL/CDTunnel peer; public keys and synthetic packets only."""
import ipaddress
import argparse
import json
import os
from pathlib import Path
import select
import shutil
import socket
import subprocess
import tempfile
import time


def read_exact(pipe, count, deadline):
    output = bytearray()
    while len(output) < count:
        remaining = deadline - time.monotonic()
        if remaining <= 0 or not select.select([pipe], [], [], remaining)[0]:
            raise TimeoutError('Fixture peer receive deadline exceeded')
        chunk = os.read(pipe.fileno(), count-len(output))
        if not chunk:
            raise EOFError('Fixture peer closed early')
        output.extend(chunk)
    return bytes(output)


def packet(payload):
    return bytes([0x60,0,0,0]) + len(payload).to_bytes(2,'big') + bytes([59,64]) + \
        ipaddress.IPv6Address('fd00::2').packed + ipaddress.IPv6Address('fd00::1').packed + payload


def frame(obj):
    encoded = json.dumps(obj).encode()
    return b'CDTunnel' + len(encoded).to_bytes(2,'big') + encoded


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--cipher',default='PSK-AES256-CBC-SHA384',choices=[
        'PSK-AES256-CBC-SHA384','PSK-AES128-CBC-SHA','PSK-AES128-GCM-SHA256','PSK-AES256-GCM-SHA384'])
    cipher = parser.parse_args().cipher
    openssl = shutil.which('openssl')
    if not openssl:
        raise SystemExit('This optional host test requires OpenSSL; it is never bundled with the app')
    evidence = []
    for mode in ['valid','wrong-key','malformed','oversized','truncated','silent','partial','backpressure']:
        with socket.socket() as bound:
            bound.bind(('127.0.0.1',0)); port = bound.getsockname()[1]
        with tempfile.TemporaryFile() as errors:
            server = subprocess.Popen([openssl,'s_server','-quiet','-no_ign_eof',
                '-accept',f'127.0.0.1:{port}','-nocert','-psk',bytes(range(32)).hex(),
                '-tls1_2','-cipher',cipher],
                stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=errors,bufsize=0)
            client = None
            try:
                for _ in range(100):
                    if server.poll() is not None:
                        errors.seek(0); raise RuntimeError('Fixture server stopped: '+errors.read(4096).decode())
                    try:
                        with socket.create_connection(('127.0.0.1',port),timeout=.1):break
                    except OSError: time.sleep(.03)
                else: raise TimeoutError('Fixture server startup deadline exceeded')
                client = subprocess.Popen(['build/probe_cd_tunnel',str(port),mode],stdout=subprocess.PIPE,stderr=subprocess.PIPE)
                if mode != 'wrong-key':
                    deadline = time.monotonic()+5
                    header = read_exact(server.stdout,10,deadline)
                    assert header[:8] == b'CDTunnel'
                    request = json.loads(read_exact(server.stdout,int.from_bytes(header[8:],'big'),deadline))
                    assert request == {'type':'clientHandshakeRequest','mtu':16000}, request
                    config = {'clientParameters':{'address':'fd00::1','netmask':'ffff:ffff:ffff:ffff::','mtu':16000},
                              'serverAddress':'fd00::2','serverRSDPort':58783}
                    if mode == 'malformed':config['serverRSDPort'] = True
                    response = frame(config)
                    if mode == 'valid':
                        # A split handshake followed by its tail and a whole packet
                        # in one TLS write, then a second response to the host packet.
                        server.stdin.write(response[:-1]); server.stdin.flush()
                        time.sleep(.02)
                        server.stdin.write(response[-1:]+packet(b'HELLO')); server.stdin.flush()
                        outgoing = read_exact(server.stdout,44,deadline)
                        assert outgoing[:8] == bytes([0x60,0,0,0,0,4,59,64])
                        assert outgoing[8:24] == ipaddress.IPv6Address('fd00::1').packed
                        assert outgoing[24:40] == ipaddress.IPv6Address('fd00::2').packed
                        assert outgoing[40:] == b'PING'
                        server.stdin.write(packet(b'PONG')); server.stdin.flush()
                    elif mode == 'truncated':
                        server.stdin.write(response[:12]); server.stdin.flush(); server.stdin.close()
                    elif mode == 'oversized':
                        server.stdin.write(response+bytes([0x60,0,0,0,255,255])); server.stdin.flush()
                    elif mode == 'partial':
                        server.stdin.write(response+packet(b'DELAY')[:10]); server.stdin.flush()
                    elif mode in ('malformed','backpressure'):
                        server.stdin.write(response); server.stdin.flush()
                    # silent deliberately sends no response.
                stdout,stderr = client.communicate(timeout=8)
                text = stdout.decode().strip()
                assert client.returncode == 0,(mode,client.returncode,text,stderr.decode())
                evidence.append('PASS '+text)
            finally:
                if client is not None and client.poll() is None: client.kill();client.wait()
                server.terminate()
                try: server.wait(timeout=2)
                except subprocess.TimeoutExpired: server.kill();server.wait()
                for pipe in (server.stdin,server.stdout):
                    if pipe and not pipe.closed:pipe.close()
    text = 'macOS CDTunnel against independent synthetic loopback TLS peer: '+cipher+'\n'+'\n'.join(evidence)+'\n'
    Path('build/cdtunnel-transport-tests.log').write_text(text)
    Path('build/cdtunnel-'+cipher.lower()+'-tests.log').write_text(text)
    print(text,end='')


if __name__ == '__main__':main()
