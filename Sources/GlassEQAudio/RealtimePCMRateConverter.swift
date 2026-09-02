import AudioToolbox
import Foundation

final class RealtimePCMRateConverter {
    let inputSampleRate: Double
    let outputSampleRate: Double
    let channelCount: Int
    let latencyFrames: Int

    private let converter: AudioConverterRef

    init(inputSampleRate: Double, outputSampleRate: Double, channelCount: Int) throws {
        self.inputSampleRate = inputSampleRate
        self.outputSampleRate = outputSampleRate
        self.channelCount = max(channelCount, 1)

        var inputFormat = Self.interleavedFloatFormat(
            sampleRate: inputSampleRate,
            channelCount: self.channelCount
        )
        var outputFormat = Self.interleavedFloatFormat(
            sampleRate: outputSampleRate,
            channelCount: self.channelCount
        )
        var converter: AudioConverterRef?
        try checkOSStatus(
            AudioConverterNew(&inputFormat, &outputFormat, &converter),
            operation: "AudioConverterNew(playback sample-rate conversion)"
        )
        guard let converter else {
            throw CoreAudioError(
                operation: "AudioConverterNew(playback sample-rate conversion)",
                status: kAudioConverterErr_UnspecifiedError
            )
        }

        let latencyFrames: Int
        do {
            var quality = UInt32(kAudioConverterQuality_Max)
            try withUnsafePointer(to: &quality) { value in
                try checkOSStatus(
                    AudioConverterSetProperty(
                        converter,
                        kAudioConverterSampleRateConverterQuality,
                        UInt32(MemoryLayout<UInt32>.size),
                        value
                    ),
                    operation: "AudioConverterSetProperty(sample-rate quality)"
                )
            }

            // Changing SRC quality resets Core Audio's prime method, so configure priming last.
            var primeMethod = UInt32(kConverterPrimeMethod_None)
            try withUnsafePointer(to: &primeMethod) { value in
                try checkOSStatus(
                    AudioConverterSetProperty(
                        converter,
                        kAudioConverterPrimeMethod,
                        UInt32(MemoryLayout<UInt32>.size),
                        value
                    ),
                    operation: "AudioConverterSetProperty(prime method)"
                )
            }

            var primeInfo = AudioConverterPrimeInfo()
            var primeInfoSize = UInt32(MemoryLayout<AudioConverterPrimeInfo>.size)
            try withUnsafeMutablePointer(to: &primeInfo) { value in
                try checkOSStatus(
                    AudioConverterGetProperty(
                        converter,
                        kAudioConverterPrimeInfo,
                        &primeInfoSize,
                        value
                    ),
                    operation: "AudioConverterGetProperty(prime info)"
                )
            }
            latencyFrames = Int(primeInfo.trailingFrames)
        } catch {
            AudioConverterDispose(converter)
            throw error
        }

        self.converter = converter
        self.latencyFrames = latencyFrames
    }

    deinit {
        AudioConverterDispose(converter)
    }

    func fill(
        inputProc: AudioConverterComplexInputDataProcRealtimeSafe,
        inputContext: UnsafeMutableRawPointer,
        outputFrames: inout UInt32,
        outputData: UnsafeMutablePointer<AudioBufferList>
    ) -> OSStatus {
        AudioConverterFillComplexBufferRealtimeSafe(
            converter,
            inputProc,
            inputContext,
            &outputFrames,
            outputData,
            nil
        )
    }

    func configuredPrimeMethod() throws -> UInt32 {
        var primeMethod: UInt32 = 0
        var propertySize = UInt32(MemoryLayout<UInt32>.size)
        try withUnsafeMutablePointer(to: &primeMethod) { value in
            try checkOSStatus(
                AudioConverterGetProperty(
                    converter,
                    kAudioConverterPrimeMethod,
                    &propertySize,
                    value
                ),
                operation: "AudioConverterGetProperty(prime method)"
            )
        }
        return primeMethod
    }

    func inputFrameCapacity(forOutputFrames outputFrames: Int) throws -> Int {
        let bytesPerFrame = channelCount * MemoryLayout<Float>.size
        let outputFrames = max(outputFrames, 1)
        guard outputFrames <= Int(UInt32.max) / bytesPerFrame else {
            throw CoreAudioError(
                operation: "AudioConverterGetProperty(required input buffer size)",
                status: kAudioConverterErr_InvalidOutputSize
            )
        }

        var bufferByteSize = UInt32(outputFrames * bytesPerFrame)
        var propertySize = UInt32(MemoryLayout<UInt32>.size)
        try withUnsafeMutablePointer(to: &bufferByteSize) { value in
            try checkOSStatus(
                AudioConverterGetProperty(
                    converter,
                    kAudioConverterPropertyCalculateInputBufferSize,
                    &propertySize,
                    value
                ),
                operation: "AudioConverterGetProperty(required input buffer size)"
            )
        }
        return max((Int(bufferByteSize) + bytesPerFrame - 1) / bytesPerFrame, 1)
    }

    static func interleavedFloatFormat(
        sampleRate: Double,
        channelCount: Int
    ) -> AudioStreamBasicDescription {
        let channelCount = UInt32(max(channelCount, 1))
        let bytesPerFrame = UInt32(MemoryLayout<Float>.size) * channelCount
        return AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: bytesPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: channelCount,
            mBitsPerChannel: 32,
            mReserved: 0
        )
    }
}
