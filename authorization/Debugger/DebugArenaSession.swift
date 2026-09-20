import Foundation

// Narrow all-stop debugserver transaction. No launch, registers, breakpoints,
// arbitrary memory writes or guest-byte publication. Only zeros in validated
// fresh host arenas. The owner closes the channel on any terminal result.
final class DebugArenaSession {
    enum Phase { case idle, supported, detachPolicy, attach, process, challenge, region, preflight, write, verify, finalProcess, finalChallenge, detach, cleanup, complete, failed }
    enum Reason: Error { case protocolFailure, wrongProcess, wrongChallenge, unsafeRegion, nonzeroMemory, serverFailure, timedOut, cancelled, disconnected }
    struct Failure: Error { let reason: Reason; let detachConfirmed: Bool }
    struct Receipt { let pid: UInt32; let challenge: Data; let regions: [DebugArenaRequest.Region] }
    enum Event { case send(Data), finished(Result<Receipt,Failure>) }
    private(set) var phase: Phase = .idle
    private let request: DebugArenaRequest, wire = DebugProtocolWire()
    private var waiting = false, acknowledged = false, retries = 0, badPackets = 0, consolePackets = 0
    private var lastPacket = Data(), commandDeadline: TimeInterval = 0, totalDeadline: TimeInterval = 0, lastTime: TimeInterval = 0
    private var packetSize = 1024, chunk = 480, index = 0
    private var offset: UInt64 = 0, readCount = 0, regionCursor: UInt64 = 0
    private var attached = false, pendingFailure: Reason?
    var diagnosticProgress: String { "phase=\(phase), region=\(index), offset=\(offset)" }
    init(request: DebugArenaRequest) { self.request = request }
    private var terminal: Bool { phase == .complete || phase == .failed }
    private func time(_ now: TimeInterval) throws {
        guard now.isFinite, now >= lastTime else { throw Reason.protocolFailure }; lastTime = now
    }
    func begin(now: TimeInterval) throws -> [Event] {
        guard phase == .idle else { throw Reason.protocolFailure }
        try time(now); totalDeadline = now + 900
        return try command("qSupported",phase:.supported,now:now)
    }
    private func command(_ text: String, phase: Phase, now: TimeInterval) throws -> [Event] {
        guard !waiting, text.utf8.count <= packetSize else { throw Reason.protocolFailure }
        lastPacket = try DebugProtocolWire.encode(text); waiting = true; acknowledged = false; retries = 0; badPackets = 0
        self.phase = phase; commandDeadline = now + 10
        return [.send(lastPacket)]
    }
    func receive(_ bytes: Data, now: TimeInterval) -> [Event] {
        guard !terminal, phase != .idle else { return [] }
        var events: [Event] = [], consumedReply = false
        do {
            try time(now)
            if now >= commandDeadline || now >= totalDeadline { return finish(.timedOut,detached:false) }
            guard bytes.count <= 65536 else { throw Reason.protocolFailure }
            for byte in bytes {
                // The next command is emitted only when this call returns. A
                // second coalesced response cannot answer an unsent command.
                guard !consumedReply else { throw Reason.protocolFailure }
                guard let event = try wire.feed(byte) else { continue }
                switch event {
                case .ack:
                    guard waiting, !acknowledged else { throw Reason.protocolFailure }; acknowledged = true
                case .nack:
                    guard waiting, !acknowledged, retries < 2 else { throw Reason.protocolFailure }
                    retries += 1; events.append(.send(lastPacket))
                case .badChecksum:
                    guard waiting, badPackets < 2 else { throw Reason.protocolFailure }
                    badPackets += 1; events.append(.send(Data([45])))
                case .packet(let payload):
                    guard waiting, let text = String(data:payload,encoding:.ascii) else { throw Reason.protocolFailure }
                    events.append(.send(Data([43])))
                    if text.hasPrefix("O"), text != "OK" {
                        consolePackets += 1
                        guard consolePackets <= 64, text.utf8.count % 2 == 1 else { throw Reason.protocolFailure }
                        _ = try DebugProtocolWire.unhex(String(text.dropFirst()),count:(text.utf8.count-1)/2)
                        continue // Deliberately do not expose/log process output.
                    }
                    guard acknowledged else { throw Reason.protocolFailure }
                    waiting = false; consumedReply = true
                    do { events += try reply(text,now:now) }
                    catch {
                        let reason = error as? Reason ?? .protocolFailure
                        if attached, phase != .detach, phase != .cleanup {
                            pendingFailure = reason
                            events += try command("D",phase:.cleanup,now:now)
                        } else { events += finish(reason,detached:false) }
                    }
                }
            }
            return events
        } catch { return finish(.protocolFailure,detached:false) }
    }
    private func reply(_ text: String, now: TimeInterval) throws -> [Event] {
        if text.hasPrefix("E") { throw Reason.serverFailure }
        switch phase {
        case .supported:
            var seen = false
            for feature in text.split(separator:";") where feature.hasPrefix("PacketSize=") {
                guard !seen else { throw Reason.protocolFailure }; seen = true
                let maximum = try DebugProtocolWire.number(String(feature.dropFirst(11)))
                guard maximum >= 256 else { throw Reason.protocolFailure }
                packetSize = Int(min(maximum,UInt64(DebugProtocolWire.capacity)))
            }
            chunk = (packetSize-64)/2
            return try command("QSetDetachOnError:1",phase:.detachPolicy,now:now)
        case .detachPolicy:
            guard text == "OK" else { throw Reason.serverFailure }
            return try command("vAttach;"+String(request.pid,radix:16),phase:.attach,now:now)
        case .attach:
            // Darwin may stop with SIGSTOP or SIGTRAP. Any valid all-stop
            // reply is followed by exact process and challenge verification.
            guard (text.hasPrefix("T") && text.count >= 3) || (text.hasPrefix("S") && text.count == 3) else { throw Reason.protocolFailure }
            _ = try DebugProtocolWire.number(String(text.dropFirst().prefix(2)))
            attached = true
            return try command("qProcessInfo",phase:.process,now:now)
        case .process, .finalProcess:
            let final = phase == .finalProcess, info = try DebugProtocolWire.fields(text)
            guard try DebugProtocolWire.number(info["pid"]) == UInt64(request.pid),
                  try DebugProtocolWire.number(info["effective-uid"]) == UInt64(request.uid),
                  try DebugProtocolWire.number(info["cputype"]) == 0x100000c,
                  try DebugProtocolWire.number(info["ptrsize"]) == 8, info["endian"] == "little" else { throw Reason.wrongProcess }
            return try read(request.challengeAddress,count:32,phase:final ? .finalChallenge : .challenge,now:now)
        case .challenge, .finalChallenge:
            let final = phase == .finalChallenge
            guard try DebugProtocolWire.unhex(text,count:32) == request.challenge else { throw Reason.wrongChallenge }
            if final { return try command("D",phase:.detach,now:now) }
            index = 0; regionCursor = request.regions[0].address
            return try command("qMemoryRegionInfo:"+String(regionCursor,radix:16),phase:.region,now:now)
        case .region:
            let info = try DebugProtocolWire.fields(text), range = request.regions[index]
            let base = try DebugProtocolWire.number(info["start"]), size = try DebugProtocolWire.number(info["size"])
            guard size > 0, base <= regionCursor, size <= UInt64.max-base, base+size > regionCursor,
                  info["error"] == nil, Set(info["permissions"] ?? "") == Set("rx"),
                  (info["name"] ?? "").isEmpty else { throw Reason.unsafeRegion }
            regionCursor = min(base+size,range.address+range.size)
            if regionCursor < range.address+range.size { return try command("qMemoryRegionInfo:"+String(regionCursor,radix:16),phase:.region,now:now) }
            offset = 0; return try readChunk(phase:.preflight,now:now)
        case .preflight:
            guard try DebugProtocolWire.unhex(text,count:readCount).allSatisfy({ $0 == 0 }) else { throw Reason.nonzeroMemory }
            offset += UInt64(readCount)
            if offset < request.regions[index].size { return try readChunk(phase:.preflight,now:now) }
            index += 1
            if index < request.regions.count {
                regionCursor = request.regions[index].address
                return try command("qMemoryRegionInfo:"+String(regionCursor,radix:16),phase:.region,now:now)
            }
            // All arenas passed the full preflight before the first write.
            index = 0; offset = 0; return try writeChunk(now:now)
        case .write:
            guard text == "OK" else { throw Reason.serverFailure }
            return try readChunk(phase:.verify,now:now)
        case .verify:
            guard try DebugProtocolWire.unhex(text,count:readCount).allSatisfy({ $0 == 0 }) else { throw Reason.nonzeroMemory }
            offset += UInt64(readCount)
            if offset == request.regions[index].size { index += 1; offset = 0 }
            if index < request.regions.count { return try writeChunk(now:now) }
            return try command("qProcessInfo",phase:.finalProcess,now:now)
        case .detach, .cleanup:
            guard text == "OK" else { throw Reason.serverFailure }
            attached = false
            if let pendingFailure { return finish(pendingFailure,detached:true) }
            phase = .complete; waiting = false; lastPacket = Data()
            return [.finished(.success(Receipt(pid:request.pid,challenge:request.challenge,regions:request.regions)))]
        default:throw Reason.protocolFailure
        }
    }
    private func read(_ address: UInt64, count: Int, phase: Phase, now: TimeInterval) throws -> [Event] {
        readCount = count
        return try command("m"+String(address,radix:16)+","+String(count,radix:16),phase:phase,now:now)
    }
    private func readChunk(phase: Phase, now: TimeInterval) throws -> [Event] {
        let range = request.regions[index], count = Int(min(UInt64(chunk),range.size-offset))
        return try read(range.address+offset,count:count,phase:phase,now:now)
    }
    private func writeChunk(now: TimeInterval) throws -> [Event] {
        let range = request.regions[index], count = Int(min(UInt64(chunk),range.size-offset))
        return try command("M"+String(range.address+offset,radix:16)+","+String(count,radix:16)+":"+String(repeating:"00",count:count),phase:.write,now:now)
    }
    func tick(now: TimeInterval) -> [Event] {
        guard !terminal, phase != .idle else { return [] }
        guard now.isFinite, now >= lastTime, now < commandDeadline, now < totalDeadline else { return finish(.timedOut,detached:false) }
        lastTime = now; return []
    }
    func cancel() -> [Event] { terminal ? [] : finish(.cancelled,detached:false) }
    func disconnected() -> [Event] { terminal ? [] : finish(.disconnected,detached:false) }
    private func finish(_ reason: Reason, detached: Bool) -> [Event] {
        phase = .failed; waiting = false; lastPacket = Data()
        return [.finished(.failure(Failure(reason:reason,detachConfirmed:detached)))]
    }
}
