import Foundation
import HeadphoneKit
@testable import SonyMDR

/// An in-process fake WH-1000XM4 speaking table set 1 over real MDR frames.
/// Used by tests and by the app's demo mode – no Bluetooth involved.
@MainActor
final class SimulatedSonyV1Device: ByteTransport {
    public var onReceive: (([UInt8]) -> Void)?
    public var onClose: ((Error?) -> Void)?
    /// Every payload the "headphones" received, for assertions.
    public private(set) var received: [[UInt8]] = []
    public var latency: Duration = .milliseconds(15)

    private var decoder = MDRFrameDecoder()
    private var seq: UInt8 = 0
    private var closed = false

    // Device state
    public var battery: UInt8 = 70
    var nc: [UInt8] = [0x01, 0x02, 0x02, 0x01, 0x00, 0x00]   // effect ncType ncValue asmType asmId level → NC on
    var eqPreset: UInt8 = 0x10
    var eqBands: [UInt8] = [10, 9, 10, 12, 13, 12]
    var stc: UInt8 = 0
    var stcDetail: [UInt8] = [0x00, 0x00, 0x01, 0x01]
    var apo: [UInt8] = [0x11, 0x00]
    var dsee: UInt8 = 1
    var connection: UInt8 = 0
    var gs: [UInt8: UInt8] = [0xD1: 1, 0xD2: 1]
    var wearPause: UInt8 = 1
    var button: UInt8 = 0x00
    var volume: UInt8 = 15
    var playing: UInt8 = 1
    var voiceGuidance: UInt8 = 1

    public init() {}

    public func write(_ bytes: [UInt8]) throws {
        guard !closed else { throw HeadphoneError.disconnected }
        for case .success(let frame) in decoder.feed(bytes) {
            if frame.dataType == MDRDataType.ack.rawValue { continue }
            // ACK with the next sequence number, then answer.
            emit(MDRFrame(.ack, sequence: 1 &- frame.sequence, payload: []))
            received.append(frame.payload)
            let table2 = frame.dataType == MDRDataType.dataMDRNo2.rawValue
            for reply in table2 ? respondTable2(to: frame.payload) : respond(to: frame.payload) {
                emit(MDRFrame(table2 ? .dataMDRNo2 : .dataMDR, sequence: seq, payload: reply))
                seq = 1 &- seq
            }
        }
    }

    public func close() {
        closed = true
    }

    private func emit(_ frame: MDRFrame) {
        let bytes = MDRFraming.encode(frame)
        let delay = latency
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !self.closed else { return }
            self.onReceive?(bytes)
        }
    }

    private func str(_ s: String) -> [UInt8] { let u = Array(s.utf8); return [UInt8(u.count)] + u }

    private func respond(to p: [UInt8]) -> [[UInt8]] {
        guard let cmd = p.first else { return [] }
        let t = p.count > 1 ? p[1] : 0
        switch cmd {
        case 0x00: return [[0x01, 0x00, 0x01, 0x10]]
        case 0x04 where t == 1: return [[0x05, 0x01] + str("WH-1000XM4")]
        case 0x04 where t == 2: return [[0x05, 0x02] + str("2.6.1")]
        case 0x06: return [[0x07, 0x00, 14, 0x11, 0x13, 0x51, 0x62, 0xD1, 0xD2, 0xE1, 0xE2, 0xF4, 0xF5, 0x39, 0xF3, 0xF6, 0xA1]]
        case 0xF6 where t == 0x03: return [[0xF7, 0x03, 0x00, wearPause]]
        case 0xF8 where t == 0x03: wearPause = p[3]; return [[0xF9, 0x03, 0x00, wearPause]]
        // one custom button: ambient control (cycles NC/ASM/off), Google Assistant, Alexa
        case 0xF0 where t == 0x06:
            return [[0xF1, 0x06, 0x01, 0x02, 0x01, 0x00, 0x03,
                     0x00, 0x01, 0x00, 0x01,
                     0x31, 0x01, 0x00, 0x32,
                     0x32, 0x01, 0x00, 0x30]]
        case 0xF6 where t == 0x06: return [[0xF7, 0x06, 0x01, button]]
        case 0xF8 where t == 0x06: if p[3] != 0xFE { button = p[3] }; return [[0xF9, 0x06, 0x01, button]]
        case 0xA0: return [[0xA1, 0x01, 30, 0x00, 0x00]]
        case 0xA2: return [[0xA3, 0x01, 0x00, playing]]
        case 0xA4: playing = p[3] == 0x01 ? 2 : 1; return [[0xA5, 0x01, 0x00, playing]]
        case 0xA6 where p.count > 2 && p[2] == 0x20: return [[0xA7, 0x01, 0x20, volume]]
        case 0xA6 where p.count > 2 && p[2] == 0x00: return [[0xA7, 0x01, 0x00, 0x02] + str("Teardrop")]
        case 0xA6 where p.count > 2 && p[2] == 0x02: return [[0xA7, 0x01, 0x02, 0x02] + str("Massive Attack")]
        case 0xA8: volume = p[3]; return [[0xA9, 0x01, 0x20, volume]]
        case 0x10: return [[0x11, 0x00, battery, 0x00]]
        case 0x18: return [[0x19, 0x00, 0x10]]
        case 0x60: return [[0x61, 0x02, 0x02, 0x02, 0x01, 0x02, 0x00, 20, 0x01, 20]]
        case 0x66: return [[0x67, 0x02] + nc]
        case 0x68:
            nc = Array(p[2...])
            return [[0x69, 0x02] + nc]
        case 0x50:
            let presets: [UInt8] = [0x00, 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0xA0, 0xA1, 0xA2]
            return [[0x51, 0x01, 6, 21, UInt8(presets.count)] + presets.flatMap { [$0, 0x00] }]
        case 0x5A: return [[0x5B, 0x01, 6, 0x10, 0x00, 0x01, 0x01, 0x01, 0x90, 0x02, 0x00, 10, 0x02, 0x00, 25, 0x02, 0x00, 63, 0x02, 0x00, 160]]
        case 0x56: return [[0x57, 0x01, eqPreset, 6] + eqBands]
        case 0x58:
            if p[2] == 0xFF { eqBands = Array(p[4...]); eqPreset = 0xA0 } else { eqPreset = p[2]; eqBands = presetBands(p[2]) }
            return [[0x59, 0x01, eqPreset, 6] + eqBands]
        case 0xF0 where t == 0x04: return [[0xF1, 0x04, 2, 0x10, 0x11]]
        case 0xF6 where t == 0x04: return [[0xF7, 0x04, 0x01] + apo]
        case 0xF6 where t == 0x05: return [[0xF7, 0x05, 0x00, stc]]
        case 0xFA where t == 0x05: return [[0xFB, 0x05] + stcDetail]
        case 0xF8 where t == 0x04: apo = Array(p[3...]); return [[0xF9, 0x04, 0x01] + apo]
        case 0xF8 where t == 0x05: stc = p[3]; return [[0xF9, 0x05, 0x01, stc]]
        case 0xFC where t == 0x05: stcDetail = Array(p[2...]); return [[0xFD, 0x05] + stcDetail]
        case 0xE0 where t == 0x02: return [[0xE1, 0x02, 0x02, 0x00]]
        case 0xE6 where t == 0x02: return [[0xE7, 0x02, 0x00, dsee]]
        case 0xE6 where t == 0x01: return [[0xE7, 0x01, 0x00, connection]]
        case 0xE8 where t == 0x02: dsee = p[3]; return [[0xE9, 0x02, 0x00, dsee]]
        case 0xE8 where t == 0x01: connection = p[3]; return [[0xE9, 0x01, 0x00, connection]]
        case 0xD0:
            let key = t == 0xD1 ? "TOUCH_PANEL_SETTING" : "MULTIPOINT_SETTING"
            return [[0xD1, t, 0x02] + str(key) + [0x00, 0x01]]
        case 0xD6: return [[0xD7, t, 0x01, gs[t] ?? 0]]
        case 0xD8: gs[t] = p[3]; return [[0xD9, t, 0x01, p[3]]]
        default: return []
        }
    }

    private func respondTable2(to p: [UInt8]) -> [[UInt8]] {
        switch (p.first, p.count) {
        case (0x46, 3): return [[0x47, 0x01, 0x01, voiceGuidance]]
        case (0x48, 4): voiceGuidance = p[3]; return [[0x49, 0x01, 0x01, voiceGuidance]]
        default: return []
        }
    }

    private func presetBands(_ id: UInt8) -> [UInt8] {
        switch id {
        case 0x10: return [10, 9, 10, 12, 13, 12]
        case 0x11: return [13, 13, 9, 10, 12, 12]
        case 0x12: return [11, 12, 11, 9, 8, 7]
        case 0x14: return [8, 8, 11, 13, 12, 10]
        case 0x16: return [16, 15, 12, 10, 10, 10]
        default: return [10, 10, 10, 10, 10, 10]
        }
    }
}
