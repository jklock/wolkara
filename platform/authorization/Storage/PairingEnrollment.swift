import Foundation
import CryptoKit

// Parsing is not enrollment or approval. A caller may persist this record only
// after authenticated enrollment or an explicitly trusted import. The RSD device
// identifier is bound separately from the Remote Pairing peer identifier.
struct PairingEnrollment {
    static let maximumSize = 16_384
    let identity: PairingIdentity
    let deviceIdentifier: String
    let connectionIdentifier: UUID
    init(identity: PairingIdentity, deviceIdentifier: String, connectionIdentifier: UUID) throws {
        guard !deviceIdentifier.isEmpty, deviceIdentifier.utf8.count <= 1024,
              !deviceIdentifier.unicodeScalars.contains(where:{ CharacterSet.controlCharacters.contains($0) }) else { throw PairingError.malformed }
        self.identity = identity; self.deviceIdentifier = deviceIdentifier; self.connectionIdentifier = connectionIdentifier
    }
    init(untrustedData: Data) throws {
        guard untrustedData.count <= Self.maximumSize else { throw PairingError.oversized }
        let object: Any
        do { object = try PropertyListSerialization.propertyList(from:untrustedData,options:[],format:nil) }
        catch { throw PairingError.malformed }
        guard let d = object as? [String:Any], d.count == 4,
              d["format"] as? String == "tolkara-enrollment-v1",
              let data = d["identity"] as? Data, let identifier = d["deviceIdentifier"] as? String,
              let uuidString = d["connectionIdentifier"] as? String, let uuid = UUID(uuidString:uuidString) else { throw PairingError.malformed }
        try self.init(identity:PairingIdentity(serialized:data),deviceIdentifier:identifier,connectionIdentifier:uuid)
    }
    func serialize() throws -> Data {
        let data = try PropertyListSerialization.data(fromPropertyList:["format":"tolkara-enrollment-v1",
            "identity":identity.serialize(),"deviceIdentifier":deviceIdentifier,
            "connectionIdentifier":connectionIdentifier.uuidString],format:.binary,options:0)
        guard data.count <= Self.maximumSize else { throw PairingError.oversized }; return data
    }
    // Public identity fingerprint: a new host key, pinned device key, identifier
    // or connection UUID cannot silently replace an already enrolled device.
    var fingerprint: Data {
        var bytes = Data("tolkara-enrollment-fingerprint-v1".utf8)
        for field in [Data(deviceIdentifier.utf8),Data(connectionIdentifier.uuidString.utf8),identity.hostIdentifier,
                      identity.signingKey.publicKey.rawRepresentation,identity.peerIdentifier,identity.peerPublicKey.rawRepresentation] {
            let n = UInt32(field.count)
            bytes.append(contentsOf:[UInt8(truncatingIfNeeded:n>>24),UInt8(truncatingIfNeeded:n>>16),UInt8(truncatingIfNeeded:n>>8),UInt8(truncatingIfNeeded:n)])
            bytes.append(field)
        }
        return Data(SHA256.hash(data:bytes))
    }
}
