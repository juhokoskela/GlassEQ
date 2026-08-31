import CoreAudio
import Foundation
import GlassEQCore
import Synchronization

public enum AudioEngineState: Equatable, Sendable {
    case stopped
    case running(output: AudioOutputDevice)
    case failed(String)
}

public enum HeadsetAggregatePromotionResult: Equatable, Sendable {
    case notApplicable
    case clockUnstable
    case aggregateUnstable
    case promoted(AudioOutputDevice)
}

public enum ColdStartupAggregatePromotionResult: Equatable, Sendable {
    case notApplicable
    case clientsActive
    case aggregateUnstable
    case promoted(AudioOutputDevice)
}

@_spi(GlassEQDiagnostics)
public typealias AudioEngineDiagnosticTrace = @Sendable (
    _ hostTimeNanoseconds: UInt64?,
    _ message: String
) -> Void

public struct AudioRenderTimingMetrics: Equatable, Sendable {
    public var callbackStartLatenessObservations: UInt64
    public var callbackStartLatenessP9999Nanoseconds: UInt64
    public var maximumCallbackStartLatenessNanoseconds: UInt64
    public var directHeadObservations: UInt64
    public var directHeadP9999Nanoseconds: UInt64
    public var maximumDirectHeadNanoseconds: UInt64
    public var tailWorkObservations: UInt64
    public var tailWorkP9999Nanoseconds: UInt64
    public var maximumTailWorkNanoseconds: UInt64
    public var totalRenderObservations: UInt64
    public var totalRenderP9999Nanoseconds: UInt64
    public var maximumTotalRenderNanoseconds: UInt64
    public var completionLatenessObservations: UInt64
    public var completionLatenessP9999Nanoseconds: UInt64
    public var maximumCompletionLatenessNanoseconds: UInt64
    public var tailCompletionObservations: UInt64
    public var minimumTailCompletionSlackFrames: Int
    public var tailDeadlineMisses: UInt64

    public init(
        callbackStartLatenessObservations: UInt64 = 0,
        callbackStartLatenessP9999Nanoseconds: UInt64 = 0,
        maximumCallbackStartLatenessNanoseconds: UInt64 = 0,
        directHeadObservations: UInt64 = 0,
        directHeadP9999Nanoseconds: UInt64 = 0,
        maximumDirectHeadNanoseconds: UInt64 = 0,
        tailWorkObservations: UInt64 = 0,
        tailWorkP9999Nanoseconds: UInt64 = 0,
        maximumTailWorkNanoseconds: UInt64 = 0,
        totalRenderObservations: UInt64 = 0,
        totalRenderP9999Nanoseconds: UInt64 = 0,
        maximumTotalRenderNanoseconds: UInt64 = 0,
        completionLatenessObservations: UInt64 = 0,
        completionLatenessP9999Nanoseconds: UInt64 = 0,
        maximumCompletionLatenessNanoseconds: UInt64 = 0,
        tailCompletionObservations: UInt64 = 0,
        minimumTailCompletionSlackFrames: Int = 0,
        tailDeadlineMisses: UInt64 = 0
    ) {
        self.callbackStartLatenessObservations = callbackStartLatenessObservations
        self.callbackStartLatenessP9999Nanoseconds = callbackStartLatenessP9999Nanoseconds
        self.maximumCallbackStartLatenessNanoseconds = maximumCallbackStartLatenessNanoseconds
        self.directHeadObservations = directHeadObservations
        self.directHeadP9999Nanoseconds = directHeadP9999Nanoseconds
        self.maximumDirectHeadNanoseconds = maximumDirectHeadNanoseconds
        self.tailWorkObservations = tailWorkObservations
        self.tailWorkP9999Nanoseconds = tailWorkP9999Nanoseconds
        self.maximumTailWorkNanoseconds = maximumTailWorkNanoseconds
        self.totalRenderObservations = totalRenderObservations
        self.totalRenderP9999Nanoseconds = totalRenderP9999Nanoseconds
        self.maximumTotalRenderNanoseconds = maximumTotalRenderNanoseconds
        self.completionLatenessObservations = completionLatenessObservations
        self.completionLatenessP9999Nanoseconds = completionLatenessP9999Nanoseconds
        self.maximumCompletionLatenessNanoseconds = maximumCompletionLatenessNanoseconds
        self.tailCompletionObservations = tailCompletionObservations
        self.minimumTailCompletionSlackFrames = minimumTailCompletionSlackFrames
        self.tailDeadlineMisses = tailDeadlineMisses
    }
}

public struct AggregateAudioRouteFingerprint: Codable, Equatable, Hashable, Sendable {
    public var outputDeviceUID: String
    public var nativeOutputStreamIndex: Int
    public var nominalSampleRate: Int64

    public init(
        outputDeviceUID: String,
        nativeOutputStreamIndex: Int,
        nominalSampleRate: Double
    ) {
        self.outputDeviceUID = outputDeviceUID
        self.nativeOutputStreamIndex = nativeOutputStreamIndex
        self.nominalSampleRate = Int64(nominalSampleRate.rounded())
    }

    public var isValid: Bool {
        !outputDeviceUID.isEmpty
            && nativeOutputStreamIndex >= 0
            && nominalSampleRate > 0
    }
}

public struct AudioEngineMetrics: Equatable, Sendable {
    public var capturedFrames: UInt64
    public var playedFrames: UInt64
    public var playbackUnderrunFrames: UInt64
    public var droppedInputFrames: UInt64
    public var droppedBufferedFrames: UInt64
    public var ringGateContentionFailures: UInt64
    public var saturatedSamples: UInt64
    public var currentBufferedFrames: Int
    public var maxBufferedFrames: Int
    public var maximumPlaybackBufferedFrames: Int
    public var minimumPlaybackBufferedFrames: Int
    public var averagePlaybackBufferedFrames: Double
    public var playbackBufferObservations: UInt64
    public var inputTimestampDiscontinuities: UInt64
    public var outputTimestampDiscontinuities: UInt64
    public var pairedTimestampDiscontinuities: UInt64
    public var qualifyingPairedTimestampDiscontinuities: UInt64
    public var lastInputTimestampJumpFrames: Double
    public var lastOutputTimestampJumpFrames: Double
    public var lastInputHostIntervalErrorNanoseconds: Int64
    public var lastOutputHostIntervalErrorNanoseconds: Int64
    public var timestampJumpIntervalObservations: UInt64
    public var minimumTimestampJumpIntervalNanoseconds: UInt64
    public var maximumTimestampJumpIntervalNanoseconds: UInt64
    public var averageTimestampJumpIntervalNanoseconds: Double
    public var maximumCaptureCallbackFrames: Int
    public var maximumPlaybackCallbackFrames: Int
    public var renderDeadlineMisses: UInt64
    public var callbackStartStarvations: UInt64
    public var renderOverruns: UInt64
    public var playbackTimestampDiscontinuities: UInt64
    public var playbackBufferRenegotiations: UInt64
    public var adaptivePlaybackRenderFailures: UInt64
    public var playbackRateCorrectionPPM: Double
    public var playbackRateCorrectionSaturated: Bool
    public var playbackOccupancyTargetFrames: Int
    public var filteredPlaybackOccupancyFrames: Double
    public var playbackBufferSampleRate: Double
    public var playbackSampleRateConversionActive: Bool
    public var tapToOutputLatencyObservations: UInt64
    public var minimumTapToOutputLatencyNanoseconds: UInt64
    public var maximumTapToOutputLatencyNanoseconds: UInt64
    public var averageTapToOutputLatencyNanoseconds: Double
    public var callbackTimingObservations: UInt64
    public var minimumInputAgeNanoseconds: UInt64
    public var maximumInputAgeNanoseconds: UInt64
    public var averageInputAgeNanoseconds: Double
    public var minimumOutputLeadNanoseconds: UInt64
    public var maximumOutputLeadNanoseconds: UInt64
    public var averageOutputLeadNanoseconds: Double
    public var renderTiming: AudioRenderTimingMetrics

    public init(
        capturedFrames: UInt64 = 0,
        playedFrames: UInt64 = 0,
        playbackUnderrunFrames: UInt64 = 0,
        droppedInputFrames: UInt64 = 0,
        droppedBufferedFrames: UInt64 = 0,
        ringGateContentionFailures: UInt64 = 0,
        saturatedSamples: UInt64 = 0,
        currentBufferedFrames: Int = 0,
        maxBufferedFrames: Int = 0,
        maximumPlaybackBufferedFrames: Int = 0,
        minimumPlaybackBufferedFrames: Int = 0,
        averagePlaybackBufferedFrames: Double = 0,
        playbackBufferObservations: UInt64 = 0,
        inputTimestampDiscontinuities: UInt64 = 0,
        outputTimestampDiscontinuities: UInt64 = 0,
        pairedTimestampDiscontinuities: UInt64 = 0,
        qualifyingPairedTimestampDiscontinuities: UInt64 = 0,
        lastInputTimestampJumpFrames: Double = 0,
        lastOutputTimestampJumpFrames: Double = 0,
        lastInputHostIntervalErrorNanoseconds: Int64 = 0,
        lastOutputHostIntervalErrorNanoseconds: Int64 = 0,
        timestampJumpIntervalObservations: UInt64 = 0,
        minimumTimestampJumpIntervalNanoseconds: UInt64 = 0,
        maximumTimestampJumpIntervalNanoseconds: UInt64 = 0,
        averageTimestampJumpIntervalNanoseconds: Double = 0,
        maximumCaptureCallbackFrames: Int = 0,
        maximumPlaybackCallbackFrames: Int = 0,
        renderDeadlineMisses: UInt64 = 0,
        callbackStartStarvations: UInt64 = 0,
        renderOverruns: UInt64 = 0,
        playbackTimestampDiscontinuities: UInt64 = 0,
        playbackBufferRenegotiations: UInt64 = 0,
        adaptivePlaybackRenderFailures: UInt64 = 0,
        playbackRateCorrectionPPM: Double = 0,
        playbackRateCorrectionSaturated: Bool = false,
        playbackOccupancyTargetFrames: Int = 0,
        filteredPlaybackOccupancyFrames: Double = 0,
        playbackBufferSampleRate: Double = 0,
        playbackSampleRateConversionActive: Bool = false,
        tapToOutputLatencyObservations: UInt64 = 0,
        minimumTapToOutputLatencyNanoseconds: UInt64 = 0,
        maximumTapToOutputLatencyNanoseconds: UInt64 = 0,
        averageTapToOutputLatencyNanoseconds: Double = 0,
        callbackTimingObservations: UInt64 = 0,
        minimumInputAgeNanoseconds: UInt64 = 0,
        maximumInputAgeNanoseconds: UInt64 = 0,
        averageInputAgeNanoseconds: Double = 0,
        minimumOutputLeadNanoseconds: UInt64 = 0,
        maximumOutputLeadNanoseconds: UInt64 = 0,
        averageOutputLeadNanoseconds: Double = 0,
        renderTiming: AudioRenderTimingMetrics = AudioRenderTimingMetrics()
    ) {
        self.capturedFrames = capturedFrames
        self.playedFrames = playedFrames
        self.playbackUnderrunFrames = playbackUnderrunFrames
        self.droppedInputFrames = droppedInputFrames
        self.droppedBufferedFrames = droppedBufferedFrames
        self.ringGateContentionFailures = ringGateContentionFailures
        self.saturatedSamples = saturatedSamples
        self.currentBufferedFrames = currentBufferedFrames
        self.maxBufferedFrames = maxBufferedFrames
        self.maximumPlaybackBufferedFrames = maximumPlaybackBufferedFrames
        self.minimumPlaybackBufferedFrames = minimumPlaybackBufferedFrames
        self.averagePlaybackBufferedFrames = averagePlaybackBufferedFrames
        self.playbackBufferObservations = playbackBufferObservations
        self.inputTimestampDiscontinuities = inputTimestampDiscontinuities
        self.outputTimestampDiscontinuities = outputTimestampDiscontinuities
        self.pairedTimestampDiscontinuities = pairedTimestampDiscontinuities
        self.qualifyingPairedTimestampDiscontinuities = qualifyingPairedTimestampDiscontinuities
        self.lastInputTimestampJumpFrames = lastInputTimestampJumpFrames
        self.lastOutputTimestampJumpFrames = lastOutputTimestampJumpFrames
        self.lastInputHostIntervalErrorNanoseconds = lastInputHostIntervalErrorNanoseconds
        self.lastOutputHostIntervalErrorNanoseconds = lastOutputHostIntervalErrorNanoseconds
        self.timestampJumpIntervalObservations = timestampJumpIntervalObservations
        self.minimumTimestampJumpIntervalNanoseconds = minimumTimestampJumpIntervalNanoseconds
        self.maximumTimestampJumpIntervalNanoseconds = maximumTimestampJumpIntervalNanoseconds
        self.averageTimestampJumpIntervalNanoseconds = averageTimestampJumpIntervalNanoseconds
        self.maximumCaptureCallbackFrames = maximumCaptureCallbackFrames
        self.maximumPlaybackCallbackFrames = maximumPlaybackCallbackFrames
        self.renderDeadlineMisses = renderDeadlineMisses
        self.callbackStartStarvations = callbackStartStarvations
        self.renderOverruns = renderOverruns
        self.playbackTimestampDiscontinuities = playbackTimestampDiscontinuities
        self.playbackBufferRenegotiations = playbackBufferRenegotiations
        self.adaptivePlaybackRenderFailures = adaptivePlaybackRenderFailures
        self.playbackRateCorrectionPPM = playbackRateCorrectionPPM
        self.playbackRateCorrectionSaturated = playbackRateCorrectionSaturated
        self.playbackOccupancyTargetFrames = playbackOccupancyTargetFrames
        self.filteredPlaybackOccupancyFrames = filteredPlaybackOccupancyFrames
        self.playbackBufferSampleRate = playbackBufferSampleRate
        self.playbackSampleRateConversionActive = playbackSampleRateConversionActive
        self.tapToOutputLatencyObservations = tapToOutputLatencyObservations
        self.minimumTapToOutputLatencyNanoseconds = minimumTapToOutputLatencyNanoseconds
        self.maximumTapToOutputLatencyNanoseconds = maximumTapToOutputLatencyNanoseconds
        self.averageTapToOutputLatencyNanoseconds = averageTapToOutputLatencyNanoseconds
        self.callbackTimingObservations = callbackTimingObservations
        self.minimumInputAgeNanoseconds = minimumInputAgeNanoseconds
        self.maximumInputAgeNanoseconds = maximumInputAgeNanoseconds
        self.averageInputAgeNanoseconds = averageInputAgeNanoseconds
        self.minimumOutputLeadNanoseconds = minimumOutputLeadNanoseconds
        self.maximumOutputLeadNanoseconds = maximumOutputLeadNanoseconds
        self.averageOutputLeadNanoseconds = averageOutputLeadNanoseconds
        self.renderTiming = renderTiming
    }
}

public struct AudioTimestampProbeRecord: Equatable, Sendable {
    public var sequence: UInt64
    public var inputJumpDetected: Bool
    public var outputJumpDetected: Bool
    public var inputFrameCount: Int
    public var outputFrameCount: Int
    public var inputSampleTime: Float64
    public var inputHostTime: UInt64
    public var inputRateScalar: Float64
    public var inputFlags: UInt32
    public var outputSampleTime: Float64
    public var outputHostTime: UInt64
    public var outputRateScalar: Float64
    public var outputFlags: UInt32
    public var inputSampleTimeDeltaFrames: Double
    public var outputSampleTimeDeltaFrames: Double
    public var inputHostIntervalErrorNanoseconds: Int64
    public var outputHostIntervalErrorNanoseconds: Int64

    public init(
        sequence: UInt64 = 0,
        inputJumpDetected: Bool = false,
        outputJumpDetected: Bool = false,
        inputFrameCount: Int = 0,
        outputFrameCount: Int = 0,
        inputSampleTime: Float64 = 0,
        inputHostTime: UInt64 = 0,
        inputRateScalar: Float64 = 0,
        inputFlags: UInt32 = 0,
        outputSampleTime: Float64 = 0,
        outputHostTime: UInt64 = 0,
        outputRateScalar: Float64 = 0,
        outputFlags: UInt32 = 0,
        inputSampleTimeDeltaFrames: Double = 0,
        outputSampleTimeDeltaFrames: Double = 0,
        inputHostIntervalErrorNanoseconds: Int64 = 0,
        outputHostIntervalErrorNanoseconds: Int64 = 0
    ) {
        self.sequence = sequence
        self.inputJumpDetected = inputJumpDetected
        self.outputJumpDetected = outputJumpDetected
        self.inputFrameCount = inputFrameCount
        self.outputFrameCount = outputFrameCount
        self.inputSampleTime = inputSampleTime
        self.inputHostTime = inputHostTime
        self.inputRateScalar = inputRateScalar
        self.inputFlags = inputFlags
        self.outputSampleTime = outputSampleTime
        self.outputHostTime = outputHostTime
        self.outputRateScalar = outputRateScalar
        self.outputFlags = outputFlags
        self.inputSampleTimeDeltaFrames = inputSampleTimeDeltaFrames
        self.outputSampleTimeDeltaFrames = outputSampleTimeDeltaFrames
        self.inputHostIntervalErrorNanoseconds = inputHostIntervalErrorNanoseconds
        self.outputHostIntervalErrorNanoseconds = outputHostIntervalErrorNanoseconds
    }
}

public struct AudioDeviceLatencyMetadata: Equatable, Sendable {
    public var objectID: AudioObjectID
    public var bufferFrameSize: UInt32?
    public var inputStreamChannelCounts: [Int]?
    public var outputStreamChannelCounts: [Int]?
    public var inputLatencyFrames: UInt32?
    public var inputSafetyOffsetFrames: UInt32?
    public var inputSafetyOffsetSettable: Bool?
    public var outputLatencyFrames: UInt32?
    public var outputSafetyOffsetFrames: UInt32?
    public var outputSafetyOffsetSettable: Bool?

    public init(
        objectID: AudioObjectID,
        bufferFrameSize: UInt32?,
        inputStreamChannelCounts: [Int]?,
        outputStreamChannelCounts: [Int]?,
        inputLatencyFrames: UInt32?,
        inputSafetyOffsetFrames: UInt32?,
        inputSafetyOffsetSettable: Bool?,
        outputLatencyFrames: UInt32?,
        outputSafetyOffsetFrames: UInt32?,
        outputSafetyOffsetSettable: Bool?
    ) {
        self.objectID = objectID
        self.bufferFrameSize = bufferFrameSize
        self.inputStreamChannelCounts = inputStreamChannelCounts
        self.outputStreamChannelCounts = outputStreamChannelCounts
        self.inputLatencyFrames = inputLatencyFrames
        self.inputSafetyOffsetFrames = inputSafetyOffsetFrames
        self.inputSafetyOffsetSettable = inputSafetyOffsetSettable
        self.outputLatencyFrames = outputLatencyFrames
        self.outputSafetyOffsetFrames = outputSafetyOffsetFrames
        self.outputSafetyOffsetSettable = outputSafetyOffsetSettable
    }
}

public struct AudioEngineLatencyMetadata: Equatable, Sendable {
    public var physicalDevice: AudioDeviceLatencyMetadata
    public var aggregateDevice: AudioDeviceLatencyMetadata

    public init(
        physicalDevice: AudioDeviceLatencyMetadata,
        aggregateDevice: AudioDeviceLatencyMetadata
    ) {
        self.physicalDevice = physicalDevice
        self.aggregateDevice = aggregateDevice
    }
}

private struct AudioEngineInternalError: Error, LocalizedError {
    var message: String

    var errorDescription: String? {
        message
    }
}

struct AudioEngineProfileUpdateUnavailable: Error, LocalizedError {
    var errorDescription: String? {
        "The audio output is being rebuilt; the profile change was not applied."
    }
}

struct RealtimeOutputFade: Sendable {
    // Five milliseconds removes callback-boundary steps without delaying steady-state audio.
    static let durationSeconds = 0.005

    private let rampFrameCount: Int
    private(set) var gain: Float
    private var startGain: Float
    private var targetGain: Float
    private var completedFrames = 0
    private var remainingFrames = 0

    init(
        sampleRate: Double,
        initiallyMuted: Bool = true,
        durationSeconds: Double = Self.durationSeconds
    ) {
        let validSampleRate = sampleRate.isFinite && sampleRate > 0 ? sampleRate : 48_000
        let validDuration = durationSeconds.isFinite && durationSeconds > 0
            ? durationSeconds
            : Self.durationSeconds
        self.rampFrameCount = max(Int((validSampleRate * validDuration).rounded()), 1)
        let initialGain: Float = initiallyMuted ? 0 : 1
        self.gain = initialGain
        self.startGain = initialGain
        self.targetGain = initialGain
    }

    var isMuted: Bool {
        remainingFrames == 0 && gain == 0
    }

    mutating func setMuted(_ isMuted: Bool) {
        let nextTarget: Float = isMuted ? 0 : 1
        guard nextTarget != targetGain else {
            return
        }
        startGain = gain
        targetGain = nextTarget
        completedFrames = 0
        remainingFrames = rampFrameCount
    }

    mutating func apply(
        to samples: UnsafeMutableBufferPointer<Float>,
        frameCount: Int,
        channelCount: Int
    ) {
        let channels = max(channelCount, 1)
        let availableFrames = min(max(frameCount, 0), samples.count / channels)
        guard availableFrames > 0 else {
            return
        }

        if remainingFrames == 0 {
            guard gain != 1 else {
                return
            }
            for index in 0..<(availableFrames * channels) {
                samples[index] = 0
            }
            return
        }

        var sampleIndex = 0
        for _ in 0..<availableFrames {
            let frameGain = gain
            for channel in 0..<channels {
                samples[sampleIndex + channel] *= frameGain
            }
            sampleIndex += channels
            advance()
        }
    }

    private mutating func advance() {
        guard remainingFrames > 0 else {
            return
        }
        remainingFrames -= 1
        if remainingFrames == 0 {
            gain = targetGain
        } else {
            completedFrames += 1
            let progress = Float(completedFrames) / Float(rampFrameCount)
            let smoothedProgress = progress * progress * (3 - 2 * progress)
            gain = startGain + (targetGain - startGain) * smoothedProgress
        }
    }
}

struct RealtimeOutputDeclicker: Sendable {
    static let durationSeconds = 64.0 / 48_000.0

    private let correctionFrameCount: Int
    private var lastSamples: [Float]
    private var correctionAnchors: [Float]
    private var hasLastSamples = false
    private var correctionPending = false
    private var completedCorrectionFrames = 0
    private var remainingCorrectionFrames = 0

    init(
        sampleRate: Double,
        channelCount: Int,
        durationSeconds: Double = Self.durationSeconds
    ) {
        let validSampleRate = sampleRate.isFinite && sampleRate > 0 ? sampleRate : 48_000
        let validDuration = durationSeconds.isFinite && durationSeconds > 0
            ? durationSeconds
            : Self.durationSeconds
        self.correctionFrameCount = max(
            Int((validSampleRate * validDuration).rounded()),
            2
        )
        let channels = max(channelCount, 1)
        self.lastSamples = Array(repeating: 0, count: channels)
        self.correctionAnchors = Array(repeating: 0, count: channels)
    }

    mutating func markDiscontinuity() {
        correctionPending = true
    }

    mutating func apply(
        to samples: UnsafeMutableBufferPointer<Float>,
        frameCount: Int,
        channelCount: Int
    ) {
        guard channelCount == lastSamples.count else {
            return
        }
        let availableFrames = min(max(frameCount, 0), samples.count / channelCount)
        guard availableFrames > 0 else {
            return
        }

        if correctionPending {
            correctionPending = false
            if hasLastSamples {
                for channel in 0..<channelCount {
                    correctionAnchors[channel] = lastSamples[channel]
                }
                completedCorrectionFrames = 0
                remainingCorrectionFrames = correctionFrameCount
            }
        }

        let framesToCorrect = min(availableFrames, remainingCorrectionFrames)
        if framesToCorrect > 0 {
            var sampleIndex = 0
            for _ in 0..<framesToCorrect {
                let progress = Float(completedCorrectionFrames)
                    / Float(correctionFrameCount - 1)
                let smoothedProgress = progress * progress * (3 - 2 * progress)
                for channel in 0..<channelCount {
                    let anchor = correctionAnchors[channel]
                    samples[sampleIndex + channel] = anchor
                        + (samples[sampleIndex + channel] - anchor) * smoothedProgress
                }
                completedCorrectionFrames += 1
                remainingCorrectionFrames -= 1
                sampleIndex += channelCount
            }
        }

        let lastFrameIndex = (availableFrames - 1) * channelCount
        for channel in 0..<channelCount {
            lastSamples[channel] = samples[lastFrameIndex + channel]
        }
        hasLastSamples = true
    }
}

struct ExtremeDurationSnapshot {
    var observations: UInt64
    var p9999Nanoseconds: UInt64
    var maximumNanoseconds: UInt64
}

final class RealtimeExtremeDurationTracker: @unchecked Sendable {
    private static let fineBucketCount = 256
    private static let fineBucketWidthNanoseconds: UInt64 = 250
    private static let coarseBucketCount = 256
    private static let coarseBucketWidthNanoseconds: UInt64 = 4_000
    private static let overflowBucket = fineBucketCount + coarseBucketCount
    private static let bucketCount = overflowBucket + 1
    private static let publishInterval: UInt64 = 1_024

    private let requestedGeneration = Atomic<UInt64>(0)
    private let publishedObservations = Atomic<UInt64>(0)
    private let publishedP9999Nanoseconds = Atomic<UInt64>(0)
    private let publishedMaximumNanoseconds = Atomic<UInt64>(0)
    private var localGeneration: UInt64 = 0
    private var bucketGenerations = [UInt64](repeating: .max, count: bucketCount)
    private var bucketCounts = [UInt64](repeating: 0, count: bucketCount)
    private var observations: UInt64 = 0
    private var maximumNanoseconds: UInt64 = 0
    private let publishPhase: UInt64

    init(publishPhase: UInt64 = 0) {
        self.publishPhase = publishPhase % Self.publishInterval
    }

    func record(_ nanoseconds: UInt64) {
        adoptRequestedGeneration()
        let bucket = Self.bucketIndex(for: nanoseconds)
        if bucketGenerations[bucket] != localGeneration {
            bucketGenerations[bucket] = localGeneration
            bucketCounts[bucket] = 0
        }
        bucketCounts[bucket] &+= 1
        observations &+= 1
        if nanoseconds > maximumNanoseconds {
            maximumNanoseconds = nanoseconds
            publishedMaximumNanoseconds.store(nanoseconds, ordering: .relaxed)
        }
        if observations == 1
            || (observations &+ publishPhase).isMultiple(of: Self.publishInterval) {
            publish()
        }
    }

    func reset() {
        requestedGeneration.wrappingAdd(1, ordering: .releasing)
        publishedObservations.store(0, ordering: .relaxed)
        publishedP9999Nanoseconds.store(0, ordering: .relaxed)
        publishedMaximumNanoseconds.store(0, ordering: .relaxed)
    }

    func snapshot() -> ExtremeDurationSnapshot {
        ExtremeDurationSnapshot(
            observations: publishedObservations.load(ordering: .relaxed),
            p9999Nanoseconds: publishedP9999Nanoseconds.load(ordering: .relaxed),
            maximumNanoseconds: publishedMaximumNanoseconds.load(ordering: .relaxed)
        )
    }

    private func adoptRequestedGeneration() {
        let requested = requestedGeneration.load(ordering: .acquiring)
        guard requested != localGeneration else {
            return
        }
        localGeneration = requested
        observations = 0
        maximumNanoseconds = 0
    }

    private func publish() {
        let rank = max(
            UInt64(ceil(Double(observations) * 0.9999)),
            1
        )
        var cumulative: UInt64 = 0
        var percentile = maximumNanoseconds
        for bucket in 0..<Self.bucketCount
        where bucketGenerations[bucket] == localGeneration {
            cumulative &+= bucketCounts[bucket]
            if cumulative >= rank {
                percentile = min(
                    Self.bucketUpperBound(
                        bucket,
                        maximumNanoseconds: maximumNanoseconds
                    ),
                    maximumNanoseconds
                )
                break
            }
        }
        publishedMaximumNanoseconds.store(maximumNanoseconds, ordering: .relaxed)
        publishedP9999Nanoseconds.store(percentile, ordering: .relaxed)
        publishedObservations.store(observations, ordering: .releasing)
    }

    private static func bucketIndex(for nanoseconds: UInt64) -> Int {
        let fineLimit = UInt64(fineBucketCount) * fineBucketWidthNanoseconds
        if nanoseconds < fineLimit {
            return Int(nanoseconds / fineBucketWidthNanoseconds)
        }
        let coarseOffset = nanoseconds - fineLimit
        let coarseBucket = Int(coarseOffset / coarseBucketWidthNanoseconds)
        return coarseBucket < coarseBucketCount
            ? fineBucketCount + coarseBucket
            : overflowBucket
    }

    private static func bucketUpperBound(
        _ bucket: Int,
        maximumNanoseconds: UInt64
    ) -> UInt64 {
        if bucket < fineBucketCount {
            return UInt64(bucket + 1) * fineBucketWidthNanoseconds
        }
        if bucket < overflowBucket {
            let fineLimit = UInt64(fineBucketCount) * fineBucketWidthNanoseconds
            return fineLimit
                + UInt64(bucket - fineBucketCount + 1) * coarseBucketWidthNanoseconds
        }
        return maximumNanoseconds
    }
}

public final class SystemTapAudioEngine: @unchecked Sendable {
    private static let preferredAggregateBufferFrameSize: UInt32 = 16
    private static let maximumSupportedCallbackFrames = 8192
    private static let startupQualificationCallbacks: UInt64 = 32
    private static let startupProbationCallbacks: UInt64 = 8
    private static let systemSoundServerBundleID = "systemsoundserverd"
    private static let headsetClockProbeDuration: TimeInterval = 0.5
    private static let headsetAggregateValidationDuration: TimeInterval = 0.75
    static let runtimeRingCapacityFrames = SeparateClockAudioBackend.runtimeRingCapacityFrames

    private enum ActiveBackend: Equatable {
        case combinedAggregate
        case separateClock
    }

    struct StartupQualificationSnapshot {
        var validCallbackStreak: UInt64
        var observedCallbacks: UInt64
        var rejectedCallbacks: UInt64
    }

    struct AggregateStartupQualificationError: Error,
        LocalizedError,
        CustomStringConvertible {
        var expectedFrameCount: Int
        var snapshot: StartupQualificationSnapshot

        var errorDescription: String? {
            "Core Audio did not deliver stable \(expectedFrameCount)-frame callbacks while starting the output."
        }

        var description: String {
            errorDescription ?? "Core Audio callbacks did not settle during startup."
        }
    }

    #if DEBUG
    struct CombinedStartupTestBoundary {
        var attempt: (UInt32) throws -> Void
        var restoreSeparateClockBackend: (
            AudioOutputDevice,
            EQProfile,
            Bool
        ) throws -> Void
        var waitBeforeRetry: () -> Void
        var stopSeparateClockBackend: () -> Void = {}
        var stopCombinedResources: () -> Void = {}
    }
    #endif

    final class AggregateCallbackFrameExpectation: @unchecked Sendable {
        struct Validation {
            fileprivate var expectation: UInt64
            var isValid: Bool
        }

        private static let streakMask = UInt64(UInt16.max)
        // One atomic transition changes the generation, applied size, and startup streak.
        private let state: Atomic<UInt64>
        private let rejectedCallbacks = Atomic<UInt64>(0)

        init(frameCount: Int) {
            self.state = Atomic(Self.encodedState(
                generation: 0,
                frameCount: frameCount,
                validCallbackStreak: 0
            ))
        }

        func update(appliedFrameCount: UInt32) {
            let previous = state.load(ordering: .relaxed)
            let generation = UInt32(truncatingIfNeeded: previous >> 32) &+ 1
            state.store(
                Self.encodedState(
                    generation: generation,
                    frameCount: Int(appliedFrameCount),
                    validCallbackStreak: 0
                ),
                ordering: .releasing
            )
        }

        func validateCallback(
            mainInputFrameCount: Int,
            systemSoundInputFrameCount: Int,
            outputFrameCount: Int,
            timestampsAreStable: Bool
        ) -> Validation {
            let snapshot = state.load(ordering: .acquiring)
            let expectedFrameCount = Int((snapshot >> 16) & UInt64(UInt16.max))
            return Validation(
                expectation: snapshot & ~Self.streakMask,
                isValid: SystemTapAudioEngine.startupCallbackIsValid(
                    mainInputFrameCount: mainInputFrameCount,
                    systemSoundInputFrameCount: systemSoundInputFrameCount,
                    outputFrameCount: outputFrameCount,
                    expectedFrameCount: expectedFrameCount,
                    timestampsAreStable: timestampsAreStable
                )
            )
        }

        func recordCallback(
            _ validation: Validation,
            metDeadlines: Bool
        ) {
            let current = state.load(ordering: .acquiring)
            guard current & ~Self.streakMask == validation.expectation else {
                return
            }

            let isValid = validation.isValid && metDeadlines
            let currentStreak = current & Self.streakMask
            let nextStreak = isValid
                ? min(currentStreak + 1, Self.streakMask)
                : 0
            let exchange = state.compareExchange(
                expected: current,
                desired: validation.expectation | nextStreak,
                ordering: .acquiringAndReleasing
            )
            if exchange.exchanged, !isValid {
                rejectedCallbacks.wrappingAdd(1, ordering: .relaxed)
            }
        }

        var validCallbackStreak: UInt64 {
            state.load(ordering: .acquiring) & Self.streakMask
        }

        var rejectedCallbackCount: UInt64 {
            rejectedCallbacks.load(ordering: .acquiring)
        }

        private static func encodedState(
            generation: UInt32,
            frameCount: Int,
            validCallbackStreak: UInt16
        ) -> UInt64 {
            let boundedFrameCount = UInt16(
                min(max(frameCount, 1), Int(UInt16.max))
            )
            return UInt64(generation) << 32
                | UInt64(boundedFrameCount) << 16
                | UInt64(validCallbackStreak)
        }
    }

    private struct PromotedHeadsetRoute: Equatable {
        var outputUID: String
        var nominalSampleRate: Int64
    }

    private struct DeferredColdStartupRoute: Equatable {
        var outputUID: String
        var nominalSampleRate: Int64
    }

    private struct ControlState {
        var state: AudioEngineState = .stopped
        var status: AudioEngineStatus = .stopped
        var tapID = AudioObjectID(kAudioObjectUnknown)
        var systemSoundTapID = AudioObjectID(kAudioObjectUnknown)
        var tapOutputUID: String?
        var tapOutputStreamIndex: Int?
        var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        var ioProcID: AudioDeviceIOProcID?
        var runtime: AudioRuntime?
        var lastTimestampProbeRecords: [AudioTimestampProbeRecord] = []
        var activeOutput: AudioOutputDevice?
        var activeProfile: EQProfile?
        var preferredAggregateBufferFrameSize = SystemTapAudioEngine.preferredAggregateBufferFrameSize
    }

    private struct CombinedRoutePreparation {
        var output: AudioOutputDevice
        var outputStreamIndex: Int
        var outputStreamChannelCounts: [Int]
        var channelPair: (left: Int, right: Int)
    }

    private struct CombinedTapSet {
        var main: AudioObjectID
        var systemSounds: AudioObjectID
        var outputUID: String
        var outputStreamIndex: Int
    }

    private struct DetachedCombinedAggregate {
        var deviceID: AudioObjectID
        var ioProcID: AudioDeviceIOProcID?
        var runtime: AudioRuntime?
    }

    private struct PreparedCombinedAggregate {
        var taps: CombinedTapSet
        var deviceID: AudioObjectID
        var ioProcID: AudioDeviceIOProcID
        var runtime: AudioRuntime
        var output: AudioOutputDevice
        var profile: EQProfile
        var ioStarted: Bool
    }

    private struct CombinedAggregateCreation {
        var deviceID: AudioObjectID
        var mainTapUID: String
        var systemSoundTapUID: String
    }

    private final class PreparedDSPConfigBox: @unchecked Sendable {
        var processor: EQProcessor?
        var comparisonReferenceProcessor: EQProcessor?
        let systemSoundPreampGains: (left: Float, right: Float)
        var retiredProcessor: EQProcessor?
        var secondRetiredProcessor: EQProcessor?
        var nextRetiredPointer: UInt = 0

        init(config: EQRenderConfiguration) {
            self.processor = EQProcessor(renderConfiguration: config)
            self.systemSoundPreampGains = SystemTapAudioEngine.systemSoundPreampGains(
                for: config
            )
        }

        init(
            equalizedConfig: EQRenderConfiguration,
            referenceConfig: EQRenderConfiguration
        ) {
            self.processor = EQProcessor(renderConfiguration: equalizedConfig)
            self.comparisonReferenceProcessor = EQProcessor(
                renderConfiguration: referenceConfig
            )
            self.systemSoundPreampGains = SystemTapAudioEngine.systemSoundPreampGains(
                for: equalizedConfig
            )
        }
    }

    private final class AudioRuntime: @unchecked Sendable {
        private struct TimestampContinuityState {
            var expectedSampleTime: Float64?
            var previousHostTime: UInt64?
            var previousFrameCount = 0
            var stableSlopeObservations = 0
        }

        private struct TimestampJump {
            var sampleTimeDeltaFrames: Double
            var hostIntervalErrorNanoseconds: Int64
            var precededByStableSlope: Bool
        }

        let channelCount: Int
        let sampleRate: Double

        private let inputChannelOffset: Int
        private let systemSoundInputChannelOffset: Int
        private let callbackFrameExpectation: AggregateCallbackFrameExpectation
        private let maxCallbackFrames: Int
        private var dspTransition: RealtimeEQTransition
        private var activeSystemSoundPreampGains: (left: Float, right: Float)
        private var outputFade: RealtimeOutputFade
        private var outputDeclicker: RealtimeOutputDeclicker
        private var scratchSamples: [Float]
        private var inputTimestampState = TimestampContinuityState()
        private var outputTimestampState = TimestampContinuityState()
        private var lastPairedTimestampJumpHostTime: UInt64?
        private var timestampProbeRecords = Array(
            repeating: AudioTimestampProbeRecord(),
            count: 64
        )
        private var timestampProbeWriteIndex = 0
        private var timestampProbeRecordCount = 0
        private var timestampProbeSequence: UInt64 = 0
        private let capturedFrames = Atomic<UInt64>(0)
        private let playedFrames = Atomic<UInt64>(0)
        #if DEBUG
        private let freezePlayedFramesForTesting = Atomic<Bool>(false)
        #endif
        private let playbackUnderrunFrames = Atomic<UInt64>(0)
        private let droppedInputFrames = Atomic<UInt64>(0)
        private let saturatedSamples = Atomic<UInt64>(0)
        private let inputTimestampDiscontinuities = Atomic<UInt64>(0)
        private let outputTimestampDiscontinuities = Atomic<UInt64>(0)
        private let pairedTimestampDiscontinuities = Atomic<UInt64>(0)
        private let qualifyingPairedTimestampDiscontinuities = Atomic<UInt64>(0)
        private let renderCallbackObservations = Atomic<UInt64>(0)
        private let firstRenderCallbackHostTimeNanoseconds = Atomic<UInt64>(0)
        private let lastInputTimestampJumpMilliFrames = Atomic<Int64>(0)
        private let lastOutputTimestampJumpMilliFrames = Atomic<Int64>(0)
        private let lastInputHostIntervalErrorNanoseconds = Atomic<Int64>(0)
        private let lastOutputHostIntervalErrorNanoseconds = Atomic<Int64>(0)
        private let timestampJumpIntervalObservations = Atomic<UInt64>(0)
        private let minimumTimestampJumpIntervalNanoseconds = Atomic<UInt64>(.max)
        private let maximumTimestampJumpIntervalNanoseconds = Atomic<UInt64>(0)
        private let totalTimestampJumpIntervalNanoseconds = Atomic<UInt64>(0)
        private let maxCaptureCallbackFrames = Atomic<Int>(0)
        private let maxPlaybackCallbackFrames = Atomic<Int>(0)
        private let renderDeadlineMisses = Atomic<UInt64>(0)
        private let callbackStartStarvations = Atomic<UInt64>(0)
        private let renderOverruns = Atomic<UInt64>(0)
        private var previousRenderStartNanoseconds: UInt64?
        private var previousRenderFrameCount = 0
        private let callbackStartLateness = RealtimeExtremeDurationTracker(publishPhase: 0)
        private let directHeadDuration = RealtimeExtremeDurationTracker(publishPhase: 205)
        private let tailWorkDuration = RealtimeExtremeDurationTracker(publishPhase: 410)
        private let totalRenderDuration = RealtimeExtremeDurationTracker(publishPhase: 615)
        private let completionLateness = RealtimeExtremeDurationTracker(publishPhase: 820)
        private let tailCompletionObservations = Atomic<UInt64>(0)
        private let minimumTailCompletionSlackFrames = Atomic<Int>(Int.max)
        private let tailDeadlineMisses = Atomic<UInt64>(0)
        private let tapToOutputLatencyObservations = Atomic<UInt64>(0)
        private let minTapToOutputLatencyNanoseconds = Atomic<UInt64>(.max)
        private let maxTapToOutputLatencyNanoseconds = Atomic<UInt64>(0)
        private let totalTapToOutputLatencyNanoseconds = Atomic<UInt64>(0)
        private let callbackTimingObservations = Atomic<UInt64>(0)
        private let minInputAgeNanoseconds = Atomic<UInt64>(.max)
        private let maxInputAgeNanoseconds = Atomic<UInt64>(0)
        private let totalInputAgeNanoseconds = Atomic<UInt64>(0)
        private let minOutputLeadNanoseconds = Atomic<UInt64>(.max)
        private let maxOutputLeadNanoseconds = Atomic<UInt64>(0)
        private let totalOutputLeadNanoseconds = Atomic<UInt64>(0)
        private let outputMutedForTransition = Atomic<Bool>(true)
        private let outputIsMuted = Atomic<Bool>(true)
        private let programmeComparisonSelection = Atomic<UInt>(
            UInt(EQProgrammeComparisonSelection.equalized.rawValue)
        )
        private let programmeComparisonActive = Atomic<Bool>(false)
        private let programmeComparisonReady = Atomic<Bool>(false)
        private let equalizedAttenuationMilliDB = Atomic<Int64>(0)
        private let filtersOffAttenuationMilliDB = Atomic<Int64>(0)
        private let pendingDSPConfigPointer = Atomic<UInt>(0)
        private let retiredDSPConfigHeadPointer = Atomic<UInt>(0)
        private var activeDSPConfigPointer: UInt = 0
        private let stopping = Atomic<Bool>(false)
        private let inCallback = Atomic<Bool>(false)
        private let playbackChannelPair = Atomic<UInt64>(
            SystemTapAudioEngine.encodedPlaybackChannelPair(left: 0, right: 1)
        )

        init(
            renderConfiguration: EQRenderConfiguration,
            inputChannelOffset: Int,
            systemSoundInputChannelOffset: Int,
            expectedCallbackFrames: Int,
            maxCallbackFrames: Int
        ) {
            self.channelCount = max(renderConfiguration.configuration.channelCount, 1)
            self.sampleRate = renderConfiguration.configuration.sampleRate
            self.inputChannelOffset = max(inputChannelOffset, 0)
            self.systemSoundInputChannelOffset = max(systemSoundInputChannelOffset, 0)
            self.callbackFrameExpectation = AggregateCallbackFrameExpectation(
                frameCount: expectedCallbackFrames
            )
            self.maxCallbackFrames = maxCallbackFrames
            self.outputFade = RealtimeOutputFade(sampleRate: self.sampleRate)
            self.outputDeclicker = RealtimeOutputDeclicker(
                sampleRate: self.sampleRate,
                channelCount: self.channelCount
            )
            self.scratchSamples = Array(
                repeating: 0,
                count: maxCallbackFrames * self.channelCount
            )
            self.dspTransition = RealtimeEQTransition(
                activeProcessor: EQProcessor(renderConfiguration: renderConfiguration),
                maximumFrameCount: maxCallbackFrames,
                channelCount: self.channelCount,
                sampleRate: self.sampleRate
            )
            self.activeSystemSoundPreampGains = SystemTapAudioEngine.systemSoundPreampGains(
                for: renderConfiguration
            )
        }

        deinit {
            drainDSPConfigBoxes()
            releaseDSPConfigBox(activeDSPConfigPointer)
        }

        func render(
            inputData: UnsafePointer<AudioBufferList>,
            inputTime: AudioTimeStamp,
            outputData: UnsafeMutablePointer<AudioBufferList>,
            outputTime: AudioTimeStamp
        ) {
            let outputBuffers = UnsafeMutableAudioBufferListPointer(outputData)
            clear(outputBuffers)

            guard !stopping.load(ordering: .acquiring),
                  enter(inCallback) else {
                return
            }
            let callbackHostTime = AudioGetCurrentHostTime()
            defer {
                inCallback.store(false, ordering: .releasing)
            }

            let inputBuffers = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: inputData)
            )
            guard let mainInputFrameCount = frameCount(
                inputBuffers,
                channelOffset: inputChannelOffset,
                channelCount: channelCount
            ),
                  let rawSystemSoundFrameCount = frameCount(
                    inputBuffers,
                    channelOffset: systemSoundInputChannelOffset,
                    channelCount: channelCount
                  ),
                  let outputFrameCount = frameCount(outputBuffers) else {
                return
            }
            let systemSoundFrameCount = rawSystemSoundFrameCount == 0
                ? mainInputFrameCount
                : rawSystemSoundFrameCount
            let inputFrameCount = min(mainInputFrameCount, systemSoundFrameCount)

            let renderStartNanoseconds = AudioConvertHostTimeToNanos(callbackHostTime)
            _ = firstRenderCallbackHostTimeNanoseconds.compareExchange(
                expected: 0,
                desired: renderStartNanoseconds,
                ordering: .relaxed
            )
            let previousRenderStart = previousRenderStartNanoseconds
            let expectedEntryIntervalNanoseconds = previousRenderStart.map { _ in
                SystemTapAudioEngine.renderPeriodNanoseconds(
                    frameCount: previousRenderFrameCount,
                    sampleRate: sampleRate
                )
            } ?? 0
            let entryElapsedNanoseconds = previousRenderStart.map {
                renderStartNanoseconds >= $0 ? renderStartNanoseconds - $0 : 0
            } ?? 0
            let callbackStartLatenessNanoseconds = entryElapsedNanoseconds
                > expectedEntryIntervalNanoseconds
                ? entryElapsedNanoseconds - expectedEntryIntervalNanoseconds
                : 0
            if previousRenderStart != nil {
                callbackStartLateness.record(callbackStartLatenessNanoseconds)
            }
            let entryDeadlineMisses = previousRenderStart.map { _ in
                SystemTapAudioEngine.missedRenderDeadlines(
                    elapsedNanoseconds: entryElapsedNanoseconds,
                    frameCount: previousRenderFrameCount,
                    sampleRate: sampleRate
                )
            } ?? 0
            previousRenderStartNanoseconds = renderStartNanoseconds
            previousRenderFrameCount = outputFrameCount
            var renderWorkTiming = EQRenderWorkTiming()
            var startupCallbackValidation: AggregateCallbackFrameExpectation.Validation?
            defer {
                let renderEndNanoseconds = AudioConvertHostTimeToNanos(
                    AudioGetCurrentHostTime()
                )
                let totalRenderNanoseconds = renderEndNanoseconds >= renderStartNanoseconds
                    ? renderEndNanoseconds - renderStartNanoseconds
                    : 0
                totalRenderDuration.record(totalRenderNanoseconds)
                if previousRenderStart != nil {
                    let currentPeriodNanoseconds = SystemTapAudioEngine.renderPeriodNanoseconds(
                        frameCount: outputFrameCount,
                        sampleRate: sampleRate
                    )
                    let completionElapsed = callbackStartLatenessNanoseconds
                        .addingReportingOverflow(totalRenderNanoseconds)
                    let completionElapsedNanoseconds = completionElapsed.overflow
                        ? UInt64.max
                        : completionElapsed.partialValue
                    completionLateness.record(
                        completionElapsedNanoseconds > currentPeriodNanoseconds
                            ? completionElapsedNanoseconds - currentPeriodNanoseconds
                            : 0
                    )
                }
                if renderWorkTiming.directHeadHostTicks > 0 {
                    directHeadDuration.record(
                        AudioConvertHostTimeToNanos(renderWorkTiming.directHeadHostTicks)
                    )
                }
                if renderWorkTiming.tailScheduledWorkHostTicks > 0 {
                    tailWorkDuration.record(
                        AudioConvertHostTimeToNanos(renderWorkTiming.tailScheduledWorkHostTicks)
                    )
                }
                if renderWorkTiming.tailCompletionObservations > 0 {
                    tailCompletionObservations.wrappingAdd(
                        renderWorkTiming.tailCompletionObservations,
                        ordering: .relaxed
                    )
                    updateMinimum(
                        minimumTailCompletionSlackFrames,
                        renderWorkTiming.minimumTailCompletionSlackFrames
                    )
                }
                if renderWorkTiming.tailDeadlineMisses > 0 {
                    tailDeadlineMisses.wrappingAdd(
                        renderWorkTiming.tailDeadlineMisses,
                        ordering: .relaxed
                    )
                }
                let executionDeadlineMisses = SystemTapAudioEngine.missedRenderDeadlines(
                    elapsedNanoseconds: totalRenderNanoseconds,
                    frameCount: outputFrameCount,
                    sampleRate: sampleRate
                )
                if let startupCallbackValidation {
                    callbackFrameExpectation.recordCallback(
                        startupCallbackValidation,
                        metDeadlines: entryDeadlineMisses == 0
                            && executionDeadlineMisses == 0
                    )
                }
                if entryDeadlineMisses > 0 {
                    callbackStartStarvations.wrappingAdd(1, ordering: .relaxed)
                }
                if SystemTapAudioEngine.renderOverranPeriod(
                    elapsedNanoseconds: totalRenderNanoseconds,
                    frameCount: outputFrameCount,
                    sampleRate: sampleRate
                ) {
                    renderOverruns.wrappingAdd(1, ordering: .relaxed)
                }
                let missedDeadlines = max(entryDeadlineMisses, executionDeadlineMisses)
                if missedDeadlines > 0 {
                    renderDeadlineMisses.wrappingAdd(
                        1,
                        ordering: .relaxed
                    )
                }
            }

            let timestampsAreStable = recordTimestampContinuity(
                inputTime: inputTime,
                inputFrameCount: inputFrameCount,
                outputTime: outputTime,
                outputFrameCount: outputFrameCount
            )
            startupCallbackValidation = callbackFrameExpectation.validateCallback(
                mainInputFrameCount: mainInputFrameCount,
                systemSoundInputFrameCount: rawSystemSoundFrameCount,
                outputFrameCount: outputFrameCount,
                timestampsAreStable: timestampsAreStable
            )
            renderCallbackObservations.wrappingAdd(1, ordering: .relaxed)

            updateMax(maxCaptureCallbackFrames, inputFrameCount)
            updateMax(maxPlaybackCallbackFrames, outputFrameCount)
            capturedFrames.wrappingAdd(UInt64(inputFrameCount), ordering: .relaxed)

            if inputFrameCount < outputFrameCount {
                playbackUnderrunFrames.wrappingAdd(
                    UInt64(outputFrameCount - inputFrameCount),
                    ordering: .relaxed
                )
            } else if inputFrameCount > outputFrameCount {
                droppedInputFrames.wrappingAdd(
                    UInt64(inputFrameCount - outputFrameCount),
                    ordering: .relaxed
                )
            }

            let frameCount = min(inputFrameCount, outputFrameCount)
            guard frameCount > 0,
                  frameCount <= maxCallbackFrames else {
                return
            }

            recordCallbackLatency(
                inputTime: inputTime,
                callbackHostTime: callbackHostTime,
                outputTime: outputTime
            )
            prepareDSPAndOutputFade()
            if programmeComparisonActive.load(ordering: .relaxed) {
                dspTransition.setProgrammeComparisonSelection(
                    selectedProgrammeComparisonBranch()
                )
            }
            let sampleCount = frameCount * channelCount
            scratchSamples.withUnsafeMutableBufferPointer { scratch in
                let samples = UnsafeMutableBufferPointer(
                    start: scratch.baseAddress,
                    count: sampleCount
                )
                SystemTapAudioEngine.copyInputSamples(
                    from: inputBuffers,
                    into: samples,
                    frameCount: frameCount,
                    channelCount: channelCount,
                    sourceChannelOffset: inputChannelOffset
                )

                let transitionResult = dspTransition.processInterleavedWithDiagnostics(
                    samples,
                    frameCount: frameCount,
                    channelCount: channelCount
                )
                renderWorkTiming = transitionResult.workTiming
                if transitionResult.programmeComparison.isActive
                    || programmeComparisonActive.load(ordering: .relaxed) {
                    publishProgrammeComparisonSnapshot(
                        transitionResult.programmeComparison
                    )
                }
                if transitionResult.saturatedSamples > 0 {
                    saturatedSamples.wrappingAdd(
                        transitionResult.saturatedSamples,
                        ordering: .relaxed
                    )
                }

                let systemSoundSaturated = SystemTapAudioEngine.mixInputSamples(
                    from: inputBuffers,
                    into: samples,
                    frameCount: frameCount,
                    channelCount: channelCount,
                    sourceChannelOffset: systemSoundInputChannelOffset,
                    preampGains: activeSystemSoundPreampGains,
                    incomingPreampGains: incomingSystemSoundPreampGains(),
                    transition: transitionResult
                )
                finishDSPTransition(transitionResult)
                if systemSoundSaturated > 0 {
                    saturatedSamples.wrappingAdd(
                        systemSoundSaturated,
                        ordering: .relaxed
                    )
                }

                outputFade.apply(
                    to: samples,
                    frameCount: frameCount,
                    channelCount: channelCount
                )
                outputDeclicker.apply(
                    to: samples,
                    frameCount: frameCount,
                    channelCount: channelCount
                )
                outputIsMuted.store(outputFade.isMuted, ordering: .releasing)

                let channelPair = SystemTapAudioEngine.decodedPlaybackChannelPair(
                    playbackChannelPair.load(ordering: .acquiring)
                )
                SystemTapAudioEngine.copyInterleavedSamples(
                    UnsafeBufferPointer(samples),
                    sourceFrameOffset: 0,
                    destinationFrameOffset: 0,
                    frameCount: frameCount,
                    sourceChannelCount: channelCount,
                    destinationLeftChannel: channelPair.left,
                    destinationRightChannel: channelPair.right,
                    to: outputBuffers
                )
            }
            #if DEBUG
            if !freezePlayedFramesForTesting.load(ordering: .relaxed) {
                playedFrames.wrappingAdd(UInt64(frameCount), ordering: .relaxed)
            }
            #else
            playedFrames.wrappingAdd(UInt64(frameCount), ordering: .relaxed)
            #endif
        }

        #if DEBUG
        func simulateRenderStallForTesting() {
            freezePlayedFramesForTesting.store(true, ordering: .releasing)
        }
        #endif

        func activate() {
            outputMutedForTransition.store(false, ordering: .releasing)
        }

        func updateExpectedCallbackFrames(appliedFrameCount: UInt32) {
            callbackFrameExpectation.update(appliedFrameCount: appliedFrameCount)
        }

        func waitForQualifiedStartup(
            minimumConsecutiveCallbacks: UInt64,
            timeout: TimeInterval
        ) -> StartupQualificationSnapshot {
            let deadline = DispatchTime.now().uptimeNanoseconds
                + UInt64(max(timeout, 0) * 1_000_000_000)
            while callbackFrameExpectation.validCallbackStreak
                    < minimumConsecutiveCallbacks,
                  DispatchTime.now().uptimeNanoseconds < deadline {
                Thread.sleep(forTimeInterval: 0.001)
            }
            return StartupQualificationSnapshot(
                validCallbackStreak: callbackFrameExpectation.validCallbackStreak,
                observedCallbacks: renderCallbackObservations.load(ordering: .acquiring),
                rejectedCallbacks: callbackFrameExpectation.rejectedCallbackCount
            )
        }

        func firstRenderCallbackHostTime() -> UInt64? {
            let value = firstRenderCallbackHostTimeNanoseconds.load(ordering: .acquiring)
            return value == 0 ? nil : value
        }

        func markStopping() {
            stopping.store(true, ordering: .releasing)
            outputMutedForTransition.store(true, ordering: .releasing)
        }

        func fadeOutForStop() {
            outputMutedForTransition.store(true, ordering: .releasing)
            // A disconnected route may no longer deliver callbacks, so never wait indefinitely.
            let timeout = DispatchTime.now().uptimeNanoseconds
                + UInt64((RealtimeOutputFade.durationSeconds + 0.02) * 1_000_000_000)
            while !outputIsMuted.load(ordering: .acquiring),
                  DispatchTime.now().uptimeNanoseconds < timeout {
                Thread.sleep(forTimeInterval: 0.001)
            }
        }

        func muteOutputForTransition() {
            outputMutedForTransition.store(true, ordering: .releasing)
        }

        func setPlaybackChannelPair(left: Int, right: Int) {
            playbackChannelPair.store(
                SystemTapAudioEngine.encodedPlaybackChannelPair(left: left, right: right),
                ordering: .releasing
            )
        }

        func resetMetrics() {
            capturedFrames.store(0, ordering: .relaxed)
            playedFrames.store(0, ordering: .relaxed)
            playbackUnderrunFrames.store(0, ordering: .relaxed)
            droppedInputFrames.store(0, ordering: .relaxed)
            saturatedSamples.store(0, ordering: .relaxed)
            inputTimestampDiscontinuities.store(0, ordering: .relaxed)
            outputTimestampDiscontinuities.store(0, ordering: .relaxed)
            pairedTimestampDiscontinuities.store(0, ordering: .relaxed)
            qualifyingPairedTimestampDiscontinuities.store(0, ordering: .relaxed)
            lastInputTimestampJumpMilliFrames.store(0, ordering: .relaxed)
            lastOutputTimestampJumpMilliFrames.store(0, ordering: .relaxed)
            lastInputHostIntervalErrorNanoseconds.store(0, ordering: .relaxed)
            lastOutputHostIntervalErrorNanoseconds.store(0, ordering: .relaxed)
            timestampJumpIntervalObservations.store(0, ordering: .relaxed)
            minimumTimestampJumpIntervalNanoseconds.store(.max, ordering: .relaxed)
            maximumTimestampJumpIntervalNanoseconds.store(0, ordering: .relaxed)
            totalTimestampJumpIntervalNanoseconds.store(0, ordering: .relaxed)
            maxCaptureCallbackFrames.store(0, ordering: .relaxed)
            maxPlaybackCallbackFrames.store(0, ordering: .relaxed)
            renderDeadlineMisses.store(0, ordering: .relaxed)
            callbackStartStarvations.store(0, ordering: .relaxed)
            renderOverruns.store(0, ordering: .relaxed)
            callbackStartLateness.reset()
            directHeadDuration.reset()
            tailWorkDuration.reset()
            totalRenderDuration.reset()
            completionLateness.reset()
            tailCompletionObservations.store(0, ordering: .relaxed)
            minimumTailCompletionSlackFrames.store(Int.max, ordering: .relaxed)
            tailDeadlineMisses.store(0, ordering: .relaxed)
            tapToOutputLatencyObservations.store(0, ordering: .relaxed)
            minTapToOutputLatencyNanoseconds.store(.max, ordering: .relaxed)
            maxTapToOutputLatencyNanoseconds.store(0, ordering: .relaxed)
            totalTapToOutputLatencyNanoseconds.store(0, ordering: .relaxed)
            callbackTimingObservations.store(0, ordering: .relaxed)
            minInputAgeNanoseconds.store(.max, ordering: .relaxed)
            maxInputAgeNanoseconds.store(0, ordering: .relaxed)
            totalInputAgeNanoseconds.store(0, ordering: .relaxed)
            minOutputLeadNanoseconds.store(.max, ordering: .relaxed)
            maxOutputLeadNanoseconds.store(0, ordering: .relaxed)
            totalOutputLeadNanoseconds.store(0, ordering: .relaxed)
        }

        func snapshotMetrics() -> AudioEngineMetrics {
            let latencyObservations = tapToOutputLatencyObservations.load(ordering: .relaxed)
            let minimumLatency = minTapToOutputLatencyNanoseconds.load(ordering: .relaxed)
            let totalLatency = totalTapToOutputLatencyNanoseconds.load(ordering: .relaxed)
            let timingObservations = callbackTimingObservations.load(ordering: .relaxed)
            let minimumInputAge = minInputAgeNanoseconds.load(ordering: .relaxed)
            let totalInputAge = totalInputAgeNanoseconds.load(ordering: .relaxed)
            let minimumOutputLead = minOutputLeadNanoseconds.load(ordering: .relaxed)
            let totalOutputLead = totalOutputLeadNanoseconds.load(ordering: .relaxed)
            let jumpIntervalObservations = timestampJumpIntervalObservations.load(
                ordering: .relaxed
            )
            let minimumJumpInterval = minimumTimestampJumpIntervalNanoseconds.load(
                ordering: .relaxed
            )
            let totalJumpInterval = totalTimestampJumpIntervalNanoseconds.load(
                ordering: .relaxed
            )
            let callbackStart = callbackStartLateness.snapshot()
            let directHead = directHeadDuration.snapshot()
            let tailWork = tailWorkDuration.snapshot()
            let totalRender = totalRenderDuration.snapshot()
            let completion = completionLateness.snapshot()
            let tailCompletions = tailCompletionObservations.load(ordering: .relaxed)
            let minimumTailSlack = minimumTailCompletionSlackFrames.load(ordering: .relaxed)
            return AudioEngineMetrics(
                capturedFrames: capturedFrames.load(ordering: .relaxed),
                playedFrames: playedFrames.load(ordering: .relaxed),
                playbackUnderrunFrames: playbackUnderrunFrames.load(ordering: .relaxed),
                droppedInputFrames: droppedInputFrames.load(ordering: .relaxed),
                saturatedSamples: saturatedSamples.load(ordering: .relaxed),
                inputTimestampDiscontinuities: inputTimestampDiscontinuities.load(
                    ordering: .relaxed
                ),
                outputTimestampDiscontinuities: outputTimestampDiscontinuities.load(
                    ordering: .relaxed
                ),
                pairedTimestampDiscontinuities: pairedTimestampDiscontinuities.load(
                    ordering: .relaxed
                ),
                qualifyingPairedTimestampDiscontinuities:
                    qualifyingPairedTimestampDiscontinuities.load(ordering: .relaxed),
                lastInputTimestampJumpFrames: Double(
                    lastInputTimestampJumpMilliFrames.load(ordering: .relaxed)
                ) / 1_000,
                lastOutputTimestampJumpFrames: Double(
                    lastOutputTimestampJumpMilliFrames.load(ordering: .relaxed)
                ) / 1_000,
                lastInputHostIntervalErrorNanoseconds:
                    lastInputHostIntervalErrorNanoseconds.load(ordering: .relaxed),
                lastOutputHostIntervalErrorNanoseconds:
                    lastOutputHostIntervalErrorNanoseconds.load(ordering: .relaxed),
                timestampJumpIntervalObservations: jumpIntervalObservations,
                minimumTimestampJumpIntervalNanoseconds:
                    jumpIntervalObservations == 0 || minimumJumpInterval == .max
                        ? 0
                        : minimumJumpInterval,
                maximumTimestampJumpIntervalNanoseconds:
                    maximumTimestampJumpIntervalNanoseconds.load(ordering: .relaxed),
                averageTimestampJumpIntervalNanoseconds: jumpIntervalObservations == 0
                    ? 0
                    : Double(totalJumpInterval) / Double(jumpIntervalObservations),
                maximumCaptureCallbackFrames: maxCaptureCallbackFrames.load(ordering: .relaxed),
                maximumPlaybackCallbackFrames: maxPlaybackCallbackFrames.load(ordering: .relaxed),
                renderDeadlineMisses: renderDeadlineMisses.load(ordering: .relaxed),
                callbackStartStarvations: callbackStartStarvations.load(ordering: .relaxed),
                renderOverruns: renderOverruns.load(ordering: .relaxed),
                tapToOutputLatencyObservations: latencyObservations,
                minimumTapToOutputLatencyNanoseconds: latencyObservations == 0 || minimumLatency == .max
                    ? 0
                    : minimumLatency,
                maximumTapToOutputLatencyNanoseconds: maxTapToOutputLatencyNanoseconds.load(
                    ordering: .relaxed
                ),
                averageTapToOutputLatencyNanoseconds: latencyObservations == 0
                    ? 0
                    : Double(totalLatency) / Double(latencyObservations),
                callbackTimingObservations: timingObservations,
                minimumInputAgeNanoseconds: timingObservations == 0 || minimumInputAge == .max
                    ? 0
                    : minimumInputAge,
                maximumInputAgeNanoseconds: maxInputAgeNanoseconds.load(ordering: .relaxed),
                averageInputAgeNanoseconds: timingObservations == 0
                    ? 0
                    : Double(totalInputAge) / Double(timingObservations),
                minimumOutputLeadNanoseconds: timingObservations == 0 || minimumOutputLead == .max
                    ? 0
                    : minimumOutputLead,
                maximumOutputLeadNanoseconds: maxOutputLeadNanoseconds.load(ordering: .relaxed),
                averageOutputLeadNanoseconds: timingObservations == 0
                    ? 0
                    : Double(totalOutputLead) / Double(timingObservations),
                renderTiming: AudioRenderTimingMetrics(
                    callbackStartLatenessObservations: callbackStart.observations,
                    callbackStartLatenessP9999Nanoseconds: callbackStart.p9999Nanoseconds,
                    maximumCallbackStartLatenessNanoseconds: callbackStart.maximumNanoseconds,
                    directHeadObservations: directHead.observations,
                    directHeadP9999Nanoseconds: directHead.p9999Nanoseconds,
                    maximumDirectHeadNanoseconds: directHead.maximumNanoseconds,
                    tailWorkObservations: tailWork.observations,
                    tailWorkP9999Nanoseconds: tailWork.p9999Nanoseconds,
                    maximumTailWorkNanoseconds: tailWork.maximumNanoseconds,
                    totalRenderObservations: totalRender.observations,
                    totalRenderP9999Nanoseconds: totalRender.p9999Nanoseconds,
                    maximumTotalRenderNanoseconds: totalRender.maximumNanoseconds,
                    completionLatenessObservations: completion.observations,
                    completionLatenessP9999Nanoseconds: completion.p9999Nanoseconds,
                    maximumCompletionLatenessNanoseconds: completion.maximumNanoseconds,
                    tailCompletionObservations: tailCompletions,
                    minimumTailCompletionSlackFrames:
                        tailCompletions == 0 || minimumTailSlack == Int.max
                            ? 0
                            : minimumTailSlack,
                    tailDeadlineMisses: tailDeadlineMisses.load(ordering: .relaxed)
                )
            )
        }

        func snapshotTimestampProbeRecords() -> [AudioTimestampProbeRecord] {
            guard timestampProbeRecordCount > 0 else {
                return []
            }
            let capacity = timestampProbeRecords.count
            let firstIndex = (timestampProbeWriteIndex - timestampProbeRecordCount + capacity)
                % capacity
            return (0..<timestampProbeRecordCount).map { offset in
                timestampProbeRecords[(firstIndex + offset) % capacity]
            }
        }

        func publishPendingDSPConfig(_ config: EQRenderConfiguration) {
            let box = PreparedDSPConfigBox(config: config)
            publishPendingDSPConfigBox(box)
        }

        func publishPendingProgrammeComparison(
            equalizedConfig: EQRenderConfiguration,
            referenceConfig: EQRenderConfiguration
        ) {
            let box = PreparedDSPConfigBox(
                equalizedConfig: equalizedConfig,
                referenceConfig: referenceConfig
            )
            publishPendingDSPConfigBox(box)
        }

        func setProgrammeComparisonSelection(
            _ selection: EQProgrammeComparisonSelection
        ) {
            programmeComparisonSelection.store(
                UInt(selection.rawValue),
                ordering: .releasing
            )
        }

        func snapshotProgrammeComparison() -> EQProgrammeComparisonSnapshot {
            EQProgrammeComparisonSnapshot(
                isActive: programmeComparisonActive.load(ordering: .acquiring),
                isReady: programmeComparisonReady.load(ordering: .acquiring),
                selection: selectedProgrammeComparisonBranch(),
                equalizedAttenuationDB: Double(
                    equalizedAttenuationMilliDB.load(ordering: .relaxed)
                ) / 1_000,
                filtersOffAttenuationDB: Double(
                    filtersOffAttenuationMilliDB.load(ordering: .relaxed)
                ) / 1_000
            )
        }

        private func publishPendingDSPConfigBox(_ box: PreparedDSPConfigBox) {
            let rawPointer = UInt(bitPattern: Unmanaged.passRetained(box).toOpaque())
            let oldPointer = pendingDSPConfigPointer.exchange(
                rawPointer,
                ordering: .acquiringAndReleasing
            )
            releaseDSPConfigBox(oldPointer)
        }

        func drainDSPConfigBoxes() {
            releaseDSPConfigBox(
                pendingDSPConfigPointer.exchange(0, ordering: .acquiringAndReleasing)
            )
            var rawPointer = retiredDSPConfigHeadPointer.exchange(
                0,
                ordering: .acquiringAndReleasing
            )
            while rawPointer != 0 {
                guard let pointer = UnsafeRawPointer(bitPattern: rawPointer) else {
                    return
                }
                let box = Unmanaged<PreparedDSPConfigBox>
                    .fromOpaque(pointer)
                    .takeUnretainedValue()
                let nextPointer = box.nextRetiredPointer
                box.nextRetiredPointer = 0
                releaseDSPConfigBox(rawPointer)
                rawPointer = nextPointer
            }
        }

        private func beginPendingDSPTransitionIfPossible() {
            guard activeDSPConfigPointer == 0,
                  !dspTransition.isTransitioning else {
                return
            }
            let rawPointer = pendingDSPConfigPointer.exchange(
                0,
                ordering: .acquiringAndReleasing
            )
            guard rawPointer != 0,
                  let pointer = UnsafeRawPointer(bitPattern: rawPointer) else {
                return
            }

            let box = Unmanaged<PreparedDSPConfigBox>
                .fromOpaque(pointer)
                .takeUnretainedValue()
            guard let processor = box.processor else {
                pushRetiredDSPConfigBox(rawPointer)
                return
            }
            let didBegin: Bool
            if let referenceProcessor = box.comparisonReferenceProcessor {
                didBegin = dspTransition.beginProgrammeComparison(
                    equalizedProcessor: processor,
                    filtersOffProcessor: referenceProcessor
                )
            } else {
                didBegin = dspTransition.beginTransition(to: processor)
            }
            guard didBegin else {
                pushRetiredDSPConfigBox(rawPointer)
                return
            }
            box.processor = nil
            box.comparisonReferenceProcessor = nil
            activeDSPConfigPointer = rawPointer
        }

        private func finishDSPTransition(_ result: EQTransitionRenderResult) {
            guard result.completedTransition,
                  activeDSPConfigPointer != 0,
                  let pointer = UnsafeRawPointer(bitPattern: activeDSPConfigPointer) else {
                return
            }
            let rawPointer = activeDSPConfigPointer
            activeDSPConfigPointer = 0
            let box = Unmanaged<PreparedDSPConfigBox>
                .fromOpaque(pointer)
                .takeUnretainedValue()
            box.retiredProcessor = result.retiredProcessor
            box.secondRetiredProcessor = result.secondRetiredProcessor
            activeSystemSoundPreampGains = box.systemSoundPreampGains
            pushRetiredDSPConfigBox(rawPointer)
        }

        private func selectedProgrammeComparisonBranch() -> EQProgrammeComparisonSelection {
            EQProgrammeComparisonSelection(
                rawValue: UInt8(
                    programmeComparisonSelection.load(ordering: .acquiring)
                )
            ) ?? .equalized
        }

        private func publishProgrammeComparisonSnapshot(
            _ snapshot: EQProgrammeComparisonSnapshot
        ) {
            programmeComparisonActive.store(snapshot.isActive, ordering: .releasing)
            programmeComparisonReady.store(snapshot.isReady, ordering: .releasing)
            equalizedAttenuationMilliDB.store(
                Int64((snapshot.equalizedAttenuationDB * 1_000).rounded()),
                ordering: .relaxed
            )
            filtersOffAttenuationMilliDB.store(
                Int64((snapshot.filtersOffAttenuationDB * 1_000).rounded()),
                ordering: .relaxed
            )
        }

        private func incomingSystemSoundPreampGains() -> (left: Float, right: Float)? {
            guard activeDSPConfigPointer != 0,
                  let pointer = UnsafeRawPointer(bitPattern: activeDSPConfigPointer) else {
                return nil
            }
            return Unmanaged<PreparedDSPConfigBox>
                .fromOpaque(pointer)
                .takeUnretainedValue()
                .systemSoundPreampGains
        }

        private func prepareDSPAndOutputFade() {
            beginPendingDSPTransitionIfPossible()
            outputFade.setMuted(outputMutedForTransition.load(ordering: .acquiring))
        }

        private func pushRetiredDSPConfigBox(_ rawPointer: UInt) {
            guard rawPointer != 0,
                  let pointer = UnsafeRawPointer(bitPattern: rawPointer) else {
                return
            }
            let box = Unmanaged<PreparedDSPConfigBox>
                .fromOpaque(pointer)
                .takeUnretainedValue()
            var head = retiredDSPConfigHeadPointer.load(ordering: .acquiring)
            while true {
                box.nextRetiredPointer = head
                let result = retiredDSPConfigHeadPointer.compareExchange(
                    expected: head,
                    desired: rawPointer,
                    ordering: .acquiringAndReleasing
                )
                if result.exchanged {
                    return
                }
                head = result.original
            }
        }

        private func releaseDSPConfigBox(_ rawPointer: UInt) {
            guard rawPointer != 0,
                  let pointer = UnsafeRawPointer(bitPattern: rawPointer) else {
                return
            }
            Unmanaged<PreparedDSPConfigBox>.fromOpaque(pointer).release()
        }

        private func frameCount(_ buffers: UnsafeMutableAudioBufferListPointer) -> Int? {
            guard let buffer = buffers.first(where: { $0.mData != nil }),
                  validatedByteCount(for: buffer) != nil else {
                return buffers.allSatisfy { $0.mData == nil } ? 0 : nil
            }
            let channels = Int(buffer.mNumberChannels)
            let frames = Int(buffer.mDataByteSize) / (channels * MemoryLayout<Float>.stride)
            return frames <= maxCallbackFrames ? frames : nil
        }

        private func frameCount(
            _ buffers: UnsafeMutableAudioBufferListPointer,
            channelOffset: Int,
            channelCount: Int
        ) -> Int? {
            guard channelOffset >= 0,
                  channelCount > 0 else {
                return nil
            }

            let requestedChannels = channelOffset..<(channelOffset + channelCount)
            var currentChannelOffset = 0
            var coveredChannelCount = 0
            var minimumFrameCount = maxCallbackFrames

            for buffer in buffers {
                let channels = Int(buffer.mNumberChannels)
                guard channels > 0,
                      channels <= CoreAudioDeviceQuery.maxChannelCount else {
                    return nil
                }
                let bufferChannels = currentChannelOffset..<(currentChannelOffset + channels)
                let coveredChannels = bufferChannels.clamped(to: requestedChannels)
                if !coveredChannels.isEmpty {
                    guard let byteCount = validatedByteCount(for: buffer) else {
                        return buffer.mData == nil ? 0 : nil
                    }
                    coveredChannelCount += coveredChannels.count
                    minimumFrameCount = min(
                        minimumFrameCount,
                        byteCount / (channels * MemoryLayout<Float>.stride)
                    )
                }
                currentChannelOffset = bufferChannels.upperBound
            }

            guard coveredChannelCount == channelCount else {
                return nil
            }
            return minimumFrameCount
        }

        private func recordTimestampContinuity(
            inputTime: AudioTimeStamp,
            inputFrameCount: Int,
            outputTime: AudioTimeStamp,
            outputFrameCount: Int
        ) -> Bool {
            let inputJump = recordTimestampContinuity(
                time: inputTime,
                frameCount: inputFrameCount,
                state: &inputTimestampState,
                discontinuities: inputTimestampDiscontinuities
            )
            let outputJump = recordTimestampContinuity(
                time: outputTime,
                frameCount: outputFrameCount,
                state: &outputTimestampState,
                discontinuities: outputTimestampDiscontinuities
            )

            if let inputJump {
                lastInputTimestampJumpMilliFrames.store(
                    Self.milliFrames(inputJump.sampleTimeDeltaFrames),
                    ordering: .relaxed
                )
                lastInputHostIntervalErrorNanoseconds.store(
                    inputJump.hostIntervalErrorNanoseconds,
                    ordering: .relaxed
                )
            }
            if let outputJump {
                lastOutputTimestampJumpMilliFrames.store(
                    Self.milliFrames(outputJump.sampleTimeDeltaFrames),
                    ordering: .relaxed
                )
                lastOutputHostIntervalErrorNanoseconds.store(
                    outputJump.hostIntervalErrorNanoseconds,
                    ordering: .relaxed
                )
            }
            if inputJump != nil, outputJump != nil {
                outputDeclicker.markDiscontinuity()
                recordPairedTimestampJump(inputTime: inputTime, outputTime: outputTime)
                if inputJump?.precededByStableSlope == true,
                   outputJump?.precededByStableSlope == true {
                    qualifyingPairedTimestampDiscontinuities.wrappingAdd(
                        1,
                        ordering: .relaxed
                    )
                }
            }
            if inputJump != nil || outputJump != nil {
                recordTimestampProbe(
                    inputTime: inputTime,
                    inputFrameCount: inputFrameCount,
                    inputJump: inputJump,
                    outputTime: outputTime,
                    outputFrameCount: outputFrameCount,
                    outputJump: outputJump
                )
            }
            return inputJump == nil
                && outputJump == nil
                && inputTimestampState.stableSlopeObservations >= 8
                && outputTimestampState.stableSlopeObservations >= 8
        }

        private func recordTimestampContinuity(
            time: AudioTimeStamp,
            frameCount: Int,
            state: inout TimestampContinuityState,
            discontinuities: borrowing Atomic<UInt64>
        ) -> TimestampJump? {
            let hostIntervalError = hostIntervalErrorNanoseconds(
                time: time,
                state: state
            )
            let precededByStableSlope = state.stableSlopeObservations >= 8
            if time.mFlags.contains(.hostTimeValid) {
                state.previousHostTime = time.mHostTime
                state.previousFrameCount = frameCount
            } else {
                state.previousHostTime = nil
                state.previousFrameCount = 0
            }

            guard time.mFlags.contains(.sampleTimeValid),
                  time.mSampleTime.isFinite else {
                state.expectedSampleTime = nil
                state.stableSlopeObservations = 0
                return nil
            }
            let sampleTimeDelta = state.expectedSampleTime.map {
                time.mSampleTime - $0
            }
            state.expectedSampleTime = time.mSampleTime + Float64(frameCount)

            if let sampleTimeDelta, abs(sampleTimeDelta) >= 0.5 {
                state.stableSlopeObservations = 0
                discontinuities.wrappingAdd(1, ordering: .relaxed)
                return TimestampJump(
                    sampleTimeDeltaFrames: sampleTimeDelta,
                    hostIntervalErrorNanoseconds: hostIntervalError ?? 0,
                    precededByStableSlope: precededByStableSlope
                )
            }
            if timestampSlopeAgrees(
                time: time,
                frameCount: frameCount,
                sampleTimeDelta: sampleTimeDelta,
                hostIntervalErrorNanoseconds: hostIntervalError
            ) {
                state.stableSlopeObservations = min(
                    state.stableSlopeObservations + 1,
                    8
                )
            } else {
                state.stableSlopeObservations = 0
            }
            return nil
        }

        private func timestampSlopeAgrees(
            time: AudioTimeStamp,
            frameCount: Int,
            sampleTimeDelta: Double?,
            hostIntervalErrorNanoseconds: Int64?
        ) -> Bool {
            guard frameCount > 0,
                  time.mFlags.contains(.sampleTimeValid),
                  time.mFlags.contains(.hostTimeValid),
                  let sampleTimeDelta,
                  let hostIntervalErrorNanoseconds else {
                return false
            }
            return SystemTapAudioEngine.timestampSlopeAgrees(
                frameCount: frameCount,
                sampleRate: sampleRate,
                sampleTimeDeltaFrames: sampleTimeDelta,
                hostIntervalErrorNanoseconds: hostIntervalErrorNanoseconds,
                rateScalar: time.mRateScalar,
                rateScalarIsValid: time.mFlags.contains(.rateScalarValid)
            )
        }

        private func hostIntervalErrorNanoseconds(
            time: AudioTimeStamp,
            state: TimestampContinuityState
        ) -> Int64? {
            guard time.mFlags.contains(.hostTimeValid),
                  let previousHostTime = state.previousHostTime,
                  state.previousFrameCount > 0,
                  let actualInterval = Self.signedHostIntervalNanoseconds(
                      from: previousHostTime,
                      to: time.mHostTime
                  ) else {
                return nil
            }
            let expectedInterval = Self.clampedInt64(
                Double(state.previousFrameCount) * 1_000_000_000 / sampleRate
            )
            let subtraction = actualInterval.subtractingReportingOverflow(expectedInterval)
            if subtraction.overflow {
                return actualInterval < 0 ? .min : .max
            }
            return subtraction.partialValue
        }

        private func recordPairedTimestampJump(
            inputTime: AudioTimeStamp,
            outputTime: AudioTimeStamp
        ) {
            pairedTimestampDiscontinuities.wrappingAdd(1, ordering: .relaxed)
            let hostTime: UInt64?
            if outputTime.mFlags.contains(.hostTimeValid) {
                hostTime = outputTime.mHostTime
            } else if inputTime.mFlags.contains(.hostTimeValid) {
                hostTime = inputTime.mHostTime
            } else {
                hostTime = nil
            }
            guard let hostTime else {
                lastPairedTimestampJumpHostTime = nil
                return
            }
            defer {
                lastPairedTimestampJumpHostTime = hostTime
            }
            guard let previousHostTime = lastPairedTimestampJumpHostTime,
                  hostTime >= previousHostTime else {
                return
            }
            let interval = AudioConvertHostTimeToNanos(hostTime - previousHostTime)
            updateMinimum(minimumTimestampJumpIntervalNanoseconds, interval)
            updateMaximum(maximumTimestampJumpIntervalNanoseconds, interval)
            totalTimestampJumpIntervalNanoseconds.wrappingAdd(interval, ordering: .relaxed)
            timestampJumpIntervalObservations.wrappingAdd(1, ordering: .relaxed)
        }

        private func recordTimestampProbe(
            inputTime: AudioTimeStamp,
            inputFrameCount: Int,
            inputJump: TimestampJump?,
            outputTime: AudioTimeStamp,
            outputFrameCount: Int,
            outputJump: TimestampJump?
        ) {
            timestampProbeSequence &+= 1
            timestampProbeRecords[timestampProbeWriteIndex] = AudioTimestampProbeRecord(
                sequence: timestampProbeSequence,
                inputJumpDetected: inputJump != nil,
                outputJumpDetected: outputJump != nil,
                inputFrameCount: inputFrameCount,
                outputFrameCount: outputFrameCount,
                inputSampleTime: inputTime.mSampleTime,
                inputHostTime: inputTime.mHostTime,
                inputRateScalar: inputTime.mRateScalar,
                inputFlags: inputTime.mFlags.rawValue,
                outputSampleTime: outputTime.mSampleTime,
                outputHostTime: outputTime.mHostTime,
                outputRateScalar: outputTime.mRateScalar,
                outputFlags: outputTime.mFlags.rawValue,
                inputSampleTimeDeltaFrames: inputJump?.sampleTimeDeltaFrames ?? 0,
                outputSampleTimeDeltaFrames: outputJump?.sampleTimeDeltaFrames ?? 0,
                inputHostIntervalErrorNanoseconds:
                    inputJump?.hostIntervalErrorNanoseconds ?? 0,
                outputHostIntervalErrorNanoseconds:
                    outputJump?.hostIntervalErrorNanoseconds ?? 0
            )
            timestampProbeWriteIndex = (timestampProbeWriteIndex + 1)
                % timestampProbeRecords.count
            timestampProbeRecordCount = min(
                timestampProbeRecordCount + 1,
                timestampProbeRecords.count
            )
        }

        private static func milliFrames(_ frames: Double) -> Int64 {
            clampedInt64(frames * 1_000)
        }

        private static func clampedInt64(_ value: Double) -> Int64 {
            guard value.isFinite else {
                return 0
            }
            if value >= Double(Int64.max) {
                return .max
            }
            if value <= Double(Int64.min) {
                return .min
            }
            return Int64(value.rounded())
        }

        private static func signedHostIntervalNanoseconds(
            from start: UInt64,
            to end: UInt64
        ) -> Int64? {
            let magnitude = end >= start
                ? AudioConvertHostTimeToNanos(end - start)
                : AudioConvertHostTimeToNanos(start - end)
            guard magnitude <= UInt64(Int64.max) else {
                return nil
            }
            return end >= start ? Int64(magnitude) : -Int64(magnitude)
        }

        private func validatedByteCount(for buffer: AudioBuffer) -> Int? {
            guard buffer.mData != nil else {
                return nil
            }
            let channels = Int(buffer.mNumberChannels)
            guard channels > 0,
                  channels <= CoreAudioDeviceQuery.maxChannelCount else {
                return nil
            }
            let bytesPerFrame = channels * MemoryLayout<Float>.stride
            let byteCount = Int(buffer.mDataByteSize)
            guard byteCount >= 0,
                  byteCount % bytesPerFrame == 0,
                  byteCount / bytesPerFrame <= maxCallbackFrames else {
                return nil
            }
            return byteCount
        }

        private func clear(_ buffers: UnsafeMutableAudioBufferListPointer) {
            for buffer in buffers {
                guard let data = buffer.mData,
                      let byteCount = validatedByteCount(for: buffer) else {
                    continue
                }
                data.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
            }
        }

        private func updateMax(_ counter: borrowing Atomic<Int>, _ value: Int) {
            var current = counter.load(ordering: .relaxed)
            while value > current {
                let result = counter.compareExchange(
                    expected: current,
                    desired: value,
                    ordering: .relaxed
                )
                if result.exchanged {
                    return
                }
                current = result.original
            }
        }

        private func recordCallbackLatency(
            inputTime: AudioTimeStamp,
            callbackHostTime: UInt64,
            outputTime: AudioTimeStamp
        ) {
            guard let latency = SystemTapAudioEngine.tapToOutputLatencyNanoseconds(
                inputTime: inputTime,
                outputTime: outputTime
            ) else {
                return
            }
            updateMinimum(minTapToOutputLatencyNanoseconds, latency)
            updateMaximum(maxTapToOutputLatencyNanoseconds, latency)
            totalTapToOutputLatencyNanoseconds.wrappingAdd(latency, ordering: .relaxed)
            tapToOutputLatencyObservations.wrappingAdd(1, ordering: .relaxed)

            guard let timing = SystemTapAudioEngine.callbackTimingNanoseconds(
                inputTime: inputTime,
                callbackHostTime: callbackHostTime,
                outputTime: outputTime
            ) else {
                return
            }
            updateMinimum(minInputAgeNanoseconds, timing.inputAge)
            updateMaximum(maxInputAgeNanoseconds, timing.inputAge)
            totalInputAgeNanoseconds.wrappingAdd(timing.inputAge, ordering: .relaxed)
            updateMinimum(minOutputLeadNanoseconds, timing.outputLead)
            updateMaximum(maxOutputLeadNanoseconds, timing.outputLead)
            totalOutputLeadNanoseconds.wrappingAdd(timing.outputLead, ordering: .relaxed)
            callbackTimingObservations.wrappingAdd(1, ordering: .relaxed)
        }

        private func updateMinimum(
            _ counter: borrowing Atomic<Int>,
            _ value: Int
        ) {
            var current = counter.load(ordering: .relaxed)
            while value < current {
                let result = counter.compareExchange(
                    expected: current,
                    desired: value,
                    ordering: .relaxed
                )
                if result.exchanged {
                    return
                }
                current = result.original
            }
        }

        private func updateMinimum(
            _ counter: borrowing Atomic<UInt64>,
            _ value: UInt64
        ) {
            var current = counter.load(ordering: .relaxed)
            while value < current {
                let result = counter.compareExchange(
                    expected: current,
                    desired: value,
                    ordering: .relaxed
                )
                if result.exchanged {
                    return
                }
                current = result.original
            }
        }

        private func updateMaximum(
            _ counter: borrowing Atomic<UInt64>,
            _ value: UInt64
        ) {
            var current = counter.load(ordering: .relaxed)
            while value > current {
                let result = counter.compareExchange(
                    expected: current,
                    desired: value,
                    ordering: .relaxed
                )
                if result.exchanged {
                    return
                }
                current = result.original
            }
        }

        private func enter(_ gate: borrowing Atomic<Bool>) -> Bool {
            gate.compareExchange(
                expected: false,
                desired: true,
                ordering: .acquiringAndReleasing
            ).exchanged
        }
    }

    private let control = Mutex(ControlState())
    private let topologyOperation = Mutex(())
    private let activeBackend = Mutex(ActiveBackend.combinedAggregate)
    private let promotedHeadsetRoute = Mutex<PromotedHeadsetRoute?>(nil)
    private let deferredColdStartupRoute = Mutex<DeferredColdStartupRoute?>(nil)
    private let diagnosticTrace = Mutex<AudioEngineDiagnosticTrace?>(nil)
    private let cleanupLedger = CoreAudioResourceCleanupLedger()
    private let separateClockBackend: SeparateClockAudioBackend

    public var state: AudioEngineState {
        switch activeBackend.withLock({ $0 }) {
        case .combinedAggregate:
            control.withLock { $0.state }
        case .separateClock:
            separateClockBackend.state
        }
    }

    public var status: AudioEngineStatus {
        switch activeBackend.withLock({ $0 }) {
        case .combinedAggregate:
            control.withLock { $0.status }
        case .separateClock:
            separateClockBackend.status
        }
    }

    public var isUsingTransitionalHeadsetBackend: Bool {
        guard activeBackend.withLock({ $0 }) == .separateClock,
              case .running(let output) = separateClockBackend.state else {
            return false
        }
        return Self.shouldUseSeparateClockBackend(for: output)
    }

    public var isDeferringColdStartupAggregate: Bool {
        guard activeBackend.withLock({ $0 }) == .separateClock,
              case .running(let output) = separateClockBackend.state else {
            return false
        }
        return deferredColdStartupRoute.withLock { route in
            route == Self.deferredColdStartupRoute(for: output)
        }
    }

    public var isUsingPromotedHeadsetAggregate: Bool {
        guard activeBackend.withLock({ $0 }) == .combinedAggregate,
              let output = control.withLock({ $0.activeOutput }) else {
            return false
        }
        return promotedHeadsetRoute.withLock { route in
            route == Self.promotedHeadsetRoute(for: output)
        }
    }

    public init(restorationStoreURL: URL? = nil) {
        let restorationStoreURL = restorationStoreURL
            ?? PersistedAudioDeviceRestorationStore.defaultURL()
        self.separateClockBackend = SeparateClockAudioBackend(
            restorationStoreURL: restorationStoreURL
        )
    }

    @_spi(GlassEQDiagnostics)
    public func setDiagnosticTrace(_ trace: AudioEngineDiagnosticTrace?) {
        diagnosticTrace.withLock { $0 = trace }
        separateClockBackend.setDiagnosticTrace(trace)
    }

    @_spi(GlassEQDiagnostics)
    public func startDiagnosticCompatibilityPath(
        output: AudioOutputDevice,
        profile: EQProfile
    ) throws {
        try topologyOperation.withLock { _ in
            deferredColdStartupRoute.withLock { $0 = nil }
            promotedHeadsetRoute.withLock { $0 = nil }
            traceDiagnostic {
                "diagnostic compatibility start output=\(output.id) buffer=\(output.bufferFrameSize)"
            }
            try startSeparateClockBackendForColdStartup(output: output, profile: profile)
        }
    }

    @_spi(GlassEQDiagnostics)
    public func quiesceDiagnosticCompatibilityOutput() throws {
        try topologyOperation.withLock { _ in
            guard activeBackend.withLock({ $0 }) == .separateClock,
                  separateClockBackend.activeOutputAndProfile() != nil else {
                throw AudioEngineInternalError(
                    message: "The diagnostic compatibility output is not running."
                )
            }
            try separateClockBackend.quiesceOutputForCombinedHandoff()
        }
    }

    @_spi(GlassEQDiagnostics)
    public func restoreDiagnosticCompatibilityOutput(
        output: AudioOutputDevice,
        profile: EQProfile
    ) throws {
        try topologyOperation.withLock { _ in
            traceDiagnostic { "diagnostic compatibility restore begin output=\(output.id)" }
            try restoreSeparateClockBackendOrStop(
                afterRejectedPromotion: (output, profile),
                preserveOutputBuffer: true
            )
            traceDiagnostic { "diagnostic compatibility restore end output=\(output.id)" }
        }
    }

    @_spi(GlassEQDiagnostics)
    public func startDiagnosticCombinedPath(
        output: AudioOutputDevice,
        profile: EQProfile,
        targetFrameSize: UInt32
    ) throws {
        try topologyOperation.withLock { _ in
            deferredColdStartupRoute.withLock { $0 = nil }
            promotedHeadsetRoute.withLock { $0 = nil }
            let isSeparateClockHandoff = activeBackend.withLock { $0 == .separateClock }
            traceDiagnostic {
                "diagnostic combined start output=\(output.id) physicalBuffer=\(output.bufferFrameSize) targetAggregateBuffer=\(targetFrameSize)"
            }
            try startCombinedAggregateAttempt(
                output: output,
                profile: profile,
                targetFrameSize: targetFrameSize,
                isSeparateClockHandoff: isSeparateClockHandoff,
                usePhysicalFirstOrdering: false
            )
        }
    }

    private func traceDiagnostic(
        hostTimeNanoseconds: UInt64? = nil,
        _ message: () -> String
    ) {
        guard let trace = diagnosticTrace.withLock({ $0 }) else {
            return
        }
        trace(hostTimeNanoseconds, message())
    }

    deinit {
        stop()
    }

    public func aggregateRouteFingerprint(
        for output: AudioOutputDevice
    ) throws -> AggregateAudioRouteFingerprint? {
        guard activeBackend.withLock({ $0 }) == .combinedAggregate else {
            return nil
        }
        if Self.shouldUseSeparateClockBackend(for: output) {
            let isActivePromotedRoute = control.withLock { state in
                    state.activeOutput?.uid == output.uid
                        && state.activeOutput?.nominalSampleRate == output.nominalSampleRate
                }
            guard isActivePromotedRoute else {
                return nil
            }
        }
        let freshOutput = try CoreAudioDeviceQuery.outputDevice(id: output.id)
        let preferredChannels = try? CoreAudioDeviceQuery.preferredStereoChannels(
            objectID: freshOutput.id
        )
        let channelPair = Self.playbackStereoPair(
            preferredChannels: preferredChannels,
            outputChannelCount: freshOutput.outputChannelCount
        )
        let streamChannelCounts = try CoreAudioDeviceQuery.streamChannelCounts(
            objectID: freshOutput.id,
            scope: kAudioDevicePropertyScopeOutput
        )
        guard let streamIndex = Self.tapOutputStreamIndex(
            streamChannelCounts: streamChannelCounts,
            playbackChannels: channelPair
        ) else {
            throw AudioEngineInternalError(
                message: "The selected stereo channels must belong to one mono or stereo output stream."
            )
        }
        return AggregateAudioRouteFingerprint(
            outputDeviceUID: freshOutput.uid,
            nativeOutputStreamIndex: streamIndex,
            nominalSampleRate: freshOutput.nominalSampleRate
        )
    }

    public func start(output: AudioOutputDevice, profile: EQProfile) throws {
        try topologyOperation.withLock { _ in
            try startSerialized(output: output, profile: profile)
        }
    }

    private func startSerialized(output: AudioOutputDevice, profile: EQProfile) throws {
        try requireCompletedCoreAudioCleanup(operation: "start a new audio route")
        let shouldUseSeparateClock = Self.shouldUseSeparateClockBackend(for: output)
            && !promotedHeadsetRoute.withLock { route in
                route == Self.promotedHeadsetRoute(for: output)
            }
        if shouldUseSeparateClock {
            deferredColdStartupRoute.withLock { $0 = nil }
            try startSeparateClockBackend(output: output, profile: profile)
            return
        }

        if !Self.shouldUseSeparateClockBackend(for: output) {
            promotedHeadsetRoute.withLock { $0 = nil }
        }

        let shouldConsiderColdStartupDeferral = Self.shouldConsiderColdStartupDeferral(
            activeBackendIsSeparate: activeBackend.withLock { $0 == .separateClock },
            combinedState: control.withLock { $0.state }
        )
        if shouldConsiderColdStartupDeferral,
           (try? hasActiveExternalOutputProcess(on: output)) != false {
            do {
                deferredColdStartupRoute.withLock { $0 = nil }
                try startCombinedAggregate(
                    output: output,
                    profile: profile,
                    usePhysicalFirstOrdering: true
                )
                return
            } catch {
                traceDiagnostic {
                    "physical-first combined startup failed; falling back to compatibility error=\(error)"
                }
                try startSeparateClockBackendForColdStartup(
                    output: output,
                    profile: profile
                )
                deferredColdStartupRoute.withLock {
                    $0 = Self.deferredColdStartupRoute(for: output)
                }
                return
            }
        }

        deferredColdStartupRoute.withLock { $0 = nil }
        try startCombinedAggregate(output: output, profile: profile)
    }

    private func hasActiveExternalOutputProcess(
        on output: AudioOutputDevice
    ) throws -> Bool {
        try CoreAudioDeviceQuery.hasActiveOutputProcess(
            using: output.id,
            excluding: [try currentAudioProcessObjectID()]
        )
    }

    private func startSeparateClockBackend(
        output: AudioOutputDevice,
        profile: EQProfile
    ) throws {
        let combinedIsRunning = activeBackend.withLock { $0 } == .combinedAggregate
            && control.withLock { state in
                if case .running = state.state {
                    return true
                }
                return false
            }
        guard combinedIsRunning else {
            stopCombinedResourcesSerialized()
            try requireCompletedCoreAudioCleanup(operation: "start compatibility audio")
            activeBackend.withLock { $0 = .separateClock }
            try separateClockBackend.start(output: output, profile: profile)
            return
        }

        try separateClockBackend.prepareOutputForHandoff(
            output: output,
            profile: profile
        )
        stopCombinedResourcesSerialized()
        do {
            try requireCompletedCoreAudioCleanup(operation: "handoff to compatibility audio")
        } catch {
            separateClockBackend.stop()
            throw error
        }
        activeBackend.withLock { $0 = .separateClock }
        _ = try separateClockBackend.activatePreparedOutputHandoff()
    }

    private func startSeparateClockBackendForColdStartup(
        output: AudioOutputDevice,
        profile: EQProfile
    ) throws {
        stopCombinedResourcesSerialized()
        try requireCompletedCoreAudioCleanup(operation: "stage compatibility audio")
        activeBackend.withLock { $0 = .separateClock }
        try separateClockBackend.startForCombinedStartupStaging(
            output: output,
            profile: profile
        )
    }

    private func startCombinedAggregate(
        output: AudioOutputDevice,
        profile: EQProfile,
        preserveStagingOutputBuffer: Bool = false,
        usePhysicalFirstOrdering: Bool = false
    ) throws {
        let isSeparateClockHandoff = activeBackend.withLock { $0 } == .separateClock
        let requestedFrameSize = control.withLock { $0.preferredAggregateBufferFrameSize }
        let attemptFrameSizes = Self.startupAttemptFrameSizes(
            requestedFrameSize: requestedFrameSize
        )
        try Self.runCombinedStartupAttempts(
            frameSizes: attemptFrameSizes,
            isSeparateClockHandoff: isSeparateClockHandoff,
            attempt: { frameSize in
                try startCombinedAggregateAttempt(
                    output: output,
                    profile: profile,
                    targetFrameSize: frameSize,
                    isSeparateClockHandoff: isSeparateClockHandoff,
                    usePhysicalFirstOrdering: usePhysicalFirstOrdering
                )
            },
            restoreSeparateClockOutput: {
                try restoreSeparateClockBackendOrStop(
                    afterRejectedPromotion: (output, profile),
                    preserveOutputBuffer: preserveStagingOutputBuffer
                )
            },
            waitBeforeRetry: {
                Thread.sleep(forTimeInterval: 0.05)
            }
        )
    }

    #if DEBUG
    func startCombinedAggregateHandoffForTesting(
        output: AudioOutputDevice,
        profile: EQProfile,
        preserveStagingOutputBuffer: Bool,
        boundary: CombinedStartupTestBoundary
    ) throws {
        let previousBackend = activeBackend.withLock { backend in
            let previousBackend = backend
            backend = .separateClock
            return previousBackend
        }
        defer {
            activeBackend.withLock { $0 = previousBackend }
        }
        let requestedFrameSize = control.withLock { $0.preferredAggregateBufferFrameSize }
        try Self.runCombinedStartupAttempts(
            frameSizes: Self.startupAttemptFrameSizes(
                requestedFrameSize: requestedFrameSize
            ),
            isSeparateClockHandoff: true,
            attempt: boundary.attempt,
            restoreSeparateClockOutput: {
                try restoreSeparateClockBackendOrStopForTesting(
                    afterRejectedPromotion: (output, profile),
                    preserveOutputBuffer: preserveStagingOutputBuffer,
                    boundary: boundary
                )
            },
            waitBeforeRetry: boundary.waitBeforeRetry
        )
    }
    #endif

    private func startCombinedAggregateAttempt(
        output: AudioOutputDevice,
        profile: EQProfile,
        targetFrameSize: UInt32,
        isSeparateClockHandoff: Bool,
        usePhysicalFirstOrdering: Bool
    ) throws {
        traceDiagnostic {
            "combined attempt begin output=\(output.id) physicalBuffer=\(output.bufferFrameSize) targetAggregateBuffer=\(targetFrameSize) handoff=\(isSeparateClockHandoff) physicalFirst=\(usePhysicalFirstOrdering)"
        }
        control.withLock { state in
            state.status = .starting
        }

        var taps: CombinedTapSet?
        var preparedAggregate: PreparedCombinedAggregate?

        do {
            let route = try prepareCombinedRoute(output: output)
            traceDiagnostic {
                "combined route prepared output=\(route.output.id) physicalBuffer=\(route.output.bufferFrameSize) streamIndex=\(route.outputStreamIndex)"
            }
            var detachedAggregate: DetachedCombinedAggregate?
            var staleTaps: CombinedTapSet?

            control.withLock { state in
                detachedAggregate = detachCombinedAggregateLocked(&state)
                state.state = .stopped
                state.lastTimestampProbeRecords.removeAll(keepingCapacity: true)

                if state.tapOutputUID == route.output.uid,
                   state.tapOutputStreamIndex == route.outputStreamIndex,
                   state.tapID != kAudioObjectUnknown,
                   state.systemSoundTapID != kAudioObjectUnknown {
                    taps = CombinedTapSet(
                        main: state.tapID,
                        systemSounds: state.systemSoundTapID,
                        outputUID: route.output.uid,
                        outputStreamIndex: route.outputStreamIndex
                    )
                } else {
                    staleTaps = detachTapSetLocked(&state)
                }
            }

            if let detachedAggregate {
                let records = disposeDetachedCombinedAggregate(detachedAggregate)
                control.withLock { state in
                    state.lastTimestampProbeRecords = records
                }
            }
            if let staleTaps {
                destroyTapSet(staleTaps)
            }
            try requireCompletedCoreAudioCleanup(operation: "replace the combined audio route")

            if taps == nil {
                let createdTaps = try createSystemTaps(
                    output: route.output,
                    streamIndex: route.outputStreamIndex
                )
                taps = CombinedTapSet(
                    main: createdTaps.main,
                    systemSounds: createdTaps.systemSounds,
                    outputUID: route.output.uid,
                    outputStreamIndex: route.outputStreamIndex
                )
            }
            guard let taps else {
                throw AudioEngineInternalError(message: "Core Audio did not create the process taps.")
            }

            let prepared = if usePhysicalFirstOrdering {
                try preparePhysicalFirstCombinedAggregate(
                    taps: taps,
                    route: route,
                    profile: profile,
                    targetFrameSize: targetFrameSize
                )
            } else {
                try prepareCombinedAggregate(
                    taps: taps,
                    route: route,
                    profile: profile,
                    targetFrameSize: targetFrameSize
                )
            }
            preparedAggregate = prepared

            if !prepared.ioStarted {
                if isSeparateClockHandoff {
                    traceDiagnostic { "combined handoff quiesce requested" }
                    try separateClockBackend.quiesceOutputForCombinedHandoff()
                }
                traceDiagnostic {
                    "AudioDeviceStart(combined aggregate) begin device=\(prepared.deviceID) buffer=\(prepared.output.bufferFrameSize)"
                }
                let startStatus = AudioDeviceStart(prepared.deviceID, prepared.ioProcID)
                traceDiagnostic {
                    "AudioDeviceStart(combined aggregate) return status=\(startStatus) device=\(prepared.deviceID)"
                }
                try checkOSStatus(
                    startStatus,
                    operation: "AudioDeviceStart(combined aggregate)"
                )
            }
            let qualificationCallbacks = Self.startupQualificationCallbacks
            let qualificationTimeout = Self.startupQualificationTimeout(
                frameCount: Int(prepared.output.bufferFrameSize),
                sampleRate: prepared.output.nominalSampleRate,
                minimumConsecutiveCallbacks: qualificationCallbacks
            )
            let qualification = prepared.runtime.waitForQualifiedStartup(
                minimumConsecutiveCallbacks: qualificationCallbacks,
                timeout: qualificationTimeout
            )
            if let firstCallbackHostTime = prepared.runtime.firstRenderCallbackHostTime() {
                traceDiagnostic(hostTimeNanoseconds: firstCallbackHostTime) {
                    "combined first callback device=\(prepared.deviceID)"
                }
            }
            traceDiagnostic {
                "combined startup qualification validStreak=\(qualification.validCallbackStreak) observed=\(qualification.observedCallbacks) rejected=\(qualification.rejectedCallbacks)"
            }
            guard qualification.validCallbackStreak >= qualificationCallbacks else {
                throw AggregateStartupQualificationError(
                    expectedFrameCount: Int(prepared.output.bufferFrameSize),
                    snapshot: qualification
                )
            }
            prepared.runtime.activate()
            let probationCallbacks = qualificationCallbacks
                + Self.startupProbationCallbacks
            let probation = prepared.runtime.waitForQualifiedStartup(
                minimumConsecutiveCallbacks: probationCallbacks,
                timeout: Self.startupQualificationTimeout(
                    frameCount: Int(prepared.output.bufferFrameSize),
                    sampleRate: prepared.output.nominalSampleRate,
                    minimumConsecutiveCallbacks: Self.startupProbationCallbacks
                )
            )
            traceDiagnostic {
                "combined startup probation validStreak=\(probation.validCallbackStreak) observed=\(probation.observedCallbacks) rejected=\(probation.rejectedCallbacks)"
            }
            guard probation.validCallbackStreak >= probationCallbacks else {
                throw AggregateStartupQualificationError(
                    expectedFrameCount: Int(prepared.output.bufferFrameSize),
                    snapshot: probation
                )
            }

            control.withLock { state in
                state.tapID = prepared.taps.main
                state.systemSoundTapID = prepared.taps.systemSounds
                state.tapOutputUID = prepared.taps.outputUID
                state.tapOutputStreamIndex = prepared.taps.outputStreamIndex
                state.aggregateDeviceID = prepared.deviceID
                state.ioProcID = prepared.ioProcID
                state.runtime = prepared.runtime
                state.activeOutput = prepared.output
                state.activeProfile = prepared.profile
                state.state = .running(output: prepared.output)
                state.status = .running(output: prepared.output)
            }
            preparedAggregate = nil
            activeBackend.withLock { $0 = .combinedAggregate }
            if isSeparateClockHandoff {
                separateClockBackend.completeCombinedHandoff()
            }
            traceDiagnostic {
                "combined attempt running device=\(prepared.deviceID) buffer=\(prepared.output.bufferFrameSize)"
            }
        } catch {
            traceDiagnostic { "combined attempt failed error=\(error)" }
            let failure = audioEngineFailure(from: error)
            var failedStateAggregate: DetachedCombinedAggregate?
            var installedTaps: CombinedTapSet?
            control.withLock { state in
                failedStateAggregate = detachCombinedAggregateLocked(&state)
                installedTaps = detachTapSetLocked(&state)
                state.activeProfile = nil
                state.state = .failed(failure.description)
                if failure.category == .systemAudioCapturePermission {
                    state.status = .permissionRequired(failure)
                } else {
                    state.status = .failed(failure)
                }
            }

            let installedTapsMatch = installedTaps?.main == taps?.main
                && installedTaps?.systemSounds == taps?.systemSounds
            if let preparedAggregate {
                _ = disposeDetachedCombinedAggregate(
                    DetachedCombinedAggregate(
                        deviceID: preparedAggregate.deviceID,
                        ioProcID: preparedAggregate.ioProcID,
                        runtime: preparedAggregate.runtime
                    )
                )
            }
            let failedStateMatchesPrepared = failedStateAggregate?.deviceID
                == preparedAggregate?.deviceID
            if let failedStateAggregate, !failedStateMatchesPrepared {
                let records = disposeDetachedCombinedAggregate(failedStateAggregate)
                control.withLock { state in
                    state.lastTimestampProbeRecords = records
                }
            }
            if let installedTaps {
                destroyTapSet(installedTaps)
            }
            if let taps, !installedTapsMatch {
                destroyTapSet(taps)
            }
            throw error
        }
    }

    private func prepareCombinedRoute(output: AudioOutputDevice) throws -> CombinedRoutePreparation {
        let freshOutput = try CoreAudioDeviceQuery.outputDevice(id: output.id)
        _ = try Self.supportedRuntimeChannelCount(for: freshOutput)
        try Self.validatePlaybackCallbackCapacity(for: freshOutput)
        let preferredChannels = try? CoreAudioDeviceQuery.preferredStereoChannels(
            objectID: freshOutput.id
        )
        let channelPair = Self.playbackStereoPair(
            preferredChannels: preferredChannels,
            outputChannelCount: freshOutput.outputChannelCount
        )
        let outputStreamChannelCounts = try CoreAudioDeviceQuery.streamChannelCounts(
            objectID: freshOutput.id,
            scope: kAudioDevicePropertyScopeOutput
        )
        guard let outputStreamIndex = Self.tapOutputStreamIndex(
            streamChannelCounts: outputStreamChannelCounts,
            playbackChannels: channelPair
        ) else {
            throw AudioEngineInternalError(
                message: "The selected stereo channels must belong to one mono or stereo output stream."
            )
        }
        return CombinedRoutePreparation(
            output: freshOutput,
            outputStreamIndex: outputStreamIndex,
            outputStreamChannelCounts: outputStreamChannelCounts,
            channelPair: channelPair
        )
    }

    private func prepareCombinedAggregate(
        taps: CombinedTapSet,
        route: CombinedRoutePreparation,
        profile: EQProfile,
        targetFrameSize: UInt32
    ) throws -> PreparedCombinedAggregate {
        var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        var ioProcID: AudioDeviceIOProcID?
        var runtime: AudioRuntime?

        do {
            traceDiagnostic {
                "prepare combined aggregate begin physicalDevice=\(route.output.id) targetBuffer=\(targetFrameSize)"
            }
            let aggregateCreation = try createCombinedAggregateDevice(
                tapID: taps.main,
                systemSoundTapID: taps.systemSounds,
                output: route.output
            )
            aggregateDeviceID = aggregateCreation.deviceID
            try waitUntilAggregateIsAlive(aggregateDeviceID)
            traceDiagnostic {
                "verify aggregate composition begin device=\(aggregateDeviceID)"
            }
            let tapUIDOrder = try verifyAggregateComposition(
                aggregateDeviceID,
                output: route.output,
                expectedTapDriftCompensation: [
                    aggregateCreation.mainTapUID: true,
                    aggregateCreation.systemSoundTapUID: true
                ]
            )
            traceDiagnostic {
                "verify aggregate composition end device=\(aggregateDeviceID)"
            }

            let aggregate = try tuneAggregateBufferFrameSize(
                deviceID: aggregateDeviceID,
                targetFrameSize: targetFrameSize
            )
            traceDiagnostic {
                "aggregate buffer ready device=\(aggregateDeviceID) requested=\(targetFrameSize) actual=\(aggregate.bufferFrameSize)"
            }
            try Self.validatePlaybackCallbackCapacity(for: aggregate)
            let mainTapChannelCount = try tapChannelCount(taps.main)
            let systemSoundTapChannelCount = try tapChannelCount(taps.systemSounds)
            guard mainTapChannelCount == route.outputStreamChannelCounts[route.outputStreamIndex],
                  systemSoundTapChannelCount == mainTapChannelCount else {
                throw AudioEngineInternalError(
                    message: "The process-tap formats do not match the selected output stream."
                )
            }
            let physicalInputChannelCount = try CoreAudioDeviceQuery.getChannelCount(
                objectID: route.output.id,
                scope: kAudioDevicePropertyScopeInput
            )
            let aggregateInputChannelCount = try CoreAudioDeviceQuery.getChannelCount(
                objectID: aggregateDeviceID,
                scope: kAudioDevicePropertyScopeInput
            )
            guard let mainTapIndex = tapUIDOrder.firstIndex(of: aggregateCreation.mainTapUID),
                  let systemSoundTapIndex = tapUIDOrder.firstIndex(
                      of: aggregateCreation.systemSoundTapUID
                  ),
                  let tapInputChannelOffsets = Self.tapInputChannelOffsets(
                      physicalInputChannelCount: physicalInputChannelCount,
                      aggregateInputChannelCount: aggregateInputChannelCount,
                      mainTapChannelCount: mainTapChannelCount,
                      systemSoundTapChannelCount: systemSoundTapChannelCount,
                      mainTapIndex: mainTapIndex,
                      systemSoundTapIndex: systemSoundTapIndex
                  ) else {
                throw AudioEngineInternalError(
                    message: "The aggregate input layout does not match its physical output and process taps."
                )
            }

            let renderConfiguration = try EQRenderConfiguration.prepare(
                profile: profile,
                sampleRate: aggregate.nominalSampleRate,
                channelCount: mainTapChannelCount,
                maximumUsableFrequency: EQRouteFrequencyPolicy.maximumUsableFrequency(
                    sampleRate: aggregate.nominalSampleRate
                )
            )
            let preparedRuntime = AudioRuntime(
                renderConfiguration: renderConfiguration,
                inputChannelOffset: tapInputChannelOffsets.main,
                systemSoundInputChannelOffset: tapInputChannelOffsets.systemSounds,
                expectedCallbackFrames: Int(aggregate.bufferFrameSize),
                maxCallbackFrames: Self.maximumSupportedCallbackFrames
            )
            runtime = preparedRuntime
            preparedRuntime.setPlaybackChannelPair(
                left: route.channelPair.left,
                right: route.channelPair.right
            )

            guard let preparedIOProcID = try createCombinedIOProc(
                deviceID: aggregateDeviceID,
                runtime: preparedRuntime
            ) else {
                throw CoreAudioError(
                    operation: "AudioDeviceCreateIOProcIDWithBlock(combined aggregate) returned nil",
                    status: kAudioHardwareUnspecifiedError
                )
            }
            ioProcID = preparedIOProcID
            traceDiagnostic {
                "set aggregate IOProc stream usage begin device=\(aggregateDeviceID)"
            }
            try configureInputStreamUsage(
                deviceID: aggregateDeviceID,
                ioProcID: preparedIOProcID,
                tapInputChannelOffset: min(
                    tapInputChannelOffsets.main,
                    tapInputChannelOffsets.systemSounds
                ),
                tapChannelCount: mainTapChannelCount + systemSoundTapChannelCount
            )
            traceDiagnostic {
                "set aggregate IOProc stream usage end device=\(aggregateDeviceID)"
            }

            var activeOutput = route.output
            activeOutput.bufferFrameSize = aggregate.bufferFrameSize
            return PreparedCombinedAggregate(
                taps: taps,
                deviceID: aggregateDeviceID,
                ioProcID: preparedIOProcID,
                runtime: preparedRuntime,
                output: activeOutput,
                profile: profile,
                ioStarted: false
            )
        } catch {
            _ = disposeDetachedCombinedAggregate(
                DetachedCombinedAggregate(
                    deviceID: aggregateDeviceID,
                    ioProcID: ioProcID,
                    runtime: runtime
                ),
                fadeOut: false
            )
            throw error
        }
    }

    private func preparePhysicalFirstCombinedAggregate(
        taps: CombinedTapSet,
        route: CombinedRoutePreparation,
        profile: EQProfile,
        targetFrameSize: UInt32
    ) throws -> PreparedCombinedAggregate {
        var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        var ioProcID: AudioDeviceIOProcID?
        var runtime: AudioRuntime?

        do {
            traceDiagnostic {
                "prepare physical-first aggregate begin physicalDevice=\(route.output.id) incumbentBuffer=\(route.output.bufferFrameSize) targetBuffer=\(targetFrameSize)"
            }
            aggregateDeviceID = try createPhysicalOnlyAggregateDevice(output: route.output)
            try waitUntilAggregateIsAlive(aggregateDeviceID)
            let initialAggregate = try CoreAudioDeviceQuery.outputDevice(id: aggregateDeviceID)
            traceDiagnostic {
                "physical-first aggregate alive device=\(aggregateDeviceID) buffer=\(initialAggregate.bufferFrameSize)"
            }
            try Self.validatePlaybackCallbackCapacity(for: initialAggregate)

            let mainTapChannelCount = try tapChannelCount(taps.main)
            let systemSoundTapChannelCount = try tapChannelCount(taps.systemSounds)
            guard mainTapChannelCount == route.outputStreamChannelCounts[route.outputStreamIndex],
                  systemSoundTapChannelCount == mainTapChannelCount else {
                throw AudioEngineInternalError(
                    message: "The process-tap formats do not match the selected output stream."
                )
            }
            let physicalInputChannelCount = try CoreAudioDeviceQuery.getChannelCount(
                objectID: route.output.id,
                scope: kAudioDevicePropertyScopeInput
            )
            let expectedAggregateInputChannelCount = physicalInputChannelCount
                + mainTapChannelCount
                + systemSoundTapChannelCount
            guard let expectedTapInputChannelOffsets = Self.tapInputChannelOffsets(
                physicalInputChannelCount: physicalInputChannelCount,
                aggregateInputChannelCount: expectedAggregateInputChannelCount,
                mainTapChannelCount: mainTapChannelCount,
                systemSoundTapChannelCount: systemSoundTapChannelCount
            ) else {
                throw AudioEngineInternalError(
                    message: "The anticipated physical-first aggregate input layout is invalid."
                )
            }

            let renderConfiguration = try EQRenderConfiguration.prepare(
                profile: profile,
                sampleRate: initialAggregate.nominalSampleRate,
                channelCount: mainTapChannelCount,
                maximumUsableFrequency: EQRouteFrequencyPolicy.maximumUsableFrequency(
                    sampleRate: initialAggregate.nominalSampleRate
                )
            )
            let preparedRuntime = AudioRuntime(
                renderConfiguration: renderConfiguration,
                inputChannelOffset: expectedTapInputChannelOffsets.main,
                systemSoundInputChannelOffset: expectedTapInputChannelOffsets.systemSounds,
                expectedCallbackFrames: Int(targetFrameSize),
                maxCallbackFrames: Self.maximumSupportedCallbackFrames
            )
            runtime = preparedRuntime
            preparedRuntime.setPlaybackChannelPair(
                left: route.channelPair.left,
                right: route.channelPair.right
            )
            guard let preparedIOProcID = try createCombinedIOProc(
                deviceID: aggregateDeviceID,
                runtime: preparedRuntime
            ) else {
                throw CoreAudioError(
                    operation: "AudioDeviceCreateIOProcIDWithBlock(physical-first aggregate) returned nil",
                    status: kAudioHardwareUnspecifiedError
                )
            }
            ioProcID = preparedIOProcID

            traceDiagnostic {
                "disable physical-first aggregate input streams begin device=\(aggregateDeviceID)"
            }
            try disableAllInputStreams(
                deviceID: aggregateDeviceID,
                ioProcID: preparedIOProcID
            )
            traceDiagnostic {
                "disable physical-first aggregate input streams end device=\(aggregateDeviceID)"
            }

            traceDiagnostic {
                "AudioDeviceStart(physical-first aggregate) begin device=\(aggregateDeviceID) buffer=\(initialAggregate.bufferFrameSize)"
            }
            let startStatus = AudioDeviceStart(aggregateDeviceID, preparedIOProcID)
            traceDiagnostic {
                "AudioDeviceStart(physical-first aggregate) return status=\(startStatus) device=\(aggregateDeviceID)"
            }
            try checkOSStatus(
                startStatus,
                operation: "AudioDeviceStart(physical-first aggregate)"
            )

            // The running physical-only IOProc keeps the hardware timebase stable. Its physical
            // input streams are disabled above; setSubtaps publishes only the tap inputs below.
            // Activating the runtime now lets the first tapped samples replace the direct route
            // as soon as HAL installs its muter, avoiding a deliberate qualification gap.
            preparedRuntime.activate()
            let aggregateCreation = try attachTapsToRunningAggregate(
                taps: taps,
                aggregateDeviceID: aggregateDeviceID
            )
            try waitUntilAggregateHasSubtaps(
                aggregateDeviceID,
                expectedTapIDs: [taps.main, taps.systemSounds]
            )
            let tapUIDOrder = try verifyPhysicalFirstAggregateComposition(
                aggregateDeviceID,
                output: route.output,
                expectedTapUIDOrder: [
                    aggregateCreation.mainTapUID,
                    aggregateCreation.systemSoundTapUID
                ]
            )
            let aggregateInputChannelCount = try CoreAudioDeviceQuery.getChannelCount(
                objectID: aggregateDeviceID,
                scope: kAudioDevicePropertyScopeInput
            )
            guard let mainTapIndex = tapUIDOrder.firstIndex(
                of: aggregateCreation.mainTapUID
            ),
                  let systemSoundTapIndex = tapUIDOrder.firstIndex(
                    of: aggregateCreation.systemSoundTapUID
                  ),
                  let actualTapInputChannelOffsets = Self.tapInputChannelOffsets(
                    physicalInputChannelCount: physicalInputChannelCount,
                    aggregateInputChannelCount: aggregateInputChannelCount,
                    mainTapChannelCount: mainTapChannelCount,
                    systemSoundTapChannelCount: systemSoundTapChannelCount,
                    mainTapIndex: mainTapIndex,
                    systemSoundTapIndex: systemSoundTapIndex
                  ),
                  actualTapInputChannelOffsets.main == expectedTapInputChannelOffsets.main,
                  actualTapInputChannelOffsets.systemSounds
                    == expectedTapInputChannelOffsets.systemSounds else {
                throw AudioEngineInternalError(
                    message: "The live aggregate tap layout does not match the prepared audio runtime."
                )
            }

            traceDiagnostic {
                "set physical-first aggregate IOProc stream usage begin device=\(aggregateDeviceID)"
            }
            try configureInputStreamUsage(
                deviceID: aggregateDeviceID,
                ioProcID: preparedIOProcID,
                tapInputChannelOffset: min(
                    actualTapInputChannelOffsets.main,
                    actualTapInputChannelOffsets.systemSounds
                ),
                tapChannelCount: mainTapChannelCount + systemSoundTapChannelCount
            )
            traceDiagnostic {
                "set physical-first aggregate IOProc stream usage end device=\(aggregateDeviceID)"
            }

            let aggregate = try tuneAggregateBufferFrameSize(
                deviceID: aggregateDeviceID,
                targetFrameSize: targetFrameSize
            )
            traceDiagnostic {
                "physical-first aggregate buffer ready device=\(aggregateDeviceID) requested=\(targetFrameSize) actual=\(aggregate.bufferFrameSize)"
            }
            try Self.validatePlaybackCallbackCapacity(for: aggregate)
            preparedRuntime.updateExpectedCallbackFrames(
                appliedFrameCount: aggregate.bufferFrameSize
            )

            var activeOutput = route.output
            activeOutput.bufferFrameSize = aggregate.bufferFrameSize
            return PreparedCombinedAggregate(
                taps: taps,
                deviceID: aggregateDeviceID,
                ioProcID: preparedIOProcID,
                runtime: preparedRuntime,
                output: activeOutput,
                profile: profile,
                ioStarted: true
            )
        } catch {
            _ = disposeDetachedCombinedAggregate(
                DetachedCombinedAggregate(
                    deviceID: aggregateDeviceID,
                    ioProcID: ioProcID,
                    runtime: runtime
                ),
                fadeOut: false
            )
            throw error
        }
    }

    public func attemptHeadsetAggregatePromotion() throws -> HeadsetAggregatePromotionResult {
        try topologyOperation.withLock { _ in
            try attemptHeadsetAggregatePromotionSerialized()
        }
    }

    public func attemptColdStartupAggregatePromotion() throws
        -> ColdStartupAggregatePromotionResult {
        try topologyOperation.withLock { _ in
            try attemptColdStartupAggregatePromotionSerialized()
        }
    }

    private func attemptColdStartupAggregatePromotionSerialized() throws
        -> ColdStartupAggregatePromotionResult {
        guard activeBackend.withLock({ $0 }) == .separateClock,
              let context = separateClockBackend.activeOutputAndProfile(),
              deferredColdStartupRoute.withLock({ route in
                  route == Self.deferredColdStartupRoute(for: context.output)
              }) else {
            return .notApplicable
        }
        let currentDefault = try CoreAudioDeviceQuery.defaultOutputDevice()
        guard Self.deferredColdStartupRoute(for: currentDefault)
                == Self.deferredColdStartupRoute(for: context.output) else {
            deferredColdStartupRoute.withLock { $0 = nil }
            return .notApplicable
        }
        if try hasActiveExternalOutputProcess(on: currentDefault) {
            return .clientsActive
        }

        do {
            try startCombinedAggregate(
                output: currentDefault,
                profile: context.profile,
                preserveStagingOutputBuffer: true
            )
        } catch {
            guard activeBackend.withLock({ $0 }) == .separateClock,
                  separateClockBackend.activeOutputAndProfile() != nil else {
                throw error
            }
            return .aggregateUnstable
        }

        let promotionResult = try Self.coldStartupPromotionResult(
            combinedState: control.withLock { $0.state }
        )
        deferredColdStartupRoute.withLock { $0 = nil }
        return promotionResult
    }

    private func attemptHeadsetAggregatePromotionSerialized() throws
        -> HeadsetAggregatePromotionResult {
        guard activeBackend.withLock({ $0 }) == .separateClock,
              let context = separateClockBackend.activeOutputAndProfile(),
              Self.shouldUseSeparateClockBackend(for: context.output) else {
            return .notApplicable
        }
        let currentDefault = try CoreAudioDeviceQuery.defaultOutputDevice()
        guard currentDefault.uid == context.output.uid,
              currentDefault.nominalSampleRate == context.output.nominalSampleRate else {
            return .notApplicable
        }
        guard try Self.deviceClockSlopeIsStable(
            deviceID: currentDefault.id,
            nominalSampleRate: currentDefault.nominalSampleRate,
            observationDuration: Self.headsetClockProbeDuration
        ) else {
            return .clockUnstable
        }

        do {
            try startCombinedAggregate(output: currentDefault, profile: context.profile)
        } catch {
            guard activeBackend.withLock({ $0 }) == .separateClock,
                  separateClockBackend.activeOutputAndProfile() != nil else {
                throw error
            }
            return .aggregateUnstable
        }

        Thread.sleep(forTimeInterval: Self.headsetAggregateValidationDuration)
        let metrics = snapshotMetrics()
        guard metrics.pairedTimestampDiscontinuities == 0,
              case .running(let output) = state else {
            return try rejectHeadsetAggregatePromotion(context)
        }
        promotedHeadsetRoute.withLock {
            $0 = Self.promotedHeadsetRoute(for: output)
        }
        return .promoted(output)
    }

    private func rejectHeadsetAggregatePromotion(
        _ context: (output: AudioOutputDevice, profile: EQProfile)
    ) throws -> HeadsetAggregatePromotionResult {
        try restoreSeparateClockBackendOrStop(afterRejectedPromotion: context)
        return .aggregateUnstable
    }

    #if DEBUG
    func rejectHeadsetAggregatePromotionForTesting(
        output: AudioOutputDevice,
        profile: EQProfile,
        boundary: CombinedStartupTestBoundary
    ) throws -> HeadsetAggregatePromotionResult {
        try restoreSeparateClockBackendOrStopForTesting(
            afterRejectedPromotion: (output, profile),
            boundary: boundary
        )
        return .aggregateUnstable
    }
    #endif

    private func restoreSeparateClockBackendOrStop(
        afterRejectedPromotion context: (output: AudioOutputDevice, profile: EQProfile),
        preserveOutputBuffer: Bool = false
    ) throws {
        do {
            try restoreSeparateClockBackend(
                afterRejectedPromotion: context,
                preserveOutputBuffer: preserveOutputBuffer
            )
        } catch {
            let restorationError = error
            separateClockBackend.stop()
            stopCombinedResourcesSerialized(restoringDirectPlayback: true)
            finishFailedSeparateClockRestoration(restorationError)
            throw restorationError
        }
    }

    private func restoreSeparateClockBackend(
        afterRejectedPromotion context: (output: AudioOutputDevice, profile: EQProfile),
        preserveOutputBuffer: Bool = false
    ) throws {
        promotedHeadsetRoute.withLock { $0 = nil }
        let activeBackendIsSeparate = activeBackend.withLock { $0 } == .separateClock
        let hasActiveOutputAndProfile = activeBackendIsSeparate
            && separateClockBackend.activeOutputAndProfile() != nil
        guard Self.requiresSeparateClockRestoration(
            activeBackendIsSeparate: activeBackendIsSeparate,
            hasActiveOutputAndProfile: hasActiveOutputAndProfile
        ) else {
            return
        }
        let output = try CoreAudioDeviceQuery.outputDevice(id: context.output.id)
        if preserveOutputBuffer {
            try startSeparateClockBackendForColdStartup(
                output: output,
                profile: context.profile
            )
        } else {
            try startSeparateClockBackend(
                output: output,
                profile: context.profile
            )
        }
    }

    static func requiresSeparateClockRestoration(
        activeBackendIsSeparate: Bool,
        hasActiveOutputAndProfile: Bool
    ) -> Bool {
        !activeBackendIsSeparate || !hasActiveOutputAndProfile
    }

    private func finishFailedSeparateClockRestoration(_ error: Error) {
        promotedHeadsetRoute.withLock { $0 = nil }
        deferredColdStartupRoute.withLock { $0 = nil }
        activeBackend.withLock { $0 = .combinedAggregate }
        traceDiagnostic {
            "compatibility restoration failed error=\(error)"
        }
    }

    #if DEBUG
    private func restoreSeparateClockBackendOrStopForTesting(
        afterRejectedPromotion context: (output: AudioOutputDevice, profile: EQProfile),
        preserveOutputBuffer: Bool = false,
        boundary: CombinedStartupTestBoundary
    ) throws {
        promotedHeadsetRoute.withLock { $0 = nil }
        do {
            try boundary.restoreSeparateClockBackend(
                context.output,
                context.profile,
                preserveOutputBuffer
            )
        } catch {
            let restorationError = error
            boundary.stopSeparateClockBackend()
            boundary.stopCombinedResources()
            finishFailedSeparateClockRestoration(restorationError)
            throw restorationError
        }
    }
    #endif

    public func rejectHeadsetAggregatePromotion() {
        promotedHeadsetRoute.withLock { $0 = nil }
    }

    public func update(profile: EQProfile) throws {
        try topologyOperation.withLock { _ in
            if activeBackend.withLock({ $0 }) == .separateClock {
                try separateClockBackend.update(profile: profile)
                return
            }
            if updateDSP(profile: profile) {
                return
            }
            let output = try Self.profileUpdateOutput(
                control.withLock { $0.activeOutput }
            )
            try startSerialized(
                output: CoreAudioDeviceQuery.outputDevice(id: output.id),
                profile: profile
            )
        }
    }

    @discardableResult
    public func updateDSP(profile: EQProfile) -> Bool {
        if activeBackend.withLock({ $0 }) == .separateClock {
            return separateClockBackend.updateDSP(profile: profile)
        }
        guard let preparation = control.withLock({ state -> (AudioRuntime, EQProfile, Double)? in
            guard let runtime = state.runtime,
                  let activeProfile = state.activeProfile else {
                return nil
            }
            let maximumUsableFrequency = EQRouteFrequencyPolicy.maximumUsableFrequency(
                sampleRate: runtime.sampleRate
            )
            return (runtime, activeProfile, maximumUsableFrequency)
        }) else {
            return false
        }
        let (runtime, activeProfile, maximumUsableFrequency) = preparation
        guard let preparedConfig = try? EQRenderConfiguration.prepare(
            profile: profile,
            sampleRate: runtime.sampleRate,
            channelCount: runtime.channelCount,
            maximumUsableFrequency: maximumUsableFrequency
        ) else {
            return false
        }
        return control.withLock { state in
            guard state.runtime === runtime,
                  state.activeProfile == activeProfile else {
                return false
            }
            guard Self.canHotSwapDSP(
                from: activeProfile,
                to: profile,
                sampleRate: runtime.sampleRate,
                channelCount: runtime.channelCount,
                maximumUsableFrequency: maximumUsableFrequency,
                preparedConfiguration: preparedConfig
            ) else {
                return false
            }
            runtime.setProgrammeComparisonSelection(.equalized)
            runtime.drainDSPConfigBoxes()
            runtime.publishPendingDSPConfig(preparedConfig)
            state.activeProfile = profile
            return true
        }
    }

    @discardableResult
    public func beginProgrammeComparison(profile: EQProfile) -> Bool {
        guard !profile.isBypassed else {
            return false
        }
        if activeBackend.withLock({ $0 }) == .separateClock {
            return separateClockBackend.beginProgrammeComparison(profile: profile)
        }
        guard let preparation = control.withLock({ state -> (AudioRuntime, EQProfile)? in
            guard let runtime = state.runtime,
                  let activeProfile = state.activeProfile else {
                return nil
            }
            return (runtime, activeProfile)
        }) else {
            return false
        }
        let (runtime, activeProfile) = preparation
        let maximumUsableFrequency = EQRouteFrequencyPolicy.maximumUsableFrequency(
            sampleRate: runtime.sampleRate
        )
        guard let equalizedConfig = try? EQRenderConfiguration.prepare(
            profile: profile,
            sampleRate: runtime.sampleRate,
            channelCount: runtime.channelCount,
            maximumUsableFrequency: maximumUsableFrequency
        ),
        let referenceConfig = try? EQRenderConfiguration.prepare(
            profile: profile.programmeComparisonReference,
            sampleRate: runtime.sampleRate,
            channelCount: runtime.channelCount,
            maximumUsableFrequency: maximumUsableFrequency
        ) else {
            return false
        }
        return control.withLock { state in
            guard state.runtime === runtime,
                  state.activeProfile == activeProfile else {
                return false
            }
            runtime.setProgrammeComparisonSelection(.equalized)
            runtime.drainDSPConfigBoxes()
            runtime.publishPendingProgrammeComparison(
                equalizedConfig: equalizedConfig,
                referenceConfig: referenceConfig
            )
            return true
        }
    }

    public func setProgrammeComparisonSelection(
        _ selection: EQProgrammeComparisonSelection
    ) {
        if activeBackend.withLock({ $0 }) == .separateClock {
            separateClockBackend.setProgrammeComparisonSelection(selection)
            return
        }
        control.withLock { state in
            state.runtime?.setProgrammeComparisonSelection(selection)
        }
    }

    public func snapshotProgrammeComparison() -> EQProgrammeComparisonSnapshot {
        if activeBackend.withLock({ $0 }) == .separateClock {
            return separateClockBackend.snapshotProgrammeComparison()
        }
        return control.withLock { $0.runtime }?.snapshotProgrammeComparison()
            ?? EQProgrammeComparisonSnapshot()
    }

    public func setPreferredAggregateBufferFrameSize(_ frameSize: UInt32) {
        guard frameSize > 0 else {
            return
        }
        control.withLock { state in
            state.preferredAggregateBufferFrameSize = frameSize
        }
    }

    public func muteOutputForTransition() {
        if activeBackend.withLock({ $0 }) == .separateClock {
            separateClockBackend.muteOutputForTransition()
            return
        }
        control.withLock { state in
            state.runtime?.muteOutputForTransition()
        }
    }

    public func stop() {
        topologyOperation.withLock { _ in
            promotedHeadsetRoute.withLock { $0 = nil }
            deferredColdStartupRoute.withLock { $0 = nil }
            separateClockBackend.stop()
            stopCombinedResourcesSerialized(restoringDirectPlayback: true)
            retryCoreAudioCleanup()
            activeBackend.withLock { $0 = .combinedAggregate }
        }
    }

    public func snapshotMetrics() -> AudioEngineMetrics {
        if activeBackend.withLock({ $0 }) == .separateClock {
            return separateClockBackend.snapshotMetrics()
        }
        return control.withLock { $0.runtime }?.snapshotMetrics() ?? AudioEngineMetrics()
    }

    public func snapshotTimestampProbeRecords() -> [AudioTimestampProbeRecord] {
        control.withLock { $0.lastTimestampProbeRecords }
    }

    public func snapshotLatencyMetadata() -> AudioEngineLatencyMetadata? {
        guard activeBackend.withLock({ $0 }) == .combinedAggregate else {
            return nil
        }
        let route = control.withLock { state -> (AudioObjectID, AudioObjectID)? in
            guard let output = state.activeOutput,
                  state.aggregateDeviceID != kAudioObjectUnknown else {
                return nil
            }
            return (output.id, state.aggregateDeviceID)
        }
        guard let route else {
            return nil
        }
        return AudioEngineLatencyMetadata(
            physicalDevice: Self.latencyMetadata(deviceID: route.0),
            aggregateDevice: Self.latencyMetadata(deviceID: route.1)
        )
    }

    public func resetDiagnostics() {
        if activeBackend.withLock({ $0 }) == .separateClock {
            separateClockBackend.resetDiagnostics()
            return
        }
        control.withLock { $0.runtime }?.resetMetrics()
    }

    public func setPlaybackBufferRenegotiationHandler(
        _ handler: (@Sendable (PlaybackBufferRenegotiation) -> Void)?
    ) {
        separateClockBackend.setPlaybackBufferRenegotiationHandler(handler)
    }

    public func setRuntimeFailureHandler(
        _ handler: (@Sendable (AudioEngineFailure) -> Void)?
    ) {
        separateClockBackend.setRuntimeFailureHandler(handler)
    }

    #if DEBUG
    public func simulateRenderStallForTesting() {
        if activeBackend.withLock({ $0 }) == .separateClock {
            separateClockBackend.simulateRenderStallForTesting()
            return
        }
        control.withLock { $0.runtime }?.simulateRenderStallForTesting()
    }
    #endif

    private func stopCombinedResourcesSerialized(
        restoringDirectPlayback: Bool = false
    ) {
        var detachedAggregate: DetachedCombinedAggregate?
        var detachedTaps: CombinedTapSet?
        control.withLock { state in
            detachedAggregate = detachCombinedAggregateLocked(&state)
            detachedTaps = detachTapSetLocked(&state)
            state.activeProfile = nil
            state.state = .stopped
            state.status = .stopped
        }
        // mutedWhenTapped restores direct output when the IOProc stops reading the taps.
        // Explicit handback skips the fade; rebuild teardown retains it.
        if let detachedAggregate {
            let records = disposeDetachedCombinedAggregate(
                detachedAggregate,
                fadeOut: !restoringDirectPlayback
            )
            control.withLock { state in
                state.lastTimestampProbeRecords = records
            }
        }
        if let detachedTaps {
            destroyTapSet(detachedTaps)
        }
    }

    private func detachCombinedAggregateLocked(
        _ state: inout ControlState
    ) -> DetachedCombinedAggregate? {
        let detached = DetachedCombinedAggregate(
            deviceID: state.aggregateDeviceID,
            ioProcID: state.ioProcID,
            runtime: state.runtime
        )
        state.aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        state.ioProcID = nil
        state.runtime = nil
        state.activeOutput = nil
        guard detached.deviceID != kAudioObjectUnknown
                || detached.ioProcID != nil
                || detached.runtime != nil else {
            return nil
        }
        return detached
    }

    private func disposeDetachedCombinedAggregate(
        _ detached: DetachedCombinedAggregate,
        fadeOut: Bool = true
    ) -> [AudioTimestampProbeRecord] {
        if fadeOut {
            detached.runtime?.fadeOutForStop()
        }
        detached.runtime?.markStopping()
        let records = detached.runtime?.snapshotTimestampProbeRecords() ?? []
        let runtime = detached.runtime
        var resources = CoreAudioResourceCleanupLedger.PendingResources(
            operation: "dispose combined aggregate",
            completion: {
                runtime?.drainDSPConfigBoxes()
            }
        )
        if detached.deviceID != kAudioObjectUnknown,
           let ioProcID = detached.ioProcID {
            resources.ioProcs.append(.init(
                deviceID: detached.deviceID,
                ioProcID: ioProcID
            ))
        }
        if detached.deviceID != kAudioObjectUnknown {
            resources.aggregateDeviceIDs.append(detached.deviceID)
        }
        guard resources.ioProcs.isEmpty == false
                || resources.aggregateDeviceIDs.isEmpty == false else {
            runtime?.drainDSPConfigBoxes()
            return records
        }
        if !cleanupLedger.dispose(resources) {
            traceDiagnostic {
                "Core Audio cleanup deferred operation=dispose combined aggregate pending=\(cleanupLedger.pendingCount)"
            }
        }
        return records
    }

    private func detachTapSetLocked(_ state: inout ControlState) -> CombinedTapSet? {
        let tapSet: CombinedTapSet?
        if state.tapID != kAudioObjectUnknown || state.systemSoundTapID != kAudioObjectUnknown {
            tapSet = CombinedTapSet(
                main: state.tapID,
                systemSounds: state.systemSoundTapID,
                outputUID: state.tapOutputUID ?? "",
                outputStreamIndex: state.tapOutputStreamIndex ?? 0
            )
        } else {
            tapSet = nil
        }
        state.tapID = AudioObjectID(kAudioObjectUnknown)
        state.systemSoundTapID = AudioObjectID(kAudioObjectUnknown)
        state.tapOutputUID = nil
        state.tapOutputStreamIndex = nil
        return tapSet
    }

    private func destroyTapSet(_ taps: CombinedTapSet) {
        var resources = CoreAudioResourceCleanupLedger.PendingResources(
            operation: "destroy combined process taps"
        )
        if taps.main != kAudioObjectUnknown {
            resources.tapIDs.append(taps.main)
        }
        if taps.systemSounds != kAudioObjectUnknown {
            resources.tapIDs.append(taps.systemSounds)
        }
        guard !resources.tapIDs.isEmpty else {
            return
        }
        if !cleanupLedger.dispose(resources) {
            traceDiagnostic {
                "Core Audio cleanup deferred operation=destroy combined process taps pending=\(cleanupLedger.pendingCount)"
            }
        }
    }

    private func requireCompletedCoreAudioCleanup(operation: String) throws {
        for attempt in 0..<3 {
            if cleanupLedger.retryPending() {
                return
            }
            if attempt < 2 {
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        traceDiagnostic {
            "Core Audio cleanup still pending before \(operation) count=\(cleanupLedger.pendingCount)"
        }
        throw CoreAudioError(
            operation: "Complete prior Core Audio cleanup before \(operation)",
            status: kAudioHardwareUnspecifiedError
        )
    }

    private func retryCoreAudioCleanup() {
        do {
            try requireCompletedCoreAudioCleanup(operation: "finish stopping audio")
        } catch {
            traceDiagnostic { "Core Audio cleanup remains owned for retry error=\(error)" }
        }
    }

    private func createSystemTaps(
        output: AudioOutputDevice,
        streamIndex: Int
    ) throws -> (main: AudioObjectID, systemSounds: AudioObjectID) {
        let ownProcess = try currentAudioProcessObjectID()
        let mainDescription = Self.makeSystemTapDescription(
            excluding: [ownProcess],
            outputUID: output.uid,
            streamIndex: streamIndex
        )
        let systemSoundDescription = Self.makeSystemSoundTapDescription(
            outputUID: output.uid,
            streamIndex: streamIndex
        )

        var mainTapID = AudioObjectID(kAudioObjectUnknown)
        traceDiagnostic { "AudioHardwareCreateProcessTap(main) begin output=\(output.id)" }
        let mainStatus = AudioHardwareCreateProcessTap(mainDescription, &mainTapID)
        traceDiagnostic {
            "AudioHardwareCreateProcessTap(main) return status=\(mainStatus) tap=\(mainTapID)"
        }
        try checkOSStatus(mainStatus, operation: "AudioHardwareCreateProcessTap(main)")
        do {
            var systemSoundTapID = AudioObjectID(kAudioObjectUnknown)
            traceDiagnostic {
                "AudioHardwareCreateProcessTap(system sounds) begin output=\(output.id)"
            }
            let systemSoundStatus = AudioHardwareCreateProcessTap(
                systemSoundDescription,
                &systemSoundTapID
            )
            traceDiagnostic {
                "AudioHardwareCreateProcessTap(system sounds) return status=\(systemSoundStatus) tap=\(systemSoundTapID)"
            }
            try checkOSStatus(
                systemSoundStatus,
                operation: "AudioHardwareCreateProcessTap(system sounds)"
            )
            return (mainTapID, systemSoundTapID)
        } catch {
            destroyTapSet(CombinedTapSet(
                main: mainTapID,
                systemSounds: AudioObjectID(kAudioObjectUnknown),
                outputUID: output.uid,
                outputStreamIndex: streamIndex
            ))
            throw error
        }
    }

    static func makeSystemTapDescription(
        excluding processes: [AudioObjectID],
        outputUID: String,
        streamIndex: Int
    ) -> CATapDescription {
        let description = CATapDescription(
            excludingProcesses: processes,
            deviceUID: outputUID,
            stream: UInt(streamIndex)
        )
        description.name = "GlassEQ System Output Tap"
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        description.isMixdown = false
        description.bundleIDs = [Self.systemSoundServerBundleID]
        description.isProcessRestoreEnabled = true
        return description
    }

    static func makeSystemSoundTapDescription(
        outputUID: String,
        streamIndex: Int
    ) -> CATapDescription {
        let description = CATapDescription(
            processes: [],
            deviceUID: outputUID,
            stream: UInt(streamIndex)
        )
        description.name = "GlassEQ System Sounds Tap"
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        description.isMixdown = false
        description.bundleIDs = [Self.systemSoundServerBundleID]
        description.isProcessRestoreEnabled = true
        return description
    }

    private func createPhysicalOnlyAggregateDevice(
        output: AudioOutputDevice
    ) throws -> AudioObjectID {
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "GlassEQ Private Output Device",
            kAudioAggregateDeviceUIDKey: "com.glasseq.aggregate.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: output.uid,
            kAudioAggregateDeviceSubDeviceListKey: [
                [
                    kAudioSubDeviceUIDKey: output.uid,
                    kAudioSubDeviceInputChannelsKey: 0,
                    kAudioSubDeviceOutputChannelsKey: output.outputChannelCount,
                    kAudioSubDeviceDriftCompensationKey: false
                ]
            ]
        ]
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        traceDiagnostic {
            "AudioHardwareCreateAggregateDevice(physical-first) begin physicalDevice=\(output.id) physicalBuffer=\(output.bufferFrameSize)"
        }
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &deviceID)
        traceDiagnostic {
            "AudioHardwareCreateAggregateDevice(physical-first) return status=\(status) device=\(deviceID)"
        }
        try checkOSStatus(
            status,
            operation: "AudioHardwareCreateAggregateDevice(physical-first)"
        )
        return deviceID
    }

    private func attachTapsToRunningAggregate(
        taps: CombinedTapSet,
        aggregateDeviceID: AudioObjectID
    ) throws -> CombinedAggregateCreation {
        let mainTapUID = try CoreAudioDeviceQuery.getStringProperty(
            objectID: taps.main,
            selector: kAudioTapPropertyUID,
            scope: kAudioObjectPropertyScopeGlobal
        )
        let systemSoundTapUID = try CoreAudioDeviceQuery.getStringProperty(
            objectID: taps.systemSounds,
            selector: kAudioTapPropertyUID,
            scope: kAudioObjectPropertyScopeGlobal
        )
        traceDiagnostic {
            "AudioHardwareAggregateDevice.setSubtaps begin device=\(aggregateDeviceID) taps=[\(taps.main), \(taps.systemSounds)]"
        }
        try AudioHardwareAggregateDevice(id: aggregateDeviceID).setSubtaps([
            AudioHardwareTap(id: taps.main),
            AudioHardwareTap(id: taps.systemSounds)
        ])
        traceDiagnostic {
            "AudioHardwareAggregateDevice.setSubtaps return device=\(aggregateDeviceID)"
        }
        return CombinedAggregateCreation(
            deviceID: aggregateDeviceID,
            mainTapUID: mainTapUID,
            systemSoundTapUID: systemSoundTapUID
        )
    }

    private func createCombinedAggregateDevice(
        tapID: AudioObjectID,
        systemSoundTapID: AudioObjectID,
        output: AudioOutputDevice
    ) throws -> CombinedAggregateCreation {
        let tapUID = try CoreAudioDeviceQuery.getStringProperty(
            objectID: tapID,
            selector: kAudioTapPropertyUID,
            scope: kAudioObjectPropertyScopeGlobal
        )
        let systemSoundTapUID = try CoreAudioDeviceQuery.getStringProperty(
            objectID: systemSoundTapID,
            selector: kAudioTapPropertyUID,
            scope: kAudioObjectPropertyScopeGlobal
        )
        let tapDescription: (String, Bool) -> [String: Any] = { uid, driftCompensation in
            var description: [String: Any] = [
                kAudioSubTapUIDKey: uid,
                kAudioSubTapDriftCompensationKey: driftCompensation
            ]
            if driftCompensation {
                description[kAudioSubTapDriftCompensationQualityKey] =
                    kAudioAggregateDriftCompensationHighQuality
            }
            return description
        }
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "GlassEQ Private Output Device",
            kAudioAggregateDeviceUIDKey: "com.glasseq.aggregate.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: output.uid,
            kAudioAggregateDeviceSubDeviceListKey: [
                [
                    kAudioSubDeviceUIDKey: output.uid,
                    kAudioSubDeviceInputChannelsKey: 0,
                    kAudioSubDeviceOutputChannelsKey: output.outputChannelCount,
                    kAudioSubDeviceDriftCompensationKey: false
                ]
            ],
            kAudioAggregateDeviceTapListKey: [
                tapDescription(tapUID, true),
                tapDescription(systemSoundTapUID, true)
            ]
        ]

        var deviceID = AudioObjectID(kAudioObjectUnknown)
        traceDiagnostic {
            "AudioHardwareCreateAggregateDevice(combined) begin physicalDevice=\(output.id) physicalBuffer=\(output.bufferFrameSize)"
        }
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &deviceID)
        traceDiagnostic {
            "AudioHardwareCreateAggregateDevice(combined) return status=\(status) device=\(deviceID)"
        }
        try checkOSStatus(status, operation: "AudioHardwareCreateAggregateDevice(combined)")
        return CombinedAggregateCreation(
            deviceID: deviceID,
            mainTapUID: tapUID,
            systemSoundTapUID: systemSoundTapUID
        )
    }

    private func tapChannelCount(_ tapID: AudioObjectID) throws -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try checkOSStatus(
            AudioObjectGetPropertyData(
                tapID,
                &address,
                0,
                nil,
                &size,
                &format
            ),
            operation: "AudioObjectGetPropertyData(tap format)"
        )
        guard size == UInt32(MemoryLayout<AudioStreamBasicDescription>.size) else {
            throw AudioEngineInternalError(
                message: "Core Audio returned an invalid process-tap format."
            )
        }
        guard format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32 else {
            throw AudioEngineInternalError(
                message: "Core Audio returned an unsupported process-tap sample format."
            )
        }
        return Int(format.mChannelsPerFrame)
    }

    private func waitUntilAggregateIsAlive(_ deviceID: AudioObjectID) throws {
        traceDiagnostic { "wait aggregate alive begin device=\(deviceID)" }
        let deadline = Date().addingTimeInterval(3)
        var lastError: Error?
        repeat {
            do {
                if try CoreAudioDeviceQuery.isDeviceAlive(id: deviceID) {
                    traceDiagnostic { "wait aggregate alive end device=\(deviceID) alive=true" }
                    return
                }
            } catch {
                lastError = error
            }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline

        if let lastError {
            throw lastError
        }
        throw CoreAudioError(
            operation: "combined aggregate did not become alive",
            status: kAudioHardwareNotRunningError
        )
    }

    private func waitUntilAggregateHasSubtaps(
        _ deviceID: AudioObjectID,
        expectedTapIDs: [AudioObjectID]
    ) throws {
        traceDiagnostic {
            "wait aggregate subtaps begin device=\(deviceID) expected=\(expectedTapIDs)"
        }
        let aggregate = AudioHardwareAggregateDevice(id: deviceID)
        let deadline = Date().addingTimeInterval(3)
        var lastError: Error?
        repeat {
            do {
                let tapIDs = try aggregate.subtaps.map(\.id)
                if tapIDs == expectedTapIDs {
                    traceDiagnostic {
                        "wait aggregate subtaps end device=\(deviceID) active=\(tapIDs)"
                    }
                    return
                }
            } catch {
                lastError = error
            }
            Thread.sleep(forTimeInterval: 0.001)
        } while Date() < deadline

        if let lastError {
            throw lastError
        }
        throw CoreAudioError(
            operation: "combined aggregate did not publish its process taps",
            status: kAudioHardwareNotRunningError
        )
    }

    private func tuneAggregateBufferFrameSize(
        deviceID: AudioObjectID,
        targetFrameSize: UInt32
    ) throws -> AudioOutputDevice {
        var aggregate = try CoreAudioDeviceQuery.outputDevice(id: deviceID)
        let range = try CoreAudioDeviceQuery.bufferFrameSizeRangeValue(objectID: deviceID)
        let requested = min(max(targetFrameSize, range.minimum), range.maximum)
        traceDiagnostic {
            "aggregate buffer inspect device=\(deviceID) current=\(aggregate.bufferFrameSize) target=\(targetFrameSize) clamped=\(requested) range=\(range.minimum)...\(range.maximum)"
        }
        guard aggregate.bufferFrameSize != requested else {
            return aggregate
        }
        do {
            traceDiagnostic {
                "set aggregate buffer begin device=\(deviceID) requested=\(requested)"
            }
            try CoreAudioDeviceQuery.setBufferFrameSize(requested, objectID: deviceID)
            for attempt in 0..<3 {
                aggregate = try CoreAudioDeviceQuery.outputDevice(id: deviceID)
                if aggregate.bufferFrameSize == requested {
                    traceDiagnostic {
                        "set aggregate buffer end device=\(deviceID) actual=\(aggregate.bufferFrameSize)"
                    }
                    return aggregate
                }
                if attempt < 2 {
                    Thread.sleep(forTimeInterval: 0.01)
                }
            }
        } catch {
            traceDiagnostic {
                "set aggregate buffer failed device=\(deviceID) actual=\(aggregate.bufferFrameSize) error=\(error)"
            }
            return aggregate
        }
        traceDiagnostic {
            "set aggregate buffer not applied device=\(deviceID) actual=\(aggregate.bufferFrameSize)"
        }
        return aggregate
    }

    private func verifyAggregateComposition(
        _ deviceID: AudioObjectID,
        output: AudioOutputDevice,
        expectedTapDriftCompensation: [String: Bool]
    ) throws -> [String] {
        let mainUID = try CoreAudioDeviceQuery.getStringProperty(
            objectID: deviceID,
            selector: kAudioAggregateDevicePropertyMainSubDevice,
            scope: kAudioObjectPropertyScopeGlobal
        )
        guard mainUID == output.uid else {
            throw AudioEngineInternalError(
                message: "The aggregate clock source does not match the selected output."
            )
        }

        let composition = try dictionaryProperty(
            objectID: deviceID,
            selector: kAudioAggregateDevicePropertyComposition
        )
        guard let tapEntries = composition[kAudioAggregateDeviceTapListKey]
            as? [NSDictionary],
            let tapUIDOrder = Self.validatedAggregateTapUIDOrder(
                tapEntries,
                expectedTapDriftCompensation: expectedTapDriftCompensation
            ) else {
            throw AudioEngineInternalError(
                message: "Core Audio returned an invalid process-tap composition."
            )
        }
        return tapUIDOrder
    }

    private func verifyPhysicalFirstAggregateComposition(
        _ deviceID: AudioObjectID,
        output: AudioOutputDevice,
        expectedTapUIDOrder: [String]
    ) throws -> [String] {
        let mainUID = try CoreAudioDeviceQuery.getStringProperty(
            objectID: deviceID,
            selector: kAudioAggregateDevicePropertyMainSubDevice,
            scope: kAudioObjectPropertyScopeGlobal
        )
        guard mainUID == output.uid else {
            throw AudioEngineInternalError(
                message: "The aggregate clock source does not match the selected output."
            )
        }
        let composition = try dictionaryProperty(
            objectID: deviceID,
            selector: kAudioAggregateDevicePropertyComposition
        )
        guard let tapEntries = composition[kAudioAggregateDeviceTapListKey]
            as? [NSDictionary] else {
            throw AudioEngineInternalError(
                message: "Core Audio did not publish the live process-tap composition."
            )
        }
        let publishedDriftMetadata = tapEntries.map { entry in
            let uid = entry[kAudioSubTapUIDKey] as? String ?? "unknown"
            let drift = (entry[kAudioSubTapDriftCompensationKey] as? NSNumber)?
                .uint32Value
            let quality = (entry[kAudioSubTapDriftCompensationQualityKey] as? NSNumber)?
                .uint32Value
            return "\(uid):drift=\(drift.map(String.init) ?? "unset"),quality=\(quality.map(String.init) ?? "unset")"
        }
        traceDiagnostic {
            "physical-first published tap drift metadata [\(publishedDriftMetadata.joined(separator: ", "))]"
        }
        let tapUIDOrder = tapEntries.compactMap {
            $0[kAudioSubTapUIDKey] as? String
        }
        guard tapUIDOrder == expectedTapUIDOrder else {
            throw AudioEngineInternalError(
                message: "Core Audio changed the live process-tap membership or order."
            )
        }
        return tapUIDOrder
    }

    static func validatedAggregateTapUIDOrder(
        _ tapEntries: [NSDictionary],
        expectedTapDriftCompensation: [String: Bool]
    ) -> [String]? {
        guard tapEntries.count == expectedTapDriftCompensation.count else {
            return nil
        }
        var tapUIDOrder: [String] = []
        tapUIDOrder.reserveCapacity(tapEntries.count)
        for entry in tapEntries {
            guard let uid = entry[kAudioSubTapUIDKey] as? String,
                  let drift = entry[kAudioSubTapDriftCompensationKey] as? NSNumber,
                  let expectedDrift = expectedTapDriftCompensation[uid],
                  drift.boolValue == expectedDrift else {
                return nil
            }
            if expectedDrift {
                guard let quality = entry[kAudioSubTapDriftCompensationQualityKey]
                    as? NSNumber,
                      quality.uint32Value == kAudioAggregateDriftCompensationHighQuality else {
                    return nil
                }
            }
            tapUIDOrder.append(uid)
        }
        guard Set(tapUIDOrder) == Set(expectedTapDriftCompensation.keys) else {
            return nil
        }
        return tapUIDOrder
    }

    private func createCombinedIOProc(
        deviceID: AudioObjectID,
        runtime: AudioRuntime
    ) throws -> AudioDeviceIOProcID? {
        var ioProcID: AudioDeviceIOProcID?
        traceDiagnostic {
            "AudioDeviceCreateIOProcIDWithBlock(combined aggregate) begin device=\(deviceID)"
        }
        let status = AudioDeviceCreateIOProcIDWithBlock(
            &ioProcID,
            deviceID,
            nil
        ) { _, inputData, inputTime, outputData, outputTime in
            runtime.render(
                inputData: inputData,
                inputTime: inputTime.pointee,
                outputData: outputData,
                outputTime: outputTime.pointee
            )
        }
        traceDiagnostic {
            "AudioDeviceCreateIOProcIDWithBlock(combined aggregate) return status=\(status) device=\(deviceID)"
        }
        try checkOSStatus(
            status,
            operation: "AudioDeviceCreateIOProcIDWithBlock(combined aggregate)"
        )
        return ioProcID
    }

    private func configureInputStreamUsage(
        deviceID: AudioObjectID,
        ioProcID: AudioDeviceIOProcID,
        tapInputChannelOffset: Int,
        tapChannelCount: Int
    ) throws {
        let streamChannelCounts = try CoreAudioDeviceQuery.streamChannelCounts(
            objectID: deviceID,
            scope: kAudioDevicePropertyScopeInput
        )
        guard let usage = Self.inputStreamUsage(
            streamChannelCounts: streamChannelCounts,
            tapChannelOffset: tapInputChannelOffset,
            tapChannelCount: tapChannelCount
        ) else {
            throw AudioEngineInternalError(
                message: "The aggregate input streams cannot isolate the process tap from physical input."
            )
        }
        try setIOProcStreamUsage(
            usage,
            deviceID: deviceID,
            ioProcID: ioProcID
        )
        let appliedUsage = try ioProcStreamUsage(
            streamCount: usage.count,
            deviceID: deviceID,
            ioProcID: ioProcID
        )
        guard appliedUsage == usage else {
            throw AudioEngineInternalError(
                message: "Core Audio did not disable the aggregate's physical input streams."
            )
        }
    }

    private func disableAllInputStreams(
        deviceID: AudioObjectID,
        ioProcID: AudioDeviceIOProcID
    ) throws {
        let streamCount = try CoreAudioDeviceQuery.streamChannelCounts(
            objectID: deviceID,
            scope: kAudioDevicePropertyScopeInput
        ).count
        guard streamCount > 0 else {
            return
        }
        let usage = Array(repeating: UInt32(0), count: streamCount)
        try setIOProcStreamUsage(
            usage,
            deviceID: deviceID,
            ioProcID: ioProcID
        )
        let appliedUsage = try ioProcStreamUsage(
            streamCount: streamCount,
            deviceID: deviceID,
            ioProcID: ioProcID
        )
        guard appliedUsage == usage else {
            throw AudioEngineInternalError(
                message: "Core Audio did not disable the physical-first aggregate's input streams."
            )
        }
    }

    private func setIOProcStreamUsage(
        _ usage: [UInt32],
        deviceID: AudioObjectID,
        ioProcID: AudioDeviceIOProcID
    ) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyIOProcStreamUsage,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        let storage = ioProcStreamUsageStorage(usage, ioProcID: ioProcID)
        defer { storage.deallocate() }
        let size = UInt32(Self.ioProcStreamUsageByteCount(streamCount: usage.count))
        try checkOSStatus(
            AudioObjectSetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                size,
                storage
            ),
            operation: "AudioObjectSetPropertyData(input IOProc stream usage)"
        )
    }

    private func ioProcStreamUsage(
        streamCount: Int,
        deviceID: AudioObjectID,
        ioProcID: AudioDeviceIOProcID
    ) throws -> [UInt32] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyIOProcStreamUsage,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        let storage = ioProcStreamUsageStorage(
            Array(repeating: 0, count: streamCount),
            ioProcID: ioProcID
        )
        defer { storage.deallocate() }
        let expectedSize = Self.ioProcStreamUsageByteCount(streamCount: streamCount)
        var size = UInt32(expectedSize)
        try checkOSStatus(
            AudioObjectGetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                &size,
                storage
            ),
            operation: "AudioObjectGetPropertyData(input IOProc stream usage)"
        )
        guard size == UInt32(expectedSize) else {
            throw AudioEngineInternalError(
                message: "Core Audio returned invalid input stream-usage metadata."
            )
        }
        let header = storage.assumingMemoryBound(to: AudioHardwareIOProcStreamUsage.self)
        guard Int(header.pointee.mNumberStreams) == streamCount else {
            throw AudioEngineInternalError(
                message: "Core Audio returned the wrong number of input stream-usage entries."
            )
        }
        let values = storage
            .advanced(by: Self.ioProcStreamUsageValuesOffset)
            .assumingMemoryBound(to: UInt32.self)
        return (0..<streamCount).map { values[$0] }
    }

    private func ioProcStreamUsageStorage(
        _ usage: [UInt32],
        ioProcID: AudioDeviceIOProcID
    ) -> UnsafeMutableRawPointer {
        let byteCount = Self.ioProcStreamUsageByteCount(streamCount: usage.count)
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: byteCount,
            alignment: MemoryLayout<AudioHardwareIOProcStreamUsage>.alignment
        )
        storage.initializeMemory(
            as: UInt8.self,
            repeating: 0,
            count: byteCount
        )
        let header = storage.assumingMemoryBound(to: AudioHardwareIOProcStreamUsage.self)
        header.pointee.mIOProc = unsafeBitCast(ioProcID, to: UnsafeMutableRawPointer.self)
        header.pointee.mNumberStreams = UInt32(usage.count)
        let values = storage
            .advanced(by: Self.ioProcStreamUsageValuesOffset)
            .assumingMemoryBound(to: UInt32.self)
        for (index, enabled) in usage.enumerated() {
            values[index] = enabled
        }
        return storage
    }

    private static let ioProcStreamUsageValuesOffset =
        MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn)!

    private static func ioProcStreamUsageByteCount(streamCount: Int) -> Int {
        ioProcStreamUsageValuesOffset + streamCount * MemoryLayout<UInt32>.stride
    }

    private func dictionaryProperty(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) throws -> NSDictionary {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let pointer = UnsafeMutablePointer<CFDictionary?>.allocate(capacity: 1)
        pointer.initialize(to: nil)
        defer {
            pointer.deinitialize(count: 1)
            pointer.deallocate()
        }
        var size = UInt32(MemoryLayout<CFDictionary?>.size)
        try checkOSStatus(
            AudioObjectGetPropertyData(
                objectID,
                &address,
                0,
                nil,
                &size,
                UnsafeMutableRawPointer(pointer)
            ),
            operation: "AudioObjectGetPropertyData(aggregate composition)"
        )
        guard let value = pointer.pointee else {
            throw CoreAudioError(
                operation: "AudioObjectGetPropertyData(aggregate composition) returned nil",
                status: kAudioHardwareBadObjectError
            )
        }
        return value as NSDictionary
    }

    private func currentAudioProcessObjectID() throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid = getpid()
        var processID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try checkOSStatus(
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<pid_t>.size),
                &pid,
                &size,
                &processID
            ),
            operation: "AudioObjectGetPropertyData(translate pid)"
        )
        guard processID != kAudioObjectUnknown else {
            throw AudioEngineInternalError(
                message: "Core Audio did not publish the GlassEQ process object."
            )
        }
        return processID
    }

    static func systemSoundPreampGains(
        for configuration: EQRenderConfiguration
    ) -> (left: Float, right: Float) {
        guard !configuration.configuration.isBypassed else {
            return (left: 1, right: 1)
        }
        let channels = configuration.configuration.channelConfigurations
        let left = channels.first?.preampLinearGain
            ?? configuration.configuration.preampLinearGain
        let right = channels.count > 1
            ? channels[1].preampLinearGain
            : left
        return (left, right)
    }

    private func audioEngineFailure(from error: Error) -> AudioEngineFailure {
        if let coreAudioError = error as? CoreAudioError {
            return classifyCoreAudioError(coreAudioError)
        }
        if let availabilityError = error as? AudioDeviceAvailabilityError {
            switch availabilityError {
            case .unsupportedOutputChannelCount,
                 .unsupportedOutputBufferFrameSize:
                return AudioEngineFailure(
                    category: .deviceFormatUnsupported,
                    userMessage: availabilityError.description,
                    operation: "CoreAudioDeviceQuery"
                )
            default:
                return AudioEngineFailure(
                    category: .outputDeviceUnavailable,
                    userMessage: availabilityError.description,
                    operation: "CoreAudioDeviceQuery"
                )
            }
        }
        return AudioEngineFailure(
            category: .coreAudioOperationFailed,
            userMessage: String(describing: error),
            operation: "SystemTapAudioEngine"
        )
    }

    static func canHotSwapDSP(
        from _: EQProfile,
        to nextProfile: EQProfile,
        sampleRate: Double,
        channelCount: Int,
        maximumUsableFrequency: Double? = nil,
        preparedConfiguration: EQRenderConfiguration? = nil
    ) -> Bool {
        if let preparedConfiguration {
            return preparedConfiguration.isNumericallySafe
        }
        return (try? EQRenderConfiguration.prepare(
            profile: nextProfile,
            sampleRate: sampleRate,
            channelCount: channelCount,
            maximumUsableFrequency: maximumUsableFrequency
        )) != nil
    }

    static func supportedRuntimeChannelCount(
        for output: AudioOutputDevice
    ) throws -> Int {
        guard output.outputChannelCount > 0 else {
            throw AudioDeviceAvailabilityError.outputDeviceHasNoOutputChannels(output.id)
        }
        guard output.outputChannelCount <= CoreAudioDeviceQuery.maxChannelCount else {
            throw AudioDeviceAvailabilityError.unsupportedOutputChannelCount(
                output.id,
                output.outputChannelCount
            )
        }
        return output.outputChannelCount
    }

    static func validatePlaybackCallbackCapacity(
        for output: AudioOutputDevice
    ) throws {
        guard output.bufferFrameSize <= UInt32(maximumSupportedCallbackFrames) else {
            throw AudioDeviceAvailabilityError.unsupportedOutputBufferFrameSize(
                output.id,
                output.bufferFrameSize,
                maximum: UInt32(maximumSupportedCallbackFrames)
            )
        }
    }

    static func startupCallbackIsValid(
        mainInputFrameCount: Int,
        systemSoundInputFrameCount: Int,
        outputFrameCount: Int,
        expectedFrameCount: Int,
        timestampsAreStable: Bool
    ) -> Bool {
        expectedFrameCount > 0
            && mainInputFrameCount == expectedFrameCount
            && (systemSoundInputFrameCount == 0
                || systemSoundInputFrameCount == expectedFrameCount)
            && outputFrameCount == expectedFrameCount
            && timestampsAreStable
    }

    static func shouldConsiderColdStartupDeferral(
        activeBackendIsSeparate: Bool,
        combinedState: AudioEngineState
    ) -> Bool {
        guard !activeBackendIsSeparate else {
            return false
        }
        switch combinedState {
        case .stopped, .failed:
            return true
        case .running:
            return false
        }
    }

    static func coldStartupPromotionResult(
        combinedState: AudioEngineState
    ) throws -> ColdStartupAggregatePromotionResult {
        guard case .running(let output) = combinedState else {
            throw AudioEngineInternalError(
                message: "The combined aggregate did not publish its active output."
            )
        }
        return .promoted(output)
    }

    static func startupAttemptFrameSizes(requestedFrameSize: UInt32) -> [UInt32] {
        var attempts = [requestedFrameSize, requestedFrameSize]
        if let saferFrameSize = [UInt32(16), 32, 64].first(where: {
            $0 > requestedFrameSize
        }) {
            attempts.append(saferFrameSize)
        }
        return attempts
    }

    static func runCombinedStartupAttempts(
        frameSizes: [UInt32],
        isSeparateClockHandoff: Bool,
        attempt: (UInt32) throws -> Void,
        restoreSeparateClockOutput: () throws -> Void,
        waitBeforeRetry: () -> Void
    ) throws {
        var lastStartupError: (any Error)?

        for (index, frameSize) in frameSizes.enumerated() {
            do {
                try attempt(frameSize)
                return
            } catch {
                let startupError = error
                lastStartupError = startupError
                let hasAnotherAttempt = index + 1 < frameSizes.count

                if isSeparateClockHandoff {
                    do {
                        try restoreSeparateClockOutput()
                    } catch {
                        throw startupError
                    }
                }

                guard startupError is AggregateStartupQualificationError,
                      hasAnotherAttempt else {
                    throw startupError
                }
                waitBeforeRetry()
            }
        }

        if let lastStartupError {
            throw lastStartupError
        }
    }

    static func startupQualificationTimeout(
        frameCount: Int,
        sampleRate: Double,
        minimumConsecutiveCallbacks: UInt64
    ) -> TimeInterval {
        guard frameCount > 0,
              sampleRate.isFinite,
              sampleRate > 0 else {
            return 0.25
        }
        let callbacksIncludingSlopeAcquisition = Double(
            minimumConsecutiveCallbacks + 10
        )
        let expectedDuration = callbacksIncludingSlopeAcquisition
            * Double(frameCount) / sampleRate
        return min(max(expectedDuration * 2, 0.25), 3)
    }

    static func playbackStereoPair(
        preferredChannels: (left: UInt32, right: UInt32)?,
        outputChannelCount: Int
    ) -> (left: Int, right: Int) {
        guard outputChannelCount > 1 else {
            return outputChannelCount == 1 ? (0, 0) : (0, 1)
        }
        guard let preferredChannels,
              preferredChannels.left >= 1,
              preferredChannels.right >= 1,
              preferredChannels.left != preferredChannels.right,
              preferredChannels.left <= UInt32(outputChannelCount),
              preferredChannels.right <= UInt32(outputChannelCount) else {
            return (0, 1)
        }
        return (
            Int(preferredChannels.left) - 1,
            Int(preferredChannels.right) - 1
        )
    }

    static func tapOutputStreamIndex(
        streamChannelCounts: [Int],
        playbackChannels: (left: Int, right: Int)
    ) -> Int? {
        guard !streamChannelCounts.isEmpty,
              streamChannelCounts.allSatisfy({ $0 > 0 }),
              playbackChannels.left >= 0,
              playbackChannels.right >= 0 else {
            return nil
        }
        var channelOffset = 0
        for (streamIndex, channelCount) in streamChannelCounts.enumerated() {
            let upperBound = channelOffset + channelCount
            if playbackChannels.left >= channelOffset,
               playbackChannels.left < upperBound,
               playbackChannels.right >= channelOffset,
               playbackChannels.right < upperBound {
                return channelCount <= 2 ? streamIndex : nil
            }
            channelOffset = upperBound
        }
        return nil
    }

    static func encodedPlaybackChannelPair(left: Int, right: Int) -> UInt64 {
        let maxChannelIndex = CoreAudioDeviceQuery.maxChannelCount - 1
        let clampedLeft = UInt64(min(max(left, 0), maxChannelIndex))
        let clampedRight = UInt64(min(max(right, 0), maxChannelIndex))
        return (clampedLeft << 32) | clampedRight
    }

    static func decodedPlaybackChannelPair(
        _ encoded: UInt64
    ) -> (left: Int, right: Int) {
        (Int(encoded >> 32), Int(encoded & 0xFFFF_FFFF))
    }

    static func tapToOutputLatencyNanoseconds(
        inputTime: AudioTimeStamp,
        outputTime: AudioTimeStamp
    ) -> UInt64? {
        guard inputTime.mFlags.contains(.hostTimeValid),
              outputTime.mFlags.contains(.hostTimeValid),
              outputTime.mHostTime >= inputTime.mHostTime else {
            return nil
        }
        return AudioConvertHostTimeToNanos(outputTime.mHostTime - inputTime.mHostTime)
    }

    static func callbackTimingNanoseconds(
        inputTime: AudioTimeStamp,
        callbackHostTime: UInt64,
        outputTime: AudioTimeStamp
    ) -> (inputAge: UInt64, outputLead: UInt64)? {
        guard inputTime.mFlags.contains(.hostTimeValid),
              outputTime.mFlags.contains(.hostTimeValid),
              callbackHostTime >= inputTime.mHostTime,
              outputTime.mHostTime >= callbackHostTime else {
            return nil
        }
        return (
            inputAge: AudioConvertHostTimeToNanos(callbackHostTime - inputTime.mHostTime),
            outputLead: AudioConvertHostTimeToNanos(outputTime.mHostTime - callbackHostTime)
        )
    }

    static func tapInputChannelOffsets(
        physicalInputChannelCount: Int,
        aggregateInputChannelCount: Int,
        mainTapChannelCount: Int,
        systemSoundTapChannelCount: Int,
        mainTapIndex: Int = 0,
        systemSoundTapIndex: Int = 1
    ) -> (main: Int, systemSounds: Int)? {
        guard physicalInputChannelCount >= 0,
              mainTapChannelCount > 0,
              systemSoundTapChannelCount == mainTapChannelCount,
              Set([mainTapIndex, systemSoundTapIndex]) == Set([0, 1]),
              aggregateInputChannelCount == physicalInputChannelCount
                + mainTapChannelCount
                + systemSoundTapChannelCount else {
            return nil
        }
        return (
            main: physicalInputChannelCount
                + (mainTapIndex == 0 ? 0 : systemSoundTapChannelCount),
            systemSounds: physicalInputChannelCount
                + (systemSoundTapIndex == 0 ? 0 : mainTapChannelCount)
        )
    }

    static func inputStreamUsage(
        streamChannelCounts: [Int],
        tapChannelOffset: Int,
        tapChannelCount: Int
    ) -> [UInt32]? {
        guard tapChannelOffset >= 0,
              tapChannelCount > 0 else {
            return nil
        }
        let tapRange = tapChannelOffset..<(tapChannelOffset + tapChannelCount)
        var channelOffset = 0
        var enabledChannelCount = 0
        var usage: [UInt32] = []
        usage.reserveCapacity(streamChannelCounts.count)

        for channelCount in streamChannelCounts {
            guard channelCount > 0 else {
                return nil
            }
            let streamRange = channelOffset..<(channelOffset + channelCount)
            if streamRange.clamped(to: tapRange).isEmpty {
                usage.append(0)
            } else if tapRange.contains(streamRange.lowerBound),
                      tapRange.contains(streamRange.upperBound - 1) {
                usage.append(1)
                enabledChannelCount += channelCount
            } else {
                return nil
            }
            channelOffset = streamRange.upperBound
        }

        guard enabledChannelCount == tapChannelCount,
              channelOffset == tapRange.upperBound else {
            return nil
        }
        return usage
    }

    static func copyInputSamples(
        from buffers: UnsafeMutableAudioBufferListPointer,
        into samples: UnsafeMutableBufferPointer<Float>,
        frameCount: Int,
        channelCount: Int,
        sourceChannelOffset: Int
    ) {
        guard frameCount > 0,
              channelCount > 0,
              sourceChannelOffset >= 0,
              frameCount * channelCount <= samples.count else {
            return
        }
        if sourceChannelOffset == 0,
           buffers.count == 1,
           let data = buffers[0].mData?.assumingMemoryBound(to: Float.self),
           Int(buffers[0].mNumberChannels) == channelCount {
            let sampleCount = frameCount * channelCount
            if sampleCount <= Int(buffers[0].mDataByteSize) / MemoryLayout<Float>.stride,
               let destination = samples.baseAddress {
                destination.update(from: data, count: sampleCount)
                return
            }
        }

        for frame in 0..<frameCount {
            let sampleBase = frame * channelCount
            for channel in 0..<channelCount {
                samples[sampleBase + channel] = inputSample(
                    from: buffers,
                    frame: frame,
                    channel: sourceChannelOffset + channel
                )
            }
        }
    }

    @discardableResult
    static func mixInputSamples(
        from buffers: UnsafeMutableAudioBufferListPointer,
        into samples: UnsafeMutableBufferPointer<Float>,
        frameCount: Int,
        channelCount: Int,
        sourceChannelOffset: Int,
        preampGains: (left: Float, right: Float),
        incomingPreampGains: (left: Float, right: Float)? = nil,
        transition: EQTransitionRenderResult = EQTransitionRenderResult()
    ) -> UInt64 {
        guard frameCount > 0,
              channelCount > 0,
              sourceChannelOffset >= 0,
              frameCount * channelCount <= samples.count else {
            return 0
        }

        var saturatedSamples: UInt64 = 0
        let targetPreampGains = incomingPreampGains ?? preampGains
        for frame in 0..<frameCount {
            let sampleBase = frame * channelCount
            let incomingWeight = incomingPreampGains == nil
                ? 0
                : transition.incomingBlendWeight(frameOffset: frame)
            let leftGain = preampGains.left
                + (targetPreampGains.left - preampGains.left) * incomingWeight
            let rightGain = preampGains.right
                + (targetPreampGains.right - preampGains.right) * incomingWeight
            for channel in 0..<channelCount {
                let gain = channel == 1 ? rightGain : leftGain
                let additionalSample = inputSample(
                    from: buffers,
                    frame: frame,
                    channel: sourceChannelOffset + channel
                ) * gain
                guard additionalSample != 0 else {
                    continue
                }
                let mixed = samples[sampleBase + channel] + additionalSample
                let output = saturateOutputSample(mixed)
                samples[sampleBase + channel] = output.sample
                if output.saturated {
                    saturatedSamples += 1
                }
            }
        }
        return saturatedSamples
    }

    private static func saturateOutputSample(
        _ value: Float
    ) -> (sample: Float, saturated: Bool) {
        guard value.isFinite else {
            return (0, true)
        }
        let threshold: Float = 0.98
        if value > threshold {
            return (
                threshold + (1 - threshold) * tanh((value - threshold) / (1 - threshold)),
                true
            )
        }
        if value < -threshold {
            return (
                -threshold + (1 - threshold) * tanh((value + threshold) / (1 - threshold)),
                true
            )
        }
        return (value, false)
    }

    private static func inputSample(
        from buffers: UnsafeMutableAudioBufferListPointer,
        frame: Int,
        channel: Int
    ) -> Float {
        var remainingChannel = channel
        for buffer in buffers {
            let channels = Int(buffer.mNumberChannels)
            guard channels > 0 else {
                continue
            }
            guard remainingChannel < channels else {
                remainingChannel -= channels
                continue
            }
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else {
                return 0
            }
            let index = frame * channels + remainingChannel
            guard index >= 0,
                  index < Int(buffer.mDataByteSize) / MemoryLayout<Float>.stride else {
                return 0
            }
            return data[index]
        }
        return 0
    }

    static func monoDownmix(
        _ samples: UnsafeBufferPointer<Float>,
        frame: Int,
        sourceChannelCount: Int
    ) -> Float {
        guard frame >= 0 else {
            return 0
        }
        let sourceChannelCount = max(sourceChannelCount, 1)
        let sampleBaseResult = frame.multipliedReportingOverflow(
            by: sourceChannelCount
        )
        guard !sampleBaseResult.overflow else {
            return 0
        }
        let sampleBase = sampleBaseResult.partialValue
        guard sampleBase >= 0, sampleBase < samples.count else {
            return 0
        }
        guard sourceChannelCount > 1,
              sampleBase + 1 < samples.count else {
            return samples[sampleBase]
        }
        return (samples[sampleBase] + samples[sampleBase + 1]) * 0.5
    }

    static func copyInterleavedSamples(
        _ samples: UnsafeBufferPointer<Float>,
        sourceFrameOffset: Int,
        destinationFrameOffset: Int,
        frameCount: Int,
        sourceChannelCount: Int,
        destinationLeftChannel: Int = 0,
        destinationRightChannel: Int = 1,
        to buffers: UnsafeMutableAudioBufferListPointer
    ) {
        let sourceChannelCount = max(sourceChannelCount, 1)
        if buffers.count == 1,
           let data = buffers[0].mData?.assumingMemoryBound(to: Float.self),
           Int(buffers[0].mNumberChannels) == 1,
           sourceChannelCount > 1,
           frameCount > 0,
           sourceFrameOffset >= 0,
           destinationFrameOffset >= 0 {
            let destinationSamples = Int(buffers[0].mDataByteSize)
                / MemoryLayout<Float>.stride
            for frameIndex in 0..<frameCount
            where destinationFrameOffset + frameIndex < destinationSamples {
                data[destinationFrameOffset + frameIndex] = monoDownmix(
                    samples,
                    frame: sourceFrameOffset + frameIndex,
                    sourceChannelCount: sourceChannelCount
                )
            }
            return
        }

        if buffers.count == 1,
           let data = buffers[0].mData?.assumingMemoryBound(to: Float.self),
           Int(buffers[0].mNumberChannels) == sourceChannelCount,
           destinationLeftChannel == 0,
           destinationRightChannel == 1,
           frameCount > 0,
           sourceFrameOffset >= 0,
           destinationFrameOffset >= 0 {
            let copySamples = frameCount * sourceChannelCount
            let sourceSampleStart = sourceFrameOffset * sourceChannelCount
            let destinationSampleStart = destinationFrameOffset * sourceChannelCount
            let destinationSamples = Int(buffers[0].mDataByteSize)
                / MemoryLayout<Float>.stride
            if sourceSampleStart + copySamples <= samples.count,
               destinationSampleStart + copySamples <= destinationSamples,
               let source = samples.baseAddress {
                data.advanced(by: destinationSampleStart).update(
                    from: source.advanced(by: sourceSampleStart),
                    count: copySamples
                )
                return
            }
        }

        guard frameCount > 0,
              sourceFrameOffset >= 0,
              destinationFrameOffset >= 0 else {
            return
        }
        let sourceRightChannel = min(1, sourceChannelCount - 1)
        var globalChannelOffset = 0
        for bufferIndex in buffers.indices {
            let bufferChannels = Int(buffers[bufferIndex].mNumberChannels)
            guard bufferChannels > 0,
                  let data = buffers[bufferIndex].mData?
                    .assumingMemoryBound(to: Float.self) else {
                globalChannelOffset += max(bufferChannels, 0)
                continue
            }
            let destinationSampleCount = Int(buffers[bufferIndex].mDataByteSize)
                / MemoryLayout<Float>.stride
            let zeroStart = destinationFrameOffset * bufferChannels
            let zeroEnd = min(
                (destinationFrameOffset + frameCount) * bufferChannels,
                destinationSampleCount
            )
            if zeroStart < zeroEnd {
                data.advanced(by: zeroStart).update(
                    repeating: 0,
                    count: zeroEnd - zeroStart
                )
            }
            scatterMappedChannel(
                samples,
                sourceChannel: 0,
                sourceFrameOffset: sourceFrameOffset,
                sourceChannelCount: sourceChannelCount,
                localChannel: destinationLeftChannel - globalChannelOffset,
                destinationFrameOffset: destinationFrameOffset,
                frameCount: frameCount,
                bufferChannels: bufferChannels,
                destinationSampleCount: destinationSampleCount,
                into: data
            )
            scatterMappedChannel(
                samples,
                sourceChannel: sourceRightChannel,
                sourceFrameOffset: sourceFrameOffset,
                sourceChannelCount: sourceChannelCount,
                localChannel: destinationRightChannel - globalChannelOffset,
                destinationFrameOffset: destinationFrameOffset,
                frameCount: frameCount,
                bufferChannels: bufferChannels,
                destinationSampleCount: destinationSampleCount,
                into: data
            )
            globalChannelOffset += bufferChannels
        }
    }

    private static func scatterMappedChannel(
        _ samples: UnsafeBufferPointer<Float>,
        sourceChannel: Int,
        sourceFrameOffset: Int,
        sourceChannelCount: Int,
        localChannel: Int,
        destinationFrameOffset: Int,
        frameCount: Int,
        bufferChannels: Int,
        destinationSampleCount: Int,
        into data: UnsafeMutablePointer<Float>
    ) {
        guard localChannel >= 0, localChannel < bufferChannels else {
            return
        }
        for frameIndex in 0..<frameCount {
            let sourceIndex = (sourceFrameOffset + frameIndex)
                * sourceChannelCount + sourceChannel
            guard sourceIndex < samples.count else {
                continue
            }
            let destinationIndex = (destinationFrameOffset + frameIndex)
                * bufferChannels + localChannel
            guard destinationIndex < destinationSampleCount else {
                continue
            }
            data[destinationIndex] = samples[sourceIndex]
        }
    }

    static func missedRenderDeadlines(
        elapsedNanoseconds: UInt64,
        frameCount: Int,
        sampleRate: Double
    ) -> UInt64 {
        let expectedNanoseconds = renderPeriodNanoseconds(
            frameCount: frameCount,
            sampleRate: sampleRate
        )
        guard expectedNanoseconds > 0 else {
            return 0
        }
        let elapsedPeriods = elapsedNanoseconds / expectedNanoseconds
        return elapsedPeriods >= 2 ? elapsedPeriods - 1 : 0
    }

    static func renderOverranPeriod(
        elapsedNanoseconds: UInt64,
        frameCount: Int,
        sampleRate: Double
    ) -> Bool {
        let expectedNanoseconds = renderPeriodNanoseconds(
            frameCount: frameCount,
            sampleRate: sampleRate
        )
        return expectedNanoseconds > 0 && elapsedNanoseconds > expectedNanoseconds
    }

    static func renderPeriodNanoseconds(
        frameCount: Int,
        sampleRate: Double
    ) -> UInt64 {
        guard frameCount > 0,
              sampleRate.isFinite,
              sampleRate > 0 else {
            return 0
        }
        return UInt64(
            max((Double(frameCount) * 1_000_000_000 / sampleRate).rounded(), 1)
        )
    }

    static func timestampSlopeAgrees(
        frameCount: Int,
        sampleRate: Double,
        sampleTimeDeltaFrames: Double,
        hostIntervalErrorNanoseconds: Int64,
        rateScalar: Double,
        rateScalarIsValid: Bool
    ) -> Bool {
        guard frameCount > 0,
              sampleRate.isFinite,
              sampleRate > 0,
              abs(sampleTimeDeltaFrames) < 0.5 else {
            return false
        }
        if rateScalarIsValid,
           (!rateScalar.isFinite || abs(rateScalar - 1) > 0.01) {
            return false
        }
        let callbackPeriodNanoseconds = Double(frameCount) * 1_000_000_000 / sampleRate
        let toleranceNanoseconds = max(callbackPeriodNanoseconds * 0.25, 50_000)
        return abs(Double(hostIntervalErrorNanoseconds)) <= toleranceNanoseconds
    }

    static func deviceClockSlopeAgrees(
        sampleTimeDeltaFrames: Double,
        hostTimeDeltaNanoseconds: UInt64,
        nominalSampleRate: Double,
        rateScalar: Double,
        rateScalarIsValid: Bool
    ) -> Bool {
        guard sampleTimeDeltaFrames.isFinite,
              sampleTimeDeltaFrames > 0,
              hostTimeDeltaNanoseconds > 0,
              nominalSampleRate.isFinite,
              nominalSampleRate > 0 else {
            return false
        }
        if rateScalarIsValid,
           (!rateScalar.isFinite || abs(rateScalar - 1) > 0.02) {
            return false
        }
        let expectedFrames = Double(hostTimeDeltaNanoseconds)
            * nominalSampleRate / 1_000_000_000
        guard expectedFrames >= 1 else {
            return false
        }
        return abs(sampleTimeDeltaFrames - expectedFrames) / expectedFrames <= 0.02
    }

    private static func deviceClockSlopeIsStable(
        deviceID: AudioObjectID,
        nominalSampleRate: Double,
        observationDuration: TimeInterval
    ) throws -> Bool {
        let first = try currentDeviceTime(deviceID: deviceID)
        Thread.sleep(forTimeInterval: observationDuration)
        let second = try currentDeviceTime(deviceID: deviceID)
        guard first.mFlags.contains(.sampleTimeValid),
              first.mFlags.contains(.hostTimeValid),
              second.mFlags.contains(.sampleTimeValid),
              second.mFlags.contains(.hostTimeValid),
              second.mHostTime > first.mHostTime else {
            return false
        }
        return deviceClockSlopeAgrees(
            sampleTimeDeltaFrames: second.mSampleTime - first.mSampleTime,
            hostTimeDeltaNanoseconds: AudioConvertHostTimeToNanos(
                second.mHostTime - first.mHostTime
            ),
            nominalSampleRate: nominalSampleRate,
            rateScalar: second.mRateScalar,
            rateScalarIsValid: second.mFlags.contains(.rateScalarValid)
        )
    }

    private static func currentDeviceTime(deviceID: AudioObjectID) throws -> AudioTimeStamp {
        var time = AudioTimeStamp()
        time.mFlags = [
            .sampleTimeValid,
            .hostTimeValid,
            .rateScalarValid
        ]
        try checkOSStatus(
            AudioDeviceGetCurrentTime(deviceID, &time),
            operation: "AudioDeviceGetCurrentTime(headset promotion)"
        )
        return time
    }

    public static func shouldUseSeparateClockBackend(for output: AudioOutputDevice) -> Bool {
#if GLASSEQ_FORCE_COMBINED_HEADSET
        false
#else
        output.isBluetoothTransport && output.nominalSampleRate <= 24_000
#endif
    }

    private static func promotedHeadsetRoute(
        for output: AudioOutputDevice
    ) -> PromotedHeadsetRoute {
        PromotedHeadsetRoute(
            outputUID: output.uid,
            nominalSampleRate: Int64(output.nominalSampleRate.rounded())
        )
    }

    private static func deferredColdStartupRoute(
        for output: AudioOutputDevice
    ) -> DeferredColdStartupRoute {
        DeferredColdStartupRoute(
            outputUID: output.uid,
            nominalSampleRate: Int64(output.nominalSampleRate.rounded())
        )
    }

    private static func latencyMetadata(deviceID: AudioObjectID) -> AudioDeviceLatencyMetadata {
        AudioDeviceLatencyMetadata(
            objectID: deviceID,
            bufferFrameSize: try? CoreAudioDeviceQuery.getUInt32Property(
                objectID: deviceID,
                selector: kAudioDevicePropertyBufferFrameSize,
                scope: kAudioObjectPropertyScopeGlobal
            ),
            inputStreamChannelCounts: try? CoreAudioDeviceQuery.streamChannelCounts(
                objectID: deviceID,
                scope: kAudioDevicePropertyScopeInput
            ),
            outputStreamChannelCounts: try? CoreAudioDeviceQuery.streamChannelCounts(
                objectID: deviceID,
                scope: kAudioDevicePropertyScopeOutput
            ),
            inputLatencyFrames: try? CoreAudioDeviceQuery.getUInt32Property(
                objectID: deviceID,
                selector: kAudioDevicePropertyLatency,
                scope: kAudioDevicePropertyScopeInput
            ),
            inputSafetyOffsetFrames: try? CoreAudioDeviceQuery.getUInt32Property(
                objectID: deviceID,
                selector: kAudioDevicePropertySafetyOffset,
                scope: kAudioDevicePropertyScopeInput
            ),
            inputSafetyOffsetSettable: propertyIsSettable(
                objectID: deviceID,
                selector: kAudioDevicePropertySafetyOffset,
                scope: kAudioDevicePropertyScopeInput
            ),
            outputLatencyFrames: try? CoreAudioDeviceQuery.getUInt32Property(
                objectID: deviceID,
                selector: kAudioDevicePropertyLatency,
                scope: kAudioDevicePropertyScopeOutput
            ),
            outputSafetyOffsetFrames: try? CoreAudioDeviceQuery.getUInt32Property(
                objectID: deviceID,
                selector: kAudioDevicePropertySafetyOffset,
                scope: kAudioDevicePropertyScopeOutput
            ),
            outputSafetyOffsetSettable: propertyIsSettable(
                objectID: deviceID,
                selector: kAudioDevicePropertySafetyOffset,
                scope: kAudioDevicePropertyScopeOutput
            )
        )
    }

    private static func propertyIsSettable(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> Bool? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var isSettable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(objectID, &address, &isSettable) == noErr else {
            return nil
        }
        return isSettable.boolValue
    }

    static func profileUpdateOutput(
        _ output: AudioOutputDevice?
    ) throws -> AudioOutputDevice {
        guard let output else {
            throw AudioEngineProfileUpdateUnavailable()
        }
        return output
    }

}
