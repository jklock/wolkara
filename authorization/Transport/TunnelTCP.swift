import Foundation
import Network

// A bounded active-open TCP stream for the reliable CDTunnel link. This is not
// a general-purpose internet TCP stack. No window scaling, SACK, urgent data,
// IP fragmentation or extension headers are negotiated/implemented.
struct TunnelTCPSegment {
    static let fin: UInt8 = 1, syn: UInt8 = 2, rst: UInt8 = 4, psh: UInt8 = 8, ack: UInt8 = 16
    let sequence: UInt32, acknowledgement: UInt32
    let flags: UInt8
    let window: UInt16
    let payload: Data
    let mss: UInt16?
}
struct TunnelTCPEndpoints {
    let localAddress: IPv6Address, remoteAddress: IPv6Address
    let localPort: UInt16, remotePort: UInt16
}
enum TunnelTCPCodec {
    static func checksum(_ bytes: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        for offset in stride(from:0,to:bytes.count,by:2) {
            sum += UInt32(bytes[offset]) << 8
            if offset + 1 < bytes.count { sum += UInt32(bytes[offset + 1]) }
        }
        while sum >> 16 != 0 { sum = (sum & 65535) + (sum >> 16) }
        return ~UInt16(sum)
    }
    private static func pseudo(_ source: Data, _ destination: Data, count: Int) -> [UInt8] {
        Array(source + destination) + [0,0,UInt8(count >> 8),UInt8(count & 255),0,0,0,6]
    }
    static func encode(_ segment: TunnelTCPSegment, endpoints: TunnelTCPEndpoints, incoming: Bool = false) -> Data {
        let source = incoming ? endpoints.remoteAddress.rawValue : endpoints.localAddress.rawValue
        let destination = incoming ? endpoints.localAddress.rawValue : endpoints.remoteAddress.rawValue
        let sourcePort = incoming ? endpoints.remotePort : endpoints.localPort
        let destinationPort = incoming ? endpoints.localPort : endpoints.remotePort
        var tcp: [UInt8] = []
        func add16(_ n: UInt16) { tcp += [UInt8(n >> 8), UInt8(n & 255)] }
        func add32(_ n: UInt32) { tcp += [UInt8(n >> 24),UInt8((n >> 16) & 255),UInt8((n >> 8) & 255),UInt8(n & 255)] }
        add16(sourcePort); add16(destinationPort); add32(segment.sequence); add32(segment.acknowledgement)
        tcp += [segment.mss == nil ? 0x50 : 0x60, segment.flags]; add16(segment.window)
        tcp += [0,0,0,0]
        if let mss = segment.mss { tcp += [2,4,UInt8(mss >> 8),UInt8(mss & 255)] }
        tcp += segment.payload
        precondition(tcp.count <= 65535)
        let check = checksum(pseudo(source,destination,count:tcp.count) + tcp)
        tcp[16] = UInt8(check >> 8); tcp[17] = UInt8(check & 255)
        return Data([0x60,0,0,0,UInt8(tcp.count >> 8),UInt8(tcp.count & 255),6,64]) + source + destination + Data(tcp)
    }
    static func decode(_ packet: Data, endpoints: TunnelTCPEndpoints, mtu: Int) throws -> TunnelTCPSegment {
        guard packet.count >= 60, packet.count <= mtu else { throw PairingError.malformed }
        let b = Array(packet)
        func u16(_ at: Int) -> UInt16 { UInt16(b[at]) << 8 | UInt16(b[at + 1]) }
        func u32(_ at: Int) -> UInt32 { UInt32(u16(at)) << 16 | UInt32(u16(at + 2)) }
        guard b[0] >> 4 == 6, b[6] == 6, b[7] != 0, Int(u16(4)) + 40 == b.count,
              Data(b[8..<24]) == endpoints.remoteAddress.rawValue,
              Data(b[24..<40]) == endpoints.localAddress.rawValue,
              u16(40) == endpoints.remotePort, u16(42) == endpoints.localPort else { throw PairingError.malformed }
        let header = Int(b[52] >> 4) * 4
        guard header >= 20, header <= b.count - 40, b[52] & 15 == 0,
              checksum(pseudo(Data(b[8..<24]),Data(b[24..<40]),count:b.count-40) + b[40...]) == 0 else {
            throw PairingError.malformed
        }
        var at = 60, mss: UInt16?
        while at < 40 + header {
            let kind = b[at]
            if kind == 0 { break }
            if kind == 1 { at += 1; continue }
            guard at + 1 < 40 + header, b[at + 1] >= 2,
                  at + Int(b[at + 1]) <= 40 + header else { throw PairingError.malformed }
            if kind == 2 {
                guard b[at + 1] == 4, mss == nil, u16(at + 2) > 0 else { throw PairingError.malformed }
                mss = u16(at + 2)
            }
            at += Int(b[at + 1])
        }
        return TunnelTCPSegment(sequence:u32(44),acknowledgement:u32(48),flags:b[53],window:u16(54),
                                payload:Data(b[(40+header)...]),mss:mss)
    }
}

final class TunnelTCP {
    enum State { case idle, synSent, established, closeWait, finWait1, finWait2, closing, lastAck, timeWait, closed, failed }
    enum Failure: Error { case invalidState, backpressure, timeout, reset }
    enum Event { case packet(Data), connected, readable, writable, peerClosed, closed, failed(Failure) }
    private struct Pending {
        var sequence: UInt32
        let flags: UInt8
        var payload: Data
        let mss: UInt16?
        var sent: TimeInterval, rto: TimeInterval = 1, retries = 0
    }
    private(set) var state: State = .idle
    private let endpoints: TunnelTCPEndpoints
    private let mtu: Int
    private var una: UInt32, next: UInt32, receiveNext: UInt32 = 0
    private var peerWindow: UInt32 = 0, windowSequence: UInt32 = 0, windowACK: UInt32 = 0
    private var sendMSS = 1220
    private var receiveBuffer = Data(), sendBuffer = Data()
    private var pending: Pending?
    private var closeRequested = false
    private var closeDeadline: TimeInterval?
    private var zeroWindowSince: TimeInterval?, lastProbe: TimeInterval = 0
    private var lastAcknowledgedByte: UInt8 = 0
    private let receiveCapacity = 32768, sendCapacity = 65536

    // Production caller supplies a fresh random ISN and ephemeral port for each
    // connection and must not reuse the tuple during TIME-WAIT. One serial owner.
    init(endpoints: TunnelTCPEndpoints, mtu: Int, initialSequence: UInt32) throws {
        guard mtu >= 1280, mtu <= 16000, endpoints.localPort > 0, endpoints.remotePort > 0,
              endpoints.localAddress != endpoints.remoteAddress else { throw PairingError.malformed }
        self.endpoints = endpoints; self.mtu = mtu; una = initialSequence; next = initialSequence
    }
    private static func before(_ a: UInt32, _ b: UInt32) -> Bool { Int32(bitPattern:a &- b) < 0 }
    private var window: UInt16 { UInt16(receiveCapacity - receiveBuffer.count) }
    private func packet(sequence: UInt32, flags: UInt8, payload: Data = Data(), mss: UInt16? = nil) -> Event {
        .packet(TunnelTCPCodec.encode(TunnelTCPSegment(sequence:sequence,acknowledgement:receiveNext,
            flags:flags,window:window,payload:payload,mss:mss),endpoints:endpoints))
    }
    private func ack() -> Event { packet(sequence:next,flags:TunnelTCPSegment.ack) }
    private func fail(_ reason: Failure) -> [Event] {
        state = .failed; pending = nil; sendBuffer = Data(); receiveBuffer = Data(); return [.failed(reason)]
    }
    func connect(now: TimeInterval) throws -> [Event] {
        guard state == .idle, now.isFinite else { throw Failure.invalidState }
        let mss = UInt16(mtu-60)
        pending = Pending(sequence:next,flags:TunnelTCPSegment.syn,payload:Data(),mss:mss,sent:now)
        next &+= 1; state = .synSent
        return [packet(sequence:una,flags:TunnelTCPSegment.syn,mss:mss)]
    }
    func write(_ data: Data, now: TimeInterval) throws -> [Event] {
        guard (state == .established || state == .closeWait), !closeRequested, now.isFinite else { throw Failure.invalidState }
        guard data.count <= sendCapacity - sendBuffer.count - (pending?.payload.count ?? 0) else { throw Failure.backpressure }
        sendBuffer.append(data)
        return flush(now:now)
    }
    func read(maximum: Int) -> (Data, [Event]) {
        guard maximum > 0, !receiveBuffer.isEmpty else { return (Data(),[]) }
        let count = min(maximum,receiveBuffer.count), output = Data(receiveBuffer.prefix(count))
        receiveBuffer = Data(receiveBuffer.dropFirst(count))
        if state == .failed || state == .closed { return (output,[]) }
        return (output,[ack()])
    }
    func shutdownWrite(now: TimeInterval) throws -> [Event] {
        guard state == .established || state == .closeWait, !closeRequested, now.isFinite else { throw Failure.invalidState }
        closeRequested = true; return flush(now:now)
    }
    private func flush(now: TimeInterval) -> [Event] {
        guard pending == nil, state == .established || state == .closeWait else { return [] }
        if !sendBuffer.isEmpty {
            guard peerWindow > 0 else { if zeroWindowSince == nil { zeroWindowSince = now; lastProbe = now }; return [] }
            zeroWindowSince = nil
            let count = min(sendBuffer.count,sendMSS,Int(peerWindow))
            let data = Data(sendBuffer.prefix(count)); sendBuffer = Data(sendBuffer.dropFirst(count))
            let sequence = next; next &+= UInt32(count)
            pending = Pending(sequence:sequence,flags:TunnelTCPSegment.ack|TunnelTCPSegment.psh,payload:data,mss:nil,sent:now)
            return [packet(sequence:sequence,flags:TunnelTCPSegment.ack|TunnelTCPSegment.psh,payload:data)]
        }
        if closeRequested {
            guard peerWindow > 0 else { if zeroWindowSince == nil { zeroWindowSince = now; lastProbe = now }; return [] }
            let sequence = next; next &+= 1
            pending = Pending(sequence:sequence,flags:TunnelTCPSegment.ack|TunnelTCPSegment.fin,payload:Data(),mss:nil,sent:now)
            state = state == .closeWait ? .lastAck : .finWait1
            return [packet(sequence:sequence,flags:TunnelTCPSegment.ack|TunnelTCPSegment.fin)]
        }
        return []
    }
    func receive(_ bytes: Data, now: TimeInterval) -> [Event] {
        guard now.isFinite, state != .idle, state != .closed, state != .failed,
              let segment = try? TunnelTCPCodec.decode(bytes,endpoints:endpoints,mtu:mtu) else { return [] }
        let syn = segment.flags & TunnelTCPSegment.syn != 0, fin = segment.flags & TunnelTCPSegment.fin != 0
        let rst = segment.flags & TunnelTCPSegment.rst != 0, hasACK = segment.flags & TunnelTCPSegment.ack != 0
        if state == .synSent {
            if rst { return hasACK && segment.acknowledgement == next ? fail(.reset) : [] }
            guard syn, hasACK, !fin, segment.acknowledgement == next, segment.payload.isEmpty else { return [] }
            una = next; receiveNext = segment.sequence &+ 1; pending = nil
            peerWindow = UInt32(segment.window); windowSequence = segment.sequence; windowACK = segment.acknowledgement
            sendMSS = min(Int(segment.mss ?? 1220),mtu-60)
            state = .established
            return [ack(),.connected]
        }
        // Exact-sequence resets only; in-window guesses receive a challenge ACK.
        if rst {
            if segment.sequence == receiveNext { return fail(.reset) }
            let distance = segment.sequence &- receiveNext
            return distance < UInt32(window) ? [ack()] : []
        }
        if state == .timeWait {
            if fin && segment.sequence &+ UInt32(segment.payload.count) &+ 1 == receiveNext {
                closeDeadline = now + 120; return [ack()]
            }
            return []
        }
        if syn { return [ack()] }
        guard hasACK else { return [] }
        let length = segment.payload.count + (fin ? 1 : 0)
        let offset = Int64(Int32(bitPattern:segment.sequence &- receiveNext)), available = Int64(window)
        let acceptable = available == 0 ? length == 0 && offset == 0 :
            (length == 0 ? offset >= 0 && offset < available :
             (offset >= 0 && offset < available) || (offset + Int64(length) - 1 >= 0 && offset + Int64(length) - 1 < available))
        // A fully duplicated payload/FIN gets our current ACK, not redelivery.
        guard acceptable else { return [ack()] }
        guard !Self.before(next,segment.acknowledgement) else { return [ack()] }
        var events: [Event] = []
        if !Self.before(segment.acknowledgement,una) {
            if Self.before(windowSequence,segment.sequence) ||
                (windowSequence == segment.sequence && !Self.before(segment.acknowledgement,windowACK)) {
                peerWindow = UInt32(segment.window); windowSequence = segment.sequence; windowACK = segment.acknowledgement
                if peerWindow > 0 { zeroWindowSince = nil }
            }
            if Self.before(una,segment.acknowledgement) {
                let amount = Int(segment.acknowledgement &- una)
                una = segment.acknowledgement
                if var p = pending {
                    if amount <= p.payload.count && amount > 0 { lastAcknowledgedByte = Array(p.payload)[amount-1] }
                    if una == next { pending = nil }
                    else if amount <= p.payload.count {
                        p.payload = Data(p.payload.dropFirst(amount)); p.sequence = una; p.sent = now; p.rto = 1; p.retries = 0; pending = p
                    }
                }
                events.append(.writable)
                if pending == nil {
                    if state == .finWait1 { state = .finWait2; closeDeadline = now + 30 }
                    else if state == .closing { state = .timeWait; closeDeadline = now + 120 }
                    else if state == .lastAck { state = .closed; return events + [.closed] }
                }
            }
        }
        if offset > 0 { return events + [ack()] + flush(now:now) }
        // Do not accept any new application bytes after the peer's FIN.
        if state == .closeWait || state == .lastAck || state == .closing || state == .timeWait {
            return events + (length > 0 ? [ack()] : []) + flush(now:now)
        }
        let skipped = min(segment.payload.count,Int(max(0,-offset)))
        let dataCount = min(segment.payload.count-skipped,Int(window))
        if dataCount > 0 {
            receiveBuffer.append(segment.payload.dropFirst(skipped).prefix(dataCount)); receiveNext &+= UInt32(dataCount)
            events.append(.readable)
        }
        let finSequence = segment.sequence &+ UInt32(segment.payload.count)
        if fin && finSequence == receiveNext && Int64(length) + offset <= available {
            receiveNext &+= 1; events.append(.peerClosed)
            if state == .established { state = .closeWait }
            else if state == .finWait1 { state = .closing }
            else if state == .finWait2 { state = .timeWait; closeDeadline = now + 120 }
        }
        if length > 0 { events.append(ack()) }
        return events + flush(now:now)
    }
    // Drive with a monotonic clock. Conservative one-segment flight limits
    // control traffic; TLS underneath supplies congestion control for the link.
    func tick(now: TimeInterval) -> [Event] {
        guard now.isFinite, state != .failed, state != .closed else { return [] }
        if let deadline = closeDeadline, now >= deadline {
            if state == .timeWait { state = .closed; return [.closed] }
            return fail(.timeout)
        }
        if var p = pending, now >= p.sent + p.rto {
            guard p.retries < 5 else { return fail(.timeout) }
            p.retries += 1; p.sent = now; p.rto = min(8,p.rto*2); pending = p
            return [packet(sequence:p.sequence,flags:p.flags,payload:p.payload,mss:p.mss)]
        }
        if let since = zeroWindowSince {
            if now >= since + 30 { return fail(.timeout) }
            if now >= lastProbe + 1 {
                lastProbe = now
                return [packet(sequence:next &- 1,flags:TunnelTCPSegment.ack,payload:Data([lastAcknowledgedByte]))]
            }
        }
        return []
    }
    func abort() -> [Event] {
        guard state != .closed && state != .failed else { return [] }
        let reset = packet(sequence:next,flags:TunnelTCPSegment.rst|TunnelTCPSegment.ack)
        state = .closed; pending = nil; sendBuffer = Data(); receiveBuffer = Data()
        return [reset,.closed]
    }
}
