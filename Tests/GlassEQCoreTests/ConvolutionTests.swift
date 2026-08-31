@testable import GlassEQCore
import Foundation
import Synchronization
import Testing

@Suite
struct ConvolutionTests {
    @Test
    func flatCurveCompilesToIdentityImpulse() throws {
        let impulse = try MinimumPhaseFIRCompiler.compile(
            points: [
                EQMagnitudePoint(frequency: 20, gainDB: 0),
                EQMagnitudePoint(frequency: 20_000, gainDB: 0)
            ],
            sampleRate: 48_000
        )

        #expect(abs(impulse[0] - 1) < 0.000_01)
        #expect(impulse.dropFirst().allSatisfy { abs($0) < 0.000_01 })
    }

    @Test
    func curveCompilerMatchesRequestedMagnitude() throws {
        let points = [
            EQMagnitudePoint(frequency: 20, gainDB: 6),
            EQMagnitudePoint(frequency: 1_000, gainDB: -3),
            EQMagnitudePoint(frequency: 20_000, gainDB: 2)
        ]
        let sampleRate = 48_000.0
        let impulse = try MinimumPhaseFIRCompiler.compile(
            points: points,
            sampleRate: sampleRate
        )

        for frequency in [0.0, 20, 100, 1_000, 8_000, 20_000, 24_000] {
            let expected = MinimumPhaseFIRCompiler.interpolatedGainDB(
                frequency: frequency,
                points: points
            )
            let actual = magnitudeDB(
                impulse: impulse,
                frequency: frequency,
                sampleRate: sampleRate
            )
            #expect(abs(actual - expected) < 0.05)
        }
    }

    @Test
    func curveCompilerUsesIdentityAboveRouteCeilingRegardlessOfPointOrder() throws {
        let sortedPoints = [
            EQMagnitudePoint(frequency: 20, gainDB: 0),
            EQMagnitudePoint(frequency: 7_200, gainDB: 0),
            EQMagnitudePoint(frequency: 7_300, gainDB: 12)
        ]
        let sortedImpulse = try MinimumPhaseFIRCompiler.compile(
            points: sortedPoints,
            sampleRate: 16_000,
            maximumUsableFrequency: 7_200
        )
        let unsortedImpulse = try MinimumPhaseFIRCompiler.compile(
            points: [sortedPoints[2], sortedPoints[0], sortedPoints[1]],
            sampleRate: 16_000,
            maximumUsableFrequency: 7_200
        )

        #expect(sortedImpulse == unsortedImpulse)
        #expect(abs(sortedImpulse[0] - 1) < 0.000_01)
        #expect(sortedImpulse.dropFirst().allSatisfy { abs($0) < 0.000_01 })
    }

    @Test
    func curveCompilerKeepsGainAtExactRouteCeiling() throws {
        let impulse = try MinimumPhaseFIRCompiler.compile(
            points: [
                EQMagnitudePoint(frequency: 20, gainDB: 0),
                EQMagnitudePoint(frequency: 7_000, gainDB: 6),
                EQMagnitudePoint(frequency: 7_125, gainDB: 12)
            ],
            sampleRate: 16_000,
            maximumUsableFrequency: 7_000
        )

        #expect(abs(magnitudeDB(
            impulse: impulse,
            frequency: 7_000,
            sampleRate: 16_000
        ) - 6) < 0.05)
        #expect(abs(magnitudeDB(
            impulse: impulse,
            frequency: 7_125,
            sampleRate: 16_000
        )) < 0.05)
    }

    @Test
    func routeAdjustmentPreservesInterpolatedCeilingAndZerosLaterPoints() {
        let points = [
            EQMagnitudePoint(frequency: 20, gainDB: 0),
            EQMagnitudePoint(frequency: 7_000, gainDB: 6),
            EQMagnitudePoint(frequency: 7_300, gainDB: 12),
            EQMagnitudePoint(frequency: 8_000, gainDB: 9),
            EQMagnitudePoint(frequency: 9_000, gainDB: -3)
        ]
        let expectedCeilingGain = MinimumPhaseFIRCompiler.interpolatedGainDB(
            frequency: 7_200,
            points: points
        )

        let adjusted = MinimumPhaseFIRCompiler.routeAdjustedPoints(
            points,
            maximumUsableFrequency: 7_200,
            nyquistFrequency: 8_000
        )

        #expect(adjusted.map(\.frequency) == [20, 7_000, 7_200, 7_300, 8_000])
        #expect(abs(adjusted[2].gainDB - expectedCeilingGain) < 0.000_000_001)
        #expect(adjusted[3].gainDB == 0)
        #expect(adjusted[4].gainDB == 0)
    }

    @Test
    func curveEndingBelowRouteCeilingTapersFromCeilingToNyquist() throws {
        let impulse = try MinimumPhaseFIRCompiler.compile(
            points: [
                EQMagnitudePoint(frequency: 20, gainDB: 0),
                EQMagnitudePoint(frequency: 7_000, gainDB: 6)
            ],
            sampleRate: 16_000,
            maximumUsableFrequency: 7_200
        )

        #expect(abs(magnitudeDB(
            impulse: impulse,
            frequency: 7_200,
            sampleRate: 16_000
        ) - 6) < 0.05)
        #expect(abs(magnitudeDB(
            impulse: impulse,
            frequency: 8_000,
            sampleRate: 16_000
        )) < 0.05)
    }

    @Test
    func curveEndpointsClampToFirstAndLastGain() {
        let points = [
            EQMagnitudePoint(frequency: 20, gainDB: 6),
            EQMagnitudePoint(frequency: 1_000, gainDB: -3),
            EQMagnitudePoint(frequency: 20_000, gainDB: 2)
        ]

        #expect(MinimumPhaseFIRCompiler.interpolatedGainDB(frequency: 0, points: points) == 6)
        #expect(MinimumPhaseFIRCompiler.interpolatedGainDB(frequency: 24_000, points: points) == 2)
    }

    @Test
    func duplicateCurveFrequencyIsRejected() {
        #expect(throws: MinimumPhaseFIRCompilerError.duplicateFrequency(1_000)) {
            _ = try MinimumPhaseFIRCompiler.compile(
                points: [
                    EQMagnitudePoint(frequency: 1_000, gainDB: 1),
                    EQMagnitudePoint(frequency: 1_000, gainDB: 2)
                ],
                sampleRate: 48_000
            )
        }
    }

    @Test
    func curveCompilationChecksCancellationWithinSynthesisLoop() {
        let checkCount = Mutex(0)

        #expect(throws: FIRAnalysisCancellation.requested) {
            _ = try MinimumPhaseFIRCompiler.compile(
                points: [
                    EQMagnitudePoint(frequency: 20, gainDB: 0),
                    EQMagnitudePoint(frequency: 20_000, gainDB: 6)
                ],
                sampleRate: 48_000,
                maximumUsableFrequency: 20_000,
                cancellationCheck: {
                    let count = checkCount.withLock { count in
                        count += 1
                        return count
                    }
                    if count == 10 {
                        throw FIRAnalysisCancellation.requested
                    }
                }
            )
        }
        #expect(checkCount.withLock { $0 } == 10)
    }

    @Test
    func certifiedPeakAnalysisChecksCancellationWithinInputLoop() {
        let checkCount = Mutex(0)

        #expect(throws: FIRAnalysisCancellation.requested) {
            _ = try MinimumPhaseFIRCompiler.certifiedPeakMagnitudeDB(
                impulseResponse: [Float](
                    repeating: 1 / Float(MinimumPhaseFIRCompiler.tapCount),
                    count: MinimumPhaseFIRCompiler.tapCount
                ),
                cancellationCheck: {
                    let count = checkCount.withLock { count in
                        count += 1
                        return count
                    }
                    if count == 10 {
                        throw FIRAnalysisCancellation.requested
                    }
                }
            )
        }
        #expect(checkCount.withLock { $0 } == 10)
    }

    @Test
    func hybridConvolverPreservesHeadTailSeams() throws {
        let seamTaps = [510, 511, 512, 513, 514, 767, 768, 769, 1_023, 1_024]
        var impulse = [Float](repeating: 0, count: 1_025)
        for (offset, tap) in seamTaps.enumerated() {
            impulse[tap] = Float(offset + 1) / 10
        }

        let output = try render(
            input: [1] + [Float](repeating: 0, count: 1_536),
            impulse: impulse,
            chunkSizes: [1, 31, 480, 7, 64, 13, 256]
        )

        for index in output.indices {
            let expected = index < impulse.count ? impulse[index] : 0
            #expect(abs(output[index] - expected) < 0.000_02)
        }
    }

    @Test
    func hybridConvolverMatchesDirectConvolutionAcrossPathologicalChunks() throws {
        var generator = DeterministicGenerator(state: 0xC0FFEE)
        let impulse = (0..<1_281).map { index in
            generator.nextFloat() * exp(-Float(index) / 220) * 0.03
        }
        let input = (0..<4_321).map { _ in generator.nextFloat() * 0.5 }
        let expected = directConvolution(input: input, impulse: impulse)
        let actual = try render(
            input: input,
            impulse: impulse,
            chunkSizes: [1, 31, 480, 7, 64, 13, 256]
        )

        #expect(actual.count == expected.count)
        for index in actual.indices {
            #expect(abs(actual[index] - expected[index]) < 0.000_05)
        }
    }

    @Test
    func importedImpulseResponseRendersSuppliedSamplesWithoutPhaseReconstruction() throws {
        let impulse: [Float] = [0, 0.25, -0.5, 0.125]
        let profile = EQProfile(
            name: "Imported IR",
            mode: .convolution,
            filters: [],
            convolution: .impulseResponse(ImpulseResponseSource(
                sampleRate: 48_000,
                samples: impulse
            ))
        )
        var processor = EQProcessor(renderConfiguration: try EQRenderConfiguration.prepare(
            profile: profile,
            sampleRate: 48_000,
            channelCount: 1
        ))
        var samples: [Float] = [1] + [Float](repeating: 0, count: 7)

        processor.processInterleaved(&samples, channelCount: 1)

        for index in samples.indices {
            #expect(abs(samples[index] - (index < impulse.count ? impulse[index] : 0)) < 0.000_01)
        }
    }

    @Test
    func importedImpulseResponseRejectsMismatchedRenderRate() {
        let profile = EQProfile(
            name: "48 kHz IR",
            mode: .convolution,
            filters: [],
            convolution: .impulseResponse(ImpulseResponseSource(
                sampleRate: 48_000,
                samples: [1]
            ))
        )

        #expect(throws: HybridConvolverError.sampleRateMismatch(
            source: 48_000,
            destination: 96_000
        )) {
            _ = try EQRenderConfiguration.prepare(
                profile: profile,
                sampleRate: 96_000,
                channelCount: 1
            )
        }
    }

    private func render(
        input: [Float],
        impulse: [Float],
        chunkSizes: [Int]
    ) throws -> [Float] {
        let kernel = try PreparedConvolutionKernel(impulseResponse: impulse)
        var convolver = try RealtimeHybridConvolver(kernel: kernel)
        var output = input
        var timing = EQRenderWorkTiming()
        var frame = 0
        var chunkIndex = 0
        while frame < input.count {
            let chunk = min(chunkSizes[chunkIndex % chunkSizes.count], input.count - frame)
            output.withUnsafeMutableBufferPointer { storage in
                let samples = UnsafeMutableBufferPointer(
                    start: storage.baseAddress! + frame,
                    count: chunk
                )
                let diagnostics = convolver.processInterleavedChannel(
                    samples,
                    frameCount: chunk,
                    channel: 0,
                    channelCount: 1,
                    preampLinearGain: 1
                )
                timing.merge(diagnostics.workTiming)
            }
            frame += chunk
            chunkIndex += 1
        }
        #expect(timing.tailDeadlineMisses == 0)
        return output
    }

    private func directConvolution(
        input: [Float],
        impulse: [Float]
    ) -> [Float] {
        var output = [Float](repeating: 0, count: input.count)
        for frame in input.indices {
            var value: Float = 0
            let lastTap = min(frame, impulse.count - 1)
            for tap in 0...lastTap {
                value += impulse[tap] * input[frame - tap]
            }
            output[frame] = value
        }
        return output
    }

    private func magnitudeDB(
        impulse: [Float],
        frequency: Double,
        sampleRate: Double
    ) -> Double {
        let omega = 2 * Double.pi * frequency / sampleRate
        var real = 0.0
        var imaginary = 0.0
        for (index, sample) in impulse.enumerated() {
            let phase = -omega * Double(index)
            real += Double(sample) * cos(phase)
            imaginary += Double(sample) * sin(phase)
        }
        return 20 * log10(max(hypot(real, imaginary), .leastNonzeroMagnitude))
    }
}

private enum FIRAnalysisCancellation: Error {
    case requested
}

private struct DeterministicGenerator {
    var state: UInt64

    mutating func nextFloat() -> Float {
        state = state &* 6_364_136_223_846_793_005 &+ 1
        let normalized = Float((state >> 40) & 0xFFFFFF) / Float(0xFFFFFF)
        return normalized * 2 - 1
    }
}
