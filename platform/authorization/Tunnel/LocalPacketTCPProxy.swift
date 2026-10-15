import Foundation
import Network
import Darwin

// Single-use loopback bridge for Apple's TLS implementation. Only the verified
// tunnel-offer port is reachable; it injects into our private packet interface,
// never forwards external traffic or relies on the suspended game process.
final class LocalPacketTCPProxy {
    enum Failure: Error { case setup, transport, timeout, cancelled }
    private let queue = DispatchQueue(label:"local.tolkara.packet-tls-proxy")
    private let codec: LocalTCPIPv4
    private let reservation: Int32
    private let listener: NWListener
    private let output: (Data)->Bool
    private var client: NWConnection?, tcp: TunnelTCP?, timer: DispatchSourceTimer?
    private var onReady: ((UInt16)->Void)?, onClosed: ((Error)->Void)?
    private var started = false, stopped = false, established = false, localReady = false
    private var reading = false, sending = false, localEOF = false, writeShutdown = false
    private var pending = Data()
    private var connectDeadline = 0.0
    private var accepted = false, packetsOut = 0, packetsIn = 0, bytesLocal = 0, bytesRemote = 0
    private var clock: TimeInterval { ProcessInfo.processInfo.systemUptime }

    init(servicePort: UInt16, output: @escaping (Data)->Bool) throws {
        guard servicePort > 0 else { throw Failure.setup }
        let fd = socket(AF_INET,SOCK_STREAM,0)
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size);address.sin_family = sa_family_t(AF_INET)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = fd >= 0 && withUnsafeMutablePointer(to:&address) { pointer in
            pointer.withMemoryRebound(to:sockaddr.self,capacity:1) { Darwin.bind(fd,$0,length)==0 && getsockname(fd,$0,&length)==0 }
        }
        guard bound else { if fd >= 0 { Darwin.close(fd) };throw Failure.setup }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host:"127.0.0.1",port:.any)
        do { listener = try NWListener(using:parameters) }
        catch { Darwin.close(fd);throw error }
        reservation = fd
        codec = LocalTCPIPv4(clientPort:UInt16(bigEndian:address.sin_port),servicePort:servicePort)
        self.output = output
    }
    func start(onReady: @escaping (UInt16)->Void, onClosed: @escaping (Error)->Void) {
        queue.async { [self] in
            guard !started, !stopped else { onClosed(Failure.setup);return }
            started = true;self.onReady = onReady;self.onClosed = onClosed;connectDeadline = clock+15
            listener.stateUpdateHandler = { [weak self] state in
                guard let self, !self.stopped else { return }
                switch state {
                case .ready:
                    guard let port = self.listener.port else { self.stop(Failure.setup);return }
                    let callback = self.onReady;self.onReady = nil;callback?(port.rawValue)
                case .failed: self.stop(Failure.transport)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self, !self.stopped, self.client == nil,
                      case .hostPort(let host,_) = connection.endpoint,
                      host == NWEndpoint.Host("127.0.0.1") else { connection.cancel();return }
                self.client = connection;self.listener.cancel()
                self.accepted = true
                connection.stateUpdateHandler = { [weak self] state in
                    guard let self, !self.stopped else { return }
                    switch state {
                    case .ready: self.localReady = true;self.readLocal();self.sendLocal()
                    case .failed, .cancelled: self.stop(Failure.transport)
                    default:break
                    }
                }
                connection.start(queue:self.queue)
                do {
                    let tcp = try TunnelTCP(endpoints:self.codec.endpoints,mtu:1500,initialSequence:.random(in:0...UInt32.max))
                    self.tcp = tcp;self.process(try tcp.connect(now:self.clock))
                } catch { self.stop(Failure.setup) }
            }
            let timer = DispatchSource.makeTimerSource(queue:queue)
            timer.schedule(deadline:.now()+0.1,repeating:0.1)
            timer.setEventHandler { [weak self] in
                guard let self, !self.stopped else { return }
                if !self.established && self.clock >= self.connectDeadline { self.stop(Failure.timeout) }
                else if let tcp = self.tcp { self.process(tcp.tick(now:self.clock)) }
            }
            self.timer = timer;timer.resume();listener.start(queue:queue)
        }
    }
    func consume(_ packet: Data) -> Bool {
        guard codec.matches(packet) else { return false }
        queue.sync {
            guard !stopped, let tcp, let bytes = try? codec.incoming(packet) else { return }
            packetsIn += 1
            process(tcp.receive(bytes,now:clock))
        }
        return true
    }
    func cancel() { queue.async { self.stop(Failure.cancelled) } }
    var diagnostic: String {
        queue.sync { "proxy accepted=\(accepted), TCP=\(established), packets out/in=\(packetsOut)/\(packetsIn), bytes local/remote=\(bytesLocal)/\(bytesRemote)" }
    }
    private func process(_ events: [TunnelTCP.Event]) {
        guard !stopped else { return }
        for event in events {
            if case .packet(let bytes) = event {
                guard let packet = try? codec.outgoing(bytes), output(packet) else { stop(Failure.transport);return }
                packetsOut += 1
            }
        }
        for event in events {
            guard !stopped else { return }
            switch event {
            case .connected: established = true;readLocal()
            case .writable: flushPending()
            case .readable: sendLocal()
            case .failed, .closed, .peerClosed: stop(Failure.transport)
            default:break
            }
        }
    }
    private func readLocal() {
        guard !stopped, established, localReady, !reading, !localEOF, pending.isEmpty, let client else { return }
        reading = true
        client.receive(minimumIncompleteLength:1,maximumLength:8192) { [weak self] data,_,ended,error in
            guard let self, !self.stopped else { return };self.reading = false
            guard error == nil, data?.isEmpty == false || ended else { self.stop(Failure.transport);return }
            self.pending = data ?? Data();self.localEOF = ended;self.flushPending()
            self.bytesLocal += data?.count ?? 0
        }
    }
    private func flushPending() {
        guard !stopped, let tcp else { return }
        if !pending.isEmpty {
            do {
                let events = try tcp.write(pending,now:clock);pending = Data();process(events)
            } catch TunnelTCP.Failure.backpressure { return }
            catch { stop(Failure.transport);return }
        }
        if localEOF && !writeShutdown {
            writeShutdown = true
            do { process(try tcp.shutdownWrite(now:clock)) } catch { stop(Failure.transport) }
        } else { readLocal() }
    }
    private func sendLocal() {
        guard !stopped, localReady, !sending, let client, let tcp else { return }
        let (bytes,events) = tcp.read(maximum:8192)
        // Mark admission before processing ACK events, since they may trigger
        // callbacks. There is at most one 8 KiB Network.framework send in flight.
        sending = !bytes.isEmpty;process(events)
        bytesRemote += bytes.count
        guard !stopped, !bytes.isEmpty else { return }
        client.send(content:bytes,completion:.contentProcessed { [weak self] error in
            guard let self, !self.stopped else { return };self.sending = false
            if error != nil { self.stop(Failure.transport) } else { self.sendLocal() }
        })
    }
    private func stop(_ error: Error) {
        guard !stopped else { return };stopped = true
        timer?.cancel();timer = nil;listener.stateUpdateHandler = nil;listener.newConnectionHandler = nil;listener.cancel()
        client?.stateUpdateHandler = nil;client?.cancel();client = nil
        if let tcp { for event in tcp.abort() {
            if case .packet(let bytes) = event, let packet = try? codec.outgoing(bytes) { _ = output(packet) }
        } }
        tcp = nil;pending = Data();onReady = nil
        let callback = onClosed;onClosed = nil;callback?(error)
    }
    deinit { timer?.cancel();listener.cancel();client?.cancel();Darwin.close(reservation) }
}
