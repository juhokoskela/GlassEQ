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

    var hasStablePoles: Bool {
        let a1 = Double(a1)
        let a2 = Double(a2)
        return abs(a2) < 1
            && 1 + a1 + a2 > 0
            && 1 - a1 + a2 > 0
    }

    var isNumericallySafe: Bool {
        b0.isFinite
            && b1.isFinite
            && b2.isFinite
            && a1.isFinite
            && a2.isFinite
            && hasStablePoles
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
        peakMagnitudeDB(
            for: filters,
            preampDB: preampDB,
            sampleRate: sampleRate,
            cancellationCheck: {}
        )
    }

    @_spi(GlassEQSettingsUI)
    public static func peakMagnitudeDB(
        for filters: [EQFilter],
        preampDB: Double,
        sampleRate: Double = 48_000,
        cancellationCheck: @Sendable () throws -> Void
    ) rethrows -> Double {
        try cancellationCheck()
        let coefficients = enabledCoefficients(filters: filters, sampleRate: sampleRate)
            .map(RenderBiquadCoefficients.init)
        guard coefficients.allSatisfy(\.isNumericallySafe) else {
            return .infinity
        }
        return preampDB + (try boundedPeakMagnitudeDB(
            for: coefficients,
            cancellationCheck: cancellationCheck
        ))
    }

    public static func points(
        for source: EQConvolutionSource?,
        preampDB: Double,
        sampleRate: Double = 48_000,
        count: Int = 96
    ) -> [FrequencyResponsePoint] {
        points(
            for: source,
            preampDB: preampDB,
            sampleRate: sampleRate,
            count: count,
            cancellationCheck: {}
        )
    }

    @_spi(GlassEQSettingsUI)
    public static func points(
        for source: EQConvolutionSource?,
        preampDB: Double,
        sampleRate: Double = 48_000,
        count: Int = 96,
        cancellationCheck: @Sendable () throws -> Void
    ) rethrows -> [FrequencyResponsePoint] {
        try cancellationCheck()
        let lower = log10(20.0)
        let upperFrequency = max(
            20,
            EQRouteFrequencyPolicy.maximumUsableFrequency(sampleRate: sampleRate)
        )
        let upper = log10(upperFrequency)
        let frequencies = try (0..<max(count, 2)).map { index in
            try cancellationCheck()
            let fraction = Double(index) / Double(max(count - 1, 1))
            return pow(10, lower + (upper - lower) * fraction)
        }

        switch source {
        case .magnitudeCurve(let curve):
            let sortedPoints = curve.points.sorted { $0.frequency < $1.frequency }
            let adjustedPoints = MinimumPhaseFIRCompiler.routeAdjustedPoints(
                sortedPoints,
                maximumUsableFrequency: upperFrequency,
                nyquistFrequency: sampleRate / 2
            )
            return frequencies.map { frequency in
                FrequencyResponsePoint(
                    frequency: frequency,
                    magnitudeDB: preampDB + MinimumPhaseFIRCompiler.interpolatedGainDB(
                        frequency: frequency,
                        points: adjustedPoints
                    )
                )
            }
        case .impulseResponse(let impulse):
            do {
                let spectrum = try ImpulseResponseSpectrum(
                    impulseResponse: impulse.samples,
                    sampleRate: impulse.sampleRate,
                    cancellationCheck: cancellationCheck
                )
                return try frequencies.map { frequency in
                    try cancellationCheck()
                    return FrequencyResponsePoint(
                        frequency: frequency,
                        magnitudeDB: preampDB + spectrum.magnitudeDB(at: frequency)
                    )
                }
            } catch {
                try cancellationCheck()
                return try frequencies.map { frequency in
                    FrequencyResponsePoint(
                        frequency: frequency,
                        magnitudeDB: preampDB + (try impulseResponseMagnitudeDB(
                            impulse,
                            frequency: frequency,
                            cancellationCheck: cancellationCheck
                        ))
                    )
                }
            }
        case nil:
            return frequencies.map {
                FrequencyResponsePoint(frequency: $0, magnitudeDB: preampDB)
            }
        }
    }

    private static func impulseResponseMagnitudeDB(
        _ impulse: ImpulseResponseSource,
        frequency: Double,
        cancellationCheck: @Sendable () throws -> Void
    ) rethrows -> Double {
        let boundedFrequency = min(frequency, impulse.sampleRate / 2)
        let omega = 2 * Double.pi * boundedFrequency / impulse.sampleRate
        var real = 0.0
        var imaginary = 0.0
        for (index, sample) in impulse.samples.enumerated() {
            if index.isMultiple(of: 256) {
                try cancellationCheck()
            }
            let phase = -omega * Double(index)
            real += Double(sample) * cos(phase)
            imaginary += Double(sample) * sin(phase)
        }
        return 20 * log10(max(hypot(real, imaginary), .leastNonzeroMagnitude))
    }

    public static func peakMagnitudeDB(
        for source: EQConvolutionSource?,
        preampDB: Double,
        sampleRate: Double = 48_000
    ) -> Double {
        (try? peakMagnitudeDB(
            for: source,
            preampDB: preampDB,
            sampleRate: sampleRate,
            cancellationCheck: {}
        )) ?? .infinity
    }

    @_spi(GlassEQSettingsUI)
    public static func peakMagnitudeDB(
        for source: EQConvolutionSource?,
        preampDB: Double,
        sampleRate: Double = 48_000,
        cancellationCheck: @Sendable () throws -> Void
    ) throws -> Double {
        try cancellationCheck()
        let maximumFrequency = EQRouteFrequencyPolicy.maximumUsableFrequency(
            sampleRate: sampleRate
        )
        switch source {
        case .magnitudeCurve(let curve):
            let impulse: [Float]
            do {
                impulse = try MinimumPhaseFIRCompiler.compile(
                    points: curve.points,
                    sampleRate: sampleRate,
                    maximumUsableFrequency: maximumFrequency,
                    cancellationCheck: cancellationCheck
                )
            } catch is MinimumPhaseFIRCompilerError {
                return .infinity
            }
            let upperBoundDB = try convolutionPeakUpperBoundDB(
                impulse,
                cancellationCheck: cancellationCheck
            )
            return preampDB + upperBoundDB
        case .impulseResponse(let impulse):
            let upperBoundDB = try convolutionPeakUpperBoundDB(
                impulse.samples,
                cancellationCheck: cancellationCheck
            )
            return preampDB + upperBoundDB
        case nil:
            return preampDB
        }
    }

    private static func convolutionPeakUpperBoundDB(
        _ impulseResponse: [Float],
        cancellationCheck: @Sendable () throws -> Void
    ) throws -> Double {
        do {
            return try MinimumPhaseFIRCompiler.certifiedPeakMagnitudeDB(
                impulseResponse: impulseResponse,
                cancellationCheck: cancellationCheck
            )
        } catch is MinimumPhaseFIRCompilerError {
            return try MinimumPhaseFIRCompiler.coefficientL1UpperBoundDB(
                impulseResponse,
                cancellationCheck: cancellationCheck
            )
        }
    }

    private static func enabledCoefficients(filters: [EQFilter], sampleRate: Double) -> [BiquadCoefficients] {
        Array(
            filters.lazy
                .filter(\.isEnabled)
                .map { BiquadCoefficients.make(filter: $0, sampleRate: sampleRate) }
        )
    }

    private static func boundedPeakMagnitudeDB(
        for coefficients: [RenderBiquadCoefficients],
        cancellationCheck: @Sendable () throws -> Void
    ) rethrows -> Double {
        try cancellationCheck()
        guard !coefficients.isEmpty else {
            return 0
        }

        let responses = coefficients.map(BiquadMagnitudeSquared.init)
        var intervals = PeakSearchQueue(PeakSearchInterval(
            lower: 0,
            upper: 1,
            upperBoundDB: cascadeUpperBoundDB(responses, lower: 0, upper: 1)
        ))
        var bestMagnitudeDB = [0.0, 0.5, 1.0]
            .map { cascadeMagnitudeDB(responses, at: $0) }
            .max() ?? 0

        let toleranceDB = 0.01
        let maximumIterations = 8_192
        for iteration in 0..<maximumIterations {
            if iteration.isMultiple(of: 16) {
                try cancellationCheck()
            }
            guard let interval = intervals.removeMaximum() else {
                return bestMagnitudeDB
            }
            guard interval.upperBoundDB.isFinite else {
                return .infinity
            }
            if interval.upperBoundDB - bestMagnitudeDB <= toleranceDB {
                return max(bestMagnitudeDB, interval.upperBoundDB)
            }

            let middle = (interval.lower + interval.upper) / 2
            guard middle > interval.lower, middle < interval.upper else {
                return max(bestMagnitudeDB, interval.upperBoundDB)
            }
            bestMagnitudeDB = max(
                bestMagnitudeDB,
                cascadeMagnitudeDB(responses, at: middle)
            )
            intervals.insert(PeakSearchInterval(
                lower: interval.lower,
                upper: middle,
                upperBoundDB: cascadeUpperBoundDB(
                    responses,
                    lower: interval.lower,
                    upper: middle
                )
            ))
            intervals.insert(PeakSearchInterval(
                lower: middle,
                upper: interval.upper,
                upperBoundDB: cascadeUpperBoundDB(
                    responses,
                    lower: middle,
                    upper: interval.upper
                )
            ))
        }

        try cancellationCheck()
        return max(
            bestMagnitudeDB,
            intervals.maximumUpperBoundDB ?? bestMagnitudeDB
        )
    }

    private static func cascadeMagnitudeDB(
        _ responses: [BiquadMagnitudeSquared],
        at position: Double
    ) -> Double {
        responses.reduce(0.0) { magnitudeDB, response in
            magnitudeDB + 10 * log10(max(
                response.ratio(at: position),
                .leastNonzeroMagnitude
            ))
        }
    }

    private static func cascadeUpperBoundDB(
        _ responses: [BiquadMagnitudeSquared],
        lower: Double,
        upper: Double
    ) -> Double {
        responses.reduce(0.0) { magnitudeDB, response in
            let maximumRatio = response.maximumRatio(lower: lower, upper: upper)
            guard maximumRatio.isFinite else {
                return .infinity
            }
            return magnitudeDB + 10 * log10(max(maximumRatio, .leastNonzeroMagnitude))
        }
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

private struct PeakSearchInterval {
    var lower: Double
    var upper: Double
    var upperBoundDB: Double
}

private struct PeakSearchQueue {
    private var storage: [PeakSearchInterval]

    init(_ interval: PeakSearchInterval) {
        self.storage = [interval]
    }

    var maximumUpperBoundDB: Double? {
        storage.first?.upperBoundDB
    }

    mutating func insert(_ interval: PeakSearchInterval) {
        storage.append(interval)
        var child = storage.count - 1
        while child > 0 {
            let parent = (child - 1) / 2
            guard storage[child].upperBoundDB > storage[parent].upperBoundDB else {
                return
            }
            storage.swapAt(child, parent)
            child = parent
        }
    }

    mutating func removeMaximum() -> PeakSearchInterval? {
        guard !storage.isEmpty else {
            return nil
        }
        guard storage.count > 1 else {
            return storage.removeLast()
        }
        let maximum = storage[0]
        storage[0] = storage.removeLast()
        var parent = 0
        while true {
            let left = parent * 2 + 1
            guard left < storage.count else {
                break
            }
            let right = left + 1
            let child = right < storage.count
                && storage[right].upperBoundDB > storage[left].upperBoundDB
                ? right
                : left
            guard storage[child].upperBoundDB > storage[parent].upperBoundDB else {
                break
            }
            storage.swapAt(parent, child)
            parent = child
        }
        return maximum
    }
}

private struct BiquadMagnitudeSquared {
    private struct Terms {
        var sum: Double
        var pair: Double
        var difference: Double

        var polynomial: (constant: Double, linear: Double, quadratic: Double) {
            (
                constant: sum * sum,
                linear: 4 * (difference * difference - sum * pair),
                quadratic: 4 * (pair * pair - difference * difference)
            )
        }

        func value(at position: Double) -> Double {
            let real = sum - 2 * pair * position
            return real * real
                + 4 * position * (1 - position) * difference * difference
        }
    }

    private var numerator: Terms
    private var denominator: Terms

    init(_ coefficients: RenderBiquadCoefficients) {
        let b0 = Double(coefficients.b0)
        let b1 = Double(coefficients.b1)
        let b2 = Double(coefficients.b2)
        let a1 = Double(coefficients.a1)
        let a2 = Double(coefficients.a2)
        self.numerator = Terms(
            sum: b0 + b1 + b2,
            pair: b0 + b2,
            difference: b0 - b2
        )
        self.denominator = Terms(
            sum: 1 + a1 + a2,
            pair: 1 + a2,
            difference: 1 - a2
        )
    }

    func ratio(at position: Double) -> Double {
        let denominatorValue = denominator.value(at: position)
        guard denominatorValue.isFinite, denominatorValue > 0 else {
            return .infinity
        }
        return numerator.value(at: position) / denominatorValue
    }

    func maximumRatio(lower: Double, upper: Double) -> Double {
        let candidates = [lower, upper] + stationaryPoints().filter {
            $0 > lower && $0 < upper
        }
        return candidates.reduce(0.0) { maximum, position in
            max(maximum, ratio(at: position))
        }.nextUp
    }

    private func stationaryPoints() -> [Double] {
        let n = numerator.polynomial
        let d = denominator.polynomial
        let quadratic = n.quadratic * d.linear - n.linear * d.quadratic
        let linear = 2 * (n.quadratic * d.constant - n.constant * d.quadratic)
        let constant = n.linear * d.constant - n.constant * d.linear

        if quadratic == 0 {
            guard linear != 0 else {
                return []
            }
            return [-constant / linear]
        }

        var discriminant = linear * linear - 4 * quadratic * constant
        let discriminantScale = linear * linear + abs(4 * quadratic * constant)
        if discriminant < 0,
           abs(discriminant) <= 64 * Double.ulpOfOne * discriminantScale {
            discriminant = 0
        }
        guard discriminant >= 0, discriminant.isFinite else {
            return []
        }

        let root = sqrt(discriminant)
        let signedRoot = linear >= 0 ? root : -root
        let firstTerm = -0.5 * (linear + signedRoot)
        guard firstTerm != 0 else {
            return [-linear / (2 * quadratic)]
        }
        return [
            firstTerm / quadratic,
            constant / firstTerm
        ]
    }
}

public enum EQProfileAnalysis {
    @_spi(GlassEQSettingsUI)
    public static func recommendedPreampDB(
        profile: EQProfile,
        sampleRate: Double = 48_000,
        cancellationCheck: @Sendable () throws -> Void
    ) throws -> Double {
        try cancellationCheck()
        let renderedPeaks: [Double]
        let activePreampDB: Double
        switch profile.channelMode {
        case .linked:
            activePreampDB = profile.preampDB
            renderedPeaks = [
                try peakMagnitudeDB(
                    mode: profile.mode,
                    filters: profile.filters,
                    source: profile.convolution,
                    preampDB: profile.preampDB,
                    sampleRate: sampleRate,
                    cancellationCheck: cancellationCheck
                )
            ]
        case .stereo:
            activePreampDB = max(profile.leftPreampDB, profile.rightPreampDB)
            renderedPeaks = [
                try peakMagnitudeDB(
                    mode: profile.mode,
                    filters: profile.leftFilters,
                    source: profile.leftConvolution,
                    preampDB: profile.leftPreampDB,
                    sampleRate: sampleRate,
                    cancellationCheck: cancellationCheck
                ),
                try peakMagnitudeDB(
                    mode: profile.mode,
                    filters: profile.rightFilters,
                    source: profile.rightConvolution,
                    preampDB: profile.rightPreampDB,
                    sampleRate: sampleRate,
                    cancellationCheck: cancellationCheck
                ),
            ]
        }
        try cancellationCheck()
        let requiredAttenuationDB = max((renderedPeaks.max() ?? 0) + 0.5, 0)
        return activePreampDB - requiredAttenuationDB
    }

    private static func peakMagnitudeDB(
        mode: EQMode,
        filters: [EQFilter],
        source: EQConvolutionSource?,
        preampDB: Double,
        sampleRate: Double,
        cancellationCheck: @Sendable () throws -> Void
    ) throws -> Double {
        if mode == .convolution {
            return try FrequencyResponse.peakMagnitudeDB(
                for: source,
                preampDB: preampDB,
                sampleRate: sampleRate,
                cancellationCheck: cancellationCheck
            )
        }
        return try FrequencyResponse.peakMagnitudeDB(
            for: filters,
            preampDB: preampDB,
            sampleRate: sampleRate,
            cancellationCheck: cancellationCheck
        )
    }
}
