import Foundation
private func check(_ value: Bool, _ message: String) { if !value { fatalError(message) } }
private func reject(_ label: String, _ work: () throws -> Void) {
    do { try work(); fatalError("Accepted: \(label)") } catch {}
}
private func hex(_ text: String) -> Data {
    let chars = Array(text); return Data(stride(from:0,to:chars.count,by:2).map { UInt8(String(chars[$0...$0+1]),radix:16)! })
}
@main struct XPCTests {
    static func main() throws {
        // Literal wire vectors, including the length excluding message ID and
        // the collection byte length preceding its element count.
        let empty = hex("920bb0290100000014000000000000000000000000000000423713420500000000f000000400000000000000")
        let value = RemoteXPCMessage(flags:1,identifier:0,value:.dictionary([:]))
        check(try RemoteXPCWire.decode(empty) == value, "empty dictionary fixture")
        check(try RemoteXPCWire.encode(value) == empty, "empty dictionary wire")
        let typed: RemoteXPCValue = .dictionary([
            "n":.null,"b":.bool(true),"i":.int(Int64.min),"u":.uint(UInt64.max),"f":.double(-1.25),
            "date":.date(42),"uuid":.uuid(Data(0..<16)),"data":.data(Data([1,2,3])),
            "s":.string("héllo 🌍"),"array":.array([.bool(false),.dictionary([:]),.string("")])])
        let message = RemoteXPCMessage(flags:0x101,identifier:UInt64.max,value:typed)
        let encoded = try RemoteXPCWire.encode(message)
        check(try RemoteXPCWire.decode(encoded) == message, "all supported types")
        let ack = try RemoteXPCWire.encode(RemoteXPCMessage(flags:0x400001,identifier:0,value:nil))
        for split in 0...encoded.count {
            var stream = RemoteXPCStream()
            let a = try stream.consume(encoded.prefix(split)), b = try stream.consume(encoded.dropFirst(split)+ack)
            check(a+b == [message,RemoteXPCMessage(flags:0x400001,identifier:0,value:nil)], "all splits and coalescing")
            try stream.finish(); reject("feed after finish") { _ = try stream.consume(Data()) }
        }
        for i in 1..<encoded.count {
            var stream = RemoteXPCStream(); _ = try stream.consume(encoded.prefix(i))
            reject("truncation") { try stream.finish() }
        }
        for i in [0,8,24,28,32,36,40] {
            var bad = empty; bad[i] ^= 0x80
            reject("malformed literal field") { _ = try RemoteXPCWire.decode(bad) }
        }
        var bad = empty; bad[8...15] = Data(repeating:255,count:8)
        var stream = RemoteXPCStream()
        reject("oversize stream") { _ = try stream.consume(bad) }
        reject("poison") { _ = try stream.consume(empty) }
        reject("invalid UTF8") {
            _ = try RemoteXPCWire.decode(hex("920bb029010100001400000000000000000000000000000042371342050000000090000002000000ff000000"))
        }
        var deep: RemoteXPCValue = .null
        for _ in 0..<34 { deep = .array([deep]) }
        reject("nesting encode") { _ = try RemoteXPCWire.encode(RemoteXPCMessage(flags:1,identifier:0,value:deep)) }
        reject("node budget") { _ = try RemoteXPCWire.encode(RemoteXPCMessage(flags:1,identifier:0,value:.array(Array(repeating:.null,count:16384)))) }
        reject("embedded NUL") { _ = try RemoteXPCWire.encode(RemoteXPCMessage(flags:1,identifier:0,value:.string("a\0b"))) }
        reject("wrong UUID size") { _ = try RemoteXPCWire.encode(RemoteXPCMessage(flags:1,identifier:0,value:.uuid(Data())) ) }
        // Reproducible bounded malformed-input coverage under ASan.
        var seed: UInt64 = 0x9f283013
        for _ in 0..<10000 {
            seed = seed &* 6364136223846793005 &+ 1
            var data = encoded; let at = Int(seed % UInt64(data.count))
            data[at] ^= UInt8(truncatingIfNeeded:seed >> 32) | 1
            _ = try? RemoteXPCWire.decode(data)
        }
        print("RemoteXPC codec: literals, types, segmentation, limits, truncation and malformed inputs passed")
    }
}
