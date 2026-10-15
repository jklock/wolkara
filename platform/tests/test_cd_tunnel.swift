import Foundation
import Network

func expect(_ value: Bool, _ message: String) { if !value { fatalError(message) } }
func reject(_ message: String, _ body: () throws -> Void) {
    do { try body(); fatalError("Accepted: \(message)") } catch {}
}
func configuration(_ edits: [String: Any] = [:], clientEdits: [String: Any] = [:]) throws -> Data {
    var client: [String: Any] = ["address":"fd00::1", "netmask":"ffff:ffff:ffff:ffff::", "mtu":16000]
    client.merge(clientEdits) { _, new in new }
    var root: [String: Any] = ["clientParameters":client, "serverAddress":"fd00::2", "serverRSDPort":58783]
    root.merge(edits) { _, new in new }
    return try JSONSerialization.data(withJSONObject: root)
}
func packet(_ payload: Data, outbound: Bool = false) -> Data {
    var header = Data([0x60,0,0,0,UInt8(payload.count >> 8),UInt8(payload.count & 255),59,64])
    header.append(IPv6Address(outbound ? "fd00::1" : "fd00::2")!.rawValue)
    header.append(IPv6Address(outbound ? "fd00::2" : "fd00::1")!.rawValue)
    return header + payload
}
@main struct TunnelTests {
    static func main() throws {
        let config = try CDTunnelConfiguration(response: configuration(), requestedMTU: 16000)
        expect(config.mtu == 16000 && config.prefixLength == 64 && config.rsdPort == 58783, "configuration")
        for mtu: Any in [1279, 16001, -1, true, "16000", 1400.5] {
            reject("bad MTU") { _ = try CDTunnelConfiguration(response: configuration(clientEdits:["mtu":mtu]), requestedMTU:16000) }
        }
        for port: Any in [0, 65536, -1, true, "58783", 4.5] {
            reject("bad RSD port") { _ = try CDTunnelConfiguration(response:configuration(["serverRSDPort":port]), requestedMTU:16000) }
        }
        for address in ["127.0.0.1", "::ffff:127.0.0.1", "::", "::1", "ff02::1", "fe80::1%en0", "invalid", "fd00::1"] {
            reject("bad server address") { _ = try CDTunnelConfiguration(response:configuration(["serverAddress":address]), requestedMTU:16000) }
        }
        for mask in ["::", "ffff:ffff:ffef::", "255.255.255.0", "ffff::%en0"] {
            reject("invalid mask") { _ = try CDTunnelConfiguration(response:configuration(clientEdits:["netmask":mask]), requestedMTU:16000) }
        }
        reject("oversized response") { _ = try CDTunnelConfiguration(response:Data(repeating:0,count:16385), requestedMTU:16000) }
        reject("invalid offered MTU") { _ = try CDTunnelStream(mtu:64000) }
        let raw = packet(Data([1,2,3])), outbound = packet(Data([4,5]), outbound:true)
        try config.validatePacket(raw, outgoing:false); try config.validatePacket(outbound, outgoing:true)
        reject("wrong direction") { try config.validatePacket(raw, outgoing:true) }
        reject("truncated length") { try config.validatePacket(raw.dropLast(), outgoing:false) }
        var badIP = raw; badIP[0] = 0x40
        reject("IPv4") { try config.validatePacket(badIP, outgoing:false) }
        var badSource = raw; badSource[8] ^= 1
        reject("unrelated endpoint") { try config.validatePacket(badSource, outgoing:false) }
        let header = try PairingFrameDecoder.encode(configuration(), format:.tunnel)
        let joined = header + raw + packet(Data()) + raw
        for chunkSize in [1,2,7,10,39,40,41,128,4096] {
            var stream = try CDTunnelStream(), outputs: [Data] = [], configs = 0
            let request = try stream.begin()
            expect(request.prefix(8) == Data("CDTunnel".utf8), "request framing")
            let bytes = Array(joined)
            for offset in stride(from:0,to:bytes.count,by:chunkSize) {
                for event in try stream.consume(Data(bytes[offset..<min(offset+chunkSize,bytes.count)])) {
                    switch event { case .configured:configs += 1; case .packet(let p):outputs.append(p) }
                }
            }
            try stream.finish()
            expect(configs == 1 && outputs == [raw,packet(Data()),raw], "segmented/coalesced stream")
            reject("EOF terminal") { _ = try stream.consume(raw) }
        }
        for end in 0..<header.count {
            var stream = try CDTunnelStream(); _ = try stream.begin()
            _ = try stream.consume(header.prefix(end))
            reject("truncated handshake") { try stream.finish() }
        }
        for end in 1..<raw.count {
            var stream = try CDTunnelStream(); _ = try stream.begin(); _ = try stream.consume(header + raw.prefix(end))
            expect(stream.hasPartialPacket, "partial packet tracking")
            reject("truncated packet") { try stream.finish() }
        }
        var oversized = Data([0x60,0,0,0,255,255])
        for invalid in [badIP, oversized] {
            var stream = try CDTunnelStream(); _ = try stream.begin(); _ = try stream.consume(header)
            reject("invalid packet framing") { _ = try stream.consume(invalid) }
            reject("stream poisoned") { _ = try stream.consume(raw) }
        }
        // A real device sends multicast control traffic immediately after the
        // configuration. Its presence must neither reach TCP nor poison framing.
        var multicast = packet(Data(repeating:0,count:76))
        multicast[6] = 0 // hop-by-hop IPv6 control traffic
        multicast.replaceSubrange(8..<24,with:IPv6Address("fe80::1234")!.rawValue)
        multicast.replaceSubrange(24..<40,with:IPv6Address("ff02::16")!.rawValue)
        for chunkSize in [1,7,40,4096] {
            var filtered = try CDTunnelStream(); _ = try filtered.begin()
            let bytes = Array(header + multicast + badSource + raw)
            var packets: [Data] = []
            for offset in stride(from:0,to:bytes.count,by:chunkSize) {
                for event in try filtered.consume(Data(bytes[offset..<min(offset+chunkSize,bytes.count)])) {
                    if case .packet(let value) = event { packets.append(value) }
                }
            }
            try filtered.finish()
            expect(packets == [raw], "unrelated tunnel traffic discarded without losing our stream")
        }
        oversized = Data(repeating:0,count:65_537)
        var stream = try CDTunnelStream(); _ = try stream.begin()
        reject("oversized chunk") { _ = try stream.consume(oversized) }
        print("PASS: CDTunnel negotiation, IPv6 endpoints/lengths/MTU, fragmented and coalesced streams, truncation and terminal errors")
    }
}
