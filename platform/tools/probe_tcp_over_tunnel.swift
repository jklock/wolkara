import Foundation
import Network

// Combined-stack loopback test. The app does not compile this synthetic probe.
@main struct TCPOverTunnelProbe {
    static func main() throws {
        guard CommandLine.arguments.count == 2, let value = UInt16(CommandLine.arguments[1]),
              let port = NWEndpoint.Port(rawValue:value) else { exit(64) }
        let tunnel = try CDTunnelConnection(host:"127.0.0.1",port:port,sessionKey:Data(0..<32),timeout:2)
        let done = DispatchSemaphore(value:0)
        var tcp: TunnelTCP?, received = Data(), result = 1, peerClosed = false, writeClosed = false
        func process(_ events: [TunnelTCP.Event]) {
            // All callbacks are on CDTunnel's queue. Send existing packet actions
            // before application callbacks enqueue new actions.
            for event in events {
                if case .packet(let packet) = event {
                    tunnel.send(packet) { error in if error != nil { tunnel.cancel() } }
                }
            }
            for event in events {
                switch event {
                case .connected:
                    do { process(try tcp!.write(Data("RSD transport fixture".utf8),now:ProcessInfo.processInfo.systemUptime)) }
                    catch { tunnel.cancel() }
                case .readable:
                    let read = tcp!.read(maximum:1024); received.append(read.0); process(read.1)
                    if received == Data("service-ready".utf8), !writeClosed {
                        writeClosed = true
                        do { process(try tcp!.shutdownWrite(now:ProcessInfo.processInfo.systemUptime)) }
                        catch { tunnel.cancel() }
                    }
                case .peerClosed:
                    peerClosed = true; tunnel.cancel()
                case .failed: tunnel.cancel()
                default:break
                }
            }
        }
        tunnel.start(onReady:{ config in
            do {
                let endpoints = TunnelTCPEndpoints(localAddress:config.clientAddress,remoteAddress:config.serverAddress,
                                                  localPort:49160,remotePort:config.rsdPort)
                tcp = try TunnelTCP(endpoints:endpoints,mtu:config.mtu,initialSequence:0x12345)
                process(try tcp!.connect(now:ProcessInfo.processInfo.systemUptime))
            } catch { tunnel.cancel() }
        },onPacket:{ packet in
            if let tcp { process(tcp.receive(packet,now:ProcessInfo.processInfo.systemUptime)) }
        },onClose:{ error in
            if received == Data("service-ready".utf8), peerClosed, writeClosed,
               tcp?.state == .timeWait, error as? CDTunnelConnection.Failure == .cancelled { result = 0 }
            print("TCP over encrypted CDTunnel: exchangeAndClose=\(result == 0)")
            done.signal()
        })
        if done.wait(timeout:.now()+8) != .success { tunnel.cancel(); exit(2) }
        withExtendedLifetime(tunnel) {}; exit(Int32(result))
    }
}
