import SwiftUI
import HeadphoneKit

enum Pane: String, CaseIterable, Identifiable {
    case sound, equalizer, conversation, device, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .sound: "Sound"
        case .equalizer: "Equalizer"
        case .conversation: "Speak-to-Chat"
        case .device: "Device"
        case .about: "App"
        }
    }
    var symbol: String {
        switch self {
        case .sound: "waveform.badge.minus"
        case .equalizer: "slider.vertical.3"
        case .conversation: "bubble.left.and.text.bubble.right"
        case .device: "gearshape"
        case .about: "app.badge"
        }
    }
}

struct MainWindow: View {
    @Environment(AppModel.self) private var model
    @ViewState private var pane: Pane? = .sound

    var body: some View {
        NavigationSplitView {
            List(selection: $pane) {
                Section {
                    ForEach(availablePanes) { p in
                        Label(p.title, systemImage: p.symbol).tag(p)
                    }
                } header: {
                    deviceHeader
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
        } detail: {
            Group {
                if model.connection == .connected, let state = model.state {
                    detail(for: pane ?? .sound, state: state)
                } else if pane == .equalizer {
                    EqualizerPane(state: nil)
                } else {
                    VStack(spacing: 16) {
                        Image(systemName: "headphones").font(.system(size: 48, weight: .light)).foregroundStyle(.tertiary)
                        Text("No headphones connected").font(.title3.weight(.semibold))
                        DeviceListView().frame(maxWidth: 380)
                    }
                    .padding(40)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle(model.connection == .connected ? model.displayName : "XMNative")
            .navigationSubtitle(windowSubtitle)
            .toolbar {
                if model.connection == .connected {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            model.perform(.refresh)
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .help("Refresh battery and status")
                    }
                    ToolbarSpacer(.fixed)
                    ToolbarItem(placement: .primaryAction) {
                        Button("Disconnect") { model.disconnect() }
                    }
                }
            }
        }
    }

    private var windowSubtitle: String {
        guard model.connection == .connected, let s = model.state else { return "" }
        var parts: [String] = []
        if let c = s.codec, c != .unknown { parts.append(c.rawValue) }
        if let p = model.batterySummary { parts.append("\(p)% battery") }
        return parts.joined(separator: " · ")
    }

    private var availablePanes: [Pane] {
        guard let s = model.state else { return [.sound, .equalizer, .about] }
        return Pane.allCases.filter { p in
            switch p {
            case .sound: s.noiseControl != nil || s.listeningModes != nil
            case .equalizer: true   // the Mac equalizer works with any headphones
            case .conversation: s.speakToChat != nil
            case .device: s.autoPowerOff != nil || s.upscaling != nil || s.connectionPriority != nil || !s.toggles.isEmpty || !s.buttons.isEmpty || !s.choices.isEmpty
            case .about: true
            }
        }
    }

    private var deviceHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.connection == .connected ? model.displayName : "Not connected")
                .font(.headline).foregroundStyle(.primary)
            if let b = model.state?.battery { BatteryRow(battery: b) }
        }
        .textCase(nil)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private func detail(for pane: Pane, state: HeadphoneState) -> some View {
        switch pane {
        case .sound: SoundPane(state: state)
        case .equalizer: EqualizerPane(state: state)
        case .conversation: SpeakToChatPane(state: state)
        case .device: DevicePane(state: state)
        case .about: AboutPane(state: state)
        }
    }
}

// MARK: - Panes

struct SoundPane: View {
    @Environment(AppModel.self) private var model
    let state: HeadphoneState
    @ViewState private var editing: ModeEditorTarget?

    var body: some View {
        Form {
            if let nc = state.noiseControl {
                Section {
                    NoiseControlSection(nc: nc).padding(.vertical, 6)
                } header: {
                    Text("Ambient Sound Control")
                } footer: {
                    Text(footer(nc.mode)).foregroundStyle(.secondary)
                }
                if let opt = state.optimizer {
                    Section {
                        OptimizerRow(optimizer: opt)
                    } header: {
                        Text("NC Optimizer")
                    } footer: {
                        Text("Wear the headphones and stay still. It measures fit and air pressure and tunes noise cancelling to you.")
                            .foregroundStyle(.secondary)
                    }
                }
            } else if let lm = state.listeningModes {
                Section {
                    ListeningModeSection(modes: lm).padding(.vertical, 6)
                } header: {
                    Text("Current Mode")
                } footer: {
                    Text(currentModeFooter(lm)).foregroundStyle(.secondary)
                }
                if let live = lm.liveNoise {
                    Section {
                        LiveNoiseSection(live: live).padding(.vertical, 4)
                    } header: {
                        Text("Noise Control")
                    } footer: {
                        Text("Noise control outside of modes, like the Noise Control screen in the Bose app.")
                            .foregroundStyle(.secondary)
                    }
                }
                ModesListSection(modes: lm, editing: $editing)
            } else {
                Text("This device has no noise control.")
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editing) { target in
            ModeEditorSheet(target: target, nameOptions: state.listeningModes?.nameOptions ?? [],
                            levelRange: state.listeningModes?.noiseLevelRange ?? 0 ... 10)
                .environment(model)
        }
    }

    private func currentModeFooter(_ lm: ListeningModesState) -> String {
        if lm.noiseLevel != nil { return "Noise cancelling strength of this mode. Lower lets in more of your surroundings." }
        if lm.current?.isUserMode == false {
            return "Bose's own modes have a fixed noise cancelling level. Create your own mode below to pick the level, Wind Block and Immersive Audio."
        }
        return "This mode's noise cancelling level can't be changed."
    }

    private func footer(_ m: NoiseMode) -> String {
        switch m {
        case .noiseCancelling: "Blocks out surrounding noise."
        case .windReduction: "Reduces wind noise while still cancelling some ambient sound."
        case .ambient: "Lets surrounding sound in. Focus on voice filters out background noise."
        case .off: "Noise cancelling and ambient sound are both off."
        }
    }
}

struct EqualizerPane: View {
    @Environment(AppModel.self) private var model
    let state: HeadphoneState?

    var body: some View {
        Form {
            if let eq = state?.equalizer {
                if eq.presets.count <= 1 {
                    EqPresetsSection(eq: eq)
                }
                if eq.presets.count > 1 {
                    Section("Preset") {
                        Picker("Preset", selection: Binding(get: { eq.activePresetID }, set: { model.perform(.selectEqPreset(id: $0)) })) {
                            ForEach(eq.presets) { Text($0.name).tag($0.id) }
                        }
                    }
                }
                Section {
                    EqualizerBands(eq: eq, height: 220)
                        .padding(.vertical, 10)
                    HStack {
                        Spacer()
                        Button("Reset to Flat") { model.perform(.setEqBands(Array(repeating: 0, count: eq.bands.count))) }
                    }
                } header: {
                    Text("Headphone EQ")
                } footer: {
                    if eq.presets.count > 1 {
                        Text("Changing a band switches to the Custom preset.").foregroundStyle(.secondary)
                    }
                }
            }
            MacEqualizerSections()
        }
        .formStyle(.grouped)
    }
}

struct SpeakToChatPane: View {
    @Environment(AppModel.self) private var model
    let state: HeadphoneState

    var body: some View {
        Form {
            if let stc = state.speakToChat {
                Section {
                    Toggle("Speak-to-Chat", isOn: Binding(get: { stc.enabled }, set: { model.perform(.setSpeakToChat(enabled: $0)) }))
                } footer: {
                    Text("Pauses music and lets ambient sound in when you start talking.").foregroundStyle(.secondary)
                }
                if let sens = stc.sensitivity, let to = stc.timeout {
                    let vf = stc.voiceFocus
                    Section("Details") {
                        Picker("Voice detection sensitivity", selection: Binding(get: { sens }, set: {
                            model.perform(.setSpeakToChatDetails(sensitivity: $0, voiceFocus: vf, timeout: to))
                        })) {
                            Text("Automatic").tag(SpeakToChatSensitivity.auto)
                            Text("High").tag(SpeakToChatSensitivity.high)
                            Text("Low").tag(SpeakToChatSensitivity.low)
                        }
                        if let vf {
                            Toggle("Voice passthrough", isOn: Binding(get: { vf }, set: {
                                model.perform(.setSpeakToChatDetails(sensitivity: sens, voiceFocus: $0, timeout: to))
                            }))
                        }
                        Picker("End Speak-to-Chat after", selection: Binding(get: { to }, set: {
                            model.perform(.setSpeakToChatDetails(sensitivity: sens, voiceFocus: vf, timeout: $0))
                        })) {
                            Text("Short (about 15 s)").tag(SpeakToChatTimeout.short)
                            Text("Standard (about 30 s)").tag(SpeakToChatTimeout.standard)
                            Text("Long (about 60 s)").tag(SpeakToChatTimeout.long)
                            Text("Don't end automatically").tag(SpeakToChatTimeout.none)
                        }
                    }
                    .disabled(!stc.enabled)
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct DevicePane: View {
    @Environment(AppModel.self) private var model
    let state: HeadphoneState

    var body: some View {
        Form {
            if let apo = state.autoPowerOff {
                Section("Power") {
                    Picker("Automatic power off", selection: Binding(get: { apo.current }, set: { model.perform(.setAutoPowerOff($0)) })) {
                        ForEach(apo.options, id: \.self) { Text($0.title).tag($0) }
                    }
                }
            }
            if state.upscaling != nil || state.connectionPriority != nil {
                Section("Sound Quality") {
                    if let u = state.upscaling {
                        Toggle(u.name, isOn: Binding(get: { u.enabled }, set: { model.perform(.setUpscaling(enabled: $0)) }))
                    }
                    if let c = state.connectionPriority {
                        Picker("Bluetooth connection", selection: Binding(get: { c.current }, set: { model.perform(.setConnectionPriority($0)) })) {
                            Text("Prioritise sound quality").tag(ConnectionPriority.soundQuality)
                            Text("Prioritise stable connection").tag(ConnectionPriority.connectionQuality)
                        }
                    }
                }
            }
            if !state.buttons.isEmpty {
                Section {
                    ForEach(state.buttons) { b in
                        Picker(b.title, selection: Binding(get: { b.selectedID }, set: { model.perform(.setButton(id: b.id, functionID: $0)) })) {
                            ForEach(b.options) { Text($0.title).tag($0.id) }
                        }
                    }
                } header: {
                    Text("Buttons")
                } footer: {
                    Text("Voice assistants only work when their app is set up on the connected phone.").foregroundStyle(.secondary)
                }
            }
            if !state.choices.isEmpty {
                Section("Calls") {
                    ForEach(state.choices) { c in
                        Picker(c.title, selection: Binding(get: { c.selectedID }, set: { model.perform(.setChoice(id: c.id, optionID: $0)) })) {
                            ForEach(c.options) { Text($0.title).tag($0.id) }
                        }
                    }
                }
            }
            if !state.toggles.isEmpty {
                Section("General") {
                    ForEach(state.toggles) { t in
                        Toggle(isOn: Binding(get: { t.isOn }, set: { model.perform(.setToggle(id: t.id, isOn: $0)) })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t.title)
                                if let s = t.subtitle { Text(s).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct AboutPane: View {
    @Environment(AppModel.self) private var model
    let state: HeadphoneState

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Device") {
                LabeledContent("Model", value: state.modelName ?? "—")
                LabeledContent("Firmware", value: state.firmwareVersion ?? "—")
                LabeledContent("Codec", value: state.codec?.rawValue ?? "—")
                LabeledContent("Protocol", value: state.protocolInfo ?? "—")
            }
            Section("App") {
                Toggle("Connect automatically when the headphones connect", isOn: $model.autoConnect)
                Toggle("Open at login", isOn: Binding(get: { model.launchAtLoginBinding }, set: { model.launchAtLogin = $0 }))
                Toggle("Show battery in the menu bar", isOn: $model.showBatteryInMenuBar)
                Toggle("Show protocol log", isOn: $model.showWireLog)
                if let err = model.loginItemError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
                LabeledContent("Version", value: model.appVersion)
            }
            if model.showWireLog {
                Section("Protocol log") {
                    ScrollView {
                        Text(model.wireLog.suffix(200).joined(separator: "\n"))
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 180)
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct OptimizerRow: View {
    @Environment(AppModel.self) private var model
    let optimizer: OptimizerState

    var body: some View {
        HStack(spacing: 12) {
            if optimizer.isRunning {
                ProgressView().controlSize(.small)
            } else if optimizer.phase == .finished {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            Text(status).foregroundStyle(optimizer.isRunning ? .primary : .secondary)
            Spacer()
            if optimizer.isRunning {
                Button("Cancel") { model.perform(.cancelOptimizer) }
                    .buttonStyle(.glass)
            } else {
                Button(optimizer.phase == .finished ? "Run Again" : "Optimize") { model.perform(.startOptimizer) }
                    .buttonStyle(.glassProminent)
            }
        }
        .animation(.smooth, value: optimizer.phase)
    }

    private var status: String {
        switch optimizer.phase {
        case .idle: "Not run yet"
        case .measuringFit: "Measuring fit…"
        case .measuringPressure: "Measuring air pressure…"
        case .optimizing: "Optimizing…"
        case .finished: "Optimized"
        }
    }
}
