import Foundation
import CoreFoundation
import Network

struct CDTunnelConfiguration {
    let clientAddress: IPv6Address
    let serverAddress: IPv6Address
    let prefixLength: Int
    let mtu: Int
    let rsdPort: UInt16

    init(response: Data, requestedMTU: Int) throws {
        guard response.count <= 16_384 else { throw PairingError.oversized }
        let object = try JSONSerialization.jsonObject(with: response)
        guard let root = object as? [String: Any],
              let client = root["clientParameters"] as? [String: Any],
              let source = Self.address(client["address"]),
              let destination = Self.address(root["serverAddress"]), source != destination,
              let maskText = client["netmask"] as? String, !maskText.contains("%"),
              let mask = IPv6Address(maskText),
              let mtu = Self.integer(client["mtu"]), mtu >= 1280, mtu <= requestedMTU,
              let port = Self.integer(root["serverRSDPort"]), port > 0, port <= 65535 else {
            throw PairingError.malformed
        }
        var prefix = 0, zeroSeen = false
        for byte in mask.rawValue {
            for shift in stride(from: 7, through: 0, by: -1) {
                if byte & (1 << shift) != 0 {
                    guard !zeroSeen else { throw PairingError.malformed }; prefix += 1
                } else { zeroSeen = true }
            }
        }
        guard prefix > 0 else { throw PairingError.malformed }
        clientAddress = source; serverAddress = destination; prefixLength = prefix
        self.mtu = mtu; rsdPort = UInt16(port)
    }
    private static func integer(_ value: Any?) -> Int? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
              n.stringValue.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
        return Int(n.stringValue)
    }
    private static func address(_ value: Any?) -> IPv6Address? {
        guard let text = value as? String, !text.contains("%"), let address = IPv6Address(text) else { return nil }
        let bytes = Array(address.rawValue)
        guard bytes.count == 16, bytes[0] != 255, bytes.contains(where: { $0 != 0 }),
              !(bytes.prefix(15).allSatisfy({ $0 == 0 }) && bytes[15] == 1),
              !(bytes.prefix(10).allSatisfy({ $0 == 0 }) && bytes[10] == 255 && bytes[11] == 255) else { return nil }
        return address
    }
    func validatePacket(_ packet: Data, outgoing: Bool) throws {
        guard packet.count >= 40, packet.count <= mtu else { throw PairingError.oversized }
        let bytes = Array(packet.prefix(40))
        guard bytes[0] >> 4 == 6, 40 + Int(bytes[4]) * 256 + Int(bytes[5]) == packet.count,
              Data(bytes[8..<24]) == (outgoing ? clientAddress.rawValue : serverAddress.rawValue),
              Data(bytes[24..<40]) == (outgoing ? serverAddress.rawValue : clientAddress.rawValue) else {
            throw PairingError.malformed
        }
    }
    func isIncomingEndpoint(_ packet: Data) -> Bool {
        guard packet.count >= 40 else { return false }
        let header = Array(packet.prefix(40))
        return Data(header[8..<24]) == serverAddress.rawValue && Data(header[24..<40]) == clientAddress.rawValue
    }
}

// The TLS stream changes format once: framed JSON handshake -> raw IPv6
// packets. A receive may split any header/body or contain both formats.
struct CDTunnelStream {
    enum Event { case configured(CDTunnelConfiguration), packet(Data) }
    private(set) var configuration: CDTunnelConfiguration?
    private var handshake = PairingFrameDecoder(.tunnel)
    private var handshakeBytes = 0
    private var packet = Data()
    private var packetLength: Int?
    private var started = false
    private var failed = false
    private(set) var diagnosticStage = "configuration pending"
    let requestedMTU: Int
    var hasPartialPacket: Bool { !packet.isEmpty }
    init(mtu: Int = 16000) throws {
        guard mtu >= 1280 && mtu <= 16000 else { throw PairingError.oversized }
        requestedMTU = mtu
    }
    mutating func begin() throws -> Data {
        guard !started, !failed else { throw PairingError.invalidState }
        started = true
        let data = try JSONSerialization.data(withJSONObject: ["type": "clientHandshakeRequest", "mtu": requestedMTU], options: [.sortedKeys])
        return try PairingFrameDecoder.encode(data, format: .tunnel)
    }
    mutating func consume(_ data: Data) throws -> [Event] {
        guard started, !failed else { throw PairingError.invalidState }
        do {
            guard data.count <= 65_536 else { throw PairingError.oversized }
            var events: [Event] = []
            for byte in data {
                if let configuration {
                    if packet.isEmpty && byte >> 4 != 6 { throw PairingError.malformed }
                    packet.append(byte)
                    if packet.count == 6 {
                        let length = 40 + Int(packet[4]) * 256 + Int(packet[5])
                        guard length <= configuration.mtu else { throw PairingError.oversized }
                        packetLength = length
                    }
                    if packet.count == packetLength {
                        let bytes = Array(packet.prefix(40))
                        diagnosticStage = "IPv6 next=\(bytes[6]), bytes=\(packet.count), sourceMatch=\(Data(bytes[8..<24]) == configuration.serverAddress.rawValue), destinationMatch=\(Data(bytes[24..<40]) == configuration.clientAddress.rawValue)"
                        // This is an IP tunnel, not a stream containing only our
                        // TCP tuple. The device also emits IPv6 control traffic.
                        // Discard unrelated, completely framed packets before
                        // demultiplexing; never deliver them to our TCP engines.
                        if configuration.isIncomingEndpoint(packet) {
                            try configuration.validatePacket(packet, outgoing: false)
                            events.append(.packet(packet))
                        }
                        packet = Data(); packetLength = nil
                    }
                } else {
                    handshakeBytes += 1
                    guard handshakeBytes <= 16_394 else { throw PairingError.oversized }
                    if let response = try handshake.consume(byte) {
                        let parsed = try CDTunnelConfiguration(response: response, requestedMTU: requestedMTU)
                        configuration = parsed; events.append(.configured(parsed))
                    }
                }
            }
            return events
        } catch { failed = true; packet = Data(); throw error }
    }
    mutating func finish() throws {
        guard started, !failed, configuration != nil, packet.isEmpty else {
            failed = true; packet = Data(); throw PairingError.malformed
        }
        failed = true // EOF is terminal even at a packet boundary.
    }
}
