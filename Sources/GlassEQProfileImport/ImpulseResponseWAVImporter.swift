import AVFoundation
import Foundation
import GlassEQCore

package enum ImpulseResponseWAVImportError: Error, Equatable, LocalizedError {
    case empty
    case unsupportedChannelCount(Int)
    case tooManyFrames(count: Int, maximum: Int)
    case invalidSampleRate(Double)
    case separateFilesMustBeMono(leftChannels: Int, rightChannels: Int)
    case channelSampleRateMismatch(left: Double, right: Double)
    case unreadableSamples
    case nonFiniteSample(channel: Int, frame: Int)

    package var errorDescription: String? {
        switch self {
        case .empty:
            "The WAV file does not contain an impulse response."
        case .unsupportedChannelCount(let count):
            "The WAV file has \(count) channels. GlassEQ currently supports mono and stereo impulse responses."
        case let .tooManyFrames(count, maximum):
            "The impulse response has \(count) taps. GlassEQ currently supports up to \(maximum) taps per channel."
        case .invalidSampleRate(let sampleRate):
            "The WAV file has an invalid sample rate (\(sampleRate) Hz)."
        case let .separateFilesMustBeMono(leftChannels, rightChannels):
            "Separate left and right imports require two mono WAV files. The selected files have \(leftChannels) and \(rightChannels) channels."
        case let .channelSampleRateMismatch(left, right):
            "The left and right files use different sample rates: \(ImportedImpulseResponse.sampleRateLabel(left)) and \(ImportedImpulseResponse.sampleRateLabel(right))."
        case .unreadableSamples:
            "GlassEQ could not read PCM samples from the WAV file."
        case let .nonFiniteSample(channel, frame):
            "The WAV file contains an invalid sample in channel \(channel + 1) at frame \(frame)."
        }
    }
}

package struct ImportedImpulseResponse: Equatable, Sendable {
    package struct Channel: Equatable, Sendable {
        package var filename: String
        package var frameCount: Int
        package var sampleRate: Double

        package init(filename: String, frameCount: Int, sampleRate: Double) {
            self.filename = filename
            self.frameCount = frameCount
            self.sampleRate = sampleRate
        }
    }

    package enum Channels: Equatable, Sendable {
        case mono(Channel)
        case stereo(left: Channel, right: Channel)

        package var count: Int {
            switch self {
            case .mono:
                1
            case .stereo:
                2
            }
        }

        package var first: Channel {
            switch self {
            case .mono(let channel), .stereo(let channel, _):
                channel
            }
        }
    }

    package var profile: EQProfile
    package var channels: Channels
    package var sourceFileCount: Int

    package init(profile: EQProfile, channels: Channels, sourceFileCount: Int) {
        self.profile = profile
        self.channels = channels
        self.sourceFileCount = sourceFileCount
    }

    package var sampleRate: Double {
        channels.first.sampleRate
    }

    package mutating func swapStereoChannels() {
        guard case let .stereo(left, right) = channels else {
            return
        }
        profile.swapStereoChannels()
        channels = .stereo(left: right, right: left)
    }

    package static func sampleRateLabel(_ sampleRate: Double) -> String {
        if sampleRate >= 1_000 {
            return Measurement(value: sampleRate / 1_000, unit: UnitFrequency.kilohertz)
                .formatted(.measurement(
                    width: .abbreviated,
                    usage: .asProvided,
                    numberFormatStyle: .number.precision(.fractionLength(1))
                ))
        }
        return Measurement(value: sampleRate, unit: UnitFrequency.hertz)
            .formatted(.measurement(
                width: .abbreviated,
                usage: .asProvided,
                numberFormatStyle: .number.precision(.fractionLength(0))
            ))
    }
}

package enum ImpulseResponseWAVImporter {
    package static func load(from url: URL) throws -> ImportedImpulseResponse {
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
        guard let channelData = buffer.floatChannelData else {
            throw ImpulseResponseWAVImportError.unreadableSamples
        }

        var sources: [ImpulseResponseSource] = []
        sources.reserveCapacity(channelCount)
        for channel in 0..<channelCount {
            let samples = Array(UnsafeBufferPointer(
                start: channelData[channel],
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
        let channel = ImportedImpulseResponse.Channel(
            filename: url.lastPathComponent,
            frameCount: frameCount,
            sampleRate: sampleRate
        )
        if sources.count == 2 {
            return ImportedImpulseResponse(
                profile: EQProfile(
                    name: name,
                    mode: .convolution,
                    channelMode: .stereo,
                    filters: [],
                    convolution: nil,
                    leftConvolution: .impulseResponse(sources[0]),
                    rightConvolution: .impulseResponse(sources[1])
                ),
                channels: .stereo(left: channel, right: channel),
                sourceFileCount: 1
            )
        }
        return ImportedImpulseResponse(
            profile: EQProfile(
                name: name,
                mode: .convolution,
                filters: [],
                convolution: .impulseResponse(sources[0])
            ),
            channels: .mono(channel),
            sourceFileCount: 1
        )
    }

    package static func loadStereoPair(
        leftURL: URL,
        rightURL: URL
    ) throws -> ImportedImpulseResponse {
        let left = try load(from: leftURL)
        let right = try load(from: rightURL)
        guard case .mono(let leftChannel) = left.channels,
              case .mono(let rightChannel) = right.channels else {
            throw ImpulseResponseWAVImportError.separateFilesMustBeMono(
                leftChannels: left.channels.count,
                rightChannels: right.channels.count
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
            name: EQProfile.inferredStereoImportName(
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
            channels: .stereo(left: leftChannel, right: rightChannel),
            sourceFileCount: 2
        )
    }
}
