#!/usr/bin/env python3
"""Read a compiled NIBArchive as data, without instantiating archived classes."""
import argparse
import json
import struct
from pathlib import Path


def parse(data):
    if len(data)<50 or data[:10]!=b'NIBArchive': raise ValueError('not a NIBArchive')
    header=struct.unpack_from('<10I',data,10)
    if header[0]!=1 or header[1] not in (9,10): raise ValueError('unsupported NIB version')
    def varint(offset):
        value=0
        for shift in range(0,64,7):
            if offset>=len(data): raise ValueError('truncated varint')
            b=data[offset]; offset+=1
            value|=(b&127)<<shift
            if b&128: return value,offset
        raise ValueError('oversized varint')
    tables=[]
    for kind in range(4):
        count,offset=header[2+kind*2:4+kind*2]
        if count>100000 or offset<50 or offset>len(data): raise ValueError('invalid NIB table')
        table=[]
        for _ in range(count):
            if kind==0:
                value=[]
                for _ in range(3): x,offset=varint(offset);value.append(x)
            elif kind in (1,3):
                length,offset=varint(offset)
                if kind==3:
                    extras,offset=varint(offset); offset+=4*extras
                if offset+length>len(data):raise ValueError('truncated string')
                value=data[offset:offset+length].rstrip(b'\0').decode('utf8'); offset+=length
            else:
                key,offset=varint(offset)
                if offset>=len(data):raise ValueError('truncated type')
                type_=data[offset];offset+=1
                if type_ in (4,5,9):value={4:True,5:False,9:None}[type_]
                elif type_==8:
                    length,offset=varint(offset)
                    if length>len(data)-offset:raise ValueError('truncated data')
                    value={'data':data[offset:offset+length].hex()};offset+=length
                else:
                    formats={0:'b',1:'h',2:'i',3:'q',6:'f',7:'d',10:'I'}
                    if type_ not in formats: raise ValueError('unknown NIB value type')
                    fmt='<'+formats[type_];value=struct.unpack_from(fmt,data,offset)[0];offset+=struct.calcsize(fmt)
                    if type_==10:value={'ref':value}
                value=(key,value)
            table.append(value)
        tables.append(table)
    objects,keys,values,classes=tables
    result=[]
    for cls,start,count in objects:
        if cls>=len(classes) or start>len(values) or count>len(values)-start:raise ValueError('invalid object')
        fields=[]
        for key,value in values[start:start+count]:
            if key>=len(keys):raise ValueError('invalid key')
            if isinstance(value,dict) and 'ref'in value and value['ref']>=len(objects):raise ValueError('invalid reference')
            fields.append([keys[key],value])
        result.append({'class':classes[cls],'values':fields})
    return {'format':1,'objects':result}

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('path',type=Path);parser.add_argument('--out',type=Path)
    args=parser.parse_args(); result=json.dumps(parse(args.path.read_bytes()),indent=2)
    if args.out:args.out.write_text(result+'\n')
    else:print(result)
