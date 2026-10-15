import Foundation
import Network
private func check(_ value: Bool, _ text: String) { if !value { fatalError(text) } }
private func reject(_ work: () throws -> Void) { do { try work(); fatalError("accepted invalid operation") } catch {} }
private func configuration() throws -> CDTunnelConfiguration {
    try CDTunnelConfiguration(response:JSONSerialization.data(withJSONObject:["clientParameters":["address":"fd00::1","netmask":"ffff:ffff:ffff:ffff::","mtu":16000],"serverAddress":"fd00::2","serverRSDPort":58783]),requestedMTU:16000)
}
private func packetEvents(_ events: [TunnelStreams.Event]) -> [Data] { events.compactMap { if case .packet(let b) = $0 { return b }; return nil } }
private func localPort(_ packet: Data) -> UInt16 { UInt16(packet[40])<<8 | UInt16(packet[41]) }
private func sequence(_ packet: Data) -> UInt32 { packet[44..<48].reduce(0) { $0<<8 | UInt32($1) } }
private func peer(_ local: UInt16, remote: UInt16 = 58783, seq: UInt32 = 200, ack: UInt32 = 101, flags: UInt8 = 18, payload: Data = Data()) -> Data {
    let e = TunnelTCPEndpoints(localAddress:IPv6Address("fd00::1")!,remoteAddress:IPv6Address("fd00::2")!,localPort:local,remotePort:remote)
    return TunnelTCPCodec.encode(TunnelTCPSegment(sequence:seq,acknowledgement:ack,flags:flags,window:32768,payload:payload,mss:nil),endpoints:e,incoming:true)
}
private func has(_ events: [TunnelStreams.Event], _ id: UUID, _ expected: String) -> Bool {
    events.contains { if case .stream(let key,let event) = $0, key == id { return String(describing:event).hasPrefix(expected) }; return false }
}
@main struct StreamTests {
    static func main() throws {
        let config = try configuration()
        let pool = TunnelStreams(configuration:config,random:{100})
        let (a,first) = try pool.open(port:58783,now:0)
        let (b,second) = try pool.open(port:12345,now:0)
        let pa = localPort(packetEvents(first)[0]), pb = localPort(packetEvents(second)[0])
        check(pa != pb && pa >= 49152 && pb >= 49152, "distinct ephemeral ports despite random collisions")
        check(sequence(packetEvents(first)[0]) == 100, "fresh supplied ISN")
        check(try pool.receive(peer(pa,remote:12345),now:0.1).isEmpty, "wrong source port ignored")
        check(try has(pool.receive(peer(pa),now:0.2),a,"connected"), "first connected")
        check(try has(pool.receive(peer(pb,remote:12345),now:0.2),b,"connected"), "second connected")
        let aWrite = try pool.write(a,data:Data("abc".utf8),now:1)
        check(packetEvents(aWrite).count == 1, "send admitted")
        reject { _ = try pool.write(a,data:Data(repeating:1,count:65536),now:1) }
        check(packetEvents(try pool.write(b,data:Data("xyz".utf8),now:1)).count == 1, "backpressure is per stream")
        let data = try pool.receive(peer(pb,remote:12345,seq:201,ack:104,flags:24,payload:Data("second".utf8)),now:1.1)
        check(has(data,b,"readable") && !has(data,a,"readable"), "tuple demultiplexing")
        check(try pool.read(a,maximum:100,now:1.1).0.isEmpty, "other stream untouched")
        check(try pool.read(b,maximum:100,now:1.1).0 == Data("second".utf8), "correct stream received")
        let retries = packetEvents(try pool.tick(now:2))
        check(retries.count == 1 && localPort(retries[0]) == pa, "only unacknowledged stream retransmits")
        let cancelled = try pool.cancel(a,now:2)
        check(has(cancelled,a,"closed") && pool.count == 1, "cancel stream retires it")
        check(try pool.cancel(a,now:2).isEmpty, "cancel once")
        let (c,third) = try pool.open(port:58783,now:2)
        check(localPort(packetEvents(third)[0]) != pa, "quarantine after abort")
        check(try pool.receive(peer(pa),now:2.1).isEmpty, "late old packet cannot reach new stream")
        reject { _ = try pool.write(a,data:Data(),now:2.1) }
        reject { _ = try pool.read(b,maximum:32769,now:2.1) }
        reject { _ = try pool.tick(now:2) }
        reject { _ = try pool.tick(now:.nan) }
        let ending = try pool.stop(now:2.2)
        check(has(ending,b,"closed") && has(ending,c,"closed") && pool.count == 0, "stop terminates all streams")
        reject { _ = try pool.open(port:80,now:3) }
        do {
            let pool = TunnelStreams(configuration:config,random:{100})
            let (id,first) = try pool.open(port:58783,now:0)
            let initial = packetEvents(first)[0]
            for t in [1.0,3,7,15,23] { check(packetEvents(try pool.tick(now:t)) == [initial], "backoff retransmission") }
            check(try has(pool.tick(now:31),id,"closed") && pool.count == 0, "connect timeout delivered")
            let (_,again) = try pool.open(port:58783,now:32)
            check(localPort(packetEvents(again)[0]) != localPort(initial), "timeout quarantines tuple")
        }
        do {
            let pool = TunnelStreams(configuration:config,random:{100})
            var opened: [UUID] = []
            for i in 0..<8 { opened.append(try pool.open(port:UInt16(30000+i),now:0).0) }
            reject { _ = try pool.open(port:40000,now:0) }
            let close = try pool.stop(now:0)
            check(opened.allSatisfy({ has(close,$0,"closed") }), "bounded slots terminate once")
        }
        do {
            let pool = TunnelStreams(configuration:config,random:{100})
            let (id,first) = try pool.open(port:58783,now:0)
            let port = localPort(packetEvents(first)[0]); _ = try pool.cancel(id,now:0)
            let (_,again) = try pool.open(port:58783,now:120)
            check(localPort(packetEvents(again)[0]) == port, "retired port eligible after quarantine")
        }
        print("TunnelStreams: multiplexing, randomized tuple allocation, admission, retirement, timeouts and cleanup passed")
    }
}
