import Foundation
import CryptoKit
import Darwin

// Private pipe worker for one-time enrollment. CryptoKit holds private keys;
// stdout is protocol data for our coordinator, never a diagnostic log.
@main struct EnrollmentCrypto {
    static func opackString(_ text: String) throws -> Data {
        let data = Data(text.utf8)
        guard data.count <= 255 else { throw PairingError.oversized }
        return (data.count <= 32 ? Data([0x40+UInt8(data.count)]) : Data([0x61,UInt8(data.count)]))+data
    }
    static func hostInfo(_ id: String) throws -> Data {
        // Remote Pairing requires software-host link identity fields even for
        // USB setup. Generate a local, unicast identifier for this app identity;
        // these are not copied from the Mac's hardware or any other product.
        let irk = SymmetricKey(size:.bits128).withUnsafeBytes { Data($0) }
        var mac = Array(irk.prefix(6)); mac[0] = (mac[0] & 0xfc) | 2
        let fields = [("accountID",id),("model","Tolkara"),("name","Tolkara"),("remotepairing_serial_number",String(id.prefix(12))),
                      ("btAddr",mac.map { String(format:"%02X",$0) }.joined(separator:":"))]
        var data = Data([0xe0+UInt8(fields.count+2)])
        for (name,value) in fields { data += try opackString(name);data += try opackString(value) }
        data += try opackString("altIRK"); data += Data([0x80])+irk
        data += try opackString("mac"); data += Data([0x76])+Data(mac)
        return data
    }
    static func main() {
        guard isatty(STDIN_FILENO)==0, isatty(STDOUT_FILENO)==0 else { exit(2) }
        var privateKey: Curve25519.Signing.PrivateKey?, shared: SymmetricKey?, host: String?
        var consumed = false
        while let line = readLine() {
            var stage = "input"
            do {
                guard line.utf8.count <= 65536, !consumed,
                      let command = try JSONSerialization.jsonObject(with:Data(line.utf8)) as? [String:String] else { throw PairingError.malformed }
                let response: [String:String]
                if let keyText = command["key"], let key = Data(base64Encoded:keyText), key.count == 64,
                   let id = command["hostIdentifier"], UUID(uuidString:id) != nil, privateKey == nil {
                    let signing = Curve25519.Signing.PrivateKey(), material = SymmetricKey(data:key)
                    let signPrefix = PairingCrypto.derive(material,salt:"Pair-Setup-Controller-Sign-Salt",info:"Pair-Setup-Controller-Sign-Info")
                    let prefix = signPrefix.withUnsafeBytes { Data($0) }
                    let identifier = Data(id.utf8), publicKey = signing.publicKey.rawRepresentation
                    let signature = try signing.signature(for:prefix+identifier+publicKey)
                    let tlv = try PairingTLV.encode([(1,identifier),(3,publicKey),(10,signature),(17,try hostInfo(id))])
                    let encryption = PairingCrypto.derive(material,salt:"Pair-Setup-Encrypt-Salt",info:"Pair-Setup-Encrypt-Info")
                    let sealed = try PairingCrypto.seal(tlv,key:encryption,nonce:PairingCrypto.nonce("PS-Msg05"))
                    privateKey = signing; shared = material; host = id
                    response = ["message5":try PairingTLV.encode([(6,Data([5])),(5,sealed)]).base64EncodedString()]
                } else if let text = command["message6"], let bytes = Data(base64Encoded:text),
                          let device = command["deviceIdentifier"],
                          let signing = privateKey, let shared, let host {
                    consumed = true
                    stage = "message6-state"
                    let outer = try PairingTLV.message(bytes,state:6)
                    guard let ciphertext = outer[5] else { throw PairingError.malformed }
                    stage = "message6-decryption"
                    let encryption = PairingCrypto.derive(shared,salt:"Pair-Setup-Encrypt-Salt",info:"Pair-Setup-Encrypt-Info")
                    let fields = try PairingTLV.decode(PairingCrypto.open(ciphertext,key:encryption,nonce:PairingCrypto.nonce("PS-Msg06")))
                    stage = "device-proof-fields"
                    guard let identifier = fields[1], let key = fields[3], key.count == 32,
                          let signature = fields[10], signature.count == 64 else { throw PairingError.authenticationFailed }
                    // The service hello identifier and the long-term signing
                    // identifier are different namespaces on the real device.
                    // Bind this key through the verified SRP session on the
                    // selected, already trusted USB channel AND its signature.
                    // Pin the signed M6 identifier for subsequent pair-verify.
                    let prefixKey = PairingCrypto.derive(shared,salt:"Pair-Setup-Accessory-Sign-Salt",info:"Pair-Setup-Accessory-Sign-Info")
                    let prefix = prefixKey.withUnsafeBytes { Data($0) }
                    let peerKey = try Curve25519.Signing.PublicKey(rawRepresentation:key)
                    stage = "device-signature"
                    guard peerKey.isValidSignature(signature,for:prefix+identifier+key) else { throw PairingError.authenticationFailed }
                    let identity = try PairingIdentity(hostIdentifier:Data(host.utf8),privateKey:signing.rawRepresentation,
                        publicKey:signing.publicKey.rawRepresentation,peerIdentifier:identifier,peerPublicKey:key)
                    let record = try PairingEnrollment(identity:identity,deviceIdentifier:device,connectionIdentifier:UUID())
                    response = ["enrollment":try record.serialize().base64EncodedString(),"fingerprint":record.fingerprint.map { String(format:"%02x",$0) }.joined()]
                    privateKey = nil
                } else { throw PairingError.invalidState }
                let data = try JSONSerialization.data(withJSONObject:response)
                print(String(decoding:data,as:UTF8.self));fflush(stdout)
            } catch {
                privateKey = nil; shared = nil; host = nil; consumed = true
                print("{\"error\":\"Enrollment cryptographic verification failed\",\"stage\":\"\(stage)\"}");fflush(stdout);exit(1)
            }
        }
    }
}
