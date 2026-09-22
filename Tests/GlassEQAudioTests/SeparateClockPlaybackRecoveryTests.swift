import CoreAudioTypes
import GlassEQCore
import Testing
@testable import GlassEQAudio

@Suite
struct SeparateClockPlaybackRecoveryTests {
    @Test(arguments: [48_000.0, 24_000.0, 16_000.0], [25, 100, 120])
    func recoversAfterPlaybackStall(outputRate: Double, stalledCallbacks: Int) throws {
        let harness = try PlaybackRecoveryHarness(outputRate: outputRate)
        let baseline = harness.run(callbacks: 32)
        let before = harness.runtime.snapshotMetrics()
        _ = harness.run(callbacks: stalledCallbacks, playback: false)
        let stalled = harness.runtime.snapshotMetrics()
        let recovery = harness.run(callbacks: 64)
        let after = harness.runtime.snapshotMetrics()

        #expect(after.adaptivePlaybackRenderFailures == 0)
        #expect(after.playbackUnderrunEvents == before.playbackUnderrunEvents)
        #expect(after.droppedBufferedFrames > before.droppedBufferedFrames)
        let baselineAge = try #require(baseline.last?.midpointAgeMS)
        try harness.expectSettled(recovery, baselineAge: baselineAge)
        if stalledCallbacks >= 100 {
            #expect(stalled.currentBufferedFrames == SeparateClockAudioBackend.runtimeRingCapacityFrames)
            #expect(stalled.droppedInputFrames > before.droppedInputFrames)
            #expect(recovery.first?.isSilent == true)
            #expect(
                recovery.filter { !$0.isSilent }.allSatisfy {
                    $0.midpointAgeMS.map { abs($0 - baselineAge) < 2 } == true
                })
        } else {
            #expect(stalled.droppedInputFrames == before.droppedInputFrames)
        }
    }

    @Test(arguments: [48_000.0, 24_000.0, 16_000.0])
    func reprimesAfterCaptureStall(outputRate: Double) throws {
        let harness = try PlaybackRecoveryHarness(outputRate: outputRate)
        let baseline = harness.run(callbacks: 32)
        let before = harness.runtime.snapshotMetrics()
        let starvation = harness.run(callbacks: 25, capture: false)
        #expect(starvation.suffix(16).allSatisfy { $0.isSilent })
        #expect(harness.runtime.snapshotMetrics().playbackUnderrunEvents > before.playbackUnderrunEvents)
        let recovery = harness.run(callbacks: 64)
        let baselineAge = try #require(baseline.last?.midpointAgeMS)
        try harness.expectSettled(recovery, baselineAge: baselineAge)
        #expect(harness.runtime.snapshotMetrics().adaptivePlaybackRenderFailures == 0)
    }

    @Test(arguments: [48_000.0, 24_000.0, 16_000.0], [12, 100])
    func settlesAfterAlternatingStalls(outputRate: Double, playbackStallCallbacks: Int) throws {
        let harness = try PlaybackRecoveryHarness(outputRate: outputRate)
        let baseline = harness.run(callbacks: 32)
        for _ in 0..<6 {
            _ = harness.run(callbacks: 8, capture: false)
            _ = harness.run(callbacks: 12)
            _ = harness.run(callbacks: playbackStallCallbacks, playback: false)
            _ = harness.run(callbacks: 12)
        }
        let settled = harness.runtime.snapshotMetrics()
        let recovery = harness.run(callbacks: 64)
        let after = harness.runtime.snapshotMetrics()
        #expect(after.adaptivePlaybackRenderFailures == 0)
        #expect(after.playbackUnderrunEvents == settled.playbackUnderrunEvents)
        #expect(after.droppedBufferedFrames == settled.droppedBufferedFrames)
        #expect(after.droppedInputFrames == settled.droppedInputFrames)
        #expect(recovery.allSatisfy { !$0.isSilent })
        let baselineAge = try #require(baseline.last?.midpointAgeMS)
        try harness.expectSettled(recovery, baselineAge: baselineAge)
    }

    @Test(arguments: [48_000.0, 24_000.0, 16_000.0])
    func doesNotReplayStoppedSourceAfterOverflow(outputRate: Double) throws {
        let harness = try PlaybackRecoveryHarness(outputRate: outputRate)
        _ = harness.run(callbacks: 32)
        _ = harness.run(callbacks: 100, playback: false)
        let full = harness.runtime.snapshotMetrics()
        _ = harness.run(callbacks: 20, playback: false, silentSource: true)
        #expect(harness.runtime.snapshotMetrics().droppedInputFrames == full.droppedInputFrames + 19_200)
        let recovery = harness.run(callbacks: 64, silentSource: true)
        #expect(recovery.allSatisfy { $0.isSilent })
        #expect(harness.runtime.snapshotMetrics().adaptivePlaybackRenderFailures == 0)
    }

    @Test(arguments: [48_000.0, 24_000.0, 16_000.0])
    func smallCallbacksFlushConverterHistory(outputRate: Double) throws {
        let harness = try PlaybackRecoveryHarness(outputRate: outputRate, captureFrames: 48, primeFrames: 192)
        let baseline = harness.run(callbacks: 32)
        let before = harness.runtime.snapshotMetrics()
        _ = harness.run(callbacks: 1_800, playback: false)
        _ = harness.run(callbacks: 320, playback: false, silentSource: true)
        #expect(harness.runtime.snapshotMetrics().droppedInputFrames > before.droppedInputFrames)
        let recovery = harness.run(callbacks: 128, silentSource: true)
        #expect(recovery.allSatisfy { $0.isSilent })
        #expect(harness.runtime.snapshotMetrics().playedFrames > before.playedFrames)
        #expect(harness.runtime.snapshotMetrics().adaptivePlaybackRenderFailures == 0)
        let resumed = harness.run(callbacks: 128)
        let baselineAge = try #require(baseline.last?.midpointAgeMS)
        try harness.expectSettled(resumed, baselineAge: baselineAge)
    }

    @Test(arguments: [48_000.0, 24_000.0, 16_000.0], [false, true])
    func transitionCompletesWithDestinationAudioAfterOverflow(outputRate: Double, convolution: Bool) throws {
        let harness = try PlaybackRecoveryHarness(outputRate: outputRate, preampDB: -12)
        _ = harness.run(callbacks: 32)
        _ = harness.run(callbacks: 100, playback: false)
        let written = harness.runtime.ringBuffer.nextWriteSequence()
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
        let target = harness.runtime.publishPendingDSPConfig(
            EQRenderConfiguration(profile: profile, sampleRate: 48_000, channelCount: 2)
        )
        _ = harness.run(callbacks: 20, playback: false)
        #expect(harness.runtime.ringBuffer.nextWriteSequence() == written)
        #expect(!harness.runtime.dspTransitionProgress().hasCompleted(target))
        var observedCompletion = false
        var recovery: [PlaybackRecoveryHarness.Observation] = []
        for _ in 0..<64 {
            recovery += harness.run(callbacks: 1)
            if !observedCompletion && harness.runtime.dspTransitionProgress().hasCompleted(target) {
                let output = try #require(recovery.last)
                #expect(!output.isSilent)
                let age = try #require(output.midpointAgeMS)
                #expect((0..<100).contains(age))
                observedCompletion = true
            }
        }
        #expect(observedCompletion)
        #expect(recovery.suffix(16).allSatisfy { !$0.isSilent })
        // Both destinations have unity gain. Decoding a recent timestamp also verifies that
        // the output has reached the new bank, rather than merely publishing completion.
        #expect(
            recovery.suffix(16).allSatisfy {
                $0.midpointAgeMS.map { (0..<100).contains($0) } ?? false
            })
        #expect(harness.runtime.snapshotMetrics().adaptivePlaybackRenderFailures == 0)
    }
}

// Calls the real DSP, ring, servo, resampler, and Core Audio PCM converter without creating
// a device or process tap. A default tick is 960 capture frames / 20 ms. Withholding a
// callback advances its timeline but does not sleep, block a realtime thread, or invoke HAL.
private final class PlaybackRecoveryHarness {
    struct Observation {
        var isSilent: Bool
        var midpointAgeMS: Double?
        var bufferedFrames: Int
    }

    let runtime: SeparateClockAudioBackend.AudioRuntime
    let primeFrames: Int
    let captureFrames: Int
    let outputRate: Double
    let outputFrames: Int
    private var sourceFrame = 0
    private var input: [Float]
    private var output: [Float]

    init(outputRate: Double, preampDB: Double = 0, captureFrames: Int = 960, primeFrames: Int = 3_072) throws {
        self.captureFrames = captureFrames
        self.primeFrames = primeFrames
        self.outputRate = outputRate
        self.outputFrames = Int(Double(captureFrames) * outputRate / 48_000)
        self.input = [Float](repeating: 0, count: captureFrames * 2)
        self.output = [Float](repeating: 0, count: outputFrames * 2)
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
                for frame in 0..<captureFrames {
                    let signal: Float = silentSource ? 0 : Float(0.1 + Double(sourceFrame + frame) / 1_000_000)
                    input[frame * 2] = signal
                    input[frame * 2 + 1] = -signal
                }
                Self.withBuffer(&input) { runtime.capture(inputData: UnsafePointer($0)) }
            }
            if playback {
                for index in output.indices { output[index] = .nan }
                Self.withBuffer(&output) {
                    runtime.playback(outputData: $0, outputSampleTime: Double(sourceFrame) * outputRate / 48_000)
                }
                #expect(output.allSatisfy { $0.isFinite })
                #expect(
                    stride(from: 0, to: output.count, by: 2).allSatisfy {
                        abs(output[$0] + output[$0 + 1]) < 0.000_001
                    })
                let isSilent = output.allSatisfy { abs($0) <= 0.000_1 }
                let midpoint = Double(output[(outputFrames / 2) * 2])
                let age =
                    midpoint > 0.05
                    ? (Double(sourceFrame + captureFrames) - (midpoint - 0.1) * 1_000_000) / 48
                    : nil
                observations.append(
                    Observation(
                        isSilent: isSilent,
                        midpointAgeMS: age,
                        bufferedFrames: runtime.ringBuffer.occupancyFrames()
                    ))
            }
            sourceFrame += captureFrames
        }
        return observations
    }

    func expectSettled(_ observations: [Observation], baselineAge: Double) throws {
        #expect(observations.count >= 16)
        for observation in observations.suffix(16) {
            #expect(!observation.isSilent)
            #expect(observation.bufferedFrames < primeFrames)
            let age = try #require(observation.midpointAgeMS)
            #expect(abs(age - baselineAge) < 2)
        }
    }

    private static func withBuffer(_ samples: inout [Float], _ body: (UnsafeMutablePointer<AudioBufferList>) -> Void) {
        samples.withUnsafeMutableBufferPointer {
            var buffer = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 2,
                    mDataByteSize: UInt32($0.count * MemoryLayout<Float>.stride), mData: $0.baseAddress
                ))
            body(&buffer)
        }
    }
}
