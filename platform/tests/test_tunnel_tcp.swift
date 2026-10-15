import Foundation
import Network

private func check(_ value: Bool, _ message: String) { if !value { fatalError(message) } }
private func reject(_ message: String, _ work: () throws -> Void) {
    do { try work(); fatalError("Accepted: \(message)") } catch {}
}
private let endpoints = TunnelTCPEndpoints(localAddress:IPv6Address("fd00::1")!,remoteAddress:IPv6Address("fd00::2")!,localPort:49160,remotePort:58783)
private let reverse = TunnelTCPEndpoints(localAddress:endpoints.remoteAddress,remoteAddress:endpoints.localAddress,localPort:endpoints.remotePort,remotePort:endpoints.localPort)
private func incoming(_ seq: UInt32, _ ack: UInt32, flags: UInt8 = 16, window: UInt16 = 32768,
                      data: Data = Data(), mss: UInt16? = nil) -> Data {
    TunnelTCPCodec.encode(TunnelTCPSegment(sequence:seq,acknowledgement:ack,flags:flags,window:window,payload:data,mss:mss),endpoints:endpoints,incoming:true)
}
private func packets(_ events: [TunnelTCP.Event]) throws -> [TunnelTCPSegment] {
    try events.compactMap { event in
        if case .packet(let bytes) = event { return try TunnelTCPCodec.decode(bytes,endpoints:reverse,mtu:16000) }
        return nil
    }
}
private func hasData(_ events: [TunnelTCP.Event]) -> Bool { events.contains { if case .readable = $0 { return true };return false } }
private func connected(isn: UInt32 = 100, peer: UInt32 = 1000, window: UInt16 = 32768, mss: UInt16 = 1220) throws -> TunnelTCP {
    let stream = try TunnelTCP(endpoints:endpoints,mtu:16000,initialSequence:isn)
    let syn = try packets(stream.connect(now:0))
    check(syn.count == 1 && syn[0].flags == 2 && syn[0].sequence == isn && syn[0].mss == 15940, "SYN")
    let result = stream.receive(incoming(peer,isn &+ 1,flags:18,window:window,mss:mss),now:0.01)
    check(stream.state == .established && result.contains { if case .connected = $0 { return true };return false }, "connect")
    let ack = try packets(result)
    check(ack.count == 1 && ack[0].acknowledgement == peer &+ 1 && ack[0].sequence == isn &+ 1, "SYN acknowledgement")
    return stream
}

@main struct TCPTests {
    static func main() throws {
        // Independently generated Python struct/checksum fixture (odd payload).
        let hex = "6000000000170640fd000000000000000000000000000002fd000000000000000000000000000001e59fc008000003e90000006550188000c76b0000616263"
        let chars = Array(hex); var fixture = Data()
        for i in stride(from:0,to:chars.count,by:2) { fixture.append(UInt8(String(chars[i...i+1]),radix:16)!) }
        let decoded = try TunnelTCPCodec.decode(fixture,endpoints:endpoints,mtu:16000)
        check(decoded.payload == Data("abc".utf8) && decoded.sequence == 1001 && decoded.acknowledgement == 101, "independent checksum vector")
        for i in fixture.indices {
            var bad = fixture; bad[i] ^= (i == 0 ? 0x10 : 1)
            // Flow label/hop-limit changes do not affect the TCP pseudo-header.
            if i == 0 || (i >= 4 && i <= 6) || i >= 8 {
                reject("corrupt TCP packet") { _ = try TunnelTCPCodec.decode(bad,endpoints:endpoints,mtu:16000) }
            }
        }
        for end in 0..<60 { reject("short TCP packet") { _ = try TunnelTCPCodec.decode(fixture.prefix(end),endpoints:endpoints,mtu:16000) } }
        do {
            let tcp = try connected(mss:4)
            var sent = try packets(tcp.write(Data("abcdefghij".utf8),now:1))
            check(sent.count == 1 && sent[0].payload == Data("abcd".utf8), "MSS segmentation")
            check(tcp.tick(now:1.9).isEmpty, "early retransmit")
            sent = try packets(tcp.tick(now:2))
            check(sent[0].sequence == 101 && sent[0].payload == Data("abcd".utf8), "retransmit")
            _ = tcp.receive(incoming(1001,103),now:2.1)
            sent = try packets(tcp.tick(now:3.2))
            check(sent[0].sequence == 103 && sent[0].payload == Data("cd".utf8), "partial ACK trims retransmit")
            sent = try packets(tcp.receive(incoming(1001,105),now:3.3))
            check(sent.last?.payload == Data("efgh".utf8) && sent.last?.sequence == 105, "ACK advances queued data")
            sent = try packets(tcp.receive(incoming(1001,109),now:3.4))
            check(sent.last?.payload == Data("ij".utf8), "final segment")
            _ = tcp.receive(incoming(1001,111),now:3.5)
            check(tcp.tick(now:30).isEmpty, "no retransmit after ACK")
        }
        do {
            let tcp = try connected()
            let early = tcp.receive(incoming(1004,101,data:Data("def".utf8)),now:1)
            check(try !hasData(early) && (packets(early).last?.acknowledgement) == 1001, "out-of-order ACK without delivery")
            check(hasData(tcp.receive(incoming(1001,101,data:Data("abc".utf8)),now:2)), "in-order receive")
            check(!hasData(tcp.receive(incoming(1001,101,data:Data("abc".utf8)),now:3)), "duplicate not delivered")
            check(hasData(tcp.receive(incoming(1002,101,data:Data("bcdef".utf8)),now:4)), "overlap tail received")
            let (read, _) = tcp.read(maximum:100)
            check(read == Data("abcdef".utf8), "ordered exactly-once stream")
            check(tcp.read(maximum:1).0.isEmpty, "drained receive buffer")
        }
        do {
            let tcp = try connected(window:0)
            check(try tcp.write(Data("abc".utf8),now:1).isEmpty, "zero window stops data")
            let probes = try packets(tcp.tick(now:2))
            check(probes.count == 1 && probes[0].sequence == 100 && probes[0].payload.count == 1, "persist probe")
            let sent = try packets(tcp.receive(incoming(1001,101,window:2),now:3))
            check(sent.last?.payload == Data("ab".utf8), "window reopening")
            let tail = try packets(tcp.receive(incoming(1001,103,window:1),now:4))
            check(tail.last?.payload == Data("c".utf8), "peer window limits send")
        }
        do {
            let tcp = try connected(window:0)
            _ = try tcp.write(Data([1]),now:1)
            _ = tcp.tick(now:31)
            check(tcp.state == .failed, "zero-window deadline")
        }
        do {
            let tcp = try connected()
            var seq: UInt32 = 1001
            for size in [12000,12000,8768] {
                let events = tcp.receive(incoming(seq,101,data:Data(repeating:7,count:size)),now:1)
                check(hasData(events), "receive-window filling"); seq &+= UInt32(size)
            }
            check(!hasData(tcp.receive(incoming(seq,101,data:Data([8])),now:2)), "full receive buffer")
            let (read, acks) = tcp.read(maximum:100)
            check(try read.count == 100 && (packets(acks).last?.window) == 100, "read reopens receive window")
            check(hasData(tcp.receive(incoming(seq,101,data:Data([8])),now:3)), "receive after read")
        }
        do {
            let tcp = try connected(isn:UInt32.max-2,peer:UInt32.max-2,mss:4)
            let sent = try packets(tcp.write(Data("abcd".utf8),now:1))
            check(sent[0].sequence == UInt32.max-1, "wrap send")
            _ = tcp.receive(incoming(UInt32.max-1,2,data:Data("abcd".utf8)),now:2)
            let (read, ack) = tcp.read(maximum:4)
            check(try read == Data("abcd".utf8) && (packets(ack).last?.acknowledgement) == 2, "sequence wrap")
            check(tcp.tick(now:30).isEmpty, "wrapped ACK retired data")
        }
        do {
            let tcp = try connected()
            _ = try tcp.write(Data(repeating:1,count:65536),now:1)
            reject("bounded send queue") { _ = try tcp.write(Data([2]),now:1) }
            let invalidACK = tcp.receive(incoming(1001,500000),now:1.1)
            check(try packets(invalidACK).count == 1, "future ACK challenged")
            let retry = try packets(tcp.tick(now:2))
            check(retry[0].sequence == 101, "future ACK did not discard pending data")
        }
        do {
            let tcp = try connected()
            let challenge = tcp.receive(incoming(1002,101,flags:4),now:1)
            check(try tcp.state == .established && (packets(challenge).count) == 1, "in-window reset challenged")
            _ = tcp.receive(incoming(1001,101,flags:4),now:2)
            check(tcp.state == .failed, "exact reset closes")
        }
        do {
            let tcp = try connected()
            _ = try tcp.shutdownWrite(now:1)
            check(tcp.state == .finWait1, "active FIN")
            _ = tcp.receive(incoming(1001,102),now:2)
            check(tcp.state == .finWait2, "FIN acknowledged")
            let closed = tcp.receive(incoming(1001,102,flags:17),now:3)
            check(tcp.state == .timeWait && closed.contains { if case .peerClosed = $0 { return true };return false }, "peer FIN")
            _ = tcp.receive(incoming(1001,102,flags:17),now:4)
            check(tcp.tick(now:123).isEmpty, "duplicate FIN restarts TIME-WAIT")
            _ = tcp.tick(now:124); check(tcp.state == .closed, "TIME-WAIT completes")
        }
        do {
            let tcp = try connected()
            let events = tcp.receive(incoming(1001,101,flags:17,data:Data("bye".utf8)),now:1)
            check(tcp.state == .closeWait && hasData(events), "passive FIN with data")
            check(tcp.read(maximum:3).0 == Data("bye".utf8), "read final bytes")
            _ = try tcp.shutdownWrite(now:2); check(tcp.state == .lastAck, "last ACK state")
            _ = tcp.receive(incoming(1005,102),now:3); check(tcp.state == .closed, "passive close")
        }
        do {
            let tcp = try TunnelTCP(endpoints:endpoints,mtu:1280,initialSequence:42)
            _ = try tcp.connect(now:0)
            for now: Double in [1,3,7,15,23,31] { _ = tcp.tick(now:now) }
            check(tcp.state == .failed, "SYN bounded retransmission")
        }
        print("PASS: tunnel TCP checksums, handshake, MSS/window/queue limits, loss/retransmission, partial ACK, ordering, wrap, resets and close")
    }
}
