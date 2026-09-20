"""Keep the debugger publication helper confined to host-owned probe pages."""
import importlib.util
from pathlib import Path
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch


class Error:
    def Success(self):
        return True


spec = importlib.util.spec_from_file_location('lldb_code_publish', Path(__file__).resolve().parents[1] / 'tools/lldb_code_publish.py')
helper = importlib.util.module_from_spec(spec)
with patch.dict(sys.modules, {'lldb': SimpleNamespace(SBError=Error)}):
    spec.loader.exec_module(helper)


class PublicationTests(unittest.TestCase):
    def setup_probe(self, data, name='host_debugger_publish_code', size=16384, address=0x100000000):
        memory = bytearray(data)
        frame = Mock()
        frame.GetFunctionName.return_value = name
        frame.FindRegister.side_effect = lambda register: SimpleNamespace(GetValueAsUnsigned=lambda: address if register == 'x0' else size)
        process = Mock()
        process.GetSelectedThread.return_value.GetFrameAtIndex.return_value = frame
        process.ReadMemory.side_effect = lambda address, size, error: bytes(memory)

        def write(address, value, error):
            memory[:] = value
            return len(value)

        process.WriteMemory.side_effect = write
        debugger = Mock()
        debugger.GetSelectedTarget.return_value.GetProcess.return_value = process
        return debugger, process, memory

    def test_zero_page_gets_only_host_sample(self):
        debugger, process, memory = self.setup_probe(bytes(16384))
        helper.publish(debugger)
        self.assertEqual(memory[:8], bytes.fromhex('40058052c0035fd6'))
        self.assertFalse(any(memory[8:]))
        process.WriteMemory.assert_called_once()

    def test_existing_samples_unchanged(self):
        for code in ['40058052c0035fd6', '20a78052c0035fd6']:
            data = bytes.fromhex(code) + bytes(16376)
            debugger, process, memory = self.setup_probe(data)
            helper.publish(debugger)
            self.assertEqual(memory, data)

    def test_rejects_other_contents_or_ranges(self):
        for kwargs in [{'data': b'x' * 16384}, {'data': bytes(16384), 'name': 'guest_function'},
                       {'data': bytes(16384), 'size': 32768}, {'data': bytes(16384), 'address': 1}]:
            debugger, process, memory = self.setup_probe(**kwargs)
            with self.assertRaises(RuntimeError):
                helper.publish(debugger)
            process.WriteMemory.assert_not_called()


if __name__ == '__main__':
    unittest.main()
