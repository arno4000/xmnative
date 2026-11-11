import Foundation

/// The two band layouts of Apple's AUGraphicEQ (`kGraphicEQParam_NumberOfBands` 0 and 1).
/// Centre frequencies as the audio unit reports them in its parameter names.
public enum MacEqLayout: Int, CaseIterable, Codable, Sendable, Identifiable {
    case ten = 10
    case thirtyOne = 31

    public var id: Int { rawValue }
    public var bandCount: Int { rawValue }

    /// Value of `kGraphicEQParam_NumberOfBands`.
    var parameterValue: Float { self == .ten ? 0 : 1 }

    public var frequencies: [Double] {
        switch self {
        case .ten: [32, 64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384]
        case .thirtyOne: [20, 25, 31.5, 40, 50, 63, 80, 100, 125, 160, 200, 250, 315, 400, 500, 630, 800,
                          1000, 1250, 1600, 2000, 2500, 3150, 4000, 5000, 6300, 8000, 10000, 12000, 16000, 20000]
        }
    }

    /// Short slider labels, the way the bands are usually named (the 10-band layout's 128 Hz is "125").
    public var labels: [String] {
        switch self {
        case .ten: ["32", "64", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]
        case .thirtyOne: ["20", "25", "31", "40", "50", "63", "80", "100", "125", "160", "200", "250", "315", "400",
                          "500", "630", "800", "1k", "1.2k", "1.6k", "2k", "2.5k", "3.1k", "4k", "5k", "6.3k", "8k",
                          "10k", "12k", "16k", "20k"]
        }
    }
}

/// Gains in dB for one layout, plus converting a curve to another layout.
public enum EqCurve {
    /// The range the app offers per band. The audio unit itself allows ±20 dB.
    public static let gainRange: ClosedRange<Int> = -12 ... 12
    public static let preampRange: ClosedRange<Int> = -12 ... 12

    /// Interpolates a curve onto other centre frequencies, linearly over log frequency.
    /// Frequencies outside the source range take the nearest end value.
    public static func resample(_ gains: [Double], from: [Double], to: [Double]) -> [Double] {
        precondition(gains.count == from.count && !gains.isEmpty)
        let xs = from.map { log2($0) }
        return to.map { f in
            let x = log2(f)
            if x <= xs[0] { return gains[0] }
            if x >= xs[xs.count - 1] { return gains[gains.count - 1] }
            var i = 0
            while xs[i + 1] < x { i += 1 }
            let t = (x - xs[i]) / (xs[i + 1] - xs[i])
            return gains[i] + (gains[i + 1] - gains[i]) * t
        }
    }

    public static func convert(_ gains: [Int], from: MacEqLayout, to: MacEqLayout) -> [Int] {
        guard from != to else { return gains }
        return resample(gains.map(Double.init), from: from.frequencies, to: to.frequencies)
            .map { clamp(Int($0.rounded())) }
    }

    public static func clamp(_ v: Int) -> Int { min(max(v, gainRange.lowerBound), gainRange.upperBound) }

    /// Gain applied before the EQ so boosted bands can't push the signal past full scale.
    public static func headroom(for gains: [Int], preamp: Int, preventClipping: Bool) -> Int {
        preamp - (preventClipping ? max(0, gains.max() ?? 0) : 0)
    }
}

/// An EQ curve with a name. Stored as gains in its own layout and converted when applied to the other one.
public struct MacEqPreset: Codable, Hashable, Sendable, Identifiable {
    public var name: String
    public var layout: MacEqLayout
    public var gains: [Int]

    public var id: String { name }

    public init(name: String, layout: MacEqLayout, gains: [Int]) {
        precondition(gains.count == layout.bandCount)
        self.name = name
        self.layout = layout
        self.gains = gains
    }

    public func gains(for target: MacEqLayout) -> [Int] { EqCurve.convert(gains, from: layout, to: target) }

    public static func flat(_ layout: MacEqLayout) -> [Int] { Array(repeating: 0, count: layout.bandCount) }

    /// Built-in curves (10-band: 32 64 128 256 512 1k 2k 4k 8k 16k).
    public static let builtIn: [MacEqPreset] = [
        .init(name: "Flat", layout: .ten, gains: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
        .init(name: "Bass Boost", layout: .ten, gains: [6, 5, 4, 2, 0, 0, 0, 0, 0, 0]),
        .init(name: "Bass Reducer", layout: .ten, gains: [-6, -5, -4, -2, 0, 0, 0, 0, 0, 0]),
        .init(name: "Treble Boost", layout: .ten, gains: [0, 0, 0, 0, 0, 0, 2, 4, 5, 6]),
        .init(name: "Treble Reducer", layout: .ten, gains: [0, 0, 0, 0, 0, 0, -2, -4, -5, -6]),
        .init(name: "Loudness", layout: .ten, gains: [6, 4, 2, 0, -1, -1, 0, 2, 4, 5]),
        .init(name: "Vocal", layout: .ten, gains: [-3, -2, -1, 1, 3, 4, 3, 1, 0, -1]),
        .init(name: "Spoken Word", layout: .ten, gains: [-5, -3, 0, 2, 3, 4, 4, 2, 0, -3]),
        .init(name: "Rock", layout: .ten, gains: [5, 4, 2, 0, -1, -1, 1, 3, 4, 4]),
        .init(name: "Electronic", layout: .ten, gains: [5, 4, 1, 0, -2, 1, 0, 1, 4, 5]),
        .init(name: "Hip-Hop", layout: .ten, gains: [6, 5, 2, 3, -1, -1, 1, 0, 2, 3]),
        .init(name: "Acoustic", layout: .ten, gains: [4, 3, 2, 1, 2, 2, 3, 3, 2, 1]),
        .init(name: "Classical", layout: .ten, gains: [4, 3, 2, 1, -1, -1, 0, 2, 3, 4]),
        .init(name: "Late Night", layout: .ten, gains: [-4, -3, -1, 0, 1, 2, 2, 0, -2, -3]),
    ]
}
