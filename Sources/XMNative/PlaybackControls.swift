import SwiftUI
import HeadphoneKit

/// Now playing + transport + headphone volume (controls whatever source the headphones play from).
struct PlaybackControls: View {
    @Environment(AppModel.self) private var model
    let playback: PlaybackState
    @ViewState private var dragVolume: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(playback.title?.isEmpty == false ? playback.title! : "Not playing")
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    if let artist = playback.artist, !artist.isEmpty {
                        Text(artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                GlassEffectContainer {
                    HStack(spacing: 4) {
                        transport("backward.fill", "Previous") { model.perform(.playback(.previous)) }
                        transport(playback.isPlaying == true ? "pause.fill" : "play.fill",
                                  playback.isPlaying == true ? "Pause" : "Play") {
                            model.perform(.playback(playback.isPlaying == true ? .pause : .play))
                        }
                        transport("forward.fill", "Next") { model.perform(.playback(.next)) }
                    }
                }
            }
            if let volume = playback.volume {
                HStack(spacing: 10) {
                    Image(systemName: "speaker.fill").foregroundStyle(.secondary).imageScale(.small)
                    Slider(value: Binding(
                        get: { dragVolume ?? Double(volume) },
                        set: { v in
                            dragVolume = v
                            model.perform(.setVolume(Int(v.rounded())))
                        }
                    ), in: 0 ... Double(max(playback.maxVolume, 1)), step: 1) { editing in
                        if !editing { dragVolume = nil }
                    }
                    Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary).imageScale(.small)
                }
                .accessibilityLabel("Headphone volume")
            }
        }
    }

    private func transport(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.small)
        .help(label)
        .accessibilityLabel(label)
    }
}
