import Foundation
import CryptoKit
private func check(_ value: Bool, _ text: String) { if !value { fatalError(text) } }
private final class Pair: ExistingPairConnection {
    var completion: PairingConnection.Completion?
    var cancelled = 0
    func start(completion: @escaping PairingConnection.Completion) { self.completion = completion }
    func cancel() { cancelled += 1 }
}
private final class FailedLink: TunnelPacketConnection {
    var cancelled = 0
    func start(onReady: @escaping (CDTunnelConfiguration)->Void,onPacket: @escaping (Data)->Void,onClose: @escaping (Error)->Void) { onClose(PairingError.authenticationFailed) }
    func send(_ packet: Data,completion: @escaping (Error?)->Void) { fatalError("failed tunnel sent packets") }
    func cancel() { cancelled += 1 }
}
@main struct SessionTests {
    static func main() throws {
        let queue = DispatchQueue(label:"developer-session-test")
        let offer = PairingSession.TunnelOffer(port:12345,sessionKey:SymmetricKey(data:Data(0..<32)))
        for mode in 0..<4 {
            let pair = Pair(), done = DispatchSemaphore(value:0)
            var factories = 0, closed = 0
            let session = try LocalDeveloperSession(pairing:pair,expectedDeviceIdentifier:"fixture-device",hostUUID:UUID(),queue:queue,timeout:0.1) { _,_ in
                factories += 1; return FailedLink()
            }
            queue.sync {
                session.start(onReady:{ _,_ in fatalError("failed setup declared ready") },onClosed:{ _ in closed += 1; done.signal() })
                if mode == 0 { pair.completion?(.failure(PairingError.authenticationFailed)) }
                if mode == 1 { session.cancel(); pair.completion?(.success(offer)) }
                if mode == 2 { pair.completion?(.success(offer)) }
                // mode 3 deliberately never produces a pairing response.
            }
            check(done.wait(timeout:.now()+2) == .success,"bounded session failure")
            queue.sync {
                check(session.state == .closed && closed == 1 && pair.cancelled == 1,"failure cleans pairing once")
                check(factories == (mode == 2 ? 1 : 0),"no tunnel before successful proof")
                session.cancel(); pair.completion?(.success(offer))
            }
            queue.sync { check(closed == 1,"late completion cannot restart session") }
        }
        print("Developer session: proof failure, pre-completion cancellation, TLS failure, startup deadline and late-result cleanup passed")
    }
}
