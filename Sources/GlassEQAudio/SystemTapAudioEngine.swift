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
        averageOutputLeadNanoseconds: Double = 0
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

public final class SystemTapAudioEngine: @unchecked Sendable {
    private static let preferredAggregateBufferFrameSize: UInt32 = 16
    private static let maximumSupportedCallbackFrames = 8192
    private static let systemSoundServerBundleID = "systemsoundserverd"
    private static let headsetClockProbeDuration: TimeInterval = 0.5
    private static let headsetAggregateValidationDuration: TimeInterval = 0.75
    static let runtimeRingCapacityFrames = SeparateClockAudioBackend.runtimeRingCapacityFrames

    private enum ActiveBackend: Equatable {
        case combinedAggregate
        case separateClock
    }

    private struct PromotedHeadsetRoute: Equatable {
        var outputUID: String
        var nominalSampleRate: Int64
    }

    struct BufferFrameSizeRestoration: Equatable, Sendable {
        var uid: String
        var originalFrameSize: UInt32
    }

    struct SampleRateRestoration: Equatable, Sendable {
        var uid: String
        var originalSampleRate: Double
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
        private let maxCallbackFrames: Int
        private var dspTransition: RealtimeEQTransition
        private var activeSystemSoundPreampGains: (left: Float, right: Float)
        private var outputFade: RealtimeOutputFade
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
            profile: EQProfile,
            sampleRate: Double,
            channelCount: Int,
            inputChannelOffset: Int,
            systemSoundInputChannelOffset: Int,
            maxCallbackFrames: Int
        ) {
            self.channelCount = max(channelCount, 1)
            self.sampleRate = sampleRate
            self.inputChannelOffset = max(inputChannelOffset, 0)
            self.systemSoundInputChannelOffset = max(systemSoundInputChannelOffset, 0)
            self.maxCallbackFrames = maxCallbackFrames
            self.outputFade = RealtimeOutputFade(sampleRate: sampleRate)
            self.scratchSamples = Array(
                repeating: 0,
                count: maxCallbackFrames * self.channelCount
            )
            let renderConfiguration = EQRenderConfiguration(
                profile: profile,
                sampleRate: sampleRate,
                channelCount: self.channelCount,
                maximumUsableFrequency: EQRouteFrequencyPolicy.maximumUsableFrequency(
                    sampleRate: sampleRate
                )
            )
            self.dspTransition = RealtimeEQTransition(
                activeProcessor: EQProcessor(renderConfiguration: renderConfiguration),
                maximumFrameCount: maxCallbackFrames,
                channelCount: self.channelCount,
                sampleRate: sampleRate
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

            recordTimestampContinuity(
                inputTime: inputTime,
                inputFrameCount: inputFrameCount,
                outputTime: outputTime,
                outputFrameCount: outputFrameCount
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

        func waitForSilentWarmUp(
            minimumCallbacks: UInt64,
            timeout: TimeInterval
        ) {
            let initialCallbacks = renderCallbackObservations.load(ordering: .acquiring)
            let deadline = DispatchTime.now().uptimeNanoseconds
                + UInt64(max(timeout, 0) * 1_000_000_000)
            while renderCallbackObservations.load(ordering: .acquiring)
                    < initialCallbacks + minimumCallbacks,
                  DispatchTime.now().uptimeNanoseconds < deadline {
                Thread.sleep(forTimeInterval: 0.001)
            }
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
                    : Double(totalOutputLead) / Double(timingObservations)
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
        ) {
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
        // Current buffer-size restorations belong to the separate-clock backend. This
        // one-time pass only repairs settings persisted by older combined-backend builds.
        Self.restorePersistedDeviceSettings(at: restorationStoreURL)
    }

    deinit {
        stop()
    }

    public func aggregateRouteFingerprint(
        for output: AudioOutputDevice
    ) throws -> AggregateAudioRouteFingerprint? {
        if Self.shouldUseSeparateClockBackend(for: output) {
            let isActivePromotedRoute = activeBackend.withLock { $0 } == .combinedAggregate
                && control.withLock { state in
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
        let shouldUseSeparateClock = Self.shouldUseSeparateClockBackend(for: output)
            && !promotedHeadsetRoute.withLock { route in
                route == Self.promotedHeadsetRoute(for: output)
            }
        if shouldUseSeparateClock {
            try startSeparateClockBackend(output: output, profile: profile)
            return
        }

        if !Self.shouldUseSeparateClockBackend(for: output) {
            promotedHeadsetRoute.withLock { $0 = nil }
        }

        try startCombinedAggregate(output: output, profile: profile)
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
            activeBackend.withLock { $0 = .separateClock }
            try separateClockBackend.start(output: output, profile: profile)
            return
        }

        try separateClockBackend.prepareOutputForHandoff(
            output: output,
            profile: profile
        )
        stopCombinedResourcesSerialized()
        activeBackend.withLock { $0 = .separateClock }
        _ = try separateClockBackend.activatePreparedOutputHandoff()
    }

    private func startCombinedAggregate(
        output: AudioOutputDevice,
        profile: EQProfile
    ) throws {
        let isSeparateClockHandoff = activeBackend.withLock { $0 } == .separateClock
        control.withLock { state in
            state.status = .starting
        }

        var taps: CombinedTapSet?
        var preparedAggregate: PreparedCombinedAggregate?

        do {
            let route = try prepareCombinedRoute(output: output)
            let targetFrameSize = control.withLock { $0.preferredAggregateBufferFrameSize }
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

            let prepared = try prepareCombinedAggregate(
                taps: taps,
                route: route,
                profile: profile,
                targetFrameSize: targetFrameSize
            )
            preparedAggregate = prepared

            if isSeparateClockHandoff {
                separateClockBackend.quiesceOutputForCombinedHandoff()
            }
            try checkOSStatus(
                AudioDeviceStart(prepared.deviceID, prepared.ioProcID),
                operation: "AudioDeviceStart(combined aggregate)"
            )
            prepared.runtime.waitForSilentWarmUp(minimumCallbacks: 32, timeout: 0.1)
            prepared.runtime.activate()

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
        } catch {
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

            if let installedTaps {
                prepareTapSetForDirectPlayback(installedTaps)
            }
            let installedTapsMatch = installedTaps?.main == taps?.main
                && installedTaps?.systemSounds == taps?.systemSounds
            if let taps, !installedTapsMatch {
                prepareTapSetForDirectPlayback(taps)
            }
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
            let aggregateCreation = try createCombinedAggregateDevice(
                tapID: taps.main,
                systemSoundTapID: taps.systemSounds,
                output: route.output
            )
            aggregateDeviceID = aggregateCreation.deviceID
            try waitUntilAggregateIsAlive(aggregateDeviceID)
            let tapUIDOrder = try verifyAggregateComposition(
                aggregateDeviceID,
                output: route.output,
                expectedTapDriftCompensation: [
                    aggregateCreation.mainTapUID: true,
                    aggregateCreation.systemSoundTapUID: true
                ]
            )

            let aggregate = try tuneAggregateBufferFrameSize(
                deviceID: aggregateDeviceID,
                targetFrameSize: targetFrameSize
            )
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

            let preparedRuntime = AudioRuntime(
                profile: profile,
                sampleRate: aggregate.nominalSampleRate,
                channelCount: mainTapChannelCount,
                inputChannelOffset: tapInputChannelOffsets.main,
                systemSoundInputChannelOffset: tapInputChannelOffsets.systemSounds,
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
            try configureInputStreamUsage(
                deviceID: aggregateDeviceID,
                ioProcID: preparedIOProcID,
                tapInputChannelOffset: min(
                    tapInputChannelOffsets.main,
                    tapInputChannelOffsets.systemSounds
                ),
                tapChannelCount: mainTapChannelCount + systemSoundTapChannelCount
            )

            var activeOutput = route.output
            activeOutput.bufferFrameSize = aggregate.bufferFrameSize
            return PreparedCombinedAggregate(
                taps: taps,
                deviceID: aggregateDeviceID,
                ioProcID: preparedIOProcID,
                runtime: preparedRuntime,
                output: activeOutput,
                profile: profile
            )
        } catch {
            if aggregateDeviceID != kAudioObjectUnknown, let ioProcID {
                _ = AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
            }
            if aggregateDeviceID != kAudioObjectUnknown {
                _ = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            }
            runtime?.drainDSPConfigBoxes()
            throw error
        }
    }

    public func attemptHeadsetAggregatePromotion() throws -> HeadsetAggregatePromotionResult {
        try topologyOperation.withLock { _ in
            try attemptHeadsetAggregatePromotionSerialized()
        }
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
            let promotionError = error
            do {
                try restoreSeparateClockBackend(afterRejectedPromotion: context)
            } catch let rollbackError {
                throw AudioEngineInternalError(
                    message: "Headset aggregate promotion failed and the compatibility path could not be restored: \(promotionError.localizedDescription); rollback: \(rollbackError.localizedDescription)"
                )
            }
            return .aggregateUnstable
        }

        Thread.sleep(forTimeInterval: Self.headsetAggregateValidationDuration)
        let metrics = snapshotMetrics()
        guard metrics.pairedTimestampDiscontinuities == 0,
              case .running(let output) = state else {
            try restoreSeparateClockBackend(afterRejectedPromotion: context)
            return .aggregateUnstable
        }
        promotedHeadsetRoute.withLock {
            $0 = Self.promotedHeadsetRoute(for: output)
        }
        return .promoted(output)
    }

    private func restoreSeparateClockBackend(
        afterRejectedPromotion context: (output: AudioOutputDevice, profile: EQProfile)
    ) throws {
        promotedHeadsetRoute.withLock { $0 = nil }
        if activeBackend.withLock({ $0 }) == .separateClock,
           separateClockBackend.activeOutputAndProfile() != nil {
            return
        }
        try startSeparateClockBackend(
            output: CoreAudioDeviceQuery.outputDevice(id: context.output.id),
            profile: context.profile
        )
    }

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
        return control.withLock { state in
            guard let runtime = state.runtime,
                  let activeProfile = state.activeProfile else {
                return false
            }
            let maximumUsableFrequency = EQRouteFrequencyPolicy.maximumUsableFrequency(
                sampleRate: runtime.sampleRate
            )
            guard Self.canHotSwapDSP(
                from: activeProfile,
                to: profile,
                sampleRate: runtime.sampleRate,
                channelCount: runtime.channelCount,
                maximumUsableFrequency: maximumUsableFrequency
            ) else {
                return false
            }
            runtime.setProgrammeComparisonSelection(.equalized)
            runtime.drainDSPConfigBoxes()
            runtime.publishPendingDSPConfig(
                EQRenderConfiguration(
                    profile: profile,
                    sampleRate: runtime.sampleRate,
                    channelCount: runtime.channelCount,
                    maximumUsableFrequency: maximumUsableFrequency
                )
            )
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
        return control.withLock { state in
            guard let runtime = state.runtime else {
                return false
            }
            let maximumUsableFrequency = EQRouteFrequencyPolicy.maximumUsableFrequency(
                sampleRate: runtime.sampleRate
            )
            let equalizedConfig = EQRenderConfiguration(
                profile: profile,
                sampleRate: runtime.sampleRate,
                channelCount: runtime.channelCount,
                maximumUsableFrequency: maximumUsableFrequency
            )
            let referenceConfig = EQRenderConfiguration(
                profile: profile.programmeComparisonReference,
                sampleRate: runtime.sampleRate,
                channelCount: runtime.channelCount,
                maximumUsableFrequency: maximumUsableFrequency
            )
            guard equalizedConfig.isNumericallySafe,
                  referenceConfig.isNumericallySafe else {
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
            separateClockBackend.stop()
            stopCombinedResourcesSerialized(restoringDirectPlayback: true)
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
        // Once the IOProc stops reading a mutedWhenTapped tap, HAL resumes the source's
        // direct route. Do this before dismantling the aggregate so active clients do not
        // have to recover from an unread, always-muted tap.
        if restoringDirectPlayback, let detachedTaps {
            prepareTapSetForDirectPlayback(detachedTaps)
        }
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
        if detached.deviceID != kAudioObjectUnknown, let ioProcID = detached.ioProcID {
            _ = AudioDeviceStop(detached.deviceID, ioProcID)
            _ = AudioDeviceDestroyIOProcID(detached.deviceID, ioProcID)
        }
        let records = detached.runtime?.snapshotTimestampProbeRecords() ?? []
        if detached.deviceID != kAudioObjectUnknown {
            _ = AudioHardwareDestroyAggregateDevice(detached.deviceID)
        }
        detached.runtime?.drainDSPConfigBoxes()
        return records
    }

    private func prepareTapSetForDirectPlayback(_ taps: CombinedTapSet) {
        if taps.main != kAudioObjectUnknown {
            try? CoreAudioDeviceQuery.setProcessTapMuteBehavior(
                .mutedWhenTapped,
                tapID: taps.main
            )
        }
        if taps.systemSounds != kAudioObjectUnknown {
            try? CoreAudioDeviceQuery.setProcessTapMuteBehavior(
                .mutedWhenTapped,
                tapID: taps.systemSounds
            )
        }
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
        if taps.main != kAudioObjectUnknown {
            _ = AudioHardwareDestroyProcessTap(taps.main)
        }
        if taps.systemSounds != kAudioObjectUnknown {
            _ = AudioHardwareDestroyProcessTap(taps.systemSounds)
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
        try checkOSStatus(
            AudioHardwareCreateProcessTap(mainDescription, &mainTapID),
            operation: "AudioHardwareCreateProcessTap(main)"
        )
        do {
            var systemSoundTapID = AudioObjectID(kAudioObjectUnknown)
            try checkOSStatus(
                AudioHardwareCreateProcessTap(systemSoundDescription, &systemSoundTapID),
                operation: "AudioHardwareCreateProcessTap(system sounds)"
            )
            return (mainTapID, systemSoundTapID)
        } catch {
            _ = AudioHardwareDestroyProcessTap(mainTapID)
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
        description.muteBehavior = .muted
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
        description.muteBehavior = .muted
        description.isMixdown = false
        description.bundleIDs = [Self.systemSoundServerBundleID]
        description.isProcessRestoreEnabled = true
        return description
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
        try checkOSStatus(
            AudioHardwareCreateAggregateDevice(description as CFDictionary, &deviceID),
            operation: "AudioHardwareCreateAggregateDevice(combined)"
        )
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
        let deadline = Date().addingTimeInterval(3)
        var lastError: Error?
        repeat {
            do {
                if try CoreAudioDeviceQuery.isDeviceAlive(id: deviceID) {
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

    private func tuneAggregateBufferFrameSize(
        deviceID: AudioObjectID,
        targetFrameSize: UInt32
    ) throws -> AudioOutputDevice {
        var aggregate = try CoreAudioDeviceQuery.outputDevice(id: deviceID)
        let range = try CoreAudioDeviceQuery.bufferFrameSizeRangeValue(objectID: deviceID)
        let requested = min(max(targetFrameSize, range.minimum), range.maximum)
        guard aggregate.bufferFrameSize != requested else {
            return aggregate
        }
        do {
            try CoreAudioDeviceQuery.setBufferFrameSize(requested, objectID: deviceID)
            for attempt in 0..<3 {
                aggregate = try CoreAudioDeviceQuery.outputDevice(id: deviceID)
                if aggregate.bufferFrameSize == requested {
                    return aggregate
                }
                if attempt < 2 {
                    Thread.sleep(forTimeInterval: 0.01)
                }
            }
        } catch {
            return aggregate
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
        try checkOSStatus(
            AudioDeviceCreateIOProcIDWithBlock(
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
            },
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
        maximumUsableFrequency: Double? = nil
    ) -> Bool {
        EQRenderConfiguration(
            profile: nextProfile,
            sampleRate: sampleRate,
            channelCount: channelCount,
            maximumUsableFrequency: maximumUsableFrequency
        ).isNumericallySafe
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

    static func tapInputChannelOffset(
        physicalInputChannelCount: Int,
        aggregateInputChannelCount: Int,
        tapChannelCount: Int
    ) -> Int? {
        guard physicalInputChannelCount >= 0,
              tapChannelCount > 0,
              aggregateInputChannelCount == physicalInputChannelCount + tapChannelCount else {
            return nil
        }
        return physicalInputChannelCount
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

    static func preferredBufferFrameSize(for _: AudioOutputDevice) -> UInt32 {
        preferredAggregateBufferFrameSize
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

    static func restoreSampleRateRestoration(
        _ restoration: SampleRateRestoration,
        outputForUID: (String) throws -> AudioOutputDevice? =
            CoreAudioDeviceQuery.outputDevice(uid:),
        setSampleRate: (Double, AudioObjectID) throws -> Void =
            CoreAudioDeviceQuery.setNominalSampleRate(_:objectID:)
    ) -> Bool {
        do {
            guard let output = try outputForUID(restoration.uid) else {
                return false
            }
            guard abs(output.nominalSampleRate - restoration.originalSampleRate) >= 1 else {
                return true
            }
            try setSampleRate(restoration.originalSampleRate, output.id)
            guard let verifiedOutput = try outputForUID(restoration.uid) else {
                return false
            }
            return abs(
                verifiedOutput.nominalSampleRate - restoration.originalSampleRate
            ) < 1
        } catch {
            return false
        }
    }

    static func restoreBufferFrameSizeRestoration(
        _ restoration: BufferFrameSizeRestoration,
        outputForUID: (String) throws -> AudioOutputDevice? =
            CoreAudioDeviceQuery.outputDevice(uid:),
        setBufferFrameSize: (UInt32, AudioObjectID) throws -> Void =
            CoreAudioDeviceQuery.setBufferFrameSize(_:objectID:)
    ) -> Bool {
        do {
            guard let output = try outputForUID(restoration.uid) else {
                return false
            }
            guard output.bufferFrameSize != restoration.originalFrameSize else {
                return true
            }
            try setBufferFrameSize(restoration.originalFrameSize, output.id)
            guard let verifiedOutput = try outputForUID(restoration.uid) else {
                return false
            }
            return verifiedOutput.bufferFrameSize == restoration.originalFrameSize
        } catch {
            return false
        }
    }

    static func restorePersistedDeviceSettings(
        at url: URL,
        outputForUID: (String) throws -> AudioOutputDevice? =
            CoreAudioDeviceQuery.outputDevice(uid:),
        setSampleRate: (Double, AudioObjectID) throws -> Void =
            CoreAudioDeviceQuery.setNominalSampleRate(_:objectID:),
        setBufferFrameSize: (UInt32, AudioObjectID) throws -> Void =
            CoreAudioDeviceQuery.setBufferFrameSize(_:objectID:)
    ) {
        var records = PersistedAudioDeviceRestorationStore.load(from: url)
        guard !records.isEmpty else {
            return
        }

        for (uid, record) in records {
            var updated = record
            if let originalSampleRate = record.originalSampleRate,
               restoreSampleRateRestoration(
                   SampleRateRestoration(
                       uid: uid,
                       originalSampleRate: originalSampleRate
                   ),
                   outputForUID: outputForUID,
                   setSampleRate: setSampleRate
               ) {
                updated.originalSampleRate = nil
            }
            if let originalBufferFrameSize = record.originalBufferFrameSize,
               restoreBufferFrameSizeRestoration(
                   BufferFrameSizeRestoration(
                       uid: uid,
                       originalFrameSize: originalBufferFrameSize
                   ),
                   outputForUID: outputForUID,
                   setBufferFrameSize: setBufferFrameSize
               ) {
                updated.originalBufferFrameSize = nil
            }
            records[uid] = updated.isEmpty ? nil : updated
        }
        try? PersistedAudioDeviceRestorationStore.save(records, to: url)
    }

}
