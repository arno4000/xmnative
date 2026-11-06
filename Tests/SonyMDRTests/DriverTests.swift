import Testing
import HeadphoneKit
@testable import SonyMDR

/// End-to-end: driver ↔ MDR link ↔ frames ↔ simulated WH-1000XM4. No Bluetooth.
@MainActor
@Suite struct DriverTests {
    @Test func handshakeDiscoversXM4Features() async throws {
        let sim = SimulatedSonyV1Device()
        let driver = SonyDriver(transport: sim, table: .one)
        try await driver.start()
        let s = driver.state

        #expect(s.modelName == "WH-1000XM4")
        #expect(s.firmwareVersion == "2.6.1")
        #expect(s.battery?.main == BatteryLevel(percent: 70, isCharging: false))
        #expect(s.codec == .ldac)
        #expect(s.noiseControl?.mode == .noiseCancelling)
        #expect(s.noiseControl?.supportedModes == [.noiseCancelling, .windReduction, .ambient, .off])
        #expect(s.noiseControl?.ambientLevelRange == 1 ... 20)
        #expect(s.equalizer?.bands.map(\.label) == ["Clear Bass", "400", "1k", "2.5k", "6.3k", "16k"])
        #expect(s.equalizer?.bandRange == -10 ... 10)
        #expect(s.equalizer?.activePreset?.name == "Bright")
        #expect(s.speakToChat == SpeakToChatState(enabled: false, sensitivity: .auto, voiceFocus: true, timeout: .standard))
        #expect(s.autoPowerOff?.current == .disabled)
        #expect(s.upscaling == UpscalingState(name: "DSEE Extreme", enabled: true))
        #expect(s.connectionPriority?.current == .soundQuality)
        #expect(s.toggles.map(\.title) == ["Touch sensor control", "Connect to 2 devices", "Pause when taken off", "Voice guidance"])
        let allTogglesOn = s.toggles.allSatisfy(\.isOn)
        #expect(allTogglesOn)
        #expect(s.buttons == [ButtonAssignment(id: 0, title: "Custom button", options: [
            ButtonFunction(id: 0x00, title: "Ambient sound control"),
            ButtonFunction(id: 0x31, title: "Google Assistant"),
            ButtonFunction(id: 0x32, title: "Amazon Alexa"),
        ], selectedID: 0)])
        #expect(s.playback == PlaybackState(isPlaying: true, volume: 15, maxVolume: 30, title: "Teardrop", artist: "Massive Attack"))
    }

    @Test func newFeaturesReachTheDevice() async throws {
        let sim = SimulatedSonyV1Device()
        let driver = SonyDriver(transport: sim, table: .one)
        try await driver.start()

        await driver.perform(.setToggle(id: "wear-pause", isOn: false))
        #expect(sim.received.last == [0xF8, 0x03, 0x00, 0x00])
        await driver.perform(.setToggle(id: "voice-guidance", isOn: false))
        #expect(sim.received.last == [0x48, 0x01, 0x01, 0x00])
        await driver.perform(.setButton(id: 0, functionID: 0x31))
        #expect(sim.received.last == [0xF8, 0x06, 0x01, 0x31])
        await driver.perform(.playback(.pause))
        #expect(sim.received.last == [0xA4, 0x01, 0x00, 0x01])
        await driver.perform(.setVolume(22))
        #expect(sim.received.last == [0xA8, 0x01, 0x20, 22])
        try await Task.sleep(for: .milliseconds(150))

        let s = driver.state
        #expect(s.toggles.first { $0.id == "wear-pause" }?.isOn == false)
        #expect(s.toggles.first { $0.id == "voice-guidance" }?.isOn == false)
        #expect(s.buttons.first?.selectedID == 0x31)
        #expect(s.playback?.isPlaying == false)
        #expect(s.playback?.volume == 22)
    }

    @Test func actionsReachTheDeviceAndNotificationsComeBack() async throws {
        let sim = SimulatedSonyV1Device()
        let driver = SonyDriver(transport: sim, table: .one)
        try await driver.start()

        await driver.perform(.setNoise(mode: .ambient, ambientLevel: 15, voiceFocus: true, isFinal: true))
        #expect(sim.received.last == [0x68, 0x02, 0x11, 0x02, 0x00, 0x01, 0x01, 0x0F])

        await driver.perform(.setEqBands([0, 2, -2, 0, 0, 10]))
        #expect(sim.received.last == [0x58, 0x01, 0xFF, 0x06, 10, 12, 8, 10, 10, 20])

        await driver.perform(.setSpeakToChat(enabled: true))
        await driver.perform(.setToggle(id: "gs-209", isOn: false))
        try await Task.sleep(for: .milliseconds(150))   // let notifications arrive

        let s = driver.state
        #expect(s.noiseControl?.mode == .ambient)
        #expect(s.noiseControl?.ambientLevel == 15)
        #expect(s.equalizer?.activePresetID == 0xA0)
        #expect(s.equalizer?.bands.map(\.value) == [0, 2, -2, 0, 0, 10])
        #expect(s.speakToChat?.enabled == true)
        #expect(s.toggles.first { $0.id == "gs-209" }?.isOn == false)
    }

    @Test func linkTimesOutWhenNobodyAcks() async {
        final class Silent: ByteTransport {
            var onReceive: (([UInt8]) -> Void)?
            var onClose: ((Error?) -> Void)?
            var writes = 0
            func write(_ bytes: [UInt8]) throws { writes += 1 }
            func close() {}
        }
        let t = Silent()
        let link = MDRLink(transport: t)
        link.ackTimeout = .milliseconds(20)
        link.maxResends = 2
        await #expect(throws: HeadphoneError.self) { try await link.send([0x00, 0x00]) }
        #expect(t.writes == 3)   // first try + 2 resends, like lm0.c
    }
}
