import Foundation

// Runs in the separate helper process on the manager's queue. Caller selects
// an authenticated, ready raw debugserver service from discovery; not every
// advertised service speaks RSP. Never construct/start this after guest entry.
final class DebugArenaClient {
    private let manager: TunnelConnectionManager, session: DebugArenaSession
    private var stream: UUID?, timer: DispatchSourceTimer?
    private var started = false, finished = false
    private var completion: ((Result<DebugArenaSession.Receipt,DebugArenaSession.Failure>) -> Void)?
    var diagnosticProgress: String { session.diagnosticProgress }
    init(manager: TunnelConnectionManager, request: DebugArenaRequest) {
        self.manager = manager; session = DebugArenaSession(request:request)
    }
    func start(port: UInt16, completion: @escaping (Result<DebugArenaSession.Receipt,DebugArenaSession.Failure>) -> Void) {
        dispatchPrecondition(condition:.onQueue(manager.queue))
        guard !started, !finished else { completion(.failure(.init(reason:.protocolFailure,detachConfirmed:false))); return }
        started = true; self.completion = completion
        // Includes establishment; the session subsequently has per-command
        // deadlines and an overall preparation deadline, driven independently.
        let connectionDeadline = ProcessInfo.processInfo.systemUptime + 15
        let timer = DispatchSource.makeTimerSource(queue:manager.queue)
        timer.schedule(deadline:.now()+0.1,repeating:0.1,leeway:.milliseconds(10))
        timer.setEventHandler { [weak self] in
            guard let self, !self.finished else { return }
            let now = ProcessInfo.processInfo.systemUptime
            if self.session.phase == .idle && now >= connectionDeadline {
                self.finish(.failure(.init(reason:.timedOut,detachConfirmed:false)))
            } else { self.process(self.session.tick(now:now)) }
        }
        self.timer = timer; timer.resume()
        do {
            let id = try manager.open(port:port) { [weak self] id,event in self?.handle(id,event) }
            if finished { manager.cancelStream(id) } else { stream = id }
        } catch { finish(.failure(.init(reason:.disconnected,detachConfirmed:false))) }
    }
    private func handle(_ id: UUID, _ event: TunnelStreams.StreamEvent) {
        guard !finished else { return }; stream = id
        do {
            switch event {
            case .connected: process(try session.begin(now:ProcessInfo.processInfo.systemUptime))
            case .readable: process(session.receive(try manager.read(id),now:ProcessInfo.processInfo.systemUptime))
            case .peerClosed, .closed: process(session.disconnected())
            default:break
            }
        } catch { finish(.failure(.init(reason:.disconnected,detachConfirmed:false))) }
    }
    private func process(_ events: [DebugArenaSession.Event]) {
        for event in events {
            guard !finished else { return }
            switch event {
            case .send(let bytes):
                guard let stream else { finish(.failure(.init(reason:.disconnected,detachConfirmed:false))); return }
                do { try manager.write(stream,data:bytes) }
                catch { finish(.failure(.init(reason:.disconnected,detachConfirmed:false))); return }
            case .finished(let result): finish(result)
            }
        }
    }
    func cancel() {
        dispatchPrecondition(condition:.onQueue(manager.queue)); process(session.cancel())
    }
    private func finish(_ result: Result<DebugArenaSession.Receipt,DebugArenaSession.Failure>) {
        guard !finished else { return }; finished = true; timer?.cancel(); timer = nil
        let id = stream; stream = nil; let callback = completion; completion = nil
        if let id { manager.cancelStream(id) }
        callback?(result)
    }
    deinit {
        timer?.cancel()
        if let id = stream { let manager = manager; manager.queue.async { manager.cancelStream(id) } }
    }
}
