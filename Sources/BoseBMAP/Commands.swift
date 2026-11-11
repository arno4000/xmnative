import Foundation
import HeadphoneKit

// BMAP commands used for the QC Ultra family, from the Bose app 13.4.2 (com.bose.bmap.messages.packets.*,
// com.bose.bmap.messages.responses.*). See docs/BOSE-PROTOCOL.md for the byte layouts.

public enum BMAP {
    // MARK: Function IDs (BmapFunction)

    public enum ProductInfo {
        public static let bmapVersion: UInt8 = 1
        public static let allFunctionBlocks: UInt8 = 2
        public static let productIDVariant: UInt8 = 3
        public static let firmwareVersion: UInt8 = 5
    }

    public enum Settings {
        public static let productName: UInt8 = 2
        public static let voicePrompts: UInt8 = 3
        public static let standbyTimer: UInt8 = 4
        public static let cnc: UInt8 = 5
        public static let rangeControl: UInt8 = 7
        public static let buttons: UInt8 = 9
        public static let multipoint: UInt8 = 10
        public static let sidetone: UInt8 = 11
        public static let onHeadDetection: UInt8 = 16
    }

    public enum Status {
        public static let battery: UInt8 = 2
        public static let chargerDetect: UInt8 = 5
    }

    public enum AudioManagement {
        public static let control: UInt8 = 3
        public static let status: UInt8 = 4
        public static let volume: UInt8 = 5
        public static let nowPlaying: UInt8 = 6
        public static let spatialAudioMode: UInt8 = 15
    }

    public enum Notification {
        public static let byFunctionBlock: UInt8 = 2
    }

    public enum AudioModes {
        public static let capabilities: UInt8 = 2
        public static let currentMode: UInt8 = 3
        public static let modeConfig: UInt8 = 6
        public static let favorites: UInt8 = 8
        public static let reset: UInt8 = 9
        public static let settingsConfig: UInt8 = 10
        public static let namesSupported: UInt8 = 11
    }

    public static let notificationBlock: UInt8 = 9

    // MARK: Requests

    public static func get(_ block: UInt8, _ function: UInt8, _ payload: [UInt8] = []) -> BMAPPacket {
        BMAPPacket(block, function, .get, payload)
    }

    public static func setGet(_ block: UInt8, _ function: UInt8, _ payload: [UInt8]) -> BMAPPacket {
        BMAPPacket(block, function, .setGet, payload)
    }

    public static func start(_ block: UInt8, _ function: UInt8, _ payload: [UInt8] = []) -> BMAPPacket {
        BMAPPacket(block, function, .start, payload)
    }

    /// Notification.ByFblock SetGet: `[mask=1 (enable)] + big-endian bitset of function blocks`
    /// (FBlockNotificationKt.createNotificationByFBlockPacketPayload).
    public static func enableNotifications(blocks: [UInt8]) -> BMAPPacket {
        setGet(notificationBlock, Notification.byFunctionBlock, [0x01] + bitset(blocks.map(Int.init)))
    }

    /// AudioModes.CurrentMode Start: `[mode][play voice prompt]` (AudioModesCurrentModeStartPacket).
    public static func selectMode(_ index: Int, announce: Bool = false) -> BMAPPacket {
        start(BMAPBlock.audioModes, AudioModes.currentMode, [UInt8(clamping: index), announce ? 1 : 0])
    }

    /// AudioModes.ModeConfig SetGet (FBlockAudioModesKt.createAudioModesConfigSetGetPayload).
    public static func setModeConfig(_ m: BoseModeConfig) -> BMAPPacket {
        var p: [UInt8] = [UInt8(clamping: m.index), m.prompt.0, m.prompt.1]
        p += modeName(m.name)
        p += [UInt8(clamping: m.cncLevel), m.autoCNC ? 1 : 0]
        if let s = m.spatial {
            p.append(s)
            if m.windBlock == nil { p.append(0) }
        }
        if let w = m.windBlock {
            if m.spatial == nil { p.append(0) }
            p.append(w ? 1 : 0)
        }
        if let a = m.ancToggle { p.append(a ? 1 : 0) }
        return setGet(BMAPBlock.audioModes, AudioModes.modeConfig, p)
    }

    /// AudioModes.Reset Start: `[mode]`, answered by a Result (AudioModesResetStartPacket). Clears a user mode.
    public static func resetMode(_ index: Int) -> BMAPPacket {
        start(BMAPBlock.audioModes, AudioModes.reset, [UInt8(clamping: index)])
    }

    /// AudioModes.Favorites SetGet: `[number of modes] + bitset over ceil(n/8) bytes`
    /// (AudioModesFavoritesSetGetPacket.getPayload). Mode m is bit m%8 of byte (len - 1 - m/8).
    public static func setFavorites(_ modes: [Int], numberOfModes: Int) -> BMAPPacket {
        let n = max(0, min(numberOfModes, 255))
        var p = [UInt8](repeating: 0, count: (n + 7) / 8 + 1)
        p[0] = UInt8(n)
        for m in modes where m >= 0 && m < n { p[p.count - 1 - m / 8] |= 1 << (m % 8) }
        return setGet(BMAPBlock.audioModes, AudioModes.favorites, p)
    }

    /// AudioModes.SettingsConfig SetGet: `[cnc][auto cnc][spatial][wind block][anc]`
    /// (AudioModesSettingsConfigSetGetPacket).
    public static func setSettingsConfig(_ c: BoseSettingsConfig) -> BMAPPacket {
        setGet(BMAPBlock.audioModes, AudioModes.settingsConfig,
               [UInt8(clamping: c.cncLevel), c.autoCNC ? 1 : 0, c.spatial, c.windBlock ? 1 : 0, c.ancToggle ? 1 : 0])
    }

    /// Settings.RangeControl SetGet: `[value][band]`, one band per packet.
    public static func setRange(band: UInt8, value: Int) -> BMAPPacket {
        setGet(BMAPBlock.settings, Settings.rangeControl, [UInt8(bitPattern: Int8(clamping: value)), band])
    }

    /// Settings.StandbyTimer SetGet: minutes, one byte or little-endian u16 above 255.
    public static func setStandbyTimer(minutes: Int) -> BMAPPacket {
        let m = max(0, min(minutes, 0xFFFF))
        return setGet(BMAPBlock.settings, Settings.standbyTimer, m <= 255 ? [UInt8(m)] : [UInt8(m & 0xFF), UInt8(m >> 8)])
    }

    /// Settings.VoicePrompts SetGet: `language (bits 0-4) | enabled << 5`.
    public static func setVoicePrompts(enabled: Bool, language: UInt8) -> BMAPPacket {
        setGet(BMAPBlock.settings, Settings.voicePrompts, [(language & 0x1F) | (enabled ? 0x20 : 0)])
    }

    public static func setMultipoint(_ on: Bool) -> BMAPPacket {
        setGet(BMAPBlock.settings, Settings.multipoint, [on ? 1 : 0])
    }

    /// Settings.OnHeadDetection SetGet: `[enabled][autoPlay | autoAnswer << 1 | autoTransparency << 2]`.
    public static func setOnHead(_ s: BoseOnHead) -> BMAPPacket {
        setGet(BMAPBlock.settings, Settings.onHeadDetection,
               [s.enabled ? 1 : 0, (s.autoPlay ? 1 : 0) | (s.autoAnswer ? 2 : 0) | (s.autoTransparency ? 4 : 0)])
    }

    /// Settings.Sidetone SetGet: `[persisted][mode]`.
    public static func setSidetone(_ mode: UInt8) -> BMAPPacket {
        setGet(BMAPBlock.settings, Settings.sidetone, [1, mode])
    }

    /// Settings.Buttons SetGet: `[button][event][mode]`.
    public static func setButton(button: UInt8, event: UInt8, mode: UInt8) -> BMAPPacket {
        setGet(BMAPBlock.settings, Settings.buttons, [button, event, mode])
    }

    public static func setVolume(_ v: Int) -> BMAPPacket {
        setGet(BMAPBlock.audioManagement, AudioManagement.volume, [UInt8(clamping: v)])
    }

    /// AudioManagement.Control Start (AudioControlValue): 1 play, 2 pause, 3 next, 4 previous.
    public static func control(_ value: UInt8) -> BMAPPacket {
        start(BMAPBlock.audioManagement, AudioManagement.control, [value])
    }

    public static func setSpatialAudio(_ mode: UInt8) -> BMAPPacket {
        setGet(BMAPBlock.audioManagement, AudioManagement.spatialAudioMode, [mode])
    }

    // MARK: Helpers

    /// Bit i of the set is bit (i % 8) of byte (count - 1 - i / 8)  (BitSetUtil.toByteArray).
    static func bitset(_ bits: [Int]) -> [UInt8] {
        guard let top = bits.max() else { return [0] }
        var out = [UInt8](repeating: 0, count: top / 8 + 1)
        for b in bits { out[out.count - 1 - b / 8] |= 1 << (b % 8) }
        return out
    }

    static func bits(_ bytes: ArraySlice<UInt8>) -> [Int] {
        let a = Array(bytes)
        var out: [Int] = []
        for i in 0 ..< a.count * 8 where a[a.count - 1 - i / 8] & (1 << (i % 8)) != 0 { out.append(i) }
        return out
    }

    /// Mode name field: UTF-8, at most 31 bytes (whole characters only), NUL-padded to 32.
    static func modeName(_ name: String) -> [UInt8] {
        var bytes: [UInt8] = []
        for ch in name {
            let utf8 = Array(String(ch).utf8)
            guard bytes.count + utf8.count <= 31 else { break }
            bytes += utf8
        }
        return bytes + [UInt8](repeating: 0, count: 32 - bytes.count)
    }

    /// 0 → false, 1 → true, anything else → unknown (the app's *EnabledTypes.getByValue).
    static func flag(_ b: UInt8) -> Bool? { b == 1 ? true : b == 0 ? false : nil }

    static func string(_ bytes: ArraySlice<UInt8>) -> String {
        let cut = bytes.firstIndex(of: 0).map { bytes[bytes.startIndex ..< $0] } ?? bytes
        return String(decoding: cut, as: UTF8.self)
    }

    // MARK: Mode prompts (AudioModesPrompt)

    static let promptNames: [UInt8: String] = [
        1: "Quiet", 2: "Aware", 3: "Transparent", 4: "Transparency", 5: "Masking", 6: "Comfort", 7: "Commute",
        8: "Outdoor", 9: "Workout", 10: "Home", 11: "Work", 12: "Music", 13: "Focus", 14: "Relax", 15: "Flight",
        16: "Airport", 17: "Driving", 18: "Training", 19: "Gym", 20: "Run", 21: "Walk", 22: "Hike", 23: "Talk",
        24: "Call", 25: "Whisper", 26: "Hearing", 27: "Learn", 28: "Podcast", 29: "Audiobook", 30: "Calm",
        31: "Sleep", 32: "Meditate", 33: "Yoga", 34: "Immersion", 35: "Stereo", 36: "Cinema",
    ]
}

// MARK: - Parsed state

public struct BoseModeConfig: Equatable, Sendable {
    public var index: Int
    public var prompt: (UInt8, UInt8)
    public var userConfigurable: Bool
    public var userConfigured: Bool
    public var favorite: Bool
    public var name: String
    public var cncMutable: Bool
    public var autoCNCMutable: Bool
    public var spatialMutable: Bool
    public var windMutable: Bool
    public var ancMutable: Bool
    /// Device value: 0 = most cancelling (BmapCncLevelConfig.mapBetweenCncLevelAndWorldVolume).
    public var cncLevel: Int
    public var autoCNC: Bool
    /// SpatialAudioModeTypes: 0 off, 1 fixed to room, 2 fixed to head. nil = not reported.
    public var spatial: UInt8?
    public var windBlock: Bool?
    public var ancToggle: Bool?

    public static func == (a: Self, b: Self) -> Bool {
        a.index == b.index && a.prompt == b.prompt && a.userConfigurable == b.userConfigurable
            && a.userConfigured == b.userConfigured && a.favorite == b.favorite && a.name == b.name
            && a.cncMutable == b.cncMutable && a.autoCNCMutable == b.autoCNCMutable && a.spatialMutable == b.spatialMutable
            && a.windMutable == b.windMutable && a.ancMutable == b.ancMutable && a.cncLevel == b.cncLevel
            && a.autoCNC == b.autoCNC && a.spatial == b.spatial && a.windBlock == b.windBlock && a.ancToggle == b.ancToggle
    }

    /// AudioModesModeConfigResponse.createFromPacket.
    init?(status p: [UInt8]) {
        guard p.count >= 44 else { return nil }
        index = Int(p[0])
        prompt = (p[1], p[2])
        userConfigurable = p[3] == 1
        userConfigured = p[4] == 1
        favorite = p[5] == 1
        name = BMAP.string(p[6 ..< 38])
        let flags = p[41]
        cncMutable = flags & 0x01 != 0
        autoCNCMutable = flags & 0x02 != 0
        spatialMutable = flags & 0x04 != 0
        windMutable = flags & 0x08 != 0
        ancMutable = flags & 0x10 != 0
        cncLevel = Int(p[42])
        autoCNC = p[43] == 1
        // getByValue: anything outside the enum is Unknown.
        spatial = p.count >= 45 && p[44] <= 2 ? p[44] : nil
        windBlock = p.count >= 47 ? BMAP.flag(p[46]) : nil
        ancToggle = p.count >= 48 ? BMAP.flag(p[47]) : nil
    }

    /// A user slot with prompt None is free (C24296zT4.j2 picks the first such mode for "add mode").
    public var isFreeSlot: Bool { userConfigurable && prompt.0 == 0 && prompt.1 == 0 }

    /// Name to show: the prompt's name for Bose's own modes, the stored name for the user's.
    public var displayName: String {
        let promptName = prompt.0 == 0 ? BMAP.promptNames[prompt.1] : nil
        if userConfigurable, !name.isEmpty { return name }
        return promptName ?? (name.isEmpty ? "Mode \(index + 1)" : name)
    }

    public var kind: ListeningMode.Kind {
        if userConfigurable { return .custom }
        switch prompt.1 {
        case 1: return .quiet
        case 2, 3, 4: return .aware
        case 34, 36: return .immersive
        default: return .custom
        }
    }

    /// Free user slots are placeholders, not modes.
    public var isUsable: Bool { !isFreeSlot }
}

public struct BoseSettingsConfig: Equatable, Sendable {
    public var cncLevel: Int
    public var autoCNC: Bool
    public var spatial: UInt8
    public var windBlock: Bool
    public var ancToggle: Bool
}

public struct BoseModeCapabilities: Equatable, Sendable {
    public var boseModes: Int
    public var userModes: Int
    public var cncSupported: Bool
    public var autoCNCSupported: Bool
    public var spatialSupported: Bool
    public var windSupported: Bool
    public var favoritesSupported: Bool
    public var ancSupported: Bool
    public var minimumFavorites: Int
    public var numberOfModes: Int { boseModes + userModes }
}

public struct BoseOnHead: Equatable, Sendable {
    public var enabled: Bool
    public var autoPlaySupported: Bool
    public var autoAnswerSupported: Bool
    public var autoTransparencySupported: Bool
    public var autoPlay: Bool
    public var autoAnswer: Bool
    public var autoTransparency: Bool
}

public struct BoseRange: Equatable, Sendable {
    public var band: UInt8
    public var min: Int
    public var max: Int
    public var value: Int
}

public struct BoseButton: Equatable, Sendable {
    public var button: UInt8
    public var event: UInt8
    public var mode: UInt8
    public var supported: [UInt8]
}

public enum BoseUpdate: Equatable, Sendable {
    case bmapVersion(String)
    case functionBlocks([Int])
    case productID(Int, variant: Int)
    case firmwareVersion(String)
    case productName(String)
    case battery(percent: Int)
    case charging(Bool)
    case voicePrompts(enabled: Bool, language: UInt8)
    case standbyTimer(minutes: Int, configurable: Bool)
    case cnc(steps: Int, level: Int)
    case ranges([BoseRange])
    case multipoint(enabled: Bool, supported: Bool)
    case onHead(BoseOnHead)
    case sidetone(mode: UInt8, supported: [UInt8])
    case button(BoseButton)
    case volume(max: Int, current: Int)
    case playState(UInt8)
    case nowPlaying(attribute: UInt8, text: String)
    case spatialAudio(UInt8)
    case modeCapabilities(BoseModeCapabilities)
    case favorites([Int])
    case namesSupported([UInt8])
    case settingsConfig(BoseSettingsConfig)
    case modeReset(Int)
    case modeConfig(BoseModeConfig)
    case currentMode(Int)
    case error(block: UInt8, function: UInt8, code: UInt8)
}

extension BMAP {
    /// Turns one packet from the device into state updates. Unknown packets give [].
    public static func parse(_ packet: BMAPPacket) -> [BoseUpdate] {
        let p = packet.payload
        if packet.op == .error {
            // [code] or [0xFF][fblock-specific code] (BmapPacket.getErrorCode)
            let code: UInt8 = p.count > 1 && p[0] == 0xFF ? p[1] : (p.first ?? 0)
            return [.error(block: packet.block, function: packet.function, code: code)]
        }
        guard packet.op == .status || packet.op == .result else { return [] }
        let isStatus = packet.op == .status

        switch (packet.block, packet.function) {
        case (BMAPBlock.productInfo, ProductInfo.bmapVersion) where isStatus:
            return [.bmapVersion(string(p[...]))]
        case (BMAPBlock.productInfo, ProductInfo.allFunctionBlocks) where isStatus:
            return [.functionBlocks(bits(p[...]))]
        case (BMAPBlock.productInfo, ProductInfo.productIDVariant) where isStatus && p.count >= 3:
            return [.productID(Int(p[0]) << 8 | Int(p[1]), variant: Int(p[2]))]
        case (BMAPBlock.productInfo, ProductInfo.firmwareVersion) where isStatus:
            return [.firmwareVersion(string(p[...]))]

        case (BMAPBlock.settings, Settings.productName) where isStatus && !p.isEmpty:
            return [.productName(string(p.dropFirst()))]
        case (BMAPBlock.settings, Settings.voicePrompts) where isStatus && !p.isEmpty:
            return [.voicePrompts(enabled: p[0] & 0x20 != 0, language: p[0] & 0x1F)]
        case (BMAPBlock.settings, Settings.standbyTimer) where isStatus && !p.isEmpty:
            let minutes = p.count >= 3 ? Int(p[2]) << 8 | Int(p[0]) : Int(p[0])
            return [.standbyTimer(minutes: minutes, configurable: !(p.count > 1 && p[1] & 1 == 1))]
        case (BMAPBlock.settings, Settings.cnc) where isStatus && p.count >= 2:
            return [.cnc(steps: Int(p[0]), level: Int(p[1]))]
        case (BMAPBlock.settings, Settings.rangeControl) where isStatus:
            var out: [BoseRange] = []
            var i = 0
            while i + 3 < p.count {
                out.append(BoseRange(band: p[i + 3], min: Int(Int8(bitPattern: p[i])), max: Int(Int8(bitPattern: p[i + 1])),
                                     value: Int(Int8(bitPattern: p[i + 2]))))
                i += 4
            }
            return out.isEmpty ? [] : [.ranges(out)]
        case (BMAPBlock.settings, Settings.multipoint) where isStatus && !p.isEmpty:
            return [.multipoint(enabled: p[0] & 1 != 0, supported: p[0] & 2 != 0)]
        case (BMAPBlock.settings, Settings.onHeadDetection) where isStatus && !p.isEmpty:
            let on = p.count > 1 ? p[1] : 0
            return [.onHead(BoseOnHead(enabled: p[0] & 1 != 0, autoPlaySupported: p[0] & 2 != 0,
                                       autoAnswerSupported: p[0] & 4 != 0, autoTransparencySupported: p[0] & 8 != 0,
                                       autoPlay: on & 1 != 0, autoAnswer: on & 2 != 0, autoTransparency: on & 4 != 0))]
        case (BMAPBlock.settings, Settings.sidetone) where isStatus && p.count >= 2:
            return [.sidetone(mode: p[1], supported: p.count > 2 ? bits(p[2...]).map { UInt8($0) } : [])]
        case (BMAPBlock.settings, Settings.buttons) where isStatus && p.count >= 7:
            return [.button(BoseButton(button: p[0], event: p[1], mode: p[2], supported: bits(p[3 ..< 7]).map { UInt8($0) }))]

        case (BMAPBlock.status, Status.battery) where isStatus && !p.isEmpty:
            return [.battery(percent: Int(p[0]))]
        case (BMAPBlock.status, Status.chargerDetect) where isStatus && !p.isEmpty:
            return [.charging(p[0] == 1)]

        case (BMAPBlock.audioManagement, AudioManagement.volume) where isStatus && p.count >= 2:
            return [.volume(max: Int(p[0]), current: Int(p[1]))]
        case (BMAPBlock.audioManagement, AudioManagement.status) where isStatus && !p.isEmpty:
            return [.playState(p[0])]
        case (BMAPBlock.audioManagement, AudioManagement.nowPlaying) where isStatus && !p.isEmpty:
            return [.nowPlaying(attribute: p[0], text: string(p.dropFirst()))]
        case (BMAPBlock.audioManagement, AudioManagement.spatialAudioMode) where isStatus && !p.isEmpty:
            return p[0] <= 2 ? [.spatialAudio(p[0])] : []

        case (BMAPBlock.audioModes, AudioModes.capabilities) where isStatus && p.count >= 6:
            // AudioModesCapabilitiesResponse: flags in [5], minimum favorites in [6]
            let f = p[5]
            return [.modeCapabilities(BoseModeCapabilities(
                boseModes: Int(p[0]), userModes: Int(p[1]), cncSupported: f & 0x01 != 0, autoCNCSupported: f & 0x02 != 0,
                spatialSupported: f & 0x04 != 0, windSupported: f & 0x08 != 0, favoritesSupported: f & 0x10 != 0,
                ancSupported: f & 0x20 != 0, minimumFavorites: p.count >= 7 ? Int(p[6]) : 0))]
        case (BMAPBlock.audioModes, AudioModes.favorites) where isStatus && !p.isEmpty:
            // AudioModesFavoritesResponse: [n] then ceil(n/8) bytes, last byte = modes 0-7
            let n = Int(p[0])
            let len = (n + 7) / 8
            guard p.count >= 1 + len else { return [] }
            return [.favorites(bits(p[1 ..< 1 + len]).filter { $0 < n })]
        case (BMAPBlock.audioModes, AudioModes.namesSupported) where isStatus:
            // AudioModesNamesResponse: byte i bit j → prompt id i*8+j, first 5 bytes, byte 4 only bits 0-4
            var ids: [UInt8] = []
            for (i, byte) in p.prefix(5).enumerated() {
                for j in 0 ..< 8 where !(i == 4 && j > 4) && byte & (1 << j) != 0 { ids.append(UInt8(i * 8 + j)) }
            }
            return [.namesSupported(ids)]
        case (BMAPBlock.audioModes, AudioModes.settingsConfig) where isStatus && p.count >= 5:
            return [.settingsConfig(BoseSettingsConfig(cncLevel: Int(p[0]), autoCNC: p[1] == 1, spatial: p[2],
                                                       windBlock: p[3] == 1, ancToggle: p[4] == 1))]
        case (BMAPBlock.audioModes, AudioModes.reset) where packet.op == .result:
            return p.isEmpty ? [] : [.modeReset(Int(p[0]))]
        case (BMAPBlock.audioModes, AudioModes.modeConfig) where isStatus:
            return BoseModeConfig(status: p).map { [.modeConfig($0)] } ?? []
        case (BMAPBlock.audioModes, AudioModes.currentMode) where !p.isEmpty:
            return [.currentMode(Int(p[0]))]   // Status (Get) or Result (Start)

        default:
            return []
        }
    }

    static func errorName(_ code: UInt8) -> String {
        switch code {
        case 1: "invalid length"
        case 3: "function block not supported"
        case 4: "function not supported"
        case 5: "operator not supported"
        case 6: "invalid data"
        case 7: "data unavailable"
        case 10: "invalid state"
        case 12: "busy"
        case 20: "insecure transport"
        default: "error \(code)"
        }
    }
}
