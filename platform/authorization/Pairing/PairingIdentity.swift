import Foundation
import CryptoKit

// A record is trusted only when supplied by authenticated enrollment or an
// explicitly trusted import. Parsing checks its structure, not its provenance.
// Keep serialized records in private protected storage, never shared Documents.
struct PairingIdentity {
    let hostIdentifier: Data
    let signingKey: Curve25519.Signing.PrivateKey
    let peerIdentifier: Data
    let peerPublicKey: Curve25519.Signing.PublicKey

    init(hostIdentifier: Data, privateKey: Data, publicKey: Data,
         peerIdentifier: Data, peerPublicKey: Data) throws {
        guard Self.validIdentifier(hostIdentifier), Self.validIdentifier(peerIdentifier),
              privateKey.count == 32, publicKey.count == 32, peerPublicKey.count == 32 else {
            throw PairingError.invalidKey
        }
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKey)
        guard key.publicKey.rawRepresentation == publicKey else { throw PairingError.invalidKey }
        self.hostIdentifier = hostIdentifier; signingKey = key
        self.peerIdentifier = peerIdentifier
        self.peerPublicKey = try Curve25519.Signing.PublicKey(rawRepresentation: peerPublicKey)
    }
    private static func validIdentifier(_ identifier: Data) -> Bool {
        !identifier.isEmpty && identifier.count <= 1024 && !identifier.contains(0) &&
        String(data: identifier, encoding: .utf8) != nil
    }
    init(serialized: Data) throws {
        guard serialized.count <= 8192 else { throw PairingError.oversized }
        let parsed: Any
        do { parsed = try PropertyListSerialization.propertyList(from: serialized, options: [], format: nil) }
        catch { throw PairingError.malformed }
        guard let object = parsed as? [String: Any], object.count == 6,
              let format = object["format"] as? String, format == "tolkara-pairing-v1",
              let host = object["hostIdentifier"] as? Data,
              let secret = object["privateKey"] as? Data,
              let key = object["publicKey"] as? Data,
              let peer = object["peerIdentifier"] as? Data,
              let peerKey = object["peerPublicKey"] as? Data else { throw PairingError.malformed }
        try self.init(hostIdentifier: host, privateKey: secret, publicKey: key,
                      peerIdentifier: peer, peerPublicKey: peerKey)
    }
    func serialize() throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: [
            "format": "tolkara-pairing-v1", "hostIdentifier": hostIdentifier,
            "privateKey": signingKey.rawRepresentation, "publicKey": signingKey.publicKey.rawRepresentation,
            "peerIdentifier": peerIdentifier, "peerPublicKey": peerPublicKey.rawRepresentation
        ], format: .binary, options: 0)
    }
}
