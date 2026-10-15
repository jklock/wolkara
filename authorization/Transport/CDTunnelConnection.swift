import Foundation
import Network
import Security

// Encrypted packet transport, not a TCP stack or executable-memory authority.
// Retain the pairing control connection while using this tunnel. Handlers run
// on the supplied serial queue (private by default) and must return promptly. No payload/key logging.
final class CDTunnelConnection {
    enum Failure: Error { case invalidState, transport, protocolFailure, timedOut, cancelled, backpressure, closed }
    private let queue: DispatchQueue
    private let connection: NWConnection
    private let timeout: TimeInterval
    private var stream: CDTunnelStream
    private var readTimer: DispatchSourceTimer?
    private var writeTimer: DispatchSourceTimer?
    private var readGeneration: UInt64 = 0, writeGeneration: UInt64 = 0
    private var started = false, closed = false, tlsReady = false
    private(set) var diagnosticStage = "TLS connection pending"
    private var onReady: ((CDTunnelConfiguration) -> Void)?
    private var onPacket: ((Data) -> Void)?
    private var onClose: ((Error) -> Void)?
    private var writes: [UUID: (Int, (Error?) -> Void)] = [:]
    private let admission = NSLock()
    private var admittedBytes = 0, admittedCount = 0

    init(host: NWEndpoint.Host, port: NWEndpoint.Port, sessionKey: Data,
         mtu: Int = 16000, timeout: TimeInterval = 10,
         queue: DispatchQueue = DispatchQueue(label: "local.tolkara.cdtunnel")) throws {
        guard timeout.isFinite, timeout >= 0.05, timeout <= 60 else { throw Failure.invalidState }
        let tls = NWProtocolTLS.Options()
        guard TKConfigurePairingTLS(tls.securityProtocolOptions, sessionKey) else { throw Failure.invalidState }
        connection = NWConnection(host: host, port: port, using: NWParameters(tls: tls))
        self.timeout = timeout; self.queue = queue; stream = try CDTunnelStream(mtu: mtu)
    }
    func start(onReady: @escaping (CDTunnelConfiguration) -> Void,
               onPacket: @escaping (Data) -> Void, onClose: @escaping (Error) -> Void) {
        queue.async { [self] in
            guard !self.started, !self.closed else { onClose(Failure.invalidState); return }
            self.started = true; self.onReady = onReady; self.onPacket = onPacket; self.onClose = onClose
            self.connection.stateUpdateHandler = { [weak self] state in
                guard let self, !self.closed else { return }
                switch state {
                case .ready:
                    guard !self.tlsReady else { return }
                    self.tlsReady = true
                    self.diagnosticStage = "TLS ready; validating negotiated protocol"
                    guard let tls = self.connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else {
                        self.diagnosticStage = "TLS metadata unavailable"
                        self.stop(Failure.protocolFailure); return
                    }
                    let metadata = tls.securityProtocolMetadata
                    let version = sec_protocol_metadata_get_negotiated_tls_protocol_version(metadata).rawValue
                    let cipher = sec_protocol_metadata_get_negotiated_tls_ciphersuite(metadata).rawValue
                    self.diagnosticStage = String(format:"TLS ready; negotiated version 0x%04x cipher 0x%04x",version,cipher)
                    guard version == 0x0303 && TKPairingTLSCipherAllowed(cipher) else {
                        self.stop(Failure.protocolFailure); return
                    }
                    do {
                        let request = try self.stream.begin()
                        self.diagnosticStage = "TLS verified; CDTunnel handshake pending"
                        self.connection.send(content: request, completion: .contentProcessed { [weak self] error in
                            guard let self, !self.closed else { return }
                            if error != nil { self.stop(Failure.transport) } else { self.receive() }
                        })
                    } catch { self.stop(Failure.protocolFailure) }
                case .failed(let error), .waiting(let error):
                    switch error {
                    case .tls(let code): self.diagnosticStage = "TLS error \(code)"
                    case .posix(let code): self.diagnosticStage = "Network POSIX error \(code.rawValue)"
                    case .dns(let code): self.diagnosticStage = "Network DNS error \(code)"
                    default: self.diagnosticStage = "Other network error"
                    }
                    self.stop(Failure.transport)
                case .cancelled: self.stop(Failure.cancelled)
                default: break
                }
            }
            self.armReadTimeout()
            self.connection.start(queue: self.queue)
        }
    }
    func cancel() { queue.async { self.stop(Failure.cancelled) } }
    func send(_ packet: Data, completion: @escaping (Error?) -> Void) {
        // Prevent a caller from enqueuing an arbitrarily large retained blob.
        guard packet.count >= 40, packet.count <= 16000 else {
            queue.async { completion(Failure.protocolFailure) }; return
        }
        // Reserve before dispatching so even queued closures cannot retain an
        // unbounded amount of packet data while the worker queue is busy.
        admission.lock()
        let accepted = admittedBytes + packet.count <= 256 * 1024 && admittedCount < 64
        if accepted { admittedBytes += packet.count; admittedCount += 1 }
        admission.unlock()
        guard accepted else { queue.async { completion(Failure.backpressure) }; return }
        queue.async { [self] in
            guard !self.closed, let configuration = self.stream.configuration else {
                self.releaseAdmission(packet.count); completion(Failure.invalidState); return
            }
            do { try configuration.validatePacket(packet, outgoing: true) }
            catch {
                self.diagnosticStage = "Outgoing IPv6 validation failed (bytes=\(packet.count), MTU=\(configuration.mtu))"
                self.releaseAdmission(packet.count); completion(Failure.protocolFailure); return
            }
            let id = UUID()
            self.writes[id] = (packet.count, completion)
            if self.writes.count == 1 { self.armWriteTimeout() }
            self.connection.send(content: packet, completion: .contentProcessed { [weak self] error in
                guard let self, let item = self.writes.removeValue(forKey: id) else { return }
                self.releaseAdmission(item.0)
                if error != nil { item.1(Failure.transport); self.stop(Failure.transport); return }
                item.1(nil)
                if self.writes.isEmpty { self.writeGeneration &+= 1; self.writeTimer?.cancel(); self.writeTimer = nil }
                else { self.armWriteTimeout() }
            })
        }
    }
    private func receive() {
        guard !closed else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, ended, error in
            guard let self, !self.closed else { return }
            guard error == nil else { self.stop(Failure.transport); return }
            do {
                var madeProgress = false
                if let data, !data.isEmpty {
                    for event in try self.stream.consume(data) {
                        madeProgress = true
                        switch event {
                        case .configured(let configuration): self.diagnosticStage = "Authenticated CDTunnel configured";self.onReady?(configuration); self.onReady = nil
                        case .packet(let packet): self.onPacket?(packet)
                        }
                    }
                }
                if ended {
                    try self.stream.finish(); self.stop(Failure.closed); return
                }
                guard data?.isEmpty == false else { self.stop(Failure.transport); return }
                if self.stream.configuration != nil {
                    if madeProgress { self.readGeneration &+= 1; self.readTimer?.cancel(); self.readTimer = nil }
                    if self.stream.hasPartialPacket && self.readTimer == nil { self.armReadTimeout() }
                    else if !self.stream.hasPartialPacket { self.readGeneration &+= 1; self.readTimer?.cancel(); self.readTimer = nil }
                }
                self.receive()
            } catch {
                self.diagnosticStage = "Incoming CDTunnel decoding failed: \(self.stream.diagnosticStage)"
                self.stop(Failure.protocolFailure)
            }
        }
    }
    private func armReadTimeout() {
        readGeneration &+= 1; let generation = readGeneration
        readTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler { [weak self] in
            guard let self, self.readGeneration == generation else { return }
            self.stop(Failure.timedOut)
        }
        readTimer = timer; timer.resume()
    }
    private func armWriteTimeout() {
        writeGeneration &+= 1; let generation = writeGeneration
        writeTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler { [weak self] in
            guard let self, self.writeGeneration == generation else { return }
            self.stop(Failure.timedOut)
        }
        writeTimer = timer; timer.resume()
    }
    private func stop(_ error: Error) {
        guard !closed else { return }
        closed = true; readGeneration &+= 1; writeGeneration &+= 1; readTimer?.cancel(); readTimer = nil; writeTimer?.cancel(); writeTimer = nil
        connection.stateUpdateHandler = nil; connection.cancel()
        let pending = writes; writes.removeAll()
        onReady = nil; onPacket = nil
        let callback = onClose; onClose = nil
        for (_, item) in pending { releaseAdmission(item.0); item.1(error) }
        callback?(error)
    }
    private func releaseAdmission(_ count: Int) {
        admission.lock(); admittedBytes -= count; admittedCount -= 1; admission.unlock()
    }
    deinit { readTimer?.cancel(); writeTimer?.cancel(); connection.cancel() }
}
