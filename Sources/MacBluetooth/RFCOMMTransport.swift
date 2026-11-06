import Foundation
import IOBluetooth
import HeadphoneKit

/// RFCOMM channel to a paired device, exposed as a HeadphoneKit `ByteTransport`.
@MainActor
public final class RFCOMMTransport: NSObject, ByteTransport {
    public var onReceive: (([UInt8]) -> Void)?
    public var onClose: ((Error?) -> Void)?

    private let device: IOBluetoothDevice
    private var channel: IOBluetoothRFCOMMChannel?
    private var openContinuation: CheckedContinuation<Void, Error>?
    private var closed = false

    init(device: IOBluetoothDevice) {
        self.device = device
    }

    /// Opens the RFCOMM channel. Only call this after the user asked to connect.
    public static func open(address: String, channelID: UInt8, timeout: Duration = .seconds(8)) async throws -> RFCOMMTransport {
        guard let device = IOBluetoothDevice(addressString: address) else {
            throw HeadphoneError.transport("Unknown Bluetooth device \(address)")
        }
        let t = RFCOMMTransport(device: device)
        try await t.open(channelID: channelID, timeout: timeout)
        return t
    }

    private func open(channelID: UInt8, timeout: Duration) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            openContinuation = cont
            var ch: IOBluetoothRFCOMMChannel?
            let status = device.openRFCOMMChannelAsync(&ch, withChannelID: channelID, delegate: self)
            channel = ch
            if status != kIOReturnSuccess {
                finishOpen(HeadphoneError.transport("Could not open RFCOMM channel \(channelID) (0x\(String(UInt32(bitPattern: status), radix: 16)))"))
                return
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                self?.finishOpen(HeadphoneError.timeout)
            }
        }
    }

    private func finishOpen(_ error: Error?) {
        guard let cont = openContinuation else { return }
        openContinuation = nil
        if let error {
            channel?.close()
            channel = nil
            cont.resume(throwing: error)
        } else {
            cont.resume()
        }
    }

    public func write(_ bytes: [UInt8]) throws {
        guard let channel, !closed else { throw HeadphoneError.disconnected }
        let mtu = max(Int(channel.getMTU()), 64)
        var offset = 0
        while offset < bytes.count {
            var chunk = Array(bytes[offset ..< min(offset + mtu, bytes.count)])
            let status = chunk.withUnsafeMutableBytes { buf in
                channel.writeSync(buf.baseAddress, length: UInt16(buf.count))
            }
            guard status == kIOReturnSuccess else {
                throw HeadphoneError.transport("RFCOMM write failed (0x\(String(UInt32(bitPattern: status), radix: 16)))")
            }
            offset += chunk.count
        }
    }

    public func close() {
        guard !closed else { return }
        closed = true
        channel?.setDelegate(nil)
        channel?.close()
        channel = nil
    }

    fileprivate func handleClosed() {
        guard !closed else { return }
        closed = true
        channel = nil
        finishOpen(HeadphoneError.disconnected)
        onClose?(HeadphoneError.disconnected)
    }
}

extension RFCOMMTransport: IOBluetoothRFCOMMChannelDelegate {
    nonisolated public func rfcommChannelOpenComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        MainActor.assumeIsolated {
            finishOpen(error == kIOReturnSuccess ? nil
                : HeadphoneError.transport("RFCOMM open failed (0x\(String(UInt32(bitPattern: error), radix: 16)))"))
        }
    }

    nonisolated public func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel!, data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int) {
        guard let dataPointer, dataLength > 0 else { return }
        let bytes = Array(UnsafeRawBufferPointer(start: dataPointer, count: dataLength))
        MainActor.assumeIsolated { onReceive?(bytes) }
    }

    nonisolated public func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        MainActor.assumeIsolated { handleClosed() }
    }
}
