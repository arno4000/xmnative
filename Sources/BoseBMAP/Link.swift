import Foundation
import HeadphoneKit

/// Request/response on top of a byte transport.
///
/// BMAP has no ACKs or sequence numbers. A request (Get / SetGet / Start) is answered with a packet for the
/// same function block and function, with operator Status, Result or Error (and sometimes Processing first).
/// The device also sends Status packets on its own when something changes on the headphones.
/// Like the Bose app, we send one request at a time and match replies by (block, function).
@MainActor
public final class BMAPLink {
    /// Every packet from the device, including replies to requests.
    public var onPacket: ((BMAPPacket) -> Void)?
    public var onClose: ((Error?) -> Void)?
    public var log: ((String) -> Void)?

    private let transport: ByteTransport
    private var decoder = BMAPPacketDecoder()
    private var waiters: [BMAPKey: [Waiter]] = [:]
    private var busy = false
    private var queue: [CheckedContinuation<Void, Never>] = []
    public private(set) var isClosed = false

    public init(transport: ByteTransport) {
        self.transport = transport
        transport.onReceive = { [weak self] bytes in self?.receive(bytes) }
        transport.onClose = { [weak self] error in self?.handleClose(error) }
    }

    public func close() {
        transport.close()
        handleClose(nil)
    }

    /// Sends without waiting for anything.
    public func send(_ packet: BMAPPacket) throws {
        if isClosed { throw HeadphoneError.disconnected }
        log?("→ \(packet)")
        do { try transport.write(packet.encoded()) } catch {
            handleClose(error)
            throw HeadphoneError.transport(error.localizedDescription)
        }
    }

    /// Sends `packet` and waits for the matching reply. Returns nil on timeout.
    ///
    /// Get / SetGet are answered by one Status. A Start that lists things (ModeConfig, GetAll, NowPlaying) is
    /// answered by any number of Status packets and then a Result, so those pass `until: [.result, .error]`.
    @discardableResult
    public func request(_ packet: BMAPPacket, until terminal: Set<BMAPOperator> = [.status, .result, .error],
                        timeout: Duration = .milliseconds(1500)) async -> BMAPPacket? {
        if isClosed { return nil }
        while busy { await withCheckedContinuation { queue.append($0) } }
        busy = true
        defer {
            busy = false
            if !queue.isEmpty { queue.removeFirst().resume() }
        }
        let waiter = Waiter(terminal: terminal)
        waiters[packet.key, default: []].append(waiter)
        defer { waiters[packet.key]?.removeAll { $0 === waiter } }
        do { try send(packet) } catch { return nil }
        let timer = Task { @MainActor in
            try? await Task.sleep(for: timeout)
            waiter.resolve(nil)
        }
        let reply = await waiter.wait()
        timer.cancel()
        return reply
    }

    private func receive(_ bytes: [UInt8]) {
        for packet in decoder.feed(bytes) {
            log?("← \(packet)")
            onPacket?(packet)
            guard let list = waiters[packet.key], let first = list.first, first.terminal.contains(packet.op) else { continue }
            waiters[packet.key]?.removeFirst()
            first.resolve(packet)
        }
    }

    private func handleClose(_ error: Error?) {
        guard !isClosed else { return }
        isClosed = true
        for list in waiters.values { list.forEach { $0.resolve(nil) } }
        waiters.removeAll()
        let pending = queue
        queue.removeAll()
        pending.forEach { $0.resume() }
        onClose?(error)
    }
}

@MainActor
private final class Waiter {
    let terminal: Set<BMAPOperator>
    init(terminal: Set<BMAPOperator>) { self.terminal = terminal }
    private var done = false
    private var value: BMAPPacket?
    private var continuation: CheckedContinuation<BMAPPacket?, Never>?

    func resolve(_ packet: BMAPPacket?) {
        guard !done else { return }
        done = true
        value = packet
        continuation?.resume(returning: packet)
        continuation = nil
    }

    func wait() async -> BMAPPacket? {
        if done { return value }
        return await withCheckedContinuation { c in
            if done { c.resume(returning: value) } else { continuation = c }
        }
    }
}
