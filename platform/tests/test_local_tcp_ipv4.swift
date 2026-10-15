import Foundation
import Network

@main struct LocalIPv4Tests {
    static func main() throws {
        let codec = LocalTCPIPv4(clientPort:55000,servicePort:49152)
        // Independently generated Python struct/checksum fixture, odd payload.
        let hex = Array("4500002b00004000400626bd0a0700020a070001c000d6d8000003e90000006550188000bc2e0000616263")
        var fixture = Data()
        for i in stride(from:0,to:hex.count,by:2) { fixture.append(UInt8(String(hex[i...i+1]),radix:16)!) }
        let packet = try codec.incoming(fixture)
        let decoded = try TunnelTCPCodec.decode(packet,endpoints:codec.endpoints,mtu:1500)
        precondition(decoded.payload == Data("abc".utf8) && decoded.sequence == 1001 && decoded.acknowledgement == 101)
        for i in fixture.indices {
            var bad = fixture; bad[i] ^= 1
            do { _ = try codec.incoming(bad); fatalError("Accepted corrupted byte \(i)") } catch {}
        }
        for i in 0..<fixture.count {
            do { _ = try codec.incoming(fixture.prefix(i)); fatalError("Accepted truncated IPv4") } catch {}
        }
        // A valid IPv4 checksum is not permission to accept fragments.
        var fragment = fixture; fragment[6] = 0x20; fragment[10] = 0; fragment[11] = 0
        let sum = TunnelTCPCodec.checksum(Array(fragment.prefix(20)))
        fragment[10] = UInt8(sum>>8); fragment[11] = UInt8(sum&255)
        do { _ = try codec.incoming(fragment); fatalError("Accepted IP fragment") } catch {}
        let outgoing = TunnelTCPCodec.encode(decoded,endpoints:codec.endpoints)
        let ipv4 = try codec.outgoing(outgoing)
        precondition(ipv4.count == fixture.count && Array(ipv4[12..<16]) == LocalTCPIPv4.client)
        precondition(TunnelTCPCodec.checksum(Array(ipv4.prefix(20))) == 0)
        let tcp = Array(ipv4.dropFirst(20))
        let pseudo = LocalTCPIPv4.client+LocalTCPIPv4.device+[0,6,0,UInt8(tcp.count)]
        precondition(TunnelTCPCodec.checksum(pseudo+tcp) == 0)
        precondition(!codec.matches(ipv4))
        print("Local IPv4 adapter: independent fixture, checksum, truncation, fragmentation and direction checks passed.")
    }
}
