import Foundation
import Network

protocol ExistingPairConnection: AnyObject {
    func start(completion: @escaping PairingConnection.Completion)
    func cancel()
}
extension PairingConnection: ExistingPairConnection {}

// Owns existing-pair verification -> encrypted tunnel -> service discovery.
// Ready means a verified catalog and usable transport, NEVER executable memory.
// Enrollment, developer-image readiness and debugger authorization are separate.
final class LocalDeveloperSession {
    enum State { case idle, pairing, tunnel, discovering, ready, closed }
    typealias Factory = (PairingSession.TunnelOffer, DispatchQueue) throws -> TunnelPacketConnection
    let queue: DispatchQueue
    private(set) var state: State = .idle
    private var pairing: ExistingPairConnection?
    private let factory: Factory, expectedIdentifier: String, hostUUID: UUID
    private let timeout: TimeInterval
    private var manager: TunnelConnectionManager?, discovery: TunnelDiscoveryClient?
    private var timer: DispatchSourceTimer?
    private var ready: ((RemoteServiceCatalog,TunnelConnectionManager) -> Void)?
    private var closed: ((Error) -> Void)?
    init(pairing: ExistingPairConnection, expectedDeviceIdentifier: String, hostUUID: UUID,
         queue: DispatchQueue, timeout: TimeInterval = 90, factory: @escaping Factory) throws {
        guard timeout.isFinite, timeout >= 0.05, timeout <= 120,
              !expectedDeviceIdentifier.isEmpty, expectedDeviceIdentifier.utf8.count <= 1024,
              !expectedDeviceIdentifier.utf8.contains(0) else { throw PairingError.malformed }
        self.pairing = pairing; expectedIdentifier = expectedDeviceIdentifier; self.hostUUID = hostUUID
        self.queue = queue; self.timeout = timeout; self.factory = factory
    }
    convenience init(host: NWEndpoint.Host, pairingPort: NWEndpoint.Port, identity: PairingIdentity,
                     expectedDeviceIdentifier: String, hostUUID: UUID) throws {
        let control = try PairingConnection(host:host,port:pairingPort,identity:identity)
        let queue = DispatchQueue(label:"local.tolkara.developer-session")
        try self.init(pairing:control,expectedDeviceIdentifier:expectedDeviceIdentifier,hostUUID:hostUUID,queue:queue) { offer,queue in
            guard let port = NWEndpoint.Port(rawValue:offer.port) else { throw PairingError.malformed }
            return try CDTunnelConnection(host:host,port:port,sessionKey:offer.sessionKey.withUnsafeBytes { Data($0) },queue:queue)
        }
    }
    func start(onReady: @escaping (RemoteServiceCatalog,TunnelConnectionManager) -> Void, onClosed: @escaping (Error) -> Void) {
        dispatchPrecondition(condition:.onQueue(queue))
        guard state == .idle, let pairing else { onClosed(PairingError.invalidState); return }
        state = .pairing; ready = onReady; closed = onClosed
        let timer = DispatchSource.makeTimerSource(queue:queue)
        timer.schedule(deadline:.now()+timeout)
        timer.setEventHandler { [weak self] in self?.stop(PairingError.exhausted) }
        self.timer = timer; timer.resume()
        pairing.start { [weak self] result in
            guard let self else { return }
            // PairingConnection owns its own serial queue. Only a single result
            // crosses queues; no packet streams or unbounded buffers do so.
            self.queue.async { [weak self] in self?.paired(result) }
        }
    }
    private func paired(_ result: Result<PairingSession.TunnelOffer,Error>) {
        guard state == .pairing else { return }
        do {
            let offer = try result.get()
            let link = try factory(offer,queue)
            let manager = TunnelConnectionManager(link:link,queue:queue)
            self.manager = manager; state = .tunnel
            // This session retains pairing through manager/discovery teardown.
            manager.start(onReady:{ [weak self,weak manager] configuration in
                guard let self, let manager, self.state == .tunnel else { return }
                self.state = .discovering
                let discovery = TunnelDiscoveryClient(manager:manager,expectedDeviceIdentifier:self.expectedIdentifier,hostUUID:self.hostUUID)
                self.discovery = discovery
                discovery.start(port:configuration.rsdPort) { [weak self,weak manager] result in
                    guard let self, let manager, self.state == .discovering else { return }
                    switch result {
                    case .success(let catalog):
                        self.state = .ready; self.timer?.cancel(); self.timer = nil
                        let callback = self.ready; self.ready = nil; callback?(catalog,manager)
                    case .failure(let error): self.stop(error)
                    }
                }
            },onClosed:{ [weak self] error in self?.stop(error) })
        } catch { stop(error) }
    }
    func cancel() {
        dispatchPrecondition(condition:.onQueue(queue)); stop(TunnelConnectionManager.Failure.cancelled)
    }
    private func stop(_ error: Error) {
        guard state != .closed else { return }
        state = .closed; timer?.cancel(); timer = nil; ready = nil
        let discovery = discovery, manager = manager, pairing = pairing
        self.discovery = nil; self.manager = nil; self.pairing = nil
        discovery?.cancel(); manager?.cancel(); pairing?.cancel()
        let callback = closed; closed = nil; callback?(error)
    }
    deinit {
        timer?.cancel(); pairing?.cancel()
        let discovery = discovery, manager = manager
        queue.async { discovery?.cancel(); manager?.cancel() }
    }
}
