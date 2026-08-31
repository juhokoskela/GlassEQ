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

    public static func compile(
        points: [EQMagnitudePoint],
        sampleRate: Double
    ) throws -> [Float] {
        guard sampleRate.isFinite, sampleRate > 0 else {
            throw MinimumPhaseFIRCompilerError.invalidSampleRate
        }

        let sortedPoints = try validatedPoints(points)
        let transform = try ComplexDoubleDFT(length: tapCount)
        let halfCount = tapCount / 2
        let nyquist = sampleRate / 2
        var logMagnitudeReal = [Double](repeating: 0, count: tapCount)
        var logMagnitudeImaginary = [Double](repeating: 0, count: tapCount)

        for bin in 0...halfCount {
            let frequency = Double(bin) * nyquist / Double(halfCount)
            let gainDB = interpolatedGainDB(
                frequency: frequency,
                points: sortedPoints
            )
            let logAmplitude = gainDB * log(10) / 20
            logMagnitudeReal[bin] = logAmplitude
            if bin > 0, bin < halfCount {
                logMagnitudeReal[tapCount - bin] = logAmplitude
            }
        }

        var cepstrumReal = [Double](repeating: 0, count: tapCount)
        var cepstrumImaginary = [Double](repeating: 0, count: tapCount)
        transform.inverse(
            real: &logMagnitudeReal,
            imaginary: &logMagnitudeImaginary,
            outputReal: &cepstrumReal,
            outputImaginary: &cepstrumImaginary
        )
        let inverseScale = 1 / Double(tapCount)
        cepstrumReal[0] *= inverseScale
        for index in 1..<halfCount {
            cepstrumReal[index] *= 2 * inverseScale
        }
        cepstrumReal[halfCount] *= inverseScale
        for index in (halfCount + 1)..<tapCount {
            cepstrumReal[index] = 0
        }
        for index in cepstrumImaginary.indices {
            cepstrumImaginary[index] = 0
        }

        var minimumPhaseLogReal = [Double](repeating: 0, count: tapCount)
        var minimumPhaseLogImaginary = [Double](repeating: 0, count: tapCount)
        transform.forward(
            real: &cepstrumReal,
            imaginary: &cepstrumImaginary,
            outputReal: &minimumPhaseLogReal,
            outputImaginary: &minimumPhaseLogImaginary
        )

        for index in 0..<tapCount {
            let amplitude = exp(minimumPhaseLogReal[index])
            let phase = minimumPhaseLogImaginary[index]
            minimumPhaseLogReal[index] = amplitude * cos(phase)
            minimumPhaseLogImaginary[index] = amplitude * sin(phase)
        }

        var impulseReal = [Double](repeating: 0, count: tapCount)
        var impulseImaginary = [Double](repeating: 0, count: tapCount)
        transform.inverse(
            real: &minimumPhaseLogReal,
            imaginary: &minimumPhaseLogImaginary,
            outputReal: &impulseReal,
            outputImaginary: &impulseImaginary
        )

        var impulse = [Float](repeating: 0, count: tapCount)
        for index in 0..<tapCount {
            let value = impulseReal[index] * inverseScale
            guard value.isFinite else {
                throw MinimumPhaseFIRCompilerError.nonFiniteImpulseResponse
            }
            impulse[index] = Float(value)
        }
        return impulse
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
