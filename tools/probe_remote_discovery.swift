import Foundation
@main struct Probe {
    static func main() throws {
        let session = RemoteDiscovery(expectedDeviceIdentifier:"fixture-device",hostUUID:UUID(uuidString:"00112233-4455-6677-8899-aabbccddeeff")!)
        func emit(_ events: [RemoteDiscovery.Event]) throws {
            var output: [[String:Any]] = []
            for event in events {
                switch event {
                case .send(let bytes): output.append(["send":bytes.base64EncodedString()])
                case .catalog(let catalog): output.append(["catalog":catalog.services.mapValues { ["port":Int($0.port),"xpc":$0.usesRemoteXPC] as [String:Any] }])
                }
            }
            let data = try JSONSerialization.data(withJSONObject:["events":output,"state":String(describing:session.state)],options:[.sortedKeys])
            print(String(decoding:data,as:UTF8.self)); fflush(stdout)
        }
        while let line = readLine() {
            do {
                guard line.utf8.count <= 100000, let command = try JSONSerialization.jsonObject(with:Data(line.utf8)) as? [String:Any] else { throw PairingError.malformed }
                let now = (command["now"] as? Double) ?? 0
                if command["begin"] as? Bool == true { try emit(session.begin(now:now)) }
                else if command["tick"] as? Bool == true { try session.tick(now:now); try emit([]) }
                else if command["finish"] as? Bool == true { try session.finish(); try emit([]) }
                else if let s = command["data"] as? String, let data = Data(base64Encoded:s) { try emit(session.receive(data,now:now)) }
                else { throw PairingError.malformed }
            } catch { print("{\"error\":true,\"state\":\"\(session.state)\"}"); fflush(stdout) }
        }
    }
}
