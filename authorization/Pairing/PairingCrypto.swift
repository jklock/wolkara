import Foundation
import CryptoKit

// CryptoKit owns the primitives. This layer implements only key derivation and
// ciphertext formats; successful decryption is NOT peer identity verification,
// completed pairing, debugger attachment, or executable-memory authorization.
enum PairingCrypto {
    static func derive(_ secret: SymmetricKey, salt: String = "", info: String) -> SymmetricKey {
        HKDF<SHA512>.deriveKey(inputKeyMaterial: secret, salt: Data(salt.utf8),
                              info: Data(info.utf8), outputByteCount: 32)
    }
    static func nonce(_ label: String) throws -> Data {
        guard label.utf8.count == 8 else { throw PairingError.malformed }
        return Data(repeating: 0, count: 4) + Data(label.utf8)
    }
    static func seal(_ plaintext: Data, key: SymmetricKey, nonce: Data) throws -> Data {
        guard plaintext.count <= PairingTLV.limit else { throw PairingError.oversized }
        let box = try ChaChaPoly.seal(plaintext, using: key, nonce: ChaChaPoly.Nonce(data: nonce))
        return box.ciphertext + box.tag // Protocol transmits no nonce prefix.
    }
    static func open(_ ciphertext: Data, key: SymmetricKey, nonce: Data) throws -> Data {
        guard ciphertext.count >= 16, ciphertext.count <= PairingTLV.limit + 16 else {
            throw PairingError.malformed
        }
        do {
            let box = try ChaChaPoly.SealedBox(nonce: ChaChaPoly.Nonce(data: nonce),
                ciphertext: ciphertext.dropLast(16), tag: ciphertext.suffix(16))
            return try ChaChaPoly.open(box, using: key)
        } catch { throw PairingError.authenticationFailed }
    }
    static func verifyKey(_ shared: SharedSecret) -> SymmetricKey {
        shared.hkdfDerivedSymmetricKey(using: SHA512.self,
            salt: Data("Pair-Verify-Encrypt-Salt".utf8),
            sharedInfo: Data("Pair-Verify-Encrypt-Info".utf8), outputByteCount: 32)
    }
    static func sharedSecret(privateKey: Curve25519.KeyAgreement.PrivateKey,
                             peerPublicKey: Data) throws -> SharedSecret {
        guard peerPublicKey.count == 32 else { throw PairingError.invalidKey }
        do {
            return try privateKey.sharedSecretFromKeyAgreement(
                with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicKey))
        } catch { throw PairingError.invalidKey }
    }
    static func hostProof(signingKey: Curve25519.Signing.PrivateKey, identifier: Data,
                          hostEphemeral: Data, deviceEphemeral: Data) throws -> Data {
        guard !identifier.isEmpty, identifier.count <= 1024,
              String(data: identifier, encoding: .utf8) != nil,
              !identifier.contains(0), hostEphemeral.count == 32, deviceEphemeral.count == 32 else {
            throw PairingError.malformed
        }
        let signature = try signingKey.signature(for: hostEphemeral + identifier + deviceEphemeral)
        return try PairingTLV.encode([(1, identifier), (10, signature)])
    }
}

// One outstanding request on one serial owner. New connection => new shared
// secret and channel. Never retry by re-encrypting with the same nonce. Transport
// failure must call close(); this object cannot be resumed or reset afterward.
final class PairingEncryptedChannel {
    private var clientKey: SymmetricKey?, serverKey: SymmetricKey?
    private var next: UInt64 = 0
    private var pending: Data?
    private var closed = false
    init(sessionKey: SymmetricKey) {
        clientKey = PairingCrypto.derive(sessionKey, info: "ClientEncrypt-main")
        serverKey = PairingCrypto.derive(sessionKey, info: "ServerEncrypt-main")
    }
    func close() { closed = true; pending = nil; clientKey = nil; serverKey = nil }
    func sealRequest(_ plaintext: Data) throws -> Data {
        guard !closed, pending == nil, let key = clientKey else { throw PairingError.invalidState }
        guard next < UInt64.max else { close(); throw PairingError.exhausted }
        var sequence = next.littleEndian
        let nonce = withUnsafeBytes(of: &sequence) { Data($0) } + Data(repeating: 0, count: 4)
        // Consume the counter before attempting encryption; an error poisons the
        // session, preventing accidental nonce reuse on a caller's retry.
        next += 1
        do {
            let result = try PairingCrypto.seal(plaintext, key: key, nonce: nonce)
            pending = nonce; return result
        } catch { close(); throw error }
    }
    func openResponse(_ ciphertext: Data) throws -> Data {
        guard !closed, let nonce = pending, let key = serverKey else { throw PairingError.invalidState }
        do {
            let result = try PairingCrypto.open(ciphertext, key: key, nonce: nonce)
            pending = nil; return result
        } catch { close(); throw error }
    }
}
