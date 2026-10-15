import Foundation
import Network

// Synthetic loopback integration probe; never part of the signed app.
@main struct RSDOverTunnelProbe {
    static func main() throws {
        guard CommandLine.arguments.count == 2, let value = UInt16(CommandLine.arguments[1]),
              let port = NWEndpoint.Port(rawValue:value) else { exit(64) }
        let tunnel = try CDTunnelConnection(host:"127.0.0.1",port:port,sessionKey:Data(0..<32),timeout:3)
        let discovery = RemoteDiscovery(expectedDeviceIdentifier:"fixture-device",hostUUID:UUID(uuidString:"00112233-4455-6677-8899-aabbccddeeff")!)
        let done = DispatchSemaphore(value:0)
        var tcp: TunnelTCP?, result = 1, discovered = false, peerClosed = false
        func now() -> Double { ProcessInfo.processInfo.systemUptime }
        func discoveryEvents(_ events: [RemoteDiscovery.Event]) throws {
            // Preserve all HTTP/2 window updates before closing the TCP write side.
            for event in events {
                if case .send(let bytes) = event { process(try tcp!.write(bytes,now:now())) }
                if case .catalog(let c) = event {
                    guard c.services["fixture.xpc"]?.port == 23456,
                          c.services["fixture.xpc"]?.usesRemoteXPC == true,
                          c.services.count == 702 else { throw PairingError.malformed }
                    discovered = true
                }
            }
            if discovered { try discovery.finish(); process(try tcp!.shutdownWrite(now:now())) }
        }
        func process(_ events: [TunnelTCP.Event]) {
            for event in events {
                if case .packet(let packet) = event {
                    tunnel.send(packet) { error in if error != nil { tunnel.cancel() } }
                }
            }
            for event in events {
                do {
                    switch event {
                    case .connected: try discoveryEvents(discovery.begin(now:now()))
                    case .readable:
                        let read = tcp!.read(maximum:16384); process(read.1)
                        try discoveryEvents(discovery.receive(read.0,now:now()))
                    case .peerClosed: peerClosed = true; tunnel.cancel()
                    case .failed: tunnel.cancel()
                    default:break
                    }
                } catch { tunnel.cancel() }
            }
        }
        tunnel.start(onReady:{ config in
            do {
                let endpoints = TunnelTCPEndpoints(localAddress:config.clientAddress,remoteAddress:config.serverAddress,
                                                  localPort:49160,remotePort:config.rsdPort)
                tcp = try TunnelTCP(endpoints:endpoints,mtu:config.mtu,initialSequence:0x12345)
                process(try tcp!.connect(now:now()))
            } catch { tunnel.cancel() }
        },onPacket:{ packet in
            if let tcp { process(tcp.receive(packet,now:now())) }
        },onClose:{ error in
            if discovered, peerClosed, tcp?.state == .timeWait,
               error as? CDTunnelConnection.Failure == .cancelled { result = 0 }
            print("RSD over encrypted CDTunnel/TCP: verifiedCatalogAndClose=\(result == 0)")
            done.signal()
        })
        if done.wait(timeout:.now()+15) != .success { tunnel.cancel(); exit(2) }
        withExtendedLifetime(tunnel) {}; exit(Int32(result))
    }
}
