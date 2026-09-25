import importlib.util
from pathlib import Path
import struct
import unittest
spec=importlib.util.spec_from_file_location('inspect_nib',Path(__file__).resolve().parents[1]/'tools/inspect_nib.py')
reader=importlib.util.module_from_spec(spec);spec.loader.exec_module(reader)
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
class NibTests(unittest.TestCase):
    def test_preserves_typed_values(self):
        self.assertEqual(reader.parse(fixture()),{'format':1,'objects':[{'class':'NSString','values':[['NS.bytes',{'data':'68656c6c6f'}]]}]})
    def test_truncated_tables(self):
        for end in [0,9,49,50,54,60,len(fixture())-2]:
            with self.assertRaises((ValueError,struct.error)):reader.parse(fixture()[:end])
    def test_invalid_reference_and_count(self):
        for offset,value in [(18,100001),(22,0),(26,0xffffffff)]:
            data=bytearray(fixture());struct.pack_into('<I',data,offset,value)
            with self.assertRaises((ValueError,struct.error)):reader.parse(data)
        data=bytearray(fixture());data[50]=0x8f
        with self.assertRaises(ValueError):reader.parse(data)
if __name__=='__main__':unittest.main()
