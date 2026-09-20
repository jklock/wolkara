"""Debugger arena initialization must reject populated guest memory before writes."""
import importlib.util
from pathlib import Path
import struct
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

class Error:
    def Success(self): return True

spec=importlib.util.spec_from_file_location('lldb_arena_publish',Path(__file__).resolve().parents[1]/'tools/lldb_arena_publish.py')
helper=importlib.util.module_from_spec(spec)
with patch.dict(sys.modules,{'lldb':SimpleNamespace(SBError=Error)}): spec.loader.exec_module(helper)

class ArenaTests(unittest.TestCase):
    def arena(self, data, name='host_debugger_publish_arena', token=bytes(8)):
        memory=bytearray(data); completion=bytearray(token)
        address=0x100000000; token_address=0x200000000
        frame=Mock(); frame.GetFunctionName.return_value=name
        regs={'x0':address,'x1':len(data),'x2':token_address}
        frame.FindRegister.side_effect=lambda reg:SimpleNamespace(GetValueAsUnsigned=lambda:regs[reg])
        process=Mock(); process.GetSelectedThread.return_value.GetFrameAtIndex.return_value=frame
        def read(a,n,e): return bytes(completion if a==token_address else memory[a-address:a-address+n])
        def write(a,d,e):
            if a==token_address: completion[:]=d
            else: memory[a-address:a-address+len(d)]=d
            return len(d)
        process.ReadMemory.side_effect=read; process.WriteMemory.side_effect=write
        debugger=Mock(); debugger.GetSelectedTarget.return_value.GetProcess.return_value=process
        return debugger,process,memory,completion
    def test_empty_arena(self):
        debugger,process,memory,token=self.arena(bytes(2*1024*1024))
        helper.publish(debugger)
        self.assertFalse(any(memory)); self.assertEqual(struct.unpack('<Q',token)[0],0x49504144434f4445)
        self.assertEqual(process.WriteMemory.call_count,3)
    def test_preflight_all_chunks_before_writes(self):
        debugger,process,_,_=self.arena(bytes(2*1024*1024-1)+b'x')
        with self.assertRaises(RuntimeError): helper.publish(debugger)
        process.WriteMemory.assert_not_called()
    def test_rejects_wrong_context_or_token(self):
        for kwargs in [{'name':'guest_code'},{'token':b'x'*8}]:
            debugger,process,_,_=self.arena(bytes(16384),**kwargs)
            with self.assertRaises(RuntimeError): helper.publish(debugger)
            process.WriteMemory.assert_not_called()

if __name__=='__main__': unittest.main()
