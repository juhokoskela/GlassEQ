import Accelerate
import Foundation

public enum MinimumPhaseFIRCompilerError: Error, Equatable, Sendable {
    case invalidSampleRate
    case insufficientPoints
    case invalidPoint
    case invalidImpulseResponse
    case duplicateFrequency(Double)
    case transformSetupFailed
    case nonFiniteImpulseResponse
}

public enum MinimumPhaseFIRCompiler {
    public static let synthesisVersion: UInt16 = 1
    public static let tapCount = 16_384
    private static let peakAnalysisOversamplingFactor = 16

    public static func compile(
        points: [EQMagnitudePoint],
        sampleRate: Double,
        maximumUsableFrequency: Double? = nil
    ) throws -> [Float] {
        try compile(
            points: points,
            sampleRate: sampleRate,
            maximumUsableFrequency: maximumUsableFrequency,
            cancellationCheck: {}
        )
    }

    static func compile(
        points: [EQMagnitudePoint],
        sampleRate: Double,
        maximumUsableFrequency: Double?,
        cancellationCheck: @Sendable () throws -> Void
    ) throws -> [Float] {
        try cancellationCheck()
        guard sampleRate.isFinite, sampleRate > 0 else {
            throw MinimumPhaseFIRCompilerError.invalidSampleRate
        }

        let sortedPoints = try validatedPoints(points)
        let nyquist = sampleRate / 2
        let synthesisPoints = routeAdjustedPoints(
            sortedPoints,
            maximumUsableFrequency: maximumUsableFrequency,
            nyquistFrequency: nyquist
        )
        try cancellationCheck()
        let transform = try ComplexDoubleDFT(length: tapCount)
        let halfCount = tapCount / 2
        var logMagnitudeReal = [Double](repeating: 0, count: tapCount)
        var logMagnitudeImaginary = [Double](repeating: 0, count: tapCount)

        for bin in 0...halfCount {
            if bin.isMultiple(of: 256) {
                try cancellationCheck()
            }
            let frequency = Double(bin) * nyquist / Double(halfCount)
            let gainDB = interpolatedGainDB(
                frequency: frequency,
                points: synthesisPoints
            )
            let logAmplitude = gainDB * log(10) / 20
            logMagnitudeReal[bin] = logAmplitude
            if bin > 0, bin < halfCount {
                logMagnitudeReal[tapCount - bin] = logAmplitude
            }
        }

        var cepstrumReal = [Double](repeating: 0, count: tapCount)
        var cepstrumImaginary = [Double](repeating: 0, count: tapCount)
        try cancellationCheck()
        transform.inverse(
            real: &logMagnitudeReal,
            imaginary: &logMagnitudeImaginary,
            outputReal: &cepstrumReal,
            outputImaginary: &cepstrumImaginary
        )
        try cancellationCheck()
        let inverseScale = 1 / Double(tapCount)
        cepstrumReal[0] *= inverseScale
        for index in 1..<halfCount {
            if index.isMultiple(of: 256) {
                try cancellationCheck()
            }
            cepstrumReal[index] *= 2 * inverseScale
        }
        cepstrumReal[halfCount] *= inverseScale
        for index in (halfCount + 1)..<tapCount {
            if index.isMultiple(of: 256) {
                try cancellationCheck()
            }
            cepstrumReal[index] = 0
        }
        for index in cepstrumImaginary.indices {
            if index.isMultiple(of: 256) {
                try cancellationCheck()
            }
            cepstrumImaginary[index] = 0
        }

        var minimumPhaseLogReal = [Double](repeating: 0, count: tapCount)
        var minimumPhaseLogImaginary = [Double](repeating: 0, count: tapCount)
        try cancellationCheck()
        transform.forward(
            real: &cepstrumReal,
            imaginary: &cepstrumImaginary,
            outputReal: &minimumPhaseLogReal,
            outputImaginary: &minimumPhaseLogImaginary
        )
        try cancellationCheck()

        for index in 0..<tapCount {
            if index.isMultiple(of: 256) {
                try cancellationCheck()
            }
            let amplitude = exp(minimumPhaseLogReal[index])
            let phase = minimumPhaseLogImaginary[index]
            minimumPhaseLogReal[index] = amplitude * cos(phase)
            minimumPhaseLogImaginary[index] = amplitude * sin(phase)
        }

        var impulseReal = [Double](repeating: 0, count: tapCount)
        var impulseImaginary = [Double](repeating: 0, count: tapCount)
        try cancellationCheck()
        transform.inverse(
            real: &minimumPhaseLogReal,
            imaginary: &minimumPhaseLogImaginary,
            outputReal: &impulseReal,
            outputImaginary: &impulseImaginary
        )
        try cancellationCheck()

        var impulse = [Float](repeating: 0, count: tapCount)
        for index in 0..<tapCount {
            if index.isMultiple(of: 256) {
                try cancellationCheck()
            }
            let value = impulseReal[index] * inverseScale
            guard value.isFinite else {
                throw MinimumPhaseFIRCompilerError.nonFiniteImpulseResponse
            }
            impulse[index] = Float(value)
        }
        return impulse
    }

    static func routeAdjustedPoints(
        _ points: [EQMagnitudePoint],
        maximumUsableFrequency: Double?,
        nyquistFrequency: Double
    ) -> [EQMagnitudePoint] {
        guard let maximumUsableFrequency,
              maximumUsableFrequency.isFinite,
              nyquistFrequency.isFinite,
              maximumUsableFrequency > 0,
              maximumUsableFrequency < nyquistFrequency else {
            return points
        }

        let ceilingGainDB = interpolatedGainDB(
            frequency: maximumUsableFrequency,
            points: points
        )
        var adjusted = points.filter { $0.frequency < maximumUsableFrequency }
        if let ceilingPoint = points.first(where: { $0.frequency == maximumUsableFrequency }) {
            adjusted.append(ceilingPoint)
        } else {
            adjusted.append(EQMagnitudePoint(
                frequency: maximumUsableFrequency,
                gainDB: ceilingGainDB
            ))
        }
        adjusted.append(contentsOf: points.lazy
            .filter {
                $0.frequency > maximumUsableFrequency
                    && $0.frequency < nyquistFrequency
            }
            .map { EQMagnitudePoint(frequency: $0.frequency, gainDB: 0) })
        adjusted.append(EQMagnitudePoint(frequency: nyquistFrequency, gainDB: 0))
        return adjusted
    }

    static func certifiedPeakMagnitudeDB(
        impulseResponse: [Float],
        cancellationCheck: @Sendable () throws -> Void
    ) throws -> Double {
        try cancellationCheck()
        guard !impulseResponse.isEmpty else {
            return -.infinity
        }

        guard impulseResponse.count <= ImpulseResponseSource.maximumFrameCount else {
            return try coefficientL1UpperBoundDB(
                impulseResponse,
                cancellationCheck: cancellationCheck
            )
        }
        let minimumSampleCount = impulseResponse.count * peakAnalysisOversamplingFactor
        var sampleCount = 1
        while sampleCount < minimumSampleCount {
            sampleCount *= 2
        }
        let transform = try ComplexDoubleDFT(length: sampleCount)
        var inputReal = [Double](repeating: 0, count: sampleCount)
        for index in impulseResponse.indices {
            if index.isMultiple(of: 256) {
                try cancellationCheck()
            }
            let sample = Double(impulseResponse[index])
            guard sample.isFinite else {
                return .infinity
            }
            inputReal[index] = sample
        }
        var inputImaginary = [Double](repeating: 0, count: sampleCount)
        var outputReal = [Double](repeating: 0, count: sampleCount)
        var outputImaginary = [Double](repeating: 0, count: sampleCount)
        try cancellationCheck()
        transform.forward(
            real: &inputReal,
            imaginary: &inputImaginary,
            outputReal: &outputReal,
            outputImaginary: &outputImaginary
        )
        try cancellationCheck()

        var sampledPeak = 0.0
        for index in outputReal.indices {
            if index.isMultiple(of: 256) {
                try cancellationCheck()
            }
            sampledPeak = max(sampledPeak, hypot(outputReal[index], outputImaginary[index]))
        }

        // Bernstein's inequality bounds the unsampled response of this finite
        // trigonometric polynomial from its nearest oversampled FFT bin.
        let polynomialDegree = impulseResponse.count - 1
        let samplingCorrection = cos(
            Double.pi * Double(polynomialDegree) / Double(sampleCount)
        )
        guard samplingCorrection.isFinite, samplingCorrection > 0 else {
            return try coefficientL1UpperBoundDB(
                impulseResponse,
                cancellationCheck: cancellationCheck
            )
        }
        let upperBound = sampledPeak / samplingCorrection
        let sampledUpperBoundDB = 20 * log10(max(upperBound, .leastNonzeroMagnitude))
        return min(
            sampledUpperBoundDB,
            try coefficientL1UpperBoundDB(
                impulseResponse,
                cancellationCheck: cancellationCheck
            )
        )
    }

    static func coefficientL1UpperBoundDB(
        _ impulseResponse: [Float],
        cancellationCheck: @Sendable () throws -> Void
    ) throws -> Double {
        var coefficientL1Norm = 0.0
        for (index, sample) in impulseResponse.enumerated() {
            if index.isMultiple(of: 256) {
                try cancellationCheck()
            }
            let sample = Double(sample)
            guard sample.isFinite else {
                return .infinity
            }
            coefficientL1Norm += abs(sample)
        }
        return 20 * log10(max(coefficientL1Norm, .leastNonzeroMagnitude))
    }

    public static func interpolatedGainDB(
        frequency: Double,
        points: [EQMagnitudePoint]
    ) -> Double {
        guard let first = points.first else {
            return 0
        }
        guard frequency > first.frequency else {
            return first.gainDB
        }
        guard let last = points.last, frequency < last.frequency else {
            return points.last?.gainDB ?? first.gainDB
        }

        var lowerIndex = 0
        var upperIndex = points.count - 1
        while lowerIndex + 1 < upperIndex {
            let middle = (lowerIndex + upperIndex) / 2
            if points[middle].frequency <= frequency {
                lowerIndex = middle
            } else {
                upperIndex = middle
            }
        }

        let lower = points[lowerIndex]
        let upper = points[upperIndex]
        let lowerLog = log(lower.frequency)
        let upperLog = log(upper.frequency)
        let fraction = (log(frequency) - lowerLog) / (upperLog - lowerLog)
        return lower.gainDB + (upper.gainDB - lower.gainDB) * fraction
    }

    private static func validatedPoints(
        _ points: [EQMagnitudePoint]
    ) throws -> [EQMagnitudePoint] {
        guard points.count >= 2 else {
            throw MinimumPhaseFIRCompilerError.insufficientPoints
        }
        guard points.allSatisfy({
            $0.frequency.isFinite
                && $0.frequency > 0
                && $0.gainDB.isFinite
        }) else {
            throw MinimumPhaseFIRCompilerError.invalidPoint
        }

        let sorted = points.sorted { $0.frequency < $1.frequency }
        for index in 1..<sorted.count where sorted[index].frequency == sorted[index - 1].frequency {
            throw MinimumPhaseFIRCompilerError.duplicateFrequency(sorted[index].frequency)
        }
        return sorted
    }
}

struct ImpulseResponseSpectrum: Sendable {
    private let sampleRate: Double
    private let transformLength: Int
    private let magnitudes: [Double]

    init(
        impulseResponse: [Float],
        sampleRate: Double,
        cancellationCheck: @Sendable () throws -> Void = {}
    ) throws {
        guard sampleRate.isFinite, sampleRate > 0 else {
            throw MinimumPhaseFIRCompilerError.invalidSampleRate
        }
        guard !impulseResponse.isEmpty,
              impulseResponse.count <= MinimumPhaseFIRCompiler.tapCount else {
            throw MinimumPhaseFIRCompilerError.invalidImpulseResponse
        }

        try cancellationCheck()
        let transformLength = MinimumPhaseFIRCompiler.tapCount
        let transform = try ComplexDoubleDFT(length: transformLength)
        var inputReal = [Double](repeating: 0, count: transformLength)
        for index in impulseResponse.indices {
            if index.isMultiple(of: 256) {
                try cancellationCheck()
            }
            let sample = Double(impulseResponse[index])
            guard sample.isFinite else {
                throw MinimumPhaseFIRCompilerError.nonFiniteImpulseResponse
            }
            inputReal[index] = sample
        }
        var inputImaginary = [Double](repeating: 0, count: transformLength)
        var outputReal = [Double](repeating: 0, count: transformLength)
        var outputImaginary = [Double](repeating: 0, count: transformLength)
        try cancellationCheck()
        transform.forward(
            real: &inputReal,
            imaginary: &inputImaginary,
            outputReal: &outputReal,
            outputImaginary: &outputImaginary
        )
        try cancellationCheck()

        var magnitudes = [Double](repeating: 0, count: transformLength / 2 + 1)
        for index in magnitudes.indices {
            if index.isMultiple(of: 256) {
                try cancellationCheck()
            }
            magnitudes[index] = hypot(outputReal[index], outputImaginary[index])
        }

        self.sampleRate = sampleRate
        self.transformLength = transformLength
        self.magnitudes = magnitudes
    }

    func magnitudeDB(at frequency: Double) -> Double {
        guard frequency.isFinite else {
            return .nan
        }
        let boundedFrequency = min(max(frequency, 0), sampleRate / 2)
        let bin = boundedFrequency * Double(transformLength) / sampleRate
        let lowerIndex = min(Int(bin.rounded(.down)), magnitudes.count - 1)
        let upperIndex = min(lowerIndex + 1, magnitudes.count - 1)
        let fraction = bin - Double(lowerIndex)
        let magnitude = magnitudes[lowerIndex]
            + (magnitudes[upperIndex] - magnitudes[lowerIndex]) * fraction
        return 20 * log10(max(magnitude, .leastNonzeroMagnitude))
    }
}

private final class ComplexDoubleDFT {
    private let forwardSetup: vDSP_DFT_SetupD
    private let inverseSetup: vDSP_DFT_SetupD

    init(length: Int) throws {
        guard let forwardSetup = vDSP_DFT_zop_CreateSetupD(
            nil,
            vDSP_Length(length),
            .FORWARD
        ) else {
            throw MinimumPhaseFIRCompilerError.transformSetupFailed
        }
        guard let inverseSetup = vDSP_DFT_zop_CreateSetupD(
            forwardSetup,
            vDSP_Length(length),
            .INVERSE
        ) else {
            vDSP_DFT_DestroySetupD(forwardSetup)
            throw MinimumPhaseFIRCompilerError.transformSetupFailed
        }
        self.forwardSetup = forwardSetup
        self.inverseSetup = inverseSetup
    }

    deinit {
        vDSP_DFT_DestroySetupD(forwardSetup)
        vDSP_DFT_DestroySetupD(inverseSetup)
    }

    func forward(
        real: inout [Double],
        imaginary: inout [Double],
        outputReal: inout [Double],
        outputImaginary: inout [Double]
    ) {
        execute(
            setup: forwardSetup,
            real: &real,
            imaginary: &imaginary,
            outputReal: &outputReal,
            outputImaginary: &outputImaginary
        )
    }

    func inverse(
        real: inout [Double],
        imaginary: inout [Double],
        outputReal: inout [Double],
        outputImaginary: inout [Double]
    ) {
        execute(
            setup: inverseSetup,
            real: &real,
            imaginary: &imaginary,
            outputReal: &outputReal,
            outputImaginary: &outputImaginary
        )
    }

    private func execute(
        setup: vDSP_DFT_SetupD,
        real: inout [Double],
        imaginary: inout [Double],
        outputReal: inout [Double],
        outputImaginary: inout [Double]
    ) {
        real.withUnsafeBufferPointer { realBuffer in
            imaginary.withUnsafeBufferPointer { imaginaryBuffer in
                outputReal.withUnsafeMutableBufferPointer { outputRealBuffer in
                    outputImaginary.withUnsafeMutableBufferPointer { outputImaginaryBuffer in
                        vDSP_DFT_ExecuteD(
                            setup,
                            realBuffer.baseAddress!,
                            imaginaryBuffer.baseAddress!,
                            outputRealBuffer.baseAddress!,
                            outputImaginaryBuffer.baseAddress!
                        )
                    }
                }
            }
        }
    }
}
