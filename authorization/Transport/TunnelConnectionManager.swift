import Foundation
import Network

// Implementations must deliver all callbacks on the manager's serial queue.
protocol TunnelPacketConnection: AnyObject {
    func start(onReady: @escaping (CDTunnelConfiguration) -> Void,
               onPacket: @escaping (Data) -> Void, onClose: @escaping (Error) -> Void)
    func send(_ packet: Data, completion: @escaping (Error?) -> Void)
    func cancel()
}
extension CDTunnelConnection: TunnelPacketConnection {}

// Internal helper-process API. Methods and application callbacks run ONLY on
// queue. This is deliberate: no unbounded async closure queue retains app writes
// or incoming packets. Each TCP stream bounds its own send/receive admission.
// The Network.framework link shares this queue and drives one bounded read.
final class TunnelConnectionManager {
    enum Failure: Error { case invalidState, cancelled, transport, backpressure }
    typealias Handler = (UUID,TunnelStreams.StreamEvent) -> Void
    let queue: DispatchQueue
    private let link: TunnelPacketConnection
    private var control: PairingConnection?
    private var streams: TunnelStreams?
    private var handlers: [UUID:Handler] = [:]
    private var timer: DispatchSourceTimer?
    private var outgoing: [Data] = []
    private var outgoingBytes = 0, writing = false
    private var started = false, stopped = false
    private var ready: ((CDTunnelConfiguration) -> Void)?
    private var closed: ((Error) -> Void)?
    private let clock: () -> TimeInterval

    init(link: TunnelPacketConnection, queue: DispatchQueue, control: PairingConnection? = nil,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.link = link; self.queue = queue; self.control = control; self.clock = clock
    }
    convenience init(host: NWEndpoint.Host, offer: PairingSession.TunnelOffer, control: PairingConnection) throws {
        let queue = DispatchQueue(label:"local.tolkara.tunnel-streams")
        guard let port = NWEndpoint.Port(rawValue:offer.port) else { throw Failure.invalidState }
        let key = offer.sessionKey.withUnsafeBytes { Data($0) }
        let link = try CDTunnelConnection(host:host,port:port,sessionKey:key,queue:queue)
        self.init(link:link,queue:queue,control:control)
    }
    private func confined() { dispatchPrecondition(condition:.onQueue(queue)) }
    func start(onReady: @escaping (CDTunnelConfiguration) -> Void, onClosed: @escaping (Error) -> Void) {
        confined()
        guard !started, !stopped else { onClosed(Failure.invalidState); return }
        started = true; ready = onReady; closed = onClosed
        link.start(onReady:{ [weak self] configuration in
            guard let self else { return }; self.confined()
            guard !self.stopped, self.streams == nil else { return }
            self.streams = TunnelStreams(configuration:configuration)
            let timer = DispatchSource.makeTimerSource(queue:self.queue)
            timer.schedule(deadline:.now()+0.1,repeating:0.1,leeway:.milliseconds(10))
            timer.setEventHandler { [weak self] in
                guard let self, !self.stopped, let streams = self.streams else { return }
                do { self.process(try streams.tick(now:self.clock())) }
                catch { self.stop(Failure.transport) }
            }
            self.timer = timer; timer.resume()
            let callback = self.ready; self.ready = nil; callback?(configuration)
        },onPacket:{ [weak self] packet in
            guard let self else { return }; self.confined()
            guard !self.stopped, let streams = self.streams else { return }
            do { self.process(try streams.receive(packet,now:self.clock())) }
            catch { self.stop(Failure.transport) }
        },onClose:{ [weak self] error in
            guard let self else { return }; self.confined(); self.stop(error)
        })
    }
    func open(port: UInt16, handler: @escaping Handler) throws -> UUID {
        confined(); guard !stopped, let streams else { throw Failure.invalidState }
        let (id,events) = try streams.open(port:port,now:clock())
        handlers[id] = handler; process(events); return id
    }
    func write(_ id: UUID, data: Data) throws {
        confined(); guard !stopped, let streams else { throw Failure.invalidState }
        process(try streams.write(id,data:data,now:clock()))
    }
    func read(_ id: UUID, maximum: Int = 16384) throws -> Data {
        confined(); guard !stopped, let streams else { throw Failure.invalidState }
        let (data,events) = try streams.read(id,maximum:maximum,now:clock()); process(events); return data
    }
    func shutdownWrite(_ id: UUID) throws {
        confined(); guard !stopped, let streams else { throw Failure.invalidState }
        process(try streams.shutdownWrite(id,now:clock()))
    }
    func cancelStream(_ id: UUID) {
        confined(); guard !stopped, let streams else { return }
        do { process(try streams.cancel(id,now:clock())) } catch { stop(Failure.transport) }
    }
    func cancel() { confined(); stop(Failure.cancelled) }
    private func process(_ events: [TunnelStreams.Event]) {
        // Deliver protocol ACKs and queued sends before application callbacks
        // can write more bytes. Skip stale callbacks after reentrant cancellation.
        for event in events {
            guard !stopped else { return }
            if case .packet(let bytes) = event {
                guard outgoingBytes + bytes.count <= 256 * 1024,
                      outgoing.count + (writing ? 1 : 0) < 256 else { stop(Failure.backpressure); return }
                outgoing.append(bytes); outgoingBytes += bytes.count; drain()
            }
        }
        for event in events {
            guard !stopped else { return }
            if case .stream(let id,let event) = event {
                let callback = handlers[id]
                if case .closed = event { handlers.removeValue(forKey:id) }
                callback?(id,event)
            }
        }
    }
    private func drain() {
        guard !stopped, !writing, !outgoing.isEmpty else { return }
        let packet = outgoing.removeFirst(), count = packet.count
        writing = true
        link.send(packet) { [weak self] error in
            guard let self else { return }; self.confined()
            guard !self.stopped else { return }
            self.writing = false; self.outgoingBytes -= count
            if error != nil { self.stop(Failure.transport) } else { self.drain() }
        }
    }
    private func stop(_ error: Error) {
        confined(); guard !stopped else { return }
        stopped = true; timer?.cancel(); timer = nil; ready = nil
        outgoing.removeAll(); outgoingBytes = 0; writing = false
        // No callback may open a new stream during teardown. Discard transport
        // resets here: the entire encrypted link is being cancelled anyway.
        _ = try? streams?.stop(now:clock()); streams = nil
        let pending = handlers; handlers.removeAll()
        link.cancel(); control?.cancel(); control = nil
        let callback = closed; closed = nil
        for (id,handler) in pending { handler(id,.closed(error)) }
        callback?(error)
    }
    deinit { timer?.cancel(); link.cancel(); control?.cancel() }
}
