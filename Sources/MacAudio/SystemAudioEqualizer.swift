import AudioToolbox
import CoreAudio
import Foundation

/// An output device as Core Audio describes it.
public struct AudioOutputDevice: Equatable, Sendable {
    public let id: AudioObjectID
    public let uid: String
    public let name: String
}

/// Sends everything the Mac plays through a `GraphicEQProcessor`, using a Core Audio process tap (macOS 14.2+):
///
/// 1. A private global stereo tap of all processes except this one, muted while tapped, so the original
///    sound stops and only the processed sound is heard.
/// 2. A private aggregate device made of the current default output device plus that tap. Its IOProc gets
///    the tapped audio as input and writes the processed audio to the real device.
///
/// Both objects belong to this process: if the app quits or crashes, macOS removes them and the sound plays
/// normally again. Follows changes of the default output device.
@MainActor
public final class SystemAudioEqualizer {
    public enum Status: Equatable, Sendable {
        case off
        case running(device: String)
        case failed(String)
    }

    public private(set) var status: Status = .off { didSet { if status != oldValue { onStatusChange?(status) } } }
    public var onStatusChange: ((Status) -> Void)?
    /// Called for each start with the new sample rate, to make a processor for it.
    public var makeProcessor: (@MainActor (Double) throws -> GraphicEQProcessor)?
    public private(set) var processor: GraphicEQProcessor?

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var device: AudioOutputDevice?
    private var listening = false
    private var deviceListeners: [(AudioObjectID, AudioObjectPropertyAddress)] = []
    private let ioQueue = DispatchQueue(label: "XMNative.MacEqualizer", qos: .userInteractive)
    private let listenerQueue = DispatchQueue.main
    private lazy var systemListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        MainActor.assumeIsolated { self?.outputChanged() }
    }
    private lazy var deviceListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        MainActor.assumeIsolated { self?.outputChanged() }
    }

    public init() {}

    public var isRunning: Bool { procID != nil }

    public func start() {
        guard !isRunning else { return }
        do {
            try startEngine()
            listenForDeviceChanges()
        } catch {
            teardown()
            status = .failed(error.localizedDescription)
        }
    }

    public func stop() {
        stopListening()
        teardown()
        status = .off
    }

    // MARK: Setup

    private func startEngine() throws {
        guard let output = try CA.defaultOutputDevice() else { throw MacAudioError("No sound output device") }
        guard let makeProcessor else { throw MacAudioError("No equalizer") }

        // Never tap our own output: that would feed the processed sound back into the EQ.
        let own = try CA.processObject(pid: getpid())
        guard own != kAudioObjectUnknown else { throw MacAudioError("Couldn't identify XMNative to Core Audio") }

        let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [own])
        tapDescription.uuid = UUID()
        tapDescription.name = "XMNative Equalizer"
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .mutedWhenTapped
        try check(AudioHardwareCreateProcessTap(tapDescription, &tapID), "Couldn't capture the Mac's sound")

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "XMNative Equalizer",
            kAudioAggregateDeviceUIDKey: "ch.siegenthaler.xmnative.eq.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: output.uid,
            kAudioAggregateDeviceClockDeviceKey: output.uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output.uid]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
                                               kAudioSubTapDriftCompensationKey: true]],
        ]
        try check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID),
                  "Couldn't route the sound through the equalizer")

        let rate = (try? CA.sampleRate(aggregateID)) ?? (try? CA.sampleRate(output.id)) ?? 48000
        let processor = try makeProcessor(rate)
        self.processor = processor

        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) { _, input, _, output, _ in
            let frames = Int(UnsafeMutableAudioBufferListPointer(output).first.map { $0.mDataByteSize / 4 / max($0.mNumberChannels, 1) } ?? 0)
            processor.process(input: input, output: output, frames: frames)
        }, "Couldn't start the equalizer")
        try check(AudioDeviceStart(aggregateID, procID), "Couldn't start the equalizer")

        device = output
        status = .running(device: output.name)
    }

    private func teardown() {
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
        processor = nil
        removeDeviceListeners()
        device = nil
    }

    // MARK: Device changes

    private func listenForDeviceChanges() {
        if !listening {
            var address = CA.address(kAudioHardwarePropertyDefaultOutputDevice)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, listenerQueue, systemListener)
            listening = true
        }
        removeDeviceListeners()
        guard let device else { return }
        for selector in [kAudioDevicePropertyNominalSampleRate, kAudioDevicePropertyDeviceIsAlive] {
            var address = CA.address(selector)
            if AudioObjectAddPropertyListenerBlock(device.id, &address, listenerQueue, deviceListener) == noErr {
                deviceListeners.append((device.id, address))
            }
        }
    }

    private func removeDeviceListeners() {
        for (id, address) in deviceListeners {
            var a = address
            AudioObjectRemovePropertyListenerBlock(id, &a, listenerQueue, deviceListener)
        }
        deviceListeners = []
    }

    private func stopListening() {
        guard listening else { return }
        var address = CA.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, listenerQueue, systemListener)
        listening = false
    }

    /// The output device changed, went away or changed its sample rate: build everything again.
    private func outputChanged() {
        guard listening else { return }
        let current = try? CA.defaultOutputDevice()
        if let device, current == device, isRunning, (try? CA.sampleRate(aggregateID)) == processor?.sampleRate,
           CA.isAlive(device.id) {
            return
        }
        teardown()
        do {
            try startEngine()
            listenForDeviceChanges()
        } catch {
            teardown()
            status = .failed(error.localizedDescription)
        }
    }
}

// MARK: - Core Audio helpers

enum CA {
    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func value<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, initial: T) throws -> T {
        var address = address(selector)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value), "Core Audio property \(selector)")
        return value
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value), "Core Audio property \(selector)")
        return value?.takeRetainedValue() as String? ?? ""
    }

    static func defaultOutputDevice() throws -> AudioOutputDevice? {
        let id = try value(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice,
                           initial: AudioObjectID(kAudioObjectUnknown))
        guard id != kAudioObjectUnknown else { return nil }
        return AudioOutputDevice(id: id, uid: try string(id, kAudioDevicePropertyDeviceUID),
                                 name: (try? string(id, kAudioObjectPropertyName)) ?? "Output")
    }

    static func processObject(pid: pid_t) throws -> AudioObjectID {
        var address = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                             UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object),
                  "Couldn't identify XMNative to Core Audio")
        return object
    }

    static func sampleRate(_ device: AudioObjectID) throws -> Double {
        try value(device, kAudioDevicePropertyNominalSampleRate, initial: Float64(0))
    }

    static func isAlive(_ device: AudioObjectID) -> Bool {
        ((try? value(device, kAudioDevicePropertyDeviceIsAlive, initial: UInt32(0))) ?? 0) != 0
    }
}
