import Darwin
import Foundation
import GlassEQCore

private struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer {
            unlock()
        }
        return try body()
    }
}

public enum SettingsPipeProcessSignalPolicy {
    private static let ignoreSIGPIPEOnce: Void = {
        _ = Darwin.signal(SIGPIPE, SIG_IGN)
    }()

    public static func ignoreBrokenPipeSignal() {
        _ = ignoreSIGPIPEOnce
    }
}

public enum SettingsImportFormat: String, CaseIterable, Codable, Identifiable, Sendable {
    case autoEQ = "AutoEQ / EqualizerAPO"
    case rew = "REW"

    public var id: String { rawValue }
}

public enum SettingsProfileKind: String, Codable, Sendable {
    case graphic10
    case graphic31
    case parametric
    case convolution
}

public enum SettingsAggregateBufferMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case automatic
    case frames16
    case frames32
    case frames64

    public var id: String { rawValue }
}

public enum SettingsSection: String, Codable, Equatable, Sendable {
    case output
}

public struct SettingsAggregateBufferDTO: Codable, Equatable, Sendable {
    public var mode: SettingsAggregateBufferMode
    public var automaticFrameSize: UInt32
    public var isAvailable: Bool

    public init(
        mode: SettingsAggregateBufferMode = .automatic,
        automaticFrameSize: UInt32 = 16,
        isAvailable: Bool = false
    ) {
        self.mode = mode
        self.automaticFrameSize = automaticFrameSize
        self.isAvailable = isAvailable
    }

    private enum CodingKeys: String, CodingKey {
        case mode
        case automaticFrameSize
        case isAvailable
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            mode: try container.decodeIfPresent(
                SettingsAggregateBufferMode.self,
                forKey: .mode
            ) ?? .automatic,
            automaticFrameSize: try container.decodeIfPresent(
                UInt32.self,
                forKey: .automaticFrameSize
            ) ?? 16,
            isAvailable: try container.decodeIfPresent(
                Bool.self,
                forKey: .isAvailable
            ) ?? false
        )
    }
}

public enum SettingsAudioHealth: String, Codable, Equatable, Sendable {
    case stopped
    case stable
    case recovering
    case needsAttention
}

public enum SettingsAudioRouteMode: String, Codable, Equatable, Sendable {
    case unavailable
    case lowLatency
    case compatibility
    case headsetCompatibility
}

public enum SettingsAudioRecoveryReason: String, Codable, Equatable, Sendable {
    case renderStall
    case deadlineMisses
    case timestampDiscontinuity
    case headsetInstability
    case playbackUnderrun
    case adaptiveRenderFailure
}

public struct SettingsAudioStatusDTO: Codable, Equatable, Sendable {
    public var health: SettingsAudioHealth
    public var routeMode: SettingsAudioRouteMode
    public var isUsingSaferBuffer: Bool

    public init(
        health: SettingsAudioHealth = .stopped,
        routeMode: SettingsAudioRouteMode = .unavailable,
        isUsingSaferBuffer: Bool = false
    ) {
        self.health = health
        self.routeMode = routeMode
        self.isUsingSaferBuffer = isUsingSaferBuffer
    }
}

public struct SettingsAudioRouteDTO: Codable, Equatable, Sendable {
    public var transport: String
    public var observedDeviceSampleRate: Double
    public var activeDeviceSampleRate: Double
    public var processingSampleRate: Double
    public var nativeOutputStreamIndex: Int?
    public var physicalDeviceBufferFrameSize: UInt32?
    public var aggregateBufferFrameSize: UInt32?
    public var physicalOutputStreamChannelCounts: [Int]
    public var aggregateInputStreamChannelCounts: [Int]
    public var aggregateOutputStreamChannelCounts: [Int]
    public var physicalInputSafetyOffsetFrames: UInt32?
    public var physicalOutputSafetyOffsetFrames: UInt32?
    public var aggregateInputSafetyOffsetFrames: UInt32?
    public var aggregateOutputSafetyOffsetFrames: UInt32?

    public init(
        transport: String = "Unknown",
        observedDeviceSampleRate: Double = 0,
        activeDeviceSampleRate: Double = 0,
        processingSampleRate: Double = 0,
        nativeOutputStreamIndex: Int? = nil,
        physicalDeviceBufferFrameSize: UInt32? = nil,
        aggregateBufferFrameSize: UInt32? = nil,
        physicalOutputStreamChannelCounts: [Int] = [],
        aggregateInputStreamChannelCounts: [Int] = [],
        aggregateOutputStreamChannelCounts: [Int] = [],
        physicalInputSafetyOffsetFrames: UInt32? = nil,
        physicalOutputSafetyOffsetFrames: UInt32? = nil,
        aggregateInputSafetyOffsetFrames: UInt32? = nil,
        aggregateOutputSafetyOffsetFrames: UInt32? = nil
    ) {
        self.transport = transport
        self.observedDeviceSampleRate = observedDeviceSampleRate
        self.activeDeviceSampleRate = activeDeviceSampleRate
        self.processingSampleRate = processingSampleRate
        self.nativeOutputStreamIndex = nativeOutputStreamIndex
        self.physicalDeviceBufferFrameSize = physicalDeviceBufferFrameSize
        self.aggregateBufferFrameSize = aggregateBufferFrameSize
        self.physicalOutputStreamChannelCounts = physicalOutputStreamChannelCounts
        self.aggregateInputStreamChannelCounts = aggregateInputStreamChannelCounts
        self.aggregateOutputStreamChannelCounts = aggregateOutputStreamChannelCounts
        self.physicalInputSafetyOffsetFrames = physicalInputSafetyOffsetFrames
        self.physicalOutputSafetyOffsetFrames = physicalOutputSafetyOffsetFrames
        self.aggregateInputSafetyOffsetFrames = aggregateInputSafetyOffsetFrames
        self.aggregateOutputSafetyOffsetFrames = aggregateOutputSafetyOffsetFrames
    }
}

public struct SettingsAudioObservationDTO: Codable, Equatable, Sendable {
    public var resetAt: Date?
    public var observationDurationSeconds: Double
    public var runtimeStartedAt: Date?
    public var runtimeDurationSeconds: Double

    public init(
        resetAt: Date? = nil,
        observationDurationSeconds: Double = 0,
        runtimeStartedAt: Date? = nil,
        runtimeDurationSeconds: Double = 0
    ) {
        self.resetAt = resetAt
        self.observationDurationSeconds = observationDurationSeconds
        self.runtimeStartedAt = runtimeStartedAt
        self.runtimeDurationSeconds = runtimeDurationSeconds
    }
}

public struct SettingsAudioRecoveryDTO: Codable, Equatable, Sendable {
    public var runtimeRebuilds: UInt64
    public var automaticRecoveries: UInt64
    public var bufferEscalations: UInt64
    public var headsetFallbacks: UInt64
    public var lastReason: SettingsAudioRecoveryReason?
    public var lastRecoveryAt: Date?

    public init(
        runtimeRebuilds: UInt64 = 0,
        automaticRecoveries: UInt64 = 0,
        bufferEscalations: UInt64 = 0,
        headsetFallbacks: UInt64 = 0,
        lastReason: SettingsAudioRecoveryReason? = nil,
        lastRecoveryAt: Date? = nil
    ) {
        self.runtimeRebuilds = runtimeRebuilds
        self.automaticRecoveries = automaticRecoveries
        self.bufferEscalations = bufferEscalations
        self.headsetFallbacks = headsetFallbacks
        self.lastReason = lastReason
        self.lastRecoveryAt = lastRecoveryAt
    }
}

public struct SettingsAudioDiagnosticsDTO: Codable, Equatable, Sendable {
    public var status: SettingsAudioStatusDTO
    public var route: SettingsAudioRouteDTO
    public var observation: SettingsAudioObservationDTO
    public var recovery: SettingsAudioRecoveryDTO

    public init(
        status: SettingsAudioStatusDTO = SettingsAudioStatusDTO(),
        route: SettingsAudioRouteDTO = SettingsAudioRouteDTO(),
        observation: SettingsAudioObservationDTO = SettingsAudioObservationDTO(),
        recovery: SettingsAudioRecoveryDTO = SettingsAudioRecoveryDTO()
    ) {
        self.status = status
        self.route = route
        self.observation = observation
        self.recovery = recovery
    }
}

public struct SettingsAudioCallbackSizeObservationDTO: Codable, Equatable, Sendable {
    public var frameCount: Int?
    public var observations: UInt64

    public init(frameCount: Int?, observations: UInt64) {
        self.frameCount = frameCount
        self.observations = observations
    }
}

public struct SettingsAudioRenderTimingDTO: Codable, Equatable, Sendable {
    public var callbackStartLatenessObservations: UInt64
    public var callbackStartLatenessP50Nanoseconds: UInt64
    public var callbackStartLatenessP99Nanoseconds: UInt64
    public var callbackStartLatenessP999Nanoseconds: UInt64
    public var callbackStartLatenessP9999Nanoseconds: UInt64
    public var maximumCallbackStartLatenessNanoseconds: UInt64
    public var directHeadObservations: UInt64
    public var directHeadP50Nanoseconds: UInt64
    public var directHeadP99Nanoseconds: UInt64
    public var directHeadP999Nanoseconds: UInt64
    public var directHeadP9999Nanoseconds: UInt64
    public var maximumDirectHeadNanoseconds: UInt64
    public var tailWorkObservations: UInt64
    public var tailWorkP50Nanoseconds: UInt64
    public var tailWorkP99Nanoseconds: UInt64
    public var tailWorkP999Nanoseconds: UInt64
    public var tailWorkP9999Nanoseconds: UInt64
    public var maximumTailWorkNanoseconds: UInt64
    public var totalRenderObservations: UInt64
    public var totalRenderP50Nanoseconds: UInt64
    public var totalRenderP99Nanoseconds: UInt64
    public var totalRenderP999Nanoseconds: UInt64
    public var totalRenderP9999Nanoseconds: UInt64
    public var maximumTotalRenderNanoseconds: UInt64
    public var completionLatenessObservations: UInt64
    public var completionLatenessP50Nanoseconds: UInt64
    public var completionLatenessP99Nanoseconds: UInt64
    public var completionLatenessP999Nanoseconds: UInt64
    public var completionLatenessP9999Nanoseconds: UInt64
    public var maximumCompletionLatenessNanoseconds: UInt64
    public var tailCompletionObservations: UInt64
    public var minimumTailCompletionSlackFrames: Int
    public var tailDeadlineMisses: UInt64

    public init(
        callbackStartLatenessObservations: UInt64 = 0,
        callbackStartLatenessP50Nanoseconds: UInt64 = 0,
        callbackStartLatenessP99Nanoseconds: UInt64 = 0,
        callbackStartLatenessP999Nanoseconds: UInt64 = 0,
        callbackStartLatenessP9999Nanoseconds: UInt64 = 0,
        maximumCallbackStartLatenessNanoseconds: UInt64 = 0,
        directHeadObservations: UInt64 = 0,
        directHeadP50Nanoseconds: UInt64 = 0,
        directHeadP99Nanoseconds: UInt64 = 0,
        directHeadP999Nanoseconds: UInt64 = 0,
        directHeadP9999Nanoseconds: UInt64 = 0,
        maximumDirectHeadNanoseconds: UInt64 = 0,
        tailWorkObservations: UInt64 = 0,
        tailWorkP50Nanoseconds: UInt64 = 0,
        tailWorkP99Nanoseconds: UInt64 = 0,
        tailWorkP999Nanoseconds: UInt64 = 0,
        tailWorkP9999Nanoseconds: UInt64 = 0,
        maximumTailWorkNanoseconds: UInt64 = 0,
        totalRenderObservations: UInt64 = 0,
        totalRenderP50Nanoseconds: UInt64 = 0,
        totalRenderP99Nanoseconds: UInt64 = 0,
        totalRenderP999Nanoseconds: UInt64 = 0,
        totalRenderP9999Nanoseconds: UInt64 = 0,
        maximumTotalRenderNanoseconds: UInt64 = 0,
        completionLatenessObservations: UInt64 = 0,
        completionLatenessP50Nanoseconds: UInt64 = 0,
        completionLatenessP99Nanoseconds: UInt64 = 0,
        completionLatenessP999Nanoseconds: UInt64 = 0,
        completionLatenessP9999Nanoseconds: UInt64 = 0,
        maximumCompletionLatenessNanoseconds: UInt64 = 0,
        tailCompletionObservations: UInt64 = 0,
        minimumTailCompletionSlackFrames: Int = 0,
        tailDeadlineMisses: UInt64 = 0
    ) {
        self.callbackStartLatenessObservations = callbackStartLatenessObservations
        self.callbackStartLatenessP50Nanoseconds = callbackStartLatenessP50Nanoseconds
        self.callbackStartLatenessP99Nanoseconds = callbackStartLatenessP99Nanoseconds
        self.callbackStartLatenessP999Nanoseconds = callbackStartLatenessP999Nanoseconds
        self.callbackStartLatenessP9999Nanoseconds = callbackStartLatenessP9999Nanoseconds
        self.maximumCallbackStartLatenessNanoseconds = maximumCallbackStartLatenessNanoseconds
        self.directHeadObservations = directHeadObservations
        self.directHeadP50Nanoseconds = directHeadP50Nanoseconds
        self.directHeadP99Nanoseconds = directHeadP99Nanoseconds
        self.directHeadP999Nanoseconds = directHeadP999Nanoseconds
        self.directHeadP9999Nanoseconds = directHeadP9999Nanoseconds
        self.maximumDirectHeadNanoseconds = maximumDirectHeadNanoseconds
        self.tailWorkObservations = tailWorkObservations
        self.tailWorkP50Nanoseconds = tailWorkP50Nanoseconds
        self.tailWorkP99Nanoseconds = tailWorkP99Nanoseconds
        self.tailWorkP999Nanoseconds = tailWorkP999Nanoseconds
        self.tailWorkP9999Nanoseconds = tailWorkP9999Nanoseconds
        self.maximumTailWorkNanoseconds = maximumTailWorkNanoseconds
        self.totalRenderObservations = totalRenderObservations
        self.totalRenderP50Nanoseconds = totalRenderP50Nanoseconds
        self.totalRenderP99Nanoseconds = totalRenderP99Nanoseconds
        self.totalRenderP999Nanoseconds = totalRenderP999Nanoseconds
        self.totalRenderP9999Nanoseconds = totalRenderP9999Nanoseconds
        self.maximumTotalRenderNanoseconds = maximumTotalRenderNanoseconds
        self.completionLatenessObservations = completionLatenessObservations
        self.completionLatenessP50Nanoseconds = completionLatenessP50Nanoseconds
        self.completionLatenessP99Nanoseconds = completionLatenessP99Nanoseconds
        self.completionLatenessP999Nanoseconds = completionLatenessP999Nanoseconds
        self.completionLatenessP9999Nanoseconds = completionLatenessP9999Nanoseconds
        self.maximumCompletionLatenessNanoseconds = maximumCompletionLatenessNanoseconds
        self.tailCompletionObservations = tailCompletionObservations
        self.minimumTailCompletionSlackFrames = minimumTailCompletionSlackFrames
        self.tailDeadlineMisses = tailDeadlineMisses
    }

    private enum CodingKeys: String, CodingKey {
        case callbackStartLatenessObservations
        case callbackStartLatenessP50Nanoseconds
        case callbackStartLatenessP99Nanoseconds
        case callbackStartLatenessP999Nanoseconds
        case callbackStartLatenessP9999Nanoseconds
        case maximumCallbackStartLatenessNanoseconds
        case directHeadObservations
        case directHeadP50Nanoseconds
        case directHeadP99Nanoseconds
        case directHeadP999Nanoseconds
        case directHeadP9999Nanoseconds
        case maximumDirectHeadNanoseconds
        case tailWorkObservations
        case tailWorkP50Nanoseconds
        case tailWorkP99Nanoseconds
        case tailWorkP999Nanoseconds
        case tailWorkP9999Nanoseconds
        case maximumTailWorkNanoseconds
        case totalRenderObservations
        case totalRenderP50Nanoseconds
        case totalRenderP99Nanoseconds
        case totalRenderP999Nanoseconds
        case totalRenderP9999Nanoseconds
        case maximumTotalRenderNanoseconds
        case completionLatenessObservations
        case completionLatenessP50Nanoseconds
        case completionLatenessP99Nanoseconds
        case completionLatenessP999Nanoseconds
        case completionLatenessP9999Nanoseconds
        case maximumCompletionLatenessNanoseconds
        case tailCompletionObservations
        case minimumTailCompletionSlackFrames
        case tailDeadlineMisses
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            callbackStartLatenessObservations: try container.decodeIfPresent(UInt64.self, forKey: .callbackStartLatenessObservations) ?? 0,
            callbackStartLatenessP50Nanoseconds: try container.decodeIfPresent(UInt64.self, forKey: .callbackStartLatenessP50Nanoseconds) ?? 0,
            callbackStartLatenessP99Nanoseconds: try container.decodeIfPresent(UInt64.self, forKey: .callbackStartLatenessP99Nanoseconds) ?? 0,
            callbackStartLatenessP999Nanoseconds: try container.decodeIfPresent(UInt64.self, forKey: .callbackStartLatenessP999Nanoseconds) ?? 0,
            callbackStartLatenessP9999Nanoseconds: try container.decodeIfPresent(UInt64.self, forKey: .callbackStartLatenessP9999Nanoseconds) ?? 0,
            maximumCallbackStartLatenessNanoseconds: try container.decodeIfPresent(UInt64.self, forKey: .maximumCallbackStartLatenessNanoseconds) ?? 0,
            directHeadObservations: try container.decodeIfPresent(UInt64.self, forKey: .directHeadObservations) ?? 0,
            directHeadP50Nanoseconds: try container.decodeIfPresent(UInt64.self, forKey: .directHeadP50Nanoseconds) ?? 0,
            directHeadP99Nanoseconds: try container.decodeIfPresent(UInt64.self, forKey: .directHeadP99Nanoseconds) ?? 0,
            directHeadP999Nanoseconds: try container.decodeIfPresent(UInt64.self, forKey: .directHeadP999Nanoseconds) ?? 0,
            directHeadP9999Nanoseconds: try container.decodeIfPresent(UInt64.self, forKey: .directHeadP9999Nanoseconds) ?? 0,
            maximumDirectHeadNanoseconds: try container.decodeIfPresent(UInt64.self, forKey: .maximumDirectHeadNanoseconds) ?? 0,
            tailWorkObservations: try container.decodeIfPresent(UInt64.self, forKey: .tailWorkObservations) ?? 0,
            tailWorkP50Nanoseconds: try container.decodeIfPresent(UInt64.self, forKey: .tailWorkP50Nanoseconds) ?? 0,
            tailWorkP99Nanoseconds: try container.decodeIfPresent(UInt64.self, forKey: .tailWorkP99Nanoseconds) ?? 0,
            tailWorkP999Nanoseconds: try container.decodeIfPresent(UInt64.self, forKey: .tailWorkP999Nanoseconds) ?? 0,
            tailWorkP9999Nanoseconds: try container.decodeIfPresent(UInt64.self, forKey: .tailWorkP9999Nanoseconds) ?? 0,
            maximumTailWorkNanoseconds: try container.decodeIfPresent(UInt64.self, forKey: .maximumTailWorkNanoseconds) ?? 0,
            totalRenderObservations: try container.decodeIfPresent(UInt64.self, forKey: .totalRenderObservations) ?? 0,
            totalRenderP50Nanoseconds: try container.decodeIfPresent(UInt64.self, forKey: .totalRenderP50Nanoseconds) ?? 0,
            totalRenderP99Nanoseconds: try container.decodeIfPresent(UInt64.self, forKey: .totalRenderP99Nanoseconds) ?? 0,
            totalRenderP999Nanoseconds: try container.decodeIfPresent(UInt64.self, forKey: .totalRenderP999Nanoseconds) ?? 0,
            totalRenderP9999Nanoseconds: try container.decodeIfPresent(UInt64.self, forKey: .totalRenderP9999Nanoseconds) ?? 0,
            maximumTotalRenderNanoseconds: try container.decodeIfPresent(UInt64.self, forKey: .maximumTotalRenderNanoseconds) ?? 0,
            completionLatenessObservations: try container.decodeIfPresent(UInt64.self, forKey: .completionLatenessObservations) ?? 0,
            completionLatenessP50Nanoseconds: try container.decodeIfPresent(UInt64.self, forKey: .completionLatenessP50Nanoseconds) ?? 0,
            completionLatenessP99Nanoseconds: try container.decodeIfPresent(UInt64.self, forKey: .completionLatenessP99Nanoseconds) ?? 0,
            completionLatenessP999Nanoseconds: try container.decodeIfPresent(UInt64.self, forKey: .completionLatenessP999Nanoseconds) ?? 0,
            completionLatenessP9999Nanoseconds: try container.decodeIfPresent(UInt64.self, forKey: .completionLatenessP9999Nanoseconds) ?? 0,
            maximumCompletionLatenessNanoseconds: try container.decodeIfPresent(UInt64.self, forKey: .maximumCompletionLatenessNanoseconds) ?? 0,
            tailCompletionObservations: try container.decodeIfPresent(UInt64.self, forKey: .tailCompletionObservations) ?? 0,
            minimumTailCompletionSlackFrames: try container.decodeIfPresent(Int.self, forKey: .minimumTailCompletionSlackFrames) ?? 0,
            tailDeadlineMisses: try container.decodeIfPresent(UInt64.self, forKey: .tailDeadlineMisses) ?? 0
        )
    }
}

public struct SettingsAudioMetricsDTO: Codable, Equatable, Sendable {
    public var capturedFrames: UInt64
    public var playedFrames: UInt64
    public var playbackUnderrunEvents: UInt64
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
    public var captureCallbackSizeObservations: [SettingsAudioCallbackSizeObservationDTO]
    public var playbackCallbackSizeObservations: [SettingsAudioCallbackSizeObservationDTO]
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
    public var renderTiming: SettingsAudioRenderTimingDTO
    public var diagnostics: SettingsAudioDiagnosticsDTO

    private enum CodingKeys: String, CodingKey {
        case capturedFrames
        case playedFrames
        case playbackUnderrunEvents
        case playbackUnderrunFrames
        case droppedInputFrames
        case droppedBufferedFrames
        case ringGateContentionFailures
        case saturatedSamples
        case currentBufferedFrames
        case maxBufferedFrames
        case maximumPlaybackBufferedFrames
        case minimumPlaybackBufferedFrames
        case averagePlaybackBufferedFrames
        case playbackBufferObservations
        case inputTimestampDiscontinuities
        case outputTimestampDiscontinuities
        case pairedTimestampDiscontinuities
        case qualifyingPairedTimestampDiscontinuities
        case lastInputTimestampJumpFrames
        case lastOutputTimestampJumpFrames
        case lastInputHostIntervalErrorNanoseconds
        case lastOutputHostIntervalErrorNanoseconds
        case timestampJumpIntervalObservations
        case minimumTimestampJumpIntervalNanoseconds
        case maximumTimestampJumpIntervalNanoseconds
        case averageTimestampJumpIntervalNanoseconds
        case maximumCaptureCallbackFrames
        case maximumPlaybackCallbackFrames
        case captureCallbackSizeObservations
        case playbackCallbackSizeObservations
        case renderDeadlineMisses
        case callbackStartStarvations
        case renderOverruns
        case playbackTimestampDiscontinuities
        case playbackBufferRenegotiations
        case adaptivePlaybackRenderFailures
        case playbackRateCorrectionPPM
        case playbackRateCorrectionSaturated
        case playbackOccupancyTargetFrames
        case filteredPlaybackOccupancyFrames
        case playbackBufferSampleRate
        case playbackSampleRateConversionActive
        case tapToOutputLatencyObservations
        case minimumTapToOutputLatencyNanoseconds
        case maximumTapToOutputLatencyNanoseconds
        case averageTapToOutputLatencyNanoseconds
        case callbackTimingObservations
        case minimumInputAgeNanoseconds
        case maximumInputAgeNanoseconds
        case averageInputAgeNanoseconds
        case minimumOutputLeadNanoseconds
        case maximumOutputLeadNanoseconds
        case averageOutputLeadNanoseconds
        case renderTiming
        case diagnostics
    }

    public init(
        capturedFrames: UInt64 = 0,
        playedFrames: UInt64 = 0,
        playbackUnderrunEvents: UInt64 = 0,
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
        captureCallbackSizeObservations: [SettingsAudioCallbackSizeObservationDTO] = [],
        playbackCallbackSizeObservations: [SettingsAudioCallbackSizeObservationDTO] = [],
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
        renderTiming: SettingsAudioRenderTimingDTO = SettingsAudioRenderTimingDTO(),
        diagnostics: SettingsAudioDiagnosticsDTO = SettingsAudioDiagnosticsDTO()
    ) {
        self.capturedFrames = capturedFrames
        self.playedFrames = playedFrames
        self.playbackUnderrunEvents = playbackUnderrunEvents
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
        self.captureCallbackSizeObservations = captureCallbackSizeObservations
        self.playbackCallbackSizeObservations = playbackCallbackSizeObservations
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
        self.diagnostics = diagnostics
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            capturedFrames: try container.decodeIfPresent(UInt64.self, forKey: .capturedFrames) ?? 0,
            playedFrames: try container.decodeIfPresent(UInt64.self, forKey: .playedFrames) ?? 0,
            playbackUnderrunEvents: try container.decodeIfPresent(UInt64.self, forKey: .playbackUnderrunEvents) ?? 0,
            playbackUnderrunFrames: try container.decodeIfPresent(UInt64.self, forKey: .playbackUnderrunFrames) ?? 0,
            droppedInputFrames: try container.decodeIfPresent(UInt64.self, forKey: .droppedInputFrames) ?? 0,
            droppedBufferedFrames: try container.decodeIfPresent(UInt64.self, forKey: .droppedBufferedFrames) ?? 0,
            ringGateContentionFailures: try container.decodeIfPresent(UInt64.self, forKey: .ringGateContentionFailures) ?? 0,
            saturatedSamples: try container.decodeIfPresent(UInt64.self, forKey: .saturatedSamples) ?? 0,
            currentBufferedFrames: try container.decodeIfPresent(Int.self, forKey: .currentBufferedFrames) ?? 0,
            maxBufferedFrames: try container.decodeIfPresent(Int.self, forKey: .maxBufferedFrames) ?? 0,
            maximumPlaybackBufferedFrames: try container.decodeIfPresent(Int.self, forKey: .maximumPlaybackBufferedFrames) ?? 0,
            minimumPlaybackBufferedFrames: try container.decodeIfPresent(Int.self, forKey: .minimumPlaybackBufferedFrames) ?? 0,
            averagePlaybackBufferedFrames: try container.decodeIfPresent(Double.self, forKey: .averagePlaybackBufferedFrames) ?? 0,
            playbackBufferObservations: try container.decodeIfPresent(UInt64.self, forKey: .playbackBufferObservations) ?? 0,
            inputTimestampDiscontinuities: try container.decodeIfPresent(UInt64.self, forKey: .inputTimestampDiscontinuities) ?? 0,
            outputTimestampDiscontinuities: try container.decodeIfPresent(UInt64.self, forKey: .outputTimestampDiscontinuities) ?? 0,
            pairedTimestampDiscontinuities: try container.decodeIfPresent(UInt64.self, forKey: .pairedTimestampDiscontinuities) ?? 0,
            qualifyingPairedTimestampDiscontinuities: try container.decodeIfPresent(UInt64.self, forKey: .qualifyingPairedTimestampDiscontinuities) ?? 0,
            lastInputTimestampJumpFrames: try container.decodeIfPresent(Double.self, forKey: .lastInputTimestampJumpFrames) ?? 0,
            lastOutputTimestampJumpFrames: try container.decodeIfPresent(Double.self, forKey: .lastOutputTimestampJumpFrames) ?? 0,
            lastInputHostIntervalErrorNanoseconds: try container.decodeIfPresent(Int64.self, forKey: .lastInputHostIntervalErrorNanoseconds) ?? 0,
            lastOutputHostIntervalErrorNanoseconds: try container.decodeIfPresent(Int64.self, forKey: .lastOutputHostIntervalErrorNanoseconds) ?? 0,
            timestampJumpIntervalObservations: try container.decodeIfPresent(UInt64.self, forKey: .timestampJumpIntervalObservations) ?? 0,
            minimumTimestampJumpIntervalNanoseconds: try container.decodeIfPresent(UInt64.self, forKey: .minimumTimestampJumpIntervalNanoseconds) ?? 0,
            maximumTimestampJumpIntervalNanoseconds: try container.decodeIfPresent(UInt64.self, forKey: .maximumTimestampJumpIntervalNanoseconds) ?? 0,
            averageTimestampJumpIntervalNanoseconds: try container.decodeIfPresent(Double.self, forKey: .averageTimestampJumpIntervalNanoseconds) ?? 0,
            maximumCaptureCallbackFrames: try container.decodeIfPresent(Int.self, forKey: .maximumCaptureCallbackFrames) ?? 0,
            maximumPlaybackCallbackFrames: try container.decodeIfPresent(Int.self, forKey: .maximumPlaybackCallbackFrames) ?? 0,
            captureCallbackSizeObservations: try container.decodeIfPresent(
                [SettingsAudioCallbackSizeObservationDTO].self,
                forKey: .captureCallbackSizeObservations
            ) ?? [],
            playbackCallbackSizeObservations: try container.decodeIfPresent(
                [SettingsAudioCallbackSizeObservationDTO].self,
                forKey: .playbackCallbackSizeObservations
            ) ?? [],
            renderDeadlineMisses: try container.decodeIfPresent(UInt64.self, forKey: .renderDeadlineMisses) ?? 0,
            callbackStartStarvations: try container.decodeIfPresent(UInt64.self, forKey: .callbackStartStarvations) ?? 0,
            renderOverruns: try container.decodeIfPresent(UInt64.self, forKey: .renderOverruns) ?? 0,
            playbackTimestampDiscontinuities: try container.decodeIfPresent(UInt64.self, forKey: .playbackTimestampDiscontinuities) ?? 0,
            playbackBufferRenegotiations: try container.decodeIfPresent(UInt64.self, forKey: .playbackBufferRenegotiations) ?? 0,
            adaptivePlaybackRenderFailures: try container.decodeIfPresent(UInt64.self, forKey: .adaptivePlaybackRenderFailures) ?? 0,
            playbackRateCorrectionPPM: try container.decodeIfPresent(Double.self, forKey: .playbackRateCorrectionPPM) ?? 0,
            playbackRateCorrectionSaturated: try container.decodeIfPresent(Bool.self, forKey: .playbackRateCorrectionSaturated) ?? false,
            playbackOccupancyTargetFrames: try container.decodeIfPresent(Int.self, forKey: .playbackOccupancyTargetFrames) ?? 0,
            filteredPlaybackOccupancyFrames: try container.decodeIfPresent(Double.self, forKey: .filteredPlaybackOccupancyFrames) ?? 0,
            playbackBufferSampleRate: try container.decodeIfPresent(Double.self, forKey: .playbackBufferSampleRate) ?? 0,
            playbackSampleRateConversionActive: try container.decodeIfPresent(Bool.self, forKey: .playbackSampleRateConversionActive) ?? false,
            tapToOutputLatencyObservations: try container.decodeIfPresent(UInt64.self, forKey: .tapToOutputLatencyObservations) ?? 0,
            minimumTapToOutputLatencyNanoseconds: try container.decodeIfPresent(UInt64.self, forKey: .minimumTapToOutputLatencyNanoseconds) ?? 0,
            maximumTapToOutputLatencyNanoseconds: try container.decodeIfPresent(UInt64.self, forKey: .maximumTapToOutputLatencyNanoseconds) ?? 0,
            averageTapToOutputLatencyNanoseconds: try container.decodeIfPresent(Double.self, forKey: .averageTapToOutputLatencyNanoseconds) ?? 0,
            callbackTimingObservations: try container.decodeIfPresent(UInt64.self, forKey: .callbackTimingObservations) ?? 0,
            minimumInputAgeNanoseconds: try container.decodeIfPresent(UInt64.self, forKey: .minimumInputAgeNanoseconds) ?? 0,
            maximumInputAgeNanoseconds: try container.decodeIfPresent(UInt64.self, forKey: .maximumInputAgeNanoseconds) ?? 0,
            averageInputAgeNanoseconds: try container.decodeIfPresent(Double.self, forKey: .averageInputAgeNanoseconds) ?? 0,
            minimumOutputLeadNanoseconds: try container.decodeIfPresent(UInt64.self, forKey: .minimumOutputLeadNanoseconds) ?? 0,
            maximumOutputLeadNanoseconds: try container.decodeIfPresent(UInt64.self, forKey: .maximumOutputLeadNanoseconds) ?? 0,
            averageOutputLeadNanoseconds: try container.decodeIfPresent(Double.self, forKey: .averageOutputLeadNanoseconds) ?? 0,
            renderTiming: try container.decodeIfPresent(
                SettingsAudioRenderTimingDTO.self,
                forKey: .renderTiming
            ) ?? SettingsAudioRenderTimingDTO(),
            diagnostics: try container.decodeIfPresent(
                SettingsAudioDiagnosticsDTO.self,
                forKey: .diagnostics
            ) ?? SettingsAudioDiagnosticsDTO()
        )
    }
}

public struct SettingsOutputDTO: Codable, Equatable, Sendable {
    public var name: String
    public var uid: String
    public var sampleRate: Double
    public var channelCount: Int
    public var bufferFrameSize: UInt32

    public init(name: String, uid: String, sampleRate: Double, channelCount: Int, bufferFrameSize: UInt32) {
        self.name = name
        self.uid = uid
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.bufferFrameSize = bufferFrameSize
    }
}

public enum SettingsOptionalUUIDPatchDTO: Codable, Equatable, Sendable {
    case set(UUID)
    case clear
}

public struct SettingsProfileStoreProtectionDTO: Codable, Equatable, Sendable {
    public var isProtected: Bool
    public var message: String
    public var resetButtonTitle: String

    public init(
        isProtected: Bool = false,
        message: String = "",
        resetButtonTitle: String = ""
    ) {
        self.isProtected = isProtected
        self.message = message
        self.resetButtonTitle = resetButtonTitle
    }

    public static var unprotected: SettingsProfileStoreProtectionDTO {
        SettingsProfileStoreProtectionDTO()
    }
}

public struct SettingsSnapshotPatchDTO: Codable, Equatable, Sendable {
    public var statusMessage: String?
    public var isRunning: Bool?
    public var isPreviewing: Bool?
    public var programmeComparison: EQProgrammeComparisonSnapshot?
    public var selectedProfileID: UUID?
    public var draftProfile: EQProfile?
    public var activeProfileID: UUID?
    public var activeProfileName: String?
    public var fallbackProfileID: UUID?
    public var currentOutput: SettingsOutputDTO?
    public var currentProcessingSampleRate: Double?
    public var currentOutputMappedProfileID: SettingsOptionalUUIDPatchDTO?
    public var aggregateBuffer: SettingsAggregateBufferDTO?
    public var profileStoreProtection: SettingsProfileStoreProtectionDTO?

    public init(
        statusMessage: String? = nil,
        isRunning: Bool? = nil,
        isPreviewing: Bool? = nil,
        programmeComparison: EQProgrammeComparisonSnapshot? = nil,
        selectedProfileID: UUID? = nil,
        draftProfile: EQProfile? = nil,
        activeProfileID: UUID? = nil,
        activeProfileName: String? = nil,
        fallbackProfileID: UUID? = nil,
        currentOutput: SettingsOutputDTO? = nil,
        currentProcessingSampleRate: Double? = nil,
        currentOutputMappedProfileID: SettingsOptionalUUIDPatchDTO? = nil,
        aggregateBuffer: SettingsAggregateBufferDTO? = nil,
        profileStoreProtection: SettingsProfileStoreProtectionDTO? = nil
    ) {
        self.statusMessage = statusMessage
        self.isRunning = isRunning
        self.isPreviewing = isPreviewing
        self.programmeComparison = programmeComparison
        self.selectedProfileID = selectedProfileID
        self.draftProfile = draftProfile
        self.activeProfileID = activeProfileID
        self.activeProfileName = activeProfileName
        self.fallbackProfileID = fallbackProfileID
        self.currentOutput = currentOutput
        self.currentProcessingSampleRate = currentProcessingSampleRate
        self.currentOutputMappedProfileID = currentOutputMappedProfileID
        self.aggregateBuffer = aggregateBuffer
        self.profileStoreProtection = profileStoreProtection
    }
}

public struct SettingsSnapshotDTO: Codable, Equatable, Sendable {
    public var profiles: [EQProfile]
    public var selectedProfileID: UUID
    public var draftProfile: EQProfile
    public var activeProfileID: UUID
    public var activeProfileName: String
    public var currentOutputName: String
    public var currentOutputUID: String
    public var currentOutputSampleRate: Double
    public var currentProcessingSampleRate: Double
    public var currentOutputChannelCount: Int
    public var currentOutputBufferFrameSize: UInt32
    public var currentOutputMappedProfileID: UUID?
    public var aggregateBuffer: SettingsAggregateBufferDTO
    public var fallbackProfileID: UUID
    public var statusMessage: String
    public var metrics: SettingsAudioMetricsDTO
    public var isRunning: Bool
    public var isPreviewing: Bool
    public var programmeComparison: EQProgrammeComparisonSnapshot
    public var profileStoreProtection: SettingsProfileStoreProtectionDTO

    private enum CodingKeys: String, CodingKey {
        case profiles
        case selectedProfileID
        case draftProfile
        case activeProfileID
        case activeProfileName
        case currentOutputName
        case currentOutputUID
        case currentOutputSampleRate
        case currentProcessingSampleRate
        case currentOutputChannelCount
        case currentOutputBufferFrameSize
        case currentOutputMappedProfileID
        case aggregateBuffer
        case fallbackProfileID
        case statusMessage
        case metrics
        case isRunning
        case isPreviewing
        case programmeComparison
        case profileStoreProtection
    }

    public init(
        profiles: [EQProfile],
        selectedProfileID: UUID,
        draftProfile: EQProfile,
        activeProfileID: UUID,
        activeProfileName: String,
        currentOutputName: String,
        currentOutputUID: String,
        currentOutputSampleRate: Double,
        currentProcessingSampleRate: Double,
        currentOutputChannelCount: Int,
        currentOutputBufferFrameSize: UInt32,
        currentOutputMappedProfileID: UUID?,
        aggregateBuffer: SettingsAggregateBufferDTO = SettingsAggregateBufferDTO(),
        fallbackProfileID: UUID,
        statusMessage: String,
        metrics: SettingsAudioMetricsDTO,
        isRunning: Bool,
        isPreviewing: Bool,
        programmeComparison: EQProgrammeComparisonSnapshot = EQProgrammeComparisonSnapshot(),
        profileStoreProtection: SettingsProfileStoreProtectionDTO = .unprotected
    ) {
        self.profiles = profiles
        self.selectedProfileID = selectedProfileID
        self.draftProfile = draftProfile
        self.activeProfileID = activeProfileID
        self.activeProfileName = activeProfileName
        self.currentOutputName = currentOutputName
        self.currentOutputUID = currentOutputUID
        self.currentOutputSampleRate = currentOutputSampleRate
        self.currentProcessingSampleRate = currentProcessingSampleRate
        self.currentOutputChannelCount = currentOutputChannelCount
        self.currentOutputBufferFrameSize = currentOutputBufferFrameSize
        self.currentOutputMappedProfileID = currentOutputMappedProfileID
        self.aggregateBuffer = aggregateBuffer
        self.fallbackProfileID = fallbackProfileID
        self.statusMessage = statusMessage
        self.metrics = metrics
        self.isRunning = isRunning
        self.isPreviewing = isPreviewing
        self.programmeComparison = programmeComparison
        self.profileStoreProtection = profileStoreProtection
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let currentOutputSampleRate = try container.decode(
            Double.self,
            forKey: .currentOutputSampleRate
        )
        self.init(
            profiles: try container.decode([EQProfile].self, forKey: .profiles),
            selectedProfileID: try container.decode(UUID.self, forKey: .selectedProfileID),
            draftProfile: try container.decode(EQProfile.self, forKey: .draftProfile),
            activeProfileID: try container.decode(UUID.self, forKey: .activeProfileID),
            activeProfileName: try container.decode(String.self, forKey: .activeProfileName),
            currentOutputName: try container.decode(String.self, forKey: .currentOutputName),
            currentOutputUID: try container.decode(String.self, forKey: .currentOutputUID),
            currentOutputSampleRate: currentOutputSampleRate,
            currentProcessingSampleRate: try container.decodeIfPresent(
                Double.self,
                forKey: .currentProcessingSampleRate
            ) ?? currentOutputSampleRate,
            currentOutputChannelCount: try container.decode(Int.self, forKey: .currentOutputChannelCount),
            currentOutputBufferFrameSize: try container.decode(UInt32.self, forKey: .currentOutputBufferFrameSize),
            currentOutputMappedProfileID: try container.decodeIfPresent(UUID.self, forKey: .currentOutputMappedProfileID),
            aggregateBuffer: try container.decodeIfPresent(
                SettingsAggregateBufferDTO.self,
                forKey: .aggregateBuffer
            ) ?? SettingsAggregateBufferDTO(),
            fallbackProfileID: try container.decode(UUID.self, forKey: .fallbackProfileID),
            statusMessage: try container.decode(String.self, forKey: .statusMessage),
            metrics: try container.decode(SettingsAudioMetricsDTO.self, forKey: .metrics),
            isRunning: try container.decodeIfPresent(Bool.self, forKey: .isRunning) ?? false,
            isPreviewing: try container.decode(Bool.self, forKey: .isPreviewing),
            programmeComparison: try container.decodeIfPresent(
                EQProgrammeComparisonSnapshot.self,
                forKey: .programmeComparison
            ) ?? EQProgrammeComparisonSnapshot(),
            profileStoreProtection: try container.decode(
                SettingsProfileStoreProtectionDTO.self,
                forKey: .profileStoreProtection
            )
        )
    }

    public static var disconnected: SettingsSnapshotDTO {
        let profile = EQProfile.flatGraphic31
        return SettingsSnapshotDTO(
            profiles: [profile],
            selectedProfileID: profile.id,
            draftProfile: profile,
            activeProfileID: profile.id,
            activeProfileName: profile.name,
            currentOutputName: "No output",
            currentOutputUID: "",
            currentOutputSampleRate: 0,
            currentProcessingSampleRate: 0,
            currentOutputChannelCount: 0,
            currentOutputBufferFrameSize: 0,
            currentOutputMappedProfileID: nil,
            aggregateBuffer: SettingsAggregateBufferDTO(),
            fallbackProfileID: profile.id,
            statusMessage: "Connecting to GlassEQ...",
            metrics: SettingsAudioMetricsDTO(),
            isRunning: false,
            isPreviewing: false,
            programmeComparison: EQProgrammeComparisonSnapshot(),
            profileStoreProtection: .unprotected
        )
    }
}

public enum SettingsFileImportMode: String, Codable, Equatable, Sendable {
    case single
    case stereoPair
}

public struct SettingsImpulseResponseChannelDTO: Codable, Equatable, Sendable {
    public var filename: String
    public var frameCount: Int
    public var sampleRate: Double

    public init(filename: String, frameCount: Int, sampleRate: Double) {
        self.filename = filename
        self.frameCount = frameCount
        self.sampleRate = sampleRate
    }
}

public enum SettingsFileImportSelectionDTO: Codable, Equatable, Sendable {
    case text(suggestedName: String, filename: String, text: String)
    case impulseResponse(
        profile: EQProfile,
        channels: [SettingsImpulseResponseChannelDTO],
        sourceFileCount: Int
    )
    case stereoText(profile: EQProfile, leftFilename: String, rightFilename: String)
}

public enum SettingsCommand: Codable, Equatable, Sendable {
    case createProfile(SettingsProfileKind)
    case duplicateProfile(UUID)
    case deleteProfile(UUID)
    case applyProfile(EQProfile)
    case useProfileForCurrentOutput(EQProfile)
    case setFallback(EQProfile)
    case importProfile(format: SettingsImportFormat, name: String, text: String)
    case importParsedProfile(EQProfile)
    case chooseImportFiles(mode: SettingsFileImportMode)
    case preview(EQProfile)
    case stopPreview
    case startProgrammeComparison(EQProfile)
    case selectProgrammeComparison(EQProgrammeComparisonSelection)
    case stopProgrammeComparison
    case resetDiagnostics
    case setAggregateBufferMode(SettingsAggregateBufferMode)
    case retryAutomaticAggregateBuffer
    case retryAudioEngine
    case openPrivacySettings
    case startMetricsPolling
    case stopMetricsPolling
    case resetUnsupportedProfileStore
    case showSetupGuide
}

public struct SettingsCommandResponse: Codable, Equatable, Sendable {
    public var snapshot: SettingsSnapshotDTO?
    public var importSucceeded: Bool?
    public var fileImportSelection: SettingsFileImportSelectionDTO?

    public init(
        snapshot: SettingsSnapshotDTO? = nil,
        importSucceeded: Bool? = nil,
        fileImportSelection: SettingsFileImportSelectionDTO? = nil
    ) {
        self.snapshot = snapshot
        self.importSucceeded = importSucceeded
        self.fileImportSelection = fileImportSelection
    }
}

public struct SettingsCommandFailure: Codable, Equatable, Error, LocalizedError, Sendable {
    public var message: String

    public init(message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

public enum SettingsEvent: Codable, Equatable, Sendable {
    case snapshotChanged(SettingsSnapshotDTO)
    case snapshotPatched(SettingsSnapshotPatchDTO)
    case metricsChanged(SettingsAudioMetricsDTO)
    case commandFailed(SettingsCommandFailure)
    case focusRequested
    case sectionRequested(SettingsSection)
    case shutdown
}

public enum SettingsPipeRequestKind: String, Codable, Equatable, Sendable {
    case connect
    case ready
    case command
    case cancel
    case disconnect
}

public enum SettingsPipeMessage: Codable, Equatable, Sendable {
    case bootstrap(sessionToken: String)
    case request(sessionToken: String, id: String, kind: SettingsPipeRequestKind, command: SettingsCommand?)
    case response(sessionToken: String, id: String, response: SettingsCommandResponse?, error: String?)
    case event(sessionToken: String, event: SettingsEvent)

    public var sessionToken: String {
        switch self {
        case .bootstrap(let sessionToken),
             .request(let sessionToken, _, _, _),
             .response(let sessionToken, _, _, _),
             .event(let sessionToken, _):
            sessionToken
        }
    }

    public func validateSessionToken(_ expected: String) throws {
        guard Self.constantTimeEquals(sessionToken, expected) else {
            throw SettingsPipeError.sessionTokenMismatch
        }
    }

    private static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let lhsBytes = Array(lhs.utf8)
        let rhsBytes = Array(rhs.utf8)
        let count = max(lhsBytes.count, rhsBytes.count)
        var difference = lhsBytes.count ^ rhsBytes.count
        for index in 0..<count {
            let lhsByte = index < lhsBytes.count ? Int(lhsBytes[index]) : 0
            let rhsByte = index < rhsBytes.count ? Int(rhsBytes[index]) : 0
            difference |= lhsByte ^ rhsByte
        }
        return difference == 0
    }
}

public enum SettingsPipeError: Error, Equatable, LocalizedError, Sendable {
    case sessionTokenMismatch
    case frameTooLarge(byteCount: Int, maximum: Int)

    public var errorDescription: String? {
        switch self {
        case .sessionTokenMismatch:
            return "Settings IPC session was invalid."
        case let .frameTooLarge(byteCount, maximum):
            return "Settings IPC frame is \(byteCount) bytes, which exceeds the \(maximum)-byte limit."
        }
    }
}

public enum SettingsPipeCodec {
    public static let maximumLineBytes = 8 * 1_024 * 1_024

    public static func encodeLine(
        _ message: SettingsPipeMessage,
        maximumLineBytes: Int = Self.maximumLineBytes
    ) throws -> Data {
        var data = try SettingsPipeJSONCodec.makeEncoder().encode(message)
        guard data.count + 1 <= maximumLineBytes else {
            throw SettingsPipeError.frameTooLarge(byteCount: data.count + 1, maximum: maximumLineBytes)
        }
        data.append(0x0A)
        return data
    }

    public static func decodeLine(_ data: Data) throws -> SettingsPipeMessage {
        try SettingsPipeJSONCodec.makeDecoder().decode(SettingsPipeMessage.self, from: data)
    }
}

public struct SettingsPipeLineBuffer: Sendable {
    public private(set) var bufferedByteCount: Int = 0

    private let maximumLineBytes: Int
    private var buffer = Data()

    public init(maximumLineBytes: Int = SettingsPipeCodec.maximumLineBytes) {
        self.maximumLineBytes = maximumLineBytes
    }

    public mutating func append(_ chunk: Data) throws -> [Data] {
        guard !chunk.isEmpty else {
            return []
        }

        buffer.append(chunk)
        bufferedByteCount = buffer.count

        var lines: [Data] = []
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let line = buffer[..<newlineIndex]
            guard line.count + 1 <= maximumLineBytes else {
                throw SettingsPipeError.frameTooLarge(byteCount: line.count + 1, maximum: maximumLineBytes)
            }
            if !line.isEmpty {
                lines.append(Data(line))
            }
            buffer.removeSubrange(...newlineIndex)
        }

        bufferedByteCount = buffer.count
        guard bufferedByteCount <= maximumLineBytes else {
            throw SettingsPipeError.frameTooLarge(byteCount: bufferedByteCount, maximum: maximumLineBytes)
        }

        return lines
    }

    public mutating func removeAll(keepingCapacity: Bool = false) {
        buffer.removeAll(keepingCapacity: keepingCapacity)
        bufferedByteCount = 0
    }
}

public actor SettingsPipeLineDecoder {
    private var buffer: SettingsPipeLineBuffer

    public init(maximumLineBytes: Int = SettingsPipeCodec.maximumLineBytes) {
        self.buffer = SettingsPipeLineBuffer(maximumLineBytes: maximumLineBytes)
    }

    public func append(_ chunk: Data) throws -> [SettingsPipeMessage] {
        let lines = try buffer.append(chunk)
        return try lines.map(SettingsPipeCodec.decodeLine)
    }

    public func removeAll(keepingCapacity: Bool = false) {
        buffer.removeAll(keepingCapacity: keepingCapacity)
    }
}

enum SettingsPipeJSONCodec {
    static func makeEncoder() -> JSONEncoder {
        JSONEncoder()
    }

    static func makeDecoder() -> JSONDecoder {
        JSONDecoder()
    }
}

public final class SettingsPipeReadPump: @unchecked Sendable {
    private let queue: DispatchQueue
    private let onMessages: @Sendable (Result<[SettingsPipeMessage], any Error>) -> Void
    private let onEndOfFile: @Sendable () -> Void
    private var buffer: SettingsPipeLineBuffer

    public init(
        label: String,
        maximumLineBytes: Int = SettingsPipeCodec.maximumLineBytes,
        onMessages: @escaping @Sendable (Result<[SettingsPipeMessage], any Error>) -> Void,
        onEndOfFile: @escaping @Sendable () -> Void
    ) {
        self.queue = DispatchQueue(label: label)
        self.buffer = SettingsPipeLineBuffer(maximumLineBytes: maximumLineBytes)
        self.onMessages = onMessages
        self.onEndOfFile = onEndOfFile
    }

    public func install(on handle: FileHandle) {
        handle.readabilityHandler = { [weak self] handle in
            guard let self else {
                return
            }
            let data = handle.availableData
            guard !data.isEmpty else {
                queue.async { [self] in
                    self.onEndOfFile()
                }
                return
            }
            queue.async { [self] in
                do {
                    let lines = try self.buffer.append(data)
                    let messages = try lines.map(SettingsPipeCodec.decodeLine)
                    self.onMessages(.success(messages))
                } catch {
                    self.onMessages(.failure(error))
                }
            }
        }
    }

    public func invalidate(handle: FileHandle?) {
        handle?.readabilityHandler = nil
        queue.async { [weak self] in
            self?.buffer.removeAll(keepingCapacity: false)
        }
    }
}

public final class SettingsPipeOrderedMainActorDelivery: @unchecked Sendable {
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var generation = 0
    private var isActive = true

    public init(label: String) {
        self.queue = DispatchQueue(label: label)
    }

    public func enqueue(_ operation: @escaping @MainActor () -> Void) {
        let scheduledGeneration: Int? = lock.withLock {
            guard isActive else {
                return nil
            }
            return generation
        }
        guard let scheduledGeneration else {
            return
        }

        queue.async { [weak self] in
            guard let self,
                  self.isCurrent(scheduledGeneration) else {
                return
            }
            let semaphore = DispatchSemaphore(value: 0)
            let operation = UncheckedSendable(value: operation)
            Task { @MainActor in
                defer {
                    semaphore.signal()
                }
                guard self.isCurrent(scheduledGeneration) else {
                    return
                }
                operation.value()
            }
            semaphore.wait()
        }
    }

    public func invalidate() {
        lock.withLock {
            isActive = false
            generation += 1
        }
    }

    private func isCurrent(_ scheduledGeneration: Int) -> Bool {
        lock.withLock {
            isActive && generation == scheduledGeneration
        }
    }
}

public struct SettingsPipeWriteSink: Sendable {
    private let writeBody: @Sendable (Data) throws -> Void
    private let closeBody: @Sendable () throws -> Void

    public init(
        _ writeBody: @escaping @Sendable (Data) throws -> Void,
        close closeBody: @escaping @Sendable () throws -> Void = {}
    ) {
        self.writeBody = writeBody
        self.closeBody = closeBody
    }

    public init(fileHandle: FileHandle) {
        SettingsPipeProcessSignalPolicy.ignoreBrokenPipeSignal()
        let handle = UncheckedSendable(value: fileHandle)
        self.writeBody = { data in
            try handle.value.write(contentsOf: data)
        }
        self.closeBody = {
            try handle.value.close()
        }
    }

    func write(_ data: Data) throws {
        try writeBody(data)
    }

    func close() throws {
        try closeBody()
    }
}

public enum SettingsPipeWritePumpError: Error, Equatable, LocalizedError, Sendable {
    case closed

    public var errorDescription: String? {
        switch self {
        case .closed:
            return "Settings IPC pipe is closed."
        }
    }
}

public final class SettingsPipeWritePump: @unchecked Sendable {
    private let queue: DispatchQueue
    private let sink: SettingsPipeWriteSink
    private let lock = NSLock()
    private var isClosing = false

    public init(label: String, sink: SettingsPipeWriteSink) {
        self.queue = DispatchQueue(label: label)
        self.sink = sink
    }

    public convenience init(label: String, fileHandle: FileHandle) {
        self.init(label: label, sink: SettingsPipeWriteSink(fileHandle: fileHandle))
    }

    public func enqueue(
        _ message: SettingsPipeMessage,
        completion: @escaping @Sendable (Result<Void, any Error>) -> Void = { _ in }
    ) {
        guard markEnqueueAccepted() else {
            queue.async {
                completion(.failure(SettingsPipeWritePumpError.closed))
            }
            return
        }

        queue.async { [sink] in
            do {
                let data = try SettingsPipeCodec.encodeLine(message)
                try sink.write(data)
                completion(.success(()))
            } catch {
                completion(.failure(error))
            }
        }
    }

    public func drainAndClose(
        completion: @escaping @Sendable (Result<Void, any Error>) -> Void = { _ in }
    ) {
        let shouldClose = lock.withLock {
            guard !isClosing else {
                return false
            }
            isClosing = true
            return true
        }

        guard shouldClose else {
            queue.async {
                completion(.success(()))
            }
            return
        }

        queue.async { [sink] in
            do {
                try sink.close()
                completion(.success(()))
            } catch {
                completion(.failure(error))
            }
        }
    }

    public func drainAndClose() async -> Result<Void, any Error> {
        await withCheckedContinuation { continuation in
            drainAndClose { result in
                continuation.resume(returning: result)
            }
        }
    }

    private func markEnqueueAccepted() -> Bool {
        lock.withLock {
            !isClosing
        }
    }
}
