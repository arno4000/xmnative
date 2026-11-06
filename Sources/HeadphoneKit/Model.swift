import Foundation

// Vendor-neutral description of what a pair of headphones can do and what state it is in.
// Every feature is optional: `nil` means "this device does not have it (or we don't know yet)".
// The UI renders only what is present, so a new vendor only has to fill in what it supports.

public struct HeadphoneState: Equatable, Sendable {
    public var vendor: String
    public var modelName: String?
    public var firmwareVersion: String?
    public var protocolInfo: String?

    public var battery: BatteryState?
    public var codec: AudioCodec?
    public var noiseControl: NoiseControlState?
    public var equalizer: EqualizerState?
    public var speakToChat: SpeakToChatState?
    public var autoPowerOff: AutoPowerOffState?
    public var upscaling: UpscalingState?
    public var connectionPriority: ConnectionPriorityState?
    /// Simple on/off settings (touch panel, voice guidance, multipoint, pause when taken off, ...).
    public var toggles: [ToggleSetting]
    /// Configurable buttons / touch areas.
    public var buttons: [ButtonAssignment]
    public var playback: PlaybackState?
    public var optimizer: OptimizerState?

    public init(vendor: String) {
        self.vendor = vendor
        self.toggles = []
        self.buttons = []
    }
}

// MARK: Battery

public struct BatteryLevel: Equatable, Sendable {
    public var percent: Int
    public var isCharging: Bool
    public init(percent: Int, isCharging: Bool) {
        self.percent = percent
        self.isCharging = isCharging
    }
}

public struct BatteryState: Equatable, Sendable {
    /// Over-ear headphones report one value.
    public var main: BatteryLevel?
    /// True-wireless earbuds report left/right (+ case).
    public var left: BatteryLevel?
    public var right: BatteryLevel?
    public var chargingCase: BatteryLevel?
    public init(main: BatteryLevel? = nil, left: BatteryLevel? = nil, right: BatteryLevel? = nil, chargingCase: BatteryLevel? = nil) {
        self.main = main
        self.left = left
        self.right = right
        self.chargingCase = chargingCase
    }
}

// MARK: Codec

public enum AudioCodec: String, Equatable, Sendable {
    case sbc = "SBC", aac = "AAC", ldac = "LDAC", aptX = "aptX", aptXHD = "aptX HD", lc3 = "LC3", other = "Other", unknown = "—"
}

// MARK: Noise control

public enum NoiseMode: String, CaseIterable, Hashable, Sendable {
    case noiseCancelling
    case windReduction
    case ambient
    case off
}

public struct NoiseControlState: Equatable, Sendable {
    public var mode: NoiseMode
    /// Ambient-sound level when `mode == .ambient`.
    public var ambientLevel: Int
    /// "Focus on voice" for ambient mode.
    public var voiceFocus: Bool

    // Capabilities
    public var supportedModes: [NoiseMode]
    /// nil → ambient mode is on/off only, no slider.
    public var ambientLevelRange: ClosedRange<Int>?
    public var supportsVoiceFocus: Bool

    public init(mode: NoiseMode, ambientLevel: Int, voiceFocus: Bool, supportedModes: [NoiseMode], ambientLevelRange: ClosedRange<Int>?, supportsVoiceFocus: Bool) {
        self.mode = mode
        self.ambientLevel = ambientLevel
        self.voiceFocus = voiceFocus
        self.supportedModes = supportedModes
        self.ambientLevelRange = ambientLevelRange
        self.supportsVoiceFocus = supportsVoiceFocus
    }
}

// MARK: Equalizer

public struct EqPreset: Equatable, Hashable, Sendable, Identifiable {
    public var id: Int
    public var name: String
    public var isCustomizable: Bool
    public init(id: Int, name: String, isCustomizable: Bool) {
        self.id = id
        self.name = name
        self.isCustomizable = isCustomizable
    }
}

public struct EqBand: Equatable, Sendable, Identifiable {
    public var id: Int
    public var label: String
    /// Display value, centred on 0 (e.g. -10...+10).
    public var value: Int
    public var isClearBass: Bool
    public init(id: Int, label: String, value: Int, isClearBass: Bool) {
        self.id = id
        self.label = label
        self.value = value
        self.isClearBass = isClearBass
    }
}

public struct EqualizerState: Equatable, Sendable {
    public var presets: [EqPreset]
    public var activePresetID: Int
    public var bands: [EqBand]
    public var bandRange: ClosedRange<Int>
    public init(presets: [EqPreset], activePresetID: Int, bands: [EqBand], bandRange: ClosedRange<Int>) {
        self.presets = presets
        self.activePresetID = activePresetID
        self.bands = bands
        self.bandRange = bandRange
    }
    public var activePreset: EqPreset? { presets.first { $0.id == activePresetID } }
}

// MARK: Speak-to-chat

public enum SpeakToChatSensitivity: String, CaseIterable, Sendable { case auto, high, low }
public enum SpeakToChatTimeout: String, CaseIterable, Sendable { case short, standard, long, none }

public struct SpeakToChatState: Equatable, Sendable {
    public var enabled: Bool
    /// nil → device has no detail settings.
    public var sensitivity: SpeakToChatSensitivity?
    public var voiceFocus: Bool?
    public var timeout: SpeakToChatTimeout?
    public init(enabled: Bool, sensitivity: SpeakToChatSensitivity? = nil, voiceFocus: Bool? = nil, timeout: SpeakToChatTimeout? = nil) {
        self.enabled = enabled
        self.sensitivity = sensitivity
        self.voiceFocus = voiceFocus
        self.timeout = timeout
    }
}

// MARK: Auto power off

public enum AutoPowerOffOption: Hashable, Sendable {
    case minutes(Int)
    case whenRemoved
    case disabled
    case other(Int)

    public var title: String {
        switch self {
        case .minutes(let m): return m >= 60 ? "After \(m / 60) h" : "After \(m) min"
        case .whenRemoved: return "When taken off"
        case .disabled: return "Never"
        case .other(let raw): return "Option \(raw)"
        }
    }
}

public struct AutoPowerOffState: Equatable, Sendable {
    public var current: AutoPowerOffOption
    public var options: [AutoPowerOffOption]
    public init(current: AutoPowerOffOption, options: [AutoPowerOffOption]) {
        self.current = current
        self.options = options
    }
}

// MARK: Audio

public struct UpscalingState: Equatable, Sendable {
    /// e.g. "DSEE", "DSEE HX", "DSEE Extreme"
    public var name: String
    public var enabled: Bool
    public init(name: String, enabled: Bool) {
        self.name = name
        self.enabled = enabled
    }
}

public enum ConnectionPriority: String, CaseIterable, Sendable { case soundQuality, connectionQuality }

public struct ConnectionPriorityState: Equatable, Sendable {
    public var current: ConnectionPriority
    public init(current: ConnectionPriority) { self.current = current }
}

// MARK: Buttons

public struct ButtonFunction: Equatable, Hashable, Sendable, Identifiable {
    public var id: Int
    public var title: String
    public init(id: Int, title: String) { self.id = id; self.title = title }
}

public struct ButtonAssignment: Equatable, Sendable, Identifiable {
    /// Driver-defined index of the button.
    public var id: Int
    public var title: String
    public var options: [ButtonFunction]
    public var selectedID: Int
    public init(id: Int, title: String, options: [ButtonFunction], selectedID: Int) {
        self.id = id
        self.title = title
        self.options = options
        self.selectedID = selectedID
    }
}

// MARK: NC Optimizer

public struct OptimizerState: Equatable, Sendable {
    public enum Phase: Equatable, Sendable { case idle, measuringFit, measuringPressure, optimizing, finished }
    public var phase: Phase
    public init(phase: Phase) { self.phase = phase }
    public var isRunning: Bool { [.measuringFit, .measuringPressure, .optimizing].contains(phase) }
}

// MARK: Playback

public enum PlaybackCommand: Sendable, Equatable { case play, pause, next, previous }

public struct PlaybackState: Equatable, Sendable {
    public var isPlaying: Bool?
    public var volume: Int?
    public var maxVolume: Int
    public var title: String?
    public var artist: String?
    public init(isPlaying: Bool? = nil, volume: Int? = nil, maxVolume: Int = 30, title: String? = nil, artist: String? = nil) {
        self.isPlaying = isPlaying
        self.volume = volume
        self.maxVolume = maxVolume
        self.title = title
        self.artist = artist
    }
}

// MARK: Generic toggles

public struct ToggleSetting: Equatable, Sendable, Identifiable {
    /// Driver-defined stable id.
    public var id: String
    public var title: String
    public var subtitle: String?
    public var isOn: Bool
    public init(id: String, title: String, subtitle: String? = nil, isOn: Bool) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.isOn = isOn
    }
}
