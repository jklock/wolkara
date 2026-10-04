import Foundation

// Independent IPv4/TCP replies to the helper's synthetic SYN. All packets stay
// in this test; no Apple service, pairing record or debugger is used.
private func checksum(_ bytes: [UInt8]) -> UInt16 {
    var sum: UInt32 = 0
    for i in stride(from: 0, to: bytes.count, by: 2) {
        sum += UInt32(bytes[i]) << 8
        if i+1 < bytes.count { sum += UInt32(bytes[i+1]) }
    }
    while sum > 65535 { sum = (sum & 65535) + (sum >> 16) }
    return ~UInt16(sum)
}
private func put(_ value: UInt32, into bytes: inout [UInt8], at: Int) {
    for n in 0..<4 { bytes[at+n] = UInt8(truncatingIfNeeded:value >> ((3-n)*8)) }
}
private func reply(to packet: Data, sequence: UInt32, flags: UInt8) -> Data {
    let sent = Array(packet)
    let header = Int(sent[0] & 15)*4
    var acknowledgement: UInt32 = 0
    for b in sent[(header+4)..<(header+8)] { acknowledgement = (acknowledgement << 8) | UInt32(b) }
    acknowledgement &+= sent[header+13] & 2 != 0 ? 1 : 0
    var bytes: [UInt8] = [0x45,0,0,40,0,0,0x40,0,64,6,0,0]
    bytes += sent[16..<20]; bytes += sent[12..<16]
    bytes += sent[(header+2)..<(header+4)]; bytes += sent[header..<(header+2)]
    bytes += [UInt8](repeating:0,count:16)
    put(sequence,into:&bytes,at:24); put(acknowledgement,into:&bytes,at:28)
    bytes[32] = 0x50; bytes[33] = flags; bytes[34] = 0x80
    let tcp = checksum(Array(bytes[12..<20])+[0,6,0,20]+Array(bytes[20..<40]))
    bytes[36] = UInt8(tcp >> 8); bytes[37] = UInt8(truncatingIfNeeded:tcp)
    let ip = checksum(Array(bytes[0..<20])); bytes[10] = UInt8(ip >> 8); bytes[11] = UInt8(truncatingIfNeeded:ip)
    return Data(bytes)
}
@main struct PacketRetryTests {
    static func main() {
        for connected in [false,true] {
            let probe = PacketServiceProbe(), done = DispatchSemaphore(value:0)
            var resetSent = false
            probe.start(output:{ packet in
                let b = Array(packet), flags = b[Int(b[0] & 15)*4+13]
                let response: Data
                if flags & 2 != 0 {
                    response = reply(to:packet,sequence:100,flags:connected ? 0x12 : 0x14)
                } else if connected && !resetSent && flags & 4 == 0 {
                    resetSent = true; response = reply(to:packet,sequence:101,flags:0x14)
                } else { return true }
                DispatchQueue.global().async { precondition(probe.consume(response)) }
                return true
            },completion:{ report in
                precondition(report.contains("TCP connection failed (reset)"),report)
                precondition(probe.serviceUnavailable == !connected)
                precondition(!probe.authorizationReady)
                done.signal()
            })
            precondition(done.wait(timeout:.now()+3) == .success,"Synthetic reset did not complete")
        }
        print("PASS: initial connection reset permits retry; reset after SYN/ACK remains terminal; no native readiness")
    }
}
