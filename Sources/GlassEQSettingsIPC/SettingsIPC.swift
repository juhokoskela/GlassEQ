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
}

public enum SettingsAggregateBufferMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case automatic
    case frames16
    case frames32
    case frames64

    public var id: String { rawValue }
}

public enum SettingsSection: String, Codable, Equatable, Sendable {
    case editor
    case importer
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

public struct SettingsAudioMetricsDTO: Codable, Equatable, Sendable {
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

    private enum CodingKeys: String, CodingKey {
        case capturedFrames
        case playedFrames
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
        case maximumCaptureCallbackFrames
        case maximumPlaybackCallbackFrames
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
    }

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
        averageTapToOutputLatencyNanoseconds: Double = 0
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
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            capturedFrames: try container.decodeIfPresent(UInt64.self, forKey: .capturedFrames) ?? 0,
            playedFrames: try container.decodeIfPresent(UInt64.self, forKey: .playedFrames) ?? 0,
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
            maximumCaptureCallbackFrames: try container.decodeIfPresent(Int.self, forKey: .maximumCaptureCallbackFrames) ?? 0,
            maximumPlaybackCallbackFrames: try container.decodeIfPresent(Int.self, forKey: .maximumPlaybackCallbackFrames) ?? 0,
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
            averageTapToOutputLatencyNanoseconds: try container.decodeIfPresent(Double.self, forKey: .averageTapToOutputLatencyNanoseconds) ?? 0
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
    public var selectedProfileID: UUID?
    public var draftProfile: EQProfile?
    public var activeProfileID: UUID?
    public var activeProfileName: String?
    public var fallbackProfileID: UUID?
    public var currentOutput: SettingsOutputDTO?
    public var currentOutputMappedProfileID: SettingsOptionalUUIDPatchDTO?
    public var aggregateBuffer: SettingsAggregateBufferDTO?
    public var profileStoreProtection: SettingsProfileStoreProtectionDTO?

    public init(
        statusMessage: String? = nil,
        isRunning: Bool? = nil,
        isPreviewing: Bool? = nil,
        selectedProfileID: UUID? = nil,
        draftProfile: EQProfile? = nil,
        activeProfileID: UUID? = nil,
        activeProfileName: String? = nil,
        fallbackProfileID: UUID? = nil,
        currentOutput: SettingsOutputDTO? = nil,
        currentOutputMappedProfileID: SettingsOptionalUUIDPatchDTO? = nil,
        aggregateBuffer: SettingsAggregateBufferDTO? = nil,
        profileStoreProtection: SettingsProfileStoreProtectionDTO? = nil
    ) {
        self.statusMessage = statusMessage
        self.isRunning = isRunning
        self.isPreviewing = isPreviewing
        self.selectedProfileID = selectedProfileID
        self.draftProfile = draftProfile
        self.activeProfileID = activeProfileID
        self.activeProfileName = activeProfileName
        self.fallbackProfileID = fallbackProfileID
        self.currentOutput = currentOutput
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
    public var currentOutputChannelCount: Int
    public var currentOutputBufferFrameSize: UInt32
    public var currentOutputMappedProfileID: UUID?
    public var aggregateBuffer: SettingsAggregateBufferDTO
    public var fallbackProfileID: UUID
    public var statusMessage: String
    public var metrics: SettingsAudioMetricsDTO
    public var isRunning: Bool
    public var isPreviewing: Bool
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
        case currentOutputChannelCount
        case currentOutputBufferFrameSize
        case currentOutputMappedProfileID
        case aggregateBuffer
        case fallbackProfileID
        case statusMessage
        case metrics
        case isRunning
        case isPreviewing
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
        currentOutputChannelCount: Int,
        currentOutputBufferFrameSize: UInt32,
        currentOutputMappedProfileID: UUID?,
        aggregateBuffer: SettingsAggregateBufferDTO = SettingsAggregateBufferDTO(),
        fallbackProfileID: UUID,
        statusMessage: String,
        metrics: SettingsAudioMetricsDTO,
        isRunning: Bool,
        isPreviewing: Bool,
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
        self.currentOutputChannelCount = currentOutputChannelCount
        self.currentOutputBufferFrameSize = currentOutputBufferFrameSize
        self.currentOutputMappedProfileID = currentOutputMappedProfileID
        self.aggregateBuffer = aggregateBuffer
        self.fallbackProfileID = fallbackProfileID
        self.statusMessage = statusMessage
        self.metrics = metrics
        self.isRunning = isRunning
        self.isPreviewing = isPreviewing
        self.profileStoreProtection = profileStoreProtection
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            profiles: try container.decode([EQProfile].self, forKey: .profiles),
            selectedProfileID: try container.decode(UUID.self, forKey: .selectedProfileID),
            draftProfile: try container.decode(EQProfile.self, forKey: .draftProfile),
            activeProfileID: try container.decode(UUID.self, forKey: .activeProfileID),
            activeProfileName: try container.decode(String.self, forKey: .activeProfileName),
            currentOutputName: try container.decode(String.self, forKey: .currentOutputName),
            currentOutputUID: try container.decode(String.self, forKey: .currentOutputUID),
            currentOutputSampleRate: try container.decode(Double.self, forKey: .currentOutputSampleRate),
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
            currentOutputChannelCount: 0,
            currentOutputBufferFrameSize: 0,
            currentOutputMappedProfileID: nil,
            aggregateBuffer: SettingsAggregateBufferDTO(),
            fallbackProfileID: profile.id,
            statusMessage: "Connecting to GlassEQ...",
            metrics: SettingsAudioMetricsDTO(),
            isRunning: false,
            isPreviewing: false,
            profileStoreProtection: .unprotected
        )
    }
}

public enum SettingsCommand: Codable, Equatable, Sendable {
    case createProfile(SettingsProfileKind)
    case duplicateProfile(UUID)
    case deleteProfile(UUID)
    case applyProfile(EQProfile)
    case useProfileForCurrentOutput(EQProfile)
    case setFallback(EQProfile)
    case importProfile(format: SettingsImportFormat, name: String, text: String)
    case preview(EQProfile)
    case stopPreview
    case resetDiagnostics
    case setAggregateBufferMode(SettingsAggregateBufferMode)
    case retryAutomaticAggregateBuffer
    case retryAudioEngine
    case openPrivacySettings
    case startMetricsPolling
    case stopMetricsPolling
    case resetUnsupportedProfileStore
}

public struct SettingsCommandResponse: Codable, Equatable, Sendable {
    public var snapshot: SettingsSnapshotDTO?
    public var importSucceeded: Bool?

    public init(snapshot: SettingsSnapshotDTO? = nil, importSucceeded: Bool? = nil) {
        self.snapshot = snapshot
        self.importSucceeded = importSucceeded
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
