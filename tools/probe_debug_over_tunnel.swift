import Foundation
import Network
@main struct Probe {
    static func main() throws {
        guard CommandLine.arguments.count == 3, let port = UInt16(CommandLine.arguments[1]) else { exit(64) }
        let mode = CommandLine.arguments[2], queue = DispatchQueue(label:"debug-transport-fixture")
        let link = try CDTunnelConnection(host:"127.0.0.1",port:NWEndpoint.Port(rawValue:port)!,sessionKey:Data(0..<32),queue:queue)
        let manager = TunnelConnectionManager(link:link,queue:queue)
        let request = try DebugArenaRequest(pid:1234,helperPID:4321,uid:501,challengeAddress:0x100000,
            challenge:Data(1...32),regions:[.init(address:0x200000,size:16384),.init(address:0x400000,size:16384)])
        let client = DebugArenaClient(manager:manager,request:request), done = DispatchSemaphore(value:0)
        var expected = false, result = 1, completions = 0
        queue.async {
            manager.start(onReady:{ configuration in
                client.start(port:configuration.rsdPort) { outcome in
                    completions += 1
                    switch outcome {
                    case .success(let receipt): expected = mode == "valid" && receipt.pid == request.pid && receipt.challenge == request.challenge && receipt.regions == request.regions
                    case .failure(let error):
                        if mode == "wrong-challenge" { expected = error.reason == .wrongChallenge && error.detachConfirmed }
                        if mode == "missing-detach-reply" { expected = error.reason == .timedOut && !error.detachConfirmed }
                    }
                    manager.cancel()
                }
            },onClosed:{ _ in
                if expected && completions == 1 { result = 0 }
                print("Debug over managed tunnel: \(mode), expectedResult=\(result == 0)")
                done.signal()
            })
        }
        if done.wait(timeout:.now()+18) != .success { queue.async { manager.cancel() }; exit(2) }
        withExtendedLifetime(client) {}; exit(Int32(result))
    }
}
