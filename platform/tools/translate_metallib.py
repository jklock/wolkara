#!/usr/bin/env python3
"""Compile original Metal AIR modules into separate iOS libraries; never edit input.

Container fields follow MetalLibraryArchive/Metal.jl's documented reader format.
The Apple compiler validates and retargets IR; its linker creates the output.
"""
import argparse
import hashlib
import json
import os
import re
from pathlib import Path
import struct
import subprocess
import tempfile


def modules(data):
    data=bytes(data)
    if len(data)<88 or data[:4]!=b'MTLB': raise ValueError('not a Metal library')
    total,table,table_size,public,public_size,private,private_size,code,code_size=struct.unpack_from('<9Q',data,16)
    if total!=len(data): raise ValueError('library size mismatch')
    for off,size in [(table,table_size),(public,public_size),(private,private_size),(code,code_size)]:
        if off<88 or off>len(data) or size>len(data)-off: raise ValueError('section outside file')
    if table+4>public: raise ValueError('invalid function table')
    count=struct.unpack_from('<I',data,table)[0]
    if not 0<count<=65536: raise ValueError('invalid function count')
    pos=table+4; result=[]; seen=set()
    for _ in range(count):
        if pos+4>public: raise ValueError('truncated function record')
        size=struct.unpack_from('<I',data,pos)[0]; end=pos+size; pos+=4
        if size<8 or end>public: raise ValueError('invalid function record size')
        tags={}; terminated=False
        while pos+4<=end:
            tag=data[pos:pos+4];pos+=4
            if tag==b'ENDT': terminated=True;break
            if pos+2>end: raise ValueError('truncated tag')
            n=struct.unpack_from('<H',data,pos)[0];pos+=2
            if n>end-pos or tag in tags: raise ValueError('invalid or duplicate tag')
            tags[tag]=data[pos:pos+n];pos+=n
        if not terminated or pos!=end: raise ValueError('invalid tag termination')
        if len(tags.get(b'OFFT',b''))!=24 or len(tags.get(b'MDSZ',b''))!=8 or len(tags.get(b'VERS',b''))!=8:
            raise ValueError('missing module metadata')
        offset=struct.unpack('<3Q',tags[b'OFFT'])[2];length=struct.unpack('<Q',tags[b'MDSZ'])[0]
        if length<20 or offset>code_size or length>code_size-offset: raise ValueError('module outside section')
        module=data[code+offset:code+offset+length]
        magic,version,start,bitcode_size,cpu=struct.unpack_from('<5I',module)
        if magic!=0x0b17c0de or version!=0 or start<20 or start>length or bitcode_size>length-start:
            raise ValueError('unsupported AIR wrapper')
        if module[start:start+4]!=b'BC\xc0\xde': raise ValueError('missing LLVM bitcode')
        if tags.get(b'HASH')!=hashlib.sha256(module).digest(): raise ValueError('module hash mismatch')
        air=struct.unpack('<4H',tags[b'VERS'])[:2]
        if (offset,length) not in seen:
            seen.add((offset,length));result.append((air,module))
    return result


def compiler_path():
    configured=os.environ.get('METAL_COMPILER')
    if configured: return Path(configured)
    os.environ.setdefault('DEVELOPER_DIR','/Applications/Xcode.app/Contents/Developer')
    info=json.loads(subprocess.check_output(['xcodebuild','-showComponent','MetalToolchain','-json']))
    return Path(info['toolchainSearchPath'])/'Metal.xctoolchain/usr/bin/metal'


def translate(source,output,compiler=None):
    if source.resolve()==output.resolve(): raise ValueError("output must be separate from original")
    data=source.read_bytes(); entries=modules(data)
    # Match the AIR revision rather than changing version metadata. Apple links
    # 2.0/2.1/.../2.7 for iOS 11/12/.../18; 2.8 corresponds to iOS 26.
    versions={(2,i):str(11+i)+'.0' for i in range(8)};versions[(2,8)]='26.0'
    air_versions={v for v,_ in entries}
    if len(air_versions)!=1 or next(iter(air_versions)) not in versions: raise ValueError('unsupported AIR version combination')
    target='air64-apple-ios'+versions[next(iter(air_versions))]
    compiler=compiler or compiler_path()
    output.parent.mkdir(parents=True,exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='tolkara-air-',dir=output.parent) as directory:
        directory=Path(directory); objects=[]
        for i,(_,module) in enumerate(entries):
            original=directory/f'{i}.mac.air';compiled=directory/f'{i}.ios.air';original.write_bytes(module)
            subprocess.run([str(compiler),'-target',target,'-c','-x','ir',str(original),'-o',str(compiled)],check=True,capture_output=True)
            objects.append(compiled)
        linked=directory/'translated.metallib'
        try:
            subprocess.run([str(compiler),'-target',target,*map(str,objects),'-o',str(linked)],check=True,capture_output=True)
        except subprocess.CalledProcessError as error:
            # Older iOS AIR targets limit texture slots to 31. Desktop AIR 2.1
            # can legitimately use more. Let Apple's semantic upgrade pass
            # produce new AIR before targeting iOS 14; never edit the original
            # bitcode or merely relabel its version metadata.
            if next(iter(air_versions)) >= (2,3) or not re.search(rb'texture argument .+ has invalid location',error.stderr or b''):
                raise
            target='air64-apple-ios14.0';objects=[]
            for i in range(len(entries)):
                original=directory/f'{i}.mac.air';upgraded=directory/f'{i}.upgraded.air';compiled=directory/f'{i}.ios.air'
                subprocess.run([str(compiler.with_name('air-opt')),'--air-upgrade','--upgrade-to-air-version=2.3',str(original),'-o',str(upgraded)],check=True,capture_output=True)
                subprocess.run([str(compiler),'-target',target,'-c','-x','ir',str(upgraded),'-o',str(compiled)],check=True,capture_output=True)
                objects.append(compiled)
            subprocess.run([str(compiler),'-target',target,*map(str,objects),'-o',str(linked)],check=True,capture_output=True)
        if linked.read_bytes()[:4]!=b'MTLB': raise ValueError('compiler did not produce a Metal library')
        linked.replace(output)
    return {'original_sha256':hashlib.sha256(data).hexdigest(),'target':target,'modules':len(entries),'output':str(output)}


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('source',type=Path);p.add_argument('output',type=Path);a=p.parse_args()
    if a.source.resolve()==a.output.resolve(): p.error('output must be separate from original')
    print(json.dumps(translate(a.source,a.output),indent=2))
if __name__=='__main__': main()
