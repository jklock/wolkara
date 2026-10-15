import Foundation
import Network

// Deterministic stdin/stdout harness for the independent Python peer. Test data
// only; never connected to real device services or compiled into the app.
@main struct TCPProbe {
    static func main() throws {
        let endpoints = TunnelTCPEndpoints(localAddress:IPv6Address("fd00::1")!,remoteAddress:IPv6Address("fd00::2")!,localPort:49160,remotePort:58783)
        let tcp = try TunnelTCP(endpoints:endpoints,mtu:16000,initialSequence:0xffffffe0)
        func data(_ value: Any?) -> Data { Data(base64Encoded:value as! String)! }
        while let line = readLine() {
            let input = try JSONSerialization.jsonObject(with:Data(line.utf8)) as! [String:Any]
            let operation = input["op"] as! String, now = (input["now"] as? NSNumber)?.doubleValue ?? 0
            var events: [TunnelTCP.Event] = [], result: [String:Any] = [:]
            do {
                switch operation {
                case "connect": events = try tcp.connect(now:now)
                case "write": events = try tcp.write(data(input["data"]),now:now)
                case "receive": events = tcp.receive(data(input["data"]),now:now)
                case "read":
                    let read = tcp.read(maximum:(input["maximum"] as! NSNumber).intValue)
                    result["data"] = read.0.base64EncodedString(); events = read.1
                case "tick": events = tcp.tick(now:now)
                case "finish": events = try tcp.shutdownWrite(now:now)
                case "abort": events = tcp.abort()
                default: throw TunnelTCP.Failure.invalidState
                }
            } catch { result["error"] = String(describing:error) }
            result["state"] = String(describing:tcp.state)
            result["events"] = events.map { event -> [String:Any] in
                switch event {
                case .packet(let bytes): return ["packet":bytes.base64EncodedString()]
                case .connected:return ["type":"connected"]
                case .readable:return ["type":"readable"]
                case .writable:return ["type":"writable"]
                case .peerClosed:return ["type":"peerClosed"]
                case .closed:return ["type":"closed"]
                case .failed(let error):return ["type":"failed","error":String(describing:error)]
                }
            }
            let output = try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys])
            print(String(data:output,encoding:.utf8)!); fflush(stdout)
        }
    }
}
