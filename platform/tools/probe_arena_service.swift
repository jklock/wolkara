import Foundation
import Network
func ipcOutcome(_ data: Data?, request: Data) -> TKACOutcome? {
    guard let data else { return nil }
    var outcome = TKAC_UNCERTAIN
    let valid = request.withUnsafeBytes { r in data.withUnsafeBytes { d in
        tkac_match(r.bindMemory(to:UInt8.self).baseAddress,r.count,d.bindMemory(to:UInt8.self).baseAddress,d.count,&outcome)
    } }
    return valid ? outcome : nil
}
func command(_ request: Data, _ kind: TKACCommand) -> Data {
    var result = Data(count:Int(TKAC_SIZE))
    precondition(result.withUnsafeMutableBytes { out in request.withUnsafeBytes { source in
        tkac_command(source.bindMemory(to:UInt8.self).baseAddress,source.count,kind,out.bindMemory(to:UInt8.self).baseAddress,out.count)
    } })
    return result
}
// Mutable fixture state is confined to the serial fixture queue. The main
// thread reads the result only after the completion semaphore is signalled.
private final class FixtureState {
    var expected = false
    var result = 1
    var completions = 0
}
@main struct Probe {
    static func main() throws {
        guard CommandLine.arguments.count == 3, let port = UInt16(CommandLine.arguments[1]) else { exit(64) }
        let mode = CommandLine.arguments[2], queue = DispatchQueue(label:"arena-service-fixture")
        let link = try CDTunnelConnection(host:"127.0.0.1",port:NWEndpoint.Port(rawValue:port)!,sessionKey:Data(0..<32),queue:queue)
        let manager = TunnelConnectionManager(link:link,queue:queue), service = ArenaPreparationService(queue:queue)
        var raw = TKACRequest()
        raw.pid = 1234; raw.uid = UInt32(geteuid()); raw.address = 0x200000; raw.size = 16384; raw.challenge_address = 0x100000
        raw.deadline_ms = UInt64(ProcessInfo.processInfo.systemUptime*1000) + (mode == "service-expiry" ? 500 : 16000)
        withUnsafeMutableBytes(of:&raw.challenge) { $0.copyBytes(from:Data(1...32)) }
        withUnsafeMutableBytes(of:&raw.identifier) { $0.copyBytes(from:Data(repeating:0xa5,count:16)) }
        var wire = Data(count:Int(TKAC_SIZE))
        precondition(wire.withUnsafeMutableBytes { tkac_encode(&raw,$0.bindMemory(to:UInt8.self).baseAddress,$0.count) })
        let request = wire, done = DispatchSemaphore(value:0)
        let state = FixtureState()
        // The default helper must positively reject before a verified service is
        // configured. No route or TLS state grants permission by itself.
        let unconfigured = ArenaPreparationService(), first = DispatchSemaphore(value:0)
        unconfigured.handle(request) { data in precondition(ipcOutcome(data,request:request) == TKAC_REJECTED); first.signal() }
        precondition(first.wait(timeout:.now()+2) == .success)
        queue.async {
            manager.start(onReady:{ configuration in
                do { try service.setVerifiedDebugService(manager:manager,port:configuration.rsdPort) }
                catch { manager.cancel(); return }
                func poll() {
                    service.handleAsync(command(request,TKAC_POLL)) { data in
                        let value = ipcOutcome(data,request:request)
                        if value == TKAC_PENDING { queue.asyncAfter(deadline:.now()+0.05) { poll() };return }
                        state.expected = mode == "valid" ? value == TKAC_PREPARED : mode == "wrong-challenge" ? value == TKAC_FAILED_DETACHED : value == TKAC_UNCERTAIN
                        state.completions += 1
                        // A completed result is stable, but a new submit cannot
                        // cause another attachment. Unknown queries are uncertain.
                        service.handleAsync(command(request,TKAC_POLL)) { repeated in
                            state.expected = state.expected && repeated == data
                            service.handleAsync(command(request,TKAC_SUBMIT)) { duplicate in
                                state.expected = state.expected && ipcOutcome(duplicate,request:request) == TKAC_UNCERTAIN
                                var changed = request;changed[80] ^= 1
                                let different = changed
                                service.handleAsync(command(different,TKAC_POLL)) { unknown in
                                    state.expected = state.expected && ipcOutcome(unknown,request:different) == TKAC_UNCERTAIN
                                    state.completions += 1;service.invalidate();manager.cancel()
                                }
                            }
                        }
                    }
                }
                service.handleAsync(command(request,TKAC_SUBMIT)) { pending in
                    precondition(ipcOutcome(pending,request:request) == TKAC_PENDING)
                    // A duplicate before preparation finishes must neither
                    // attach twice nor imply that the arena is safe to free.
                    service.handleAsync(command(request,TKAC_SUBMIT)) { duplicate in
                        precondition(ipcOutcome(duplicate,request:request) == TKAC_UNCERTAIN)
                        poll()
                    }
                }
            },onClosed:{ _ in
                if state.expected && state.completions == 2 { state.result = 0 }
                print("Arena service over managed tunnel: \(mode), expectedResult=\(state.result == 0)")
                done.signal()
            })
        }
        if done.wait(timeout:.now()+18) != .success { queue.async { manager.cancel() }; exit(2) }
        withExtendedLifetime(service) {}; exit(Int32(state.result))
    }
}
