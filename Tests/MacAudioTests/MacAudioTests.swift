import AudioToolbox
import Foundation
import Testing
@testable import MacAudio

// MARK: - Helpers

/// A buffer list with the given channel counts per buffer, interleaved within each buffer.
final class TestBuffers {
    let list: UnsafeMutableAudioBufferListPointer
    let channels: [Int]
    let frames: Int

    init(channels: [Int], frames: Int) {
        self.channels = channels
        self.frames = frames
        list = AudioBufferList.allocate(maximumBuffers: channels.count)
        for (i, c) in channels.enumerated() {
            let data = UnsafeMutablePointer<Float>.allocate(capacity: c * frames)
            data.initialize(repeating: 0, count: c * frames)
            list[i] = AudioBuffer(mNumberChannels: UInt32(c), mDataByteSize: UInt32(c * frames * 4), mData: data)
        }
    }

    deinit {
        for b in list { b.mData?.deallocate() }
        list.unsafeMutablePointer.deallocate()
    }

    func set(buffer: Int, channel: Int, _ value: (Int) -> Float) {
        let d = list[buffer].mData!.assumingMemoryBound(to: Float.self)
        let stride = channels[buffer]
        for f in 0 ..< frames { d[f * stride + channel] = value(f) }
    }

    func samples(buffer: Int, channel: Int) -> [Float] {
        let d = list[buffer].mData!.assumingMemoryBound(to: Float.self)
        let stride = channels[buffer]
        return (0 ..< frames).map { d[$0 * stride + channel] }
    }
}

func sine(_ hz: Double, rate: Double = 48000, amplitude: Float = 0.25) -> (Int) -> Float {
    { f in amplitude * Float(sin(2 * .pi * hz * Double(f) / rate)) }
}

func rms(_ x: ArraySlice<Float>) -> Double {
    sqrt(x.reduce(0) { $0 + Double($1) * Double($1) } / Double(x.count))
}

func db(_ ratio: Double) -> Double { 20 * log10(ratio) }

/// Gain in dB the processor applies to a sine, measured after the filters settle.
func measuredGain(layout: MacEqLayout, gains: [Int], preamp: Int = 0, hz: Double) throws -> Double {
    let p = try GraphicEQProcessor(layout: layout, sampleRate: 48000, maxFrames: 512)
    p.setGains(gains)
    p.setPreamp(preamp)
    let frames = 48000
    let input = TestBuffers(channels: [2], frames: frames)
    input.set(buffer: 0, channel: 0, sine(hz))
    input.set(buffer: 0, channel: 1, sine(hz))
    let output = TestBuffers(channels: [2], frames: frames)
    p.process(input: input.list.unsafePointer, output: output.list.unsafeMutablePointer, frames: frames)
    let settle = frames / 2
    let inL = input.samples(buffer: 0, channel: 0)[settle...]
    let outL = output.samples(buffer: 0, channel: 0)[settle...]
    let outR = output.samples(buffer: 0, channel: 1)[settle...]
    #expect(abs(rms(outL) - rms(outR)) < 1e-4)
    return db(rms(outL) / rms(inL))
}

// MARK: - Curves

@Suite struct EqCurveTests {
    @Test func layoutsMatchTheAudioUnit() throws {
        for layout in MacEqLayout.allCases {
            #expect(layout.frequencies.count == layout.bandCount)
            #expect(layout.labels.count == layout.bandCount)
            #expect(layout.frequencies == layout.frequencies.sorted())
        }
        // The audio unit's parameter names carry the centre frequencies.
        for layout in MacEqLayout.allCases {
            let p = try GraphicEQProcessor(layout: layout, sampleRate: 48000)
            let names = try parameterNames(of: p)
            #expect(names.count == layout.bandCount)
            for (name, hz) in zip(names, layout.frequencies) {
                let value = Double(name.replacingOccurrences(of: " Hz", with: "")) ?? -1
                #expect(value == hz, "\(name) vs \(hz)")
            }
        }
    }

    @Test func resamplingKeepsTheShape() {
        let ten = MacEqPreset.builtIn.first { $0.name == "Bass Boost" }!.gains
        let thirtyOne = EqCurve.convert(ten, from: .ten, to: .thirtyOne)
        #expect(thirtyOne.count == 31)
        #expect(thirtyOne.first == 6)          // 20 Hz: below the first band, takes its value
        #expect(thirtyOne.last == 0)
        #expect(thirtyOne[MacEqLayout.thirtyOne.frequencies.firstIndex(of: 125)!] == 4)   // ~128 Hz band
        let back = EqCurve.convert(thirtyOne, from: .thirtyOne, to: .ten)
        #expect(zip(back, ten).allSatisfy { abs($0 - $1) <= 1 })
        #expect(EqCurve.convert(ten, from: .ten, to: .ten) == ten)
    }

    @Test func builtInPresetsAreValid() {
        #expect(Set(MacEqPreset.builtIn.map(\.name)).count == MacEqPreset.builtIn.count)
        for p in MacEqPreset.builtIn {
            #expect(p.gains.count == p.layout.bandCount)
            #expect(p.gains.allSatisfy(EqCurve.gainRange.contains))
            #expect(p.gains(for: .thirtyOne).count == 31)
        }
        #expect(MacEqPreset.builtIn.first?.gains == MacEqPreset.flat(.ten))
    }

    @Test func headroomTakesOffTheLargestBoost() {
        #expect(EqCurve.headroom(for: [6, 0, -3], preamp: 0, preventClipping: true) == -6)
        #expect(EqCurve.headroom(for: [6, 0, -3], preamp: 2, preventClipping: false) == 2)
        #expect(EqCurve.headroom(for: [-6, -2], preamp: 0, preventClipping: true) == 0)
    }

    private func parameterNames(of p: GraphicEQProcessor) throws -> [String] {
        let unit = Mirror(reflecting: p).children.first { $0.label == "unit" }!.value as! AudioUnit
        var size: UInt32 = 0
        AudioUnitGetPropertyInfo(unit, kAudioUnitProperty_ParameterList, kAudioUnitScope_Global, 0, &size, nil)
        var ids = [AudioUnitParameterID](repeating: 0, count: Int(size) / 4)
        AudioUnitGetProperty(unit, kAudioUnitProperty_ParameterList, kAudioUnitScope_Global, 0, &ids, &size)
        return ids.filter { $0 < 10000 }.map { id in
            var info = AudioUnitParameterInfo()
            var s = UInt32(MemoryLayout<AudioUnitParameterInfo>.size)
            AudioUnitGetProperty(unit, kAudioUnitProperty_ParameterInfo, kAudioUnitScope_Global, id, &info, &s)
            return info.cfNameString?.takeUnretainedValue() as String? ?? ""
        }
    }
}

// MARK: - Processing

@Suite struct GraphicEQProcessorTests {
    @Test func flatPassesThrough() throws {
        let g = try measuredGain(layout: .ten, gains: MacEqPreset.flat(.ten), hz: 1000)
        #expect(abs(g) < 0.3)
    }

    @Test func boostingABandRaisesThatFrequency() throws {
        var gains = MacEqPreset.flat(.ten)
        gains[5] = 12   // 1 kHz
        let at1k = try measuredGain(layout: .ten, gains: gains, hz: 1024)
        #expect(abs(at1k - 12) < 1.5, "\(at1k) dB")
        let at64 = try measuredGain(layout: .ten, gains: gains, hz: 64)
        #expect(abs(at64) < 1, "\(at64) dB")
    }

    @Test func cuttingWorksIn31Bands() throws {
        var gains = MacEqPreset.flat(.thirtyOne)
        gains[MacEqLayout.thirtyOne.frequencies.firstIndex(of: 100)!] = -12
        let at100 = try measuredGain(layout: .thirtyOne, gains: gains, hz: 100)
        #expect(at100 < -9, "\(at100) dB")
        let at4k = try measuredGain(layout: .thirtyOne, gains: gains, hz: 4000)
        #expect(abs(at4k) < 1, "\(at4k) dB")
    }

    @Test func preampScalesTheInput() throws {
        let g = try measuredGain(layout: .ten, gains: MacEqPreset.flat(.ten), preamp: -6, hz: 1000)
        #expect(abs(g + 6) < 0.3, "\(g) dB")
    }

    @Test func takesTheSignalFromTheLastBuffersAndFillsEveryOutputLayout() throws {
        let p = try GraphicEQProcessor(layout: .ten, sampleRate: 48000, maxFrames: 256)
        let frames = 4096   // more than maxFrames: processed in pieces
        // A device input buffer first, then the tap as two non-interleaved buffers.
        let input = TestBuffers(channels: [1, 1, 1], frames: frames)
        input.set(buffer: 0, channel: 0) { _ in 0.9 }
        input.set(buffer: 1, channel: 0, sine(1000))
        input.set(buffer: 2, channel: 0, sine(1000, amplitude: 0.1))

        let stereo = TestBuffers(channels: [2], frames: frames)
        p.process(input: input.list.unsafePointer, output: stereo.list.unsafeMutablePointer, frames: frames)
        let l = stereo.samples(buffer: 0, channel: 0)[2048...]
        let r = stereo.samples(buffer: 0, channel: 1)[2048...]
        #expect(abs(db(rms(l) / rms(input.samples(buffer: 1, channel: 0)[2048...]))) < 0.3)
        #expect(abs(db(rms(r) / rms(input.samples(buffer: 2, channel: 0)[2048...]))) < 0.3)

        let mono = TestBuffers(channels: [1], frames: frames)
        p.process(input: input.list.unsafePointer, output: mono.list.unsafeMutablePointer, frames: frames)
        let m = mono.samples(buffer: 0, channel: 0)[2048...]
        #expect(abs(db(rms(m) / (0.5 * (0.25 + 0.1) / sqrt(2)))) < 0.5)

        let surround = TestBuffers(channels: [4], frames: frames)
        p.process(input: input.list.unsafePointer, output: surround.list.unsafeMutablePointer, frames: frames)
        #expect(rms(surround.samples(buffer: 0, channel: 0)[2048...]) > 0.1)
        #expect(surround.samples(buffer: 0, channel: 2).allSatisfy { $0 == 0 })
        #expect(surround.samples(buffer: 0, channel: 3).allSatisfy { $0 == 0 })
    }

    @Test func monoInputGoesToBothSides() throws {
        let p = try GraphicEQProcessor(layout: .ten, sampleRate: 44100)
        let frames = 2048
        let input = TestBuffers(channels: [1], frames: frames)
        input.set(buffer: 0, channel: 0, sine(500, rate: 44100))
        let out = TestBuffers(channels: [1, 1], frames: frames)
        p.process(input: input.list.unsafePointer, output: out.list.unsafeMutablePointer, frames: frames)
        #expect(out.samples(buffer: 0, channel: 0) == out.samples(buffer: 1, channel: 0))
        #expect(rms(out.samples(buffer: 0, channel: 0)[1024...]) > 0.1)
    }

    @Test func noInputIsSilence() throws {
        let p = try GraphicEQProcessor(layout: .ten, sampleRate: 48000)
        let out = TestBuffers(channels: [2], frames: 128)
        out.set(buffer: 0, channel: 0) { _ in 1 }
        p.process(input: nil, output: out.list.unsafeMutablePointer, frames: 128)
        #expect(out.samples(buffer: 0, channel: 0).allSatisfy { $0 == 0 })
    }
}
