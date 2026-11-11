import Foundation

// Bose BMAP packets, as implemented in the Bose app 13.4.2
// (com.bose.bmap.messages.packets.BmapPacket, com.bose.bmap.service.SppConnectionManager):
//
//   fblock:u8  function:u8  (deviceID << 6 | port << 4 | operator):u8  length:u8  payload[length]
//
// No start/end markers, checksum, escaping, sequence numbers or ACKs. Over RFCOMM, packets are
// simply written back to back; a read can carry several of them.

public enum BMAPOperator: UInt8, Sendable {
    case set = 0
    case get = 1
    case setGet = 2
    case status = 3
    case error = 4
    case start = 5
    case result = 6
    case processing = 7
}

/// Function block IDs (BmapFunctionBlock).
public enum BMAPBlock {
    public static let productInfo: UInt8 = 0
    public static let settings: UInt8 = 1
    public static let status: UInt8 = 2
    public static let firmwareUpdate: UInt8 = 3
    public static let deviceManagement: UInt8 = 4
    public static let audioManagement: UInt8 = 5
    public static let callManagement: UInt8 = 6
    public static let control: UInt8 = 7
    public static let authentication: UInt8 = 18
    public static let audioModes: UInt8 = 31
}

public struct BMAPPacket: Equatable, Sendable, CustomStringConvertible {
    public var block: UInt8
    public var function: UInt8
    public var op: BMAPOperator
    public var deviceID: UInt8
    public var port: UInt8
    public var payload: [UInt8]

    public init(_ block: UInt8, _ function: UInt8, _ op: BMAPOperator, _ payload: [UInt8] = [], deviceID: UInt8 = 0, port: UInt8 = 0) {
        self.block = block
        self.function = function
        self.op = op
        self.deviceID = deviceID
        self.port = port
        self.payload = payload
    }

    /// Key used to match a reply to its request.
    public var key: BMAPKey { BMAPKey(block: block, function: function) }

    public func encoded() -> [UInt8] {
        precondition(payload.count <= 255, "BMAP payloads are at most 255 bytes")
        let opByte = (deviceID & 0x03) << 6 | (port & 0x03) << 4 | op.rawValue
        return [block, function, opByte, UInt8(payload.count)] + payload
    }

    public var description: String {
        "[\(block).\(function) \(op)] " + payload.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}

public struct BMAPKey: Hashable, Sendable {
    public var block: UInt8
    public var function: UInt8
    public init(block: UInt8, function: UInt8) { self.block = block; self.function = function }
}

/// Splits a byte stream into packets. Keeps partial packets across reads.
public struct BMAPPacketDecoder: Sendable {
    private var buffer: [UInt8] = []

    public init() {}

    public mutating func feed(_ bytes: [UInt8]) -> [BMAPPacket] {
        buffer += bytes
        var out: [BMAPPacket] = []
        var i = 0
        while buffer.count - i >= 4 {
            let len = Int(buffer[i + 3])
            guard buffer.count - i >= 4 + len else { break }
            let opByte = buffer[i + 2]
            // Unknown operator values (8...15) are reserved; keep them as `.error` so callers don't hang.
            let op = BMAPOperator(rawValue: opByte & 0x0F) ?? .error
            out.append(BMAPPacket(buffer[i], buffer[i + 1], op, Array(buffer[(i + 4) ..< (i + 4 + len)]),
                                  deviceID: opByte >> 6, port: (opByte >> 4) & 0x03))
            i += 4 + len
        }
        buffer.removeFirst(i)
        return out
    }
}

func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
}
