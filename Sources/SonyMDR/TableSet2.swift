import Foundation
import HeadphoneKit

/// Command table set 2 (com.sony.songpal.tandemfamily.message.mdr.v2.table1 in the app).
/// Used by WH-1000XM5 / XM6, WF-1000XM5 and newer. Same command byte layout as table 1,
/// but battery moved to POWER, NC/ASM got new inquired types, and on/off values are inverted
/// (OnOffSettingValue: ON = 0x00, OFF = 0x01). Exceptions: DSEE (00 off / 01 auto),
/// connection mode (00 sound / 01 connection) and auto power off (element ids).
public enum SonyV2 {
    enum Cmd {
        static let getProtocolInfo: UInt8 = 0x00, retProtocolInfo: UInt8 = 0x01
        static let getDeviceInfo: UInt8 = 0x04, retDeviceInfo: UInt8 = 0x05
        static let commonGetStatus: UInt8 = 0x12, commonRetStatus: UInt8 = 0x13, commonNtfyStatus: UInt8 = 0x15
        static let powerGetCapability: UInt8 = 0x20, powerRetCapability: UInt8 = 0x21
        static let powerGetStatus: UInt8 = 0x22, powerRetStatus: UInt8 = 0x23, powerNtfyStatus: UInt8 = 0x25
        static let powerGetParam: UInt8 = 0x26, powerRetParam: UInt8 = 0x27, powerSetParam: UInt8 = 0x28, powerNtfyParam: UInt8 = 0x29
        static let eqGetCapability: UInt8 = 0x50, eqRetCapability: UInt8 = 0x51
        static let eqGetParam: UInt8 = 0x56, eqRetParam: UInt8 = 0x57, eqSetParam: UInt8 = 0x58, eqNtfyParam: UInt8 = 0x59
        static let ncGetParam: UInt8 = 0x66, ncRetParam: UInt8 = 0x67, ncSetParam: UInt8 = 0x68, ncNtfyParam: UInt8 = 0x69
        static let gsGetCapability: UInt8 = 0xD0, gsRetCapability: UInt8 = 0xD1
        static let gsGetParam: UInt8 = 0xD6, gsRetParam: UInt8 = 0xD7, gsSetParam: UInt8 = 0xD8, gsNtfyParam: UInt8 = 0xD9
        static let audioGetParam: UInt8 = 0xE6, audioRetParam: UInt8 = 0xE7, audioSetParam: UInt8 = 0xE8, audioNtfyParam: UInt8 = 0xE9
        static let sysGetParam: UInt8 = 0xF6, sysRetParam: UInt8 = 0xF7, sysSetParam: UInt8 = 0xF8, sysNtfyParam: UInt8 = 0xF9
        static let sysGetExtParam: UInt8 = 0xFA, sysRetExtParam: UInt8 = 0xFB, sysSetExtParam: UInt8 = 0xFC, sysNtfyExtParam: UInt8 = 0xFD
    }

    /// v2 NcAsmInquiredType values we know how to drive, in probing order.
    public enum NcType {
        /// MODE_NC_ASM_DUAL_NC_MODE_SWITCH_AND_ASM_SEAMLESS – e.g. WH-1000XM5
        public static let dualSeamless: UInt8 = 0x17
        /// …_NA (noise adaptive) – e.g. WH-1000XM6 / WF-1000XM5
        public static let dualSeamlessAdaptive: UInt8 = 0x19
        /// MODE_NC_ASM_DUAL_SINGLE_…
        public static let dualSingleSeamless: UInt8 = 0x16
        /// MODE_NC_ASM_AUTO_…
        public static let autoSeamless: UInt8 = 0x15
        /// ASM_SEAMLESS (ambient only)
        public static let asmSeamless: UInt8 = 0x22
        public static let probeOrder: [UInt8] = [dualSeamless, dualSeamlessAdaptive, dualSingleSeamless, autoSeamless, asmSeamless]
    }

    enum PowerType { static let autoPowerOff: UInt8 = 0x04, autoPowerOffWearing: UInt8 = 0x05 }
    enum AudioType { static let connectionMode: UInt8 = 0x00, upscaling: UInt8 = 0x01 }
    enum SystemType { static let controlByWearing: UInt8 = 0x01, smartTalkingType1: UInt8 = 0x02, smartTalkingType2: UInt8 = 0x0C }

    // MARK: Requests

    public static func getProtocolInfo() -> [UInt8] { [Cmd.getProtocolInfo, 0x00] }
    public static func getModelName() -> [UInt8] { [Cmd.getDeviceInfo, 0x01] }
    public static func getFirmwareVersion() -> [UInt8] { [Cmd.getDeviceInfo, 0x02] }
    /// PowerInquiredType: 0 battery, 1 left/right, 2 case.
    public static func getBattery(_ type: UInt8) -> [UInt8] { [Cmd.powerGetStatus, type] }
    /// CommonInquiredType.AUDIO_CODEC = 2
    public static func getCodec() -> [UInt8] { [Cmd.commonGetStatus, 0x02] }
    public static func getNcAsm(_ type: UInt8) -> [UInt8] { [Cmd.ncGetParam, type] }

    /// 68 type valueChangeStatus(0 changing / 1 changed) onOff(1 on) mode(0 NC / 1 ASM) asmMode(0 normal / 1 voice) level [trailer]
    public static func setNcAsm(type: UInt8, mode: NoiseMode, ambientLevel: Int, voiceFocus: Bool, isFinal: Bool, trailer: [UInt8]) -> [UInt8] {
        let change: UInt8 = isFinal ? 0x01 : 0x00
        let on: UInt8 = mode == .off ? 0x00 : 0x01
        let level = UInt8(clamping: max(0, ambientLevel))
        if type == NcType.asmSeamless {
            return [Cmd.ncSetParam, type, change, on, voiceFocus ? 0x01 : 0x00, level]
        }
        let m: UInt8 = mode == .ambient ? 0x01 : 0x00
        var out: [UInt8] = [Cmd.ncSetParam, type, change, on, m, voiceFocus ? 0x01 : 0x00, level]
        if type == NcType.dualSeamlessAdaptive { out += trailer.count == 2 ? trailer : [0x00, 0x00] }
        return out
    }

    /// EQ inquired type: 00 preset EQ, 02 non-customizable, 04 preset EQ with error code (same layout).
    public static func getEqCapability(_ type: UInt8 = 0x00) -> [UInt8] { [Cmd.eqGetCapability, type] }
    public static func getEq(_ type: UInt8 = 0x00) -> [UInt8] { [Cmd.eqGetParam, type] }
    public static func selectEqPreset(_ id: Int, type: UInt8 = 0x00) -> [UInt8] { [Cmd.eqSetParam, type, UInt8(clamping: id), 0x00] }
    public static func setEqBands(_ steps: [Int], type: UInt8 = 0x00) -> [UInt8] {
        [Cmd.eqSetParam, type, 0xFF, UInt8(clamping: steps.count)] + steps.map { UInt8(clamping: $0) }
    }

    public static func getSpeakToChat() -> [UInt8] { [Cmd.sysGetParam, SystemType.smartTalkingType2] }
    /// F8 0C onOff(ON = 0) preview(OFF = 1)
    public static func setSpeakToChat(_ on: Bool) -> [UInt8] { [Cmd.sysSetParam, SystemType.smartTalkingType2, on ? 0x00 : 0x01, 0x01] }
    public static func getSpeakToChatDetails() -> [UInt8] { [Cmd.sysGetExtParam, SystemType.smartTalkingType2] }
    /// FC 0C sensitivity timeout (no voice-focus byte in type 2)
    public static func setSpeakToChatDetails(_ s: SpeakToChatSensitivity, _ t: SpeakToChatTimeout) -> [UInt8] {
        [Cmd.sysSetExtParam, SystemType.smartTalkingType2, SonyV1.sensitivityByte(s), SonyV1.timeoutByte(t)]
    }

    /// "Pause when taken off" (control by wearing, Kotlin V2ControlByWearingRepository). ON = 0x00.
    public static func getWearPause() -> [UInt8] { [Cmd.sysGetParam, SystemType.controlByWearing] }
    public static func setWearPause(_ on: Bool) -> [UInt8] { [Cmd.sysSetParam, SystemType.controlByWearing, on ? 0x00 : 0x01] }

    public static func getAutoPowerOffCapability() -> [UInt8] { [Cmd.powerGetCapability, PowerType.autoPowerOff] }
    public static func getAutoPowerOff() -> [UInt8] { [Cmd.powerGetParam, PowerType.autoPowerOff] }
    /// 28 04 active selectTime (no leading 01, unlike table set 1)
    public static func setAutoPowerOff(active: UInt8, selectTime: UInt8) -> [UInt8] {
        [Cmd.powerSetParam, PowerType.autoPowerOff, active, selectTime]
    }

    public static func getUpscaling() -> [UInt8] { [Cmd.audioGetParam, AudioType.upscaling] }
    /// E8 01 v (00 off, 01 auto – not inverted)
    public static func setUpscaling(_ on: Bool) -> [UInt8] { [Cmd.audioSetParam, AudioType.upscaling, on ? 0x01 : 0x00] }
    public static func getConnectionMode() -> [UInt8] { [Cmd.audioGetParam, AudioType.connectionMode] }
    public static func setConnectionPriority(_ p: ConnectionPriority) -> [UInt8] {
        [Cmd.audioSetParam, AudioType.connectionMode, p == .soundQuality ? 0x00 : 0x01]
    }

    /// General settings D1…D4. Different from table set 1: setting type 00 bool / 01 list, string format 00 raw / 01 enum.
    public static func getGeneralSettingCapability(_ id: UInt8) -> [UInt8] { [Cmd.gsGetCapability, id, 0x01] }
    public static func getGeneralSetting(_ id: UInt8) -> [UInt8] { [Cmd.gsGetParam, id] }
    public static func setGeneralSetting(_ id: UInt8, _ on: Bool) -> [UInt8] { [Cmd.gsSetParam, id, 0x00, on ? 0x00 : 0x01] }

    // MARK: Parsing

    public static func parse(_ p: [UInt8]) -> [SonyUpdate] {
        guard let cmd = p.first else { return [] }
        switch cmd {
        case Cmd.retProtocolInfo:
            guard p.count >= 4 else { return [] }
            return [.protocolVersion(Int(p[2]) << 8 | Int(p[3]))]
        case Cmd.retDeviceInfo:
            guard p.count >= 3 else { return [] }
            switch p[1] {
            case 0x01: return SonyDecode.string(p, lengthAt: 2).map { [.modelName($0.0)] } ?? []
            case 0x02: return SonyDecode.string(p, lengthAt: 2).map { [.firmwareVersion($0.0)] } ?? []
            default: return []
            }
        case Cmd.powerRetStatus, Cmd.powerNtfyStatus:
            return SonyV1.parseBattery(p)
        case Cmd.powerRetCapability:
            guard p.count >= 3, p[1] == PowerType.autoPowerOff else { return [] }
            let n = min(Int(p[2]), p.count - 3)
            return [.autoPowerOffOptions(Array(p[3 ..< 3 + n]))]
        case Cmd.powerRetParam, Cmd.powerNtfyParam:
            guard p.count >= 4, p[1] == PowerType.autoPowerOff else { return [] }
            return [.autoPowerOff(active: p[2], selectTime: p[3])]
        case Cmd.commonRetStatus, Cmd.commonNtfyStatus:
            guard p.count >= 3, p[1] == 0x02 else { return [] }
            return [.codec(SonyDecode.codec(p[2]))]
        case Cmd.ncRetParam, Cmd.ncNtfyParam:
            return parseNc(p)
        case Cmd.eqRetCapability:
            guard p.count >= 5, [0x00, 0x02, 0x04].contains(p[1]) else { return [] }
            return [.eqCapability(bandCount: Int(p[2]), levelSteps: Int(p[3]), presets: SonyDecode.eqPresets(p, countAt: 4))]
        case Cmd.eqRetParam, Cmd.eqNtfyParam:
            guard p.count >= 4, [0x00, 0x02, 0x04].contains(p[1]) else { return [] }
            let n = min(Int(p[3]), p.count - 4)
            return [.eqParam(presetID: Int(p[2]), bandSteps: p[4 ..< 4 + n].map(Int.init))]
        case Cmd.audioRetParam, Cmd.audioNtfyParam:
            guard p.count >= 3 else { return [] }
            switch p[1] {
            case AudioType.upscaling: return [.upscaling(p[2] == 0x01)]
            case AudioType.connectionMode, 0x02:
                switch p[2] {
                case 0x00: return [.connectionPriority(.soundQuality)]
                case 0x01: return [.connectionPriority(.connectionQuality)]
                default: return []
                }
            default: return []
            }
        case Cmd.sysRetParam, Cmd.sysNtfyParam:
            guard p.count >= 3 else { return [] }
            switch p[1] {
            case SystemType.smartTalkingType2, SystemType.smartTalkingType1: return [.speakToChat(p[2] == 0x00)]
            case SystemType.controlByWearing: return [.wearPause(p[2] == 0x00)]
            default: return []
            }
        case Cmd.sysRetExtParam, Cmd.sysNtfyExtParam:
            guard p.count >= 4, p[1] == SystemType.smartTalkingType2 else { return [] }
            return [.speakToChatDetails(SonyV1.sensitivity(p[2]), voiceFocus: nil, SonyV1.timeout(p[3]))]
        case Cmd.gsRetCapability:
            return parseGsCapability(p)
        case Cmd.gsRetParam, Cmd.gsNtfyParam:
            guard p.count >= 4, p[2] == 0x00 else { return [] }
            return [.generalSetting(id: p[1], isOn: p[3] == 0x00)]
        default:
            return [.unknown(command: cmd)]
        }
    }

    static func parseNc(_ p: [UInt8]) -> [SonyUpdate] {
        guard p.count >= 6 else { return [] }
        let type = p[1], on = p[3] == 0x01
        if type == NcType.asmSeamless {
            return [.noise(SonyNoiseSnapshot(inquiredType: type, mode: on ? .ambient : .off,
                                             ambientLevel: Int(p[5]), voiceFocus: p[4] == 0x01))]
        }
        guard p.count >= 7, NcType.probeOrder.contains(type) else { return [] }
        let mode: NoiseMode = !on ? .off : (p[4] == 0x01 ? .ambient : .noiseCancelling)
        return [.noise(SonyNoiseSnapshot(inquiredType: type, mode: mode, ambientLevel: Int(p[6]),
                                         voiceFocus: p[5] == 0x01, trailer: Array(p.dropFirst(7))))]
    }

    /// D1 id settingType format len title len subtitle …
    static func parseGsCapability(_ p: [UInt8]) -> [SonyUpdate] {
        guard p.count >= 6,
              let (title, i1) = SonyDecode.string(p, lengthAt: 4),
              let (subtitle, _) = SonyDecode.string(p, lengthAt: i1) else { return [] }
        let isEnum = p[3] == 0x01
        return [.generalSettingCapability(id: p[1],
                                          title: isEnum ? SonyGeneralSettingNames.title(title) : title,
                                          subtitle: subtitle.isEmpty || isEnum ? nil : subtitle,
                                          isBoolean: p[2] == 0x00)]
    }
}

/// Table 2 (DataType 0x0E) of table-set-2 devices: voice guidance.
public enum SonyV2Table2 {
    enum Cmd {
        static let vgGetParam: UInt8 = 0x46, vgRetParam: UInt8 = 0x47, vgSetParam: UInt8 = 0x48, vgNtfyParam: UInt8 = 0x49
    }
    /// VoiceGuidanceInquiredType variants that carry an on/off switch, in probing order.
    public static let onOffTypes: [UInt8] = [0x02, 0x01, 0x03, 0x00]

    public static func getVoiceGuidance(_ type: UInt8) -> [UInt8] { [Cmd.vgGetParam, type] }
    /// 02: 48 02 onOff lang · others: 48 tt onOff (ON = 0x00)
    public static func setVoiceGuidance(_ on: Bool, type: UInt8, language: UInt8?) -> [UInt8] {
        let v: UInt8 = on ? 0x00 : 0x01
        if type == 0x02 { return [Cmd.vgSetParam, type, v, language ?? 0x01] }
        return [Cmd.vgSetParam, type, v]
    }

    public static func parse(_ p: [UInt8]) -> [SonyUpdate] {
        guard p.count >= 3, p[0] == Cmd.vgRetParam || p[0] == Cmd.vgNtfyParam, onOffTypes.contains(p[1]) else { return [] }
        return [.voiceGuidanceV2(type: p[1], isOn: p[2] == 0x00, language: p.count >= 4 ? p[3] : nil)]
    }
}
