#!/usr/bin/env python3
import hashlib
from pathlib import Path
import struct
import sys
import unittest
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'tools'))
from translate_metallib import modules

def library():
    bitcode=b'BC\xc0\xde'+bytes(12)
    module=struct.pack('<5I',0x0b17c0de,0,20,len(bitcode),0xffffffff)+bitcode
    tags=[]
    for tag,value in [(b'NAME',b'test\0'),(b'HASH',hashlib.sha256(module).digest()),(b'MDSZ',struct.pack('<Q',len(module))),(b'OFFT',bytes(24)),(b'VERS',struct.pack('<4H',2,0,2,0))]:
        tags.append(tag+struct.pack('<H',len(value))+value)
    record=b''.join(tags)+b'ENDT';record=struct.pack('<I',4+len(record))+record
    table=struct.pack('<I',1)+record; public=88+len(table);private=public+8;code=private+8
    header=b'MTLB'+bytes(12)+struct.pack('<9Q',code+len(module),88,len(record),public,8,private,8,code,len(module))
    return header+table+struct.pack('<I4s',4,b'ENDT')*2+module

class MetalTests(unittest.TestCase):
    def test_read_module(self):
        data=library(); result=modules(data);self.assertEqual(result[0][0],(2,0));self.assertEqual(data,library())
    def test_truncation(self):
        data=library()
        for length in range(len(data)):
            with self.assertRaises(ValueError): modules(data[:length])
    def test_invalid_ranges(self):
        for offset in (24,40,56,72):
            data=bytearray(library());struct.pack_into('<Q',data,offset,2**64-1)
            with self.assertRaises(ValueError): modules(data)
    def test_hash(self):
        data=bytearray(library());data[-1]^=1
        with self.assertRaisesRegex(ValueError,'hash'): modules(data)
    def test_wrapper(self):
        data=bytearray(library());code=struct.unpack_from('<Q',data,72)[0];struct.pack_into('<I',data,code+12,2**32-1)
        with self.assertRaisesRegex(ValueError,'wrapper'): modules(data)
if __name__=='__main__':unittest.main()
