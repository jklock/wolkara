import Foundation
import Security
import CryptoKit

protocol PairingKeychainBackend {
    func add(_ attributes: [String:Any]) -> OSStatus
    func copy(_ query: [String:Any]) -> (OSStatus,Any?)
    func delete(_ query: [String:Any]) -> OSStatus
}
struct SystemPairingKeychain: PairingKeychainBackend {
    func add(_ attributes: [String:Any]) -> OSStatus { SecItemAdd(attributes as CFDictionary,nil) }
    func copy(_ query: [String:Any]) -> (OSStatus,Any?) {
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary,&value)
        return (status,value)
    }
    func delete(_ query: [String:Any]) -> OSStatus { SecItemDelete(query as CFDictionary) }
}

// Exact per-device queries in our dedicated access group; never enumerate the
// user's keychain. No file fallback, synchronization or credential logging.
// Immutable enrollment means insert races cannot silently replace trust pins.
final class PairingKeychain {
    enum Failure: Error { case configuration, conflict, corruptRecord, keychain(OSStatus) }
    private let group: String
    private let backend: PairingKeychainBackend
    static let service = "local.tolkara.pairing.enrollment.v1"
    init(accessGroup: String, backend: PairingKeychainBackend = SystemPairingKeychain()) throws {
        guard accessGroup.count <= 256, accessGroup.contains("."),
              accessGroup.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 46 }) else { throw Failure.configuration }
        group = accessGroup; self.backend = backend
    }
    convenience init(bundle: Bundle = .main) throws {
        guard let group = bundle.object(forInfoDictionaryKey:"TKPairingKeychainGroup") as? String else { throw Failure.configuration }
        try self.init(accessGroup:group)
    }
    private func query(_ identifier: String) throws -> [String:Any] {
        guard !identifier.isEmpty, identifier.utf8.count <= 1024,
              !identifier.unicodeScalars.contains(where:{ CharacterSet.controlCharacters.contains($0) }) else { throw PairingError.malformed }
        let account = SHA256.hash(data:Data(identifier.utf8)).map { String(format:"%02x",$0) }.joined()
        return [kSecClass as String:kSecClassGenericPassword,
            kSecAttrService as String:Self.service,kSecAttrAccount as String:account,
            kSecAttrAccessGroup as String:group,kSecAttrSynchronizable as String:false,
            kSecUseDataProtectionKeychain as String:true]
    }
    func load(deviceIdentifier: String) throws -> PairingEnrollment? {
        var q = try query(deviceIdentifier)
        q[kSecReturnData as String] = true; q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status,value) = backend.copy(q)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Failure.keychain(status) }
        guard let attributes = value as? [String:Any], let bytes = attributes[kSecValueData as String] as? Data,
              attributes[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String,
              attributes[kSecAttrAccessGroup as String] as? String == group else { throw Failure.corruptRecord }
        let record: PairingEnrollment
        do { record = try PairingEnrollment(untrustedData:bytes) } catch { throw Failure.corruptRecord }
        guard record.deviceIdentifier == deviceIdentifier else { throw Failure.corruptRecord }
        return record
    }
    // Caller supplies a record from authenticated enrollment or approved import.
    // Duplicate identical inserts are safe; changing a pin requires an explicit
    // forget operation by the enrollment UI before this method can succeed.
    func insertTrusted(_ record: PairingEnrollment) throws {
        var q = try query(record.deviceIdentifier)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        q[kSecValueData as String] = try record.serialize()
        let status = backend.add(q)
        if status == errSecDuplicateItem {
            guard let existing = try load(deviceIdentifier:record.deviceIdentifier), existing.fingerprint == record.fingerprint else { throw Failure.conflict }
        } else if status != errSecSuccess { throw Failure.keychain(status) }
    }
    func forget(deviceIdentifier: String) throws {
        let status = backend.delete(try query(deviceIdentifier))
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.keychain(status) }
    }
}
