import Foundation

// Original implementation of the documented wire formats. These types neither
// open sockets nor authenticate a peer. No payload or key should be logged.
enum PairingError: Error, Equatable {
    case malformed, oversized, invalidState, invalidKey, authenticationFailed, exhausted
}

enum PairingTLV {
    static let limit = 16_384
    static func encode(_ entries: [(UInt8, Data)]) throws -> Data {
        var result = Data()
        var seen = Set<UInt8>()
        for (type, value) in entries {
            guard seen.insert(type).inserted else { throw PairingError.malformed }
            guard value.count <= limit else { throw PairingError.oversized }
            let fragments = max(1, (value.count + 254) / 255)
            guard result.count + value.count + fragments * 2 <= limit else { throw PairingError.oversized }
            let bytes = Array(value)
            if bytes.isEmpty { result.append(contentsOf: [type, 0]) }
            var offset = 0
            while offset < bytes.count {
                let count = min(255, bytes.count - offset)
                result.append(contentsOf: [type, UInt8(count)])
                result.append(contentsOf: bytes[offset..<offset + count])
                offset += count
            }
        }
        return result
    }
    static func decode(_ data: Data) throws -> [UInt8: Data] {
        guard data.count <= limit else { throw PairingError.oversized }
        let bytes = Array(data)
        var fields: [UInt8: Data] = [:], offset = 0
        var previous: UInt8?
        while offset < bytes.count {
            guard bytes.count - offset >= 2 else { throw PairingError.malformed }
            let type = bytes[offset], count = Int(bytes[offset + 1]); offset += 2
            guard count <= bytes.count - offset else { throw PairingError.malformed }
            // Reordered duplicate fields are ambiguous. Adjacent fragments may
            // be 254 or 255 bytes in existing implementations; accept both.
            guard fields[type] == nil || previous == type else { throw PairingError.malformed }
            fields[type, default: Data()].append(contentsOf: bytes[offset..<offset + count])
            previous = type; offset += count
        }
        return fields
    }
    static func message(_ data: Data, state: UInt8) throws -> [UInt8: Data] {
        let fields = try decode(data)
        guard fields[7] == nil else { throw PairingError.authenticationFailed }
        guard fields[6] == Data([state]) else { throw PairingError.invalidState }
        return fields
    }
}

struct PairingFrameDecoder {
    enum Format { case pairing, tunnel }
    private let magic: [UInt8]
    private var header = Data(), body = Data()
    private var expected: Int?
    private var failed = false
    init(_ format: Format = .pairing) {
        magic = Array((format == .pairing ? "RPPairing" : "CDTunnel").utf8)
    }
    static func encode(_ payload: Data, format: Format = .pairing) throws -> Data {
        guard !payload.isEmpty, payload.count <= 65_535 else { throw PairingError.oversized }
        var wire = Data((format == .pairing ? "RPPairing" : "CDTunnel").utf8)
        wire.append(contentsOf: [UInt8(payload.count >> 8), UInt8(payload.count & 255)])
        wire.append(payload)
        return wire
    }
    // Byte streaming retains at most one 64KB message. Invalid magic/length is
    // terminal: callers must close the connection, not scan secrets for a header.
    mutating func consume(_ byte: UInt8) throws -> Data? {
        guard !failed else { throw PairingError.invalidState }
        if let size = expected {
            body.append(byte)
            if body.count == size {
                let result = body
                body = Data(); header = Data(); expected = nil
                return result
            }
        } else {
            if header.count < magic.count && byte != magic[header.count] {
                failed = true; throw PairingError.malformed
            }
            header.append(byte)
            if header.count == magic.count + 2 {
                let size = Int(header[magic.count]) * 256 + Int(header[magic.count + 1])
                guard size > 0 else { failed = true; throw PairingError.malformed }
                expected = size
            }
        }
        return nil
    }
    mutating func finish() throws {
        guard !failed, header.isEmpty, expected == nil else {
            failed = true; body = Data(); throw PairingError.malformed
        }
    }
}
