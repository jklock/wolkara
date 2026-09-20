import Foundation

// Own C RSP codec wrapped with bounded storage. Payloads may contain host memory
// and must never be logged, even in a failed protocol exchange.
final class DebugProtocolWire {
    enum Event { case packet(Data), ack, nack, badChecksum }
    static let capacity = 32768
    private let storage = UnsafeMutablePointer<UInt8>.allocate(capacity:capacity)
    private var parser = DWParser()
    init() { dw_init(&parser,storage,Self.capacity) }
    deinit { storage.deallocate() }
    func feed(_ byte: UInt8) throws -> Event? {
        switch dw_feed(&parser,byte) {
        case DW_MORE:return nil
        case DW_PACKET:return .packet(Data(bytes:storage,count:parser.length))
        case DW_ACK:return .ack
        case DW_NACK:return .nack
        case DW_BAD_CHECKSUM:return .badChecksum
        default:throw PairingError.malformed
        }
    }
    static func encode(_ command: String) throws -> Data {
        let bytes = Data(command.utf8)
        guard bytes.count <= capacity else { throw PairingError.oversized }
        var output = Data(count:bytes.count*2+4)
        let count = output.withUnsafeMutableBytes { destination in
            bytes.withUnsafeBytes { source in dw_encode(source.baseAddress,source.count,destination.baseAddress,destination.count) }
        }
        guard count > 0 else { throw PairingError.malformed }
        output.count = count; return output
    }
    static func unhex(_ text: String, count: Int) throws -> Data {
        let b = Array(text.utf8)
        guard count >= 0, count <= capacity/2, b.count == count*2 else { throw PairingError.malformed }
        func digit(_ b: UInt8) -> UInt8? {
            if b >= 48 && b <= 57 { return b-48 }; if b >= 65 && b <= 70 { return b-55 }; if b >= 97 && b <= 102 { return b-87 }; return nil
        }
        var result = Data(capacity:count)
        for at in stride(from:0,to:b.count,by:2) {
            guard let high = digit(b[at]), let low = digit(b[at+1]) else { throw PairingError.malformed }
            result.append(high<<4 | low)
        }
        return result
    }
    static func number(_ text: String?) throws -> UInt64 {
        guard let text, !text.isEmpty, text.utf8.count <= 16,
              text.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
              let value = UInt64(text,radix:16) else { throw PairingError.malformed }; return value
    }
    static func fields(_ text: String) throws -> [String:String] {
        guard text.utf8.count <= capacity else { throw PairingError.oversized }
        var fields: [String:String] = [:]
        for pair in text.split(separator:";",omittingEmptySubsequences:true) {
            guard fields.count < 128, let separator = pair.firstIndex(of:":") else { throw PairingError.malformed }
            let key = String(pair[..<separator]), value = String(pair[pair.index(after:separator)...])
            guard !key.isEmpty, fields[key] == nil else { throw PairingError.malformed }; fields[key] = value
        }
        return fields
    }
}
