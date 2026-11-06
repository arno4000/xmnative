import Testing
import HeadphoneKit
@testable import SonyMDR

@Suite struct TableSet1Tests {
    @Test func noiseCancellingOnDualSingleDevice() {
        // XM4-style capability: ncSettingType DUAL_SINGLE_OFF (2), asmSettingType LEVEL_ADJUSTMENT (1)
        #expect(SonyV1.setNcAsm(mode: .noiseCancelling, ambientLevel: 12, voiceFocus: false, isFinal: true,
                                ncSettingType: 0x02, asmSettingType: 0x01)
                == [0x68, 0x02, 0x11, 0x02, 0x02, 0x01, 0x00, 0x00])
    }

    @Test func ambientWhileDraggingThenFinal() {
        #expect(SonyV1.setNcAsm(mode: .ambient, ambientLevel: 14, voiceFocus: true, isFinal: false,
                                ncSettingType: 0x02, asmSettingType: 0x01)
                == [0x68, 0x02, 0x10, 0x02, 0x00, 0x01, 0x01, 0x0E])
        #expect(SonyV1.setNcAsm(mode: .ambient, ambientLevel: 14, voiceFocus: true, isFinal: true,
                                ncSettingType: 0x02, asmSettingType: 0x01)[2] == 0x11)
    }

    @Test func turningOnFromOffUsesEffectOn() {
        // Like Sound Connect's on/off switch: NcAsmSendStatus.ON → effect 0x01
        #expect(SonyV1.setNcAsm(mode: .noiseCancelling, ambientLevel: 0, voiceFocus: false, isFinal: true, turningOn: true,
                                ncSettingType: 0x02, asmSettingType: 0x01)
                == [0x68, 0x02, 0x01, 0x02, 0x02, 0x01, 0x00, 0x00])
        #expect(SonyV1.setNcAsm(mode: .ambient, ambientLevel: 3, voiceFocus: false, isFinal: false, turningOn: true,
                                ncSettingType: 0x02, asmSettingType: 0x01)[2] == 0x10)
    }

    @Test func offAndWind() {
        #expect(SonyV1.setNcAsm(mode: .off, ambientLevel: 5, voiceFocus: false, isFinal: true, ncSettingType: 0x02, asmSettingType: 0x01)
                == [0x68, 0x02, 0x00, 0x02, 0x00, 0x01, 0x00, 0x00])
        #expect(SonyV1.setNcAsm(mode: .windReduction, ambientLevel: 5, voiceFocus: false, isFinal: true, ncSettingType: 0x02, asmSettingType: 0x01)[4] == 0x01)
    }

    @Test func parsesNcAsmNotification() {
        #expect(SonyV1.parse([0x69, 0x02, 0x11, 0x02, 0x00, 0x01, 0x01, 0x0E])
                == [.noise(SonyNoiseSnapshot(inquiredType: 2, mode: .ambient, ambientLevel: 14, voiceFocus: true))])
        #expect(SonyV1.parse([0x67, 0x02, 0x01, 0x02, 0x02, 0x01, 0x00, 0x00])
                == [.noise(SonyNoiseSnapshot(inquiredType: 2, mode: .noiseCancelling, ambientLevel: 0, voiceFocus: false))])
        #expect(SonyV1.parse([0x67, 0x02, 0x01, 0x02, 0x01, 0x01, 0x00, 0x00])
                == [.noise(SonyNoiseSnapshot(inquiredType: 2, mode: .windReduction, ambientLevel: 0, voiceFocus: false))])
    }

    @Test func parsesNcCapability() {
        #expect(SonyV1.parse([0x61, 0x02, 0x02, 0x02, 0x01, 0x02, 0x00, 20, 0x01, 20])
                == [.ncAsmCapabilityV1(inquiredType: 2, ncSettingType: 2, asmSettingType: 1, asmMaxLevel: 20, hasVoiceMode: true)])
    }

    @Test func parsesBattery() {
        #expect(SonyV1.parse([0x11, 0x00, 70, 0x00]) == [.battery(BatteryLevel(percent: 70, isCharging: false))])
        #expect(SonyV1.parse([0x13, 0x01, 50, 0x01, 60, 0x00])
                == [.leftRightBattery(left: BatteryLevel(percent: 50, isCharging: true), right: BatteryLevel(percent: 60, isCharging: false))])
    }

    @Test func parsesDeviceInfoAndFunctions() {
        #expect(SonyV1.parse([0x05, 0x01, 0x03] + Array("WH-".utf8)) == [.modelName("WH-")])
        #expect(SonyV1.parse([0x07, 0x00, 0x02, 0x62, 0xF5]) == [.supportedFunctions([0x62, 0xF5])])
    }

    @Test func equalizer() {
        #expect(SonyV1.selectEqPreset(0x10, type: 0x01) == [0x58, 0x01, 0x10, 0x00])
        #expect(SonyV1.setEqBands([10, 12, 8, 10, 10, 20]) == [0x58, 0x01, 0xFF, 0x06, 10, 12, 8, 10, 10, 20])
        #expect(SonyV1.parse([0x57, 0x01, 0xA0, 0x02, 0x0A, 0x0B]) == [.eqParam(presetID: 0xA0, bandSteps: [10, 11])])
        #expect(SonyV1.parse([0x51, 0x01, 0x06, 0x15, 0x02, 0x10, 0x00, 0xA0, 0x03, 0x41, 0x42, 0x43])
                == [.eqCapability(bandCount: 6, levelSteps: 21, presets: [
                    EqPreset(id: 0x10, name: "Bright", isCustomizable: false),
                    EqPreset(id: 0xA0, name: "ABC", isCustomizable: true),
                ])])
    }

    @Test func eqBandLabels() {
        let infos = [SonyEqBandInfo(kind: 0x10, value: 1), SonyEqBandInfo(kind: 0x01, value: 400),
                     SonyEqBandInfo(kind: 0x02, value: 25), SonyEqBandInfo(kind: 0x02, value: 160)]
        #expect(infos.map(\.label) == ["Clear Bass", "400", "2.5k", "16k"])
    }

    @Test func systemSettings() {
        #expect(SonyV1.setSpeakToChat(true) == [0xF8, 0x05, 0x01, 0x01])
        #expect(SonyV1.parse([0xF7, 0x05, 0x00, 0x01]) == [.speakToChat(true)])
        #expect(SonyV1.setAutoPowerOff(active: 0x11, selectTime: 0x00) == [0xF8, 0x04, 0x01, 0x11, 0x00])
        #expect(SonyV1.parse([0xF9, 0x04, 0x01, 0x10, 0x00]) == [.autoPowerOff(active: 0x10, selectTime: 0x00)])
        #expect(SonyV1.setSpeakToChatDetails(.high, voiceFocus: true, .long) == [0xFC, 0x05, 0x00, 0x01, 0x01, 0x02])
        #expect(SonyV1.setUpscaling(true) == [0xE8, 0x02, 0x00, 0x01])
        #expect(SonyV1.setConnectionPriority(.connectionQuality) == [0xE8, 0x01, 0x00, 0x01])
    }

    @Test func generalSettings() {
        let key = Array("TOUCH_PANEL_SETTING".utf8)
        #expect(SonyV1.parse([0xD1, 0xD1, 0x02, UInt8(key.count)] + key + [0x00, 0x01])
                == [.generalSettingCapability(id: 0xD1, title: "Touch sensor control", subtitle: nil, isBoolean: true)])
        #expect(SonyV1.setGeneralSetting(0xD2, false) == [0xD8, 0xD2, 0x01, 0x00])
        #expect(SonyV1.parse([0xD9, 0xD2, 0x01, 0x01]) == [.generalSetting(id: 0xD2, isOn: true)])
    }

    @Test func truncatedPayloadsDoNotCrash() {
        for cmd: UInt8 in [0x01, 0x05, 0x07, 0x11, 0x13, 0x19, 0x1B, 0x51, 0x57, 0x59, 0x5B, 0x61, 0x67, 0x69, 0xD1, 0xD7, 0xD9, 0xE1, 0xE7, 0xE9, 0xF1, 0xF7, 0xF9, 0xFB, 0xFD] {
            for n in 0 ..< 4 {
                _ = SonyV1.parse([cmd] + Array(repeating: 0x02, count: n))
                _ = SonyV2.parse([cmd] + Array(repeating: 0x02, count: n))
            }
        }
    }
}

@Suite struct TableSet2Tests {
    @Test func noiseControl() {
        #expect(SonyV2.setNcAsm(type: 0x17, mode: .noiseCancelling, ambientLevel: 10, voiceFocus: false, isFinal: true, trailer: [])
                == [0x68, 0x17, 0x01, 0x01, 0x00, 0x00, 0x0A])
        #expect(SonyV2.setNcAsm(type: 0x17, mode: .ambient, ambientLevel: 20, voiceFocus: true, isFinal: false, trailer: [])
                == [0x68, 0x17, 0x00, 0x01, 0x01, 0x01, 0x14])
        #expect(SonyV2.setNcAsm(type: 0x17, mode: .off, ambientLevel: 20, voiceFocus: false, isFinal: true, trailer: [])[3] == 0x00)
        #expect(SonyV2.parse([0x69, 0x17, 0x01, 0x01, 0x01, 0x00, 0x08])
                == [.noise(SonyNoiseSnapshot(inquiredType: 0x17, mode: .ambient, ambientLevel: 8, voiceFocus: false))])
    }

    @Test func adaptiveTrailerRoundTrips() {
        let snap = SonyV2.parse([0x69, 0x19, 0x01, 0x01, 0x00, 0x00, 0x0A, 0x01, 0x02])
        #expect(snap == [.noise(SonyNoiseSnapshot(inquiredType: 0x19, mode: .noiseCancelling, ambientLevel: 10, voiceFocus: false, trailer: [0x01, 0x02]))])
        #expect(SonyV2.setNcAsm(type: 0x19, mode: .noiseCancelling, ambientLevel: 10, voiceFocus: false, isFinal: true, trailer: [0x01, 0x02])
                == [0x68, 0x19, 0x01, 0x01, 0x00, 0x00, 0x0A, 0x01, 0x02])
    }

    @Test func invertedOnOff() {
        #expect(SonyV2.setSpeakToChat(true) == [0xF8, 0x0C, 0x00, 0x01])
        #expect(SonyV2.parse([0xF7, 0x0C, 0x00, 0x01]) == [.speakToChat(true)])
        #expect(SonyV2.parse([0xF7, 0x0C, 0x01, 0x01]) == [.speakToChat(false)])
    }

    @Test func batteryAndCodec() {
        #expect(SonyV2.getBattery(0) == [0x22, 0x00])
        #expect(SonyV2.parse([0x23, 0x00, 0x55, 0x01]) == [.battery(BatteryLevel(percent: 85, isCharging: true))])
        #expect(SonyV2.parse([0x13, 0x02, 0x10]) == [.codec(.ldac)])
    }
}

@Suite struct NewFeatureVectorTests {
    @Test func tableSet1Extras() {
        #expect(SonyV1.setWearPause(true) == [0xF8, 0x03, 0x00, 0x01])
        #expect(SonyV1.parse([0xF9, 0x03, 0x00, 0x00]) == [.wearPause(false)])
        #expect(SonyV1.setAssignable([0xFE, 0x31]) == [0xF8, 0x06, 0x02, 0xFE, 0x31])
        #expect(SonyV1.playback(.next) == [0xA4, 0x01, 0x00, 0x02])
        #expect(SonyV1.parse([0xA5, 0x01, 0x00, 0x02]) == [.playStatus(isPlaying: false)])
        #expect(SonyV1.parse([0xA9, 0x01, 0x00]) == [.metadataChanged(type: 0x00)])
        #expect(SonyV1Table2.setVoiceGuidance(true) == [0x48, 0x01, 0x01, 0x01])
        #expect(SonyV1.optimizer(start: true) == [0x84, 0x01, 0x00, 0x01])
        #expect(SonyV1.parse([0x85, 0x01, 0x00, 0x10]) == [.optimizerStatus(0x10)])
    }

    @Test func assignableCapabilityParsing() {
        // one key (custom button) with three presets; first preset has one action
        let keys = SonyV1.parseAssignableCapability([0xF1, 0x06, 0x01, 0x02, 0x01, 0x00, 0x03,
                                                     0x00, 0x01, 0x00, 0x01, 0x31, 0x01, 0x00, 0x32, 0x32, 0x00])
        #expect(keys == [SonyAssignableKey(key: 0x02, keyType: 0x01, defaultPreset: 0x00, presets: [0x00, 0x31, 0x32])])
    }

    @Test func tableSet2Extras() {
        #expect(SonyV2.setAutoPowerOff(active: 0x11, selectTime: 0x04) == [0x28, 0x04, 0x11, 0x04])
        #expect(SonyV2.parse([0x29, 0x04, 0x04, 0x04]) == [.autoPowerOff(active: 0x04, selectTime: 0x04)])
        #expect(SonyV1.autoPowerOffOption(0x04) == .minutes(15))
        #expect(SonyV2.setUpscaling(true) == [0xE8, 0x01, 0x01])
        #expect(SonyV2.parse([0xE7, 0x00, 0x01]) == [.connectionPriority(.connectionQuality)])
        #expect(SonyV2.setWearPause(true) == [0xF8, 0x01, 0x00])
        #expect(SonyV2.parse([0xF7, 0x01, 0x01]) == [.wearPause(false)])
        #expect(SonyV2.setSpeakToChatDetails(.low, .none) == [0xFC, 0x0C, 0x02, 0x03])
        #expect(SonyV2.parse([0xFB, 0x0C, 0x01, 0x00]) == [.speakToChatDetails(.high, voiceFocus: nil, .short)])
        #expect(SonyV2.setGeneralSetting(0xD1, true) == [0xD8, 0xD1, 0x00, 0x00])
        #expect(SonyV2.parse([0xD7, 0xD2, 0x00, 0x01]) == [.generalSetting(id: 0xD2, isOn: false)])
        let key = Array("MULTIPOINT_SETTING".utf8)
        #expect(SonyV2.parse([0xD1, 0xD1, 0x00, 0x01, UInt8(key.count)] + key + [0x00])
                == [.generalSettingCapability(id: 0xD1, title: "Connect to 2 devices", subtitle: nil, isBoolean: true)])
        #expect(SonyV2Table2.setVoiceGuidance(false, type: 0x02, language: 0x03) == [0x48, 0x02, 0x01, 0x03])
        #expect(SonyV2Table2.parse([0x47, 0x03, 0x00]) == [.voiceGuidanceV2(type: 0x03, isOn: true, language: nil)])
    }
}
