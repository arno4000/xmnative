import Foundation

/// A raw, already-open byte pipe to the headphones (RFCOMM on macOS/Linux, anything else in tests).
/// Implemented per platform; drivers never see the OS Bluetooth API.
@MainActor
public protocol ByteTransport: AnyObject {
    /// Called for every chunk of bytes the device sends.
    var onReceive: (([UInt8]) -> Void)? { get set }
    /// Called once when the link goes away (nil error = closed by us).
    var onClose: ((Error?) -> Void)? { get set }
    func write(_ bytes: [UInt8]) throws
    func close()
}

/// What the platform layer knows about a paired device before we talk to it.
public struct DeviceDescriptor: Hashable, Sendable, Identifiable {
    public var id: String { address }
    public var address: String
    public var name: String
    public var isConnected: Bool
    /// RFCOMM service UUIDs advertised via SDP, mapped to their channel IDs.
    public var rfcommServices: [UUID: UInt8]
    /// Every service class UUID in the cached SDP records (RFCOMM or not), for telling vendors apart.
    public var advertisedServices: Set<UUID>
    /// Bluetooth SIG company ID from the Device ID record (Sony 0x012D, Bose 0x009E), if cached.
    public var vendorID: UInt16?

    public init(address: String, name: String, isConnected: Bool, rfcommServices: [UUID: UInt8], advertisedServices: Set<UUID> = [],
                vendorID: UInt16? = nil) {
        self.address = address
        self.name = name
        self.isConnected = isConnected
        self.rfcommServices = rfcommServices
        self.advertisedServices = advertisedServices
        self.vendorID = vendorID
    }
}

/// User intents. Drivers translate them to vendor commands.
public enum HeadphoneAction: Sendable, Equatable {
    /// `isFinal == false` while a slider is still being dragged.
    case setNoise(mode: NoiseMode, ambientLevel: Int, voiceFocus: Bool, isFinal: Bool)
    case selectEqPreset(id: Int)
    case setEqBands([Int])
    case setSpeakToChat(enabled: Bool)
    case setSpeakToChatDetails(sensitivity: SpeakToChatSensitivity, voiceFocus: Bool?, timeout: SpeakToChatTimeout)
    case setAutoPowerOff(AutoPowerOffOption)
    case setUpscaling(enabled: Bool)
    case setConnectionPriority(ConnectionPriority)
    case setToggle(id: String, isOn: Bool)
    case setButton(id: Int, functionID: Int)
    case selectListeningMode(id: Int)
    /// Noise cancelling strength of the current listening mode.
    case setNoiseLevel(Int, isFinal: Bool)
    case setChoice(id: String, optionID: Int)
    case createListeningMode(ListeningModeSettings)
    case updateListeningMode(id: Int, ListeningModeSettings)
    case deleteListeningMode(id: Int)
    case setListeningModeFavorite(id: Int, isFavorite: Bool)
    /// Noise control outside of modes. `isFinal == false` while the slider is dragged.
    case setLiveNoise(isOn: Bool, level: Int, isFinal: Bool)
    case playback(PlaybackCommand)
    case setVolume(Int)
    case startOptimizer
    case cancelOptimizer
    case refresh
}

/// One live session with one device.
@MainActor
public protocol HeadphoneDriver: AnyObject {
    var state: HeadphoneState { get }
    /// Called on every state change.
    var onStateChange: ((HeadphoneState) -> Void)? { get set }
    /// Called once when the session ends (nil = closed by us).
    var onDisconnect: ((Error?) -> Void)? { get set }
    /// Handshake + initial queries.
    func start() async throws
    func perform(_ action: HeadphoneAction) async
    func stop()
}

/// Drivers that can report the raw protocol traffic for the debug log.
@MainActor
public protocol WireLogging: AnyObject {
    var log: ((String) -> Void)? { get set }
}

/// A vendor plug-in. Register one per protocol family (Sony MDR, Bose BMAP, ...).
@MainActor
public protocol HeadphoneDriverFactory {
    var vendor: String { get }
    /// RFCOMM service UUIDs this driver can speak, so the platform layer knows what to look up via SDP.
    var serviceUUIDs: [UUID] { get }
    /// Cheap name-based hint for devices whose SDP records are not cached yet.
    func mightSupport(deviceName: String) -> Bool
    /// Picks the RFCOMM service to open on this device, or nil if the driver can't handle it.
    func preferredService(for device: DeviceDescriptor) -> (uuid: UUID, channel: UInt8)?
    func makeDriver(device: DeviceDescriptor, serviceUUID: UUID, transport: ByteTransport) -> HeadphoneDriver
}

extension HeadphoneDriverFactory {
    /// Hint from cached metadata (vendor ID, advertised services) for devices whose control service isn't known yet.
    public func mightSupport(device: DeviceDescriptor) -> Bool { false }
}

public enum HeadphoneError: Error, LocalizedError {
    case timeout
    case disconnected
    case notSupported
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .timeout: return "The headphones did not respond."
        case .disconnected: return "The headphones disconnected."
        case .notSupported: return "This device is not supported."
        case .transport(let s): return s
        }
    }
}
