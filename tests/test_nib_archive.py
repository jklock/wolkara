"""The in-app NIBArchive reader against tools/inspect_nib.py, on synthetic nibs."""
import json
from pathlib import Path
import struct
import subprocess
import sys
import unittest
from test_nib import fixture, reader, varint

ROOT=Path(__file__).resolve().parents[1]
def reader_path():
    # tools/test_emulation.sh passes its build; under discover, build one.
    if __name__=='__main__' and len(sys.argv)>1:return Path(sys.argv.pop(1)).resolve()
    path=ROOT/'build/emulation/test_nib_archive_unittest'
    path.parent.mkdir(parents=True,exist_ok=True)
    subprocess.run(['xcrun','clang','-fobjc-arc','-Wall','-Wextra','-Werror','-O1','-g','-fsanitize=address,undefined',
                    '-Itranslation/AppKit','-framework','Foundation','translation/AppKit/NibArchive.m','tests/test_nib_archive.m',
                    '-o',str(path)],cwd=ROOT,check=True)
    return path
IN_APP=reader_path()
# The cases test_nib.py refuses, as data.
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
class InAppNibTests(unittest.TestCase):
    def in_app(self,data,*command):
        path=IN_APP.parent/'nib-fixture.nib';path.write_bytes(data)
        return subprocess.run([*command,str(IN_APP),str(path)],capture_output=True,text=True)
    def resident(self,data):
        result=self.in_app(data,'/usr/bin/time','-l')
        self.assertEqual(result.returncode,0,result.stderr)
        for line in result.stderr.splitlines():
            if line.strip().endswith('maximum resident set size'):return int(line.split()[0])
        self.fail('no resident size reported')
    def test_agrees_with_the_build_time_reader(self):
        # A value of every kind, not just the table shape.
        for data in (fixture(),typed_fixture(),blob_fixture(4<<20)):
            result=self.in_app(data)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertEqual(json.loads(result.stdout),reader.parse(data))
    def test_holds_a_blob_in_one_piece(self):
        # Memory per byte of blob, fixed cost aside.
        size=4<<20
        growth=(self.resident(blob_fixture(size))-self.resident(blob_fixture(256)))/size
        self.assertLess(growth,24,f'{growth:.1f} bytes held per byte of blob')
    def test_refuses_what_the_build_time_reader_refuses(self):
        for data in truncated()+malformed():
            with self.assertRaises((ValueError,struct.error)):reader.parse(data)
            result=self.in_app(data)
            self.assertNotEqual(result.returncode,0,result.stdout)
            self.assertNotIn('Sanitizer',result.stderr)
if __name__=='__main__':unittest.main()
