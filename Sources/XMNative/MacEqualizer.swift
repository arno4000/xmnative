import Foundation
import Observation
import MacAudio

/// The Mac-wide equalizer: settings, presets and the audio engine behind them.
/// Independent of the headphones: it works on whatever output device is selected.
@MainActor
@Observable
final class MacEqualizer {
    enum Status: Equatable {
        case off
        case askingPermission
        case needsPermission
        case running(device: String)
        case failed(String)
    }

    struct Settings: Codable, Equatable {
        var enabled = false
        var layout = MacEqLayout.ten
        var gains = MacEqPreset.flat(.ten)
        var preamp = 0
        var preventClipping = true
        var presets: [MacEqPreset] = []
    }

    private(set) var settings: Settings
    private(set) var status: Status = .off

    private let engine = SystemAudioEqualizer()
    private let defaults: UserDefaults
    private static let key = "macEqualizer"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key), let s = try? JSONDecoder().decode(Settings.self, from: data),
           s.gains.count == s.layout.bandCount {
            settings = s
        } else {
            settings = Settings()
        }
        engine.makeProcessor = { [weak self] rate in
            guard let self else { throw MacAudioError("Equalizer closed") }
            let p = try GraphicEQProcessor(layout: self.settings.layout, sampleRate: rate)
            p.setGains(self.settings.gains)
            p.setPreamp(self.effectivePreamp)
            return p
        }
        engine.onStatusChange = { [weak self] s in self?.engineStatusChanged(s) }
        if settings.enabled { start() }
    }

    // MARK: Reading

    var isEnabled: Bool { settings.enabled }
    var layout: MacEqLayout { settings.layout }
    var gains: [Int] { settings.gains }
    var preamp: Int { settings.preamp }
    var preventClipping: Bool { settings.preventClipping }
    var savedPresets: [MacEqPreset] { settings.presets }
    var builtInPresets: [MacEqPreset] { MacEqPreset.builtIn }

    /// The gain actually applied before the EQ.
    var effectivePreamp: Int {
        EqCurve.headroom(for: settings.gains, preamp: settings.preamp, preventClipping: settings.preventClipping)
    }

    /// The preset whose curve matches the current bands, if any.
    var presetName: String? {
        (builtInPresets + savedPresets).first { $0.gains(for: layout) == gains }?.name
    }

    var isFlat: Bool { gains.allSatisfy { $0 == 0 } }

    var statusText: String {
        switch status {
        case .off: "Off"
        case .askingPermission: "Waiting for permission…"
        case .needsPermission: "Needs permission to process the Mac's sound"
        case .running(let device): "On · \(device)"
        case .failed(let message): message
        }
    }

    // MARK: Changing

    func setEnabled(_ on: Bool) {
        guard on != settings.enabled else { return }
        settings.enabled = on
        persist()
        if on { start() } else { engine.stop() }
    }

    func setGain(_ db: Int, band: Int, isFinal: Bool) {
        guard settings.gains.indices.contains(band) else { return }
        settings.gains[band] = EqCurve.clamp(db)
        engine.processor?.setGain(settings.gains[band], band: band)
        engine.processor?.setPreamp(effectivePreamp)
        if isFinal { persist() }
    }

    func setGains(_ gains: [Int]) {
        guard gains.count == layout.bandCount else { return }
        settings.gains = gains.map(EqCurve.clamp)
        engine.processor?.setGains(settings.gains)
        engine.processor?.setPreamp(effectivePreamp)
        persist()
    }

    func apply(_ preset: MacEqPreset) { setGains(preset.gains(for: layout)) }

    func resetToFlat() { setGains(MacEqPreset.flat(layout)) }

    func setPreamp(_ db: Int, isFinal: Bool) {
        settings.preamp = min(max(db, EqCurve.preampRange.lowerBound), EqCurve.preampRange.upperBound)
        engine.processor?.setPreamp(effectivePreamp)
        if isFinal { persist() }
    }

    func setPreventClipping(_ on: Bool) {
        settings.preventClipping = on
        engine.processor?.setPreamp(effectivePreamp)
        persist()
    }

    /// Switches between 10 and 31 bands, keeping the shape of the curve.
    func setLayout(_ layout: MacEqLayout) {
        guard layout != settings.layout else { return }
        settings.gains = EqCurve.convert(settings.gains, from: settings.layout, to: layout)
        settings.layout = layout
        persist()
        // The audio unit's band count is fixed once it runs.
        if engine.isRunning {
            engine.stop()
            engine.start()
        }
    }

    func savePreset(named name: String) {
        let preset = MacEqPreset(name: name, layout: layout, gains: gains)
        if let i = settings.presets.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            settings.presets[i] = preset
        } else {
            settings.presets.append(preset)
        }
        persist()
    }

    func deletePreset(named name: String) {
        settings.presets.removeAll { $0.name == name }
        persist()
    }

    func isBuiltIn(_ name: String) -> Bool {
        builtInPresets.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    // MARK: Engine

    private func start() {
        switch AudioCapturePermission.state {
        case .authorized:
            engine.start()
        case .denied:
            status = .needsPermission
        case .unknown:
            status = .askingPermission
            AudioCapturePermission.request { [weak self] granted in
                MainActor.assumeIsolated {
                    guard let self, self.settings.enabled else { return }
                    if granted { self.engine.start() } else { self.status = .needsPermission }
                }
            }
        }
    }

    /// Try again, e.g. after granting the permission in System Settings.
    func retry() {
        guard settings.enabled else { return }
        engine.stop()
        start()
    }

    private func engineStatusChanged(_ s: SystemAudioEqualizer.Status) {
        switch s {
        case .off: status = settings.enabled && status == .needsPermission ? .needsPermission : .off
        case .running(let device): status = .running(device: device)
        case .failed(let message): status = .failed(message)
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: Self.key) }
    }
}
