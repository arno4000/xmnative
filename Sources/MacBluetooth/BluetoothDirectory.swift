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
        var seen = Set<String>()
        return devices.compactMap { d in
            // macOS sometimes lists the same device twice.
            guard let addr = d.addressString, seen.insert(addr.lowercased()).inserted else { return nil }
            if d.isConnected() { watchDisconnect(d) }
            return DeviceDescriptor(address: addr, name: d.name ?? addr, isConnected: d.isConnected(),
                                    rfcommServices: Self.services(of: d, candidates: candidateUUIDs),
                                    advertisedServices: Self.serviceClasses(of: d), vendorID: Self.vendorID(of: d))
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
                                rfcommServices: Self.services(of: d, candidates: candidateUUIDs),
                                advertisedServices: Self.serviceClasses(of: d), vendorID: Self.vendorID(of: d))
    }

    @objc public func sdpQueryComplete(_ device: IOBluetoothDevice, status: IOReturn) {
        finishSDP(device.addressString ?? "")
    }

    private func finishSDP(_ address: String) {
        sdpContinuations.removeValue(forKey: address)?.resume()
    }

    /// All service class UUIDs (SDP attribute 0x0001) in the cached records, expanded to 128 bit.
    /// macOS caches the attribute either as a sequence of UUIDs or as a single UUID.
    static func serviceClasses(of device: IOBluetoothDevice) -> Set<UUID> {
        var out = Set<UUID>()
        for record in (device.services as? [IOBluetoothSDPServiceRecord]) ?? [] {
            guard let element = record.getAttributeDataElement(0x0001) else { continue }
            var uuids: [IOBluetoothSDPUUID] = []
            if let u = element.getUUIDValue() { uuids.append(u) }
            for item in (element.getArrayValue() ?? []) as NSArray {
                if let u = (item as? IOBluetoothSDPDataElement)?.getUUIDValue() { uuids.append(u) }
            }
            for short in uuids {
                guard let full = short.getWithLength(16), full.length == 16 else { continue }
                let b = full.bytes.assumingMemoryBound(to: UInt8.self)
                out.insert(UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                                       b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15])))
            }
        }
        return out
    }

    /// Bluetooth SIG company ID from the cached Device ID (PnP Information, 0x1200) record, attribute 0x0201.
    static func vendorID(of device: IOBluetoothDevice) -> UInt16? {
        let pnp = IOBluetoothSDPUUID(uuid16: 0x1200)
        for record in (device.services as? [IOBluetoothSDPServiceRecord]) ?? [] where record.hasService(from: [pnp as Any]) {
            if let n = record.getAttributeDataElement(0x0201)?.getNumberValue() { return n.uint16Value }
        }
        return nil
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
