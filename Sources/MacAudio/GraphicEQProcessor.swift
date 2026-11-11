import AudioToolbox
import Foundation
import Synchronization

public struct MacAudioError: LocalizedError, Equatable {
    public let step: String
    public let status: OSStatus

    public init(_ step: String, _ status: OSStatus = 0) {
        self.step = step
        self.status = status
    }

    public var errorDescription: String? {
        status == 0 ? step : "\(step) (error \(status))"
    }
}

@discardableResult
func check(_ status: OSStatus, _ step: String) throws -> OSStatus {
    guard status == noErr else { throw MacAudioError(step, status) }
    return status
}

/// Runs stereo audio through Apple's AUGraphicEQ. `process` is real-time safe: no allocation, no locks.
///
/// Input and output buffer lists may be interleaved or not and have any channel count. The processor
/// works in stereo: it reads the first two channels of the input (mono is doubled) and writes left/right
/// to the first two output channels, both averaged for a mono output, silence for any further channels.
public final class GraphicEQProcessor: @unchecked Sendable {
    public let layout: MacEqLayout
    public let sampleRate: Double
    /// Frames rendered through the audio unit at once. Longer buffers are processed in pieces.
    public let maxFrames: Int

    private let unit: AudioUnit
    private let inL: UnsafeMutablePointer<Float>
    private let inR: UnsafeMutablePointer<Float>
    private let outL: UnsafeMutablePointer<Float>
    private let outR: UnsafeMutablePointer<Float>
    private let renderList: UnsafeMutableAudioBufferListPointer
    private var sampleTime: Float64 = 0
    private let preampGain = Atomic<UInt32>(Float(1).bitPattern)

    public init(layout: MacEqLayout, sampleRate: Double, maxFrames: Int = 1024) throws {
        precondition(sampleRate > 0 && maxFrames > 0)
        self.layout = layout
        self.sampleRate = sampleRate
        self.maxFrames = maxFrames

        var desc = AudioComponentDescription(componentType: kAudioUnitType_Effect,
                                             componentSubType: kAudioUnitSubType_GraphicEQ,
                                             componentManufacturer: kAudioUnitManufacturer_Apple,
                                             componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &desc) else { throw MacAudioError("Apple's graphic EQ is missing") }
        var instance: AudioUnit?
        try check(AudioComponentInstanceNew(component, &instance), "Couldn't load Apple's graphic EQ")
        unit = instance!

        inL = .allocate(capacity: maxFrames)
        inR = .allocate(capacity: maxFrames)
        outL = .allocate(capacity: maxFrames)
        outR = .allocate(capacity: maxFrames)
        for p in [inL, inR, outL, outR] { p.initialize(repeating: 0, count: maxFrames) }
        renderList = AudioBufferList.allocate(maximumBuffers: 2)

        do {
            try configure()
        } catch {
            AudioComponentInstanceDispose(unit)
            free()
            throw error
        }
    }

    deinit {
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        free()
    }

    private func free() {
        for p in [inL, inR, outL, outR] { p.deallocate() }
        renderList.unsafeMutablePointer.deallocate()
    }

    private func configure() throws {
        var format = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2,
            mBitsPerChannel: 32, mReserved: 0)
        let formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        for scope in [kAudioUnitScope_Input, kAudioUnitScope_Output] {
            try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, scope, 0, &format, formatSize),
                      "Couldn't set the EQ's audio format")
        }
        var frames = UInt32(maxFrames)
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
                                       &frames, UInt32(MemoryLayout<UInt32>.size)), "Couldn't set the EQ's buffer size")
        var callback = AURenderCallbackStruct(inputProc: graphicEQInput,
                                              inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                                       &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)),
                  "Couldn't connect the EQ")
        // The band count has to be chosen before the unit is initialized.
        try check(AudioUnitSetParameter(unit, AudioUnitParameterID(kGraphicEQParam_NumberOfBands), kAudioUnitScope_Global,
                                        0, layout.parameterValue, 0), "Couldn't set the number of bands")
        try check(AudioUnitInitialize(unit), "Couldn't start the EQ")
    }

    // MARK: Settings (any thread)

    /// Gains in dB, one per band of `layout`.
    public func setGains(_ gains: [Int]) {
        for (band, db) in gains.prefix(layout.bandCount).enumerated() { setGain(db, band: band) }
    }

    public func setGain(_ db: Int, band: Int) {
        guard band >= 0, band < layout.bandCount else { return }
        AudioUnitSetParameter(unit, AudioUnitParameterID(band), kAudioUnitScope_Global, 0, Float(db), 0)
    }

    public func gain(band: Int) -> Float {
        var value: AudioUnitParameterValue = 0
        AudioUnitGetParameter(unit, AudioUnitParameterID(band), kAudioUnitScope_Global, 0, &value)
        return value
    }

    /// Gain before the EQ, in dB.
    public func setPreamp(_ db: Int) {
        preampGain.store(Float(pow(10, Double(db) / 20)).bitPattern, ordering: .relaxed)
    }

    // MARK: Processing (real-time thread)

    fileprivate func fillInput(_ ioData: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
        let list = UnsafeMutableAudioBufferListPointer(ioData)
        for i in 0 ..< list.count {
            let source = i == 0 ? inL : inR
            if let d = list[i].mData {
                d.assumingMemoryBound(to: Float.self).update(from: source, count: frames)
            } else {
                list[i].mData = UnsafeMutableRawPointer(source)
            }
            list[i].mDataByteSize = UInt32(frames * 4)
        }
    }

    /// Processes `frames` frames from `input` into `output`. `input` may hold more buffers than the
    /// signal: the signal is taken from the last buffers (an aggregate device lists its taps last).
    public func process(input: UnsafePointer<AudioBufferList>?, output: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
        let out = UnsafeMutableAudioBufferListPointer(output)
        guard let input else { Self.silence(out, frames: frames); return }
        let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let source = Self.stereoSource(inList)
        let gain = Float(bitPattern: preampGain.load(ordering: .relaxed))

        var done = 0
        while done < frames {
            let n = min(maxFrames, frames - done)
            Self.read(inList, source, offset: done, frames: n, gain: gain, left: inL, right: inR)
            if render(frames: n) != noErr {
                outL.update(from: inL, count: n)
                outR.update(from: inR, count: n)
            }
            Self.write(out, offset: done, frames: n, left: outL, right: outR)
            done += n
        }
    }

    private func render(frames: Int) -> OSStatus {
        renderList[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: UnsafeMutableRawPointer(outL))
        renderList[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: UnsafeMutableRawPointer(outR))
        var flags = AudioUnitRenderActionFlags()
        var time = AudioTimeStamp()
        time.mSampleTime = sampleTime
        time.mFlags = .sampleTimeValid
        sampleTime += Float64(frames)
        return AudioUnitRender(unit, &flags, &time, 0, UInt32(frames), renderList.unsafeMutablePointer)
    }

    // MARK: Buffer layouts

    /// Where the left and right input channels are: (buffer, channel in buffer) each.
    struct Source { var left: (Int, Int); var right: (Int, Int); var valid: Bool }

    static func stereoSource(_ list: UnsafeMutableAudioBufferListPointer) -> Source {
        // Walk back from the last buffer until two channels are covered.
        var first = list.count
        var channels = 0
        while first > 0 && channels < 2 {
            first -= 1
            channels += Int(list[first].mNumberChannels)
        }
        var left: (Int, Int)?
        var right: (Int, Int)?
        for b in first ..< list.count where list[b].mNumberChannels > 0 && right == nil {
            for c in 0 ..< Int(list[b].mNumberChannels) where right == nil {
                if left == nil { left = (b, c) } else { right = (b, c) }
            }
        }
        guard let left else { return Source(left: (0, 0), right: (0, 0), valid: false) }
        return Source(left: left, right: right ?? left, valid: true)
    }

    static func read(_ list: UnsafeMutableAudioBufferListPointer, _ source: Source, offset: Int, frames: Int, gain: Float,
                     left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        guard source.valid else {
            left.update(repeating: 0, count: frames)
            right.update(repeating: 0, count: frames)
            return
        }
        copyChannel(list[source.left.0], channel: source.left.1, offset: offset, frames: frames, gain: gain, into: left)
        copyChannel(list[source.right.0], channel: source.right.1, offset: offset, frames: frames, gain: gain, into: right)
    }

    private static func copyChannel(_ buffer: AudioBuffer, channel: Int, offset: Int, frames: Int, gain: Float,
                                    into dest: UnsafeMutablePointer<Float>) {
        let stride = Int(buffer.mNumberChannels)
        let available = Int(buffer.mDataByteSize) / 4 / max(stride, 1)
        guard let data = buffer.mData?.assumingMemoryBound(to: Float.self), stride > 0 else {
            dest.update(repeating: 0, count: frames)
            return
        }
        for f in 0 ..< frames {
            let frame = offset + f
            dest[f] = frame < available ? data[frame * stride + channel] * gain : 0
        }
    }

    static func write(_ list: UnsafeMutableAudioBufferListPointer, offset: Int, frames: Int,
                      left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) {
        let total = list.reduce(0) { $0 + Int($1.mNumberChannels) }
        var channel = 0
        for b in 0 ..< list.count {
            let stride = Int(list[b].mNumberChannels)
            let available = Int(list[b].mDataByteSize) / 4 / max(stride, 1)
            guard let data = list[b].mData?.assumingMemoryBound(to: Float.self), stride > 0 else {
                channel += stride
                continue
            }
            for c in 0 ..< stride {
                let k = channel + c
                for f in 0 ..< frames {
                    let frame = offset + f
                    guard frame < available else { break }
                    let v: Float = total == 1 ? (left[f] + right[f]) * 0.5 : k == 0 ? left[f] : k == 1 ? right[f] : 0
                    data[frame * stride + c] = v
                }
            }
            channel += stride
        }
    }

    static func silence(_ list: UnsafeMutableAudioBufferListPointer, frames: Int) {
        for b in 0 ..< list.count {
            guard let data = list[b].mData else { continue }
            memset(data, 0, Int(list[b].mDataByteSize))
        }
    }
}

private func graphicEQInput(_ refCon: UnsafeMutableRawPointer, _ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                            _ time: UnsafePointer<AudioTimeStamp>, _ bus: UInt32, _ frames: UInt32,
                            _ ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    guard let ioData else { return noErr }
    Unmanaged<GraphicEQProcessor>.fromOpaque(refCon).takeUnretainedValue().fillInput(ioData, frames: Int(frames))
    return noErr
}
