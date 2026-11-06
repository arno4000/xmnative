import Foundation
import HeadphoneKit

/// Reliable message link on top of a byte transport (stop-and-wait, 1-bit sequence),
/// mirroring lm0.c in the Sony app:
///  * we send DATA frames with our current sequence number and wait for an ACK,
///  * the ACK carries the *next* sequence number to use; an ACK with the current number is invalid,
///  * every received DATA frame is ACKed with `1 - seq`, and a repeated `seq` is a duplicate.
@MainActor
public final class MDRLink {
    public var onMessage: ((_ dataType: UInt8, _ payload: [UInt8]) -> Void)?
    public var onClose: ((Error?) -> Void)?
    /// Optional wire log for debugging (direction, bytes).
    public var log: ((String) -> Void)?

    public var ackTimeout: Duration = .milliseconds(1500)
    public var maxResends = 3

    private let transport: ByteTransport
    private var decoder = MDRFrameDecoder()
    private var sendSequence: UInt8 = 0
    private var lastReceivedSequence: UInt8? = nil
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var ackWaiter: (id: Int, cont: CheckedContinuation<Bool, Never>)?
    private var nextWaiterID = 0
    private(set) public var isClosed = false

    public init(transport: ByteTransport) {
        self.transport = transport
        transport.onReceive = { [weak self] bytes in self?.receive(bytes) }
        transport.onClose = { [weak self] error in self?.handleClose(error) }
    }

    public func close() {
        transport.close()
        handleClose(nil)
    }

    /// Sends one message and waits for the device's ACK (with resends, like the app).
    public func send(_ payload: [UInt8], type: MDRDataType = .dataMDR) async throws {
        if isClosed { throw HeadphoneError.disconnected }
        while busy { await withCheckedContinuation { waiters.append($0) } }
        busy = true
        defer {
            busy = false
            if !waiters.isEmpty { waiters.removeFirst().resume() }
        }

        let frame = MDRFraming.encode(MDRFrame(type, sequence: sendSequence, payload: payload))
        log?("→ \(hex(payload))")
        try write(frame)
        guard MDRDataType.requiresAck(type.rawValue) else { return }

        for attempt in 0 ... maxResends {
            if await waitForAck() { return }
            if isClosed { throw HeadphoneError.disconnected }
            if attempt < maxResends {
                log?("resend #\(attempt + 1)")
                try write(frame)
            }
        }
        throw HeadphoneError.timeout
    }

    // MARK: - Private

    private func write(_ bytes: [UInt8]) throws {
        do { try transport.write(bytes) } catch {
            handleClose(error)
            throw HeadphoneError.transport(error.localizedDescription)
        }
    }

    private func waitForAck() async -> Bool {
        nextWaiterID += 1
        let id = nextWaiterID
        let timeout = ackTimeout
        return await withCheckedContinuation { cont in
            ackWaiter = (id, cont)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                self?.resolveAck(id: id, acked: false)
            }
        }
    }

    private func resolveAck(id: Int?, acked: Bool) {
        guard let w = ackWaiter, id == nil || w.id == id else { return }
        ackWaiter = nil
        w.cont.resume(returning: acked)
    }

    private func receive(_ bytes: [UInt8]) {
        for result in decoder.feed(bytes) {
            guard case .success(let frame) = result else {
                log?("✗ bad frame: \(result)")
                continue
            }
            handle(frame)
        }
    }

    private func handle(_ frame: MDRFrame) {
        if frame.dataType == MDRDataType.ack.rawValue {
            if frame.sequence != sendSequence {
                sendSequence = frame.sequence
                resolveAck(id: nil, acked: true)
            } else {
                log?("ignoring invalid ACK seq \(frame.sequence)")
            }
            return
        }
        if MDRDataType.requiresAck(frame.dataType) {
            try? write(MDRFraming.ack(forReceivedSequence: frame.sequence))
            if lastReceivedSequence == frame.sequence {
                log?("duplicate seq \(frame.sequence), ignored")
                return
            }
            lastReceivedSequence = frame.sequence
        }
        log?("← \(hex(frame.payload))")
        onMessage?(frame.dataType, frame.payload)
    }

    private func handleClose(_ error: Error?) {
        guard !isClosed else { return }
        isClosed = true
        resolveAck(id: nil, acked: false)
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
        onClose?(error)
    }
}

func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
}
