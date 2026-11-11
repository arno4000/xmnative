import SwiftUI
import AppKit
import MacAudio

/// The Mac-wide equalizer in the Equalizer pane.
struct MacEqualizerSections: View {
    @Environment(MacEqualizer.self) private var eq
    @ViewState private var saving = false
    @ViewState private var newName = ""

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { eq.isEnabled }, set: { eq.setEnabled($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Equalize All Mac Sound")
                    Text(eq.statusText)
                        .font(.caption)
                        .foregroundStyle(statusColor)
                }
            }
            .toggleStyle(.switch)
            if eq.status == .needsPermission {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Allow XMNative under Privacy & Security › Screen & System Audio Recording › System Audio Recording Only, then try again.")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Open Privacy Settings") { NSWorkspace.shared.open(AudioCapturePermission.settingsURL) }
                        Button("Try Again") { eq.retry() }
                    }
                }
            } else if case .failed = eq.status {
                Button("Try Again") { eq.retry() }
            }
        } header: {
            Text("Mac Equalizer")
        } footer: {
            Text("Uses Apple's built-in graphic equalizer on everything this Mac plays, on any output, and follows you when you switch outputs. It doesn't change the headphones, so it has no effect on your phone. Turned off, the sound is untouched.")
                .foregroundStyle(.secondary)
        }

        Section {
            Picker("Bands", selection: Binding(get: { eq.layout }, set: { eq.setLayout($0) })) {
                Text("10 Bands").tag(MacEqLayout.ten)
                Text("31 Bands").tag(MacEqLayout.thirtyOne)
            }
            .pickerStyle(.segmented)

            LabeledContent("Preset") {
                MacEqPresetMenu()
            }

            MacEqBands(height: 200)
                .padding(.vertical, 8)

            LabeledContent("Preamp") {
                HStack {
                    Slider(value: Binding(get: { Double(eq.preamp) }, set: { eq.setPreamp(Int($0.rounded()), isFinal: false) }),
                           in: Double(EqCurve.preampRange.lowerBound) ... Double(EqCurve.preampRange.upperBound), step: 1) { editing in
                        if !editing { eq.setPreamp(eq.preamp, isFinal: true) }
                    }
                    .frame(maxWidth: 220)
                    Text(dB(eq.preamp)).monospacedDigit().foregroundStyle(.secondary).frame(width: 48, alignment: .trailing)
                }
            }
            Toggle(isOn: Binding(get: { eq.preventClipping }, set: { eq.setPreventClipping($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Prevent Clipping")
                    Text("Lowers the level by the largest boost so loud parts don't distort. Total: \(dB(eq.effectivePreamp)).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)

            HStack {
                Button("Save Current as Preset…") { newName = ""; saving = true }
                Spacer()
                Button("Reset to Flat") { eq.resetToFlat() }
                    .disabled(eq.isFlat)
            }
        } header: {
            Text("Mac EQ Bands")
        }
        .alert("Save Preset", isPresented: $saving) {
            TextField("Name", text: $newName)
            Button("Save") {
                let n = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !n.isEmpty && !eq.isBuiltIn(n) { eq.savePreset(named: n) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves the current \(eq.layout.bandCount) bands. Presets work in both layouts.")
        }
    }

    private var statusColor: Color {
        switch eq.status {
        case .running: .green
        case .failed, .needsPermission: .orange
        default: .secondary
        }
    }
}

func dB(_ v: Int) -> String { v > 0 ? "+\(v) dB" : "\(v) dB" }

/// Vertical sliders for the Mac EQ. 31 bands scroll sideways when there's no room.
struct MacEqBands: View {
    @Environment(MacEqualizer.self) private var eq
    var height: CGFloat = 200
    var showValues = true
    @ViewState private var dragValues: [Int]?

    var body: some View {
        let values = dragValues ?? eq.gains
        let labels = eq.layout.labels
        let wide = eq.layout == .thirtyOne
        Group {
            if wide {
                ScrollView(.horizontal) {
                    columns(values, labels, width: 26).padding(.bottom, 6)
                }
            } else {
                columns(values, labels, width: nil)
            }
        }
        .animation(.smooth(duration: 0.2), value: eq.gains)
    }

    private func columns(_ values: [Int], _ labels: [String], width: CGFloat?) -> some View {
        HStack(alignment: .bottom, spacing: 0) {
            ForEach(Array(labels.enumerated()), id: \.offset) { i, label in
                VStack(spacing: 6) {
                    if showValues {
                        Text(values[i] > 0 ? "+\(values[i])" : "\(values[i])")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    VerticalSlider(value: values[i], range: EqCurve.gainRange) { v, final in
                        var vs = dragValues ?? eq.gains
                        vs[i] = v
                        dragValues = final ? nil : vs
                        eq.setGain(v, band: i, isFinal: final)
                    }
                    .frame(height: height)
                    .accessibilityLabel("\(label) hertz")
                    Text(label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                .frame(width: width)
                .frame(maxWidth: width == nil ? .infinity : nil)
            }
        }
    }
}

struct MacEqPresetMenu: View {
    @Environment(MacEqualizer.self) private var eq

    var body: some View {
        let current = eq.presetName
        Menu {
            ForEach(eq.builtInPresets) { p in
                Button { eq.apply(p) } label: {
                    if p.name == current { Label(p.name, systemImage: "checkmark") } else { Text(p.name) }
                }
            }
            if !eq.savedPresets.isEmpty {
                Divider()
                ForEach(eq.savedPresets) { p in
                    Button { eq.apply(p) } label: {
                        if p.name == current { Label(p.name, systemImage: "checkmark") } else { Text(p.name) }
                    }
                }
                Divider()
                Menu("Delete Preset") {
                    ForEach(eq.savedPresets) { p in
                        Button(p.name, role: .destructive) { eq.deletePreset(named: p.name) }
                    }
                }
            }
        } label: {
            Text(current ?? "Custom")
        }
        .menuStyle(.button)
        .buttonStyle(.glass)
        .fixedSize()
    }
}

/// The Mac EQ in the menu bar popover.
struct MacEqualizerCard: View {
    @Environment(MacEqualizer.self) private var eq
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Card("Mac EQ", symbol: "slider.horizontal.3", trailing: AnyView(trailing)) {
            if eq.isEnabled {
                if eq.layout == .ten {
                    MacEqBands(height: 64, showValues: false)
                } else {
                    Button("31 bands · Edit in Settings") { AppActions.openMainWindow(openWindow) }
                        .buttonStyle(.link)
                        .font(.callout)
                }
                Text(eq.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private var trailing: some View {
        HStack(spacing: 8) {
            if eq.isEnabled { MacEqPresetMenu().controlSize(.small) }
            Toggle("Mac EQ", isOn: Binding(get: { eq.isEnabled }, set: { eq.setEnabled($0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}
