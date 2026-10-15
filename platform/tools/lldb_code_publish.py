"""Opt-in LLDB helper restricted to the two host-generated probe samples.

Debugserver initializes a zeroed runtime-owned RX page with our sample, or writes
back identical bytes of an existing sample. No file or imported-application mapping is accessed.
Do not use this as a general
guest memory writer. This is a capability test, not the production code cache.
"""
import lldb


def publish(debugger):
    process = debugger.GetSelectedTarget().GetProcess()
    thread = process.GetSelectedThread()
    frame = thread.GetFrameAtIndex(0)
    if frame.GetFunctionName() != 'host_debugger_publish_code':
        raise RuntimeError('not stopped at the host code publication rendezvous')
    address = frame.FindRegister('x0').GetValueAsUnsigned()
    size = frame.FindRegister('x1').GetValueAsUnsigned()
    if size != 16384 or address % size:
        raise RuntimeError('expected one aligned 16 KB host sample page')
    error = lldb.SBError()
    data = process.ReadMemory(address, size, error)
    if not error.Success() or len(data) != size:
        raise RuntimeError('cannot read complete host sample page: ' + str(error))
    allowed = [bytes.fromhex('40058052c0035fd6'), bytes.fromhex('20a78052c0035fd6')]
    initializing = not any(data)
    if initializing:
        # A fresh RX mapping has no program bytes: initialize our own known sample.
        data = allowed[0] + data[8:]
    elif data[:8] not in allowed or any(data[8:]):
        raise RuntimeError('page is not an expected host-generated sample')
    written = process.WriteMemory(address, data, error)
    if not error.Success() or written != size:
        raise RuntimeError('cannot publish complete host sample page: ' + str(error))
    verified = process.ReadMemory(address, size, error)
    if not error.Success() or verified != data:
        raise RuntimeError('page bytes changed during publication')
    print('PUBLISH_OK: ' + ('initialized zeroed host sample page' if initializing else '16384 byte-identical host sample bytes'))
