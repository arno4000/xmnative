import Foundation
import IOBluetooth
import HeadphoneKit

/// Lists paired devices and resolves RFCOMM service channels.
///
/// `pairedDevices` only reads what macOS already cached (no radio traffic).
/// `refreshServices` performs a live SDP query and should only run on user request.
@MainActor
public final class BluetoothDirectory: NSObject {
    /// Called when a paired device connects or disconnects.
    public var onChange: (() -> Void)?

    private var connectNotification: IOBluetoothUserNotification?
    private var disconnectNotifications: [String: IOBluetoothUserNotification] = [:]
    private var sdpContinuations: [String: CheckedContinuation<Void, Never>] = [:]

    public override init() {
        super.init()
    }

    public func startObserving() {
        guard connectNotification == nil else { return }
        connectNotification = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(deviceConnected(_:device:)))
    }

    @objc private func deviceConnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        watchDisconnect(device)
        onChange?()
    }

    @objc private func deviceDisconnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        disconnectNotifications.removeValue(forKey: device.addressString ?? "")?.unregister()
        onChange?()
    }

    private func watchDisconnect(_ device: IOBluetoothDevice) {
        guard let addr = device.addressString, disconnectNotifications[addr] == nil else { return }
        disconnectNotifications[addr] = device.register(forDisconnectNotification: self, selector: #selector(deviceDisconnected(_:device:)))
    }

    /// Paired devices with whatever RFCOMM services (from `candidateUUIDs`) are in the SDP cache.
    public func pairedDevices(candidateUUIDs: [UUID]) -> [DeviceDescriptor] {
        let devices = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        return devices.compactMap { d in
            guard let addr = d.addressString else { return nil }
            if d.isConnected() { watchDisconnect(d) }
            return DeviceDescriptor(address: addr, name: d.name ?? addr, isConnected: d.isConnected(),
                                    rfcommServices: Self.services(of: d, candidates: candidateUUIDs))
        }
        .sorted { ($0.isConnected ? 0 : 1, $0.name) < ($1.isConnected ? 0 : 1, $1.name) }
    }

    /// Live SDP query (touches the radio). Returns the refreshed descriptor.
    public func refreshServices(address: String, candidateUUIDs: [UUID], timeout: Duration = .seconds(6)) async -> DeviceDescriptor? {
        guard let d = IOBluetoothDevice(addressString: address) else { return nil }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            sdpContinuations[address] = cont
            let status = d.performSDPQuery(self)
            if status != kIOReturnSuccess { finishSDP(address) }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                self?.finishSDP(address)
            }
        }
        return DeviceDescriptor(address: address, name: d.name ?? address, isConnected: d.isConnected(),
                                rfcommServices: Self.services(of: d, candidates: candidateUUIDs))
    }

    @objc public func sdpQueryComplete(_ device: IOBluetoothDevice, status: IOReturn) {
        finishSDP(device.addressString ?? "")
    }

    private func finishSDP(_ address: String) {
        sdpContinuations.removeValue(forKey: address)?.resume()
    }

    static func services(of device: IOBluetoothDevice, candidates: [UUID]) -> [UUID: UInt8] {
        var out: [UUID: UInt8] = [:]
        for uuid in candidates {
            var u = uuid.uuid
            let sdpUUID = withUnsafeBytes(of: &u) { IOBluetoothSDPUUID(bytes: $0.baseAddress, length: 16) }
            guard let record = device.getServiceRecord(for: sdpUUID) else { continue }
            var channel: BluetoothRFCOMMChannelID = 0
            if record.getRFCOMMChannelID(&channel) == kIOReturnSuccess {
                out[uuid] = channel
            }
        }
        return out
    }
}
