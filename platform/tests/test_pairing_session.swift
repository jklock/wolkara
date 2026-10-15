import Foundation
import CryptoKit

@main struct PairingSessionTests {
    static func main() throws {
        let peer = Peer(), record = try peer.identity()
        let restored = try PairingIdentity(serialized: record.serialize())
        check(restored.hostIdentifier == record.hostIdentifier && restored.peerIdentifier == record.peerIdentifier &&
              restored.signingKey.rawRepresentation == record.signingKey.rawRepresentation &&
              restored.peerPublicKey.rawRepresentation == record.peerPublicKey.rawRepresentation, "record roundtrip")
        reject("mismatched record keys") { _ = try PairingIdentity(hostIdentifier: peer.hostID,
            privateKey: peer.host.rawRepresentation, publicKey: peer.signing.publicKey.rawRepresentation,
            peerIdentifier: peer.peerID, peerPublicKey: peer.signing.publicKey.rawRepresentation) }
        reject("minimal legacy record without peer trust") { _ = try PairingIdentity(serialized: PropertyListSerialization.data(fromPropertyList: ["identifier": "id", "private_key": peer.host.rawRepresentation, "public_key": peer.host.publicKey.rawRepresentation], format: .binary, options: 0)) }
        reject("oversized record") { _ = try PairingIdentity(serialized: Data(repeating: 0, count: 8193)) }
        reject("garbage record") { _ = try PairingIdentity(serialized: Data([1,2,3])) }
        let session = try peer.session()
        try peer.advanceToListener(session)
        guard case .tunnel(let offer) = try session.receive(peer.listenerResponse()) else { fatalError("Missing offer") }
        check(offer.port == 59100 && offer.sessionKey.withUnsafeBytes({Data($0)}) == peer.shared.withUnsafeBytes({Data($0)}), "tunnel offer")
        check(session.phase == .complete, "complete session")
        reject("completed session replay") { _ = try session.receive(peer.listenerResponse()) }

        for mode in 0..<5 {
            let peer = Peer(), s = try peer.session(); try peer.handshake(s)
            let proof: Data
            switch mode {
            case 0: proof = try peer.proof(peerID: Data("unknown".utf8))
            case 1: proof = try peer.proof(wrongSigningKey: true)
            case 2: proof = try peer.proof(tamper: true)
            case 3: proof = Data([6,1,2,3,32]) + peer.ephemeral.publicKey.rawRepresentation
            default: proof = Data([6,1,2,7,1,2])
            }
            reject("invalid device proof \(mode)") { _ = try s.receive(response(event(proof), seq: 1)) }
            check(s.phase == .closed, "failed proof closes session")
            reject("restart failed session") { _ = try s.begin() }
        }
        for badPort: Any in [0, -1, 65536, 2.5, true, "59100", NSNull()] {
            let peer = Peer(), s = try peer.session(); try peer.advanceToListener(s)
            reject("invalid listener port") { _ = try s.receive(peer.listenerResponse(port: badPort)) }
            check(s.phase == .closed, "bad listener closes")
        }
        do {
            let peer = Peer(), s = try peer.session(); try peer.advanceToListener(s)
            reject("forged listener ciphertext") { _ = try s.receive(peer.listenerResponse(tamper: true)) }
            check(s.phase == .closed, "tampered listener closes")
        }
        for seq: Any in [true, -1, 1.5, "1", NSNull()] {
            let s = try Peer().session(); _ = try s.begin()
            reject("invalid envelope sequence") { _ = try s.receive(response([:], seq: seq)) }
        }
        do {
            let peer = Peer(), s = try peer.session(); try peer.handshake(s)
            reject("replayed sequence") { _ = try s.receive(response(event(peer.proof()), seq: 0)) }
        }
        do {
            let s = try Peer().session(); _ = try s.begin()
            reject("host reflected envelope") { _ = try s.receive(response([:], seq: 0, origin: "host")) }
        }
        do {
            let s = try Peer().session()
            reject("unsolicited message") { _ = try s.receive(response([:], seq: 0)) }
        }
        do {
            let s = try Peer().session(); _ = try s.begin(); s.close()
            reject("closed message") { _ = try s.receive(response([:], seq: 0)) }
        }
        do {
            let peer = Peer(), s = try peer.session(); try peer.handshake(s)
            _ = try s.receive(response(event(peer.proof()), seq: 1))
            reject("wrong M4 state") { _ = try s.receive(response(event(Data([6,1,2])), seq: 2)) }
        }
        print("PASS: synthetic pairing identity, peer/host proofs, session ordering, encrypted listener and rejection paths")
    }
}
