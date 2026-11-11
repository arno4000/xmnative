import Foundation
import Testing
import HeadphoneKit
@testable import BoseBMAP

@MainActor
@Suite struct BoseDriverTests {
    private func connected() async throws -> (BoseDriver, SimulatedBoseDevice) {
        let device = SimulatedBoseDevice()
        let driver = BoseDriver(transport: device)
        try await driver.start()
        return (driver, device)
    }

    private func settle() async throws { try await Task.sleep(for: .milliseconds(60)) }

    @Test func handshakeFillsState() async throws {
        let (d, _) = try await connected()
        let s = d.state
        #expect(s.modelName == "Bose QuietComfort Ultra Headphones (2nd Gen)")
        #expect(s.firmwareVersion == "1.2.11")
        #expect(s.protocolInfo == "Bose BMAP 1.4.0")
        #expect(s.battery?.main == BatteryLevel(percent: 64, isCharging: false))
        #expect(s.playback?.volume == 12)
        #expect(s.playback?.maxVolume == 31)
        #expect(s.playback?.isPlaying == true)
        #expect(s.playback?.title == "Song")
        #expect(s.playback?.artist == "Artist")
        #expect(s.autoPowerOff?.current == .minutes(20))
        #expect(s.toggles.map(\.id) == ["voice-prompts", "multipoint", "wear-detect", "wear-pause", "wear-answer"])
        #expect(s.toggles.first { $0.id == "wear-pause" }?.isOn == true)
        #expect(s.toggles.first { $0.id == "wear-answer" }?.isOn == false)
    }

    @Test func listsModesSkippingEmptyUserSlots() async throws {
        let (d, _) = try await connected()
        let m = try #require(d.state.listeningModes)
        #expect(m.modes.map(\.name) == ["Quiet", "Aware", "Immersion", "Bus"])
        #expect(m.modes.map(\.kind) == [.quiet, .aware, .immersive, .custom])
        #expect(m.currentID == 0)
        #expect(m.noiseLevel == nil)        // Quiet can't be changed
        // Quiet has no spatial setting of its own, so the one outside of modes (SettingsConfig) shows.
        #expect(m.spatialAudio?.selectedID == 0)
        #expect(m.noiseLevelRange == 0 ... 10)
        #expect(m.modes.map(\.isUserMode) == [false, false, false, true])
        #expect(m.modes.allSatisfy { $0.isFavorite })
        #expect(m.modes[0].settings == nil)
        #expect(m.modes[1].settings == ListeningModeSettings(nameID: 2, activeSense: true))   // Aware: ActiveSense only
        #expect(m.modes[2].settings == ListeningModeSettings(nameID: 34, spatialAudio: 1))   // Immersion: spatial only
        #expect(m.modes[3].settings == ListeningModeSettings(nameID: 12, customName: "Bus", noiseLevel: 7, noiseControl: true,
                                                             activeSense: false, windBlock: false, spatialAudio: 0))
        #expect(m.freeSlots == 1)
        #expect(m.favoritesSupported)
        #expect(m.minimumFavorites == 1)
        #expect(m.nameOptions.map(\.title) == ["Commute", "Home", "Work", "Music", "Focus", "Flight"])
    }

    @Test func equalizerHasThreeBands() async throws {
        let (d, _) = try await connected()
        let eq = try #require(d.state.equalizer)
        #expect(eq.bands.map(\.label) == ["Bass", "Mid", "Treble"])
        #expect(eq.bands.map(\.value) == [3, 0, -2])
        #expect(eq.bandRange == -10 ... 10)
    }

    @Test func selectingAModeSendsCurrentModeStart() async throws {
        let (d, dev) = try await connected()
        await d.perform(.selectListeningMode(id: 2))
        #expect(dev.received.last?.encoded() == [0x1F, 0x03, 0x05, 0x02, 0x02, 0x00])
        #expect(d.state.listeningModes?.currentID == 2)
        // Immersion lets you choose the spatial audio type.
        #expect(d.state.listeningModes?.spatialAudio?.selectedID == 1)
        #expect(d.state.listeningModes?.noiseLevel == nil)
    }

    @Test func noiseLevelRewritesTheModeConfig() async throws {
        let (d, dev) = try await connected()
        await d.perform(.selectListeningMode(id: 3))
        #expect(d.state.listeningModes?.noiseLevel == 7)       // device 3 = strength 10 - 3
        await d.perform(.setNoiseLevel(4, isFinal: false))
        #expect(dev.received.last?.op == .start)   // nothing written while dragging
        await d.perform(.setNoiseLevel(4, isFinal: true))
        let sent = try #require(dev.received.last)
        var expected: [UInt8] = [0x03, 0x00, 0x0C] + Array("Bus".utf8) + [UInt8](repeating: 0, count: 29)
        expected += [0x06, 0x00, 0x00, 0x00, 0x01]   // cnc 10-4, autoCNC, spatial, wind, anc
        #expect(sent.encoded() == [0x1F, 0x06, 0x02, UInt8(expected.count)] + expected)
        #expect(dev.modes[3][42] == 6)
        #expect(d.state.listeningModes?.noiseLevel == 4)
    }

    @Test func spatialAudioForMutableMode() async throws {
        let (d, dev) = try await connected()
        await d.perform(.selectListeningMode(id: 2))
        await d.perform(.setChoice(id: "spatial", optionID: 2))
        #expect(dev.received.last?.payload[37] == 2)
        #expect(dev.modes[2][44] == 2)
        #expect(d.state.listeningModes?.spatialAudio?.selectedID == 2)
    }

    @Test func eqSendsOnlyChangedBands() async throws {
        let (d, dev) = try await connected()
        let before = dev.received.count
        await d.perform(.setEqBands([3, 5, -2]))
        let sent = dev.received[before...].map { $0.encoded() }
        #expect(sent == [[0x01, 0x07, 0x02, 0x02, 0x05, 0x01]])
        #expect(d.state.equalizer?.bands.map(\.value) == [3, 5, -2])
        await d.perform(.setEqBands([-12, 5, -2]))   // clamped to the device's range
        #expect(dev.received.last?.encoded() == [0x01, 0x07, 0x02, 0x02, 0xF6, 0x00])
    }

    @Test func togglesAndPower() async throws {
        let (d, dev) = try await connected()
        await d.perform(.setToggle(id: "wear-pause", isOn: false))
        #expect(dev.received.last?.encoded() == [0x01, 0x10, 0x02, 0x02, 0x01, 0x00])
        await d.perform(.setToggle(id: "voice-prompts", isOn: false))
        #expect(dev.received.last?.encoded() == [0x01, 0x03, 0x02, 0x01, 0x01])
        await d.perform(.setAutoPowerOff(.minutes(60)))
        #expect(dev.received.last?.encoded() == [0x01, 0x04, 0x02, 0x01, 0x3C])
        #expect(d.state.autoPowerOff?.current == .minutes(60))
    }

    @Test func playbackAndVolume() async throws {
        let (d, dev) = try await connected()
        await d.perform(.playback(.pause))
        #expect(dev.received.last?.encoded() == [0x05, 0x03, 0x05, 0x01, 0x02])
        #expect(d.state.playback?.isPlaying == false)
        await d.perform(.setVolume(20))
        #expect(dev.received.last?.encoded() == [0x05, 0x05, 0x02, 0x01, 0x14])
        #expect(d.state.playback?.volume == 20)
    }

    @Test func followsModeChangesOnTheHeadphones() async throws {
        let (d, dev) = try await connected()
        dev.pushCurrentMode(1)
        try await settle()
        #expect(d.state.listeningModes?.current?.name == "Aware")
    }

    @Test func registersForNotifications() async throws {
        let (_, dev) = try await connected()
        let n = try #require(dev.received.first { $0.block == 9 })
        // enable + blocks {0,1,2,4,5,9,31}
        #expect(n.encoded() == [0x09, 0x02, 0x02, 0x05, 0x01, 0x80, 0x00, 0x02, 0x37])
    }

    @Test func unsupportedFunctionsAreSkippedQuickly() async throws {
        let device = SimulatedBoseDevice()
        device.unsupported = [BMAPKey(block: 1, function: 7), BMAPKey(block: 31, function: 6)]
        let driver = BoseDriver(transport: device)
        let start = ContinuousClock.now
        try await driver.start()
        #expect(ContinuousClock.now - start < .seconds(2))
        #expect(driver.state.equalizer == nil)
        #expect(driver.state.listeningModes == nil)
    }

    @Test func refusedSettingIsReadBack() async throws {
        let (d, dev) = try await connected()
        dev.unsupported = [BMAPKey(block: 1, function: 10)]
        await d.perform(.setToggle(id: "multipoint", isOn: false))
        // SetGet refused → Get to restore the real value (also refused here, so the toggle stays as sent).
        #expect(dev.received.suffix(2).map(\.op) == [.setGet, .get])
    }
}

@MainActor
@Suite struct BoseModeManagementTests {
    private func connected(_ configure: (SimulatedBoseDevice) -> Void = { _ in }) async throws -> (BoseDriver, SimulatedBoseDevice) {
        let device = SimulatedBoseDevice()
        configure(device)
        let driver = BoseDriver(transport: device)
        try await driver.start()
        return (driver, device)
    }

    @Test func newModeTemplateUsesAnUnusedNameAndTheAppDefaults() async throws {
        let (d, _) = try await connected()
        let t = try #require(d.state.listeningModes?.newModeTemplate)
        // Music (12) is taken by "Bus", so the first free name is Commute (7). Level 5 like the Bose app.
        #expect(t == ListeningModeSettings(nameID: 7, noiseLevel: 5, noiseControl: true, activeSense: false, windBlock: false,
                                           spatialAudio: 0))
    }

    @Test func createsAModeInTheFreeSlot() async throws {
        let (d, dev) = try await connected()
        var t = try #require(d.state.listeningModes?.newModeTemplate)
        t.noiseLevel = 8
        t.windBlock = true
        let before = dev.received.count
        await d.perform(.createListeningMode(t))
        let sent = dev.received[before...].map { $0.encoded() }
        var config: [UInt8] = [0x04, 0x00, 0x07] + Array("Commute".utf8) + [UInt8](repeating: 0, count: 25)
        config += [0x02, 0x00, 0x00, 0x01, 0x01]   // cnc 10-8, auto, spatial, wind, anc
        #expect(sent == [
            [0x1F, 0x06, 0x02, UInt8(config.count)] + config,
            [0x1F, 0x08, 0x02, 0x02, 0x05, 0x1F],        // favorites: 5 modes, {0,1,2,3,4}
            [0x1F, 0x03, 0x05, 0x02, 0x04, 0x00],        // switch to it
        ])
        let m = try #require(d.state.listeningModes)
        #expect(m.current?.name == "Commute")
        #expect(m.current?.isFavorite == true)
        #expect(m.current?.settings?.noiseLevel == 8)
        #expect(m.freeSlots == 0)
        #expect(m.newModeTemplate == nil)
    }

    @Test func renamesAndRetunesAUserMode() async throws {
        let (d, dev) = try await connected()
        var s = try #require(d.state.listeningModes?.modes.first { $0.id == 3 }?.settings)
        s.nameID = 13
        s.customName = "Train"
        s.spatialAudio = 2
        await d.perform(.updateListeningMode(id: 3, s))
        let p = try #require(dev.received.last?.payload)
        #expect(Array(p[0 ... 2]) == [0x03, 0x00, 0x0D])
        #expect(BMAP.string(p[3 ..< 35]) == "Train")
        #expect(Array(p[35...]) == [0x03, 0x00, 0x02, 0x00, 0x01])
        #expect(d.state.listeningModes?.modes.first { $0.id == 3 }?.name == "Train")
    }

    @Test func boseModesKeepTheirNameAndOnlyChangeWhatIsAllowed() async throws {
        let (d, dev) = try await connected()
        // Try to change everything on Aware: only ActiveSense may change.
        let s = ListeningModeSettings(nameID: 13, customName: "X", noiseLevel: 0, noiseControl: false, activeSense: false,
                                      windBlock: true, spatialAudio: 2)
        await d.perform(.updateListeningMode(id: 1, s))
        let p = try #require(dev.received.last?.payload)
        #expect(Array(p[0 ... 2]) == [0x01, 0x00, 0x02])
        #expect(BMAP.string(p[3 ..< 35]) == "")
        #expect(Array(p[35...]) == [0x0A, 0x00, 0x00, 0x00, 0x01])   // cnc unchanged (Aware's own), auto off
    }

    @Test func deletingTheCurrentModeResetsItAndSwitchesAway() async throws {
        let (d, dev) = try await connected()
        await d.perform(.selectListeningMode(id: 3))
        let before = dev.received.count
        await d.perform(.deleteListeningMode(id: 3))
        let sent = dev.received[before...].map { $0.encoded() }
        #expect(sent == [
            [0x1F, 0x09, 0x05, 0x01, 0x03],              // AudioModes.Reset
            [0x1F, 0x06, 0x01, 0x01, 0x03],              // read the slot back
            [0x1F, 0x08, 0x02, 0x02, 0x05, 0x07],        // favorites without 3
            [0x1F, 0x03, 0x05, 0x02, 0x00, 0x00],        // switch to the first favorite
        ])
        let m = try #require(d.state.listeningModes)
        #expect(m.modes.map(\.name) == ["Quiet", "Aware", "Immersion"])
        #expect(m.currentID == 0)
        #expect(m.freeSlots == 2)
    }

    @Test func deleteFallsBackToWritingAnEmptyMode() async throws {
        let (d, dev) = try await connected { $0.resetSupported = false }
        await d.perform(.deleteListeningMode(id: 3))
        let write = try #require(dev.received.first { $0.block == 31 && $0.function == 6 && $0.op == .setGet })
        #expect(Array(write.payload[0 ... 2]) == [0x03, 0x00, 0x00])
        #expect(write.payload[3 ..< 35].allSatisfy { $0 == 0 })
        #expect(write.payload[35] == 5)
        #expect(d.state.listeningModes?.modes.contains { $0.id == 3 } == false)
    }

    @Test func boseModesCannotBeDeleted() async throws {
        let (d, dev) = try await connected()
        let before = dev.received.count
        await d.perform(.deleteListeningMode(id: 0))
        #expect(dev.received.count == before)
    }

    @Test func favoritesKeepTheMinimum() async throws {
        let (d, dev) = try await connected()
        await d.perform(.setListeningModeFavorite(id: 0, isFavorite: false))
        #expect(dev.received.last?.encoded() == [0x1F, 0x08, 0x02, 0x02, 0x05, 0x0E])
        await d.perform(.setListeningModeFavorite(id: 1, isFavorite: false))
        await d.perform(.setListeningModeFavorite(id: 2, isFavorite: false))
        let before = dev.received.count
        await d.perform(.setListeningModeFavorite(id: 3, isFavorite: false))   // last one stays
        #expect(dev.received.count == before)
        #expect(d.state.listeningModes?.favoriteCount == 1)
    }

    @Test func noiseControlOutsideOfModes() async throws {
        let (d, dev) = try await connected()
        #expect(d.state.listeningModes?.liveNoise == LiveNoiseControl(isOn: true, level: 8, range: 0 ... 10))
        await d.perform(.setLiveNoise(isOn: true, level: 10, isFinal: false))
        #expect(dev.received.last?.function != 10)              // not while dragging
        await d.perform(.setLiveNoise(isOn: true, level: 10, isFinal: true))
        #expect(dev.received.last?.encoded() == [0x1F, 0x0A, 0x02, 0x05, 0x00, 0x00, 0x00, 0x00, 0x01])
        await d.perform(.setLiveNoise(isOn: false, level: 10, isFinal: false))   // a toggle is written at once
        #expect(dev.received.last?.encoded() == [0x1F, 0x0A, 0x02, 0x05, 0x00, 0x00, 0x00, 0x00, 0x00])
        #expect(d.state.listeningModes?.liveNoise?.isOn == false)
    }

    @Test func immersiveAudioOutsideOfModesUsesSettingsConfig() async throws {
        let (d, dev) = try await connected()
        await d.perform(.setChoice(id: "spatial", optionID: 1))   // current mode Quiet has no own spatial setting
        #expect(dev.received.last?.encoded() == [0x1F, 0x0A, 0x02, 0x05, 0x02, 0x00, 0x01, 0x00, 0x01])
        #expect(d.state.listeningModes?.spatialAudio?.selectedID == 1)
    }
}

@Suite struct BoseParserTests {
    @Test func favoritesBitmapCountsFromTheLastByte() {
        // 10 modes → 2 bytes; mode 9 in the first byte, modes 0 and 3 in the last.
        #expect(BMAP.parse(BMAPPacket(31, 8, .status, [10, 0x02, 0x09])) == [.favorites([0, 3, 9])])
        #expect(BMAP.setFavorites([0, 3, 9], numberOfModes: 10).payload == [10, 0x02, 0x09])
    }

    @Test func namesBitmapCountsFromTheFirstByte() {
        // byte 0 bit 7 → 7, byte 1 bit 2 → 10, byte 4 bit 4 → 36; byte 4 bits 5-7 are ignored
        #expect(BMAP.parse(BMAPPacket(31, 11, .status, [0x80, 0x04, 0, 0, 0xF0])) == [.namesSupported([7, 10, 36])])
    }

    @Test func capabilitiesFlags() {
        let caps = BMAP.parse(BMAPPacket(31, 2, .status, [3, 2, 0, 0, 0, 0x10, 2]))
        #expect(caps == [.modeCapabilities(BoseModeCapabilities(boseModes: 3, userModes: 2, cncSupported: false,
            autoCNCSupported: false, spatialSupported: false, windSupported: false, favoritesSupported: true,
            ancSupported: false, minimumFavorites: 2))])
    }

    @Test func modeConfigFlagsAndUnknownValues() {
        var p = SimulatedBoseDevice.modeBytes(prompt: 1, flags: 0x1F)
        p[46] = 7   // not 0/1 → unknown
        guard case .modeConfig(let m)? = BMAP.parse(BMAPPacket(31, 6, .status, p)).first else { Issue.record("no config"); return }
        #expect(m.cncMutable && m.autoCNCMutable && m.spatialMutable && m.windMutable && m.ancMutable)
        #expect(m.windBlock == nil)
        #expect(m.ancToggle == true)
    }
}

@MainActor
@Suite struct BoseFactoryTests {
    let spp = BoseDriverFactory.sppService

    @Test func claimsSPPOnlyOnBoseDevices() {
        let f = BoseDriverFactory()
        let bose = DeviceDescriptor(address: "a", name: "Arno's headphones", isConnected: true, rfcommServices: [spp: 8],
                                    advertisedServices: [UUID(uuidString: "0000FEBE-0000-1000-8000-00805F9B34FB")!])
        #expect(f.preferredService(for: bose)?.channel == 8)
        let byName = DeviceDescriptor(address: "b", name: "Bose QC Ultra Headphones", isConnected: true, rfcommServices: [spp: 2])
        #expect(f.preferredService(for: byName)?.channel == 2)
        // Renamed headphones ("A") are still recognised by the Device ID vendor (0x009E = Bose).
        let renamed = DeviceDescriptor(address: "d", name: "A", isConnected: true, rfcommServices: [spp: 2], vendorID: 0x009E)
        #expect(f.preferredService(for: renamed)?.channel == 2)
        let decafade = DeviceDescriptor(address: "e", name: "A", isConnected: true, rfcommServices: [spp: 2],
                                        advertisedServices: [UUID(uuidString: "00000000-DECA-FADE-DECA-DEAFDECACAFF")!])
        #expect(f.preferredService(for: decafade)?.channel == 2)
        let other = DeviceDescriptor(address: "c", name: "WH-1000XM4", isConnected: true, rfcommServices: [spp: 3])
        #expect(f.preferredService(for: other) == nil)
    }
}
