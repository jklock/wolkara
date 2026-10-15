#!/usr/bin/env python3
"""Independent packet peer for our bounded CDTunnel TCP implementation.

No device/network access: Python builds and validates packets independently and
exchanges them with the real Swift state machine over stdin/stdout.
"""
import base64
import ipaddress
import json
import select
import struct
import subprocess
import tempfile
from pathlib import Path

LOCAL=ipaddress.IPv6Address('fd00::1').packed
REMOTE=ipaddress.IPv6Address('fd00::2').packed
MASK=(1<<32)-1

def checksum(data):
    data+=b'\0' if len(data)%2 else b''
    value=sum(struct.unpack('!%dH'%(len(data)//2),data))
    while value>>16:value=(value&65535)+(value>>16)
    return (~value)&65535

def packet(seq,ack,payload=b'',flags=16,window=200,mss=None):
    options=b'' if mss is None else struct.pack('!BBH',2,4,mss)
    tcp=struct.pack('!HHIIBBHHH',58783,49160,seq&MASK,ack&MASK,((20+len(options))//4)<<4,flags,window,0,0)+options+payload
    pseudo=REMOTE+LOCAL+struct.pack('!I3xB',len(tcp),6)
    tcp=tcp[:16]+struct.pack('!H',checksum(pseudo+tcp))+tcp[18:]
    return struct.pack('!IHBB',6<<28,len(tcp),6,64)+REMOTE+LOCAL+tcp

def decode(raw):
    assert len(raw)>=60 and raw[0]>>4==6 and raw[6:8]==b'\x06\x40'
    assert raw[8:24]==LOCAL and raw[24:40]==REMOTE
    assert int.from_bytes(raw[4:6],'big')==len(raw)-40
    tcp=raw[40:];assert checksum(LOCAL+REMOTE+struct.pack('!I3xB',len(tcp),6)+tcp)==0
    source,dest,seq,ack,offset,flags,window,_,_=struct.unpack('!HHIIBBHHH',tcp[:20])
    assert (source,dest)==(49160,58783) and 20<=offset//16*4<=len(tcp)
    return dict(seq=seq,ack=ack,flags=flags,window=window,data=tcp[(offset>>4)*4:],raw=raw)

class Driver:
    def __init__(self):
        self.err=tempfile.TemporaryFile()
        self.child=subprocess.Popen(['build/probe_tunnel_tcp'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=self.err,bufsize=0)
        self.now=0
    def call(self,op,**args):
        self.now+=.01
        for key in ('data',):
            if key in args:args[key]=base64.b64encode(args[key]).decode()
        self.child.stdin.write((json.dumps(dict(op=op,now=self.now,**args))+'\n').encode())
        if not select.select([self.child.stdout],[],[],5)[0]:raise TimeoutError('Swift harness stalled')
        line=self.child.stdout.readline()
        if not line:
            self.err.seek(0);raise RuntimeError(self.err.read(4096).decode())
        result=json.loads(line)
        assert 'error' not in result,result
        result['packets']=[decode(base64.b64decode(e['packet'])) for e in result['events'] if 'packet' in e]
        return result
    def receive(self,*args,**kw):return self.call('receive',data=packet(*args,**kw))
    def tick(self,delta):self.now+=delta;return self.call('tick')
    def close(self):
        self.child.stdin.close()
        try:self.child.wait(timeout=2)
        except subprocess.TimeoutExpired:self.child.kill();self.child.wait()
        self.err.close()

def main():
    d=Driver()
    try:
        client=0xffffffe0;server=0xffffff20
        syn=d.call('connect')['packets'][0]
        assert syn['flags']==2 and syn['seq']==client
        retry=d.tick(1)['packets'][0];assert retry['raw']==syn['raw']
        client=(client+1)&MASK
        result=d.receive(server,client,flags=18,mss=97)
        server=(server+1)&MASK
        assert result['state']=='established' and result['packets'][0]['ack']==server
        source=bytes((i*37+11)%256 for i in range(9000))
        sent=d.call('write',data=source)['packets']
        received=bytearray();segments=0
        while sent:
            assert len(sent)==1
            segment=sent[0];data=segment['data'];assert segment['seq']==client and 0<len(data)<=97
            if segments==7:
                # A receiver ACKs only an initial portion; the retransmission
                # must start at its new ACK, without delivering those bytes twice.
                split=13;received.extend(data[:split]);client=(client+split)&MASK
                assert not d.receive(server,client)['packets']
                retried=d.tick(1.1)['packets'][0]
                assert retried['seq']==client and retried['data']==data[split:]
                data=retried['data']
            received.extend(data);client=(client+len(data))&MASK
            if segments==3:
                retried=d.tick(1.1)['packets'][0]
                assert retried['seq']==segment['seq'] and retried['data']==data
            if segments==12:
                assert not d.receive(server,client,window=0)['packets']
                probe=d.tick(1.1)['packets'][0]
                assert probe['seq']==(client-1)&MASK and probe['data']==bytes(received[-1:])
            sent=d.receive(server,client)['packets'];segments+=1
        assert bytes(received)==source and segments>90
        target=bytes((i*13+7)%256 for i in range(40000))
        offset=0;window=32768;delivered=bytearray();count=0
        while offset<len(target):
            if window==0:
                result=d.call('read',maximum=777)
                delivered+=base64.b64decode(result['data'])
                window=result['packets'][0]['window'];assert window==777
            size=min(1200,window,len(target)-offset)
            if count%11==0 and offset+size+10<len(target) and window>size:
                early=d.receive((server+size)&MASK,client,payload=target[offset+size:offset+size+10])
                assert early['packets'][0]['ack']==server
                assert not any(e.get('type')=='readable' for e in early['events'])
            raw=packet(server,client,payload=target[offset:offset+size])
            result=d.call('receive',data=raw)
            server=(server+size)&MASK;offset+=size
            assert result['packets'][-1]['ack']==server
            window=result['packets'][-1]['window']
            duplicate=d.call('receive',data=raw)
            assert not any(e.get('type')=='readable' for e in duplicate['events'])
            count+=1
        while len(delivered)<len(target):
            result=d.call('read',maximum=999)
            data=base64.b64decode(result['data']);assert data
            delivered+=data
        assert bytes(delivered)==target
        result=d.receive(server,client,flags=17);server=(server+1)&MASK
        assert result['state']=='closeWait' and result['packets'][0]['ack']==server
        reply=d.call('write',data=b'done')['packets'][0]
        assert reply['seq']==client and reply['data']==b'done'
        client=(client+4)&MASK;d.receive(server,client)
        fin=d.call('finish')['packets'][0]
        assert fin['flags']&1 and fin['seq']==client
        client=(client+1)&MASK
        assert d.receive(server,client)['state']=='closed'
        assert not d.tick(200)['packets']
        text='PASS: independent Python TCP peer exchanged 9KB/40KB, verified every checksum, and exercised loss, partial ACK, zero window, reordering, duplication, sequence wrap and half-close\n'
        Path('build/tunnel-tcp-peer-tests.log').write_text(text);print(text,end='')
    finally:d.close()

if __name__=='__main__':main()
