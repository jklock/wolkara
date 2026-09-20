#!/usr/bin/env python3
"""Synthetic encrypted TCP/RSP peer; never attaches to a real process."""
import json
import shutil
import socket
import struct
import subprocess
import tempfile
import time
import sys
from pathlib import Path
from test_tcp_over_tunnel import load

def main():
    cd=load('cd_fixture','tools/test_cd_tunnel_transport.py')
    tcp=load('tcp_fixture','tests/test_tunnel_tcp_peer.py')
    rsp=load('rsp_fixture','tests/test_debug_arena_peer.py')
    evidence=[]
    service='--service' in sys.argv
    regions=(0x200000,) if service else rsp.REGIONS
    modes=('valid','wrong-challenge','missing-detach-reply')+(('service-expiry',) if service else ())
    for mode in modes:
        with socket.socket() as s: s.bind(('127.0.0.1',0)); port=s.getsockname()[1]
        with tempfile.TemporaryFile() as errors:
            server=subprocess.Popen([shutil.which('openssl'),'s_server','-quiet','-no_ign_eof','-accept',f'127.0.0.1:{port}',
                '-nocert','-psk',bytes(range(32)).hex(),'-tls1_2','-cipher','PSK-AES256-CBC-SHA384'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=errors,bufsize=0)
            client=None
            try:
                for _ in range(100):
                    if server.poll() is not None: raise RuntimeError('TLS peer stopped')
                    try:
                        with socket.create_connection(('127.0.0.1',port),timeout=.1): break
                    except OSError: time.sleep(.03)
                else: raise TimeoutError('TLS peer start')
                client=subprocess.Popen(['build/probe_arena_service' if service else 'build/probe_debug_over_tunnel',str(port),mode],stdout=subprocess.PIPE,stderr=subprocess.PIPE)
                deadline=time.monotonic()+15
                h=cd.read_exact(server.stdout,10,deadline); assert h[:8]==b'CDTunnel'
                assert json.loads(cd.read_exact(server.stdout,int.from_bytes(h[8:],'big'),deadline))=={'type':'clientHandshakeRequest','mtu':16000}
                server.stdin.write(cd.frame({'clientParameters':{'address':'fd00::1','netmask':'ffff:ffff:ffff:ffff::','mtu':16000},'serverAddress':'fd00::2','serverRSDPort':58783})); server.stdin.flush()
                def raw_receive():
                    h=cd.read_exact(server.stdout,40,deadline); b=cd.read_exact(server.stdout,int.from_bytes(h[4:6],'big'),deadline)
                    assert h[8:24]==tcp.LOCAL and h[24:40]==tcp.REMOTE
                    assert tcp.checksum(tcp.LOCAL+tcp.REMOTE+struct.pack('!I3xB',len(b),6)+b)==0
                    local,remote,seq,ack,offset,flags,window,_,_=struct.unpack('!HHIIBBHHH',b[:20])
                    assert remote==58783 and local>=49152
                    return local,seq,ack,flags,b[(offset>>4)*4:]
                local,seq,_,flags,data=raw_receive(); assert flags==2 and not data
                host=(seq+1)&tcp.MASK; peer=7001; incoming=bytearray()
                def send(data=b'',flags=16,sequence=None):
                    options=b'\x02\x04\x04\xc4' if flags&2 else b''
                    body=struct.pack('!HHIIBBHHH',58783,local,peer if sequence is None else sequence,host,((20+len(options))//4)<<4,flags,32768,0,0)+options+data
                    check=tcp.checksum(tcp.REMOTE+tcp.LOCAL+struct.pack('!I3xB',len(body),6)+body)
                    body=body[:16]+struct.pack('!H',check)+body[18:]
                    server.stdin.write(struct.pack('!IHBB',6<<28,len(body),6,64)+tcp.REMOTE+tcp.LOCAL+body); server.stdin.flush()
                send(flags=18,sequence=peer-1)
                def receive():
                    nonlocal host
                    p,seq,ack,flags,data=raw_receive(); assert p==local and seq==host and not flags&7
                    if data:
                        incoming.extend(data); host=(host+len(data))&tcp.MASK; send()
                    return ack
                def take(n):
                    while len(incoming)<n: receive()
                    b=bytes(incoming[:n]); del incoming[:n]; return b
                def read_command():
                    b=take(1)
                    while b==b'+': b=take(1)
                    assert b==b'$'
                    while True:
                        byte=take(1); b+=byte
                        if byte==b'#': break
                    return rsp.command(b+take(2))
                def respond(text):
                    nonlocal peer
                    data=b'+'+rsp.frame(text)
                    for i in range(0,len(data),1301):
                        chunk=data[i:i+1301]; send(chunk,24); peer+=len(chunk)
                        # On detach the client is entitled to close immediately
                        # after reading its OK, so no final ACK is required here.
                        if i+len(chunk)<len(data):
                            while receive()!=peer: pass
                preflight={base:0 for base in regions}; wrote=0; finished=False
                for _ in range(100):
                    text=read_command()
                    if mode=='service-expiry':
                        assert text=='qSupported'; finished=True; break
                    if text=='qSupported': answer='PacketSize=8000'
                    elif text=='QSetDetachOnError:1': answer='OK'
                    elif text=='vAttach;4d2': answer='T13thread:7;'
                    elif text=='qProcessInfo': answer='pid:4d2;effective-uid:1f5;cputype:100000c;ptrsize:8;endian:little;'
                    elif text.startswith('qMemoryRegionInfo:'):
                        base=int(text.split(':')[1],16); assert base in regions; answer=f'start:{base:x};size:4000;permissions:rx;'
                    elif text.startswith('m'):
                        address,count=(int(v,16) for v in text[1:].split(','))
                        if address==0x100000:
                            assert count==32; answer=('ff'*32 if mode=='wrong-challenge' else rsp.CHALLENGE.hex())
                        else:
                            base=next(b for b in regions if b<=address<b+16384)
                            assert address+count<=base+16384
                            if wrote==0: preflight[base]+=count
                            answer='00'*count
                    elif text.startswith('M'):
                        header,data=text[1:].split(':');address,count=(int(v,16) for v in header.split(','))
                        assert all(n==16384 for n in preflight.values())
                        assert any(b<=address and address+count<=b+16384 for b in regions) and data=='00'*count
                        wrote+=count;answer='OK'
                    elif text=='D':
                        finished=True
                        assert wrote==(0 if mode=='wrong-challenge' else 16384*len(regions))
                        if mode=='missing-detach-reply': break
                        answer='OK'
                    else: raise AssertionError(text)
                    respond(answer)
                    if finished: break
                assert finished
                stdout,stderr=client.communicate(timeout=15)
                assert client.returncode==0,(mode,client.returncode,stdout.decode(),stderr.decode())
                evidence.append('PASS '+stdout.decode().strip())
            finally:
                if client is not None and client.poll() is None: client.kill();client.wait()
                server.terminate()
                try: server.wait(timeout=2)
                except subprocess.TimeoutExpired:server.kill();server.wait()
                for pipe in (server.stdin,server.stdout):
                    if pipe and not pipe.closed:pipe.close()
    text='Synthetic managed TLS/CDTunnel/TCP/RSP integration (no real attachment)\n'+'\n'.join(evidence)+'\n'
    Path('build/arena-service-tests.log' if service else 'build/debug-over-tunnel-tests.log').write_text(text);print(text,end='')

if __name__=='__main__':main()
