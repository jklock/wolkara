import Foundation
import Network
@main struct Probe {
    static func main() throws {
        guard CommandLine.arguments.count == 2, let port = UInt16(CommandLine.arguments[1]),
              let line = readLine(), let data = line.data(using:.utf8),
              let fields = try JSONSerialization.jsonObject(with:data) as? [String:NSNumber],
              let pid = fields["pid"], let uid = fields["uid"], let address = fields["address"], let challenge = fields["challengeAddress"] else { exit(64) }
        let request = try DebugArenaRequest(pid:pid.uint32Value,helperPID:UInt32(getpid()),uid:uid.uint32Value,
            challengeAddress:challenge.uint64Value,challenge:Data(1...32),regions:[.init(address:address.uint64Value,size:16384)])
        let session = DebugArenaSession(request:request), queue = DispatchQueue(label:"native-debugserver-fixture")
        let connection = NWConnection(host:"127.0.0.1",port:NWEndpoint.Port(rawValue:port)!,using:.tcp)
        let done = DispatchSemaphore(value:0), timer = DispatchSource.makeTimerSource(queue:queue)
        var result: Int32 = 1, completed = false
        let process: ([DebugArenaSession.Event]) -> Void = { events in
            guard !completed else { return }
            for event in events {
                switch event {
                case .send(let bytes): connection.send(content:bytes,completion:.contentProcessed { _ in })
                case .finished(let outcome):
                    completed = true; timer.cancel(); connection.cancel()
                    switch outcome {
                    case .success: result = 0; print("PASS: Apple macOS debugserver prepared our zero arena and confirmed detachment; no code executed")
                    case .failure(let error): print("Native debugserver fixture failed: \(error.reason), detachConfirmed=\(error.detachConfirmed)")
                    }
                    done.signal(); return
                }
            }
        }
        var read: (() -> Void)!
        read = {
            connection.receive(minimumIncompleteLength:1,maximumLength:65536) { bytes,_,closed,error in
                if let bytes, !bytes.isEmpty { process(session.receive(bytes,now:ProcessInfo.processInfo.systemUptime)) }
                if error != nil || closed { process(session.disconnected()) }
                else if !completed { read() }
            }
        }
        connection.stateUpdateHandler = { state in
            if case .ready = state {
                do { process(try session.begin(now:ProcessInfo.processInfo.systemUptime)); read() }
                catch { process(session.disconnected()) }
            } else if case .failed = state { process(session.disconnected()) }
        }
        timer.schedule(deadline:.now()+0.1,repeating:0.1)
        timer.setEventHandler { process(session.tick(now:ProcessInfo.processInfo.systemUptime)) }
        timer.resume(); connection.start(queue:queue)
        if done.wait(timeout:.now()+20) != .success { connection.cancel();exit(2) }
        exit(result)
    }
}
