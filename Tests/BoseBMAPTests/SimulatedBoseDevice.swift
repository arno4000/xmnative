import Foundation
import HeadphoneKit
@testable import BoseBMAP

/// An in-process fake QC Ultra Headphones (2nd Gen) answering BMAP packets. No Bluetooth involved.
/// Reply layouts follow the response parsers in the Bose app 13.4.2.
@MainActor
final class SimulatedBoseDevice: ByteTransport {
    var onReceive: (([UInt8]) -> Void)?
    var onClose: ((Error?) -> Void)?
    /// Every packet the "headphones" received.
    private(set) var received: [BMAPPacket] = []
    var latency: Duration = .milliseconds(5)
    /// Functions that answer with Error 4 (function not supported).
    var unsupported: Set<BMAPKey> = []

    private var decoder = BMAPPacketDecoder()
    private var closed = false

    // Device state
    var battery: UInt8 = 64
    var charging: UInt8 = 0
    var currentMode: UInt8 = 0
    // Device CNC: 0 = most cancelling.
    var modes: [[UInt8]] = [
        SimulatedBoseDevice.mode(0, prompt: 1, cnc: 0, spatial: 0, favorite: true),                       // Quiet
        SimulatedBoseDevice.mode(1, prompt: 2, cnc: 10, spatial: 0, flags: 0x02, autoCNC: true, favorite: true), // Aware, ActiveSense
        SimulatedBoseDevice.mode(2, prompt: 34, cnc: 0, spatial: 1, flags: 0x04, favorite: true),          // Immersion
        SimulatedBoseDevice.mode(3, prompt: 12, cnc: 3, spatial: 0, user: true, name: "Bus", flags: 0x1F, favorite: true),
        SimulatedBoseDevice.mode(4, prompt: 0, cnc: 5, spatial: 0, user: true, configured: false, flags: 0x1F),
    ]
    var favorites: Set<Int> = [0, 1, 2, 3]
    var settingsConfig: [UInt8] = [2, 0, 0, 0, 1]   // cnc 2, auto off, spatial off, wind off, anc on
    /// Prompt ids offered for user modes.
    var names: [UInt8] = [7, 10, 11, 12, 13, 15]
    var resetSupported = true
    var eq: [Int8] = [3, 0, -2]   // bass, mid, treble
    var standby: UInt8 = 20
    var voicePrompts: UInt8 = 0x21  // US English, on
    var multipoint: UInt8 = 0x03    // supported, on
    var onHead: [UInt8] = [0x07, 0x01]
    var volume: UInt8 = 12

    /// ModeConfig Status (AudioModesModeConfigResponse): 48 bytes.
    /// flags: bit0 cnc, bit1 auto cnc, bit2 spatial, bit3 wind, bit4 anc mutable.
    static func mode(_ i: UInt8, prompt: UInt8, cnc: UInt8, spatial: UInt8, user: Bool = false, configured: Bool = true,
                     name: String = "", flags: UInt8 = 0, autoCNC: Bool = false, favorite: Bool = false) -> [UInt8] {
        var p: [UInt8] = [i, 0, prompt, user ? 1 : 0, user && configured ? 1 : 0, favorite ? 1 : 0]
        p += BMAP.modeName(name)                         // [6..37]
        p += [0, 0, 0]                                    // [38..40]
        p.append(flags)                                   // [41]
        p += [cnc, autoCNC ? 1 : 0, spatial, 0, 0, 1]     // [42..47]: cnc, auto, spatial, ?, wind, anc
        return p
    }

    /// Mode config bytes without a device, for parser tests.
    nonisolated static func modeBytes(prompt: UInt8, flags: UInt8) -> [UInt8] {
        var p: [UInt8] = [0, 0, prompt, 0, 0, 0] + BMAP.modeName("") + [0, 0, 0, flags]
        p += [0, 0, 0, 0, 0, 1]
        return p
    }

    func write(_ bytes: [UInt8]) throws {
        guard !closed else { throw HeadphoneError.disconnected }
        for packet in decoder.feed(bytes) {
            received.append(packet)
            if unsupported.contains(packet.key) {
                emit(BMAPPacket(packet.block, packet.function, .error, [0x04]))
                continue
            }
            respond(to: packet).forEach(emit)
        }
    }

    func close() { closed = true }

    private func emit(_ packet: BMAPPacket) {
        let bytes = packet.encoded()
        let delay = latency
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !self.closed else { return }
            self.onReceive?(bytes)
        }
    }

    private func status(_ p: BMAPPacket, _ payload: [UInt8]) -> BMAPPacket {
        BMAPPacket(p.block, p.function, .status, payload)
    }

    private func respond(to p: BMAPPacket) -> [BMAPPacket] {
        switch (p.block, p.function, p.op) {
        case (0, 1, .get): return [status(p, Array("1.4.0".utf8))]
        case (0, 2, .get): return [status(p, BMAP.bitset([0, 1, 2, 4, 5, 7, 9, 31]))]
        case (0, 3, .get): return [status(p, [0x40, 0x82, 0x01])]
        case (0, 5, .get): return [status(p, Array("1.2.11".utf8))]
        case (9, 2, .setGet): return [status(p, p.payload)]

        case (1, 2, .get): return [status(p, [0x00] + Array("Arno's QC Ultra".utf8))]
        case (1, 5, .get): return [status(p, [11, 5, 0x01])]
        case (1, 7, .get): return [eqStatus()]
        case (1, 7, .setGet):
            let band = Int(p.payload[1])
            if band < eq.count { eq[band] = Int8(bitPattern: p.payload[0]) }
            return [eqStatus()]
        case (1, 4, .get): return [status(p, [standby, 0x00])]
        case (1, 4, .setGet): standby = p.payload[0]; return [status(p, [standby, 0x00])]
        case (1, 3, .get): return [status(p, [voicePrompts, 0, 0, 0, 0x03])]
        case (1, 3, .setGet): voicePrompts = p.payload[0]; return [status(p, [voicePrompts, 0, 0, 0, 0x03])]
        case (1, 10, .get): return [status(p, [multipoint])]
        case (1, 10, .setGet): multipoint = 0x02 | p.payload[0]; return [status(p, [multipoint])]
        case (1, 16, .get): return [status(p, onHead)]
        case (1, 16, .setGet): onHead = [0x06 | p.payload[0], p.payload[1]]; return [status(p, onHead)]

        case (2, 2, .get): return [status(p, [battery, 0x01, 0x2C, 0x00])]
        case (2, 5, .get): return [status(p, [charging])]

        case (5, 5, .get): return [status(p, [31, volume])]
        case (5, 5, .setGet): volume = p.payload[0]; return [status(p, [31, volume])]
        case (5, 4, .get): return [status(p, [0x01, 0x00, 0x00])]
        case (5, 6, .start):
            return [status(p, [0x00] + Array("Song".utf8)), status(p, [0x01] + Array("Artist".utf8)),
                    BMAPPacket(5, 6, .result)]
        case (5, 3, .start): return [BMAPPacket(5, 3, .result, p.payload)]

        case (31, 2, .get): return [status(p, [3, 2, 0, 0, 0, 0x3F, 1])]
        case (31, 11, .get):
            var bitmap = [UInt8](repeating: 0, count: 5)
            for n in names { bitmap[Int(n) / 8] |= 1 << (n % 8) }
            return [status(p, bitmap)]
        case (31, 8, .get): return [favoritesStatus()]
        case (31, 8, .setGet):
            let n = Int(p.payload[0])
            favorites = Set(BMAP.bits(p.payload[1...]).filter { $0 < n })
            return [favoritesStatus()]
        case (31, 10, .get): return [status(p, settingsConfig)]
        case (31, 10, .setGet): settingsConfig = p.payload; return [status(p, settingsConfig)]
        case (31, 9, .start):
            guard resetSupported else { return [BMAPPacket(31, 9, .error, [0x05])] }
            let i = Int(p.payload[0])
            modes[i] = Self.mode(UInt8(i), prompt: 0, cnc: 5, spatial: 0, user: true, configured: false, flags: 0x1F)
            return [BMAPPacket(31, 9, .result, [UInt8(i)])]
        case (31, 6, .get): return [status(p, modes[Int(p.payload[0])])]
        case (31, 6, .start):
            return modes.map { BMAPPacket(31, 6, .status, $0) } + [BMAPPacket(31, 6, .result)]
        case (31, 6, .setGet):
            // Request: [i][prompt 2][name 32][cnc][autoCNC][spatial][wind][anc]
            let q = p.payload
            let i = Int(q[0])
            guard i < modes.count, q.count >= 37 else { return [BMAPPacket(31, 6, .error, [0x06])] }
            modes[i][1] = q[1]
            modes[i][2] = q[2]
            modes[i][4] = q[2] == 0 ? 0 : 1
            modes[i].replaceSubrange(6 ..< 38, with: q[3 ..< 35])
            modes[i][42] = q[35]
            modes[i][43] = q[36]
            if q.count > 37 { modes[i][44] = q[37] }
            if q.count > 38 { modes[i][46] = q[38] }
            if q.count > 39 { modes[i][47] = q[39] }
            return [status(p, modes[i])]
        case (31, 3, .get): return [status(p, [currentMode])]
        case (31, 3, .start):
            currentMode = p.payload[0]
            return [BMAPPacket(31, 3, .processing), status(p, [currentMode])]

        default:
            return [BMAPPacket(p.block, p.function, .error, [0x04])]
        }
    }

    private func favoritesStatus() -> BMAPPacket {
        let n = modes.count
        var p = [UInt8](repeating: 0, count: (n + 7) / 8 + 1)
        p[0] = UInt8(n)
        for m in favorites { p[p.count - 1 - m / 8] |= 1 << (m % 8) }
        return BMAPPacket(31, 8, .status, p)
    }

    private func eqStatus() -> BMAPPacket {
        // [min][max][current][band] per band
        BMAPPacket(1, 7, .status, eq.enumerated().flatMap { i, v in [0xF6, 0x0A, UInt8(bitPattern: v), UInt8(i)] })
    }

    /// The user pressed something on the headphones.
    func pushCurrentMode(_ i: UInt8) {
        currentMode = i
        emit(BMAPPacket(31, 3, .status, [i]))
    }
}
