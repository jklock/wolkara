import Foundation

// Own bounded codec for the public RemoteXPC wire format. No object handles,
// file transfers, or executable content are accepted by this discovery path.
indirect enum RemoteXPCValue: Equatable {
    case null, bool(Bool), int(Int64), uint(UInt64), double(Double), date(UInt64)
    case data(Data), string(String), uuid(Data), array([RemoteXPCValue]), dictionary([String: RemoteXPCValue])
    var dictionary: [String: RemoteXPCValue]? { if case .dictionary(let d) = self { return d }; return nil }
    var string: String? { if case .string(let s) = self { return s }; return nil }
}
struct RemoteXPCMessage: Equatable {
    let flags: UInt32, identifier: UInt64
    let value: RemoteXPCValue?
}
enum RemoteXPCWire {
    static let maximumPayload = 1_048_576
    static let maximumNodes = 16_384
    private struct Reader {
        let bytes: [UInt8]
        var at = 0, nodes = 0
        mutating func take(_ count: Int, end: Int) throws -> [UInt8] {
            guard count >= 0, at <= end, count <= end - at else { throw PairingError.malformed }
            defer { at += count }; return Array(bytes[at..<(at + count)])
        }
        mutating func number(_ count: Int, end: Int) throws -> UInt64 {
            let b = try take(count, end:end)
            return b.enumerated().reduce(0) { $0 | UInt64($1.element) << ($1.offset * 8) }
        }
        mutating func padding(_ length: Int, end: Int) throws {
            let pad = try take((4 - length % 4) % 4, end:end)
            guard pad.allSatisfy({ $0 == 0 }) else { throw PairingError.malformed }
        }
        mutating func text(_ b: [UInt8]) throws -> String {
            guard b.last == 0, !b.dropLast().contains(0), let s = String(bytes:b.dropLast(),encoding:.utf8) else { throw PairingError.malformed }
            return s
        }
        mutating func object(end: Int, depth: Int) throws -> RemoteXPCValue {
            nodes += 1
            guard depth <= 32, nodes <= RemoteXPCWire.maximumNodes else { throw PairingError.oversized }
            let kind = try number(4,end:end)
            switch kind {
            case 0x1000: return .null
            case 0x2000:
                let n = try number(4,end:end); guard n <= 1 else { throw PairingError.malformed }; return .bool(n == 1)
            case 0x3000: return .int(Int64(bitPattern:try number(8,end:end)))
            case 0x4000: return .uint(try number(8,end:end))
            case 0x5000: return .double(Double(bitPattern:try number(8,end:end)))
            case 0x7000: return .date(try number(8,end:end))
            case 0x8000, 0x9000:
                let length = Int(try number(4,end:end)), b = try take(length,end:end)
                try padding(length,end:end)
                return kind == 0x8000 ? .data(Data(b)) : .string(try text(b))
            case 0xa000: return .uuid(Data(try take(16,end:end)))
            case 0xe000, 0xf000:
                let length = Int(try number(4,end:end))
                guard length >= 4, length <= end - at else { throw PairingError.malformed }
                let limit = at + length, count = Int(try number(4,end:limit))
                guard count <= RemoteXPCWire.maximumNodes - nodes else { throw PairingError.oversized }
                var array: [RemoteXPCValue] = [], dictionary: [String:RemoteXPCValue] = [:]
                for _ in 0..<count {
                    var key = ""
                    if kind == 0xf000 {
                        let start = at
                        while at < limit && bytes[at] != 0 { at += 1 }
                        guard at < limit else { throw PairingError.malformed }
                        at += 1; key = try text(Array(bytes[start..<at])); try padding(at-start,end:limit)
                        guard dictionary[key] == nil else { throw PairingError.malformed }
                    }
                    let value = try object(end:limit,depth:depth+1)
                    if kind == 0xf000 { dictionary[key] = value } else { array.append(value) }
                }
                guard at == limit else { throw PairingError.malformed }
                return kind == 0xf000 ? .dictionary(dictionary) : .array(array)
            default: throw PairingError.malformed
            }
        }
    }
    private struct Writer {
        var bytes = Data(), nodes = 0
        mutating func add(_ b: Data) throws {
            guard b.count <= RemoteXPCWire.maximumPayload - bytes.count else { throw PairingError.oversized }; bytes.append(b)
        }
        mutating func number(_ n: UInt64, count: Int) throws {
            try add(Data((0..<count).map { UInt8(truncatingIfNeeded:n >> ($0 * 8)) }))
        }
        mutating func text(_ s: String, prefixed: Bool) throws {
            guard !s.utf8.contains(0), s.utf8.count < RemoteXPCWire.maximumPayload else { throw PairingError.malformed }
            let d = Data(s.utf8) + Data([0]); if prefixed { try number(UInt64(d.count),count:4) }
            try add(d); try add(Data(repeating:0,count:(4-d.count%4)%4))
        }
        mutating func object(_ value: RemoteXPCValue, depth: Int) throws {
            nodes += 1; guard depth <= 32, nodes <= RemoteXPCWire.maximumNodes else { throw PairingError.oversized }
            func kind(_ value: RemoteXPCValue) -> UInt64 {
                switch value {
                case .null: return 0x1000; case .bool: return 0x2000; case .int: return 0x3000
                case .uint: return 0x4000; case .double: return 0x5000; case .date: return 0x7000
                case .data: return 0x8000; case .string: return 0x9000; case .uuid: return 0xa000
                case .array: return 0xe000; case .dictionary: return 0xf000
                }
            }
            try number(kind(value),count:4)
            switch value {
            case .null: break
            case .bool(let b): try number(b ? 1 : 0,count:4)
            case .int(let n): try number(UInt64(bitPattern:n),count:8)
            case .uint(let n), .date(let n): try number(n,count:8)
            case .double(let d): try number(d.bitPattern,count:8)
            case .uuid(let d): guard d.count == 16 else { throw PairingError.malformed }; try add(d)
            case .data(let d):
                guard d.count <= RemoteXPCWire.maximumPayload else { throw PairingError.oversized }
                try number(UInt64(d.count),count:4); try add(d); try add(Data(repeating:0,count:(4-d.count%4)%4))
            case .string(let s): try text(s,prefixed:true)
            case .array(let values):
                guard values.count <= RemoteXPCWire.maximumNodes - nodes else { throw PairingError.oversized }
                let start = bytes.count; try number(0,count:4); try number(UInt64(values.count),count:4)
                for v in values { try object(v,depth:depth+1) }; patchLength(at:start)
            case .dictionary(let values):
                guard values.count <= RemoteXPCWire.maximumNodes - nodes else { throw PairingError.oversized }
                let start = bytes.count; try number(0,count:4); try number(UInt64(values.count),count:4)
                for k in values.keys.sorted() { try text(k,prefixed:false); try object(values[k]!,depth:depth+1) }; patchLength(at:start)
            }
        }
        mutating func patchLength(at: Int) {
            let count = bytes.count - at - 4
            for i in 0..<4 { bytes[at+i] = UInt8(truncatingIfNeeded:count >> (8*i)) }
        }
    }
    static func encode(_ message: RemoteXPCMessage) throws -> Data {
        var w = Writer()
        if let value = message.value {
            try w.number(0x42133742,count:4); try w.number(5,count:4); try w.object(value,depth:0)
        }
        let payload = w.bytes; w = Writer()
        try w.number(0x29b00b92,count:4); try w.number(UInt64(message.flags),count:4)
        // The wire length excludes the eight-byte message identifier.
        try w.number(UInt64(payload.count),count:8); try w.number(message.identifier,count:8)
        // A full-size payload may exceed Writer's payload-only limit by 24 bytes.
        return w.bytes + payload
    }
    static func decode(_ data: Data) throws -> RemoteXPCMessage {
        guard data.count >= 24, data.count <= maximumPayload+24 else { throw PairingError.oversized }
        var r = Reader(bytes:Array(data)); let end = data.count
        guard try r.number(4,end:end) == 0x29b00b92 else { throw PairingError.malformed }
        let flags = UInt32(try r.number(4,end:end)), length = try r.number(8,end:end), id = try r.number(8,end:end)
        guard length == UInt64(end-24), flags & 1 == 1 else { throw PairingError.malformed }
        var value: RemoteXPCValue?
        if length != 0 {
            guard try r.number(4,end:end) == 0x42133742, try r.number(4,end:end) == 5 else { throw PairingError.malformed }
            value = try r.object(end:end,depth:0)
        }
        guard r.at == end else { throw PairingError.malformed }
        return RemoteXPCMessage(flags:flags,identifier:id,value:value)
    }
}

struct RemoteXPCStream {
    private var bytes = Data(), length: Int?
    private var failed = false
    var hasPartialMessage: Bool { !bytes.isEmpty }
    mutating func consume(_ input: Data) throws -> [RemoteXPCMessage] {
        guard !failed else { throw PairingError.invalidState }
        do {
            guard input.count <= 65_536 else { throw PairingError.oversized }
            var result: [RemoteXPCMessage] = []
            for b in input {
                bytes.append(b)
                if bytes.count == 16 {
                    let n = bytes[8..<16].enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << ($1.offset*8) }
                    guard n <= UInt64(RemoteXPCWire.maximumPayload) else { throw PairingError.oversized }; length = Int(n)+24
                }
                if bytes.count == length {
                    result.append(try RemoteXPCWire.decode(bytes)); bytes = Data(); length = nil
                }
            }
            return result
        } catch { failed = true; bytes = Data(); throw error }
    }
    mutating func finish() throws {
        guard !failed else { throw PairingError.invalidState }; failed = true
        guard bytes.isEmpty else { bytes = Data(); throw PairingError.malformed }
    }
}
