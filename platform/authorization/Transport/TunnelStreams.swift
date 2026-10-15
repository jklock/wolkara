import Foundation

// Deterministic stream ownership core. The connection manager confines it to
// one serial queue. Every operation uses the same monotonic time source.
final class TunnelStreams {
    enum Failure: Error { case invalidState, capacity, invalidTime, cancelled }
    enum StreamEvent { case connected, readable, writable, peerClosed, closed(Error?) }
    enum Event { case packet(Data), stream(UUID, StreamEvent) }
    private struct Entry { let port: UInt16; let tcp: TunnelTCP }
    private let configuration: CDTunnelConfiguration
    private let random: () -> UInt32
    private var entries: [UUID:Entry] = [:], ports: [UInt16:UUID] = [:]
    private var retired: [UInt16:TimeInterval] = [:]
    private var lastTime: TimeInterval = 0
    private var stopped = false
    var count: Int { entries.count }
    init(configuration: CDTunnelConfiguration, random: @escaping () -> UInt32 = { UInt32.random(in:.min ... .max) }) {
        self.configuration = configuration; self.random = random
    }
    private func advance(_ now: TimeInterval) throws {
        guard !stopped else { throw Failure.invalidState }
        guard now.isFinite, now >= lastTime else { throw Failure.invalidTime }
        lastTime = now; retired = retired.filter { $0.value > now }
    }
    func open(port: UInt16, now: TimeInterval) throws -> (UUID,[Event]) {
        try advance(now)
        guard port > 0 else { throw Failure.invalidState }
        guard entries.count < 8 else { throw Failure.capacity }
        let start = Int(random() % 16384)
        guard let local = (0..<16384).lazy.map({ UInt16(49152 + ((start+$0)%16384)) }).first(where:{ self.ports[$0] == nil && self.retired[$0] == nil }) else { throw Failure.capacity }
        let endpoints = TunnelTCPEndpoints(localAddress:configuration.clientAddress,remoteAddress:configuration.serverAddress,
                                          localPort:local,remotePort:port)
        let tcp = try TunnelTCP(endpoints:endpoints,mtu:configuration.mtu,initialSequence:random())
        let id = UUID(); entries[id] = Entry(port:local,tcp:tcp); ports[local] = id
        return (id,translate(try tcp.connect(now:now),id:id,now:now))
    }
    func receive(_ packet: Data, now: TimeInterval) throws -> [Event] {
        try advance(now)
        guard packet.count >= 60, packet.count <= configuration.mtu else { return [] }
        let header = Array(packet.prefix(44)), port = UInt16(header[42])<<8 | UInt16(header[43])
        guard let id = ports[port], let entry = entries[id] else { return [] }
        // TunnelTCP validates the complete tuple and checksum before use.
        return translate(entry.tcp.receive(packet,now:now),id:id,now:now)
    }
    func write(_ id: UUID, data: Data, now: TimeInterval) throws -> [Event] {
        try advance(now)
        guard let entry = entries[id] else { throw Failure.invalidState }
        return translate(try entry.tcp.write(data,now:now),id:id,now:now)
    }
    func read(_ id: UUID, maximum: Int, now: TimeInterval) throws -> (Data,[Event]) {
        try advance(now)
        guard maximum > 0, maximum <= 32768, let entry = entries[id] else { throw Failure.invalidState }
        let (data,events) = entry.tcp.read(maximum:maximum)
        return (data,translate(events,id:id,now:now))
    }
    func shutdownWrite(_ id: UUID, now: TimeInterval) throws -> [Event] {
        try advance(now)
        guard let entry = entries[id] else { throw Failure.invalidState }
        return translate(try entry.tcp.shutdownWrite(now:now),id:id,now:now)
    }
    func cancel(_ id: UUID, now: TimeInterval) throws -> [Event] {
        try advance(now)
        guard let entry = entries[id] else { return [] }
        return translate(entry.tcp.abort(),id:id,now:now,cancellation:true)
    }
    func tick(now: TimeInterval) throws -> [Event] {
        try advance(now)
        var result: [Event] = []
        for (id,entry) in Array(entries) { result += translate(entry.tcp.tick(now:now),id:id,now:now) }
        return result
    }
    func stop(now: TimeInterval) throws -> [Event] {
        try advance(now)
        var result: [Event] = []
        for id in Array(entries.keys) { result += try cancel(id,now:now) }
        stopped = true; return result
    }
    private func translate(_ events: [TunnelTCP.Event], id: UUID, now: TimeInterval, cancellation: Bool = false) -> [Event] {
        let terminal = events.contains { switch $0 { case .closed,.failed:return true;default:return false } }
        var result: [Event] = []
        for event in events {
            switch event {
            case .packet(let bytes): result.append(.packet(bytes))
            case .connected: if !terminal { result.append(.stream(id,.connected)) }
            case .readable: if !terminal { result.append(.stream(id,.readable)) }
            case .writable: if !terminal { result.append(.stream(id,.writable)) }
            case .peerClosed: if !terminal { result.append(.stream(id,.peerClosed)) }
            case .closed: result.append(.stream(id,.closed(cancellation ? Failure.cancelled : nil)))
            case .failed(let error): result.append(.stream(id,.closed(error)))
            }
        }
        if terminal, let entry = entries.removeValue(forKey:id) {
            ports.removeValue(forKey:entry.port)
            // Keep aborted/failed tuples unavailable too: late segments from
            // the old peer cannot be interpreted by a newly opened connection.
            retired[entry.port] = now + 120
        }
        return result
    }
}
