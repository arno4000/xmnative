import Foundation
import HeadphoneKit

/// Which Sony command table a device speaks. Chosen by the RFCOMM service UUID (l1 in the app).
public enum SonyTableSet: Sendable {
    /// Service 96CC203E-5068-46AD-B32D-E316F5E069BA – WH-1000XM4 / WF-1000XM4 generation and older.
    case one
    /// Service 956C7B26-D49A-4BA8-B03F-B17D393CB6E2 – WH-1000XM5 / XM6 / WF-1000XM5 generation and newer.
    case two
}

/// Decoded meaning of a single incoming message. Pure data, so it can be unit-tested.
public enum SonyUpdate: Equatable, Sendable {
    case protocolVersion(Int)
    case modelName(String)
    case firmwareVersion(String)
    case supportedFunctions([UInt8])

    case battery(BatteryLevel)
    case leftRightBattery(left: BatteryLevel, right: BatteryLevel)
    case caseBattery(BatteryLevel)
    case codec(AudioCodec)

    /// Table set 1 NC/ASM capability.
    case ncAsmCapabilityV1(inquiredType: UInt8, ncSettingType: UInt8, asmSettingType: UInt8, asmMaxLevel: Int, hasVoiceMode: Bool)
    case noise(SonyNoiseSnapshot)

    case eqCapability(bandCount: Int, levelSteps: Int, presets: [EqPreset])
    case eqParam(presetID: Int, bandSteps: [Int])
    case eqBandInfo([SonyEqBandInfo])

    case speakToChat(Bool)
    case speakToChatDetails(SpeakToChatSensitivity, voiceFocus: Bool?, SpeakToChatTimeout)

    case autoPowerOffOptions([UInt8])
    case autoPowerOff(active: UInt8, selectTime: UInt8)

    case upscalingType(UInt8)
    case upscaling(Bool)
    case connectionPriority(ConnectionPriority)

    case generalSettingCapability(id: UInt8, title: String, subtitle: String?, isBoolean: Bool)
    case generalSetting(id: UInt8, isOn: Bool)

    case wearPause(Bool)
    case assignableCapability([SonyAssignableKey])
    case assignable([UInt8])
    case playbackCapability(maxVolume: Int)
    case playStatus(isPlaying: Bool?)
    case volume(Int)
    case metadata(type: UInt8, text: String?)
    case metadataChanged(type: UInt8)
    case voiceGuidance(Bool)
    /// Table set 2 voice guidance, with the inquired type it was read through and the language byte (type 02).
    case voiceGuidanceV2(type: UInt8, isOn: Bool, language: UInt8?)
    case optimizerAvailable
    case optimizerStatus(UInt8)

    case unknown(command: UInt8)
}

public struct SonyAssignableKey: Equatable, Sendable {
    public var key: UInt8
    public var keyType: UInt8
    public var defaultPreset: UInt8
    public var presets: [UInt8]
}

public struct SonyNoiseSnapshot: Equatable, Sendable {
    public var inquiredType: UInt8
    public var mode: NoiseMode
    public var ambientLevel: Int
    public var voiceFocus: Bool
    /// Table set 2 only: adaptive NC fields to round-trip unchanged.
    public var trailer: [UInt8] = []
}

public struct SonyEqBandInfo: Equatable, Sendable {
    public var kind: UInt8   // 1 Hz, 2 kHz, 0x10 specific (value 1 = Clear Bass)
    public var value: Int
    public var label: String {
        switch kind {
        case 0x01: return value >= 1000 ? Self.k(Double(value) / 1000) : "\(value)"
        case 0x02: return Self.k(Double(value) / 10)
        case 0x10 where value == 1: return "Clear Bass"
        default: return "?"
        }
    }
    public var isClearBass: Bool { kind == 0x10 && value == 1 }
    private static func k(_ v: Double) -> String {
        v == v.rounded() ? "\(Int(v))k" : String(format: "%.1fk", v)
    }
}

// MARK: - Shared helpers

enum SonyDecode {
    static func string(_ p: [UInt8], lengthAt i: Int, max: Int = 128) -> (String, next: Int)? {
        guard i < p.count else { return nil }
        let n = min(Int(p[i]), max)
        guard i + 1 + n <= p.count else { return nil }
        let s = String(decoding: p[(i + 1) ..< (i + 1 + n)], as: UTF8.self)
        return (s, i + 1 + n)
    }

    static func level(_ percent: UInt8, _ status: UInt8) -> BatteryLevel {
        BatteryLevel(percent: Int(percent), isCharging: status == 0x01)
    }

    static func codec(_ raw: UInt8) -> AudioCodec {
        switch raw {
        case 0x01: return .sbc
        case 0x02: return .aac
        case 0x10: return .ldac
        case 0x20: return .aptX
        case 0x21: return .aptXHD
        case 0x30: return .lc3
        case 0x00: return .unknown
        default: return .other
        }
    }

    static func eqPresets(_ p: [UInt8], countAt i: Int) -> [EqPreset] {
        guard i < p.count else { return [] }
        var presets: [EqPreset] = []
        var off = i + 1
        for _ in 0 ..< Int(p[i]) {
            guard off + 1 < p.count else { break }
            let id = Int(p[off])
            let (name, next) = string(p, lengthAt: off + 1) ?? ("", p.count)
            presets.append(EqPreset(id: id, name: name.isEmpty ? SonyEqNames.name(for: id) : name,
                                    isCustomizable: SonyEqNames.isCustomizable(id)))
            off = next
        }
        return presets
    }
}

enum SonyEqNames {
    static func name(for id: Int) -> String {
        switch id {
        case 0x00: return "Off"
        case 0x01: return "Rock"
        case 0x02: return "Pop"
        case 0x03: return "Jazz"
        case 0x04: return "Dance"
        case 0x05: return "EDM"
        case 0x06: return "R&B/Hip-Hop"
        case 0x07: return "Acoustic"
        case 0x10: return "Bright"
        case 0x11: return "Excited"
        case 0x12: return "Mellow"
        case 0x13: return "Relaxed"
        case 0x14: return "Vocal"
        case 0x15: return "Treble Boost"
        case 0x16: return "Bass Boost"
        case 0x17: return "Speech"
        case 0x20: return "Gaming"
        case 0xA0: return "Custom"
        case 0xA1 ... 0xA5: return "User Setting \(id - 0xA0)"
        default: return "Preset \(id)"
        }
    }

    static func isCustomizable(_ id: Int) -> Bool { id == 0xA0 || (0xA1 ... 0xA5).contains(id) }
}
