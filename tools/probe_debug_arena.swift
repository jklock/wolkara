import Foundation
@main struct Probe {
    static func main() throws {
        let request = try DebugArenaRequest(pid:1234,helperPID:4321,uid:501,challengeAddress:0x100000,
            challenge:Data(1...32),regions:[.init(address:0x200000,size:16384),.init(address:0x400000,size:16384)])
        let session = DebugArenaSession(request:request)
        func output(_ events: [DebugArenaSession.Event]) throws {
            let values: [[String:Any]] = events.map { event in
                switch event {
                case .send(let bytes): return ["send":bytes.base64EncodedString()]
                case .finished(.success(let receipt)): return ["success":true,"pid":receipt.pid,"regions":receipt.regions.count]
                case .finished(.failure(let error)): return ["failure":String(describing:error.reason),"detached":error.detachConfirmed]
                }
            }
            let data = try JSONSerialization.data(withJSONObject:["events":values,"phase":String(describing:session.phase)],options:[.sortedKeys])
            print(String(decoding:data,as:UTF8.self)); fflush(stdout)
        }
        while let line = readLine() {
            do {
                guard line.utf8.count <= 100000, let value = try JSONSerialization.jsonObject(with:Data(line.utf8)) as? [String:Any] else { throw PairingError.malformed }
                let now = value["now"] as? Double ?? 0
                if value["begin"] as? Bool == true { try output(session.begin(now:now)) }
                else if value["tick"] as? Bool == true { try output(session.tick(now:now)) }
                else if value["cancel"] as? Bool == true { try output(session.cancel()) }
                else if value["disconnect"] as? Bool == true { try output(session.disconnected()) }
                else if let text = value["data"] as? String, let data = Data(base64Encoded:text) { try output(session.receive(data,now:now)) }
                else { throw PairingError.malformed }
            } catch { print("{\"error\":true}"); fflush(stdout) }
        }
    }
}
