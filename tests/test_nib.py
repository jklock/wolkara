import importlib.util
import json
from pathlib import Path
import struct
import subprocess
import sys
import unittest
spec=importlib.util.spec_from_file_location('inspect_nib',Path(__file__).resolve().parents[1]/'tools/inspect_nib.py')
reader=importlib.util.module_from_spec(spec);spec.loader.exec_module(reader)
# The same reader, ported into the app.
IN_APP=Path(sys.argv.pop(1)).resolve() if len(sys.argv)>1 else None
def varint(n):
    data=bytearray()
    while n>=128:data.append(n&127);n>>=7
    data.append(n|128);return bytes(data)
def fixture():
    objects=bytes([0x80,0x80,0x81])
    keys=varint(8)+b'NS.bytes'
    values=bytes([0x80,8])+varint(5)+b'hello'
    classes=varint(9)+varint(0)+b'NSString\0'
    tables=[objects,keys,values,classes];offset=50;header=[1,10]
    for table in tables:header += [1,offset];offset+=len(table)
    return b'NIBArchive'+struct.pack('<10I',*header)+b''.join(tables)
def truncated():
    return [fixture()[:end] for end in [0,9,49,50,54,60,len(fixture())-2]]
def malformed():
    data=[]
    for offset,value in [(18,100001),(22,0),(26,0xffffffff)]:
        one=bytearray(fixture());struct.pack_into('<I',one,offset,value);data.append(bytes(one))
    one=bytearray(fixture());one[50]=0x8f;data.append(bytes(one))
    return data
# Every value type the archive defines, in one object.
def typed_fixture():
    objects=bytes([0x80,0x80,0x8b])+bytes([0x81,0x8b,0x80])
    keys=b''
    for name in [b'byte',b'short',b'int',b'long',b'single',b'double',b'yes',b'no',b'none',b'ref',b'bytes']:
        keys+=varint(len(name))+name
    values=(bytes([0x80,0])+struct.pack('<b',-2)+
            bytes([0x81,1])+struct.pack('<h',-300)+
            bytes([0x82,2])+struct.pack('<i',-70000)+
            bytes([0x83,3])+struct.pack('<q',-5000000000)+
            bytes([0x84,6])+struct.pack('<f',0.1)+
            bytes([0x85,7])+struct.pack('<d',0.1)+
            bytes([0x86,4])+bytes([0x87,5])+bytes([0x88,9])+
            bytes([0x89,10])+struct.pack('<I',1)+
            bytes([0x8a,8])+varint(3)+b'\x00\xfe\x7f')
    classes=varint(9)+varint(0)+b'NSObject\0'+varint(7)+varint(1)+struct.pack('<I',0)+b'NSMenu\0'
    tables=[objects,keys,values,classes];offset=50;header=[1,10]
    for count,table in zip([2,11,11,2],tables):header+=[count,offset];offset+=len(table)
    return b'NIBArchive'+struct.pack('<10I',*header)+b''.join(tables)
# One data value of the given size, as an image in a nib.
def blob_fixture(size):
    blob=bytes(range(256))*(size//256)+bytes(size%256)
    objects=bytes([0x80,0x80,0x81])
    keys=varint(8)+b'NS.bytes'
    values=bytes([0x80,8])+varint(len(blob))+blob
    classes=varint(7)+varint(0)+b'NSData\0'
    tables=[objects,keys,values,classes];offset=50;header=[1,10]
    for table in tables:header+=[1,offset];offset+=len(table)
    return b'NIBArchive'+struct.pack('<10I',*header)+b''.join(tables)
class NibTests(unittest.TestCase):
    def in_app(self,data,*command):
        path=IN_APP.parent/'nib-fixture.nib';path.write_bytes(data)
        return subprocess.run([*command,str(IN_APP),str(path)],capture_output=True,text=True)
    def resident(self,data):
        result=self.in_app(data,'/usr/bin/time','-l')
        self.assertEqual(result.returncode,0,result.stderr)
        for line in result.stderr.splitlines():
            if line.strip().endswith('maximum resident set size'):return int(line.split()[0])
        self.fail('no resident size reported')
    def test_preserves_typed_values(self):
        self.assertEqual(reader.parse(fixture()),{'format':1,'objects':[{'class':'NSString','values':[['NS.bytes',{'data':'68656c6c6f'}]]}]})
    def test_truncated_tables(self):
        for data in truncated():
            with self.assertRaises((ValueError,struct.error)):reader.parse(data)
    def test_invalid_reference_and_count(self):
        for data in malformed():
            with self.assertRaises((ValueError,struct.error)):reader.parse(data)
    @unittest.skipUnless(IN_APP,'the in-app reader was not built')
    def test_in_app_reader_agrees(self):
        # A value of every kind, not just the table shape.
        for data in (fixture(),typed_fixture(),blob_fixture(4<<20)):
            result=self.in_app(data)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertEqual(json.loads(result.stdout),reader.parse(data))
    @unittest.skipUnless(IN_APP,'the in-app reader was not built')
    def test_in_app_reader_holds_a_blob_in_one_piece(self):
        # Memory per byte of blob, fixed cost aside.
        size=4<<20
        growth=(self.resident(blob_fixture(size))-self.resident(blob_fixture(256)))/size
        self.assertLess(growth,24,f'{growth:.1f} bytes held per byte of blob')
    @unittest.skipUnless(IN_APP,'the in-app reader was not built')
    def test_in_app_reader_refuses_the_same(self):
        for data in truncated()+malformed():
            result=self.in_app(data)
            self.assertNotEqual(result.returncode,0,result.stdout)
            self.assertNotIn('Sanitizer',result.stderr)
if __name__=='__main__':unittest.main()
