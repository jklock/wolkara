import Foundation
import CryptoKit

@main struct EnrollmentCryptoTests {
    static func run(corrupt: Bool) throws {
        let child = Process(), input = Pipe(), output = Pipe()
        child.executableURL = URL(fileURLWithPath:"build/enrollment_crypto")
        child.standardInput = input; child.standardOutput = output; child.standardError = FileHandle.nullDevice
        try child.run()
        defer { try? input.fileHandleForWriting.close(); if child.isRunning { child.terminate() };child.waitUntilExit() }
        func exchange(_ fields: [String:String]) throws -> [String:String] {
            try input.fileHandleForWriting.write(contentsOf:JSONSerialization.data(withJSONObject:fields)+Data([10]))
            var line = Data()
            while true {
                guard let byte = try output.fileHandleForReading.read(upToCount:1), !byte.isEmpty else { throw PairingError.malformed }
                if byte[0] == 10 { break };line += byte
                guard line.count <= 65536 else { throw PairingError.oversized }
            }
            return try JSONSerialization.jsonObject(with:line) as! [String:String]
        }
        let rawKey = Data(repeating:0x37,count:64), key = SymmetricKey(data:rawKey)
        let host = "00112233-4455-6677-8899-AABBCCDDEEFF", peer = Data("synthetic-peer".utf8)
        let encryption = PairingCrypto.derive(key,salt:"Pair-Setup-Encrypt-Salt",info:"Pair-Setup-Encrypt-Info")
        let first = try exchange(["key":rawKey.base64EncodedString(),"hostIdentifier":host])
        let m5 = try PairingTLV.message(Data(base64Encoded:first["message5"]!)!,state:5)
        let fields = try PairingTLV.decode(PairingCrypto.open(m5[5]!,key:encryption,nonce:PairingCrypto.nonce("PS-Msg05")))
        let hostPublic = try Curve25519.Signing.PublicKey(rawRepresentation:fields[3]!)
        let prefix = PairingCrypto.derive(key,salt:"Pair-Setup-Controller-Sign-Salt",info:"Pair-Setup-Controller-Sign-Info").withUnsafeBytes { Data($0) }
        precondition(fields[1] == Data(host.utf8) && hostPublic.isValidSignature(fields[10]!,for:prefix+fields[1]!+fields[3]!))
        let peerKey = try Curve25519.Signing.PrivateKey(rawRepresentation:Data(repeating:0x52,count:32))
        let accessory = PairingCrypto.derive(key,salt:"Pair-Setup-Accessory-Sign-Salt",info:"Pair-Setup-Accessory-Sign-Info").withUnsafeBytes { Data($0) }
        var signature = try peerKey.signature(for:accessory+peer+peerKey.publicKey.rawRepresentation)
        if corrupt { signature[0] ^= 1 }
        let proof = try PairingTLV.encode([(1,peer),(3,peerKey.publicKey.rawRepresentation),(10,signature)])
        let sealed = try PairingCrypto.seal(proof,key:encryption,nonce:PairingCrypto.nonce("PS-Msg06"))
        let m6 = try PairingTLV.encode([(6,Data([6])),(5,sealed)])
        let result = try exchange(["message6":m6.base64EncodedString(),"deviceIdentifier":"synthetic-udid"])
        if corrupt { precondition(result["error"] != nil && result["enrollment"] == nil) }
        else {
            let enrollment = try PairingEnrollment(untrustedData:Data(base64Encoded:result["enrollment"]!)!)
            precondition(enrollment.identity.peerPublicKey.rawRepresentation == peerKey.publicKey.rawRepresentation)
            precondition(enrollment.identity.peerIdentifier == peer)
            precondition(enrollment.identity.signingKey.publicKey.rawRepresentation == hostPublic.rawRepresentation)
            precondition(enrollment.deviceIdentifier == "synthetic-udid")
        }
    }
    static func main() throws {
        try run(corrupt:false); try run(corrupt:true)
        print("Enrollment CryptoKit worker: host proof, pinned peer identity export and invalid signature rejection passed.")
    }
}
