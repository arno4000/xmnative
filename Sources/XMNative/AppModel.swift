import Foundation
import Observation
import ServiceManagement
import HeadphoneKit
import SonyMDR
import BoseBMAP
import MacBluetooth

@MainActor
@Observable
final class AppModel {
    enum Connection: Equatable {
        case idle
        case connecting(String)
        case connected
        case failed(String)
    }

    private(set) var devices: [DeviceDescriptor] = []
    private(set) var connection: Connection = .idle
    private(set) var state: HeadphoneState?
    private(set) var connectedAddress: String?
    private(set) var wireLog: [String] = []

    var autoConnect: Bool {
        didSet { defaults.set(autoConnect, forKey: "autoConnect") }
    }
    var lastAddress: String? {
        didSet { defaults.set(lastAddress, forKey: "lastAddress") }
    }
    var showBatteryInMenuBar: Bool {
        didSet { defaults.set(showBatteryInMenuBar, forKey: "showBatteryInMenuBar") }
    }
    var showWireLog = false

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                loginItemError = error.localizedDescription
            }
            loginItemRevision += 1
        }
    }
    private(set) var loginItemError: String?
    /// Bumped so SwiftUI re-reads `launchAtLogin` (SMAppService isn't observable).
    private var loginItemRevision = 0

    /// Vendor plug-ins. Sony first: Bose claims the generic serial port service, but only on Bose devices.
    let factories: [HeadphoneDriverFactory] = [SonyDriverFactory(), BoseDriverFactory()]

    private let defaults = UserDefaults.standard
    private let directory = BluetoothDirectory()
    private var driver: HeadphoneDriver?
    private var refreshTask: Task<Void, Never>?

    init() {
        autoConnect = defaults.object(forKey: "autoConnect") as? Bool ?? true
        showBatteryInMenuBar = defaults.object(forKey: "showBatteryInMenuBar") as? Bool ?? true
        lastAddress = defaults.string(forKey: "lastAddress")
        loadEqPresets()
        directory.onChange = { [weak self] in self?.devicesChanged() }
        directory.startObserving()
        reloadDevices()
        maybeAutoConnect()
    }

    // MARK: Devices

    private var candidateUUIDs: [UUID] { factories.flatMap(\.serviceUUIDs) }

    /// Paired devices that some driver can (probably) handle.
    var compatibleDevices: [DeviceDescriptor] {
        devices.filter { d in
            factories.contains { $0.preferredService(for: d) != nil || $0.mightSupport(deviceName: d.name) || $0.mightSupport(device: d) }
        }
    }

    func reloadDevices() {
        devices = directory.pairedDevices(candidateUUIDs: candidateUUIDs)
    }

    private func devicesChanged() {
        reloadDevices()
        if let addr = connectedAddress, devices.first(where: { $0.address == addr })?.isConnected == false {
            handleDisconnect(nil)
        }
        maybeAutoConnect()
    }

    private func maybeAutoConnect() {
        guard autoConnect, driver == nil, let addr = lastAddress,
              let d = devices.first(where: { $0.address == addr && $0.isConnected }) else { return }
        switch connection {
        case .idle, .failed: Task { await connect(d) }
        default: break
        }
    }

    // MARK: Connection

    func connect(_ device: DeviceDescriptor) async {
        disconnect()
        connection = .connecting(device.name)
        var desc = device
        if factories.allSatisfy({ $0.preferredService(for: desc) == nil }) {
            desc = await directory.refreshServices(address: device.address, candidateUUIDs: candidateUUIDs) ?? device
        }
        guard let factory = factories.first(where: { $0.preferredService(for: desc) != nil }),
              let service = factory.preferredService(for: desc) else {
            connection = .failed("\(device.name) doesn't offer a control channel this app understands.")
            return
        }
        do {
            let transport = try await RFCOMMTransport.open(address: desc.address, channelID: service.channel)
            let drv = factory.makeDriver(device: desc, serviceUUID: service.uuid, transport: transport)
            try await attach(drv, address: desc.address)
            lastAddress = desc.address
        } catch {
            driver?.stop()
            driver = nil
            connectedAddress = nil
            state = nil
            connection = .failed(error.localizedDescription)
        }
    }

    /// Reconnect to the last used device, if it is connected to the Mac.
    func reconnect() {
        reloadDevices()
        guard let addr = lastAddress, let d = devices.first(where: { $0.address == addr }) else { return }
        Task { await connect(d) }
    }

    var canReconnect: Bool {
        guard let addr = lastAddress else { return false }
        return devices.contains { $0.address == addr && $0.isConnected }
    }

    private func attach(_ drv: HeadphoneDriver, address: String) async throws {
        driver = drv
        connectedAddress = address
        wireLog.removeAll()
        if let logging = drv as? WireLogging {
            logging.log = { [weak self] line in
                guard let self, self.showWireLog else { return }
                self.wireLog.append(line)
                if self.wireLog.count > 400 { self.wireLog.removeFirst(self.wireLog.count - 400) }
            }
        }
        drv.onStateChange = { [weak self] s in self?.state = s }
        drv.onDisconnect = { [weak self] e in self?.handleDisconnect(e) }
        state = drv.state
        try await drv.start()
        state = drv.state
        connection = .connected
        startPeriodicRefresh()
    }

    func disconnect() {
        refreshTask?.cancel()
        refreshTask = nil
        let d = driver
        driver = nil
        d?.onDisconnect = nil
        d?.stop()
        state = nil
        connectedAddress = nil
        connection = .idle
    }

    private func handleDisconnect(_ error: Error?) {
        guard driver != nil else { return }
        refreshTask?.cancel()
        driver = nil
        state = nil
        connectedAddress = nil
        connection = error.map { .failed($0.localizedDescription) } ?? .idle
    }

    private func startPeriodicRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(120))
                guard !Task.isCancelled else { return }
                await self?.driver?.perform(.refresh)
            }
        }
    }

    // MARK: Actions

    func perform(_ action: HeadphoneAction) {
        guard let driver else { return }
        Task { await driver.perform(action) }
    }

    var displayName: String {
        state?.modelName ?? devices.first { $0.address == connectedAddress }?.name ?? "Headphones"
    }

    /// Lowest battery percentage, for the menu bar.
    var batterySummary: Int? {
        guard let b = state?.battery else { return nil }
        return [b.main, b.left, b.right].compactMap { $0?.percent }.min()
    }

    var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    // MARK: EQ presets

    struct EqPreset: Hashable {
        let name: String
        let values: [Int]
    }

    struct SavedEqPreset: Codable, Hashable, Identifiable {
        var id: UUID
        var name: String
        var values: [Int]
    }

    /// The Bose app's headphone presets (cP3.a: bass, mid, treble), for 3-band bass/mid/treble EQs.
    func builtInEqPresets(for eq: EqualizerState) -> [EqPreset] {
        guard eq.presets.count <= 1, eq.bands.map(\.label) == ["Bass", "Mid", "Treble"] else { return [] }
        return [
            EqPreset(name: "Bass Boost", values: [8, 0, 0]),
            EqPreset(name: "Bass Reducer", values: [-8, -2, 0]),
            EqPreset(name: "Treble Boost", values: [0, 0, 6]),
            EqPreset(name: "Treble Reducer", values: [0, -2, -6]),
        ].map { EqPreset(name: $0.name, values: $0.values.map { min(max($0, eq.bandRange.lowerBound), eq.bandRange.upperBound) }) }
    }

    /// Saved presets, kept per band layout so they always fit the device.
    private(set) var savedEqPresetsByLayout: [String: [SavedEqPreset]] = [:]

    private func eqLayoutKey(_ eq: EqualizerState) -> String {
        (state?.vendor ?? "") + ":" + eq.bands.map(\.label).joined(separator: "|")
    }

    func savedEqPresets(for eq: EqualizerState) -> [SavedEqPreset] {
        savedEqPresetsByLayout[eqLayoutKey(eq)] ?? []
    }

    func saveEqPreset(name: String, eq: EqualizerState) {
        let key = eqLayoutKey(eq)
        var list = savedEqPresetsByLayout[key] ?? []
        let values = eq.bands.map(\.value)
        if let i = list.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            list[i].values = values
        } else {
            list.append(SavedEqPreset(id: UUID(), name: name, values: values))
        }
        savedEqPresetsByLayout[key] = list
        persistEqPresets()
    }

    func deleteEqPreset(id: UUID, eq: EqualizerState) {
        savedEqPresetsByLayout[eqLayoutKey(eq)]?.removeAll { $0.id == id }
        persistEqPresets()
    }

    /// Name of the preset matching the current bands, if any.
    func eqPresetName(for eq: EqualizerState) -> String? {
        let values = eq.bands.map(\.value)
        if values.allSatisfy({ $0 == 0 }) { return "Flat" }
        return builtInEqPresets(for: eq).first { $0.values == values }?.name
            ?? savedEqPresets(for: eq).first { $0.values == values }?.name
    }

    private func persistEqPresets() {
        if let data = try? JSONEncoder().encode(savedEqPresetsByLayout) { defaults.set(data, forKey: "eqPresets") }
    }

    private func loadEqPresets() {
        guard let data = defaults.data(forKey: "eqPresets"),
              let decoded = try? JSONDecoder().decode([String: [SavedEqPreset]].self, from: data) else { return }
        savedEqPresetsByLayout = decoded
    }

    /// Touch `loginItemRevision` so views refresh after toggling.
    var launchAtLoginBinding: Bool {
        _ = loginItemRevision
        return launchAtLogin
    }
}
