import UIKit
import CryptoKit
import Security

// Simulator-only test app. These are public, deterministic fixture keys; never
// use them for enrollment. Reports contain only pass/fail and OSStatus values.
@main final class StorageProbe: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name:"Storage probe",sessionRole:session.role)
        configuration.delegateClass = StorageProbeScene.self
        return configuration
    }
    static func fixture(changed: Bool = false) throws -> PairingEnrollment {
        let host = try Curve25519.Signing.PrivateKey(rawRepresentation:Data(repeating:0x21,count:32))
        let peer = try Curve25519.Signing.PrivateKey(rawRepresentation:Data(repeating:changed ? 0x44 : 0x32,count:32))
        let identity = try PairingIdentity(hostIdentifier:Data("synthetic-host".utf8),privateKey:host.rawRepresentation,
            publicKey:host.publicKey.rawRepresentation,peerIdentifier:Data("synthetic-peer".utf8),peerPublicKey:peer.publicKey.rawRepresentation)
        return try PairingEnrollment(identity:identity,deviceIdentifier:"synthetic-storage-probe-v1",
            connectionIdentifier:UUID(uuidString:"00112233-4455-6677-8899-aabbccddeeff")!)
    }
    static func probe() throws -> String {
        let store = try PairingKeychain(), record = try fixture()
        if CommandLine.arguments.contains("--storage-write") {
            try store.forget(deviceIdentifier:record.deviceIdentifier)
            try store.insertTrusted(record); try store.insertTrusted(record)
            do { try store.insertTrusted(fixture(changed:true)); return "FAIL: trust pin replaced\n" }
            catch PairingKeychain.Failure.conflict {}
            guard try store.load(deviceIdentifier:record.deviceIdentifier)?.fingerprint == record.fingerprint else { return "FAIL: readback\n" }
            return "PASS: synthetic record inserted, duplicate accepted, conflicting pin rejected, protected readback matched\n"
        }
        if CommandLine.arguments.contains("--storage-read") {
            guard try store.load(deviceIdentifier:record.deviceIdentifier)?.fingerprint == record.fingerprint else { return "FAIL: cross-process readback\n" }
            return "PASS: entitled process read the persisted synthetic record\n"
        }
        if CommandLine.arguments.contains("--storage-delete") {
            try store.forget(deviceIdentifier:record.deviceIdentifier)
            guard try store.load(deviceIdentifier:record.deviceIdentifier) == nil else { return "FAIL: deletion\n" }
            return "PASS: synthetic record deleted and absent\n"
        }
        if CommandLine.arguments.contains("--storage-empty") {
            guard try store.load(deviceIdentifier:record.deviceIdentifier) == nil else { return "FAIL: deleted record remained visible\n" }
            return "PASS: original writer observes deletion by the shared app\n"
        }
        if CommandLine.arguments.contains("--storage-denied") {
            do { _ = try store.load(deviceIdentifier:record.deviceIdentifier); return "FAIL: missing shared entitlement was accepted\n" }
            catch PairingKeychain.Failure.keychain(let status) where status == errSecMissingEntitlement {
                return "PASS: app without the shared entitlement was denied (-34018)\n"
            }
        }
        return "FAIL: no probe mode\n"
    }
}

final class StorageProbeScene: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene:scene), controller = UIViewController()
        let label = UILabel(); label.numberOfLines = 0; label.textAlignment = .center
        label.text = "Testing synthetic pairing storage"; controller.view = label
        window.rootViewController = controller; window.makeKeyAndVisible(); self.window = window
        DispatchQueue.global(qos:.userInitiated).async {
            let output: String
            do { output = try StorageProbe.probe() }
            catch { output = "FAIL: \(error)\n" }
            let directory = FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0]
            try? Data(output.utf8).write(to:directory.appendingPathComponent("storage-probe.txt"),options:.atomic)
            DispatchQueue.main.async { label.text = output }
        }
    }
}
