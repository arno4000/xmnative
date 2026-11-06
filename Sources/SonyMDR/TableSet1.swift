import Foundation
import HeadphoneKit

/// Command table set 1 (com.sony.songpal.tandemfamily.message.mdr.v1.table1 in the app).
/// Used by WH-1000XM4 and older models. Payload byte 0 is always the command.
public enum SonyV1 {
    // MARK: Commands
    enum Cmd {
        static let getProtocolInfo: UInt8 = 0x00, retProtocolInfo: UInt8 = 0x01
        static let getDeviceInfo: UInt8 = 0x04, retDeviceInfo: UInt8 = 0x05
        static let getSupportFunction: UInt8 = 0x06, retSupportFunction: UInt8 = 0x07
        static let getBattery: UInt8 = 0x10, retBattery: UInt8 = 0x11, ntfyBattery: UInt8 = 0x13
        static let getCodec: UInt8 = 0x18, retCodec: UInt8 = 0x19, ntfyCodec: UInt8 = 0x1B
        static let eqGetCapability: UInt8 = 0x50, eqRetCapability: UInt8 = 0x51
        static let eqGetParam: UInt8 = 0x56, eqRetParam: UInt8 = 0x57, eqSetParam: UInt8 = 0x58, eqNtfyParam: UInt8 = 0x59
        static let eqGetExtInfo: UInt8 = 0x5A, eqRetExtInfo: UInt8 = 0x5B
        static let ncGetCapability: UInt8 = 0x60, ncRetCapability: UInt8 = 0x61
        static let ncGetParam: UInt8 = 0x66, ncRetParam: UInt8 = 0x67, ncSetParam: UInt8 = 0x68, ncNtfyParam: UInt8 = 0x69
        static let gsGetCapability: UInt8 = 0xD0, gsRetCapability: UInt8 = 0xD1
        static let gsGetParam: UInt8 = 0xD6, gsRetParam: UInt8 = 0xD7, gsSetParam: UInt8 = 0xD8, gsNtfyParam: UInt8 = 0xD9
        static let audioGetCapability: UInt8 = 0xE0, audioRetCapability: UInt8 = 0xE1
        static let audioGetParam: UInt8 = 0xE6, audioRetParam: UInt8 = 0xE7, audioSetParam: UInt8 = 0xE8, audioNtfyParam: UInt8 = 0xE9
        static let sysGetCapability: UInt8 = 0xF0, sysRetCapability: UInt8 = 0xF1
        static let sysGetParam: UInt8 = 0xF6, sysRetParam: UInt8 = 0xF7, sysSetParam: UInt8 = 0xF8, sysNtfyParam: UInt8 = 0xF9
        static let optGetCapability: UInt8 = 0x80, optRetCapability: UInt8 = 0x81
        static let optGetStatus: UInt8 = 0x82, optRetStatus: UInt8 = 0x83, optSetStatus: UInt8 = 0x84, optNtfyStatus: UInt8 = 0x85
        static let playGetCapability: UInt8 = 0xA0, playRetCapability: UInt8 = 0xA1
        static let playGetStatus: UInt8 = 0xA2, playRetStatus: UInt8 = 0xA3, playSetStatus: UInt8 = 0xA4, playNtfyStatus: UInt8 = 0xA5
        static let playGetParam: UInt8 = 0xA6, playRetParam: UInt8 = 0xA7, playSetParam: UInt8 = 0xA8, playNtfyParam: UInt8 = 0xA9
        static let sysGetExtParam: UInt8 = 0xFA, sysRetExtParam: UInt8 = 0xFB, sysSetExtParam: UInt8 = 0xFC, sysNtfyExtParam: UInt8 = 0xFD
    }

    /// FunctionType codes from CONNECT_RET_SUPPORT_FUNCTION (v1.table1.param.FunctionType).
    public enum Function {
        public static let batteryLevel: UInt8 = 0x11
        public static let codecIndicator: UInt8 = 0x13
        public static let leftRightBattery: UInt8 = 0x15
        public static let cradleBattery: UInt8 = 0x18
        public static let presetEq: UInt8 = 0x51
        public static let ebb: UInt8 = 0x52
        public static let presetEqNonCustomizable: UInt8 = 0x53
        public static let noiseCancelling: UInt8 = 0x61
        public static let ncAndAsm: UInt8 = 0x62
        public static let ambientSound: UInt8 = 0x63
        public static let generalSetting1: UInt8 = 0xD1
        public static let generalSetting2: UInt8 = 0xD2
        public static let generalSetting3: UInt8 = 0xD3
        public static let connectionMode: UInt8 = 0xE1
        public static let upscaling: UInt8 = 0xE2
        public static let autoPowerOff: UInt8 = 0xF4
        public static let smartTalkingMode: UInt8 = 0xF5
        public static let controlByWearing: UInt8 = 0xF3
        public static let assignableSettings: UInt8 = 0xF6
        public static let playbackController: UInt8 = 0xA1
        public static let voiceGuidance: UInt8 = 0x39
        public static let ncOptimizer: UInt8 = 0x81
    }

    enum SystemType {
        static let controlByWearing: UInt8 = 0x03
        static let autoPowerOff: UInt8 = 0x04
        static let smartTalking: UInt8 = 0x05
        static let assignable: UInt8 = 0x06
    }
    enum AudioType { static let connectionMode: UInt8 = 0x01, upscaling: UInt8 = 0x02 }

    // MARK: Requests

    public static func getProtocolInfo() -> [UInt8] { [Cmd.getProtocolInfo, 0x00] }
    public static func getModelName() -> [UInt8] { [Cmd.getDeviceInfo, 0x01] }
    public static func getFirmwareVersion() -> [UInt8] { [Cmd.getDeviceInfo, 0x02] }
    public static func getSupportFunctions() -> [UInt8] { [Cmd.getSupportFunction, 0x00] }
    /// 0 = single battery, 1 = left/right, 2 = charging case.
    public static func getBattery(_ type: UInt8) -> [UInt8] { [Cmd.getBattery, type] }
    public static func getCodec() -> [UInt8] { [Cmd.getCodec, 0x00] }

    public static func getNcAsmCapability(_ type: UInt8) -> [UInt8] { [Cmd.ncGetCapability, type] }
    public static func getNcAsm(_ type: UInt8) -> [UInt8] { [Cmd.ncGetParam, type] }

    /// NCASM_SET_PARAM for inquired type 2 (NC + ASM), vm0.a0 layout:
    /// 68 02 effect ncSettingType ncValue asmSettingType asmId asmLevel
    /// effect (NcAsmEffect): 0x00 off, 0x01 on, 0x10 slider being dragged, 0x11 change completed.
    /// Sound Connect's table-set-1 screen (feature/ncasm/n1) sends 0x01 when its on/off switch turns
    /// noise control on, and 0x10/0x11 for slider changes. Neither makes the headphones speak.
    static func effect(mode: NoiseMode, isFinal: Bool, turningOn: Bool) -> UInt8 {
        if mode == .off { return 0x00 }
        if !isFinal { return 0x10 }
        return turningOn ? 0x01 : 0x11
    }

    public static func setNcAsm(mode: NoiseMode, ambientLevel: Int, voiceFocus: Bool, isFinal: Bool, turningOn: Bool = false,
                                ncSettingType: UInt8, asmSettingType: UInt8) -> [UInt8] {
        let effect = effect(mode: mode, isFinal: isFinal, turningOn: turningOn)
        let dualSingle = ncSettingType == 0x02
        let ncValue: UInt8
        switch mode {
        case .noiseCancelling: ncValue = dualSingle ? 0x02 : 0x01
        case .windReduction: ncValue = 0x01
        case .ambient, .off: ncValue = 0x00
        }
        let asmLevel: UInt8
        if mode == .ambient {
            asmLevel = asmSettingType == 0x01 ? UInt8(clamping: max(1, ambientLevel)) : 0x01
        } else {
            asmLevel = 0x00
        }
        return [Cmd.ncSetParam, 0x02, effect, ncSettingType, ncValue, asmSettingType,
                voiceFocus ? 0x01 : 0x00, asmLevel]
    }

    /// Inquired type 3 (ambient only): 68 03 effect asmSettingType asmId level
    public static func setAsmOnly(enabled: Bool, ambientLevel: Int, voiceFocus: Bool, isFinal: Bool, turningOn: Bool = false, asmSettingType: UInt8) -> [UInt8] {
        let effect = effect(mode: enabled ? .ambient : .off, isFinal: isFinal, turningOn: turningOn)
        let level: UInt8 = enabled ? (asmSettingType == 0x01 ? UInt8(clamping: max(1, ambientLevel)) : 0x01) : 0x00
        return [Cmd.ncSetParam, 0x03, effect, asmSettingType, voiceFocus ? 0x01 : 0x00, level]
    }

    /// Inquired type 1 (NC only): 68 01 ncSettingType value
    public static func setNcOnly(enabled: Bool) -> [UInt8] { [Cmd.ncSetParam, 0x01, 0x00, enabled ? 0x01 : 0x00] }

    /// 1 = preset EQ (customizable), 3 = preset EQ (non-customizable).
    public static func getEqCapability(_ type: UInt8) -> [UInt8] { [Cmd.eqGetCapability, type] }
    public static func getEq(_ type: UInt8) -> [UInt8] { [Cmd.eqGetParam, type] }
    public static func getEqBandInfo(_ type: UInt8) -> [UInt8] { [Cmd.eqGetExtInfo, type] }
    public static func selectEqPreset(_ id: Int, type: UInt8) -> [UInt8] { [Cmd.eqSetParam, type, UInt8(clamping: id), 0x00] }
    /// Band values are raw steps (0 ... levelSteps-1). Preset 0xFF = "apply to the current preset".
    public static func setEqBands(_ steps: [Int]) -> [UInt8] {
        [Cmd.eqSetParam, 0x01, 0xFF, UInt8(clamping: steps.count)] + steps.map { UInt8(clamping: $0) }
    }

    public static func getAutoPowerOffCapability() -> [UInt8] { [Cmd.sysGetCapability, SystemType.autoPowerOff] }
    public static func getAutoPowerOff() -> [UInt8] { [Cmd.sysGetParam, SystemType.autoPowerOff] }
    /// F8 04 01 activeElementId selectTimeElementId
    public static func setAutoPowerOff(active: UInt8, selectTime: UInt8) -> [UInt8] {
        [Cmd.sysSetParam, SystemType.autoPowerOff, 0x01, active, selectTime]
    }

    public static func getSpeakToChat() -> [UInt8] { [Cmd.sysGetParam, SystemType.smartTalking] }
    /// F8 05 01(MODE_ON_OFF) value
    public static func setSpeakToChat(_ on: Bool) -> [UInt8] { [Cmd.sysSetParam, SystemType.smartTalking, 0x01, on ? 0x01 : 0x00] }
    public static func getSpeakToChatDetails() -> [UInt8] { [Cmd.sysGetExtParam, SystemType.smartTalking] }
    /// FC 05 00 sensitivity voiceFocus modeOutTime
    public static func setSpeakToChatDetails(_ s: SpeakToChatSensitivity, voiceFocus: Bool, _ t: SpeakToChatTimeout) -> [UInt8] {
        [Cmd.sysSetExtParam, SystemType.smartTalking, 0x00, sensitivityByte(s), voiceFocus ? 0x01 : 0x00, timeoutByte(t)]
    }

    /// "Pause when taken off" (SYSTEM inquired type 3, from the app's V1ControlByWearingRepository).
    public static func getWearPause() -> [UInt8] { [Cmd.sysGetParam, SystemType.controlByWearing] }
    public static func setWearPause(_ on: Bool) -> [UInt8] { [Cmd.sysSetParam, SystemType.controlByWearing, 0x00, on ? 0x01 : 0x00] }

    /// Assignable buttons. The set carries one preset per key, in capability order; 0xFE = leave unchanged.
    public static func getAssignableCapability() -> [UInt8] { [Cmd.sysGetCapability, SystemType.assignable] }
    public static func getAssignable() -> [UInt8] { [Cmd.sysGetParam, SystemType.assignable] }
    public static func setAssignable(_ presets: [UInt8]) -> [UInt8] {
        [Cmd.sysSetParam, SystemType.assignable, UInt8(clamping: presets.count)] + presets
    }

    /// NC Optimizer (OptimizerInquiredType 1). Control: 01 start, 00 cancel.
    public static func getOptimizerCapability() -> [UInt8] { [Cmd.optGetCapability, 0x01] }
    public static func getOptimizerStatus() -> [UInt8] { [Cmd.optGetStatus, 0x01] }
    public static func optimizer(start: Bool) -> [UInt8] { [Cmd.optSetStatus, 0x01, 0x00, start ? 0x01 : 0x00] }

    /// Playback controller (PlayInquiredType 1).
    public static func getPlaybackCapability() -> [UInt8] { [Cmd.playGetCapability, 0x01] }
    public static func getPlayStatus() -> [UInt8] { [Cmd.playGetStatus, 0x01] }
    public static func getVolume() -> [UInt8] { [Cmd.playGetParam, 0x01, 0x20] }
    public static func setVolume(_ v: Int) -> [UInt8] { [Cmd.playSetParam, 0x01, 0x20, UInt8(clamping: v)] }
    /// 00 track, 01 album, 02 artist
    public static func getMetadata(_ type: UInt8) -> [UInt8] { [Cmd.playGetParam, 0x01, type] }
    public static func playback(_ c: PlaybackCommand) -> [UInt8] {
        let code: UInt8 = switch c { case .pause: 0x01; case .next: 0x02; case .previous: 0x03; case .play: 0x07 }
        return [Cmd.playSetStatus, 0x01, 0x00, code]
    }

    public static func getAudioCapability(_ type: UInt8) -> [UInt8] { [Cmd.audioGetCapability, type] }
    public static func getAudio(_ type: UInt8) -> [UInt8] { [Cmd.audioGetParam, type] }
    public static func setUpscaling(_ on: Bool) -> [UInt8] { [Cmd.audioSetParam, AudioType.upscaling, 0x00, on ? 0x01 : 0x00] }
    public static func setConnectionPriority(_ p: ConnectionPriority) -> [UInt8] {
        [Cmd.audioSetParam, AudioType.connectionMode, 0x00, p == .soundQuality ? 0x00 : 0x01]
    }

    /// D0 gsType language(1 = English)
    public static func getGeneralSettingCapability(_ id: UInt8) -> [UInt8] { [Cmd.gsGetCapability, id, 0x01] }
    public static func getGeneralSetting(_ id: UInt8) -> [UInt8] { [Cmd.gsGetParam, id] }
    /// D8 gsType 01(BOOLEAN) value
    public static func setGeneralSetting(_ id: UInt8, _ on: Bool) -> [UInt8] { [Cmd.gsSetParam, id, 0x01, on ? 0x01 : 0x00] }

    // MARK: Parsing

    public static func parse(_ p: [UInt8]) -> [SonyUpdate] {
        guard let cmd = p.first else { return [] }
        switch cmd {
        case Cmd.retProtocolInfo where p.count >= 4:
            return [.protocolVersion(Int(p[2]) << 8 | Int(p[3]))]

        case Cmd.retDeviceInfo where p.count >= 3:
            switch p[1] {
            case 0x01: return SonyDecode.string(p, lengthAt: 2).map { [.modelName($0.0)] } ?? []
            case 0x02: return SonyDecode.string(p, lengthAt: 2).map { [.firmwareVersion($0.0)] } ?? []
            default: return []
            }

        case Cmd.retSupportFunction where p.count >= 3:
            let n = min(Int(p[2]), p.count - 3)
            return [.supportedFunctions(Array(p[3 ..< 3 + n]))]

        case Cmd.retBattery, Cmd.ntfyBattery:
            return parseBattery(p)

        case Cmd.retCodec, Cmd.ntfyCodec:
            guard p.count >= 3 else { return [] }
            return [.codec(SonyDecode.codec(p[2]))]

        case Cmd.ncRetCapability where p.count >= 3:
            return parseNcCapability(p)

        case Cmd.ncRetParam, Cmd.ncNtfyParam:
            return parseNcParam(p)

        case Cmd.eqRetCapability where p.count >= 5 && (p[1] == 0x01 || p[1] == 0x03):
            return [.eqCapability(bandCount: Int(p[2]), levelSteps: Int(p[3]), presets: SonyDecode.eqPresets(p, countAt: 4))]

        case Cmd.eqRetParam, Cmd.eqNtfyParam:
            guard p.count >= 4, p[1] == 0x01 || p[1] == 0x03 else { return [] }
            let n = min(Int(p[3]), p.count - 4)
            return [.eqParam(presetID: Int(p[2]), bandSteps: p[4 ..< 4 + n].map(Int.init))]

        case Cmd.eqRetExtInfo where p.count >= 3:
            var infos: [SonyEqBandInfo] = []
            var i = 3
            for _ in 0 ..< Int(p[2]) where i + 2 < p.count {
                infos.append(SonyEqBandInfo(kind: p[i], value: Int(p[i + 1]) << 8 | Int(p[i + 2])))
                i += 3
            }
            return [.eqBandInfo(infos)]

        case Cmd.sysRetCapability where p.count >= 3:
            switch p[1] {
            case SystemType.autoPowerOff:
                let n = min(Int(p[2]), p.count - 3)
                return [.autoPowerOffOptions(Array(p[3 ..< 3 + n]))]
            case SystemType.assignable:
                return [.assignableCapability(parseAssignableCapability(p))]
            default: return []
            }

        case Cmd.sysRetParam, Cmd.sysNtfyParam:
            guard p.count >= 4 else { return [] }
            switch p[1] {
            case SystemType.autoPowerOff where p.count >= 5: return [.autoPowerOff(active: p[3], selectTime: p[4])]
            case SystemType.smartTalking: return [.speakToChat(p[3] == 0x01)]
            case SystemType.controlByWearing: return [.wearPause(p[3] == 0x01)]
            case SystemType.assignable:
                let n = min(Int(p[2]), p.count - 3)
                return [.assignable(Array(p[3 ..< 3 + n]))]
            default: return []
            }

        case Cmd.sysRetExtParam, Cmd.sysNtfyExtParam:
            guard p.count >= 6, p[1] == SystemType.smartTalking else { return [] }
            return [.speakToChatDetails(sensitivity(p[3]), voiceFocus: p[4] == 0x01, timeout(p[5]))]

        case Cmd.audioRetCapability where p.count >= 3 && p[1] == AudioType.upscaling:
            return [.upscalingType(p[2])]

        case Cmd.audioRetParam, Cmd.audioNtfyParam:
            guard p.count >= 4 else { return [] }
            switch p[1] {
            case AudioType.connectionMode: return [.connectionPriority(p[3] == 0x00 ? .soundQuality : .connectionQuality)]
            case AudioType.upscaling: return [.upscaling(p[3] == 0x01)]
            default: return []
            }

        case Cmd.gsRetCapability where p.count >= 5:
            return parseGsCapability(p)

        case Cmd.gsRetParam, Cmd.gsNtfyParam:
            guard p.count >= 4, p[2] == 0x01 else { return [] }
            return [.generalSetting(id: p[1], isOn: p[3] == 0x01)]

        case Cmd.optRetCapability where p.count >= 2 && p[1] == 0x01:
            return [.optimizerAvailable]
        case Cmd.optRetStatus, Cmd.optNtfyStatus:
            guard p.count >= 4, p[1] == 0x01 else { return [] }
            return [.optimizerStatus(p[3])]
        case Cmd.playRetCapability where p.count >= 3 && p[1] == 0x01:
            return [.playbackCapability(maxVolume: Int(p[2]))]
        case Cmd.playRetStatus, Cmd.playNtfyStatus:
            guard p.count >= 4, p[1] == 0x01 else { return [] }
            guard p[2] == 0x00 else { return [.playStatus(isPlaying: nil)] }
            return [.playStatus(isPlaying: p[3] == 0x01)]
        case Cmd.playRetParam, Cmd.playNtfyParam:
            guard p.count >= 3, p[1] == 0x01 else { return [] }
            if p[2] == 0x20 { return p.count >= 4 ? [.volume(Int(p[3]))] : [] }
            if cmd == Cmd.playNtfyParam { return [.metadataChanged(type: p[2])] }
            guard p.count >= 5 else { return [] }
            let text = p[3] == 0x02 ? SonyDecode.string(p, lengthAt: 4)?.0 : nil
            return [.metadata(type: p[2], text: text)]

        default:
            return [.unknown(command: cmd)]
        }
    }

    /// F1 06 nKeys { key keyType defaultPreset nPresets { preset nActions { action function } } }
    static func parseAssignableCapability(_ p: [UInt8]) -> [SonyAssignableKey] {
        guard p.count >= 3 else { return [] }
        var keys: [SonyAssignableKey] = []
        var i = 3
        for _ in 0 ..< Int(p[2]) {
            guard i + 3 < p.count else { break }
            var k = SonyAssignableKey(key: p[i], keyType: p[i + 1], defaultPreset: p[i + 2], presets: [])
            let nPresets = Int(p[i + 3])
            i += 4
            for _ in 0 ..< nPresets {
                guard i + 1 < p.count else { break }
                k.presets.append(p[i])
                i += 2 + Int(p[i + 1]) * 2
            }
            keys.append(k)
        }
        return keys
    }

    static func parseBattery(_ p: [UInt8]) -> [SonyUpdate] {
        guard p.count >= 4 else { return [] }
        switch p[1] {
        case 0x00: return [.battery(SonyDecode.level(p[2], p[3]))]
        case 0x01 where p.count >= 6:
            return [.leftRightBattery(left: SonyDecode.level(p[2], p[3]), right: SonyDecode.level(p[4], p[5]))]
        case 0x02: return [.caseBattery(SonyDecode.level(p[2], p[3]))]
        default: return []
        }
    }

    static func parseNcCapability(_ p: [UInt8]) -> [SonyUpdate] {
        // tm0.d2: type 2 → [61 02 ncSettingType ncSteps asmSettingType count (asmId steps)*]
        //         type 3 → [61 03 asmSettingType count (asmId steps)*]
        func asm(_ start: Int) -> (max: Int, voice: Bool) {
            guard start < p.count else { return (20, false) }
            var maxLevel = 0, voice = false
            var i = start + 1
            for _ in 0 ..< Int(p[start]) where i + 1 < p.count {
                if p[i] == 0x01 { voice = true }
                maxLevel = max(maxLevel, Int(p[i + 1]))
                i += 2
            }
            return (maxLevel == 0 ? 20 : maxLevel, voice)
        }
        switch p[1] {
        case 0x02 where p.count >= 6:
            let a = asm(5)
            return [.ncAsmCapabilityV1(inquiredType: 0x02, ncSettingType: p[2], asmSettingType: p[4], asmMaxLevel: a.max, hasVoiceMode: a.voice)]
        case 0x03 where p.count >= 4:
            let a = asm(3)
            return [.ncAsmCapabilityV1(inquiredType: 0x03, ncSettingType: 0, asmSettingType: p[2], asmMaxLevel: a.max, hasVoiceMode: a.voice)]
        case 0x01:
            return [.ncAsmCapabilityV1(inquiredType: 0x01, ncSettingType: p[2], asmSettingType: 0, asmMaxLevel: 0, hasVoiceMode: false)]
        default: return []
        }
    }

    static func parseNcParam(_ p: [UInt8]) -> [SonyUpdate] {
        guard p.count >= 4 else { return [] }
        switch p[1] {
        case 0x02 where p.count >= 8:
            // effect ncSettingType ncValue asmSettingType asmId asmLevel
            let effect = p[2], ncSettingType = p[3], ncValue = p[4], asmLevel = Int(p[7])
            let mode: NoiseMode
            if effect == 0x00 { mode = .off }
            else if ncValue == 0x00 { mode = asmLevel > 0 ? .ambient : .off }
            else if ncSettingType == 0x02 && ncValue == 0x01 { mode = .windReduction }
            else { mode = .noiseCancelling }
            return [.noise(SonyNoiseSnapshot(inquiredType: 0x02, mode: mode, ambientLevel: asmLevel, voiceFocus: p[6] == 0x01))]
        case 0x03 where p.count >= 6:
            let on = p[2] != 0x00 && p[5] > 0
            return [.noise(SonyNoiseSnapshot(inquiredType: 0x03, mode: on ? .ambient : .off, ambientLevel: Int(p[5]), voiceFocus: p[4] == 0x01))]
        case 0x01:
            return [.noise(SonyNoiseSnapshot(inquiredType: 0x01, mode: p[3] == 0x01 ? .noiseCancelling : .off, ambientLevel: 0, voiceFocus: false))]
        default: return []
        }
    }

    static func parseGsCapability(_ p: [UInt8]) -> [SonyUpdate] {
        // D1 id | format len title len subtitle | settingType ...
        guard let (title, i1) = SonyDecode.string(p, lengthAt: 3),
              let (subtitle, i2) = SonyDecode.string(p, lengthAt: i1), i2 < p.count else { return [] }
        let isEnum = p[2] == 0x02
        return [.generalSettingCapability(id: p[1],
                                          title: isEnum ? SonyGeneralSettingNames.title(title) : title,
                                          subtitle: subtitle.isEmpty ? nil : (isEnum ? nil : subtitle),
                                          isBoolean: p[i2] == 0x01)]
    }

    static func sensitivity(_ b: UInt8) -> SpeakToChatSensitivity { b == 1 ? .high : b == 2 ? .low : .auto }
    static func sensitivityByte(_ s: SpeakToChatSensitivity) -> UInt8 { s == .high ? 1 : s == .low ? 2 : 0 }
    static func timeout(_ b: UInt8) -> SpeakToChatTimeout { [.short, .standard, .long, .none][Int(min(b, 3))] }
    static func timeoutByte(_ t: SpeakToChatTimeout) -> UInt8 {
        switch t { case .short: 0; case .standard: 1; case .long: 2; case .none: 3 }
    }

    /// AutoPowerOffElementId (v1.table1.param)
    public static func autoPowerOffOption(_ b: UInt8) -> AutoPowerOffOption {
        switch b {
        case 0x00: return .minutes(5)
        case 0x01: return .minutes(30)
        case 0x02: return .minutes(60)
        case 0x03: return .minutes(180)
        case 0x04: return .minutes(15)
        case 0x10: return .whenRemoved
        case 0x11: return .disabled
        default: return .other(Int(b))
        }
    }

    public static func autoPowerOffByte(_ o: AutoPowerOffOption) -> UInt8? {
        switch o {
        case .minutes(5): return 0x00
        case .minutes(30): return 0x01
        case .minutes(60): return 0x02
        case .minutes(180): return 0x03
        case .minutes(15): return 0x04
        case .whenRemoved: return 0x10
        case .disabled: return 0x11
        case .other(let raw): return UInt8(clamping: raw)
        default: return nil
        }
    }

    static func assignablePresetTitle(_ b: UInt8) -> String {
        switch b {
        case 0x00: "Ambient sound control"
        case 0x10: "Volume"
        case 0x20: "Playback"
        case 0x30: "Voice assistant (phone)"
        case 0x31: "Google Assistant"
        case 0x32: "Amazon Alexa"
        case 0x33: "Tencent Xiaowei"
        case 0xFF: "No function"
        default: "Function \(b)"
        }
    }

    static func assignableKeyTitle(_ k: SonyAssignableKey) -> String {
        switch k.key {
        case 0x00: k.keyType == 0x00 ? "Left touch sensor" : "Left button"
        case 0x01: k.keyType == 0x00 ? "Right touch sensor" : "Right button"
        case 0x02: k.keyType == 0x01 ? "Custom button" : "Custom touch area"
        case 0x03: "C button"
        default: "Button \(k.key)"
        }
    }

    /// UpscalingType (v1.table1.param)
    public static func upscalingName(_ b: UInt8) -> String {
        switch b { case 0x00: "DSEE HX"; case 0x01: "DSEE"; case 0x02: "DSEE Extreme"; default: "DSEE" }
    }
}

/// English titles for GsTitleTitle enum names (devices with GsStringFormat.ENUM_NAME send the key).
enum SonyGeneralSettingNames {
    static func title(_ key: String) -> String {
        switch key {
        case "TOUCH_PANEL_SETTING": return "Touch sensor control"
        case "VOICE_GUIDANCE_SETTING": return "Voice guidance"
        case "MULTIPOINT_SETTING": return "Connect to 2 devices"
        case "SIDETONE_SETTING": return "Hear own voice during calls"
        case "TAP_SENSITIVITY_SETTING": return "Tap sensitivity"
        case "FACETAP_SETTING", "SELECTABLE_FACETAP_SETTING": return "Quick Access (face tap)"
        case "TWS_ONE_SIDE_USE_NCASM_SETTING": return "NC with one earbud"
        case let k where k.hasPrefix("ASSIGNABLE_KEY_SETTING"): return "Custom button"
        default:
            return key.replacingOccurrences(of: "_SETTING", with: "").replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}
