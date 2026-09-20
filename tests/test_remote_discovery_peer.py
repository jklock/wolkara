#!/usr/bin/env python3
"""Independent stdlib-only RemoteXPC peer; exercises our Swift binary over pipes.
No Apple services or pairing records are read. All device identifiers are fixtures.
"""
import base64
import json
import struct
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
U32 = lambda x: struct.pack('<I', x)
U64 = lambda x: struct.pack('<Q', x)
BE = lambda x: struct.pack('>I', x)

def padded(b):
    return b + b'\0' * (-len(b) % 4)

def obj(value):
    if value is None:
        return U32(0x1000)
    if isinstance(value, bool):
        return U32(0x2000) + U32(value)
    if isinstance(value, int):
        return U32(0x4000) + U64(value)
    if isinstance(value, str):
        b = value.encode() + b'\0'
        return U32(0x9000) + U32(len(b)) + padded(b)
    if isinstance(value, bytes):
        return U32(0x8000) + U32(len(value)) + padded(value)
    if isinstance(value, list):
        b = U32(len(value)) + b''.join(map(obj, value))
        return U32(0xe000) + U32(len(b)) + b
    if isinstance(value, dict):
        b = U32(len(value)) + b''.join(padded(k.encode() + b'\0') + obj(v) for k, v in value.items())
        return U32(0xf000) + U32(len(b)) + b
    raise AssertionError(type(value))

def wrap(value=None, flags=0x101, message=0, raw=None):
    b = b'' if value is None and raw is None else U32(0x42133742) + U32(5) + (obj(value) if raw is None else raw)
    return U32(0x29b00b92) + U32(flags) + U64(len(b)) + U64(message) + b

def h2(kind, data=b'', stream=0, flags=0):
    return len(data).to_bytes(3, 'big') + bytes([kind, flags]) + BE(stream) + data

def frames(data):
    result = []
    while data:
        assert len(data) >= 9
        size = int.from_bytes(data[:3], 'big')
        assert len(data) >= size + 9
        result.append((data[3], data[4], int.from_bytes(data[5:9], 'big'), data[9:9 + size]))
        data = data[9 + size:]
    return result

def decode_object(b, at=0):
    kind, = struct.unpack_from('<I', b, at)
    at += 4
    if kind == 0x1000:
        return None, at
    if kind == 0x2000:
        n, = struct.unpack_from('<I', b, at)
        assert n in (0, 1)
        return bool(n), at + 4
    if kind == 0x4000:
        return struct.unpack_from('<Q', b, at)[0], at + 8
    if kind == 0xa000:
        return b[at:at + 16].hex(), at + 16
    if kind in (0x8000, 0x9000):
        length, = struct.unpack_from('<I', b, at)
        at += 4
        v = b[at:at + length]
        if kind == 0x9000:
            assert v[-1] == 0
            v = v[:-1].decode()
        return v, at + ((length + 3) // 4) * 4
    if kind == 0xf000:
        length, count = struct.unpack_from('<II', b, at)
        end = at + 4 + length
        at += 8
        d = {}
        for _ in range(count):
            nul = b.index(0, at)
            key = b[at:nul].decode()
            at += ((nul - at + 1 + 3) // 4) * 4
            value, at = decode_object(b, at)
            assert key not in d
            d[key] = value
        assert at == end
        return d, at
    raise AssertionError(hex(kind))

def decode_wrapper(b):
    magic, flags, length, message = struct.unpack_from('<IIQQ', b)
    assert magic == 0x29b00b92 and len(b) == length + 24
    if length == 0:
        return flags, message, None
    assert b[24:32] == U32(0x42133742) + U32(5)
    value, end = decode_object(b, 32)
    assert end == len(b)
    return flags, message, value

class Peer:
    def __enter__(self):
        self.p = subprocess.Popen([str(ROOT / 'build/probe_remote_discovery')], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        return self
    def __exit__(self, *args):
        self.p.stdin.close()
        self.p.wait(timeout=5)
        assert self.p.returncode == 0
    def command(self, **values):
        self.p.stdin.write(json.dumps(values) + '\n')
        self.p.stdin.flush()
        return json.loads(self.p.stdout.readline())
    def send(self, data, now=1):
        return self.command(data=base64.b64encode(data).decode(), now=now)
    def begin(self):
        result = self.command(begin=True)
        wire = sent(result)
        preface = b'PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n'
        assert wire.startswith(preface)
        f = frames(wire[len(preface):])
        assert [(x[0], x[2]) for x in f] == [(4, 0), (8, 0), (1, 1), (0, 1), (1, 3), (0, 1), (0, 3)]
        assert f[0][3] == b'\0\3' + BE(100) + b'\0\4' + BE(1048576)
        assert f[1][3] == BE(983041)
        assert decode_wrapper(f[3][3]) == (1, 0, {})
        assert decode_wrapper(f[5][3]) == (0x201, 0, None)
        assert decode_wrapper(f[6][3]) == (0x400001, 0, None)
    def settings(self):
        self.begin()
        response = self.send(h2(8, BE(1000)) + h2(4) + h2(4, flags=1))
        check_handshake(sent(response))

def sent(result):
    assert 'error' not in result, result
    return b''.join(base64.b64decode(e['send']) for e in result['events'] if 'send' in e)

def check_handshake(data):
    f = frames(data)
    assert f[0] == (4, 1, 0, b'')
    flags, message, value = decode_wrapper(b''.join(x[3] for x in f if x[0] == 0))
    assert flags == 0x101 and message == 1
    assert value == {'MessageType':'Handshake', 'MessagingProtocolVersion':7,
                     'UUID':'00112233445566778899aabbccddeeff',
                     'Properties':{'RemoteXPCVersionFlags':0x0100000000000006,'SensitivePropertiesVisible':True}, 'Services':{}}

def catalog(device='fixture-device', port='12345'):
    return {'Properties':{'UniqueDeviceID':device,'ProductType':'SyntheticDevice'},
            'Services':{'com.apple.debugserver.DVTSecureSocketProxy':{'Port':port,'Properties':{'UsesRemoteXPC':False}},
                        'fixture.xpc':{'Port':'23456','Properties':{'UsesRemoteXPC':True}}}}

def deliver(peer, wire):
    events = []
    # Break both HTTP/2 headers and XPC structures across arbitrary TCP reads.
    for start in range(0, len(wire), 113):
        result = peer.send(wire[start:start + 113])
        assert 'error' not in result, result
        events.extend(result['events'])
    return events

def failure(wire, ready=True):
    with Peer() as p:
        p.settings() if ready else p.begin()
        assert p.send(wire).get('error')
        assert p.send(h2(4)).get('error')

def main():
    with Peer() as p:
        p.settings()
        # Independent assemblers: the reply notification interleaves with root init.
        empty = wrap({}, flags=1)
        split = len(empty) // 2
        assert not p.send(h2(0, empty[:split], 1)).get('error')
        assert not p.send(h2(0, wrap(flags=0x400001), 3)).get('error')
        assert not p.send(h2(0, empty[split:], 1)).get('error')
        value = catalog()
        # Larger than the default HTTP/2 window; every byte receives exact credits.
        for i in range(700):
            value['Services'][f'fixture.service.{i:04d}'] = {'Port':str(30000+i),'Properties':{'UsesRemoteXPC':True}}
        wire = wrap(value, message=17)
        assert len(wire) > 65535
        f = h2(1, stream=3, flags=4)
        for i in range(0, len(wire), 10000):
            chunk = wire[i:i+10000]
            f += h2(0, bytes([3])+chunk+b'\0'*3, 3, 8)  # padded DATA
        events = deliver(p, f)
        catalogs = [e['catalog'] for e in events if 'catalog' in e]
        assert len(catalogs) == 1 and len(catalogs[0]) == 702
        assert catalogs[0]['fixture.xpc'] == {'port':23456,'xpc':True}
        updates = frames(b''.join(base64.b64decode(e['send']) for e in events if 'send' in e))
        total = len(wire) + 4 * ((len(wire)+9999)//10000)
        for stream in (0, 3):
            assert sum(int.from_bytes(x[3],'big') for x in updates if x[0] == 8 and x[2] == stream) == total
        assert not p.command(finish=True).get('error')

    # Initial zero stream window defers the modern handshake and resumes exactly.
    with Peer() as p:
        p.begin()
        assert frames(sent(p.send(h2(4, b'\0\4'+BE(0))))) == [(4,1,0,b'')]
        pieces = b''
        for _ in range(100):
            outgoing = frames(sent(p.send(h2(8, BE(37), 1))))
            pieces += b''.join(x[3] for x in outgoing if x[0] == 0)
            if len(pieces) >= 24 and len(pieces) == 24 + int.from_bytes(pieces[8:16], 'little'):
                break
        check_handshake(h2(4, flags=1)+h2(0,pieces,1))
        assert p.send(h2(6,b'12345678'))['events'] == [{'send':base64.b64encode(h2(6,b'12345678',flags=1)).decode()}]
        result = p.send(h2(0,wrap(catalog()),1))
        assert result['state'] == 'complete'

    for bad in [h2(4,b'bad'),h2(4,stream=1),h2(4,b'\0\4'+BE(0x80000000)),
                h2(4,b'\0\5'+BE(1)),h2(8,BE(0)),h2(8,BE(0x7fffffff)),
                h2(0,b'\x08abc',1,8),h2(0,b'',5),h2(0,b'',1,1),
                h2(1,b'nonempty',1,4),h2(6,b'123'),h2(7,b'\0'*8),h2(3,BE(1),1),
                b'\x00\x40\x01\0\0'+BE(1),h2(0,wrap(catalog('wrong-device')),1),
                h2(0,wrap(catalog(port='65536')),1),h2(0,wrap(catalog(port='0')),1),
                h2(0,wrap(catalog(port=' 123')),1),h2(0,wrap(catalog(port=123)),1),
                h2(0,wrap(raw=U32(0xf000)+U32(4)+U32(0xffffffff)),1)]:
        failure(bad)
    # Deep hostile payload without using our encoder's limits.
    v = None
    for _ in range(40):
        v = [v]
    failure(h2(0,wrap(v),1))
    # Duplicate dictionary keys cannot silently replace a port/device identifier.
    entry = padded(b'key\0') + obj(None)
    duplicate = U32(0xf000)+U32(4+len(entry)*2)+U32(2)+entry*2
    failure(h2(0,wrap(raw=duplicate),1))
    failure(h2(0,wrap(catalog()),1),ready=False)
    with Peer() as p:
        p.begin()
        assert p.command(tick=True,now=20).get('error')
    with Peer() as p:
        p.settings()
        assert not p.send(b'\0\0').get('error')
        assert p.command(finish=True).get('error')
    with Peer() as p:
        p.settings()
        assert not p.send(h2(0,wrap(catalog())[:20],1),now=19).get('error')
        assert p.command(tick=True,now=20).get('error')
    print('Independent RemoteXPC/RSD peer: handshake order/version, >64 KiB catalog, interleaving, flow control, identity, hostile input and deadlines passed')

if __name__ == "__main__":
    main()
