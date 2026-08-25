import Foundation

public enum EQRouteFrequencyPolicy {
    public static let maximumProfileFrequency = 20_000.0
    public static let maximumSampleRateFraction = 0.45

    public static func maximumUsableFrequency(sampleRate: Double) -> Double {
        guard sampleRate.isFinite, sampleRate > 0 else {
            return maximumProfileFrequency
        }
        return min(maximumProfileFrequency, sampleRate * maximumSampleRateFraction)
    }

    public static func supports(_ filter: EQFilter, sampleRate: Double) -> Bool {
        sampleRate.isFinite
            && sampleRate > 0
            && filter.frequency.isFinite
            && filter.frequency <= maximumUsableFrequency(sampleRate: sampleRate)
    }

    public static func inactiveEnabledFilterCount(profile: EQProfile, sampleRate: Double) -> Int {
        let filters: [EQFilter]
        switch profile.channelMode {
        case .linked:
            filters = profile.filters
        case .stereo:
            filters = profile.leftFilters + profile.rightFilters
        }
        return filters.count { $0.isEnabled && !supports($0, sampleRate: sampleRate) }
    }
}

public struct BiquadCoefficients: Equatable, Sendable {
    public var b0: Double
    public var b1: Double
    public var b2: Double
    public var a1: Double
    public var a2: Double

    public init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        self.b0 = b0
        self.b1 = b1
        self.b2 = b2
        self.a1 = a1
        self.a2 = a2
    }

    public static let identity = BiquadCoefficients(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)

    public static func make(
        filter: EQFilter,
        sampleRate: Double,
        maximumUsableFrequency: Double? = nil
    ) -> BiquadCoefficients {
        let processingCeiling = EQRouteFrequencyPolicy.maximumUsableFrequency(sampleRate: sampleRate)
        let routeCeiling = maximumUsableFrequency ?? processingCeiling
        guard filter.isEnabled,
              sampleRate.isFinite,
              sampleRate > 0,
              routeCeiling.isFinite,
              routeCeiling > 0,
              filter.frequency.isFinite,
              filter.frequency <= min(processingCeiling, routeCeiling) else {
            return .identity
        }

        let frequency = max(filter.frequency, 1)
        let q = max(filter.q, 0.000_1)
        let omega = 2 * Double.pi * frequency / sampleRate
        let sinOmega = sin(omega)
        let cosOmega = cos(omega)
        let alpha = sinOmega / (2 * q)
        let amplitude = pow(10, filter.gainDB / 40)

        let raw: (b0: Double, b1: Double, b2: Double, a0: Double, a1: Double, a2: Double)

        switch filter.kind {
        case .peak:
            raw = (
                b0: 1 + alpha * amplitude,
                b1: -2 * cosOmega,
                b2: 1 - alpha * amplitude,
                a0: 1 + alpha / amplitude,
                a1: -2 * cosOmega,
                a2: 1 - alpha / amplitude
            )
        case .lowShelf:
            let sqrtA = sqrt(amplitude)
            let twoSqrtAAlpha = 2 * sqrtA * alpha
            raw = (
                b0: amplitude * ((amplitude + 1) - (amplitude - 1) * cosOmega + twoSqrtAAlpha),
                b1: 2 * amplitude * ((amplitude - 1) - (amplitude + 1) * cosOmega),
                b2: amplitude * ((amplitude + 1) - (amplitude - 1) * cosOmega - twoSqrtAAlpha),
                a0: (amplitude + 1) + (amplitude - 1) * cosOmega + twoSqrtAAlpha,
                a1: -2 * ((amplitude - 1) + (amplitude + 1) * cosOmega),
                a2: (amplitude + 1) + (amplitude - 1) * cosOmega - twoSqrtAAlpha
            )
        case .highShelf:
            let sqrtA = sqrt(amplitude)
            let twoSqrtAAlpha = 2 * sqrtA * alpha
            raw = (
                b0: amplitude * ((amplitude + 1) + (amplitude - 1) * cosOmega + twoSqrtAAlpha),
                b1: -2 * amplitude * ((amplitude - 1) + (amplitude + 1) * cosOmega),
                b2: amplitude * ((amplitude + 1) + (amplitude - 1) * cosOmega - twoSqrtAAlpha),
                a0: (amplitude + 1) - (amplitude - 1) * cosOmega + twoSqrtAAlpha,
                a1: 2 * ((amplitude - 1) - (amplitude + 1) * cosOmega),
                a2: (amplitude + 1) - (amplitude - 1) * cosOmega - twoSqrtAAlpha
            )
        case .highPass:
            raw = (
                b0: (1 + cosOmega) / 2,
                b1: -(1 + cosOmega),
                b2: (1 + cosOmega) / 2,
                a0: 1 + alpha,
                a1: -2 * cosOmega,
                a2: 1 - alpha
            )
        case .lowPass:
            raw = (
                b0: (1 - cosOmega) / 2,
                b1: 1 - cosOmega,
                b2: (1 - cosOmega) / 2,
                a0: 1 + alpha,
                a1: -2 * cosOmega,
                a2: 1 - alpha
            )
        }

        return BiquadCoefficients(
            b0: raw.b0 / raw.a0,
            b1: raw.b1 / raw.a0,
            b2: raw.b2 / raw.a0,
            a1: raw.a1 / raw.a0,
            a2: raw.a2 / raw.a0
        )
    }
}

struct RenderBiquadCoefficients: Equatable, Sendable {
    var b0: Float
    var b1: Float
    var b2: Float
    var a1: Float
    var a2: Float

    init(_ coefficients: BiquadCoefficients) {
        self.b0 = Float(coefficients.b0)
        self.b1 = Float(coefficients.b1)
        self.b2 = Float(coefficients.b2)
        self.a1 = Float(coefficients.a1)
        self.a2 = Float(coefficients.a2)
    }
}

public struct BiquadState: Sendable {
    private static let denormalFlushThreshold: Float = 1.0e-20

    public var z1: Float = 0
    public var z2: Float = 0

    public init() {}

    mutating func process(_ input: Float, coefficients c: RenderBiquadCoefficients) -> Float {
        processWithDiagnostics(input, coefficients: c).sample
    }

    mutating func processWithDiagnostics(
        _ input: Float,
        coefficients c: RenderBiquadCoefficients
    ) -> (sample: Float, encounteredNonFinite: Bool) {
        let y = c.b0 * input + z1
        let nextZ1 = c.b1 * input - c.a1 * y + z2
        let nextZ2 = c.b2 * input - c.a2 * y
        let encounteredNonFinite = !input.isFinite
            || !y.isFinite
            || !nextZ1.isFinite
            || !nextZ2.isFinite
        z1 = Self.flushDenormal(nextZ1)
        z2 = Self.flushDenormal(nextZ2)
        return (Self.flushDenormal(y), encounteredNonFinite)
    }

    public mutating func process(_ input: Float, coefficients c: BiquadCoefficients) -> Float {
        let x = Double(input)
        let y = c.b0 * x + Double(z1)
        z1 = Self.flushDenormal(Float(c.b1 * x - c.a1 * y + Double(z2)))
        z2 = Self.flushDenormal(Float(c.b2 * x - c.a2 * y))
        return Self.flushDenormal(Float(y))
    }

    private static func flushDenormal(_ value: Float) -> Float {
        guard value.isFinite, abs(value) >= denormalFlushThreshold else {
            return 0
        }
        return value
    }
}

public struct FrequencyResponsePoint: Equatable, Sendable {
    public var frequency: Double
    public var magnitudeDB: Double

    public init(frequency: Double, magnitudeDB: Double) {
        self.frequency = frequency
        self.magnitudeDB = magnitudeDB
    }
}

public enum FrequencyResponse {
    public static func magnitudeDB(
        for coefficients: BiquadCoefficients,
        frequency: Double,
        sampleRate: Double
    ) -> Double {
        let omega = 2 * Double.pi * frequency / sampleRate
        let z1r = cos(-omega)
        let z1i = sin(-omega)
        let z2r = cos(-2 * omega)
        let z2i = sin(-2 * omega)

        let numeratorReal = coefficients.b0 + coefficients.b1 * z1r + coefficients.b2 * z2r
        let numeratorImag = coefficients.b1 * z1i + coefficients.b2 * z2i
        let denominatorReal = 1 + coefficients.a1 * z1r + coefficients.a2 * z2r
        let denominatorImag = coefficients.a1 * z1i + coefficients.a2 * z2i

        let numerator = hypot(numeratorReal, numeratorImag)
        let denominator = max(hypot(denominatorReal, denominatorImag), .leastNonzeroMagnitude)
        return 20 * log10(max(numerator / denominator, .leastNonzeroMagnitude))
    }

    public static func magnitudeDB(
        for filters: [EQFilter],
        preampDB: Double,
        frequency: Double,
        sampleRate: Double
    ) -> Double {
        magnitudeDB(
            for: enabledCoefficients(filters: filters, sampleRate: sampleRate),
            preampDB: preampDB,
            frequency: frequency,
            sampleRate: sampleRate
        )
    }

    public static func points(
        for filters: [EQFilter],
        preampDB: Double,
        sampleRate: Double = 48_000,
        count: Int = 96
    ) -> [FrequencyResponsePoint] {
        points(
            for: enabledCoefficients(filters: filters, sampleRate: sampleRate),
            preampDB: preampDB,
            sampleRate: sampleRate,
            count: count
        )
    }

    public static func peakMagnitudeDB(
        for filters: [EQFilter],
        preampDB: Double,
        sampleRate: Double = 48_000
    ) -> Double {
        let coefficients = enabledCoefficients(filters: filters, sampleRate: sampleRate)
        return points(for: coefficients, preampDB: preampDB, sampleRate: sampleRate, count: 192)
            .map(\.magnitudeDB)
            .max() ?? preampDB
    }

    public static func points(
        for source: EQConvolutionSource?,
        preampDB: Double,
        sampleRate: Double = 48_000,
        count: Int = 96
    ) -> [FrequencyResponsePoint] {
        let lower = log10(20.0)
        let upperFrequency = max(
            20,
            EQRouteFrequencyPolicy.maximumUsableFrequency(sampleRate: sampleRate)
        )
        let upper = log10(upperFrequency)
        let curve = magnitudePoints(from: source)
        return (0..<max(count, 2)).map { index in
            let fraction = Double(index) / Double(max(count - 1, 1))
            let frequency = pow(10, lower + (upper - lower) * fraction)
            return FrequencyResponsePoint(
                frequency: frequency,
                magnitudeDB: preampDB + MinimumPhaseFIRCompiler.interpolatedGainDB(
                    frequency: frequency,
                    points: curve
                )
            )
        }
    }

    public static func peakMagnitudeDB(
        for source: EQConvolutionSource?,
        preampDB: Double,
        sampleRate: Double = 48_000
    ) -> Double {
        let maximumFrequency = EQRouteFrequencyPolicy.maximumUsableFrequency(
            sampleRate: sampleRate
        )
        let curve = magnitudePoints(from: source)
        let relevantGains = curve.lazy
            .filter { $0.frequency <= maximumFrequency }
            .map(\.gainDB)
        let boundaryGain = MinimumPhaseFIRCompiler.interpolatedGainDB(
            frequency: maximumFrequency,
            points: curve
        )
        return preampDB + max(relevantGains.max() ?? 0, boundaryGain)
    }

    private static func magnitudePoints(
        from source: EQConvolutionSource?
    ) -> [EQMagnitudePoint] {
        switch source {
        case .magnitudeCurve(let curve):
            return curve.points.sorted { $0.frequency < $1.frequency }
        case nil:
            return []
        }
    }

    private static func enabledCoefficients(filters: [EQFilter], sampleRate: Double) -> [BiquadCoefficients] {
        Array(
            filters.lazy
                .filter(\.isEnabled)
                .map { BiquadCoefficients.make(filter: $0, sampleRate: sampleRate) }
        )
    }

    private static func magnitudeDB(
        for coefficients: [BiquadCoefficients],
        preampDB: Double,
        frequency: Double,
        sampleRate: Double
    ) -> Double {
        coefficients.reduce(preampDB) { magnitude, coefficients in
            magnitude + magnitudeDB(for: coefficients, frequency: frequency, sampleRate: sampleRate)
        }
    }

    private static func points(
        for coefficients: [BiquadCoefficients],
        preampDB: Double,
        sampleRate: Double,
        count: Int
    ) -> [FrequencyResponsePoint] {
        let lower = log10(20.0)
        let upperFrequency = max(
            20,
            EQRouteFrequencyPolicy.maximumUsableFrequency(sampleRate: sampleRate)
        )
        let upper = log10(upperFrequency)
        return (0..<max(count, 2)).map { index in
            let fraction = Double(index) / Double(max(count - 1, 1))
            let frequency = pow(10, lower + (upper - lower) * fraction)
            return FrequencyResponsePoint(
                frequency: frequency,
                magnitudeDB: magnitudeDB(
                    for: coefficients,
                    preampDB: preampDB,
                    frequency: frequency,
                    sampleRate: sampleRate
                )
            )
        }
    }
}

public enum EQProfileAnalysis {
    public static func recommendedPreampDB(profile: EQProfile, sampleRate: Double = 48_000) -> Double {
        let peaks: [Double]
        switch profile.channelMode {
        case .linked:
            peaks = [peakMagnitudeDB(
                mode: profile.mode,
                filters: profile.filters,
                source: profile.convolution,
                preampDB: profile.preampDB,
                sampleRate: sampleRate
            )]
        case .stereo:
            peaks = [
                peakMagnitudeDB(
                    mode: profile.mode,
                    filters: profile.leftFilters,
                    source: profile.leftConvolution,
                    preampDB: profile.leftPreampDB,
                    sampleRate: sampleRate
                ),
                peakMagnitudeDB(
                    mode: profile.mode,
                    filters: profile.rightFilters,
                    source: profile.rightConvolution,
                    preampDB: profile.rightPreampDB,
                    sampleRate: sampleRate
                )
            ]
        }
        let peak = peaks.max() ?? 0
        if peak > -0.5 {
            return -peak - 0.5
        }
        switch profile.channelMode {
        case .linked:
            return profile.preampDB
        case .stereo:
            return min(profile.leftPreampDB, profile.rightPreampDB)
        }
    }

    private static func peakMagnitudeDB(
        mode: EQMode,
        filters: [EQFilter],
        source: EQConvolutionSource?,
        preampDB: Double,
        sampleRate: Double
    ) -> Double {
        if mode == .convolution {
            return FrequencyResponse.peakMagnitudeDB(
                for: source,
                preampDB: preampDB,
                sampleRate: sampleRate
            )
        }
        return FrequencyResponse.peakMagnitudeDB(
            for: filters,
            preampDB: preampDB,
            sampleRate: sampleRate
        )
    }
}
