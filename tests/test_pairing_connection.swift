import Foundation
import Network
import CryptoKit

private final class FixtureServer {
    enum Mode { case valid, wrongProof, badMagic, truncated, extraBytes, silent }
    let peer = Peer()
    private let queue = DispatchQueue(label: "local.tolkara.test-peer")
    private let listener: NWListener
    private var connection: NWConnection?
    private var decoder = PairingFrameDecoder()
    private var phase = 0
    private let mode: Mode
    private var stopped = false
    init(mode: Mode) throws {
        self.mode = mode
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }
    func start() throws -> NWEndpoint.Port {
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state { case .ready, .failed: ready.signal(); default: break }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self, self.connection == nil, !self.stopped else { connection.cancel(); return }
            self.connection = connection
            connection.stateUpdateHandler = { [weak self] state in
                if case .ready = state { self?.receive() }
            }
            connection.start(queue: self.queue)
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 3) == .success, let port = listener.port else {
            throw PairingConnection.Failure.transport
        }
        return port
    }
    func stop() {
        queue.sync { stopped = true; connection?.stateUpdateHandler = nil; connection?.cancel(); connection = nil
            listener.newConnectionHandler = nil; listener.stateUpdateHandler = nil; listener.cancel() }
    }
    private func receive() {
        guard !stopped, let connection else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] bytes, _, done, error in
            guard let self, !self.stopped else { return }
            guard let bytes, !bytes.isEmpty, error == nil else { return }
            do {
                for byte in bytes { if let message = try self.decoder.consume(byte) { try self.reply(message) } }
                if !done { self.receive() }
            } catch { fatalError("Synthetic peer protocol error: \(error)") }
        }
    }
    private func reply(_ message: Data) throws {
        if mode == .silent { return }
        if mode == .badMagic { send(Data("NotPairing".utf8)); return }
        if mode == .truncated {
            connection?.send(content: Data("RPPairing\0\u{10}{".utf8), contentContext: .finalMessage,
                             isComplete: true, completion: .contentProcessed { _ in })
            return
        }
        let envelope = try object(message)
        check((envelope["sequenceNumber"] as? NSNumber)?.intValue == phase, "host sequence over TCP")
        let output: Data
        switch phase {
        case 0:
            let clear = try payload(message) as! [String: Any]
            let request = ((clear["request"] as! [String: Any])["_0"] as! [String: Any])["handshake"] as! [String: Any]
            let settings = request["_0"] as! [String: Any]
            check((settings["wireProtocolVersion"] as! NSNumber).intValue == 19, "wire version")
            output = try response(["response": ["_1": ["handshake": ["_0": [:]]]]], seq: 0)
        case 1:
            let values = try PairingTLV.message(tlv(message), state: 1)
            peer.hostEphemeral = values[3]!
            peer.shared = try peer.ephemeral.sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: peer.hostEphemeral))
            peer.verifyKey = peer.shared.hkdfDerivedSymmetricKey(using: SHA512.self, salt: Data("Pair-Verify-Encrypt-Salt".utf8), sharedInfo: Data("Pair-Verify-Encrypt-Info".utf8), outputByteCount: 32)
            output = try response(event(peer.proof(wrongSigningKey: mode == .wrongProof)), seq: 1)
        case 2:
            try peer.verifyHost(message)
            output = try response(event(Data([6,1,4])), seq: 2)
        case 3:
            let ciphertext = Data(base64Encoded: try payload(message, kind: "streamEncrypted") as! String)!
            let key = peer.shared.hkdfDerivedSymmetricKey(using: SHA512.self, salt: Data(), sharedInfo: Data("ClientEncrypt-main".utf8), outputByteCount: 32)
            let box = try ChaChaPoly.SealedBox(combined: Data(repeating: 0, count: 12) + ciphertext)
            let request = try object(ChaChaPoly.open(box, using: key))
            let listener = ((request["request"] as! [String: Any])["_0"] as! [String: Any])["createListener"] as! [String: Any]
            check(listener["transportProtocolType"] as? String == "tcp", "encrypted listener over TCP")
            output = try peer.listenerResponse()
        default: fatalError("Too many pairing requests")
        }
        phase += 1
        var framed = try PairingFrameDecoder.encode(output)
        if mode == .extraBytes { framed.append(0); send(framed) }
        else { sendFragmented(Array(framed), offset: 0) }
    }
    private func send(_ bytes: Data) {
        connection?.send(content: bytes, completion: .contentProcessed { _ in })
    }
    private func sendFragmented(_ bytes: [UInt8], offset: Int) {
        guard !stopped, offset < bytes.count, let connection else { return }
        let end = min(offset + 17, bytes.count)
        connection.send(content: Data(bytes[offset..<end]), completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else { return }
            self.queue.asyncAfter(deadline: .now() + .milliseconds(1)) { [weak self] in
                self?.sendFragmented(bytes, offset: end)
            }
        })
    }
}

@main struct PairingConnectionTests {
    static func main() throws {
        for mode: FixtureServer.Mode in [.valid, .wrongProof, .badMagic, .truncated, .extraBytes, .silent] {
            let server = try FixtureServer(mode: mode), port = try server.start()
            defer { server.stop() }
            let client = try PairingConnection(host: "127.0.0.1", port: port, identity: server.peer.identity(), timeout: 1)
            let finished = DispatchSemaphore(value: 0)
            let lock = NSLock(); var callbacks = 0; var success = false; var failure: PairingConnection.Failure?
            client.start { result in
                lock.lock(); callbacks += 1
                switch result {
                case .success(let offer): success = offer.port == 59100
                case .failure(let error): failure = error as? PairingConnection.Failure
                }
                lock.unlock(); finished.signal()
            }
            check(finished.wait(timeout: .now() + 4) == .success, "bounded network completion")
            lock.lock()
            check(callbacks == 1 && success == (mode == .valid), "unexpected network outcome \(mode)")
            if mode == .silent { check(failure == .timedOut, "silent peer must time out") }
            lock.unlock()
            client.cancel()
            check(finished.wait(timeout: .now() + .milliseconds(30)) == .timedOut, "duplicate callback")
        }
        do {
            let server = try FixtureServer(mode: .silent), port = try server.start(); defer { server.stop() }
            let client = try PairingConnection(host: "127.0.0.1", port: port, identity: server.peer.identity(), timeout: 1)
            let done = DispatchSemaphore(value: 0)
            client.start { result in
                guard case .failure(let error) = result, error as? PairingConnection.Failure == .cancelled else {
                    fatalError("Cancellation not reported")
                }
                done.signal()
            }
            client.cancel()
            check(done.wait(timeout: .now() + 2) == .success, "cancel completion")
            check(done.wait(timeout: .now() + .milliseconds(30)) == .timedOut, "cancel called twice")
        }
        print("PASS: loopback pairing exchange, fragmented TCP, wrong proof, malformed/extra/truncated data, timeout and cancellation")
    }
}
