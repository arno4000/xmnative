import SwiftUI
import HeadphoneKit

// Design notes (macOS 26/27 "Liquid Glass"):
// * Glass is reserved for the control layer: the mode selector, slider thumbs and buttons.
//   Content groups use quiet system fills, so glass never sits on a glass background.
// * Shapes are concentric with their container (ConcentricRectangle / capsules).
// * No custom gradients or drop shadows. Selection is tinted glass that morphs between items.

// MARK: - Noise control

extension NoiseMode {
    var title: String {
        switch self {
        case .noiseCancelling: "Noise Cancelling"
        case .windReduction: "Wind Reduction"
        case .ambient: "Ambient Sound"
        case .off: "Off"
        }
    }
    var shortTitle: String {
        switch self {
        case .noiseCancelling: "Noise Canc."
        case .windReduction: "Wind"
        case .ambient: "Ambient"
        case .off: "Off"
        }
    }
    var symbol: String {
        switch self {
        case .noiseCancelling: "waveform.badge.minus"
        case .windReduction: "wind"
        case .ambient: "ear"
        case .off: "circle.slash"
        }
    }
}

/// Segmented mode selector. The selected item is a tinted glass capsule that morphs between items.
struct NoiseModePicker: View {
    let modes: [NoiseMode]
    let selection: NoiseMode
    let onSelect: (NoiseMode) -> Void
    @Namespace private var glassNS

    var body: some View {
        GlassEffectContainer(spacing: 4) {
            HStack(spacing: 4) {
                ForEach(modes, id: \.self) { mode in
                    let selected = selection == mode
                    Button { onSelect(mode) } label: {
                        VStack(spacing: 4) {
                            Image(systemName: mode.symbol)
                                .font(.system(size: 16, weight: .medium))
                                .frame(height: 20)
                            Text(mode.shortTitle)
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                        }
                        .foregroundStyle(selected ? Color.white : Color.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .contentShape(.capsule)
                        // Glass applied to the label itself, so the content renders on top of it.
                        .glassEffect(selected ? .regular.tint(.accentColor).interactive() : .identity, in: .capsule)
                        .glassEffectID(mode, in: glassNS)
                    }
                    .buttonStyle(.plain)
                    .help(mode.title)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(4)
            .background(.fill.quaternary, in: .capsule)
        }
        .animation(.bouncy(duration: 0.35), value: selection)
    }
}

/// Mode picker + ambient level + voice focus, bound to the model.
struct NoiseControlSection: View {
    @Environment(AppModel.self) private var model
    let nc: NoiseControlState
    @ViewState private var dragLevel: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            NoiseModePicker(modes: nc.supportedModes, selection: nc.mode) { mode in
                model.perform(.setNoise(mode: mode, ambientLevel: nc.ambientLevel, voiceFocus: nc.voiceFocus, isFinal: true))
            }
            if nc.mode == .ambient {
                VStack(alignment: .leading, spacing: 10) {
                    if let range = nc.ambientLevelRange, range.count > 1 {
                        HStack(spacing: 10) {
                            Image(systemName: "speaker.wave.1.fill").foregroundStyle(.secondary).imageScale(.small)
                            Slider(value: Binding(
                                get: { dragLevel ?? Double(nc.ambientLevel) },
                                set: { v in
                                    dragLevel = v
                                    model.perform(.setNoise(mode: .ambient, ambientLevel: Int(v), voiceFocus: nc.voiceFocus, isFinal: false))
                                }
                            ), in: Double(range.lowerBound) ... Double(range.upperBound), step: 1) { editing in
                                if !editing, let v = dragLevel {
                                    model.perform(.setNoise(mode: .ambient, ambientLevel: Int(v), voiceFocus: nc.voiceFocus, isFinal: true))
                                    dragLevel = nil
                                }
                            }
                            Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary).imageScale(.small)
                            Text("\(Int(dragLevel ?? Double(nc.ambientLevel)))")
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .contentTransition(.numericText())
                                .frame(width: 22, alignment: .trailing)
                        }
                    }
                    if nc.supportsVoiceFocus {
                        Toggle(isOn: Binding(
                            get: { nc.voiceFocus },
                            set: { model.perform(.setNoise(mode: .ambient, ambientLevel: nc.ambientLevel, voiceFocus: $0, isFinal: true)) }
                        )) {
                            Label("Focus on voice", systemImage: "person.wave.2")
                        }
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    }
                }
                .transition(.blurReplace)
            }
        }
        .animation(.smooth(duration: 0.25), value: nc.mode)
    }
}

// MARK: - Equalizer

struct EqPresetMenu: View {
    @Environment(AppModel.self) private var model
    let eq: EqualizerState

    var body: some View {
        Picker(selection: Binding(get: { eq.activePresetID }, set: { model.perform(.selectEqPreset(id: $0)) })) {
            ForEach(eq.presets) { p in Text(p.name).tag(p.id) }
        } label: {
            EmptyView()
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .buttonStyle(.glass)
        .fixedSize()
    }
}

/// Vertical band sliders.
struct EqualizerBands: View {
    @Environment(AppModel.self) private var model
    let eq: EqualizerState
    var height: CGFloat = 170
    var interactive = true
    var showValues = true
    @ViewState private var dragValues: [Int]?

    var body: some View {
        let values = dragValues ?? eq.bands.map(\.value)
        HStack(alignment: .bottom, spacing: 0) {
            ForEach(Array(eq.bands.enumerated()), id: \.offset) { i, band in
                VStack(spacing: 6) {
                    if showValues {
                        Text(values[i] > 0 ? "+\(values[i])" : "\(values[i])")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .contentTransition(.numericText(value: Double(values[i])))
                    }
                    VerticalSlider(value: values[i], range: eq.bandRange, accent: band.isClearBass ? .orange : .accentColor,
                                   interactive: interactive) { v, final in
                        var vs = dragValues ?? eq.bands.map(\.value)
                        vs[i] = v
                        dragValues = final ? nil : vs
                        model.perform(.setEqBands(vs))
                    }
                    .frame(height: height)
                    Text(band.label)
                        .font(.caption2.weight(band.isClearBass ? .semibold : .regular))
                        .foregroundStyle(band.isClearBass ? Color.orange : Color.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .frame(maxWidth: .infinity)
                if band.isClearBass && i < eq.bands.count - 1 {
                    Rectangle().fill(.separator).frame(width: 1, height: height * 0.7).padding(.bottom, 24)
                }
            }
        }
        .animation(.smooth(duration: 0.2), value: eq.bands)
    }
}

/// A vertical slider in the macOS 26 idiom: thin track, accent fill from the zero line,
/// and a glass pill thumb that grows while dragging.
struct VerticalSlider: View {
    let value: Int
    let range: ClosedRange<Int>
    var accent: Color = .accentColor
    var interactive = true
    let onChange: (Int, _ isFinal: Bool) -> Void
    @ViewState private var dragging = false

    private var thumbSize: CGSize { dragging ? CGSize(width: 26, height: 16) : CGSize(width: 22, height: 13) }

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let usable = max(h - thumbSize.height, 1)
            let span = CGFloat(max(1, range.upperBound - range.lowerBound))
            let frac = CGFloat(value - range.lowerBound) / span
            let zeroFrac = CGFloat(min(max(0, range.lowerBound), range.upperBound) - range.lowerBound) / span
            let knobCenter = thumbSize.height / 2 + usable * (1 - frac)
            let zeroY = thumbSize.height / 2 + usable * (1 - zeroFrac)
            ZStack(alignment: .top) {
                Capsule().fill(.fill.secondary).frame(width: 4)
                Capsule()
                    .fill(accent)
                    .frame(width: 4, height: max(abs(zeroY - knobCenter), 0))
                    .offset(y: min(zeroY, knobCenter))
                Capsule()
                    .fill(.white)
                    .frame(width: thumbSize.width, height: thumbSize.height)
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .offset(y: knobCenter - thumbSize.height / 2)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(interactive ? DragGesture(minimumDistance: 0)
                .onChanged { g in
                    if !dragging { dragging = true }
                    let v = valueFor(y: g.location.y, height: h)
                    if v != value { onChange(v, false) }
                }
                .onEnded { g in
                    dragging = false
                    onChange(valueFor(y: g.location.y, height: h), true)
                } : nil)
            .animation(.snappy(duration: 0.18), value: dragging)
        }
        .accessibilityElement()
        .accessibilityValue("\(value)")
        .accessibilityAdjustableAction { dir in
            switch dir {
            case .increment: onChange(min(value + 1, range.upperBound), true)
            case .decrement: onChange(max(value - 1, range.lowerBound), true)
            @unknown default: break
            }
        }
    }

    private func valueFor(y: CGFloat, height: CGFloat) -> Int {
        let usable = max(height - thumbSize.height, 1)
        let frac = 1 - min(max((y - thumbSize.height / 2) / usable, 0), 1)
        return range.lowerBound + Int((frac * CGFloat(range.upperBound - range.lowerBound)).rounded())
    }
}

// MARK: - Battery

struct BatteryBadge: View {
    let label: String?
    let level: BatteryLevel

    var body: some View {
        HStack(spacing: 4) {
            if let label { Text(label).font(.caption2.weight(.semibold)).foregroundStyle(.secondary) }
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(color)
            Text("\(level.percent)%").font(.caption.monospacedDigit().weight(.medium))
        }
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        if level.isCharging { return "battery.100percent.bolt" }
        switch level.percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    private var color: Color {
        level.isCharging ? .green : level.percent <= 15 ? .red : level.percent <= 30 ? .orange : .primary
    }
}

struct BatteryRow: View {
    let battery: BatteryState
    var body: some View {
        HStack(spacing: 10) {
            if let m = battery.main { BatteryBadge(label: nil, level: m) }
            if let l = battery.left { BatteryBadge(label: "L", level: l) }
            if let r = battery.right { BatteryBadge(label: "R", level: r) }
            if let c = battery.chargingCase { BatteryBadge(label: "Case", level: c) }
        }
    }
}

// MARK: - Content group

/// A quiet content group for the popover: system fill, corners concentric with the window.
struct Card<Content: View>: View {
    let title: String?
    let symbol: String?
    var trailing: AnyView? = nil
    @ViewBuilder let content: Content

    init(_ title: String? = nil, symbol: String? = nil, trailing: AnyView? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.trailing = trailing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if title != nil || trailing != nil {
                HStack {
                    if let title {
                        Label(title, systemImage: symbol ?? "")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    trailing
                }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.fill.quaternary, in: ConcentricRectangle(corners: .concentric(minimum: .fixed(14)), isUniform: true))
    }
}
