import SwiftUI
import HeadphoneKit

// Listening mode management (Bose): list, editor, noise control outside of modes.

enum NoiseLevelText {
    /// Same wording and thresholds as the Bose app (C4559Np1.O).
    static func describe(_ level: Int, isOn: Bool = true) -> String {
        guard isOn else { return "Noise control is off: no noise cancelling and no wind block." }
        switch level {
        case 8...: return "Blocks most outside sounds."
        case 4 ..< 8: return "Lets in some outside sounds."
        default: return "Lets in the most outside sounds."
        }
    }
}

enum ImmersiveText {
    static func describe(_ id: Int) -> String {
        switch id {
        case 1: "Still: audio stays in place. Best when you're sitting down."
        case 2: "Motion: audio follows you. Best when you're moving around."
        default: "Off: classic stereo."
        }
    }
}

/// Slider with the ear/headphones end markers and the value, used for noise cancelling strength.
struct NoiseLevelSlider: View {
    let value: Int
    let range: ClosedRange<Int>
    var enabled = true
    let onChange: (Int, _ isFinal: Bool) -> Void
    @ViewState private var drag: Double?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "ear").foregroundStyle(.secondary).imageScale(.small).help("Lets in more of your surroundings")
            Slider(value: Binding(get: { drag ?? Double(value) }, set: { v in
                drag = v
                onChange(Int(v.rounded()), false)
            }), in: Double(range.lowerBound) ... Double(range.upperBound), step: 1) { editing in
                if !editing, let v = drag {
                    onChange(Int(v.rounded()), true)
                    drag = nil
                }
            }
            .disabled(!enabled)
            Image(systemName: "headphones.circle.fill").foregroundStyle(.secondary).imageScale(.small).help("More noise cancelling")
            Text("\(Int((drag ?? Double(value)).rounded()))")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
                .frame(width: 22, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Noise cancelling")
        .accessibilityValue("\(value) of \(range.upperBound)")
    }
}

// MARK: - Noise control outside of modes

struct LiveNoiseSection: View {
    @Environment(AppModel.self) private var model
    let live: LiveNoiseControl
    @ViewState private var dragLevel: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(get: { live.isOn }, set: { model.perform(.setLiveNoise(isOn: $0, level: live.level, isFinal: true)) })) {
                Label("Noise Control", systemImage: "waveform.badge.minus")
            }
            .toggleStyle(.switch)
            NoiseLevelSlider(value: live.level, range: live.range, enabled: live.isOn) { v, final in
                dragLevel = final ? nil : v
                model.perform(.setLiveNoise(isOn: live.isOn, level: v, isFinal: final))
            }
            Text(NoiseLevelText.describe(dragLevel ?? live.level, isOn: live.isOn))
                .font(.caption).foregroundStyle(.secondary)
                .contentTransition(.opacity)
        }
    }
}

// MARK: - Mode list (main window)

struct ModesListSection: View {
    @Environment(AppModel.self) private var model
    let modes: ListeningModesState
    @Binding var editing: ModeEditorTarget?
    @ViewState private var confirmDelete: ListeningMode?

    var body: some View {
        Section {
            ForEach(modes.modes) { mode in
                row(mode)
            }
            HStack {
                Button {
                    if let t = modes.newModeTemplate { editing = .new(t) }
                } label: {
                    Label("New Mode…", systemImage: "plus")
                }
                .disabled(modes.newModeTemplate == nil)
                Spacer()
                Text(modes.freeSlots == 1 ? "1 free slot" : "\(modes.freeSlots) free slots")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Modes")
        } footer: {
            if modes.favoritesSupported {
                Text("Starred modes are the ones the mode button on the headphones cycles through. At least \(max(modes.minimumFavorites, 1)) must stay starred.")
                    .foregroundStyle(.secondary)
            }
        }
        .confirmationDialog("Delete \"\(confirmDelete?.name ?? "")\"?", isPresented: Binding(
            get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }), titleVisibility: .visible) {
            Button("Delete Mode", role: .destructive) {
                if let m = confirmDelete { model.perform(.deleteListeningMode(id: m.id)) }
                confirmDelete = nil
            }
        } message: {
            Text("The mode is removed from the headphones.")
        }
    }

    private func row(_ mode: ListeningMode) -> some View {
        let isCurrent = mode.id == modes.currentID
        let canUnstar = modes.favoriteCount > max(modes.minimumFavorites, 1)
        return HStack(spacing: 10) {
            Image(systemName: mode.kind.symbol)
                .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(mode.name).fontWeight(isCurrent ? .semibold : .regular)
                Text(subtitle(mode)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if isCurrent {
                Text("Active").font(.caption.weight(.medium)).foregroundStyle(Color.accentColor)
            } else {
                Button("Use") { model.perform(.selectListeningMode(id: mode.id)) }
                    .controlSize(.small)
            }
            if mode.settings != nil {
                Button { editing = .existing(mode) } label: { Image(systemName: "slider.horizontal.3") }
                    .buttonStyle(.borderless)
                    .help("Edit \(mode.name)")
            }
            if modes.favoritesSupported {
                Button {
                    model.perform(.setListeningModeFavorite(id: mode.id, isFavorite: !mode.isFavorite))
                } label: {
                    Image(systemName: mode.isFavorite ? "star.fill" : "star")
                        .foregroundStyle(mode.isFavorite ? Color.yellow : .secondary)
                }
                .buttonStyle(.borderless)
                .disabled(mode.isFavorite && !canUnstar)
                .help(mode.isFavorite ? "Remove from the mode button cycle" : "Add to the mode button cycle")
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            if !isCurrent { Button("Use") { model.perform(.selectListeningMode(id: mode.id)) } }
            if mode.settings != nil { Button("Edit…") { editing = .existing(mode) } }
            if mode.isUserMode {
                Divider()
                Button("Delete…", role: .destructive) { confirmDelete = mode }
            }
        }
    }

    private func subtitle(_ m: ListeningMode) -> String {
        var parts: [String] = [m.isUserMode ? "Your mode" : "Bose mode"]
        if let s = m.settings {
            if s.noiseControl == false {
                parts.append("Noise control off")
            } else if let l = s.noiseLevel {
                parts.append("Noise cancelling \(l)")
            }
            if s.activeSense == true { parts.append("ActiveSense") }
            if s.windBlock == true { parts.append("Wind Block") }
            if let sp = s.spatialAudio, sp != 0 { parts.append(sp == 1 ? "Immersive: Still" : "Immersive: Motion") }
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Editor

enum ModeEditorTarget: Identifiable {
    case new(ListeningModeSettings)
    case existing(ListeningMode)
    var id: String {
        switch self {
        case .new: "new"
        case .existing(let m): "mode-\(m.id)"
        }
    }
}

struct ModeEditorSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let target: ModeEditorTarget
    let nameOptions: [ChoiceOption]
    let levelRange: ClosedRange<Int>
    @ViewState private var draft: ListeningModeSettings
    @ViewState private var customName: String
    @ViewState private var confirmDelete = false

    init(target: ModeEditorTarget, nameOptions: [ChoiceOption], levelRange: ClosedRange<Int>) {
        self.target = target
        self.nameOptions = nameOptions
        self.levelRange = levelRange
        let s: ListeningModeSettings = switch target {
        case .new(let t): t
        case .existing(let m): m.settings ?? ListeningModeSettings(nameID: 0)
        }
        _draft = ViewState(initialValue: s)
        _customName = ViewState(initialValue: s.customName ?? "")
    }

    private var isNew: Bool { if case .new = target { true } else { false } }
    private var mode: ListeningMode? { if case .existing(let m) = target { m } else { nil } }
    private var canRename: Bool { isNew || mode?.isUserMode == true }
    private var promptTitle: String { nameOptions.first { $0.id == draft.nameID }?.title ?? "Mode" }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if canRename {
                    Section {
                        Picker("Announced name", selection: $draft.nameID) {
                            ForEach(nameOptions) { Text($0.title).tag($0.id) }
                            if !nameOptions.contains(where: { $0.id == draft.nameID }) {
                                Text(promptTitle).tag(draft.nameID)
                            }
                        }
                        TextField("Name", text: $customName, prompt: Text(promptTitle))
                    } header: {
                        Text("Name")
                    } footer: {
                        Text("The headphones say the announced name when you switch to the mode. The name is optional and is stored on the headphones; leave it empty to use the announced name.")
                            .foregroundStyle(.secondary)
                    }
                } else if let mode {
                    Section { LabeledContent("Mode", value: mode.name) } footer: {
                        Text("Bose's own modes can't be renamed. Only the settings below can be changed.").foregroundStyle(.secondary)
                    }
                }

                if draft.noiseLevel != nil || draft.noiseControl != nil || draft.activeSense != nil || draft.windBlock != nil {
                    Section("Noise Cancelling") {
                        if let on = draft.noiseControl {
                            Toggle("Noise Control", isOn: Binding(get: { on }, set: { draft.noiseControl = $0 }))
                        }
                        if let level = draft.noiseLevel {
                            VStack(alignment: .leading, spacing: 6) {
                                NoiseLevelSlider(value: level, range: levelRange, enabled: draft.noiseControl != false) { v, _ in
                                    draft.noiseLevel = v
                                }
                                Text(NoiseLevelText.describe(level, isOn: draft.noiseControl != false))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if let auto = draft.activeSense {
                            Toggle(isOn: Binding(get: { auto }, set: { draft.activeSense = $0 })) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("ActiveSense")
                                    Text("If it gets too loud, noise cancelling adjusts automatically.").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        if let wind = draft.windBlock {
                            Toggle(isOn: Binding(get: { wind }, set: { draft.windBlock = $0 })) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Wind Block")
                                    Text(draft.noiseControl == false ? "Needs Noise Control." : "Reduces wind noise in windy places.")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .disabled(draft.noiseControl == false)
                        }
                    }
                }

                if let sp = draft.spatialAudio {
                    Section {
                        Picker("Immersive Audio", selection: Binding(get: { sp }, set: { draft.spatialAudio = $0 })) {
                            Text("Off").tag(0)
                            Text("Still").tag(1)
                            Text("Motion").tag(2)
                        }
                        .pickerStyle(.segmented)
                    } header: {
                        Text("Immersive Audio")
                    } footer: {
                        Text(ImmersiveText.describe(sp)).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                if let mode, mode.isUserMode {
                    Button("Delete Mode…", role: .destructive) { confirmDelete = true }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Create" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                    .disabled(!hasChanges)
            }
            .padding(16)
        }
        .frame(width: 460, height: 560)
        .navigationTitle(isNew ? "New Mode" : "Edit \(mode?.name ?? "Mode")")
        .confirmationDialog("Delete \"\(mode?.name ?? "")\"?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Mode", role: .destructive) {
                if let mode { model.perform(.deleteListeningMode(id: mode.id)) }
                dismiss()
            }
        } message: {
            Text("The mode is removed from the headphones.")
        }
    }

    private var finalDraft: ListeningModeSettings {
        var d = draft
        let name = customName.trimmingCharacters(in: .whitespacesAndNewlines)
        d.customName = name.isEmpty || name == promptTitle ? nil : name
        return d
    }

    private var hasChanges: Bool {
        switch target {
        case .new: true
        case .existing(let m): finalDraft != m.settings
        }
    }

    private func save() {
        switch target {
        case .new: model.perform(.createListeningMode(finalDraft))
        case .existing(let m): model.perform(.updateListeningMode(id: m.id, finalDraft))
        }
        dismiss()
    }
}

// MARK: - EQ presets

struct EqPresetsSection: View {
    @Environment(AppModel.self) private var model
    let eq: EqualizerState
    @ViewState private var saving = false
    @ViewState private var newName = ""

    var body: some View {
        let values = eq.bands.map(\.value)
        let builtIn = model.builtInEqPresets(for: eq)
        let saved = model.savedEqPresets(for: eq)
        Section {
            if !builtIn.isEmpty {
                presetFlow(builtIn.map { ($0.name, $0.values, nil as UUID?) }, current: values)
            }
            if !saved.isEmpty {
                presetFlow(saved.map { ($0.name, $0.values, $0.id as UUID?) }, current: values)
            }
            HStack {
                Button("Save Current as Preset…") { newName = ""; saving = true }
                Spacer()
                Button("Reset to Flat") { model.perform(.setEqBands(Array(repeating: 0, count: eq.bands.count))) }
                    .disabled(values.allSatisfy { $0 == 0 })
            }
        } header: {
            Text("Presets")
        } footer: {
            Text(builtIn.isEmpty ? "Your presets are kept in this app." :
                    "The first presets are the Bose app's. Your presets are kept in this app; right-click one to delete it.")
                .foregroundStyle(.secondary)
        }
        .alert("Save Preset", isPresented: $saving) {
            TextField("Name", text: $newName)
            Button("Save") {
                let n = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !n.isEmpty { model.saveEqPreset(name: n, eq: eq) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves the current bands (\(values.map { $0 > 0 ? "+\($0)" : "\($0)" }.joined(separator: " / "))).")
        }
    }

    private func presetFlow(_ presets: [(String, [Int], UUID?)], current: [Int]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(presets.enumerated()), id: \.offset) { _, p in
                    let active = p.1 == current
                    Button(p.0) { model.perform(.setEqBands(p.1)) }
                        .buttonStyle(.glass)
                        .tint(active ? .accentColor : nil)
                        .fontWeight(active ? .semibold : .regular)
                        .accessibilityAddTraits(active ? .isSelected : [])
                        .contextMenu {
                            if let id = p.2 {
                                Button("Delete \"\(p.0)\"", role: .destructive) { model.deleteEqPreset(id: id, eq: eq) }
                            }
                        }
                }
            }
            .padding(.vertical, 2)
        }
    }
}

/// Preset menu for the popover's equalizer card when the device has no presets of its own.
struct AppEqPresetMenu: View {
    @Environment(AppModel.self) private var model
    let eq: EqualizerState

    var body: some View {
        let values = eq.bands.map(\.value)
        Menu {
            Button("Flat") { model.perform(.setEqBands(Array(repeating: 0, count: eq.bands.count))) }
            ForEach(model.builtInEqPresets(for: eq), id: \.name) { p in
                Button { model.perform(.setEqBands(p.values)) } label: {
                    if p.values == values { Label(p.name, systemImage: "checkmark") } else { Text(p.name) }
                }
            }
            let saved = model.savedEqPresets(for: eq)
            if !saved.isEmpty {
                Divider()
                ForEach(saved) { p in
                    Button { model.perform(.setEqBands(p.values)) } label: {
                        if p.values == values { Label(p.name, systemImage: "checkmark") } else { Text(p.name) }
                    }
                }
            }
        } label: {
            Text(model.eqPresetName(for: eq) ?? "Custom")
        }
        .menuStyle(.button)
        .buttonStyle(.glass)
        .fixedSize()
    }
}
