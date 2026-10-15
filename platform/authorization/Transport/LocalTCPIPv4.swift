import Foundation
import Network

// Adapt the bounded TCP engine to the packet provider's private IPv4 link.
// No internet routes, NAT, forwarding or IP fragmentation are supported.
struct LocalTCPIPv4 {
    static let client: [UInt8] = [10,7,0,1]
    static let device: [UInt8] = [10,7,0,2]
    let endpoints: TunnelTCPEndpoints
    init(clientPort: UInt16, servicePort: UInt16) {
        endpoints = TunnelTCPEndpoints(localAddress:IPv6Address("fd00::1")!,
            remoteAddress:IPv6Address("fd00::2")!,localPort:clientPort,remotePort:servicePort)
    }
    private func pseudo(_ source: [UInt8], _ destination: [UInt8], _ count: Int) -> [UInt8] {
        source + destination + [0,6,UInt8(count >> 8),UInt8(count & 255)]
    }
    // A matched malformed packet belongs to this flow and must be dropped,
    // not reflected back into the device as another connection.
    func matches(_ data: Data) -> Bool {
        let b = Array(data)
        guard b.count >= 40, b[0] >> 4 == 4, b[9] == 6,
              Array(b[12..<16]) == Self.device, Array(b[16..<20]) == Self.client else { return false }
        let h = Int(b[0] & 15) * 4
        guard h >= 20, h+20 <= b.count else { return false }
        return UInt16(b[h]) << 8 | UInt16(b[h+1]) == endpoints.remotePort &&
            UInt16(b[h+2]) << 8 | UInt16(b[h+3]) == endpoints.localPort
    }
    func incoming(_ data: Data) throws -> Data {
        guard matches(data), data.count <= 1500 else { throw PairingError.malformed }
        let b = Array(data), h = Int(data[0] & 15) * 4
        guard Int(b[2]) << 8 | Int(b[3]) == b.count, b[8] > 0,
              b[6] & 0xbf == 0, b[7] == 0, // allow DF only; reject fragments/reserved flag
              TunnelTCPCodec.checksum(Array(b[..<h])) == 0 else { throw PairingError.malformed }
        var tcp = Array(b[h...])
        guard TunnelTCPCodec.checksum(pseudo(Self.device,Self.client,tcp.count)+tcp) == 0 else { throw PairingError.malformed }
        tcp[16] = 0; tcp[17] = 0
        let source = endpoints.remoteAddress.rawValue, destination = endpoints.localAddress.rawValue
        let prefix = Array(source+destination)+[0,0,UInt8(tcp.count>>8),UInt8(tcp.count&255),0,0,0,6]
        let sum = TunnelTCPCodec.checksum(prefix+tcp)
        tcp[16] = UInt8(sum>>8); tcp[17] = UInt8(sum&255)
        return Data([0x60,0,0,0,UInt8(tcp.count>>8),UInt8(tcp.count&255),6,64])+source+destination+Data(tcp)
    }
    func outgoing(_ data: Data) throws -> Data {
        guard data.count >= 60, data.count <= 1500 else { throw PairingError.malformed }
        let reverse = TunnelTCPEndpoints(localAddress:endpoints.remoteAddress,remoteAddress:endpoints.localAddress,
            localPort:endpoints.remotePort,remotePort:endpoints.localPort)
        _ = try TunnelTCPCodec.decode(data,endpoints:reverse,mtu:1500)
        var tcp = Array(data.dropFirst(40))
        tcp[16] = 0; tcp[17] = 0
        let sum = TunnelTCPCodec.checksum(pseudo(Self.client,Self.device,tcp.count)+tcp)
        tcp[16] = UInt8(sum>>8); tcp[17] = UInt8(sum&255)
        let size = tcp.count+20
        var header: [UInt8] = [0x45,0,UInt8(size>>8),UInt8(size&255),0,0,0x40,0,64,6,0,0]+Self.client+Self.device
        let ipSum = TunnelTCPCodec.checksum(header)
        header[10] = UInt8(ipSum>>8); header[11] = UInt8(ipSum&255)
        return Data(header+tcp)
    }
}
