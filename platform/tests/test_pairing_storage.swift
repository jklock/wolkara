import Foundation
import CryptoKit
import Security
private func check(_ value: Bool, _ text: String) { if !value { fatalError(text) } }
private func reject(_ block: () throws -> Void) { do { try block(); fatalError("unexpected acceptance") } catch {} }
private final class Backend: PairingKeychainBackend {
    var records: [String:[String:Any]] = [:], queries: [[String:Any]] = []
    var forced: OSStatus?
    func key(_ q: [String:Any]) -> String {
        check(q[kSecClass as String] as? String == kSecClassGenericPassword as String,"class")
        check(q[kSecAttrService as String] as? String == PairingKeychain.service,"only own service")
        check(q[kSecAttrAccessGroup as String] as? String == "TEAM.local.fixture","explicit group")
        check(q[kSecAttrSynchronizable as String] as? Bool == false,"no sync")
        check(q[kSecUseDataProtectionKeychain as String] as? Bool == true,"data protection")
        let account = q[kSecAttrAccount as String] as! String
        check(account.count == 64 && account.allSatisfy({ $0.isHexDigit }),"hashed per-device account")
        return account
    }
    func add(_ q: [String:Any]) -> OSStatus {
        queries.append(q); let k = key(q)
        if let forced { return forced }
        guard records[k] == nil else { return errSecDuplicateItem }
        check(q[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String,"unlock/device binding")
        records[k] = q; return errSecSuccess
    }
    func copy(_ q: [String:Any]) -> (OSStatus,Any?) {
        queries.append(q); let k = key(q)
        check(q[kSecMatchLimit as String] as? String == kSecMatchLimitOne as String,"no enumeration")
        check(q[kSecReturnData as String] as? Bool == true && q[kSecReturnAttributes as String] as? Bool == true,"verify data and metadata")
        if let forced { return (forced,nil) }
        guard let record = records[k] else { return (errSecItemNotFound,nil) }; return (errSecSuccess,record)
    }
    func delete(_ q: [String:Any]) -> OSStatus {
        queries.append(q); let k = key(q)
        if let forced { return forced }
        return records.removeValue(forKey:k) == nil ? errSecItemNotFound : errSecSuccess
    }
}
private func fixture(device: String = "device-one", changed: Bool = false) throws -> PairingEnrollment {
    let h = try Curve25519.Signing.PrivateKey(rawRepresentation:Data(repeating:1,count:32))
    let p = try Curve25519.Signing.PrivateKey(rawRepresentation:Data(repeating:changed ? 3 : 2,count:32))
    let identity = try PairingIdentity(hostIdentifier:Data("host-id".utf8),privateKey:h.rawRepresentation,
        publicKey:h.publicKey.rawRepresentation,peerIdentifier:Data("peer-id".utf8),peerPublicKey:p.publicKey.rawRepresentation)
    return try PairingEnrollment(identity:identity,deviceIdentifier:device,connectionIdentifier:UUID(uuidString:"00112233-4455-6677-8899-aabbccddeeff")!)
}
@main struct StorageTests {
    static func main() throws {
        let backend = Backend(), store = try PairingKeychain(accessGroup:"TEAM.local.fixture",backend:backend)
        let first = try fixture(), other = try fixture(device:"device-two"), changed = try fixture(changed:true)
        let serialized = try first.serialize(), roundtrip = try PairingEnrollment(untrustedData:serialized)
        check(roundtrip.fingerprint == first.fingerprint,"envelope roundtrip")
        check(roundtrip.identity.signingKey.rawRepresentation == first.identity.signingKey.rawRepresentation,"private key roundtrip")
        check(try store.load(deviceIdentifier:first.deviceIdentifier) == nil,"missing record")
        try store.insertTrusted(first); try store.insertTrusted(first); try store.insertTrusted(other)
        check(backend.records.count == 2,"idempotent inserts and per-device isolation")
        reject { try store.insertTrusted(changed) }
        check(try store.load(deviceIdentifier:first.deviceIdentifier)?.fingerprint == first.fingerprint,"conflict preserves original")
        let saved = backend.records
        let key = backend.records.first(where:{ ($0.value[kSecValueData as String] as? Data).flatMap { try? PairingEnrollment(untrustedData:$0) }?.deviceIdentifier == first.deviceIdentifier })!.key
        backend.records[key]![kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        reject { _ = try store.load(deviceIdentifier:first.deviceIdentifier) }
        backend.records = saved
        backend.records[key]![kSecValueData as String] = try other.serialize()
        reject { _ = try store.load(deviceIdentifier:first.deviceIdentifier) }
        backend.records = saved
        backend.records[key]![kSecValueData as String] = Data(repeating:0,count:16385)
        reject { _ = try store.load(deviceIdentifier:first.deviceIdentifier) }
        backend.records = saved
        for status in [errSecInteractionNotAllowed,errSecMissingEntitlement,errSecNotAvailable,errSecAuthFailed] {
            backend.forced = status
            reject { _ = try store.load(deviceIdentifier:first.deviceIdentifier) }
            reject { try store.insertTrusted(first) }
            reject { try store.forget(deviceIdentifier:first.deviceIdentifier) }
        }
        backend.forced = nil
        try store.forget(deviceIdentifier:first.deviceIdentifier); try store.forget(deviceIdentifier:first.deviceIdentifier)
        check(try store.load(deviceIdentifier:first.deviceIdentifier) == nil,"explicit removal")
        check(try store.load(deviceIdentifier:other.deviceIdentifier) != nil,"removal does not affect another device")
        try store.insertTrusted(changed)
        check(try store.load(deviceIdentifier:first.deviceIdentifier)?.fingerprint == changed.fingerprint,"replacement requires explicit removal")
        for group in ["", "*", "$(AppIdentifierPrefix)local.fixture", "TEAM.local.*", "TEAM local.fixture"] {
            reject { _ = try PairingKeychain(accessGroup:group,backend:backend) }
        }
        for identifier in ["", "bad\0id", "bad\nid", String(repeating:"a",count:1025)] {
            reject { _ = try store.load(deviceIdentifier:identifier) }
            reject { _ = try fixture(device:identifier) }
        }
        var envelope = try PropertyListSerialization.propertyList(from:serialized,format:nil) as! [String:Any]
        envelope["approved"] = true
        reject { _ = try PairingEnrollment(untrustedData:PropertyListSerialization.data(fromPropertyList:envelope,format:.binary,options:0)) }
        reject { _ = try PairingEnrollment(untrustedData:Data(repeating:0,count:16385)) }
        print("Pairing storage: envelope bounds, exact protected queries, immutable pins, device isolation and failure propagation passed")
    }
}
