#!/usr/bin/env python3
"""Integration regression using our own shader and Apple's Metal compiler."""
import hashlib
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'tools'))
from translate_metallib import modules,translate


@unittest.skipUnless(os.environ.get('METAL_COMPILER'),'set METAL_COMPILER for compiler integration')
class CompilerTests(unittest.TestCase):
    def test_desktop_texture_slot_33(self):
        compiler=Path(os.environ['METAL_COMPILER'])
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);source=root/'test.metal';original=root/'original.metallib'
            source.write_text('#include <metal_stdlib>\nusing namespace metal;\n'
                              'fragment float4 sample33(texture2d<float, access::read> tex [[texture(33)]]) '
                              '{ return tex.read(uint2(0)); }\n')
            compiled=subprocess.run([str(compiler),'-target','air64-apple-macos10.14','-std=macos-metal2.1',
                                     '-fmodules-cache-path='+str(root/'modules'),
                                     str(source),'-o',str(original)],capture_output=True,text=True)
            self.assertEqual(compiled.returncode,0,compiled.stderr)
            before=hashlib.sha256(original.read_bytes()).digest()
            self.assertEqual(modules(original.read_bytes())[0][0],(2,1))
            output=root/'translated.metallib';report=translate(original,output,compiler)
            self.assertEqual(report['target'],'air64-apple-ios14.0')
            self.assertEqual(modules(output.read_bytes())[0][0],(2,3))
            self.assertEqual(hashlib.sha256(original.read_bytes()).digest(),before)


if __name__=='__main__':unittest.main()
