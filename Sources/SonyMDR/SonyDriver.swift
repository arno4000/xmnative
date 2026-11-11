import Foundation
import HeadphoneKit

@MainActor
public final class SonyDriver: HeadphoneDriver, WireLogging {
    public private(set) var state: HeadphoneState {
        didSet { if state != oldValue { onStateChange?(state) } }
    }
    public var onStateChange: ((HeadphoneState) -> Void)?
    public var log: ((String) -> Void)? {
        didSet { link.log = log }
    }

    public let table: SonyTableSet
    private let link: MDRLink

    // Capabilities learned from the device
    private var functions: Set<UInt8> = []
    private var ncV1: (type: UInt8, ncSettingType: UInt8, asmSettingType: UInt8, maxLevel: Int, voice: Bool)?
    private var ncTypeV2: UInt8?
    private var noiseTrailer: [UInt8] = []
    private var eqType: UInt8 = 0x01
    private var eqLevelSteps = 21
    private var eqBandCount = 0
    private var eqPresets: [EqPreset] = []
    private var eqBandInfo: [SonyEqBandInfo] = []
    private var eqParam: (preset: Int, steps: [Int])?
    private var apoOptions: [UInt8] = []
    private var apoSelectTime: UInt8 = 0x00
    private var upscalingName = "DSEE"
    private var eqTypeV2: UInt8 = 0x00
    private var voiceGuidanceTypeV2: UInt8?
    private var voiceGuidanceLanguageV2: UInt8?

    // request → response matching (keyed by response command byte)
    /// Keyed by `table << 8 | command` (table 0x0C or 0x0E).
    private var responseWaiters: [Int: [PendingResponse]] = [:]
    private var assignableKeys: [SonyAssignableKey] = []
    private var assignablePresets: [UInt8] = []
    // latest-wins coalescing for slider-driven actions
    private var coalesced: [String: HeadphoneAction] = [:]
    private var inFlight: Set<String> = []

    public init(transport: ByteTransport, table: SonyTableSet, vendor: String = "Sony") {
        self.table = table
        self.link = MDRLink(transport: transport)
        self.state = HeadphoneState(vendor: vendor)
        link.onMessage = { [weak self] type, payload in self?.handle(type: type, payload: payload) }
    }

    public var onDisconnect: ((Error?) -> Void)? {
        get { link.onClose }
        set { link.onClose = newValue }
    }

    public func stop() { link.close() }

    // MARK: - Handshake

    public func start() async throws {
        switch table {
        case .one: try await startV1()
        case .two: try await startV2()
        }
    }

    private func startV1() async throws {
        guard await request(SonyV1.getProtocolInfo(), expect: SonyV1.Cmd.retProtocolInfo) else {
            throw HeadphoneError.timeout
        }
        await request(SonyV1.getModelName(), expect: SonyV1.Cmd.retDeviceInfo)
        await request(SonyV1.getFirmwareVersion(), expect: SonyV1.Cmd.retDeviceInfo)
        let gotFunctions = await request(SonyV1.getSupportFunctions(), expect: SonyV1.Cmd.retSupportFunction)
        let has: (UInt8) -> Bool = { f in !gotFunctions || self.functions.isEmpty || self.functions.contains(f) }
        typealias F = SonyV1.Function

        if has(F.batteryLevel) { await request(SonyV1.getBattery(0), expect: SonyV1.Cmd.retBattery) }
        if functions.contains(F.leftRightBattery) { await request(SonyV1.getBattery(1), expect: SonyV1.Cmd.retBattery) }
        if functions.contains(F.cradleBattery) { await request(SonyV1.getBattery(2), expect: SonyV1.Cmd.retBattery) }
        if has(F.codecIndicator) { await request(SonyV1.getCodec(), expect: SonyV1.Cmd.retCodec) }

        let ncType: UInt8? = functions.contains(F.ncAndAsm) || functions.isEmpty ? 0x02
            : functions.contains(F.ambientSound) ? 0x03
            : functions.contains(F.noiseCancelling) ? 0x01 : nil
        if let t = ncType {
            await request(SonyV1.getNcAsmCapability(t), expect: SonyV1.Cmd.ncRetCapability)
            await request(SonyV1.getNcAsm(t), expect: SonyV1.Cmd.ncRetParam)
        }

        if has(F.presetEq) || functions.contains(F.presetEqNonCustomizable) {
            eqType = functions.contains(F.presetEq) || functions.isEmpty ? 0x01 : 0x03
            await request(SonyV1.getEqCapability(eqType), expect: SonyV1.Cmd.eqRetCapability)
            await request(SonyV1.getEqBandInfo(eqType), expect: SonyV1.Cmd.eqRetExtInfo, timeout: .milliseconds(800))
            await request(SonyV1.getEq(eqType), expect: SonyV1.Cmd.eqRetParam)
        }
        if has(F.smartTalkingMode) {
            await request(SonyV1.getSpeakToChat(), expect: SonyV1.Cmd.sysRetParam)
            await request(SonyV1.getSpeakToChatDetails(), expect: SonyV1.Cmd.sysRetExtParam, timeout: .milliseconds(800))
        }
        if has(F.autoPowerOff) {
            await request(SonyV1.getAutoPowerOffCapability(), expect: SonyV1.Cmd.sysRetCapability)
            await request(SonyV1.getAutoPowerOff(), expect: SonyV1.Cmd.sysRetParam)
        }
        if has(F.upscaling) {
            await request(SonyV1.getAudioCapability(SonyV1.AudioType.upscaling), expect: SonyV1.Cmd.audioRetCapability)
            await request(SonyV1.getAudio(SonyV1.AudioType.upscaling), expect: SonyV1.Cmd.audioRetParam)
        }
        if has(F.connectionMode) {
            await request(SonyV1.getAudio(SonyV1.AudioType.connectionMode), expect: SonyV1.Cmd.audioRetParam)
        }
        for gs in [F.generalSetting1, F.generalSetting2, F.generalSetting3] where functions.contains(gs) {
            if await request(SonyV1.getGeneralSettingCapability(gs), expect: SonyV1.Cmd.gsRetCapability) {
                await request(SonyV1.getGeneralSetting(gs), expect: SonyV1.Cmd.gsRetParam)
            }
        }
        if functions.contains(F.controlByWearing) {
            await request(SonyV1.getWearPause(), expect: SonyV1.Cmd.sysRetParam)
        }
        if functions.contains(F.assignableSettings),
           await request(SonyV1.getAssignableCapability(), expect: SonyV1.Cmd.sysRetCapability) {
            await request(SonyV1.getAssignable(), expect: SonyV1.Cmd.sysRetParam)
        }
        if functions.contains(F.ncOptimizer),
           await request(SonyV1.getOptimizerCapability(), expect: SonyV1.Cmd.optRetCapability) {
            await request(SonyV1.getOptimizerStatus(), expect: SonyV1.Cmd.optRetStatus)
        }
        if functions.contains(F.voiceGuidance) {
            await request(SonyV1Table2.getVoiceGuidance(), expect: SonyV1Table2.Cmd.vgRetParam, table: .dataMDRNo2)
        }
        if functions.contains(F.playbackController),
           await request(SonyV1.getPlaybackCapability(), expect: SonyV1.Cmd.playRetCapability) {
            await request(SonyV1.getPlayStatus(), expect: SonyV1.Cmd.playRetStatus)
            await request(SonyV1.getVolume(), expect: SonyV1.Cmd.playRetParam)
            await refreshMetadata()
        }
    }

    private func refreshMetadata() async {
        await request(SonyV1.getMetadata(0x00), expect: SonyV1.Cmd.playRetParam, timeout: .milliseconds(800))
        await request(SonyV1.getMetadata(0x02), expect: SonyV1.Cmd.playRetParam, timeout: .milliseconds(800))
    }

    private func startV2() async throws {
        guard await request(SonyV2.getProtocolInfo(), expect: SonyV2.Cmd.retProtocolInfo) else {
            throw HeadphoneError.timeout
        }
        await request(SonyV2.getModelName(), expect: SonyV2.Cmd.retDeviceInfo)
        await request(SonyV2.getFirmwareVersion(), expect: SonyV2.Cmd.retDeviceInfo)
        // Table set 2 feature discovery by probing: unsupported queries are ACKed but never answered.
        let probe: Duration = .milliseconds(700)
        if !(await request(SonyV2.getBattery(0), expect: SonyV2.Cmd.powerRetStatus, timeout: probe)) {
            if await request(SonyV2.getBattery(1), expect: SonyV2.Cmd.powerRetStatus, timeout: probe) {
                await request(SonyV2.getBattery(2), expect: SonyV2.Cmd.powerRetStatus, timeout: probe)
            }
        }
        await request(SonyV2.getCodec(), expect: SonyV2.Cmd.commonRetStatus, timeout: probe)
        for t in SonyV2.NcType.probeOrder {
            if await request(SonyV2.getNcAsm(t), expect: SonyV2.Cmd.ncRetParam, timeout: probe), ncTypeV2 != nil { break }
        }
        for t: UInt8 in [0x00, 0x04, 0x02] {
            if await request(SonyV2.getEqCapability(t), expect: SonyV2.Cmd.eqRetCapability, timeout: probe) {
                eqTypeV2 = t
                await request(SonyV2.getEq(t), expect: SonyV2.Cmd.eqRetParam, timeout: probe)
                break
            }
        }
        if await request(SonyV2.getSpeakToChat(), expect: SonyV2.Cmd.sysRetParam, timeout: probe) {
            await request(SonyV2.getSpeakToChatDetails(), expect: SonyV2.Cmd.sysRetExtParam, timeout: probe)
        }
        await request(SonyV2.getWearPause(), expect: SonyV2.Cmd.sysRetParam, timeout: probe)
        if await request(SonyV2.getAutoPowerOffCapability(), expect: SonyV2.Cmd.powerRetCapability, timeout: probe) {
            await request(SonyV2.getAutoPowerOff(), expect: SonyV2.Cmd.powerRetParam, timeout: probe)
        }
        await request(SonyV2.getUpscaling(), expect: SonyV2.Cmd.audioRetParam, timeout: probe)
        await request(SonyV2.getConnectionMode(), expect: SonyV2.Cmd.audioRetParam, timeout: probe)
        for gs: UInt8 in [0xD1, 0xD2, 0xD3, 0xD4] {
            guard await request(SonyV2.getGeneralSettingCapability(gs), expect: SonyV2.Cmd.gsRetCapability, timeout: probe) else { break }
            await request(SonyV2.getGeneralSetting(gs), expect: SonyV2.Cmd.gsRetParam, timeout: probe)
        }
        for t in SonyV2Table2.onOffTypes {
            if await request(SonyV2Table2.getVoiceGuidance(t), expect: SonyV2Table2.Cmd.vgRetParam, table: .dataMDRNo2, timeout: probe) { break }
        }
    }

    // MARK: - Requests

    /// Sends `payload` and waits until a message with command byte `expect` arrives.
    @discardableResult
    private func request(_ payload: [UInt8], expect: UInt8, table: MDRDataType = .dataMDR,
                         timeout: Duration = .milliseconds(2000)) async -> Bool {
        let key = Int(table.rawValue) << 8 | Int(expect)
        let pending = PendingResponse()
        responseWaiters[key, default: []].append(pending)   // registered before anything can arrive
        defer { responseWaiters[key]?.removeAll { $0 === pending } }
        do {
            try await link.send(payload, type: table)
        } catch {
            pending.resolve(false)
            return false
        }
        if pending.isDone { return pending.result }
        let timer = Task { @MainActor in
            try? await Task.sleep(for: timeout)
            pending.resolve(false)
        }
        let ok = await pending.wait()
        timer.cancel()
        return ok
    }

    private func send(_ payload: [UInt8], table: MDRDataType = .dataMDR) async {
        do { try await link.send(payload, type: table) } catch { log?("send failed: \(error)") }
    }

    // MARK: - Incoming

    private func handle(type: UInt8, payload: [UInt8]) {
        let tableByte: UInt8
        let updates: [SonyUpdate]
        switch MDRDataType(rawValue: type) {
        case .dataMDR?, .largeDataMDR?, .shotMDR?:
            tableByte = MDRDataType.dataMDR.rawValue
            updates = table == .one ? SonyV1.parse(payload) : SonyV2.parse(payload)
        case .dataMDRNo2?, .shotMDRNo2?:
            tableByte = MDRDataType.dataMDRNo2.rawValue
            updates = table == .one ? SonyV1Table2.parse(payload) : SonyV2Table2.parse(payload)
        default:
            return
        }
        updates.forEach(apply)
        if let cmd = payload.first, let waiters = responseWaiters.removeValue(forKey: Int(tableByte) << 8 | Int(cmd)) {
            waiters.forEach { $0.resolve(true) }
        }
    }

    func apply(_ update: SonyUpdate) {
        switch update {
        case .protocolVersion(let v):
            state.protocolInfo = "Sony MDR table set \(table == .one ? 1 : 2), v\(String(v, radix: 16))"
        case .modelName(let n): state.modelName = n
        case .firmwareVersion(let v): state.firmwareVersion = v
        case .supportedFunctions(let f): functions = Set(f)

        case .battery(let l): state.battery = (state.battery ?? BatteryState()).with { $0.main = l }
        case .leftRightBattery(let l, let r): state.battery = (state.battery ?? BatteryState()).with { $0.left = l; $0.right = r }
        case .caseBattery(let c): state.battery = (state.battery ?? BatteryState()).with { $0.chargingCase = c }
        case .codec(let c): state.codec = c

        case let .ncAsmCapabilityV1(type, ncSettingType, asmSettingType, maxLevel, voice):
            ncV1 = (type, ncSettingType, asmSettingType, maxLevel, voice)
            if var n = state.noiseControl { applyNoiseCapabilities(&n); state.noiseControl = n }
        case .noise(let snap):
            if table == .two { ncTypeV2 = snap.inquiredType; noiseTrailer = snap.trailer }
            var n = state.noiseControl ?? NoiseControlState(mode: .off, ambientLevel: 10, voiceFocus: false,
                                                            supportedModes: [], ambientLevelRange: nil, supportsVoiceFocus: false)
            n.mode = snap.mode
            if snap.mode == .ambient && snap.ambientLevel > 0 { n.ambientLevel = snap.ambientLevel }
            if snap.mode == .ambient { n.voiceFocus = snap.voiceFocus }
            applyNoiseCapabilities(&n)
            state.noiseControl = n

        case let .eqCapability(bandCount, levelSteps, presets):
            eqBandCount = bandCount
            eqLevelSteps = levelSteps > 1 ? levelSteps : 21
            eqPresets = presets
            rebuildEq()
        case .eqParam(let preset, let steps):
            eqParam = (preset, steps)
            rebuildEq()
        case .eqBandInfo(let info):
            eqBandInfo = info
            rebuildEq()

        case .speakToChat(let on):
            state.speakToChat = (state.speakToChat ?? SpeakToChatState(enabled: on)).with { $0.enabled = on }
        case let .speakToChatDetails(s, vf, t):
            state.speakToChat = (state.speakToChat ?? SpeakToChatState(enabled: false)).with {
                $0.sensitivity = s; $0.voiceFocus = vf; $0.timeout = t
            }

        case .autoPowerOffOptions(let opts):
            apoOptions = opts
            if let s = state.autoPowerOff { state.autoPowerOff = AutoPowerOffState(current: s.current, options: apoOptionList()) }
        case let .autoPowerOff(active, selectTime):
            apoSelectTime = selectTime
            state.autoPowerOff = AutoPowerOffState(current: SonyV1.autoPowerOffOption(active), options: apoOptionList(including: active))

        case .upscalingType(let t):
            upscalingName = SonyV1.upscalingName(t)
            if let u = state.upscaling { state.upscaling = UpscalingState(name: upscalingName, enabled: u.enabled) }
        case .upscaling(let on): state.upscaling = UpscalingState(name: upscalingName, enabled: on)
        case .connectionPriority(let p): state.connectionPriority = ConnectionPriorityState(current: p)

        case let .generalSettingCapability(id, title, subtitle, isBoolean):
            guard isBoolean else { return }
            let key = "gs-\(id)"
            if let i = state.toggles.firstIndex(where: { $0.id == key }) {
                state.toggles[i].title = title; state.toggles[i].subtitle = subtitle
            } else {
                state.toggles.append(ToggleSetting(id: key, title: title, subtitle: subtitle, isOn: false))
            }
        case let .generalSetting(id, isOn):
            if let i = state.toggles.firstIndex(where: { $0.id == "gs-\(id)" }) { state.toggles[i].isOn = isOn }

        case .wearPause(let on):
            setToggle(id: "wear-pause", title: "Pause when taken off",
                      subtitle: "Music pauses when you take the headphones off and resumes when you put them back on.", isOn: on)
        case .voiceGuidance(let on):
            setToggle(id: "voice-guidance", title: "Voice guidance",
                      subtitle: "Spoken notifications such as battery level and power on/off.", isOn: on)

        case .assignableCapability(let keys):
            assignableKeys = keys
            rebuildButtons()
        case .assignable(let presets):
            assignablePresets = presets
            rebuildButtons()

        case .playbackCapability(let maxVolume):
            var p = state.playback ?? PlaybackState()
            p.maxVolume = maxVolume > 0 ? maxVolume : 30
            state.playback = p
        case .playStatus(let playing):
            state.playback?.isPlaying = playing
        case .volume(let v):
            state.playback?.volume = v
        case let .metadata(type, text):
            if type == 0x00 { state.playback?.title = text }
            if type == 0x02 { state.playback?.artist = text }
        case .metadataChanged:
            Task { await refreshMetadata() }

        case let .voiceGuidanceV2(type, on, language):
            voiceGuidanceTypeV2 = type
            if let language { voiceGuidanceLanguageV2 = language }
            setToggle(id: "voice-guidance", title: "Voice guidance",
                      subtitle: "Spoken notifications such as battery level and power on/off.", isOn: on)
        case .optimizerAvailable:
            if state.optimizer == nil { state.optimizer = OptimizerState(phase: .idle) }
        case .optimizerStatus(let s):
            let phase: OptimizerState.Phase = switch s {
            case 0x01: .measuringFit
            case 0x02: .measuringPressure
            case 0x10: .optimizing
            case 0x11: .finished
            default: .idle
            }
            state.optimizer = OptimizerState(phase: phase)

        case .unknown: break
        }
    }

    private func setToggle(id: String, title: String, subtitle: String?, isOn: Bool) {
        if let i = state.toggles.firstIndex(where: { $0.id == id }) {
            state.toggles[i].isOn = isOn
        } else {
            state.toggles.append(ToggleSetting(id: id, title: title, subtitle: subtitle, isOn: isOn))
        }
    }

    private func rebuildButtons() {
        guard !assignableKeys.isEmpty else { return }
        state.buttons = assignableKeys.enumerated().compactMap { i, key in
            guard key.presets.count > 1 else { return nil }   // nothing to choose
            let current = i < assignablePresets.count ? assignablePresets[i] : key.defaultPreset
            return ButtonAssignment(id: i, title: SonyV1.assignableKeyTitle(key),
                                    options: key.presets.map { ButtonFunction(id: Int($0), title: SonyV1.assignablePresetTitle($0)) },
                                    selectedID: Int(current))
        }
    }

    private func applyNoiseCapabilities(_ n: inout NoiseControlState) {
        switch table {
        case .one:
            guard let c = ncV1 else {
                n.supportedModes = [.noiseCancelling, .ambient, .off]
                n.ambientLevelRange = 1 ... 20
                n.supportsVoiceFocus = true
                return
            }
            switch c.type {
            case 0x01: n.supportedModes = [.noiseCancelling, .off]
            case 0x03: n.supportedModes = [.ambient, .off]
            default: n.supportedModes = c.ncSettingType == 0x02 ? [.noiseCancelling, .windReduction, .ambient, .off] : [.noiseCancelling, .ambient, .off]
            }
            n.ambientLevelRange = c.asmSettingType == 0x01 ? 1 ... max(1, c.maxLevel) : nil
            n.supportsVoiceFocus = c.voice
        case .two:
            n.supportedModes = ncTypeV2 == SonyV2.NcType.asmSeamless ? [.ambient, .off] : [.noiseCancelling, .ambient, .off]
            n.ambientLevelRange = 1 ... 20
            n.supportsVoiceFocus = true
        }
        n.ambientLevel = min(max(n.ambientLevel, n.ambientLevelRange?.lowerBound ?? 1), n.ambientLevelRange?.upperBound ?? 20)
    }

    private func rebuildEq() {
        guard let param = eqParam else { return }
        let center = (eqLevelSteps - 1) / 2
        let count = param.steps.count
        let labels: [String]
        var clearBass: Int? = nil
        if eqBandInfo.count == count {
            labels = eqBandInfo.map(\.label)
            clearBass = eqBandInfo.firstIndex(where: \.isClearBass)
        } else {
            switch count {
            case 6: labels = ["Clear Bass", "400", "1k", "2.5k", "6.3k", "16k"]; clearBass = 0
            case 5: labels = ["400", "1k", "2.5k", "6.3k", "16k"]
            case 10: labels = ["31", "63", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]
            default: labels = (1 ... max(1, count)).map { "Band \($0)" }
            }
        }
        let bands = param.steps.enumerated().map { i, raw in
            EqBand(id: i, label: i < labels.count ? labels[i] : "Band \(i + 1)", value: raw - center, isClearBass: i == clearBass)
        }
        var presets = eqPresets
        if !presets.contains(where: { $0.id == param.preset }) {
            presets.append(EqPreset(id: param.preset, name: SonyEqNames.name(for: param.preset), isCustomizable: SonyEqNames.isCustomizable(param.preset)))
        }
        state.equalizer = EqualizerState(presets: presets, activePresetID: param.preset, bands: bands, bandRange: -center ... center)
    }

    private func apoOptionList(including active: UInt8? = nil) -> [AutoPowerOffOption] {
        var ids = apoOptions
        if let a = active, !ids.contains(a) { ids.append(a) }
        if ids.isEmpty { ids = [0x10, 0x11] }
        return ids.map(SonyV1.autoPowerOffOption)
    }

    // MARK: - Actions

    public func perform(_ action: HeadphoneAction) async {
        guard let key = coalesceKey(action) else { return await execute(action) }
        coalesced[key] = action
        guard !inFlight.contains(key) else { return }
        inFlight.insert(key)
        while let next = coalesced.removeValue(forKey: key) { await execute(next) }
        inFlight.remove(key)
    }

    private func coalesceKey(_ a: HeadphoneAction) -> String? {
        switch a {
        case .setNoise: return "noise"
        case .setEqBands: return "eq"
        case .setVolume: return "volume"
        default: return nil
        }
    }

    private func execute(_ action: HeadphoneAction) async {
        switch action {
        case let .setNoise(mode, level, voice, isFinal):
            let turningOn = state.noiseControl?.mode == .off && mode != .off
            if var n = state.noiseControl {
                n.mode = mode; n.ambientLevel = level; n.voiceFocus = voice
                state.noiseControl = n
            }
            switch table {
            case .one:
                let c = ncV1 ?? (0x02, 0x00, 0x01, 20, true)
                switch c.type {
                case 0x01: await send(SonyV1.setNcOnly(enabled: mode != .off))
                case 0x03: await send(SonyV1.setAsmOnly(enabled: mode == .ambient, ambientLevel: level, voiceFocus: voice, isFinal: isFinal,
                                                        turningOn: turningOn, asmSettingType: c.asmSettingType))
                default: await send(SonyV1.setNcAsm(mode: mode, ambientLevel: level, voiceFocus: voice, isFinal: isFinal, turningOn: turningOn,
                                                    ncSettingType: c.ncSettingType, asmSettingType: c.asmSettingType))
                }
            case .two:
                await send(SonyV2.setNcAsm(type: ncTypeV2 ?? SonyV2.NcType.dualSeamless, mode: mode, ambientLevel: level,
                                           voiceFocus: voice, isFinal: isFinal, trailer: noiseTrailer))
            }

        case .selectEqPreset(let id):
            if var p = eqParam { p.preset = id; eqParam = p; rebuildEq() }
            if table == .one {
                await send(SonyV1.selectEqPreset(id, type: eqType))
                await request(SonyV1.getEq(eqType), expect: SonyV1.Cmd.eqRetParam)
            } else {
                await send(SonyV2.selectEqPreset(id, type: eqTypeV2))
                await request(SonyV2.getEq(eqTypeV2), expect: SonyV2.Cmd.eqRetParam)
            }

        case .setEqBands(let values):
            let center = (eqLevelSteps - 1) / 2
            let raw = values.map { min(max($0 + center, 0), eqLevelSteps - 1) }
            if var p = eqParam { p.steps = raw; eqParam = p; rebuildEq() }
            await send(table == .one ? SonyV1.setEqBands(raw) : SonyV2.setEqBands(raw, type: eqTypeV2))

        case .setSpeakToChat(let on):
            state.speakToChat?.enabled = on
            await send(table == .one ? SonyV1.setSpeakToChat(on) : SonyV2.setSpeakToChat(on))

        case let .setSpeakToChatDetails(s, vf, t):
            state.speakToChat?.sensitivity = s; state.speakToChat?.voiceFocus = vf; state.speakToChat?.timeout = t
            if table == .one {
                await send(SonyV1.setSpeakToChatDetails(s, voiceFocus: vf ?? true, t))
            } else {
                await send(SonyV2.setSpeakToChatDetails(s, t))
            }

        case .setAutoPowerOff(let option):
            guard let b = SonyV1.autoPowerOffByte(option) else { return }
            let isTimer: Bool = { if case .minutes = option { return true }; return false }()
            if isTimer { apoSelectTime = b }
            state.autoPowerOff?.current = option
            let sel = isTimer ? b : apoSelectTime
            await send(table == .one ? SonyV1.setAutoPowerOff(active: b, selectTime: sel)
                                     : SonyV2.setAutoPowerOff(active: b, selectTime: sel))

        case .setUpscaling(let on):
            state.upscaling?.enabled = on
            await send(table == .one ? SonyV1.setUpscaling(on) : SonyV2.setUpscaling(on))

        case .setConnectionPriority(let p):
            state.connectionPriority?.current = p
            await send(table == .one ? SonyV1.setConnectionPriority(p) : SonyV2.setConnectionPriority(p))

        case let .setButton(index, functionID):
            guard table == .one, index < assignableKeys.count else { return }
            var presets = [UInt8](repeating: 0xFE, count: assignableKeys.count)   // 0xFE = unchanged
            presets[index] = UInt8(clamping: functionID)
            if index < assignablePresets.count { assignablePresets[index] = UInt8(clamping: functionID) }
            rebuildButtons()
            await send(SonyV1.setAssignable(presets))

        case .playback(let command):
            guard table == .one else { return }
            if command == .play { state.playback?.isPlaying = true }
            if command == .pause { state.playback?.isPlaying = false }
            await send(SonyV1.playback(command))

        case .setVolume(let v):
            guard table == .one else { return }
            state.playback?.volume = v
            await send(SonyV1.setVolume(v))

        case let .setToggle(id, isOn) where id == "wear-pause":
            setToggle(id: id, title: "", subtitle: nil, isOn: isOn)
            await send(table == .one ? SonyV1.setWearPause(isOn) : SonyV2.setWearPause(isOn))

        case let .setToggle(id, isOn) where id == "voice-guidance":
            setToggle(id: id, title: "", subtitle: nil, isOn: isOn)
            if table == .one {
                await send(SonyV1Table2.setVoiceGuidance(isOn), table: .dataMDRNo2)
            } else if let t = voiceGuidanceTypeV2 {
                await send(SonyV2Table2.setVoiceGuidance(isOn, type: t, language: voiceGuidanceLanguageV2), table: .dataMDRNo2)
            }

        case let .setToggle(id, isOn):
            guard id.hasPrefix("gs-"), let gs = UInt8(id.dropFirst(3)) else { return }
            if let i = state.toggles.firstIndex(where: { $0.id == id }) { state.toggles[i].isOn = isOn }
            await send(table == .one ? SonyV1.setGeneralSetting(gs, isOn) : SonyV2.setGeneralSetting(gs, isOn))

        case .selectListeningMode, .setNoiseLevel, .setChoice, .createListeningMode, .updateListeningMode,
             .deleteListeningMode, .setListeningModeFavorite, .setLiveNoise:
            return   // Bose-style features; Sony uses noise modes instead.

        case .startOptimizer, .cancelOptimizer:
            guard table == .one, state.optimizer != nil else { return }
            let start = action == .startOptimizer
            state.optimizer = OptimizerState(phase: start ? .measuringFit : .idle)
            await send(SonyV1.optimizer(start: start))

        case .refresh:
            if table == .one {
                if state.battery?.main != nil { await request(SonyV1.getBattery(0), expect: SonyV1.Cmd.retBattery) }
                if state.battery?.left != nil { await request(SonyV1.getBattery(1), expect: SonyV1.Cmd.retBattery) }
                if state.battery?.chargingCase != nil { await request(SonyV1.getBattery(2), expect: SonyV1.Cmd.retBattery) }
                if state.codec != nil { await request(SonyV1.getCodec(), expect: SonyV1.Cmd.retCodec) }
            } else {
                if state.battery?.main != nil { await request(SonyV2.getBattery(0), expect: SonyV2.Cmd.powerRetStatus) }
                if state.battery?.left != nil { await request(SonyV2.getBattery(1), expect: SonyV2.Cmd.powerRetStatus) }
                if state.codec != nil { await request(SonyV2.getCodec(), expect: SonyV2.Cmd.commonRetStatus) }
            }
        }
    }
}

@MainActor
final class PendingResponse {
    private(set) var isDone = false
    private(set) var result = false
    private var continuation: CheckedContinuation<Bool, Never>?

    func resolve(_ value: Bool) {
        guard !isDone else { return }
        isDone = true
        result = value
        continuation?.resume(returning: value)
        continuation = nil
    }

    func wait() async -> Bool {
        if isDone { return result }
        return await withCheckedContinuation { c in
            if isDone { c.resume(returning: result) } else { continuation = c }
        }
    }
}

extension BatteryState {
    func with(_ f: (inout BatteryState) -> Void) -> BatteryState { var c = self; f(&c); return c }
}

extension SpeakToChatState {
    func with(_ f: (inout SpeakToChatState) -> Void) -> SpeakToChatState { var c = self; f(&c); return c }
}

// MARK: - Factory

@MainActor
public struct SonyDriverFactory: HeadphoneDriverFactory {
    /// RFCOMM services from lm0.i in the app. The app tries table set 2 first, then table set 1.
    public static let tableSet2Service = UUID(uuidString: "956C7B26-D49A-4BA8-B03F-B17D393CB6E2")!
    public static let tableSet1Service = UUID(uuidString: "96CC203E-5068-46AD-B32D-E316F5E069BA")!
    /// Byte-reversed spellings the app also carries (lm0.h.b()).
    static let tableSet2Reversed = UUID(uuidString: "E2B63C39-7DB1-3FB0-A84B-9AD4267B6C95")!
    static let tableSet1Reversed = UUID(uuidString: "BA69E0F5-16E3-2DB3-AD46-68503E20CC96")!

    public static var knownServiceUUIDs: [UUID] { [tableSet2Service, tableSet1Service, tableSet2Reversed, tableSet1Reversed] }

    public init() {}
    public var vendor: String { "Sony" }
    public var serviceUUIDs: [UUID] { Self.knownServiceUUIDs }

    public func mightSupport(deviceName: String) -> Bool {
        let n = deviceName.uppercased()
        return ["WH-", "WF-", "WI-", "MDR-", "LINKBUDS", "ULT WEAR", "INZONE", "SONY"].contains { n.contains($0) }
    }

    public func preferredService(for device: DeviceDescriptor) -> (uuid: UUID, channel: UInt8)? {
        for uuid in Self.knownServiceUUIDs {
            if let ch = device.rfcommServices[uuid] { return (uuid, ch) }
        }
        return nil
    }

    public func makeDriver(device: DeviceDescriptor, serviceUUID: UUID, transport: ByteTransport) -> HeadphoneDriver {
        let table: SonyTableSet = (serviceUUID == Self.tableSet1Service || serviceUUID == Self.tableSet1Reversed) ? .one : .two
        return SonyDriver(transport: transport, table: table)
    }
}
