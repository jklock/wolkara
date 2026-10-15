import Foundation
import Network
import CryptoKit

// Public synthetic offer; this deliberately bypasses pairing in this transport
// fixture. Pairing cryptography has separate independent-peer tests.
private final class FixtureOffer: ExistingPairConnection {
    let port: UInt16
    var cancellations = 0
    init(_ port: UInt16) { self.port = port }
    func start(completion: @escaping PairingConnection.Completion) {
        completion(.success(PairingSession.TunnelOffer(port:port,sessionKey:SymmetricKey(data:Data(0..<32)))))
    }
    func cancel() { cancellations += 1 }
}
@main struct ManagedTunnelProbe {
    static func main() throws {
        guard CommandLine.arguments.count == 2, let port = UInt16(CommandLine.arguments[1]) else { exit(64) }
        let queue = DispatchQueue(label:"fixture-managed-tunnel")
        let offer = FixtureOffer(port), done = DispatchSemaphore(value:0)
        let session = try LocalDeveloperSession(pairing:offer,expectedDeviceIdentifier:"fixture-device",
            hostUUID:UUID(uuidString:"00112233-4455-6677-8899-aabbccddeeff")!,queue:queue,timeout:12) { offer,queue in
                try CDTunnelConnection(host:"127.0.0.1",port:NWEndpoint.Port(rawValue:offer.port)!,
                    sessionKey:offer.sessionKey.withUnsafeBytes { Data($0) },timeout:3,queue:queue)
            }
        var result = 1, catalogReceived = false, serviceReceived = Data(), serviceClosed = 0, completed = false
        queue.async {
            session.start(onReady:{ catalog,manager in
                guard catalog.services.count == 702, let service = catalog.services["com.apple.debugserver.DVTSecureSocketProxy"],
                      service.port == 12345, !service.usesRemoteXPC, offer.cancellations == 0 else { session.cancel(); return }
                catalogReceived = true
                do {
                    _ = try manager.open(port:service.port) { id,event in
                        do {
                            switch event {
                            case .connected: try manager.write(id,data:Data("second-stream".utf8))
                            case .readable:
                                serviceReceived.append(try manager.read(id))
                                if serviceReceived == Data("stream-two-ready".utf8) { completed = true; session.cancel() }
                            case .closed: serviceClosed += 1
                            default:break
                            }
                        } catch { session.cancel() }
                    }
                } catch { session.cancel() }
            },onClosed:{ _ in
                if completed, catalogReceived, offer.cancellations == 1, serviceClosed == 1 { result = 0 }
                print("Managed tunnel: catalogAndSecondStream=\(result == 0), controlReleased=\(offer.cancellations == 1)")
                done.signal()
            })
        }
        if done.wait(timeout:.now()+15) != .success { queue.async { session.cancel() }; exit(2) }
        withExtendedLifetime(session) {}; exit(Int32(result))
    }
}
