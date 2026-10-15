import Foundation
import CryptoKit

private func hex(_ s: String) -> Data {
    let s = Array(s.utf8); precondition(s.count % 2 == 0)
    func digit(_ b: UInt8) -> UInt8 { b <= 57 ? b - 48 : b - 87 }
    return Data(stride(from: 0, to: s.count, by: 2).map { digit(s[$0]) * 16 + digit(s[$0 + 1]) })
}
private func check(_ condition: Bool, _ label: String) {
    if !condition { fatalError("FAIL: \(label)") }
}
private func rejects(_ label: String, _ operation: () throws -> Void) {
    do { try operation(); fatalError("Accepted invalid input: \(label)") } catch {}
}
private func bytes(_ key: SymmetricKey) -> Data { key.withUnsafeBytes { Data($0) } }

@main struct PairingTests {
    static func main() throws {
        // Literal wire fixture, with no use of our encoder to derive expected bytes.
        let payload = Data("{}".utf8)
        let wire = Data([0x52,0x50,0x50,0x61,0x69,0x72,0x69,0x6e,0x67,0,2,0x7b,0x7d])
        check(try PairingFrameDecoder.encode(payload) == wire, "RPPairing literal frame")
        var decoder = PairingFrameDecoder(), messages: [Data] = []
        for byte in wire + wire {
            if let message = try decoder.consume(byte) { messages.append(message) }
        }
        try decoder.finish(); check(messages == [payload,payload], "coalesced frames")
        let maxPayload = Data(repeating: 0xa5, count: 65_535)
        for byte in try PairingFrameDecoder.encode(maxPayload) {
            if let message = try decoder.consume(byte) { check(message == maxPayload, "max payload") }
        }
        rejects("oversized frame") { _ = try PairingFrameDecoder.encode(Data(repeating: 0, count: 65_536)) }
        rejects("empty frame") { _ = try PairingFrameDecoder.encode(Data()) }
        for length in 1..<wire.count {
            var partial = PairingFrameDecoder()
            for byte in wire.prefix(length) { _ = try partial.consume(byte) }
            rejects("truncated frame") { try partial.finish() }
        }
        var bad = PairingFrameDecoder()
        rejects("wrong magic") { _ = try bad.consume(0) }
        rejects("poisoned decoder") { _ = try bad.consume(0x52) }
        var zero = PairingFrameDecoder()
        rejects("zero length") { for byte in wire.prefix(9) + Data([0,0]) { _ = try zero.consume(byte) } }
        var tunnel = PairingFrameDecoder(.tunnel)
        let tunnelWire = try PairingFrameDecoder.encode(payload, format: .tunnel)
        check(tunnelWire.prefix(8) == Data("CDTunnel".utf8), "CDTunnel header")
        for byte in tunnelWire { if let result = try tunnel.consume(byte) { check(result == payload, "tunnel body") } }

        let srp = Data((0..<384).map { UInt8(truncatingIfNeeded: $0) })
        let split = try PairingTLV.encode([(6,Data([3])), (3,srp)])
        check(split[4] == 255 && split[261] == 129, "TLV 255/129 split")
        check(try PairingTLV.decode(split)[3] == srp, "fragment reassembly")
        // Noncanonical but documented 254-byte fragments are also interoperable.
        let alternate = Data([3,254]) + srp.prefix(254) + Data([3,130]) + srp.suffix(130)
        check(try PairingTLV.decode(alternate)[3] == srp, "254-byte fragment")
        rejects("short TLV header") { _ = try PairingTLV.decode(Data([6])) }
        rejects("truncated TLV value") { _ = try PairingTLV.decode(Data([6,2,1])) }
        rejects("nonadjacent duplicate") { _ = try PairingTLV.decode(Data([6,1,2,3,0,6,1,4])) }
        rejects("duplicate encode") { _ = try PairingTLV.encode([(6,Data()),(6,Data())]) }
        rejects("oversized TLV") { _ = try PairingTLV.decode(Data(repeating: 0, count: 16_385)) }
        rejects("wrong state") { _ = try PairingTLV.message(Data([6,1,2]), state: 4) }
        rejects("device error") { _ = try PairingTLV.message(Data([6,1,4,7,1,2]), state: 4) }
        rejects("duplicate state bytes") { _ = try PairingTLV.message(Data([6,1,4,6,1,4]), state: 4) }
        check(try PairingTLV.message(Data([6,1,4]), state: 4)[6] == Data([4]), "state 4")

        // RFC 7748 section 6.1 independent X25519 agreement vector.
        let alice = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation:
            hex("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a"))
        let bobPublic = hex("de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f")
        let shared = try PairingCrypto.sharedSecret(privateKey: alice, peerPublicKey: bobPublic)
        let sharedBytes = shared.withUnsafeBytes { Data($0) }
        check(sharedBytes == hex("4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742"), "RFC 7748 shared secret")
        rejects("low order public key") { _ = try PairingCrypto.sharedSecret(privateKey: alice, peerPublicKey: Data(repeating: 0, count: 32)) }
        rejects("short public key") { _ = try PairingCrypto.sharedSecret(privateKey: alice, peerPublicKey: Data([1])) }
        // Expected HKDF outputs generated independently with Python hmac/SHA512.
        let key = PairingCrypto.verifyKey(shared)
        check(bytes(key) == hex("4088b4ce1491e289da3f5462e5faee3d061d2c3f8734cefeb0216982a7eb32a7"), "pair-verify HKDF")
        let sessionKey = SymmetricKey(data: sharedBytes)
        check(bytes(PairingCrypto.derive(sessionKey, info: "ClientEncrypt-main")) == hex("d0724ad08f73296a482a76c1aca971527737c1a14380cd701b4a46f7796d4044"), "client HKDF")
        check(bytes(PairingCrypto.derive(sessionKey, info: "ServerEncrypt-main")) == hex("71567b382dfbb7ce6862bb38607cb708376d9e2fefb39b70315b46f0eb7e0eea"), "server HKDF")
        let nonce = try PairingCrypto.nonce("PV-Msg03")
        check(nonce == Data([0,0,0,0,80,86,45,77,115,103,48,51]), "literal verify nonce")
        rejects("bad nonce label") { _ = try PairingCrypto.nonce("bad") }

        // Use an independent primitive invocation to decrypt/check our proof,
        // including the exact signature transcript, TLV layout and tag placement.
        let signer = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 0x42, count: 32))
        let hostPublic = alice.publicKey.rawRepresentation, identity = Data("fixture-host".utf8)
        let proof = try PairingCrypto.hostProof(signingKey: signer, identifier: identity,
                                               hostEphemeral: hostPublic, deviceEphemeral: bobPublic)
        check(proof.prefix(14) == Data([1,12]) + identity, "identity TLV")
        check(proof[14] == 10 && proof[15] == 64 && proof.count == 80, "signature TLV")
        check(signer.publicKey.isValidSignature(proof.suffix(64), for: hostPublic + identity + bobPublic), "signature transcript")
        rejects("invalid identity") { _ = try PairingCrypto.hostProof(signingKey: signer, identifier: Data([0]), hostEphemeral: hostPublic, deviceEphemeral: bobPublic) }
        let sealed = try PairingCrypto.seal(proof, key: key, nonce: nonce)
        let box = try ChaChaPoly.SealedBox(combined: nonce + sealed)
        check(try ChaChaPoly.open(box, using: key) == proof, "ciphertext/tag layout")
        check(try PairingCrypto.open(sealed, key: key, nonce: nonce) == proof, "AEAD roundtrip")
        for position in sealed.indices {
            var corrupt = sealed; corrupt[position] ^= 1
            rejects("tampered ciphertext") { _ = try PairingCrypto.open(corrupt, key: key, nonce: nonce) }
        }
        rejects("wrong AEAD key") { _ = try PairingCrypto.open(sealed, key: SymmetricKey(size: .bits256), nonce: nonce) }
        rejects("short AEAD tag") { _ = try PairingCrypto.open(Data([0]), key: key, nonce: nonce) }

        let channel = PairingEncryptedChannel(sessionKey: sessionKey)
        rejects("unsolicited reply") { _ = try channel.openResponse(sealed) }
        let clientKey = PairingCrypto.derive(sessionKey, info: "ClientEncrypt-main")
        let serverKey = PairingCrypto.derive(sessionKey, info: "ServerEncrypt-main")
        var lastReply = Data()
        // Cross the single-byte counter boundary to check the LE nonce layout.
        for sequence in 0..<260 {
            let request = try channel.sealRequest(payload)
            rejects("concurrent request") { _ = try channel.sealRequest(payload) }
            let n = Data([UInt8(sequence & 255), UInt8(sequence >> 8)] + Array(repeating: UInt8(0), count: 10))
            let requestBox = try ChaChaPoly.SealedBox(combined: n + request)
            check(try ChaChaPoly.open(requestBox, using: clientKey) == payload, "request counter")
            let responseBox = try ChaChaPoly.seal(Data("response".utf8), using: serverKey, nonce: ChaChaPoly.Nonce(data: n))
            lastReply = responseBox.ciphertext + responseBox.tag
            check(try channel.openResponse(lastReply) == Data("response".utf8), "response counter")
            rejects("duplicate response") { _ = try channel.openResponse(lastReply) }
        }
        _ = try channel.sealRequest(payload)
        rejects("replayed old response") { _ = try channel.openResponse(lastReply) }
        rejects("poison after auth failure") { _ = try channel.sealRequest(payload) }
        let oversized = PairingEncryptedChannel(sessionKey: sessionKey)
        rejects("oversized encryption") { _ = try oversized.sealRequest(Data(repeating: 0, count: 16_385)) }
        rejects("failed encryption closes channel") { _ = try oversized.sealRequest(payload) }
        let closed = PairingEncryptedChannel(sessionKey: sessionKey); closed.close()
        rejects("explicitly closed") { _ = try closed.sealRequest(payload) }

        // Deterministic malformed-input smoke test; Swift's checked indexing and
        // ASan must both survive arbitrary length fields and fragment sequences.
        var rng: UInt64 = 0x7ca061
        for _ in 0..<10_000 {
            rng = rng &* 6364136223846793005 &+ 1
            let count = Int(rng >> 56), data = Data((0..<count).map { _ in
                rng = rng &* 6364136223846793005 &+ 1; return UInt8(truncatingIfNeeded: rng >> 32)
            })
            _ = try? PairingTLV.decode(data)
            var parser = PairingFrameDecoder()
            for byte in data { do { _ = try parser.consume(byte) } catch { break } }
            try? parser.finish()
        }
        print("PASS: pairing wire, X25519/HKDF, proof encryption, tamper/replay rejection and bounds (synthetic peers only)")
    }
}
