import Foundation

// Keeps the discovery TCP stream alive after the catalog arrives. Caller owns
// this object through tunnel teardown; the authenticated tunnel is a separate
// requirement and no result here authorizes guest execution.
final class TunnelDiscoveryClient {
    private let manager: TunnelConnectionManager
    private let discovery: RemoteDiscovery
    private var stream: UUID?
    private var timer: DispatchSourceTimer?
    private var completion: ((Result<RemoteServiceCatalog,Error>) -> Void)?
    private var started = false, finished = false, cancelled = false
    private(set) var diagnosticStage = "TCP stream pending"
    init(manager: TunnelConnectionManager, expectedDeviceIdentifier: String, hostUUID: UUID) {
        self.manager = manager
        discovery = RemoteDiscovery(expectedDeviceIdentifier:expectedDeviceIdentifier,hostUUID:hostUUID)
    }
    func start(port: UInt16, completion: @escaping (Result<RemoteServiceCatalog,Error>) -> Void) {
        dispatchPrecondition(condition:.onQueue(manager.queue))
        guard !started, !cancelled else { completion(.failure(PairingError.invalidState)); return }
        started = true; self.completion = completion
        // This outer deadline includes TCP establishment. The protocol also
        // checks its own fixed deadline on every incoming frame.
        let timer = DispatchSource.makeTimerSource(queue:manager.queue)
        timer.schedule(deadline:.now()+20)
        timer.setEventHandler { [weak self] in self?.fail(PairingError.exhausted) }
        self.timer = timer; timer.resume()
        do {
            let id = try manager.open(port:port) { [weak self] id,event in self?.handle(id,event) }
            if cancelled { manager.cancelStream(id) } else { stream = id }
        } catch { fail(error) }
    }
    private func handle(_ id: UUID, _ event: TunnelStreams.StreamEvent) {
        guard !cancelled else { return }
        stream = id
        if finished {
            // Stop reading after the first catalog. Any subsequent service
            // update stays bounded by TCP's receive window; callers re-discover
            // when developer-image state changes instead of using stale ports.
            if case .closed = event { stream = nil }
            return
        }
        do {
            switch event {
            case .connected:
                diagnosticStage = "TCP connected; RemoteXPC negotiation"
                try process(discovery.begin(now:ProcessInfo.processInfo.systemUptime),id:id)
            case .readable:
                let bytes = try manager.read(id)
                diagnosticStage = "RemoteXPC received \(bytes.count) bytes; state \(discovery.state)"
                try process(discovery.receive(bytes,now:ProcessInfo.processInfo.systemUptime),id:id)
            case .peerClosed: fail(PairingError.malformed)
            case .closed(let error): stream = nil; fail(error ?? PairingError.malformed)
            default:break
            }
        } catch { fail(error) }
    }
    private func process(_ events: [RemoteDiscovery.Event], id: UUID) throws {
        var catalog: RemoteServiceCatalog?
        for event in events {
            switch event {
            case .send(let bytes): try manager.write(id,data:bytes)
            case .catalog(let value): catalog = value
            }
        }
        if let catalog {
            try discovery.finish(); finished = true; timer?.cancel(); timer = nil
            let callback = completion; completion = nil; callback?(.success(catalog))
        }
    }
    func cancel() {
        dispatchPrecondition(condition:.onQueue(manager.queue))
        fail(TunnelConnectionManager.Failure.cancelled)
    }
    private func fail(_ error: Error) {
        guard !cancelled else { return }
        // Errors here are our fixed protocol enums, never peer payloads.
        if error is PairingError || error is TunnelTCP.Failure || error is TunnelStreams.Failure || error is TunnelConnectionManager.Failure || error is CDTunnelConnection.Failure {
            diagnosticStage += "; \(error)"
        }
        cancelled = true; finished = true; timer?.cancel(); timer = nil
        let id = stream; stream = nil
        let callback = completion; completion = nil
        if let id { manager.cancelStream(id) }
        callback?(.failure(error))
    }
    deinit {
        timer?.cancel()
        if let id = stream {
            let manager = manager
            manager.queue.async { manager.cancelStream(id) }
        }
    }
}
