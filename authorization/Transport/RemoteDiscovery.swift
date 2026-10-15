import Foundation

struct RemoteServiceCatalog: Equatable {
    struct Service: Equatable { let port: UInt16; let usesRemoteXPC: Bool }
    let deviceIdentifier: String
    let services: [String:Service]
    init(_ value: RemoteXPCValue, expectedDeviceIdentifier: String) throws {
        guard !expectedDeviceIdentifier.isEmpty,
              let root = value.dictionary, let properties = root["Properties"]?.dictionary,
              let identifier = properties["UniqueDeviceID"]?.string,
              identifier == expectedDeviceIdentifier else { throw PairingError.authenticationFailed }
        guard let entries = root["Services"]?.dictionary, entries.count <= 2048 else { throw PairingError.malformed }
        var result: [String:Service] = [:]
        for (name, value) in entries {
            guard !name.isEmpty, name.utf8.count <= 512, let entry = value.dictionary,
                  let portText = entry["Port"]?.string, !portText.isEmpty, portText.utf8.count <= 5,
                  portText.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                  let port = UInt16(portText), port > 0 else { throw PairingError.malformed }
            var usesXPC = false
            if let p = entry["Properties"] {
                guard let d = p.dictionary else { throw PairingError.malformed }
                if let flag = d["UsesRemoteXPC"] {
                    guard case .bool(let b) = flag else { throw PairingError.malformed }; usesXPC = b
                }
            }
            result[name] = Service(port:port,usesRemoteXPC:usesXPC)
        }
        deviceIdentifier = identifier; services = result
    }
}

// Narrow RemoteXPC discovery exchange, not a general HTTP/2 or HPACK client.
// The owner supplies a serial reliable byte stream and monotonic time, drains
// every .send event in order, and calls tick even when no bytes arrive.
// Catalog metadata is accepted only on the already authenticated tunnel; the
// identifier comparison additionally binds it to the device selected by user.
final class RemoteDiscovery {
    enum State { case idle, negotiating, discovering, complete, failed }
    enum Event { case send(Data), catalog(RemoteServiceCatalog) }
    private(set) var state: State = .idle
    private var frame = Data(), frameLength: Int?
    private var root = RemoteXPCStream(), reply = RemoteXPCStream()
    private var settingsSeen = false, settingsAcknowledged = false
    private var connectionWindow = 65535, initialWindow = 65535
    private var windows: [UInt32:Int] = [1:65535,3:65535]
    private var pending = Data(), pendingOffset = 0
    private var receivedBytes = 0, frames = 0
    private var deadline = 0.0
    private let expectedIdentifier: String, hostUUID: UUID
    init(expectedDeviceIdentifier: String, hostUUID: UUID) {
        expectedIdentifier = expectedDeviceIdentifier; self.hostUUID = hostUUID
    }
    private static func be(_ n: UInt32) -> Data {
        Data([UInt8(truncatingIfNeeded:n>>24),UInt8(truncatingIfNeeded:n>>16),UInt8(truncatingIfNeeded:n>>8),UInt8(truncatingIfNeeded:n)])
    }
    static func frame(type: UInt8, flags: UInt8 = 0, stream: UInt32 = 0, payload: Data = Data()) -> Data {
        precondition(payload.count <= 16384 && stream <= 0x7fffffff)
        let length = payload.count
        return Data([UInt8(length>>16),UInt8((length>>8)&255),UInt8(length&255),type,flags]) + be(stream) + payload
    }
    private func xpc(_ value: RemoteXPCValue?, flags: UInt32, id: UInt64, stream: UInt32) throws -> Data {
        let bytes = try RemoteXPCWire.encode(RemoteXPCMessage(flags:flags,identifier:id,value:value))
        guard bytes.count <= min(connectionWindow,windows[stream] ?? 0) else { throw PairingError.invalidState }
        connectionWindow -= bytes.count; windows[stream]! -= bytes.count
        return Self.frame(type:0,stream:stream,payload:bytes)
    }
    func begin(now: TimeInterval) throws -> [Event] {
        guard state == .idle, now.isFinite, !expectedIdentifier.isEmpty else { throw PairingError.invalidState }
        state = .negotiating; deadline = now + 20
        var bytes = Data("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".utf8)
        // A 1 MiB receive window and at most two locally opened channels.
        bytes += Self.frame(type:4,payload:Data([0,3])+Self.be(100)+Data([0,4])+Self.be(1_048_576))
        bytes += Self.frame(type:8,payload:Self.be(1_048_576-65535))
        bytes += Self.frame(type:1,flags:4,stream:1)
        bytes += try xpc(.dictionary([:]),flags:1,id:0,stream:1)
        bytes += Self.frame(type:1,flags:4,stream:3)
        bytes += try xpc(nil,flags:0x201,id:0,stream:1)
        bytes += try xpc(nil,flags:0x400001,id:0,stream:3)
        return [.send(bytes)]
    }
    func tick(now: TimeInterval) throws {
        guard state == .negotiating || state == .discovering else { return }
        guard now.isFinite, now < deadline else { fail(); throw PairingError.exhausted }
    }
    private func fail() { state = .failed; frame = Data(); pending = Data(); root = RemoteXPCStream(); reply = RemoteXPCStream() }
    func finish() throws {
        guard state == .complete else { fail(); throw PairingError.malformed }
    }
    func receive(_ bytes: Data, now: TimeInterval) throws -> [Event] {
        guard state == .negotiating || state == .discovering else { throw PairingError.invalidState }
        do {
            try tick(now:now)
            guard bytes.count <= 65536, bytes.count <= 2_097_152 - receivedBytes else { throw PairingError.oversized }
            receivedBytes += bytes.count
            var result: [Event] = []
            for b in bytes {
                frame.append(b)
                if frame.count == 9 {
                    let size = Int(frame[0])<<16 | Int(frame[1])<<8 | Int(frame[2])
                    guard size <= 16384 else { throw PairingError.oversized }; frameLength = size + 9
                }
                if frame.count == frameLength {
                    frames += 1; guard frames <= 4096 else { throw PairingError.oversized }
                    let f = frame; frame = Data(); frameLength = nil
                    result += try handle(f)
                }
            }
            return result
        } catch { fail(); throw error }
    }
    private func handle(_ frame: Data) throws -> [Event] {
        let b = Array(frame)
        func u32(_ at: Int) -> UInt32 { UInt32(b[at])<<24 | UInt32(b[at+1])<<16 | UInt32(b[at+2])<<8 | UInt32(b[at+3]) }
        let type = b[3], flags = b[4], stream = u32(5) & 0x7fffffff
        let payload = Data(b.dropFirst(9)), count = payload.count
        var result: [Event] = []
        switch type {
        case 4: // SETTINGS
            guard stream == 0, flags & ~1 == 0 else { throw PairingError.malformed }
            if flags & 1 != 0 {
                guard count == 0, !settingsAcknowledged else { throw PairingError.malformed }; settingsAcknowledged = true
            } else {
                guard count % 6 == 0 else { throw PairingError.malformed }
                for at in stride(from:9,to:b.count,by:6) {
                    let key = UInt16(b[at])<<8 | UInt16(b[at+1]), value = u32(at+2)
                    if key == 2 { guard value <= 1 else { throw PairingError.malformed } }
                    if key == 4 {
                        guard value <= 0x7fffffff else { throw PairingError.malformed }
                        let delta = Int(value)-initialWindow
                        for id in [UInt32(1),3] {
                            guard windows[id]! + delta <= 0x7fffffff else { throw PairingError.malformed }
                            windows[id]! += delta
                        }
                        initialWindow = Int(value)
                    }
                    if key == 5 { guard value >= 16384, value <= 16777215 else { throw PairingError.malformed } }
                }
                result.append(.send(Self.frame(type:4,flags:1)))
                if !settingsSeen {
                    settingsSeen = true; state = .discovering
                    var uuid = hostUUID.uuid
                    let value: RemoteXPCValue = .dictionary([
                        "MessageType":.string("Handshake"), "MessagingProtocolVersion":.uint(7),
                        "UUID":.uuid(withUnsafeBytes(of:&uuid) { Data($0) }),
                        "Properties":.dictionary(["RemoteXPCVersionFlags":.uint(0x0100000000000006),"SensitivePropertiesVisible":.bool(true)]),
                        "Services":.dictionary([:])])
                    pending = try RemoteXPCWire.encode(RemoteXPCMessage(flags:0x101,identifier:1,value:value))
                }
                result += flush()
            }
        case 8: // WINDOW_UPDATE
            guard count == 4, stream == 0 || windows[stream] != nil else { throw PairingError.malformed }
            let increment = Int(u32(9) & 0x7fffffff)
            guard increment > 0 else { throw PairingError.malformed }
            if stream == 0 {
                guard connectionWindow + increment <= 0x7fffffff else { throw PairingError.malformed }; connectionWindow += increment
            } else {
                guard windows[stream]! + increment <= 0x7fffffff else { throw PairingError.malformed }; windows[stream]! += increment
            }
            result += flush()
        case 6: // PING
            guard stream == 0, count == 8, flags & ~1 == 0 else { throw PairingError.malformed }
            if flags & 1 == 0 { result.append(.send(Self.frame(type:6,flags:1,payload:payload))) }
        case 1: // RemoteXPC uses empty header blocks, not HTTP request headers.
            guard settingsSeen, (stream == 1 || stream == 3), flags == 4, count == 0 else { throw PairingError.malformed }
        case 0:
            guard settingsSeen, (stream == 1 || stream == 3), flags & ~8 == 0 else { throw PairingError.malformed }
            var data = payload
            if flags & 8 != 0 {
                guard count > 0, Int(b[9]) < count else { throw PairingError.malformed }
                data = Data(b[10..<(b.count-Int(b[9]))])
            }
            // Both channels have separate assemblers; interleaved partial XPC
            // messages must never become one message or steal each other's data.
            let messages = try stream == 1 ? root.consume(data) : reply.consume(data)
            for message in messages {
                if let value = message.value {
                    guard let dictionary = value.dictionary else { throw PairingError.malformed }
                    if dictionary.isEmpty { continue }
                    guard state == .discovering, pending.isEmpty,
                          !root.hasPartialMessage, !reply.hasPartialMessage else { throw PairingError.invalidState }
                    let catalog = try RemoteServiceCatalog(value,expectedDeviceIdentifier:expectedIdentifier)
                    state = .complete; result.append(.catalog(catalog))
                }
            }
            if count > 0 {
                result.append(.send(Self.frame(type:8,payload:Self.be(UInt32(count)))))
                result.append(.send(Self.frame(type:8,stream:stream,payload:Self.be(UInt32(count)))))
            }
        case 2: // PRIORITY does not change the fixed two-channel scheduler.
            guard stream != 0, count == 5, u32(9) & 0x7fffffff != stream else { throw PairingError.malformed }
        case 3,7,5,9: // Reset, go-away, pushed streams, HPACK continuation unsupported.
            throw PairingError.invalidState
        default: break // Unknown extension frames are ignored as required by HTTP/2.
        }
        return result
    }
    private func flush() -> [Event] {
        var result: [Event] = []
        while pendingOffset < pending.count {
            let count = min(16384,pending.count-pendingOffset,connectionWindow,windows[1]!)
            if count <= 0 { break }
            let bytes = Data(pending[pendingOffset..<(pendingOffset+count)])
            result.append(.send(Self.frame(type:0,stream:1,payload:bytes)))
            connectionWindow -= count; windows[1]! -= count; pendingOffset += count
        }
        if pendingOffset == pending.count { pending = Data(); pendingOffset = 0 }
        return result
    }
}
