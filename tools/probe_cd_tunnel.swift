import Foundation
import Network

// Synthetic loopback fixture only. Does not read device keys or use a VPN.
@main struct CDTunnelProbe {
    static func main() throws {
        guard CommandLine.arguments.count == 3, let value = UInt16(CommandLine.arguments[1]),
              let port = NWEndpoint.Port(rawValue: value) else { exit(64) }
        let mode = CommandLine.arguments[2]
        var key = Data(0..<32)
        if mode == "wrong-key" { key[0] ^= 1 }
        let tunnel = try CDTunnelConnection(host:"127.0.0.1", port:port, sessionKey:key, timeout:1.5)
        let finished = DispatchSemaphore(value:0)
        var ready = 0, packets = 0, sent = false, invalidRejected = false, result = 1
        var writeCallbacks = 0, acceptedWrites = 0, limitedWrites = 0
        tunnel.start(onReady: { config in
            ready += 1
            guard config.mtu == 16000 && config.rsdPort == 58783 else { tunnel.cancel(); return }
            if mode == "backpressure" {
                var packet = Data([0x60,0,0,0,0x3e,0x58,59,64])
                packet.append(config.clientAddress.rawValue); packet.append(config.serverAddress.rawValue)
                packet.append(Data(repeating: 0, count: 15960))
                for _ in 0..<40 {
                    tunnel.send(packet) { error in
                        writeCallbacks += 1
                        if error == nil { acceptedWrites += 1 }
                        if error as? CDTunnelConnection.Failure == .backpressure { limitedWrites += 1 }
                        if writeCallbacks == 40 { tunnel.cancel() }
                    }
                }
            }
            if mode == "valid" {
                tunnel.send(Data([0])) { error in invalidRejected = error != nil }
                var packet = Data([0x60,0,0,0,0,4,59,64])
                packet.append(config.clientAddress.rawValue); packet.append(config.serverAddress.rawValue)
                packet.append(Data("PING".utf8))
                tunnel.send(packet) { error in
                    sent = error == nil
                    if packets == 2 { tunnel.cancel() }
                }
            }
        }, onPacket: { packet in
            packets += 1
            let expected = packets == 1 ? "HELLO" : "PONG"
            guard packet.suffix(expected.count) == Data(expected.utf8) else { tunnel.cancel(); return }
            if packets == 2 && sent { tunnel.cancel() }
        }, onClose: { error in
            let failure = error as? CDTunnelConnection.Failure
            switch mode {
            case "valid": result = ready == 1 && packets == 2 && sent && invalidRejected && failure == .cancelled ? 0 : 1
            case "backpressure": result = ready == 1 && writeCallbacks == 40 && acceptedWrites > 0 && limitedWrites > 0 && acceptedWrites + limitedWrites == 40 && failure == .cancelled ? 0 : 1
            case "wrong-key": result = ready == 0 && failure == .transport ? 0 : 1
            case "silent", "partial": result = packets == 0 && failure == .timedOut ? 0 : 1
            case "malformed", "oversized", "truncated": result = packets == 0 && failure == .protocolFailure ? 0 : 1
            default: result = 1
            }
            print("CDTunnel \(mode): ready=\(ready) packets=\(packets) expectedResult=\(result == 0)")
            finished.signal()
        })
        if finished.wait(timeout:.now()+8) != .success { tunnel.cancel(); print("Probe exceeded deadline"); exit(2) }
        withExtendedLifetime(tunnel) {}
        exit(Int32(result))
    }
}
