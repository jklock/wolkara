import Foundation
import Network
private func check(_ value: Bool, _ text: String) { if !value { fatalError(text) } }
private final class Link: TunnelPacketConnection {
    let queue: DispatchQueue
    let config: CDTunnelConfiguration
    var packets: [Data] = [], cancelled = 0
    var sendFailure = false, holdWrites = false
    var pending: [(Error?) -> Void] = []
    var packet: ((Data) -> Void)?, close: ((Error) -> Void)?
    init(queue: DispatchQueue) throws {
        self.queue = queue
        config = try CDTunnelConfiguration(response:JSONSerialization.data(withJSONObject:["clientParameters":["address":"fd00::1","netmask":"ffff:ffff:ffff:ffff::","mtu":16000],"serverAddress":"fd00::2","serverRSDPort":58783]),requestedMTU:16000)
    }
    func start(onReady: @escaping (CDTunnelConfiguration)->Void,onPacket: @escaping (Data)->Void,onClose: @escaping (Error)->Void) {
        packet = onPacket; close = onClose; onReady(config)
    }
    func send(_ bytes: Data,completion: @escaping (Error?)->Void) {
        packets.append(bytes)
        if holdWrites { pending.append(completion) }
        else { completion(sendFailure ? PairingError.exhausted : nil) }
    }
    func cancel() { cancelled += 1; packet = nil; close = nil }
    func reply(_ index: Int, seq: UInt32 = 1000, flags: UInt8 = 18, payload: Data = Data(), extraACK: UInt32 = 0) {
        let bytes = packets[index], b = Array(bytes)
        let local = UInt16(b[40])<<8 | UInt16(b[41]), remote = UInt16(b[42])<<8 | UInt16(b[43])
        let outgoing = b[44..<48].reduce(UInt32(0)) { $0<<8 | UInt32($1) }
        let e = TunnelTCPEndpoints(localAddress:config.clientAddress,remoteAddress:config.serverAddress,localPort:local,remotePort:remote)
        packet?(TunnelTCPCodec.encode(TunnelTCPSegment(sequence:seq,acknowledgement:outgoing &+ 1 &+ extraACK,flags:flags,window:32768,payload:payload,mss:nil),endpoints:e,incoming:true))
    }
}
@main struct ManagerTests {
    static func main() throws {
        let queue = DispatchQueue(label:"manager-test")
        let done = DispatchSemaphore(value:0)
        try queue.sync {
            let link = try Link(queue:queue)
            var clock: Double = 0
            let manager = TunnelConnectionManager(link:link,queue:queue,clock:{clock})
            var closed = 0, aClosed = 0, bClosed = 0
            manager.start(onReady:{ _ in },onClosed:{ _ in closed += 1 })
            let a = try manager.open(port:58783) { id,event in
                if case .closed = event { aClosed += 1; manager.cancelStream(id) }
            }
            _ = try manager.open(port:54321) { _,event in if case .closed = event { bClosed += 1 } }
            check(link.packets.count == 2,"two streams")
            link.reply(0)
            try manager.write(a,data:Data("hello".utf8))
            check(link.packets.count == 4,"handshake ACK before app data")
            manager.cancelStream(a); manager.cancelStream(a)
            check(aClosed == 1 && bClosed == 0,"one stream closed once")
            let oldReceive = link.packet, oldClose = link.close
            manager.cancel(); manager.cancel()
            oldReceive?(Data()); oldClose?(PairingError.exhausted)
            check(closed == 1 && aClosed == 1 && bClosed == 1 && link.cancelled == 1,"late callbacks cannot double finish")
            clock = 500
        }
        try queue.sync {
            let link = try Link(queue:queue)
            let manager = TunnelConnectionManager(link:link,queue:queue)
            var close = 0, streamClose = 0
            manager.start(onReady:{ _ in },onClosed:{ _ in close += 1 })
            link.sendFailure = true
            _ = try manager.open(port:58783) { _,event in if case .closed = event { streamClose += 1 } }
            check(close == 1 && streamClose == 1,"synchronous send failure cleans up reentrantly")
        }
        try queue.sync {
            let link = try Link(queue:queue)
            let manager = TunnelConnectionManager(link:link,queue:queue)
            var failures = 0
            manager.start(onReady:{ _ in },onClosed:{ error in
                check(error as? TunnelConnectionManager.Failure == .backpressure,"packet admission bound")
                failures += 1
            })
            _ = try manager.open(port:58783) { id,event in
                if case .readable = event { _ = try? manager.read(id) }
            }
            link.reply(0)
            link.holdWrites = true
            for i in 0..<300 { link.reply(0,seq:UInt32(1001+i),flags:24,payload:Data([1])) }
            check(failures == 1 && link.pending.count == 1,"one transport write in flight, bounded packet backlog")
            link.pending[0](nil) // Late completion after teardown must be harmless.
            check(failures == 1,"late write completion ignored")
        }
        try queue.sync {
            let link = try Link(queue:queue); link.holdWrites = true
            let manager = TunnelConnectionManager(link:link,queue:queue)
            manager.start(onReady:{ _ in },onClosed:{ _ in })
            for i in 0..<8 { _ = try manager.open(port:UInt16(30000+i)) { _,_ in } }
            check(link.packets.count == 1 && link.pending.count == 1,"only first queued packet sent")
            for _ in 0..<8 { let completion = link.pending.removeFirst(); completion(nil) }
            check(link.packets.count == 8 && link.pending.isEmpty,"queued packets drain in order")
            let ports = link.packets.map { UInt16($0[42])<<8 | UInt16($0[43]) }
            check(ports == Array(30000..<30008).map(UInt16.init),"FIFO across streams")
            manager.cancel()
        }
        // Real DispatchSource scheduling with an injected monotonic clock,
        // without sleeping 31 seconds to exercise a SYN timeout.
        try queue.sync {
            let link = try Link(queue:queue)
            var clock: Double = 0
            let manager = TunnelConnectionManager(link:link,queue:queue,clock:{clock})
            var failures = 0
            manager.start(onReady:{ _ in },onClosed:{ _ in check(failures == 1,"exactly one timed-out stream"); done.signal() })
            _ = try manager.open(port:58783) { _,event in
                if case .closed(let error) = event {
                    check(error as? TunnelTCP.Failure == .timeout,"timer produces TCP timeout")
                    failures += 1; manager.cancel()
                }
            }
            for (index,t) in [1.0,3,7,15,23,31].enumerated() {
                queue.asyncAfter(deadline:.now()+Double(index+1)*0.15) { clock = t }
            }
        }
        check(done.wait(timeout:.now()+3) == .success,"automatic timer drives TCP")
        print("Tunnel manager: serial callbacks, reentrant cancellation/failure, independent streams and automatic timeout passed")
    }
}
