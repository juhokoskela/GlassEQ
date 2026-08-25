import AVFoundation
import Foundation
import GlassEQCore

enum ImpulseResponseWAVImportError: Error, Equatable, LocalizedError {
    case empty
    case unsupportedChannelCount(Int)
    case tooManyFrames(count: Int, maximum: Int)
    case invalidSampleRate(Double)
    case sampleRateMismatch(file: Double, output: Double)
    case separateFilesMustBeMono(leftChannels: Int, rightChannels: Int)
    case channelSampleRateMismatch(left: Double, right: Double)
    case unreadableSamples
    case nonFiniteSample(channel: Int, frame: Int)

    var errorDescription: String? {
        switch self {
        case .empty:
            "The WAV file does not contain an impulse response."
        case .unsupportedChannelCount(let count):
            "The WAV file has \(count) channels. GlassEQ currently supports mono and stereo impulse responses."
        case let .tooManyFrames(count, maximum):
            "The impulse response has \(count) taps. GlassEQ currently supports up to \(maximum) taps per channel."
        case .invalidSampleRate(let sampleRate):
            "The WAV file has an invalid sample rate (\(sampleRate) Hz)."
        case let .sampleRateMismatch(file, output):
            "This impulse response is \(Self.rateLabel(file)); the current output is \(Self.rateLabel(output)). Export a matching WAV from REW."
        case let .separateFilesMustBeMono(leftChannels, rightChannels):
            "Separate left and right imports require two mono WAV files. The selected files have \(leftChannels) and \(rightChannels) channels."
        case let .channelSampleRateMismatch(left, right):
            "The left and right files use different sample rates: \(Self.rateLabel(left)) and \(Self.rateLabel(right))."
        case .unreadableSamples:
            "GlassEQ could not read PCM samples from the WAV file."
        case let .nonFiniteSample(channel, frame):
            "The WAV file contains an invalid sample in channel \(channel + 1) at frame \(frame)."
        }
    }

    private static func rateLabel(_ sampleRate: Double) -> String {
        if sampleRate >= 1_000 {
            return String(format: "%.1f kHz", sampleRate / 1_000)
        }
        return String(format: "%.0f Hz", sampleRate)
    }
}

struct ImportedImpulseResponse: Equatable, Sendable {
    struct Channel: Equatable, Sendable {
        var filename: String
        var frameCount: Int
        var sampleRate: Double
    }

    var profile: EQProfile
    var channels: [Channel]
    var sourceFileCount: Int

    var channelCount: Int {
        channels.count
    }

    var sampleRate: Double {
        channels.first?.sampleRate ?? 0
    }

    mutating func swapStereoChannels() {
        guard profile.channelMode == .stereo,
              channels.count == 2 else {
            return
        }
        let left = profile.leftConvolution
        profile.leftConvolution = profile.rightConvolution
        profile.rightConvolution = left
        channels.swapAt(0, 1)
    }
}

enum ImpulseResponseWAVImporter {
    static func load(
        from url: URL,
        expectedSampleRate: Double? = nil
    ) throws -> ImportedImpulseResponse {
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer {
            if hasAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let file = try AVAudioFile(
            forReading: url,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let format = file.processingFormat
        let channelCount = Int(format.channelCount)
        guard (1...2).contains(channelCount) else {
            throw ImpulseResponseWAVImportError.unsupportedChannelCount(channelCount)
        }

        let sampleRate = format.sampleRate
        guard sampleRate.isFinite,
              ProfilePersistence.impulseSampleRateRange.contains(sampleRate) else {
            throw ImpulseResponseWAVImportError.invalidSampleRate(sampleRate)
        }
        if let expectedSampleRate,
           expectedSampleRate.isFinite,
           expectedSampleRate > 0,
           abs(sampleRate - expectedSampleRate) >= 0.5 {
            throw ImpulseResponseWAVImportError.sampleRateMismatch(
                file: sampleRate,
                output: expectedSampleRate
            )
        }

        guard file.length > 0 else {
            throw ImpulseResponseWAVImportError.empty
        }
        guard file.length <= AVAudioFramePosition(ImpulseResponseSource.maximumFrameCount) else {
            throw ImpulseResponseWAVImportError.tooManyFrames(
                count: Int(file.length),
                maximum: ImpulseResponseSource.maximumFrameCount
            )
        }

        let capacity = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: capacity
        ) else {
            throw ImpulseResponseWAVImportError.unreadableSamples
        }
        try file.read(into: buffer, frameCount: capacity)
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else {
            throw ImpulseResponseWAVImportError.empty
        }
        guard let channels = buffer.floatChannelData else {
            throw ImpulseResponseWAVImportError.unreadableSamples
        }

        var sources: [ImpulseResponseSource] = []
        sources.reserveCapacity(channelCount)
        for channel in 0..<channelCount {
            let samples = Array(UnsafeBufferPointer(
                start: channels[channel],
                count: frameCount
            ))
            if let frame = samples.firstIndex(where: { !$0.isFinite }) {
                throw ImpulseResponseWAVImportError.nonFiniteSample(
                    channel: channel,
                    frame: frame
                )
            }
            sources.append(ImpulseResponseSource(
                sampleRate: sampleRate,
                samples: samples
            ))
        }

        let name = url.deletingPathExtension().lastPathComponent
        let profile: EQProfile
        if channelCount == 1 {
            profile = EQProfile(
                name: name,
                mode: .convolution,
                filters: [],
                convolution: .impulseResponse(sources[0])
            )
        } else {
            profile = EQProfile(
                name: name,
                mode: .convolution,
                channelMode: .stereo,
                filters: [],
                convolution: nil,
                leftConvolution: .impulseResponse(sources[0]),
                rightConvolution: .impulseResponse(sources[1])
            )
        }

        return ImportedImpulseResponse(
            profile: profile,
            channels: (0..<channelCount).map { _ in
                ImportedImpulseResponse.Channel(
                    filename: url.lastPathComponent,
                    frameCount: frameCount,
                    sampleRate: sampleRate
                )
            },
            sourceFileCount: 1
        )
    }

    static func loadStereoPair(
        leftURL: URL,
        rightURL: URL,
        expectedSampleRate: Double? = nil
    ) throws -> ImportedImpulseResponse {
        let left = try load(
            from: leftURL,
            expectedSampleRate: expectedSampleRate
        )
        let right = try load(
            from: rightURL,
            expectedSampleRate: expectedSampleRate
        )
        guard left.channelCount == 1,
              right.channelCount == 1 else {
            throw ImpulseResponseWAVImportError.separateFilesMustBeMono(
                leftChannels: left.channelCount,
                rightChannels: right.channelCount
            )
        }
        guard abs(left.sampleRate - right.sampleRate) < 0.5 else {
            throw ImpulseResponseWAVImportError.channelSampleRateMismatch(
                left: left.sampleRate,
                right: right.sampleRate
            )
        }
        guard case .impulseResponse(let leftSource) = left.profile.convolution,
              case .impulseResponse(let rightSource) = right.profile.convolution else {
            throw ImpulseResponseWAVImportError.unreadableSamples
        }

        let profile = EQProfile(
            name: inferredStereoProfileName(
                leftURL: leftURL,
                rightURL: rightURL,
                fallback: "Imported Stereo IR"
            ),
            mode: .convolution,
            channelMode: .stereo,
            filters: [],
            convolution: nil,
            leftConvolution: .impulseResponse(leftSource),
            rightConvolution: .impulseResponse(rightSource)
        )
        return ImportedImpulseResponse(
            profile: profile,
            channels: [left.channels[0], right.channels[0]],
            sourceFileCount: 2
        )
    }

}

func inferredStereoProfileName(
    leftURL: URL,
    rightURL: URL,
    fallback: String
) -> String {
    let left = removingChannelSuffix(leftURL.deletingPathExtension().lastPathComponent)
    let right = removingChannelSuffix(rightURL.deletingPathExtension().lastPathComponent)
    if !left.isEmpty,
       left.caseInsensitiveCompare(right) == .orderedSame {
        return left
    }
    return fallback
}

private func removingChannelSuffix(_ name: String) -> String {
    let suffixes = [
        " left", "-left", "_left", " l", "-l", "_l",
        " right", "-right", "_right", " r", "-r", "_r"
    ]
    let lowercased = name.lowercased()
    for suffix in suffixes where lowercased.hasSuffix(suffix) {
        return String(name.dropLast(suffix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return name
}
