import SwiftUI
import HeadphoneKit

struct PopoverView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 12)

            Divider()

            Group {
                switch model.connection {
                case .connected:
                    if let state = model.state { connectedBody(state) }
                case .connecting(let name):
                    VStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Connecting to \(name)…").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 120)
                case .idle, .failed:
                    VStack(spacing: 10) {
                        DeviceListView()
                        MacEqualizerCard()
                    }
                }
            }
            .padding(12)

            Divider()
            footer
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        .frame(width: 340)
        .containerShape(.rect(cornerRadius: 22))
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "headphones")
                .font(.system(size: 22, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(model.connection == .connected ? Color.accentColor : Color.secondary)
                .frame(width: 34, height: 34)
                .symbolEffect(.pulse, isActive: isConnecting)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.connection == .connected ? model.displayName : "XMNative")
                    .font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let b = model.state?.battery { BatteryRow(battery: b) }
        }
    }

    private var isConnecting: Bool {
        if case .connecting = model.connection { return true }
        return false
    }

    private var subtitle: String {
        switch model.connection {
        case .connected:
            var parts: [String] = []
            if let c = model.state?.codec, c != .unknown { parts.append(c.rawValue) }
            if let fw = model.state?.firmwareVersion { parts.append("FW \(fw)") }
            return parts.isEmpty ? "Connected" : parts.joined(separator: " · ")
        case .connecting: return "Connecting…"
        case .idle: return "Not connected"
        case .failed(let msg): return msg
        }
    }

    @ViewBuilder
    private func connectedBody(_ state: HeadphoneState) -> some View {
        VStack(spacing: 10) {
            if let nc = state.noiseControl {
                NoiseControlSection(nc: nc)
                    .padding(.horizontal, 2)
                    .padding(.bottom, 2)
            }
            if let lm = state.listeningModes {
                ListeningModeSection(modes: lm, includeLiveNoise: true)
                    .padding(.horizontal, 2)
                    .padding(.bottom, 2)
            }
            if let eq = state.equalizer {
                Card("Equalizer", symbol: "slider.vertical.3", trailing: eq.presets.count > 1 ? AnyView(EqPresetMenu(eq: eq)) : AnyView(AppEqPresetMenu(eq: eq))) {
                    EqualizerBands(eq: eq, height: 64)
                }
            }
            MacEqualizerCard()
            if let p = state.playback {
                Card { PlaybackControls(playback: p) }
            }
            let quick = quickToggles(state)
            if !quick.isEmpty {
                Card {
                    VStack(spacing: 8) {
                        ForEach(quick, id: \.title) { t in
                            Toggle(isOn: Binding(get: { t.isOn }, set: t.set)) {
                                Label(t.title, systemImage: t.symbol)
                            }
                            .toggleStyle(.switch)
                            .controlSize(.small)
                        }
                    }
                }
            }
        }
    }

    private struct Quick { let title: String; let symbol: String; let isOn: Bool; let set: (Bool) -> Void }

    private func quickToggles(_ s: HeadphoneState) -> [Quick] {
        var out: [Quick] = []
        if let stc = s.speakToChat {
            out.append(Quick(title: "Speak-to-Chat", symbol: "bubble.left.and.text.bubble.right", isOn: stc.enabled) {
                model.perform(.setSpeakToChat(enabled: $0))
            })
        }
        if let u = s.upscaling {
            out.append(Quick(title: u.name, symbol: "sparkles", isOn: u.enabled) { model.perform(.setUpscaling(enabled: $0)) })
        }
        return out
    }

    private var footer: some View {
        GlassEffectContainer {
            HStack(spacing: 8) {
                Button {
                    AppActions.openMainWindow(openWindow)
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                Spacer()
                if model.connection == .connected {
                    Button("Disconnect") { model.disconnect() }
                }
                Button {
                    NSApp.terminate(nil)
                } label: {
                    Image(systemName: "power")
                }
                .help("Quit XMNative")
            }
            .buttonStyle(.glass)
            .controlSize(.regular)
        }
    }
}

struct DeviceListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if case .failed(let msg) = model.connection {
                Label(msg, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Paired headphones").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            if model.compatibleDevices.isEmpty {
                Text("No supported headphones found. Pair your Sony or Bose headphones in System Settings › Bluetooth. If they're paired but missing here, allow XMNative under Privacy & Security › Bluetooth.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(model.compatibleDevices) { d in
                HStack {
                    Image(systemName: "headphones")
                        .foregroundStyle(d.isConnected ? Color.accentColor : .secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(d.name)
                        Text(d.isConnected ? "Connected to this Mac" : "Not connected")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    // Not disabled when macOS says "not connected": IOBluetooth sometimes reports that for
                    // devices that are connected (seen with Bose). Opening the channel fails clearly if they aren't.
                    Button("Connect") { Task { await model.connect(d) } }
                        .buttonStyle(.glassProminent)
                        .controlSize(.small)
                        .help(d.isConnected ? "Open the control channel" : "macOS doesn't report these as connected. Try anyway.")
                }
                .padding(10)
                .background(.fill.quaternary, in: ConcentricRectangle(corners: .concentric(minimum: .fixed(12)), isUniform: true))
            }
            HStack {
                Button("Refresh list") { model.reloadDevices() }
                Spacer()
                if case .failed = model.connection, model.canReconnect {
                    Button("Try again") { model.reconnect() }
                }
            }
            .buttonStyle(.link)
            .font(.callout)
            .padding(.top, 4)
        }
    }
}
