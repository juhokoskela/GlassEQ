import CoreAudio
import GlassEQCore
import Testing
@testable import GlassEQAudio

@Suite
struct SeparateClockDSPTransitionTests {
    @Test(arguments: [48_000.0, 24_000.0])
    func transitionCompletesOnlyAfterPlayback(outputSampleRate: Double) throws {
        let active = EQRenderConfiguration(
            profile: EQProfile(
                name: "Active",
                mode: .parametric,
                preampDB: -12,
                filters: []
            ),
            sampleRate: 48_000,
            channelCount: 2
        )
        var identityProfile = EQProfile.flatParametric
        identityProfile.isBypassed = true
        let identity = EQRenderConfiguration(
            profile: identityProfile,
            sampleRate: 48_000,
            channelCount: 2
        )
        let runtime = SeparateClockAudioBackend.AudioRuntime(
            renderConfiguration: active,
            ringCapacityFrames: 4_096,
            scratchFrames: 1_024,
            captureCallbackFrames: 1_024,
            playbackPrimeFrames: 3_072
        )
        try runtime.configurePlayback(
            primeFrames: 3_072,
            outputSampleRate: outputSampleRate
        )
        let target = runtime.publishPendingDSPConfig(identity)

        withInterleavedBuffer(frames: 1_024, repeating: 0.25) { input in
            runtime.capture(inputData: UnsafePointer(input))
            runtime.capture(inputData: UnsafePointer(input))
            runtime.capture(inputData: UnsafePointer(input))
        }

        #expect(!runtime.dspTransitionProgress().hasCompleted(target))

        for callback in 0..<4 {
            withInterleavedBuffer(frames: 512, repeating: 0) { output in
                runtime.playback(
                    outputData: output,
                    outputSampleTime: Double(callback * 512)
                )
            }
            if callback == 0 {
                #expect(!runtime.dspTransitionProgress().hasCompleted(target))
            }
            if runtime.dspTransitionProgress().hasCompleted(target) {
                break
            }
        }

        #expect(runtime.dspTransitionProgress().hasCompleted(target))
    }

    @Test(arguments: [0, 128, 512])
    func discardedFadeWaitsForDestinationBankPlayback(acceptedTailFrames: Int) throws {
        let active = EQRenderConfiguration(
            profile: EQProfile(name: "Active", mode: .parametric, preampDB: -12, filters: []),
            sampleRate: 48_000,
            channelCount: 2
        )
        var identityProfile = EQProfile.flatParametric
        identityProfile.isBypassed = true
        let identity = EQRenderConfiguration(profile: identityProfile, sampleRate: 48_000, channelCount: 2)
        let capacity = 1_024 + acceptedTailFrames
        let runtime = SeparateClockAudioBackend.AudioRuntime(
            renderConfiguration: active,
            ringCapacityFrames: capacity,
            scratchFrames: 1_024,
            captureCallbackFrames: 1_024,
            playbackPrimeFrames: capacity
        )
        try runtime.configurePlayback(primeFrames: capacity, outputSampleRate: 48_000)
        let target = runtime.publishPendingDSPConfig(identity)

        // The first block warms the bank. The second starts its 480-frame blend and
        // completes it at offset 479, but may drop that frame.
        withInterleavedBuffer(frames: 1_024, repeating: 0.25) { input in
            runtime.capture(inputData: UnsafePointer(input))
            runtime.capture(inputData: UnsafePointer(input))
            // Further rejected input must not arm completion either.
            runtime.capture(inputData: UnsafePointer(input))
        }
        #expect(runtime.ringBuffer.nextWriteSequence() == UInt64(capacity))
        #expect(!runtime.dspTransitionProgress().hasCompleted(target))

        for callback in 0..<9 {
            withInterleavedBuffer(frames: 128, repeating: 0) { output in
                runtime.playback(outputData: output, outputSampleTime: Double(callback * 128))
                if runtime.dspTransitionProgress().hasCompleted(target) {
                    let samples = UnsafeMutableAudioBufferListPointer(output)[0].mData!
                        .assumingMemoryBound(to: Float.self)
                    #expect(abs(samples[64 * 2] - 0.25) < 0.000_001)
                }
            }
            #expect(!runtime.dspTransitionProgress().hasCompleted(target))
        }

        // Overflow discards queued fade samples without completing it. Refill without
        // another overflow; the first played frame of the new bank may now complete it.
        #expect(runtime.ringBuffer.occupancyFrames() == 0)
        withInterleavedBuffer(frames: capacity, repeating: 0.25) { input in
            runtime.capture(inputData: UnsafePointer(input))
        }
        #expect(!runtime.dspTransitionProgress().hasCompleted(target))
        for callback in 9..<18 {
            withInterleavedBuffer(frames: 128, repeating: 0) { output in
                runtime.playback(outputData: output, outputSampleTime: Double(callback * 128))
                if runtime.dspTransitionProgress().hasCompleted(target) {
                    let samples = UnsafeMutableAudioBufferListPointer(output)[0].mData!
                        .assumingMemoryBound(to: Float.self)
                    #expect(abs(samples[64 * 2] - 0.25) < 0.000_001)
                }
            }
            if runtime.dspTransitionProgress().hasCompleted(target) {
                break
            }
        }
        #expect(runtime.dspTransitionProgress().hasCompleted(target))
    }

    private func withInterleavedBuffer(
        frames: Int,
        repeating sample: Float,
        _ body: (UnsafeMutablePointer<AudioBufferList>) -> Void
    ) {
        var samples = Array(repeating: sample, count: frames * 2)
        let buffers = AudioBufferList.allocate(maximumBuffers: 1)
        defer { free(buffers.unsafeMutablePointer) }
        samples.withUnsafeMutableBufferPointer { samples in
            buffers[0] = AudioBuffer(
                mNumberChannels: 2,
                mDataByteSize: UInt32(samples.count * MemoryLayout<Float>.stride),
                mData: samples.baseAddress
            )
            body(buffers.unsafeMutablePointer)
        }
    }
}
