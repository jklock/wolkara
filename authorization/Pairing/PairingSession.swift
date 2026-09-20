import Foundation
import CoreFoundation
import CryptoKit

// Existing-pair verification only. This does not implement first-time pairing.
// No sockets, storage, attachment or native-execution permission are accessed.
// Use a single serial owner; transport errors/timeouts must call close().
final class PairingSession {
    enum Phase { case idle, handshake, deviceProof, verification, listener, complete, closed }
    enum Step {
        case send(Data) // RPPairing JSON payload; the transport adds framing.
        case tunnel(TunnelOffer)
    }
    struct TunnelOffer {
        let port: UInt16
        let sessionKey: SymmetricKey
        // A listener is not evidence of a developer service or executable arena.
    }
    private(set) var phase: Phase = .idle
    private var identity: PairingIdentity?
    private var ephemeral: Curve25519.KeyAgreement.PrivateKey?
    private var sessionKey: SymmetricKey?
    private var channel: PairingEncryptedChannel?
    private var sequence: UInt64 = 0
    private var lastPeerSequence: UInt64?

    init(identity: PairingIdentity) { self.identity = identity }
    func close() {
        phase = .closed; ephemeral = nil; identity = nil; sessionKey = nil
        channel?.close(); channel = nil
    }
    func begin() throws -> Data {
        guard phase == .idle else { close(); throw PairingError.invalidState }
        do {
            ephemeral = Curve25519.KeyAgreement.PrivateKey()
            let message = try envelope(kind: "plain", payload: ["request": ["_0": ["handshake": ["_0": [
                "hostOptions": ["attemptPairVerify": true], "wireProtocolVersion": 19]]]]])
            phase = .handshake
            return message
        } catch { close(); throw error }
    }
    func receive(_ bytes: Data) throws -> Step {
        guard phase != .idle && phase != .closed && phase != .complete else {
            close(); throw PairingError.invalidState
        }
        do {
            let envelope = try Self.object(bytes)
            guard let origin = envelope["originatedBy"] as? String, origin == "device",
                  let peerSequence = Self.unsigned(envelope["sequenceNumber"]),
                  lastPeerSequence.map({ peerSequence > $0 }) ?? true,
                  let message = envelope["message"] as? [String: Any], message.count == 1 else {
                throw PairingError.malformed
            }
            lastPeerSequence = peerSequence
            if phase == .listener { return try receiveListener(message) }
            guard let plain = message["plain"] as? [String: Any], plain.count == 1,
                  let payload = plain["_0"] as? [String: Any] else { throw PairingError.malformed }
            switch phase {
            case .handshake:
                guard let response = payload["response"] as? [String: Any],
                      let result = response["_1"] as? [String: Any],
                      let handshake = result["handshake"] as? [String: Any],
                      handshake["_0"] is [String: Any], let ephemeral else { throw PairingError.malformed }
                let start = try PairingTLV.encode([(6, Data([1])), (3, ephemeral.publicKey.rawRepresentation)])
                let output = try pairingData(start, start: true)
                phase = .deviceProof
                return .send(output)
            case .deviceProof:
                return try receiveProof(Self.pairingBytes(payload))
            case .verification:
                _ = try PairingTLV.message(Self.pairingBytes(payload), state: 4)
                guard let sessionKey else { throw PairingError.invalidState }
                let channel = PairingEncryptedChannel(sessionKey: sessionKey)
                self.channel = channel
                let keyBytes = sessionKey.withUnsafeBytes { Data($0) }
                let request = try Self.json(["request": ["_0": ["createListener": [
                    "key": keyBytes.base64EncodedString(), "transportProtocolType": "tcp"]]]])
                let ciphertext = try channel.sealRequest(request)
                let output = try self.envelope(kind: "streamEncrypted", payload: ciphertext.base64EncodedString())
                phase = .listener; ephemeral = nil; identity = nil
                return .send(output)
            default: throw PairingError.invalidState
            }
        } catch { close(); throw error }
    }
    private func receiveProof(_ data: Data) throws -> Step {
        let fields = try PairingTLV.message(data, state: 2)
        guard let deviceEphemeral = fields[3], let encrypted = fields[5],
              let ephemeral, let identity else { throw PairingError.malformed }
        let shared = try PairingCrypto.sharedSecret(privateKey: ephemeral, peerPublicKey: deviceEphemeral)
        let key = PairingCrypto.verifyKey(shared)
        let proof = try PairingTLV.decode(PairingCrypto.open(encrypted, key: key,
                                                nonce: PairingCrypto.nonce("PV-Msg02")))
        guard proof[7] == nil, let peerID = proof[1], let signature = proof[10],
              peerID == identity.peerIdentifier, signature.count == 64 else {
            throw PairingError.authenticationFailed
        }
        // HAP-style transcript from Apple's public Pair Verify implementation.
        // Remote Pairing reuse is a compatibility hypothesis until verified on
        // the actual device. Missing/incompatible proof MUST fail, never skip.
        let transcript = deviceEphemeral + peerID + ephemeral.publicKey.rawRepresentation
        guard identity.peerPublicKey.isValidSignature(signature, for: transcript) else {
            throw PairingError.authenticationFailed
        }
        let hostProof = try PairingCrypto.hostProof(signingKey: identity.signingKey,
            identifier: identity.hostIdentifier, hostEphemeral: ephemeral.publicKey.rawRepresentation,
            deviceEphemeral: deviceEphemeral)
        let sealed = try PairingCrypto.seal(hostProof, key: key, nonce: PairingCrypto.nonce("PV-Msg03"))
        let response = try pairingData(PairingTLV.encode([(6, Data([3])), (5, sealed)]), start: false)
        sessionKey = shared.withUnsafeBytes { SymmetricKey(data: $0) }
        phase = .verification
        return .send(response)
    }
    private func receiveListener(_ message: [String: Any]) throws -> Step {
        guard let encrypted = message["streamEncrypted"] as? [String: Any], encrypted.count == 1,
              let text = encrypted["_0"] as? String, text.utf8.count <= 24_000,
              let ciphertext = Data(base64Encoded: text), let channel, let sessionKey else {
            throw PairingError.malformed
        }
        let object = try Self.object(channel.openResponse(ciphertext))
        guard let response = object["response"] as? [String: Any],
              let result = response["_1"] as? [String: Any],
              let listener = result["createListener"] as? [String: Any],
              let port = Self.unsigned(listener["port"]), port > 0, port <= 65_535 else {
            throw PairingError.malformed
        }
        let offer = TunnelOffer(port: UInt16(port), sessionKey: sessionKey)
        self.sessionKey = nil; channel.close(); self.channel = nil
        phase = .complete
        return .tunnel(offer)
    }
    private func pairingData(_ data: Data, start: Bool) throws -> Data {
        try envelope(kind: "plain", payload: ["event": ["_0": ["pairingData": ["_0": [
            "data": data.base64EncodedString(), "kind": "verifyManualPairing", "startNewSession": start]]]]])
    }
    private func envelope(kind: String, payload: Any) throws -> Data {
        guard sequence < UInt64.max else { throw PairingError.exhausted }
        let output = try Self.json(["message": [kind: ["_0": payload]], "originatedBy": "host",
                                   "sequenceNumber": NSNumber(value: sequence)])
        sequence += 1
        return output
    }
    private static func pairingBytes(_ payload: [String: Any]) throws -> Data {
        guard let event = payload["event"] as? [String: Any],
              let detail = event["_0"] as? [String: Any] else { throw PairingError.malformed }
        if detail["pairingRejectedWithError"] != nil || detail["pairVerifyFailed"] != nil {
            throw PairingError.authenticationFailed
        }
        guard let pairing = detail["pairingData"] as? [String: Any],
              let value = pairing["_0"] as? [String: Any],
              let text = value["data"] as? String, text.utf8.count <= 24_000,
              let data = Data(base64Encoded: text), data.count <= PairingTLV.limit else {
            throw PairingError.malformed
        }
        return data
    }
    private static func json(_ object: [String: Any]) throws -> Data {
        let data: Data
        do { data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }
        catch { throw PairingError.malformed }
        guard data.count <= 65_535 else { throw PairingError.oversized }
        return data
    }
    private static func object(_ data: Data) throws -> [String: Any] {
        guard data.count <= 65_535 else { throw PairingError.oversized }
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw PairingError.malformed
            }
            return object
        } catch { throw PairingError.malformed }
    }
    private static func unsigned(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        // NSNumber bridging would otherwise silently turn negative/fractional
        // ports or Boolean sequence numbers into integers.
        let text = number.stringValue
        guard !text.isEmpty, text.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
        return UInt64(text)
    }
}
