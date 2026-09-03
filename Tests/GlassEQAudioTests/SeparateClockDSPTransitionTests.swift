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
