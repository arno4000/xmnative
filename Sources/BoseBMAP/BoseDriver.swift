import Foundation
import HeadphoneKit

@MainActor
public final class BoseDriver: HeadphoneDriver, WireLogging {
    public private(set) var state: HeadphoneState {
        didSet { if state != oldValue { onStateChange?(state) } }
    }
    public var onStateChange: ((HeadphoneState) -> Void)?
    public var log: ((String) -> Void)? {
        didSet { link.log = log }
    }
    public var onDisconnect: ((Error?) -> Void)? {
        get { link.onClose }
        set { link.onClose = newValue }
    }

    private let link: BMAPLink

    // What the device told us
    private var blocks: Set<Int> = []
    private var productID: Int?
    private var productName: String?
    private var batteryPercent: Int?
    private var charging = false
    private var modes: [Int: BoseModeConfig] = [:]
    private var currentMode: Int?
    private var cncSteps = 11
    private var ranges: [BoseRange] = []
    private var voicePromptLanguage: UInt8 = 0
    private var onHead: BoseOnHead?
    private var buttons: [Int: BoseButton] = [:]
    private var amSpatial: UInt8?
    private var modeCaps: BoseModeCapabilities?
    private var favorites: [Int]?
    private var supportedNames: [UInt8] = []
    private var settingsConfig: BoseSettingsConfig?
    private var sidetoneOptions: [UInt8] = []

    // latest-wins coalescing for slider-driven actions
    private var coalesced: [String: HeadphoneAction] = [:]
    private var inFlight: Set<String> = []

    public init(transport: ByteTransport) {
        link = BMAPLink(transport: transport)
        state = HeadphoneState(vendor: "Bose")
        link.onPacket = { [weak self] packet in self?.handle(packet) }
    }

    public func stop() { link.close() }

    // MARK: - Handshake

    public func start() async throws {
        // Same opening as the Bose app: BMAP version, then the list of function blocks.
        guard let v = await link.request(BMAP.get(BMAPBlock.productInfo, BMAP.ProductInfo.bmapVersion), timeout: .seconds(3)),
              v.op == .status else {
            throw HeadphoneError.timeout
        }
        await get(BMAPBlock.productInfo, BMAP.ProductInfo.allFunctionBlocks)
        await get(BMAPBlock.productInfo, BMAP.ProductInfo.productIDVariant)
        await get(BMAPBlock.productInfo, BMAP.ProductInfo.firmwareVersion)

        if has(BMAP.notificationBlock) {
            // Ask the headphones to report changes made on the headphones themselves (buttons, battery, ...).
            let wanted = [BMAPBlock.productInfo, BMAPBlock.settings, BMAPBlock.status, BMAPBlock.deviceManagement,
                          BMAPBlock.audioManagement, BMAPBlock.audioModes, BMAP.notificationBlock]
            await link.request(BMAP.enableNotifications(blocks: wanted.filter { has($0) }))
        }

        if has(BMAPBlock.settings) {
            typealias S = BMAP.Settings
            for f in [S.productName, S.cnc, S.rangeControl, S.standbyTimer, S.voicePrompts, S.multipoint,
                      S.onHeadDetection, S.sidetone, S.buttons] {
                await get(BMAPBlock.settings, f)
            }
        }
        if has(BMAPBlock.status) {
            await get(BMAPBlock.status, BMAP.Status.battery)
            await get(BMAPBlock.status, BMAP.Status.chargerDetect)
        }
        if has(BMAPBlock.audioModes) {
            await get(BMAPBlock.audioModes, BMAP.AudioModes.capabilities)
            await get(BMAPBlock.audioModes, BMAP.AudioModes.namesSupported)
            await get(BMAPBlock.audioModes, BMAP.AudioModes.favorites)
            // Answering this is what makes the Bose app offer noise control outside of modes (C10989el0 → 31508).
            await get(BMAPBlock.audioModes, BMAP.AudioModes.settingsConfig)
            // One Status per mode, then a Result.
            await link.request(BMAP.start(BMAPBlock.audioModes, BMAP.AudioModes.modeConfig), until: [.result, .error],
                               timeout: .seconds(6))
            await get(BMAPBlock.audioModes, BMAP.AudioModes.currentMode)
        }
        if has(BMAPBlock.audioManagement) {
            typealias A = BMAP.AudioManagement
            await get(BMAPBlock.audioManagement, A.volume)
            await get(BMAPBlock.audioManagement, A.status)
            await get(BMAPBlock.audioManagement, A.spatialAudioMode)
            await refreshNowPlaying()
        }
    }

    private func has(_ block: UInt8) -> Bool { blocks.isEmpty || blocks.contains(Int(block)) }

    /// Get with a short timeout. Unsupported functions answer quickly with an Error.
    @discardableResult
    private func get(_ block: UInt8, _ function: UInt8, _ payload: [UInt8] = []) async -> Bool {
        await link.request(BMAP.get(block, function, payload), timeout: .milliseconds(1200))?.op == .status
    }

    /// SetGet, and re-read the value if the device refused, so the UI shows the real state again.
    private func setGet(_ packet: BMAPPacket) async {
        let reply = await link.request(packet, timeout: .seconds(2))
        if reply?.op != .status {
            if let reply, reply.op == .error, let code = reply.payload.last { log?("refused: \(BMAP.errorName(code))") }
            await get(packet.block, packet.function)
        }
    }

    private func refreshNowPlaying() async {
        await link.request(BMAP.start(BMAPBlock.audioManagement, BMAP.AudioManagement.nowPlaying), until: [.result, .error],
                           timeout: .milliseconds(1200))
    }

    // MARK: - Incoming

    private func handle(_ packet: BMAPPacket) {
        BMAP.parse(packet).forEach(apply)
    }

    func apply(_ update: BoseUpdate) {
        switch update {
        case .bmapVersion(let v): state.protocolInfo = "Bose BMAP \(v)"
        case .functionBlocks(let b): blocks = Set(b)
        case let .productID(id, _):
            productID = id
            state.modelName = BoseModels.name(for: id) ?? productName
        case .firmwareVersion(let v): state.firmwareVersion = v
        case .productName(let n):
            productName = n
            if state.modelName == nil || productID.flatMap(BoseModels.name) == nil { state.modelName = n }

        case .battery(let pct):
            batteryPercent = pct
            rebuildBattery()
        case .charging(let c):
            charging = c
            rebuildBattery()

        case let .voicePrompts(enabled, language):
            voicePromptLanguage = language
            setToggle("voice-prompts", "Voice prompts", "Spoken notifications such as battery level and connection status.", enabled)
        case let .standbyTimer(minutes, configurable):
            guard configurable else { state.autoPowerOff = nil; return }
            let current: AutoPowerOffOption = minutes == 0 ? .disabled : .minutes(minutes)
            var options: [AutoPowerOffOption] = [.minutes(5), .minutes(20), .minutes(40), .minutes(60), .minutes(180), .disabled]
            if !options.contains(current) { options.insert(current, at: 0) }
            state.autoPowerOff = AutoPowerOffState(current: current, options: options)
        case let .cnc(steps, _):
            if steps > 1 { cncSteps = steps }
            rebuildModes()
        case .ranges(let r):
            ranges = r
            rebuildEq()
        case let .multipoint(enabled, supported):
            if supported {
                setToggle("multipoint", "Connect to two devices", "Stay connected to two devices at the same time.", enabled)
            }
        case .onHead(let o):
            onHead = o
            setToggle("wear-detect", "Wear detection", "Lets the headphones notice when you take them off.", o.enabled)
            if o.autoPlaySupported {
                setToggle("wear-pause", "Pause when taken off", "Music pauses when you take the headphones off and resumes when you put them back on.", o.autoPlay)
            }
            if o.autoAnswerSupported {
                setToggle("wear-answer", "Answer calls by putting on", nil, o.autoAnswer)
            }
        case let .sidetone(mode, supported):
            sidetoneOptions = supported.isEmpty ? [0, 3, 2, 1] : supported
            setChoice(ChoiceSetting(id: "sidetone", title: "Hear yourself during calls",
                                    options: sidetoneOptions.map { ChoiceOption(id: Int($0), title: BoseNames.sidetone($0)) },
                                    selectedID: Int(mode)))
        case .button(let b):
            buttons[Int(b.button) << 8 | Int(b.event)] = b
            rebuildButtons()

        case let .volume(maxVolume, current):
            var p = state.playback ?? PlaybackState()
            p.maxVolume = maxVolume > 0 ? maxVolume : 30
            p.volume = current
            state.playback = p
        case .playState(let s):
            var p = state.playback ?? PlaybackState()
            p.isPlaying = s == 1
            state.playback = p
        case let .nowPlaying(attribute, text):
            guard state.playback != nil else { return }
            if attribute == 0 { state.playback?.title = text.isEmpty ? nil : text }
            if attribute == 1 { state.playback?.artist = text.isEmpty ? nil : text }
        case .spatialAudio(let m):
            amSpatial = m
            rebuildModes()

        case .modeCapabilities(let c):
            modeCaps = c
            rebuildModes()
        case .favorites(let f):
            favorites = f
            rebuildModes()
        case .namesSupported(let n):
            supportedNames = n
            rebuildModes()
        case .settingsConfig(let c):
            settingsConfig = c
            rebuildModes()
        case .modeReset: break
        case .modeConfig(let m):
            modes[m.index] = m
            rebuildModes()
        case .currentMode(let i):
            currentMode = i
            rebuildModes()

        case let .error(block, function, code):
            log?("error \(block).\(function): \(BMAP.errorName(code))")
        }
    }

    private func rebuildBattery() {
        guard let pct = batteryPercent else { return }
        state.battery = BatteryState(main: BatteryLevel(percent: pct, isCharging: charging))
    }

    private func setToggle(_ id: String, _ title: String, _ subtitle: String?, _ isOn: Bool) {
        if let i = state.toggles.firstIndex(where: { $0.id == id }) {
            state.toggles[i].isOn = isOn
        } else {
            state.toggles.append(ToggleSetting(id: id, title: title, subtitle: subtitle, isOn: isOn))
        }
    }

    private func setChoice(_ c: ChoiceSetting) {
        if let i = state.choices.firstIndex(where: { $0.id == c.id }) { state.choices[i] = c } else { state.choices.append(c) }
    }

    // MARK: Modes

    /// Device CNC 0 = most cancelling. The Bose app shows `steps - 1 - level` as "Noise Cancellation"
    /// (BmapCncLevelConfig.mapBetweenCncLevelAndWorldVolume; 8-10 = "blocks most outside sounds").
    private func strength(_ cnc: Int, steps: Int) -> Int { min(max(steps - 1 - cnc, 0), steps - 1) }
    private func cnc(_ strength: Int, steps: Int) -> Int { min(max(steps - 1 - strength, 0), steps - 1) }
    /// Noise control outside of modes always uses 11 steps in the app (C4559Np1.Q).
    private static let liveSteps = 11
    /// Level the Bose app gives a new mode (UR4.F).
    private static let newModeCNC = 5

    private func promptName(_ id: UInt8) -> String { BMAP.promptNames[id] ?? "Mode" }

    private func settings(for m: BoseModeConfig) -> ListeningModeSettings? {
        var s = ListeningModeSettings(nameID: Int(m.prompt.1))
        if m.userConfigurable, !m.name.isEmpty, m.name != promptName(m.prompt.1) { s.customName = m.name }
        if m.cncMutable { s.noiseLevel = strength(m.cncLevel, steps: cncSteps) }
        if m.ancMutable, let a = m.ancToggle { s.noiseControl = a }
        if m.autoCNCMutable { s.activeSense = m.autoCNC }
        if m.windMutable, let w = m.windBlock { s.windBlock = w }
        if m.spatialMutable, let sp = m.spatial { s.spatialAudio = Int(sp) }
        let anything = s.noiseLevel != nil || s.noiseControl != nil || s.activeSense != nil || s.windBlock != nil || s.spatialAudio != nil
        return m.userConfigurable || anything ? s : nil
    }

    private var freeSlot: BoseModeConfig? {
        modes.values.filter(\.isFreeSlot).min { $0.index < $1.index }
    }

    private var nameOptionIDs: [UInt8] {
        let ids = supportedNames.filter { $0 != 0 && BMAP.promptNames[$0] != nil }
        return ids.isEmpty ? BMAP.promptNames.keys.filter { $0 != 0 }.sorted() : ids
    }

    /// What a new mode starts with: the fields the device supports, values like the Bose app (UR4.F).
    private func newModeTemplate(_ slot: BoseModeConfig) -> ListeningModeSettings {
        let used = Set(modes.values.filter { !$0.isFreeSlot }.map(\.prompt.1))
        let name = nameOptionIDs.first { !used.contains($0) } ?? nameOptionIDs.first ?? 1
        var t = ListeningModeSettings(nameID: Int(name))
        let c = modeCaps
        if c?.cncSupported ?? slot.cncMutable { t.noiseLevel = strength(Self.newModeCNC, steps: cncSteps) }
        if c?.ancSupported ?? slot.ancMutable, let a = slot.ancToggle { t.noiseControl = a }
        if c?.autoCNCSupported ?? slot.autoCNCMutable { t.activeSense = slot.autoCNC }
        if c?.windSupported ?? slot.windMutable, let w = slot.windBlock { t.windBlock = w }
        if c?.spatialSupported ?? slot.spatialMutable, let sp = slot.spatial { t.spatialAudio = Int(sp) }
        return t
    }

    private func favoriteSet() -> Set<Int> {
        Set(favorites ?? modes.values.filter(\.favorite).map(\.index))
    }

    private func rebuildModes() {
        guard !modes.isEmpty else { return }
        let favs = favoriteSet()
        let list = modes.values.filter(\.isUsable).sorted { $0.index < $1.index }.map { m in
            ListeningMode(id: m.index, name: m.displayName, kind: m.kind, isUserMode: m.userConfigurable,
                          isFavorite: favs.contains(m.index), settings: settings(for: m))
        }
        let current = currentMode ?? list.first?.id ?? 0
        var s = ListeningModesState(modes: list, currentID: current, noiseLevelRange: 0 ... max(1, cncSteps - 1))
        s.nameOptions = nameOptionIDs.map { ChoiceOption(id: Int($0), title: promptName($0)) }
        s.freeSlots = modes.values.filter(\.isFreeSlot).count
        s.newModeTemplate = freeSlot.map(newModeTemplate)
        s.favoritesSupported = modeCaps?.favoritesSupported ?? false
        s.minimumFavorites = modeCaps?.minimumFavorites ?? 0
        if let m = modes[current], let ms = settings(for: m) {
            s.noiseLevel = ms.noiseLevel
            if let sp = ms.spatialAudio { s.spatialAudio = Self.spatialChoice(UInt8(sp)) }
        }
        if let sc = settingsConfig {
            if modeCaps?.cncSupported ?? true {
                s.liveNoise = LiveNoiseControl(isOn: sc.ancToggle, level: strength(sc.cncLevel, steps: Self.liveSteps),
                                               range: 0 ... Self.liveSteps - 1)
            }
            // Spatial audio outside of modes (capability 31310) when the current mode doesn't have its own.
            if s.spatialAudio == nil, modeCaps?.spatialSupported ?? false, sc.spatial <= 2 {
                s.spatialAudio = Self.spatialChoice(sc.spatial)
            }
        }
        if s.spatialAudio == nil, let sp = amSpatial { s.spatialAudio = Self.spatialChoice(sp) }
        state.listeningModes = s
    }

    /// Fields a mode lets you change: its mutable flags, or for a new mode what the device supports.
    private struct Changeable { var cnc, auto, spatial, wind, anc: Bool }

    private func changeable(_ m: BoseModeConfig, creating: Bool) -> Changeable {
        guard creating, let c = modeCaps else {
            return Changeable(cnc: m.cncMutable, auto: m.autoCNCMutable, spatial: m.spatialMutable, wind: m.windMutable, anc: m.ancMutable)
        }
        return Changeable(cnc: c.cncSupported, auto: c.autoCNCSupported, spatial: c.spatialSupported, wind: c.windSupported, anc: c.ancSupported)
    }

    /// Applies `s` to `m`, changing only what the device allows. Fields the device didn't report stay unreported.
    private func apply(_ s: ListeningModeSettings, to m: BoseModeConfig, creating: Bool = false) -> BoseModeConfig {
        var m = m
        let allowed = changeable(m, creating: creating)
        if m.userConfigurable {
            let id = UInt8(clamping: s.nameID)
            m.prompt = (0, id)
            let custom = s.customName?.trimmingCharacters(in: .whitespacesAndNewlines)
            m.name = custom.flatMap { $0.isEmpty ? nil : $0 } ?? promptName(id)
        }
        if allowed.cnc, let v = s.noiseLevel { m.cncLevel = cnc(v, steps: cncSteps) }
        if allowed.auto, let v = s.activeSense { m.autoCNC = v }
        if allowed.spatial, let v = s.spatialAudio, m.spatial != nil, (0 ... 2).contains(v) { m.spatial = UInt8(v) }
        if allowed.wind, let v = s.windBlock, m.windBlock != nil { m.windBlock = v }
        if allowed.anc, let v = s.noiseControl, m.ancToggle != nil { m.ancToggle = v }
        return m
    }

    /// Writes a mode and keeps what the device answers (or re-reads it if refused).
    private func writeMode(_ m: BoseModeConfig) async -> Bool {
        modes[m.index] = m
        rebuildModes()
        let reply = await link.request(BMAP.setModeConfig(m), timeout: .seconds(3))
        if reply?.op == .status { return true }
        if let reply, reply.op == .error, let code = reply.payload.last { log?("mode refused: \(BMAP.errorName(code))") }
        await get(BMAPBlock.audioModes, BMAP.AudioModes.modeConfig, [UInt8(clamping: m.index)])
        return false
    }

    private func writeFavorites(_ set: Set<Int>) async {
        guard let caps = modeCaps, caps.favoritesSupported else { return }
        favorites = set.sorted()
        rebuildModes()
        await setGet(BMAP.setFavorites(set.sorted(), numberOfModes: caps.numberOfModes))
    }

    static func spatialChoice(_ selected: UInt8) -> ChoiceSetting {
        ChoiceSetting(id: "spatial", title: "Immersive audio",
                      options: [ChoiceOption(id: 0, title: "Off"), ChoiceOption(id: 1, title: "Still"), ChoiceOption(id: 2, title: "Motion")],
                      selectedID: Int(selected))
    }

    private func rebuildEq() {
        guard !ranges.isEmpty else { state.equalizer = nil; return }
        let sorted = ranges.sorted { BoseNames.bandOrder($0.band) < BoseNames.bandOrder($1.band) }
        let lo = sorted.map(\.min).min() ?? -10
        let hi = sorted.map(\.max).max() ?? 10
        state.equalizer = EqualizerState(
            presets: [EqPreset(id: 0, name: "Custom", isCustomizable: true)], activePresetID: 0,
            bands: sorted.map { EqBand(id: Int($0.band), label: BoseNames.band($0.band), value: $0.value, isClearBass: false) },
            bandRange: lo ... max(hi, lo + 1))
    }

    private func rebuildButtons() {
        state.buttons = buttons.sorted { $0.key < $1.key }.compactMap { key, b in
            var options = b.supported
            if !options.contains(b.mode) { options.insert(b.mode, at: 0) }
            guard options.count > 1 else { return nil }
            return ButtonAssignment(id: key, title: BoseNames.button(b.button, event: b.event),
                                    options: options.map { ButtonFunction(id: Int($0), title: BoseNames.buttonMode($0)) },
                                    selectedID: Int(b.mode))
        }
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
        case .setNoiseLevel: "noise"
        case .setLiveNoise: "live-noise"
        case .setEqBands: "eq"
        case .setVolume: "volume"
        default: nil
        }
    }

    private func execute(_ action: HeadphoneAction) async {
        switch action {
        case .selectListeningMode(let id):
            guard modes[id] != nil else { return }
            currentMode = id
            rebuildModes()
            let reply = await link.request(BMAP.selectMode(id), until: [.status, .result, .error], timeout: .seconds(3))
            if reply?.op != .status && reply?.op != .result {
                await get(BMAPBlock.audioModes, BMAP.AudioModes.currentMode)
            }

        case let .setNoiseLevel(level, isFinal):
            guard let i = currentMode, var m = modes[i], m.cncMutable else { return }
            m.cncLevel = cnc(level, steps: cncSteps)
            modes[i] = m
            rebuildModes()
            // Writing the mode config while dragging would be a lot of traffic for little gain.
            if isFinal { _ = await writeMode(m) }

        case let .setChoice(id, optionID) where id == "spatial":
            let value = UInt8(clamping: optionID)
            if let i = currentMode, var m = modes[i], m.spatialMutable, m.spatial != nil {
                m.spatial = value
                _ = await writeMode(m)
            } else if var sc = settingsConfig, modeCaps?.spatialSupported ?? false {
                sc.spatial = value
                settingsConfig = sc
                rebuildModes()
                await setGet(BMAP.setSettingsConfig(sc))
            } else if amSpatial != nil {
                amSpatial = value
                rebuildModes()
                await setGet(BMAP.setSpatialAudio(value))
            }

        case let .setChoice(id, optionID) where id == "sidetone":
            if let i = state.choices.firstIndex(where: { $0.id == id }) { state.choices[i].selectedID = optionID }
            await setGet(BMAP.setSidetone(UInt8(clamping: optionID)))

        case .setChoice:
            return

        case .createListeningMode(let s):
            guard let slot = freeSlot else { return }
            var m = slot
            m.cncLevel = Self.newModeCNC
            m = apply(s, to: m, creating: true)
            guard await writeMode(m) else { return }
            // Like the Bose app, a new mode joins the mode button cycle (FS4.a → ModeDetails favorites the mode).
            if modeCaps?.favoritesSupported ?? false {
                await writeFavorites(favoriteSet().union([m.index]))
            }
            await execute(.selectListeningMode(id: m.index))

        case let .updateListeningMode(id, s):
            guard let m = modes[id], m.isUsable else { return }
            _ = await writeMode(apply(s, to: m))

        case .deleteListeningMode(let id):
            // YQ4.c2: AudioModes.Reset, falling back to writing an empty mode; then favorites; then switch away.
            guard let m = modes[id], m.userConfigurable, !m.isFreeSlot else { return }
            let reply = await link.request(BMAP.resetMode(id), until: [.result, .error], timeout: .seconds(3))
            if reply?.op != .result {
                var empty = m
                empty.prompt = (0, 0)
                empty.name = ""
                empty.cncLevel = Self.newModeCNC
                _ = await writeMode(empty)
            }
            // Read the slot back; what the headphones say decides whether the mode is gone.
            await get(BMAPBlock.audioModes, BMAP.AudioModes.modeConfig, [UInt8(clamping: id)])
            guard modes[id]?.isFreeSlot ?? true else { log?("mode \(id) was not deleted"); return }
            var favs = favoriteSet()
            if favs.remove(id) != nil { await writeFavorites(favs) }
            if currentMode == id {
                let next = (modeCaps?.favoritesSupported ?? false) ? (favs.sorted().first ?? 0) : 0
                await execute(.selectListeningMode(id: next))
            }
            rebuildModes()

        case let .setListeningModeFavorite(id, isFavorite):
            guard modeCaps?.favoritesSupported ?? false, modes[id]?.isUsable == true else { return }
            var favs = favoriteSet()
            if isFavorite { favs.insert(id) } else {
                guard favs.count > max(modeCaps?.minimumFavorites ?? 0, 1) else { return }
                favs.remove(id)
            }
            await writeFavorites(favs)

        case let .setLiveNoise(isOn, level, isFinal):
            guard var sc = settingsConfig else { return }
            let toggled = sc.ancToggle != isOn
            sc.ancToggle = isOn
            sc.cncLevel = cnc(level, steps: Self.liveSteps)
            settingsConfig = sc
            rebuildModes()
            if isFinal || toggled { await setGet(BMAP.setSettingsConfig(sc)) }

        case .setEqBands(let values):
            let sorted = ranges.sorted { BoseNames.bandOrder($0.band) < BoseNames.bandOrder($1.band) }
            for (i, r) in sorted.enumerated() where i < values.count {
                let v = min(max(values[i], r.min), r.max)
                guard v != r.value, let idx = ranges.firstIndex(where: { $0.band == r.band }) else { continue }
                ranges[idx].value = v
                rebuildEq()
                await setGet(BMAP.setRange(band: r.band, value: v))
            }

        case .selectEqPreset:
            return   // Only the custom EQ on these models.

        case .setAutoPowerOff(let option):
            let minutes: Int
            switch option {
            case .minutes(let m): minutes = m
            case .disabled: minutes = 0
            default: return
            }
            state.autoPowerOff?.current = option
            await setGet(BMAP.setStandbyTimer(minutes: minutes))

        case let .setToggle(id, isOn):
            setToggle(id, "", nil, isOn)
            switch id {
            case "voice-prompts":
                await setGet(BMAP.setVoicePrompts(enabled: isOn, language: voicePromptLanguage))
            case "multipoint":
                await setGet(BMAP.setMultipoint(isOn))
            case "wear-detect", "wear-pause", "wear-answer":
                guard var o = onHead else { return }
                if id == "wear-detect" { o.enabled = isOn }
                if id == "wear-pause" { o.autoPlay = isOn }
                if id == "wear-answer" { o.autoAnswer = isOn }
                onHead = o
                await setGet(BMAP.setOnHead(o))
            default:
                return
            }

        case let .setButton(key, functionID):
            guard var b = buttons[key] else { return }
            b.mode = UInt8(clamping: functionID)
            buttons[key] = b
            rebuildButtons()
            await setGet(BMAP.setButton(button: b.button, event: b.event, mode: b.mode))

        case .playback(let command):
            let value: UInt8 = switch command {
            case .play: 1
            case .pause: 2
            case .next: 3
            case .previous: 4
            }
            if command == .play { state.playback?.isPlaying = true }
            if command == .pause { state.playback?.isPlaying = false }
            await link.request(BMAP.control(value), until: [.result, .error])
            if command == .next || command == .previous {
                try? await Task.sleep(for: .milliseconds(400))
                await refreshNowPlaying()
            }

        case .setVolume(let v):
            state.playback?.volume = v
            await setGet(BMAP.setVolume(v))

        case .refresh:
            await get(BMAPBlock.status, BMAP.Status.battery)
            await get(BMAPBlock.status, BMAP.Status.chargerDetect)
            if !modes.isEmpty { await get(BMAPBlock.audioModes, BMAP.AudioModes.currentMode) }

        case .setNoise, .setSpeakToChat, .setSpeakToChatDetails, .setUpscaling, .setConnectionPriority,
             .startOptimizer, .cancelOptimizer:
            return   // Sony features.
        }
    }
}

// MARK: - Names

enum BoseModels {
    /// BoseProductId (Bose app 13.4.2), headphones only.
    static func name(for productID: Int) -> String? {
        switch productID {
        case 0x400C: "Bose QuietComfort 35"
        case 0x4020: "Bose QuietComfort 35 II"
        case 0x4024: "Bose Noise Cancelling Headphones 700"
        case 0x4039: "Bose QuietComfort 45"
        case 0x4066: "Bose QuietComfort Ultra Headphones"
        case 0x4075: "Bose QuietComfort Headphones"
        case 0x4082: "Bose QuietComfort Ultra Headphones (2nd Gen)"
        case 0x4083: "Bose QuietComfort Headphones (2nd Gen)"
        case 0x4072: "Bose QuietComfort Ultra Earbuds"
        case 0x4062: "Bose QuietComfort Ultra Earbuds (2nd Gen)"
        default: nil
        }
    }
}

enum BoseNames {
    /// RangeControlIdentifier: 0 bass, 1 mid, 2 treble, 3 low-mid, 4 high-mid.
    static func band(_ id: UInt8) -> String {
        switch id {
        case 0: "Bass"
        case 1: "Mid"
        case 2: "Treble"
        case 3: "Low Mid"
        case 4: "High Mid"
        default: "Band \(id)"
        }
    }

    /// Low to high frequency.
    static func bandOrder(_ id: UInt8) -> Int {
        switch id {
        case 0: 0
        case 3: 1
        case 1: 2
        case 4: 3
        case 2: 4
        default: Int(id) + 10
        }
    }

    /// SidetoneMode
    static func sidetone(_ m: UInt8) -> String {
        switch m {
        case 0: "Off"
        case 1: "High"
        case 2: "Medium"
        case 3: "Low"
        default: "Option \(m)"
        }
    }

    /// ConfigurableButtonId + event type.
    static func button(_ id: UInt8, event: UInt8) -> String {
        let name: String = switch id {
        case 0: "Noise control button"
        case 2: "Voice assistant button"
        case 3: "Right shortcut"
        case 4: "Left shortcut"
        case 128: "Shortcut"
        default: "Button \(id)"
        }
        let gesture: String? = switch event {
        case 3, 4: "press"
        case 5: "press and hold"
        case 6: "double press"
        case 7: "double press and hold"
        case 8: "triple press"
        case 9: "long press"
        case 10, 11, 12: "very long press"
        default: nil
        }
        return gesture.map { "\(name) (\($0))" } ?? name
    }

    /// ActionButtonMode
    static func buttonMode(_ m: UInt8) -> String {
        switch m {
        case 0: "Not set"
        case 1: "Voice assistant"
        case 2: "Noise control"
        case 3: "Battery level"
        case 4: "Play / pause"
        case 5: "More noise cancelling"
        case 6: "Less noise cancelling"
        case 7: "Wake word on/off"
        case 8: "Switch device"
        case 9: "Conversation mode"
        case 10: "Next track"
        case 11: "Previous track"
        case 12: "Read notifications"
        case 13: "Wind mode"
        case 14: "Off"
        case 15: "App action"
        case 16: "Spotify Tap"
        case 17: "Cycle modes"
        case 18: "Cycle volume presets"
        case 19: "Immersive audio"
        case 20: "Line in"
        case 21: "Linking"
        case 25: "Third-party service"
        case 26: "Smart action"
        case 27: "Alexa"
        default: "Function \(m)"
        }
    }
}

// MARK: - Factory

@MainActor
public struct BoseDriverFactory: HeadphoneDriverFactory {
    /// Serial Port Profile; the Bose app opens BMAP on it (SppConnectionManager).
    public static let sppService = UUID(uuidString: "00001101-0000-1000-8000-00805F9B34FB")!
    /// Bose's Bluetooth SIG company ID.
    static let boseVendorID: UInt16 = 0x009E
    /// Bose's 16-bit service UUIDs (0xFEBE, 0xFDD2), the "Bragi" UUID prefix (BluetoothService.isBoseDevice),
    /// and the Bose RFCOMM service every BMAP headset carries in SDP.
    static let boseServices: [UUID] = [
        UUID(uuidString: "0000FEBE-0000-1000-8000-00805F9B34FB")!,
        UUID(uuidString: "0000FDD2-0000-1000-8000-00805F9B34FB")!,
        UUID(uuidString: "00000000-DECA-FADE-DECA-DEAFDECACAFF")!,
    ]
    static let bragiPrefix = "F4C93A79-D04F-4565"

    public init() {}
    public var vendor: String { "Bose" }
    public var serviceUUIDs: [UUID] { [Self.sppService] }

    public func mightSupport(deviceName: String) -> Bool {
        let n = deviceName.uppercased()
        return ["BOSE", "QUIETCOMFORT", "QC ULTRA", "QC45", "QC35", "NC 700"].contains { n.contains($0) }
    }

    public func mightSupport(device: DeviceDescriptor) -> Bool { looksLikeBose(device) }

    /// SPP is common, so only claim it for devices that look like Bose.
    public func looksLikeBose(_ device: DeviceDescriptor) -> Bool {
        device.vendorID == Self.boseVendorID
            || device.advertisedServices.contains { Self.boseServices.contains($0) || $0.uuidString.hasPrefix(Self.bragiPrefix) }
            || mightSupport(deviceName: device.name)
    }

    public func preferredService(for device: DeviceDescriptor) -> (uuid: UUID, channel: UInt8)? {
        guard looksLikeBose(device), let ch = device.rfcommServices[Self.sppService] else { return nil }
        return (Self.sppService, ch)
    }

    public func makeDriver(device: DeviceDescriptor, serviceUUID: UUID, transport: ByteTransport) -> HeadphoneDriver {
        BoseDriver(transport: transport)
    }
}
