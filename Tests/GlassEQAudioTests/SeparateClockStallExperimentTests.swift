import CoreAudio
import Foundation
import GlassEQCore
import Testing
@testable import GlassEQAudio

@Suite
struct SeparateClockStallExperimentTests {
    @Test(arguments: [48_000.0, 24_000.0, 16_000.0], [25, 100, 120])
    func playbackStall(outputRate: Double, stalledCallbacks: Int) throws {
        let experiment = try StallExperiment(outputRate: outputRate)
        let baseline = experiment.run(callbacks: 32)
        let before = experiment.runtime.snapshotMetrics()
        _ = experiment.run(callbacks: stalledCallbacks, playback: false)
        let stalled = experiment.runtime.snapshotMetrics()
        let recovery = experiment.run(callbacks: 64)
        let after = experiment.runtime.snapshotMetrics()

        #expect(after.adaptivePlaybackRenderFailures == 0)
        #expect(after.playbackUnderrunEvents == before.playbackUnderrunEvents)
        #expect(after.droppedBufferedFrames > before.droppedBufferedFrames)
        #expect(recovery.suffix(16).allSatisfy { !$0.isSilent })
        #expect(recovery.suffix(16).allSatisfy { $0.bufferedFrames < experiment.primeFrames })
        let baselineAge = try #require(baseline.last?.midpointAgeMS)
        #expect(recovery.suffix(16).allSatisfy { abs(($0.midpointAgeMS ?? .infinity) - baselineAge) < 2 })
        if stalledCallbacks >= 100 {
            #expect(stalled.currentBufferedFrames == SeparateClockAudioBackend.runtimeRingCapacityFrames)
            #expect(stalled.droppedInputFrames > before.droppedInputFrames)
            #expect(recovery.first?.isSilent == true)
            #expect(recovery.filter { !$0.isSilent }.allSatisfy {
                abs(($0.midpointAgeMS ?? .infinity) - baselineAge) < 2
            })
        } else {
            #expect(stalled.droppedInputFrames == before.droppedInputFrames)
        }
        try experiment.report(
            scenario: "playback-stall-\(stalledCallbacks * 20)ms",
            baseline: baseline, recovery: recovery, before: before
        )
    }

    @Test(arguments: [48_000.0, 24_000.0, 16_000.0])
    func captureStall(outputRate: Double) throws {
        let experiment = try StallExperiment(outputRate: outputRate)
        let baseline = experiment.run(callbacks: 32)
        let before = experiment.runtime.snapshotMetrics()
        let starvation = experiment.run(callbacks: 25, capture: false)
        #expect(starvation.suffix(16).allSatisfy { $0.isSilent })
        #expect(experiment.runtime.snapshotMetrics().playbackUnderrunEvents > before.playbackUnderrunEvents)
        let recovery = experiment.run(callbacks: 64)
        #expect(recovery.suffix(16).allSatisfy { !$0.isSilent })
        let baselineAge = try #require(baseline.last?.midpointAgeMS)
        #expect(recovery.suffix(16).allSatisfy { abs(($0.midpointAgeMS ?? .infinity) - baselineAge) < 2 })
        #expect(experiment.runtime.snapshotMetrics().adaptivePlaybackRenderFailures == 0)
        try experiment.report(scenario: "capture-stall-500ms", baseline: baseline, recovery: recovery, before: before)
    }

    @Test(arguments: [48_000.0, 24_000.0, 16_000.0], [12, 100])
    func alternatingStalls(outputRate: Double, playbackStallCallbacks: Int) throws {
        let experiment = try StallExperiment(outputRate: outputRate)
        let baseline = experiment.run(callbacks: 32)
        let before = experiment.runtime.snapshotMetrics()
        for _ in 0..<6 {
            _ = experiment.run(callbacks: 8, capture: false)
            _ = experiment.run(callbacks: 12)
            _ = experiment.run(callbacks: playbackStallCallbacks, playback: false)
            _ = experiment.run(callbacks: 12)
        }
        let settled = experiment.runtime.snapshotMetrics()
        let recovery = experiment.run(callbacks: 64)
        let after = experiment.runtime.snapshotMetrics()
        #expect(after.adaptivePlaybackRenderFailures == 0)
        #expect(after.playbackUnderrunEvents == settled.playbackUnderrunEvents)
        #expect(after.droppedBufferedFrames == settled.droppedBufferedFrames)
        #expect(after.droppedInputFrames == settled.droppedInputFrames)
        #expect(recovery.allSatisfy { !$0.isSilent })
        #expect(recovery.suffix(16).allSatisfy { $0.bufferedFrames < experiment.primeFrames })
        let baselineAge = try #require(baseline.last?.midpointAgeMS)
        #expect(recovery.suffix(16).allSatisfy { abs(($0.midpointAgeMS ?? .infinity) - baselineAge) < 2 })
        try experiment.report(
            scenario: "six-alternating-stalls-\(playbackStallCallbacks * 20)ms-playback",
            baseline: baseline, recovery: recovery, before: before
        )
    }

    @Test(arguments: [48_000.0, 24_000.0, 16_000.0])
    func sourceStopsWhileRingIsFull(outputRate: Double) throws {
        let experiment = try StallExperiment(outputRate: outputRate)
        let baseline = experiment.run(callbacks: 32)
        let before = experiment.runtime.snapshotMetrics()
        _ = experiment.run(callbacks: 100, playback: false)
        let full = experiment.runtime.snapshotMetrics()
        _ = experiment.run(callbacks: 20, playback: false, silentSource: true)
        #expect(experiment.runtime.snapshotMetrics().droppedInputFrames == full.droppedInputFrames + 19_200)
        let recovery = experiment.run(callbacks: 64, silentSource: true)
        #expect(recovery.allSatisfy { $0.isSilent })
        #expect(experiment.runtime.snapshotMetrics().adaptivePlaybackRenderFailures == 0)
        try experiment.report(scenario: "source-stops-during-overflow", baseline: baseline, recovery: recovery, before: before)
    }

    @Test(arguments: [48_000.0, 24_000.0, 16_000.0])
    func smallCallbacksFlushConverterHistory(outputRate: Double) throws {
        let experiment = try StallExperiment(outputRate: outputRate, captureFrames: 48, primeFrames: 192)
        let baseline = experiment.run(callbacks: 32)
        let before = experiment.runtime.snapshotMetrics()
        _ = experiment.run(callbacks: 1_800, playback: false)
        _ = experiment.run(callbacks: 320, playback: false, silentSource: true)
        #expect(experiment.runtime.snapshotMetrics().droppedInputFrames > before.droppedInputFrames)
        let recovery = experiment.run(callbacks: 128, silentSource: true)
        #expect(recovery.allSatisfy { $0.isSilent })
        #expect(experiment.runtime.snapshotMetrics().playedFrames > before.playedFrames)
        #expect(experiment.runtime.snapshotMetrics().adaptivePlaybackRenderFailures == 0)
        try experiment.report(scenario: "source-stops-small-callbacks", baseline: baseline, recovery: recovery, before: before)
        let resumed = experiment.run(callbacks: 128)
        let baselineAge = try #require(baseline.last?.midpointAgeMS)
        #expect(resumed.suffix(16).allSatisfy { !$0.isSilent })
        #expect(resumed.suffix(16).allSatisfy { abs(($0.midpointAgeMS ?? .infinity) - baselineAge) < 2 })
    }

    @Test(arguments: [48_000.0, 24_000.0, 16_000.0], [false, true])
    func transitionDuringOverflow(outputRate: Double, convolution: Bool) throws {
        let experiment = try StallExperiment(outputRate: outputRate, preampDB: -12)
        _ = experiment.run(callbacks: 32)
        let before = experiment.runtime.snapshotMetrics()
        _ = experiment.run(callbacks: 100, playback: false)
        let written = experiment.runtime.ringBuffer.nextWriteSequence()
        var profile = EQProfile.flatParametric
        if convolution {
            var impulse = [Float](repeating: 0, count: ImpulseResponseSource.maximumFrameCount)
            impulse[0] = 1
            profile = EQProfile(
                name: "Identity FIR", mode: .convolution, filters: [],
                convolution: .impulseResponse(ImpulseResponseSource(sampleRate: 48_000, samples: impulse))
            )
        } else {
            profile.isBypassed = true
        }
        let target = experiment.runtime.publishPendingDSPConfig(
            EQRenderConfiguration(profile: profile, sampleRate: 48_000, channelCount: 2)
        )
        _ = experiment.run(callbacks: 20, playback: false)
        #expect(experiment.runtime.ringBuffer.nextWriteSequence() == written)
        #expect(!experiment.runtime.dspTransitionProgress().hasCompleted(target))
        var completedAt: Int?
        var recovery: [StallExperiment.Observation] = []
        for callback in 0..<64 {
            recovery += experiment.run(callbacks: 1)
            if completedAt == nil && experiment.runtime.dspTransitionProgress().hasCompleted(target) {
                completedAt = callback + 1
            }
        }
        #expect(completedAt != nil)
        #expect(recovery.suffix(16).allSatisfy { !$0.isSilent })
        // Both destinations have unity gain. Decoding a recent timestamp also verifies that
        // the output has reached the new bank, rather than merely publishing completion.
        #expect(recovery.suffix(16).allSatisfy {
            $0.midpointAgeMS.map { (0..<100).contains($0) } ?? false
        })
        #expect(experiment.runtime.snapshotMetrics().adaptivePlaybackRenderFailures == 0)
        try experiment.report(
            scenario: convolution ? "FIR-transition-during-overflow" : "bypass-transition-during-overflow",
            baseline: [], recovery: recovery, before: before, completedAt: completedAt
        )
    }
}

// Calls the real DSP, ring, servo, resampler, and Core Audio PCM converter without creating
// a device or process tap. A default tick is 960 capture frames / 20 ms. Withholding a
// callback advances its timeline but does not sleep, block a realtime thread, or invoke HAL.
private final class StallExperiment {
    struct Observation {
        var isSilent: Bool
        var midpointAgeMS: Double?
        var lastNonzeroFrame: Int?
        var bufferedFrames: Int
    }

    let runtime: SeparateClockAudioBackend.AudioRuntime
    let primeFrames: Int
    let captureFrames: Int
    let outputRate: Double
    let outputFrames: Int
    private var sourceFrame = 0

    init(outputRate: Double, preampDB: Double = 0, captureFrames: Int = 960, primeFrames: Int = 3_072) throws {
        self.captureFrames = captureFrames
        self.primeFrames = primeFrames
        self.outputRate = outputRate
        self.outputFrames = Int(Double(captureFrames) * outputRate / 48_000)
        runtime = SeparateClockAudioBackend.AudioRuntime(
            renderConfiguration: EQRenderConfiguration(
                profile: EQProfile(name: "Timestamp signal", mode: .parametric, preampDB: preampDB, filters: []),
                sampleRate: 48_000, channelCount: 2
            ),
            ringCapacityFrames: SeparateClockAudioBackend.runtimeRingCapacityFrames,
            scratchFrames: 1_024, captureCallbackFrames: captureFrames, playbackPrimeFrames: primeFrames
        )
        try runtime.configurePlayback(primeFrames: primeFrames, outputSampleRate: outputRate)
    }

    func run(callbacks: Int, capture: Bool = true, playback: Bool = true, silentSource: Bool = false) -> [Observation] {
        var observations: [Observation] = []
        for _ in 0..<callbacks {
            if capture {
                var input = [Float](repeating: 0, count: captureFrames * 2)
                if !silentSource {
                    for frame in 0..<captureFrames {
                        let signal = Float(0.1 + Double(sourceFrame + frame) / 1_000_000)
                        input[frame * 2] = signal
                        input[frame * 2 + 1] = -signal
                    }
                }
                withBuffer(&input) { runtime.capture(inputData: UnsafePointer($0)) }
            }
            if playback {
                var output = [Float](repeating: .nan, count: outputFrames * 2)
                withBuffer(&output) {
                    runtime.playback(outputData: $0, outputSampleTime: Double(sourceFrame) * outputRate / 48_000)
                }
                #expect(output.allSatisfy { $0.isFinite })
                #expect(stride(from: 0, to: output.count, by: 2).allSatisfy {
                    abs(output[$0] + output[$0 + 1]) < 0.000_001
                })
                let lastNonzero = stride(from: output.count - 2, through: 0, by: -2).first {
                    abs(output[$0]) > 0.000_1
                }.map { $0 / 2 }
                let midpoint = Double(output[(outputFrames / 2) * 2])
                let age = midpoint > 0.05
                    ? (Double(sourceFrame + captureFrames) - (midpoint - 0.1) * 1_000_000) / 48
                    : nil
                observations.append(Observation(
                    isSilent: lastNonzero == nil,
                    midpointAgeMS: age,
                    lastNonzeroFrame: lastNonzero,
                    bufferedFrames: runtime.ringBuffer.occupancyFrames()
                ))
            }
            sourceFrame += captureFrames
        }
        return observations
    }

    func report(
        scenario: String, baseline: [Observation], recovery: [Observation],
        before: AudioEngineMetrics, completedAt: Int? = nil
    ) throws {
        let after = runtime.snapshotMetrics()
        let baselineAge = baseline.last?.midpointAgeMS
        let freshCallback = baselineAge.flatMap { baselineAge in
            recovery.firstIndex { observation in
                observation.midpointAgeMS.map { abs($0 - baselineAge) < 20 } ?? false
            }.map { $0 + 1 }
        }
        let lastAudible = recovery.enumerated().compactMap { index, observation in
            observation.lastNonzeroFrame.map { Double(index * outputFrames + $0 + 1) / outputRate * 1_000 }
        }.last
        let report = Report(
            scenario: scenario, outputRate: outputRate,
            baselineAgeMS: baselineAge,
            firstRecoveryAgeMS: baseline.isEmpty ? nil : recovery.first?.midpointAgeMS,
            settledAgeMS: baseline.isEmpty ? nil : recovery.last?.midpointAgeMS,
            freshAtCallback: freshCallback,
            firstNonSilentCallback: recovery.firstIndex { !$0.isSilent }.map { $0 + 1 },
            lastNonSilentEndMS: lastAudible,
            completionCallback: completedAt,
            droppedInput: after.droppedInputFrames - before.droppedInputFrames,
            droppedBuffered: after.droppedBufferedFrames - before.droppedBufferedFrames,
            underruns: after.playbackUnderrunEvents - before.playbackUnderrunEvents,
            renderFailures: after.adaptivePlaybackRenderFailures - before.adaptivePlaybackRenderFailures,
            timestampJumps: after.playbackTimestampDiscontinuities - before.playbackTimestampDiscontinuities,
            finalBufferedMin: recovery.suffix(16).map(\.bufferedFrames).min() ?? 0,
            finalBufferedMax: recovery.suffix(16).map(\.bufferedFrames).max() ?? 0
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(report)
        print("RING_EXPERIMENT \(String(decoding: data, as: UTF8.self))")
    }

    private struct Report: Encodable {
        var scenario: String
        var outputRate: Double
        var baselineAgeMS: Double?
        var firstRecoveryAgeMS: Double?
        var settledAgeMS: Double?
        var freshAtCallback: Int?
        var firstNonSilentCallback: Int?
        var lastNonSilentEndMS: Double?
        var completionCallback: Int?
        var droppedInput: UInt64
        var droppedBuffered: UInt64
        var underruns: UInt64
        var renderFailures: UInt64
        var timestampJumps: UInt64
        var finalBufferedMin: Int
        var finalBufferedMax: Int
    }

    private func withBuffer(_ samples: inout [Float], _ body: (UnsafeMutablePointer<AudioBufferList>) -> Void) {
        let buffers = AudioBufferList.allocate(maximumBuffers: 1)
        defer { free(buffers.unsafeMutablePointer) }
        samples.withUnsafeMutableBufferPointer {
            buffers[0] = AudioBuffer(
                mNumberChannels: 2,
                mDataByteSize: UInt32($0.count * MemoryLayout<Float>.stride), mData: $0.baseAddress
            )
            body(buffers.unsafeMutablePointer)
        }
    }
}
