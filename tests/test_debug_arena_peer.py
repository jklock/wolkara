#!/usr/bin/env python3
"""Independent GDB-RSP peer over pipes. No debugger/device/process attachment.
Only synthetic addresses, challenge bytes and zero-filled byte arrays are used.
"""
import base64
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
CHALLENGE = bytes(range(1,33))
REGIONS = (0x200000,0x400000)

def frame(text):
    b = text.encode('ascii')
    encoded = b''.join(bytes([125,v^32]) if v in b'$#}*' else bytes([v]) for v in b)
    return b'$'+encoded+b'#'+f'{sum(encoded)%256:02x}'.encode()

def command(wire):
    assert wire[0:1] == b'$' and wire[-3:-2] == b'#'
    b = wire[1:-3]; assert sum(b)%256 == int(wire[-2:],16)
    result = bytearray(); escaped = False
    for v in b:
        if escaped: result.append(v^32); escaped=False
        elif v == 125: escaped=True
        else: result.append(v)
    assert not escaped
    return result.decode('ascii')

class Driver:
    def __enter__(self):
        self.p = subprocess.Popen([str(ROOT/'build/probe_debug_arena')],stdin=subprocess.PIPE,stdout=subprocess.PIPE,text=True)
        self.now = 0
        return self
    def __exit__(self,*args):
        self.p.stdin.close(); self.p.wait(timeout=3); assert self.p.returncode == 0
    def call(self,**value):
        value['now'] = self.now
        self.p.stdin.write(json.dumps(value)+'\n'); self.p.stdin.flush()
        result = json.loads(self.p.stdout.readline()); assert 'error' not in result,result
        return result
    def send(self,wire):
        self.now += .001
        return self.call(data=base64.b64encode(wire).decode())

def emitted(result):
    commands=[]; terminal=[]; controls=[]
    for event in result['events']:
        if 'send' in event:
            b = base64.b64decode(event['send'])
            if b in (b'+',b'-'): controls.append(b)
            else: commands.append(command(b))
        else: terminal.append(event)
    return commands,terminal,controls

def exchange(mode='success',packet_size='1000',fragment=False):
    with Driver() as driver:
        commands,terminal,_ = emitted(driver.call(begin=True))
        reads = {base:set() for base in REGIONS}; writes=[]; after_write=False; process_queries=0; challenge_reads=0; detach=False
        while commands:
            assert len(commands)==1
            text = commands[0]
            if text == 'qSupported': response = 'PacketSize='+packet_size+';qXfer:features:read+'
            elif text == 'QSetDetachOnError:1': response = '' if mode == 'unsupported_detach_policy' else 'OK'
            elif text.startswith('vAttach;'):
                assert text == 'vAttach;4d2'
                response = 'E01' if mode == 'attach_error' else 'T13thread:7;'
            elif text == 'qProcessInfo':
                process_queries += 1
                pid = '4d3' if mode == 'wrong_pid' or (mode=='final_pid' and process_queries==2) else '4d2'
                uid = '0' if mode == 'wrong_uid' else '1f5'
                cpu = '1000007' if mode == 'wrong_arch' else '100000c'
                response = f'pid:{pid};effective-uid:{uid};cputype:{cpu};ptrsize:8;endian:little;'
                if mode == 'duplicate_pid': response += 'pid:4d2;'
            elif text.startswith('qMemoryRegionInfo:'):
                address = int(text.split(':')[1],16); assert address in REGIONS
                permission = 'rwx' if mode=='unsafe_last' and address==REGIONS[-1] else 'rx'
                response = f'start:{address:x};size:4000;permissions:{permission};'
                if mode=='file_backed': response+='name:2f6170702f62696e617279;'
            elif text.startswith('m'):
                address,count = (int(v,16) for v in text[1:].split(','))
                if address == 0x100000:
                    assert count==32
                    challenge_reads+=1
                    response = CHALLENGE.hex()
                    if mode=='wrong_challenge' or (mode=='final_challenge' and challenge_reads==2): response='ff'*32
                else:
                    base = next(base for base in REGIONS if base<=address<base+16384)
                    assert count > 0 and address+count<=base+16384
                    response = '00'*count
                    if not after_write: reads[base].update(range(address-base,address-base+count))
                    if mode=='nonzero_last' and base==REGIONS[-1] and not after_write: response='01'+response[2:]
                    if mode=='verify_corrupt' and after_write: response='01'+response[2:]
                    if mode=='short_read': response=response[:-2]
            elif text.startswith('M'):
                header,data = text[1:].split(':'); address,count=(int(v,16) for v in header.split(','))
                assert all(len(v)==16384 for v in reads.values()),'write before full preflight'
                base=next(base for base in REGIONS if base<=address<base+16384)
                assert address+count<=base+16384 and data=='00'*count
                assert len(text)<=min(int(packet_size,16),32768)
                writes.append((address,count)); after_write=True
                response='E0e' if mode=='write_error' else 'OK'
            elif text=='D':
                detach=True; response='E01' if mode=='detach_error' else 'OK'
            else: raise AssertionError(text)
            wire=b'+'+frame(response)
            if mode=='detach_trailing' and text=='D': wire+=b'junk'
            if fragment:
                results=[]
                for piece in [wire[:1],wire[1:2],wire[2:19],wire[19:]]:
                    if piece: results.extend(driver.send(piece)['events'])
                result={'events':results}
            else: result=driver.send(wire)
            commands,finished,controls=emitted(result)
            assert controls == ([] if mode=='detach_trailing' and text=='D' else [b'+']),(mode,text,controls)
            terminal+=finished
        assert len(terminal)==1,(mode,terminal)
        result=terminal[0]
        if mode=='success':
            assert result.get('success') is True and result['pid']==1234 and result['regions']==2
            assert detach and sum(n for _,n in writes)==32768
        else:
            assert 'failure' in result and not result.get('success')
            if mode in ('wrong_pid','wrong_uid','wrong_arch','duplicate_pid','wrong_challenge','unsafe_last','file_backed','nonzero_last','short_read'):
                assert not writes and detach and result['detached'] is True
            if mode in ('unsupported_detach_policy','attach_error','detach_error','detach_trailing'):
                assert result['detached'] is False
            if mode=='detach_trailing': assert result['failure']=='protocolFailure' and detach
        assert driver.call(tick=True)['events']==[]
        return result

def main():
    for mode in ['success','wrong_pid','wrong_uid','wrong_arch','duplicate_pid','wrong_challenge','unsafe_last','file_backed',
                 'nonzero_last','short_read','write_error','verify_corrupt','final_pid','final_challenge','detach_error','detach_trailing','attach_error','unsupported_detach_policy']:
        exchange(mode,fragment=mode=='success')
    exchange(packet_size='8000'); exchange(packet_size='100')
    for mode in ('checksum','nack','deadline','disconnect','cancel','coalesced','response_without_ack'):
        with Driver() as d:
            first=d.call(begin=True)
            if mode=='checksum':
                bad=bytearray(frame('PacketSize=1000'));bad[-1]=ord('0') if bad[-1]!=ord('0') else ord('1')
                result=d.send(b'+'+bad);assert emitted(result)==([],[],[b'-'])
                result=d.send(frame('PacketSize=1000'));assert emitted(result)[0]==['QSetDetachOnError:1']
            elif mode=='nack':
                assert d.send(b'-')['events']==first['events']
                assert d.send(b'-')['events']==first['events']
                assert emitted(d.send(b'-'))[1][0]['failure']=='protocolFailure'
            elif mode=='deadline':
                d.now=10;assert emitted(d.call(tick=True))[1][0]=={'failure':'timedOut','detached':False}
            elif mode in ('disconnect','cancel'):
                assert emitted(d.call(**{mode:True}))[1][0]['detached'] is False
            elif mode=='coalesced':
                result=d.send(b'+'+frame('PacketSize=1000')+b'+'+frame('OK'))
                c,t,_=emitted(result);assert not c and t[0]['failure']=='protocolFailure'
            else:
                assert emitted(d.send(frame('PacketSize=1000')))[1][0]['failure']=='protocolFailure'
    # Unsupported tiny/overflow PacketSize cannot produce an attach command.
    for value in ('ff','10000000000000000','xyz'):
        with Driver() as d:
            d.call(begin=True);c,t,_=emitted(d.send(b'+'+frame('PacketSize='+value)))
            assert not c and len(t)==1 and t[0]['detached'] is False
    # Trailing unsolicited bytes must also discard a queued next command.
    with Driver() as d:
        d.call(begin=True)
        r=d.send(b'+'+frame('PacketSize=1000')+b'junk')
        assert not emitted(r)[0] and emitted(r)[1][0]['failure']=='protocolFailure'
    text='PASS: independent RSP peer validated exact PID/UID/architecture/challenge, all-arenas preflight, zero-only writes/readback, detach confirmation, small/large packets, fragmentation, checksums, NACK limits, errors and timeouts\n'
    (ROOT/'build/debug-arena-peer-tests.log').write_text(text);print(text,end='')

if __name__=='__main__':main()
