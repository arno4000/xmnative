import Foundation

// Sony "Tandem" framing, as implemented in Sound Connect 13.3.0
// (qm0.a / qm0.b / cp0.b / cp0.f / qm0.e in the decompiled APK):
//
//   0x3E | escape( dataType, seq, len[4, big endian], payload[len], checksum ) | 0x3C
//
// checksum = (sum of dataType..payload) & 0xFF
// escaping: 0x3C → 3D 2C, 0x3D → 3D 2D, 0x3E → 3D 2E   (unescape: 3D x → x | 0x10)

public enum MDRDataType: UInt8, Sendable {
    case data = 0x00
    case ack = 0x01
    case dataMCNo1 = 0x02
    case dataSSH = 0x07
    case dataICD = 0x09
    case dataEV = 0x0A
    /// Command table 1 (both table sets use this byte; the RFCOMM service decides the table).
    case dataMDR = 0x0C
    case dataCommon = 0x0D
    /// Command table 2 (voice guidance, peripherals, ...).
    case dataMDRNo2 = 0x0E
    case shot = 0x10
    case shotMCNo1 = 0x12
    case shotICD = 0x19
    case shotEV = 0x1A
    case shotMDR = 0x1C
    case shotCommon = 0x1D
    case shotMDRNo2 = 0x1E
    case largeDataSSH = 0x27
    case largeDataMDR = 0x2C
    case largeDataCommon = 0x2D

    public static func requiresAck(_ raw: UInt8) -> Bool {
        guard let t = MDRDataType(rawValue: raw) else { return true }
        switch t {
        case .ack, .shot, .shotMCNo1, .shotICD, .shotEV, .shotMDR, .shotCommon, .shotMDRNo2: return false
        default: return true
        }
    }
}

public struct MDRFrame: Equatable, Sendable {
    public var dataType: UInt8
    public var sequence: UInt8
    public var payload: [UInt8]

    public init(dataType: UInt8, sequence: UInt8, payload: [UInt8]) {
        self.dataType = dataType
        self.sequence = sequence
        self.payload = payload
    }

    public init(_ type: MDRDataType, sequence: UInt8, payload: [UInt8]) {
        self.init(dataType: type.rawValue, sequence: sequence, payload: payload)
    }
}

public enum MDRFraming {
    public static let startByte: UInt8 = 0x3E
    public static let endByte: UInt8 = 0x3C
    public static let escapeByte: UInt8 = 0x3D

    public static func checksum<C: Collection>(_ bytes: C) -> UInt8 where C.Element == UInt8 {
        bytes.reduce(0) { $0 &+ $1 }
    }

    public static func escape(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count + 4)
        for b in bytes {
            switch b {
            case 0x3C, 0x3D, 0x3E: out.append(escapeByte); out.append(b & ~0x10)
            default: out.append(b)
            }
        }
        return out
    }

    public static func unescape(_ bytes: [UInt8]) throws -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            if bytes[i] == escapeByte {
                i += 1
                guard i < bytes.count else { throw MDRFrameError.danglingEscape }
                out.append(bytes[i] | 0x10)
            } else {
                out.append(bytes[i])
            }
            i += 1
        }
        return out
    }

    public static func encode(_ frame: MDRFrame) -> [UInt8] {
        let n = UInt32(frame.payload.count)
        var body: [UInt8] = [frame.dataType, frame.sequence,
                             UInt8(truncatingIfNeeded: n >> 24), UInt8(truncatingIfNeeded: n >> 16),
                             UInt8(truncatingIfNeeded: n >> 8), UInt8(truncatingIfNeeded: n)]
        body += frame.payload
        body.append(checksum(body))
        return [startByte] + escape(body) + [endByte]
    }

    /// ACK for a received frame: the app answers sequence `s` with `1 - s` (cp0.d.a).
    public static func ack(forReceivedSequence seq: UInt8) -> [UInt8] {
        encode(MDRFrame(.ack, sequence: 1 &- seq, payload: []))
    }

    /// Decodes one unescaped frame body (everything between the start and end byte).
    public static func decodeBody(_ escaped: [UInt8]) throws -> MDRFrame {
        let b = try unescape(escaped)
        guard b.count >= 7 else { throw MDRFrameError.tooShort }
        guard checksum(b.dropLast()) == b[b.count - 1] else { throw MDRFrameError.badChecksum }
        let len = Int(b[2]) << 24 | Int(b[3]) << 16 | Int(b[4]) << 8 | Int(b[5])
        guard len >= 0, len <= b.count - 7 else { throw MDRFrameError.badLength }
        return MDRFrame(dataType: b[0], sequence: b[1], payload: Array(b[6 ..< 6 + len]))
    }
}

public enum MDRFrameError: Error, Equatable {
    case danglingEscape, tooShort, badChecksum, badLength
}

/// Streaming decoder: feed arbitrary chunks, get complete frames out.
public struct MDRFrameDecoder {
    private var buffer: [UInt8] = []
    private var inFrame = false

    public init() {}

    public mutating func feed(_ bytes: [UInt8]) -> [Result<MDRFrame, MDRFrameError>] {
        var out: [Result<MDRFrame, MDRFrameError>] = []
        for byte in bytes {
            if !inFrame {
                if byte == MDRFraming.startByte { inFrame = true; buffer.removeAll(keepingCapacity: true) }
                continue
            }
            if byte == MDRFraming.endByte {
                inFrame = false
                do { out.append(.success(try MDRFraming.decodeBody(buffer))) }
                catch let e as MDRFrameError { out.append(.failure(e)) }
                catch { out.append(.failure(.tooShort)) }
                buffer.removeAll(keepingCapacity: true)
            } else if byte == MDRFraming.startByte {
                // Resync on a stray start byte.
                buffer.removeAll(keepingCapacity: true)
            } else {
                buffer.append(byte)
            }
        }
        return out
    }
}
