import Foundation
import Network

// Transport for the existing-pair state machine. It does not enroll, attach a
// debugger, route packets, or declare the application executable. All session
// mutation and callbacks are confined to the private serial queue.
final class PairingConnection {
    enum Failure: Error { case invalidState, timedOut, cancelled, transport, protocolFailure }
    typealias Completion = (Result<PairingSession.TunnelOffer, Error>) -> Void
    private let queue = DispatchQueue(label: "local.tolkara.pairing-connection")
    private let session: PairingSession
    private let host: NWEndpoint.Host
    private let port: NWEndpoint.Port
    private let timeout: TimeInterval
    private var connection: NWConnection?
    private var timer: DispatchSourceTimer?
    private var completion: Completion?
    private var decoder = PairingFrameDecoder()
    private var started = false
    private var finished = false
    private var waitingForReply = false
    private var ready = false

    init(host: NWEndpoint.Host, port: NWEndpoint.Port, identity: PairingIdentity, timeout: TimeInterval = 10) throws {
        guard timeout.isFinite, timeout >= 0.05, timeout <= 60 else { throw Failure.invalidState }
        self.host = host; self.port = port; session = PairingSession(identity: identity); self.timeout = timeout
    }
    // Callers retain this object through completion; completion executes on the
    // private queue. UI consumers must dispatch to main. No credential logging.
    func start(completion: @escaping Completion) {
        queue.async { [self] in
            guard !self.started, !self.finished else { completion(.failure(Failure.invalidState)); return }
            self.started = true; self.completion = completion
            let connection = NWConnection(host: self.host, port: self.port, using: .tcp)
            self.connection = connection
            connection.stateUpdateHandler = { [weak self] state in
                guard let self, !self.finished else { return }
                switch state {
                case .ready:
                    guard !self.ready else { return }
                    self.ready = true
                    do { try self.send(self.session.begin()) }
                    catch { self.finish(.failure(Failure.protocolFailure)) }
                case .failed, .waiting:
                    self.finish(.failure(Failure.transport))
                case .cancelled:
                    self.finish(.failure(Failure.cancelled))
                default: break
                }
            }
            self.armTimeout()
            connection.start(queue: self.queue)
        }
    }
    func cancel() {
        queue.async {
            if self.finished { self.connection?.cancel(); self.connection = nil }
            else { self.finish(.failure(Failure.cancelled)) }
        }
    }
    private func armTimeout() {
        timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler { [weak self] in self?.finish(.failure(Failure.timedOut)) }
        self.timer = timer; timer.resume()
    }
    private func send(_ message: Data) throws {
        guard !finished, let connection, !waitingForReply else { throw Failure.invalidState }
        let framed = try PairingFrameDecoder.encode(message)
        waitingForReply = true
        armTimeout()
        connection.send(content: framed, completion: .contentProcessed { [weak self] error in
            guard let self, !self.finished else { return }
            if error != nil { self.finish(.failure(Failure.transport)); return }
            self.receive()
        })
    }
    private func receive() {
        guard !finished, waitingForReply, let connection else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, ended, error in
            guard let self, !self.finished else { return }
            if error != nil { self.finish(.failure(Failure.transport)); return }
            do {
                var message: Data?
                if let data {
                    for byte in data {
                        // We permit one response per request. Extra bytes cannot
                        // be an answer to our next request, which isn't sent yet.
                        guard message == nil else { throw Failure.protocolFailure }
                        message = try self.decoder.consume(byte)
                    }
                }
                if let message {
                    self.waitingForReply = false
                    switch try self.session.receive(message) {
                    case .send(let output):
                        guard !ended else { throw Failure.transport }
                        try self.send(output)
                    case .tunnel(let offer): self.finish(.success(offer))
                    }
                } else if ended {
                    try self.decoder.finish()
                    self.finish(.failure(Failure.transport))
                } else if data?.isEmpty != false {
                    self.finish(.failure(Failure.transport))
                } else { self.receive() }
            } catch { self.finish(.failure(Failure.protocolFailure)) }
        }
    }
    private func finish(_ result: Result<PairingSession.TunnelOffer, Error>) {
        guard !finished else { return }
        finished = true; waitingForReply = false; timer?.cancel(); timer = nil
        session.close(); connection?.stateUpdateHandler = nil
        // Keep the control connection alive while the caller establishes and
        // uses the offered tunnel; the service may tie listener lifetime to it.
        // The caller must retain this object, then cancel it during teardown.
        if case .failure = result { connection?.cancel(); connection = nil }
        decoder = PairingFrameDecoder()
        let callback = completion; completion = nil
        callback?(result)
    }
    deinit { timer?.cancel(); connection?.cancel() }
}
