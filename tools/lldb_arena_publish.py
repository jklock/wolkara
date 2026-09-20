"""Initialize a fresh runtime-owned arena before any original guest bytes load."""
import lldb
import struct

def publish(debugger):
    process = debugger.GetSelectedTarget().GetProcess()
    frame = process.GetSelectedThread().GetFrameAtIndex(0)
    if frame.GetFunctionName() != 'host_debugger_publish_arena':
        raise RuntimeError('not at the fresh arena rendezvous')
    address = frame.FindRegister('x0').GetValueAsUnsigned()
    size = frame.FindRegister('x1').GetValueAsUnsigned()
    completion = frame.FindRegister('x2').GetValueAsUnsigned()
    if not size or size > 128 * 1024 * 1024 or size % 16384 or address % 16384:
        raise RuntimeError('invalid arena range')
    error = lldb.SBError()
    token = process.ReadMemory(completion, 8, error)
    if not error.Success() or token != bytes(8):
        raise RuntimeError('invalid completion token')
    # Preflight every byte before writing: never publish an existing guest image.
    chunk_size = 1024 * 1024
    for offset in range(0, size, chunk_size):
        count = min(chunk_size, size-offset)
        data = process.ReadMemory(address+offset, count, error)
        if not error.Success() or len(data) != count or any(data):
            raise RuntimeError('arena is not entirely fresh zeroed memory')
    for offset in range(0, size, chunk_size):
        count = min(chunk_size, size-offset)
        if process.WriteMemory(address+offset, bytes(count), error) != count or not error.Success():
            raise RuntimeError('arena initialization failed')
    if process.WriteMemory(completion, struct.pack('<Q', 0x49504144434f4445), error) != 8 or not error.Success():
        raise RuntimeError('completion write failed')
    print('ARENA_OK: initialized %d zeroed runtime bytes before guest load' % size)
