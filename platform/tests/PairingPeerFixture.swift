import Foundation
import CryptoKit

func check(_ value: Bool, _ message: String) { if !value { fatalError(message) } }
func reject(_ message: String, _ operation: () throws -> Void) {
    do { try operation(); fatalError("Accepted: \(message)") } catch {}
}
func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }
func object(_ bytes: Data) throws -> [String: Any] { try JSONSerialization.jsonObject(with: bytes) as! [String: Any] }
func payload(_ bytes: Data, kind: String = "plain") throws -> Any {
    let o = try object(bytes)
    check(o["originatedBy"] as? String == "host", "outgoing origin")
    return ((o["message"] as! [String: Any])[kind] as! [String: Any])["_0"]!
}
func response(_ payload: Any, seq: Any, kind: String = "plain", origin: String = "device") throws -> Data {
    try json(["message": [kind: ["_0": payload]], "originatedBy": origin, "sequenceNumber": seq])
}
func event(_ bytes: Data) -> [String: Any] {
    ["event": ["_0": ["pairingData": ["_0": ["data": bytes.base64EncodedString()]]]]]
}
func tlv(_ bytes: Data) throws -> Data {
    let p = try payload(bytes) as! [String: Any]
    let details = (((p["event"] as! [String: Any])["_0"] as! [String: Any])["pairingData"] as! [String: Any])["_0"] as! [String: Any]
    check(details["kind"] as? String == "verifyManualPairing", "verification kind")
    return Data(base64Encoded: details["data"] as! String)!
}
func outgoing(_ step: PairingSession.Step) -> Data {
    guard case .send(let data) = step else { fatalError("Unexpected tunnel before handshake completed") }; return data
}

// Local independent peer fixture. It uses CryptoKit directly for signature and
// AEAD, and literal field bytes for messages, instead of the client crypto API.
final class Peer {
    let signing = Curve25519.Signing.PrivateKey()
    let ephemeral = Curve25519.KeyAgreement.PrivateKey()
    let host = Curve25519.Signing.PrivateKey()
    let hostID = Data("test-host".utf8), peerID = Data("test-device".utf8)
    var shared: SharedSecret!
    var verifyKey: SymmetricKey!
    var hostEphemeral = Data()
    func identity() throws -> PairingIdentity {
        try PairingIdentity(hostIdentifier: hostID, privateKey: host.rawRepresentation,
            publicKey: host.publicKey.rawRepresentation, peerIdentifier: peerID,
            peerPublicKey: signing.publicKey.rawRepresentation)
    }
    func session() throws -> PairingSession { PairingSession(identity: try identity()) }
    func handshake(_ session: PairingSession) throws {
        let start = try object(session.begin())
        check((start["sequenceNumber"] as! NSNumber).intValue == 0, "first host sequence")
        let bytes = outgoing(try session.receive(response(["response": ["_1": ["handshake": ["_0": [:]]]]], seq: 0)))
        let values = try PairingTLV.message(tlv(bytes), state: 1)
        hostEphemeral = values[3]!
        shared = try ephemeral.sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: hostEphemeral))
        verifyKey = shared.hkdfDerivedSymmetricKey(using: SHA512.self,
            salt: Data("Pair-Verify-Encrypt-Salt".utf8), sharedInfo: Data("Pair-Verify-Encrypt-Info".utf8), outputByteCount: 32)
    }
    func proof(peerID: Data? = nil, wrongSigningKey: Bool = false, tamper: Bool = false) throws -> Data {
        let id = peerID ?? self.peerID
        let transcript = ephemeral.publicKey.rawRepresentation + id + hostEphemeral
        let key = wrongSigningKey ? Curve25519.Signing.PrivateKey() : signing
        let signature = try key.signature(for: transcript)
        let clear = Data([1,UInt8(id.count)]) + id + Data([10,64]) + signature
        let nonce = Data([0,0,0,0,80,86,45,77,115,103,48,50])
        let box = try ChaChaPoly.seal(clear, using: verifyKey, nonce: ChaChaPoly.Nonce(data: nonce))
        var encrypted = box.ciphertext + box.tag
        if tamper { encrypted[encrypted.startIndex] ^= 1 }
        return Data([6,1,2,3,32]) + ephemeral.publicKey.rawRepresentation + Data([5,UInt8(encrypted.count)]) + encrypted
    }
    func verifyHost(_ bytes: Data) throws {
        let values = try PairingTLV.message(tlv(bytes), state: 3)
        let nonce = Data([0,0,0,0,80,86,45,77,115,103,48,51])
        let box = try ChaChaPoly.SealedBox(combined: nonce + values[5]!)
        let clear = try ChaChaPoly.open(box, using: verifyKey)
        let fields = try PairingTLV.decode(clear)
        check(fields[1] == hostID, "host identity proof")
        check(host.publicKey.isValidSignature(fields[10]!, for: hostEphemeral + hostID + ephemeral.publicKey.rawRepresentation), "host signature")
    }
    func advanceToListener(_ session: PairingSession) throws {
        try handshake(session)
        try verifyHost(outgoing(session.receive(response(event(proof()), seq: 1))))
        let bytes = outgoing(try session.receive(response(event(Data([6,1,4])), seq: 2)))
        let cipher = Data(base64Encoded: try payload(bytes, kind: "streamEncrypted") as! String)!
        let key = shared.hkdfDerivedSymmetricKey(using: SHA512.self, salt: Data(), sharedInfo: Data("ClientEncrypt-main".utf8), outputByteCount: 32)
        let box = try ChaChaPoly.SealedBox(combined: Data(repeating: 0, count: 12) + cipher)
        let clear = try object(ChaChaPoly.open(box, using: key))
        let listener = ((clear["request"] as! [String: Any])["_0"] as! [String: Any])["createListener"] as! [String: Any]
        check(listener["transportProtocolType"] as? String == "tcp", "tunnel transport")
        check(Data(base64Encoded: listener["key"] as! String) == shared.withUnsafeBytes({Data($0)}), "listener session key")
        check(session.phase == .listener, "listener phase")
    }
    func listenerResponse(port: Any = 59100, tamper: Bool = false) throws -> Data {
        let clear = try json(["response": ["_1": ["createListener": ["port": port]]]])
        let key = shared.hkdfDerivedSymmetricKey(using: SHA512.self, salt: Data(), sharedInfo: Data("ServerEncrypt-main".utf8), outputByteCount: 32)
        let box = try ChaChaPoly.seal(clear, using: key, nonce: ChaChaPoly.Nonce(data: Data(repeating: 0, count: 12)))
        var encrypted = box.ciphertext + box.tag
        if tamper { encrypted[encrypted.startIndex] ^= 1 }
        return try response(encrypted.base64EncodedString(), seq: 3, kind: "streamEncrypted")
    }
}

