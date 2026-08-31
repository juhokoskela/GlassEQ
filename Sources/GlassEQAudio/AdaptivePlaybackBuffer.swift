import CoreAudio
import Foundation

public enum PlaybackBufferInstabilityReason: UInt8, Codable, Equatable, Sendable {
    case underrun = 1
    case adaptiveRenderFailure = 4
}

public enum PlaybackBufferRenegotiationCause: Equatable, Sendable {
    case instability(PlaybackBufferInstabilityReason)
    case stableDecay
}

public struct PlaybackBufferRenegotiation: Equatable, Sendable {
    public var outputName: String
    public var outputUID: String
    public var sampleRate: Double
    public var previousFrameSize: UInt32
    public var frameSize: UInt32
    public var previousPlaybackTargetFrames: Int
    public var playbackTargetFrames: Int
    public var cause: PlaybackBufferRenegotiationCause

    public init(
        outputName: String,
        outputUID: String,
        sampleRate: Double,
        previousFrameSize: UInt32,
        frameSize: UInt32,
        previousPlaybackTargetFrames: Int? = nil,
        playbackTargetFrames: Int,
        cause: PlaybackBufferRenegotiationCause
    ) {
        self.outputName = outputName
        self.outputUID = outputUID
        self.sampleRate = sampleRate
        self.previousFrameSize = previousFrameSize
        self.frameSize = frameSize
        self.previousPlaybackTargetFrames = previousPlaybackTargetFrames ?? playbackTargetFrames
        self.playbackTargetFrames = playbackTargetFrames
        self.cause = cause
    }
}

struct PlaybackBufferCalibrationEvent: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case instability
        case stabilized
    }

    var kind: Kind
    var timestamp: Date
    var reason: PlaybackBufferInstabilityReason?
    var previousFrameSize: UInt32?
    var resultingFrameSize: UInt32
    var previousTargetFrames: UInt32?
    var resultingTargetFrames: UInt32?
}

struct PersistedPlaybackBufferOperatingPoint: Codable, Equatable, Sendable {
    var frameSize: UInt32
    var stableTargetFrames: UInt32?
    var probingTargetFrames: UInt32?
    var unstableThroughTargetFrames: UInt32?

    var preferredTargetFrames: Int? {
        (probingTargetFrames ?? stableTargetFrames).map(Int.init)
    }
}

struct PersistedPlaybackBufferCalibration: Codable, Equatable, Sendable {
    var outputUID: String
    var sampleRate: Double
    var tapSampleRate: Double? = nil
    var stableFrameSize: UInt32?
    var probingFrameSize: UInt32?
    var operatingPoints: [PersistedPlaybackBufferOperatingPoint]
    var events: [PlaybackBufferCalibrationEvent]

    var preferredFrameSize: UInt32? {
        probingFrameSize ?? stableFrameSize
    }

    func operatingPoint(for frameSize: UInt32) -> PersistedPlaybackBufferOperatingPoint? {
        operatingPoints.first { $0.frameSize == frameSize }
    }

    func preferredTargetFrames(for frameSize: UInt32) -> Int? {
        operatingPoint(for: frameSize)?.preferredTargetFrames
    }

    mutating func updateOperatingPoint(
        for frameSize: UInt32,
        _ update: (inout PersistedPlaybackBufferOperatingPoint) -> Void
    ) {
        if let index = operatingPoints.firstIndex(where: { $0.frameSize == frameSize }) {
            update(&operatingPoints[index])
            return
        }
        var operatingPoint = PersistedPlaybackBufferOperatingPoint(
            frameSize: frameSize,
            stableTargetFrames: nil,
            probingTargetFrames: nil,
            unstableThroughTargetFrames: nil
        )
        update(&operatingPoint)
        operatingPoints.append(operatingPoint)
    }
}

private struct LegacyPersistedPlaybackBufferSize: Codable {
    var outputUID: String
    var sampleRate: Double
    var frameSize: UInt32
}

private struct PersistedPlaybackBufferCalibrationDocument: Codable {
    static let currentSchemaVersion = 3

    var schemaVersion: Int
    var calibrations: [PersistedPlaybackBufferCalibration]
}

private struct PersistedPlaybackBufferCalibrationV1: Codable {
    var outputUID: String
    var sampleRate: Double
    var stableFrameSize: UInt32?
    var probingFrameSize: UInt32?
    var stableTargetFrames: UInt32?
    var probingTargetFrames: UInt32?
    var events: [PlaybackBufferCalibrationEvent]
}

private struct PersistedPlaybackBufferCalibrationDocumentV1: Codable {
    var schemaVersion: Int
    var calibrations: [PersistedPlaybackBufferCalibrationV1]
}

struct PlaybackBufferCalibrationProbe: Equatable, Sendable {
    var outputUID: String
    var sampleRate: Double
    var tapSampleRate: Double? = nil
    var frameSize: UInt32
    var targetFrames: Int
    var startedAt: ContinuousClock.Instant

    func hasCompletedProbation(
        at now: ContinuousClock.Instant,
        duration: Duration = PlaybackBufferCalibrationPolicy.probationDuration
    ) -> Bool {
        startedAt.duration(to: now) >= duration
    }
}

struct PlaybackBufferUnderrunEvidence: Sendable {
    // Reprime separates underrun signals into episodes, so the controller can corroborate them
    // from generation deltas without adding counters to the realtime callback.
    private var count = 0
    private var startedAt: ContinuousClock.Instant?

    mutating func record(
        eventCount: UInt64,
        at now: ContinuousClock.Instant,
        requiredCount: Int = PlaybackBufferAdaptationPolicy.requiredUnderrunCount,
        window: Duration = PlaybackBufferAdaptationPolicy.underrunWindow
    ) -> Bool {
        guard eventCount > 0, requiredCount > 0 else {
            return false
        }
        if let startedAt,
           startedAt.duration(to: now) > window {
            reset()
        }
        if startedAt == nil {
            startedAt = now
        }
        count += Int(min(eventCount, UInt64(requiredCount)))
        guard count >= requiredCount else {
            return false
        }
        reset()
        return true
    }

    mutating func reset() {
        count = 0
        startedAt = nil
    }
}

struct PlaybackBufferAdaptationEvidenceObservation: Equatable, Sendable {
    var observedDisturbance = false
    var escalationReason: PlaybackBufferInstabilityReason?
}

struct PlaybackBufferAdaptationEvidence: Sendable {
    private var handledInstabilityGeneration: UInt64 = 0
    private var handledTimestampDiscontinuities: UInt64 = 0
    private var underruns = PlaybackBufferUnderrunEvidence()

    mutating func reset(
        instabilityGeneration: UInt64,
        timestampDiscontinuities: UInt64
    ) {
        handledInstabilityGeneration = instabilityGeneration
        handledTimestampDiscontinuities = timestampDiscontinuities
        underruns.reset()
    }

    mutating func resetUnderrunEpisodes() {
        underruns.reset()
    }

    mutating func observe(
        instabilityGeneration: UInt64,
        reason: PlaybackBufferInstabilityReason,
        timestampDiscontinuities: UInt64,
        at now: ContinuousClock.Instant
    ) -> PlaybackBufferAdaptationEvidenceObservation {
        var observation = PlaybackBufferAdaptationEvidenceObservation()

        if timestampDiscontinuities < handledTimestampDiscontinuities {
            handledTimestampDiscontinuities = timestampDiscontinuities
        } else if timestampDiscontinuities != handledTimestampDiscontinuities {
            handledTimestampDiscontinuities = timestampDiscontinuities
            observation.observedDisturbance = true
        }

        guard instabilityGeneration != handledInstabilityGeneration else {
            return observation
        }
        let eventCount = instabilityGeneration &- handledInstabilityGeneration
        handledInstabilityGeneration = instabilityGeneration
        observation.observedDisturbance = true

        switch reason {
        case .underrun:
            if underruns.record(eventCount: eventCount, at: now) {
                observation.escalationReason = .underrun
            }
        case .adaptiveRenderFailure:
            underruns.reset()
            observation.escalationReason = .adaptiveRenderFailure
        }
        return observation
    }
}

struct UnresolvedPlaybackBufferInstability: Equatable, Sendable {
    var outputUID: String
    var sampleRate: Double
    var tapSampleRate: Double? = nil
    var frameSize: UInt32
    var targetFrames: Int
    var reason: PlaybackBufferInstabilityReason
}

struct PlaybackBufferInstabilityPersistenceGate: Sendable {
    private var lastInstability: UnresolvedPlaybackBufferInstability?

    mutating func shouldPersist(_ instability: UnresolvedPlaybackBufferInstability) -> Bool {
        guard lastInstability != instability else {
            return false
        }
        lastInstability = instability
        return true
    }

    mutating func persistenceFailed(for instability: UnresolvedPlaybackBufferInstability) {
        if lastInstability == instability {
            lastInstability = nil
        }
    }

    mutating func reset(outputUID: String? = nil) {
        guard outputUID == nil || lastInstability?.outputUID == outputUID else {
            return
        }
        lastInstability = nil
    }
}

struct AdaptivePlaybackRenderRecoveryPolicy {
    static let maximumRestartAttempts = 1

    static func shouldRestart(afterCompletedAttempts attempts: Int) -> Bool {
        attempts < maximumRestartAttempts
    }

    static func effectiveInstabilityReason(
        latest: PlaybackBufferInstabilityReason,
        renderFailureActive: Bool
    ) -> PlaybackBufferInstabilityReason {
        renderFailureActive ? .adaptiveRenderFailure : latest
    }
}

enum PlaybackBufferCalibrationPolicy {
    static let probationDuration: Duration = .seconds(60)
    static let maximumEventCount = 16

    static func shouldProbe(
        frameSize: UInt32,
        targetFrames: Int,
        calibration: PersistedPlaybackBufferCalibration?
    ) -> Bool {
        let operatingPoint = calibration?.operatingPoint(for: frameSize)
        return calibration?.stableFrameSize != frameSize
            || operatingPoint?.stableTargetFrames != UInt32(clamping: targetFrames)
            || calibration?.probingFrameSize != nil
            || operatingPoint?.probingTargetFrames != nil
    }
}

enum PlaybackBufferAdaptationPolicy {
    static let requiredUnderrunCount = 3
    static let underrunWindow: Duration = .seconds(2)
    static let decayDelay: Duration = .seconds(5 * 60)
}

enum PersistedPlaybackBufferCalibrationStore {
    static func defaultURL(nextTo restorationStoreURL: URL) -> URL {
        restorationStoreURL.deletingLastPathComponent()
            .appendingPathComponent("LearnedPlaybackBuffers.json", isDirectory: false)
    }

    static func load(from url: URL) -> [PersistedPlaybackBufferCalibration] {
        guard let data = try? Data(contentsOf: url) else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let document = try? decoder.decode(PersistedPlaybackBufferCalibrationDocument.self, from: data),
           document.schemaVersion == PersistedPlaybackBufferCalibrationDocument.currentSchemaVersion {
            return normalized(document.calibrations)
        }

        // Schema 2 persisted callback growth caused by timestamp reanchors. Do not migrate that
        // contaminated evidence; legacy and schema 1 records predate that escalation path.
        if let document = try? decoder.decode(PersistedPlaybackBufferCalibrationDocumentV1.self, from: data),
           document.schemaVersion == 1 {
            return normalized(document.calibrations.map(migrateV1Calibration))
        }

        guard let legacyRecords = try? JSONDecoder().decode([LegacyPersistedPlaybackBufferSize].self, from: data) else {
            return []
        }
        return normalized(legacyRecords.map {
            PersistedPlaybackBufferCalibration(
                outputUID: $0.outputUID,
                sampleRate: $0.sampleRate,
                stableFrameSize: $0.frameSize,
                probingFrameSize: nil,
                operatingPoints: [],
                events: []
            )
        })
    }

    static func calibration(
        outputUID: String,
        sampleRate: Double,
        tapSampleRate: Double? = nil,
        from url: URL
    ) -> PersistedPlaybackBufferCalibration? {
        let tapSampleRate = tapSampleRate ?? sampleRate
        return load(from: url).first {
            $0.outputUID == outputUID
                && normalizedSampleRate($0.sampleRate) == normalizedSampleRate(sampleRate)
                && normalizedSampleRate($0.tapSampleRate ?? $0.sampleRate)
                    == normalizedSampleRate(tapSampleRate)
        }
    }

    static func preferredFrameSize(
        outputUID: String,
        sampleRate: Double,
        tapSampleRate: Double? = nil,
        from url: URL
    ) -> UInt32? {
        calibration(
            outputUID: outputUID,
            sampleRate: sampleRate,
            tapSampleRate: tapSampleRate,
            from: url
        )?.preferredFrameSize
    }

    static func removeCalibrations(outputUID: String, at url: URL) throws {
        guard !outputUID.isEmpty else {
            return
        }
        let calibrations = load(from: url)
        let retainedCalibrations = calibrations.filter { $0.outputUID != outputUID }
        guard retainedCalibrations.count != calibrations.count else {
            return
        }
        try write(retainedCalibrations, to: url)
    }

    static func beginProbe(
        outputUID: String,
        sampleRate: Double,
        tapSampleRate: Double? = nil,
        frameSize: UInt32,
        targetFrames: Int,
        at url: URL
    ) throws {
        guard frameSize > 0, targetFrames > 0 else {
            return
        }
        try updateCalibration(
            outputUID: outputUID,
            sampleRate: sampleRate,
            tapSampleRate: tapSampleRate,
            at: url
        ) { calibration in
            calibration.probingFrameSize = frameSize
            calibration.updateOperatingPoint(for: frameSize) { operatingPoint in
                operatingPoint.probingTargetFrames = UInt32(clamping: targetFrames)
            }
        }
    }

    static func recordInstability(
        outputUID: String,
        sampleRate: Double,
        tapSampleRate: Double? = nil,
        previousFrameSize: UInt32,
        resultingFrameSize: UInt32,
        previousTargetFrames: Int,
        resultingTargetFrames: Int,
        reason: PlaybackBufferInstabilityReason,
        timestamp: Date = Date(),
        at url: URL
    ) throws {
        guard previousFrameSize > 0, resultingFrameSize > 0,
              previousTargetFrames > 0, resultingTargetFrames > 0 else {
            return
        }
        guard reason == .underrun else {
            return
        }
        try updateCalibration(
            outputUID: outputUID,
            sampleRate: sampleRate,
            tapSampleRate: tapSampleRate,
            at: url
        ) { calibration in
            let previousCalibration = calibration
            let previousTarget = UInt32(clamping: previousTargetFrames)
            if resultingFrameSize != previousFrameSize,
               calibration.stableFrameSize == previousFrameSize {
                calibration.stableFrameSize = nil
            }
            if resultingFrameSize != previousFrameSize,
               calibration.probingFrameSize == previousFrameSize {
                calibration.probingFrameSize = resultingFrameSize
            }
            if calibration.stableFrameSize == nil {
                calibration.probingFrameSize = resultingFrameSize
            }
            calibration.updateOperatingPoint(for: previousFrameSize) { operatingPoint in
                if operatingPoint.stableTargetFrames == previousTarget {
                    operatingPoint.stableTargetFrames = nil
                }
                operatingPoint.probingTargetFrames = nil
                operatingPoint.unstableThroughTargetFrames = max(
                    operatingPoint.unstableThroughTargetFrames ?? 0,
                    previousTarget
                )
            }
            calibration.updateOperatingPoint(for: resultingFrameSize) { operatingPoint in
                operatingPoint.probingTargetFrames = UInt32(clamping: resultingTargetFrames)
            }
            guard calibration != previousCalibration else {
                return
            }
            calibration.events.append(PlaybackBufferCalibrationEvent(
                kind: .instability,
                timestamp: timestamp,
                reason: reason,
                previousFrameSize: previousFrameSize,
                resultingFrameSize: resultingFrameSize,
                previousTargetFrames: previousTarget,
                resultingTargetFrames: UInt32(clamping: resultingTargetFrames)
            ))
        }
    }

    static func recordStable(
        outputUID: String,
        sampleRate: Double,
        tapSampleRate: Double? = nil,
        frameSize: UInt32,
        targetFrames: Int,
        timestamp: Date = Date(),
        at url: URL
    ) throws {
        guard frameSize > 0, targetFrames > 0 else {
            return
        }
        try updateCalibration(
            outputUID: outputUID,
            sampleRate: sampleRate,
            tapSampleRate: tapSampleRate,
            at: url
        ) { calibration in
            calibration.stableFrameSize = frameSize
            calibration.probingFrameSize = nil
            calibration.updateOperatingPoint(for: frameSize) { operatingPoint in
                operatingPoint.stableTargetFrames = UInt32(clamping: targetFrames)
                operatingPoint.probingTargetFrames = nil
            }
            calibration.events.append(PlaybackBufferCalibrationEvent(
                kind: .stabilized,
                timestamp: timestamp,
                reason: nil,
                previousFrameSize: nil,
                resultingFrameSize: frameSize,
                previousTargetFrames: nil,
                resultingTargetFrames: UInt32(clamping: targetFrames)
            ))
        }
    }

    private static func updateCalibration(
        outputUID: String,
        sampleRate: Double,
        tapSampleRate: Double?,
        at url: URL,
        update: (inout PersistedPlaybackBufferCalibration) -> Void
    ) throws {
        let tapSampleRate = tapSampleRate ?? sampleRate
        guard !outputUID.isEmpty, sampleRate > 0, tapSampleRate > 0 else {
            return
        }

        var calibrations = load(from: url)
        let index: Int
        if let existingIndex = calibrations.firstIndex(where: {
            $0.outputUID == outputUID
                && normalizedSampleRate($0.sampleRate) == normalizedSampleRate(sampleRate)
                && normalizedSampleRate($0.tapSampleRate ?? $0.sampleRate)
                    == normalizedSampleRate(tapSampleRate)
        }) {
            index = existingIndex
        } else {
            calibrations.append(PersistedPlaybackBufferCalibration(
                outputUID: outputUID,
                sampleRate: sampleRate,
                tapSampleRate: tapSampleRate,
                stableFrameSize: nil,
                probingFrameSize: nil,
                operatingPoints: [],
                events: []
            ))
            index = calibrations.index(before: calibrations.endIndex)
        }

        let previousCalibration = calibrations[index]
        update(&calibrations[index])
        guard calibrations[index] != previousCalibration else {
            return
        }
        calibrations[index].events = Array(
            calibrations[index].events.suffix(PlaybackBufferCalibrationPolicy.maximumEventCount)
        )
        try write(calibrations, to: url)
    }

    private static func write(_ calibrations: [PersistedPlaybackBufferCalibration], to url: URL) throws {
        let document = PersistedPlaybackBufferCalibrationDocument(
            schemaVersion: PersistedPlaybackBufferCalibrationDocument.currentSchemaVersion,
            calibrations: normalized(calibrations)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    private static func normalized(
        _ calibrations: [PersistedPlaybackBufferCalibration]
    ) -> [PersistedPlaybackBufferCalibration] {
        var uniqueRecords: [String: PersistedPlaybackBufferCalibration] = [:]
        for var calibration in calibrations where !calibration.outputUID.isEmpty && calibration.sampleRate > 0 {
            calibration.stableFrameSize = calibration.stableFrameSize.flatMap { $0 > 0 ? $0 : nil }
            calibration.probingFrameSize = calibration.probingFrameSize.flatMap { $0 > 0 ? $0 : nil }
            calibration.operatingPoints = normalizedOperatingPoints(calibration.operatingPoints)
            calibration.events = Array(
                calibration.events
                    .filter { $0.resultingFrameSize > 0 }
                    .sorted { $0.timestamp < $1.timestamp }
                    .suffix(PlaybackBufferCalibrationPolicy.maximumEventCount)
            )
            let key = recordKey(
                outputUID: calibration.outputUID,
                sampleRate: calibration.sampleRate,
                tapSampleRate: calibration.tapSampleRate ?? calibration.sampleRate
            )
            if var existing = uniqueRecords[key] {
                existing.stableFrameSize = maximum(existing.stableFrameSize, calibration.stableFrameSize)
                existing.probingFrameSize = maximum(existing.probingFrameSize, calibration.probingFrameSize)
                existing.operatingPoints = normalizedOperatingPoints(
                    existing.operatingPoints + calibration.operatingPoints
                )
                existing.events = Array(
                    (existing.events + calibration.events)
                        .sorted { $0.timestamp < $1.timestamp }
                        .suffix(PlaybackBufferCalibrationPolicy.maximumEventCount)
                )
                uniqueRecords[key] = existing
            } else {
                uniqueRecords[key] = calibration
            }
        }
        return uniqueRecords.values.sorted(by: areInAscendingOrder)
    }

    private static func normalizedOperatingPoints(
        _ operatingPoints: [PersistedPlaybackBufferOperatingPoint]
    ) -> [PersistedPlaybackBufferOperatingPoint] {
        var pointsByFrameSize: [UInt32: PersistedPlaybackBufferOperatingPoint] = [:]
        for var operatingPoint in operatingPoints where operatingPoint.frameSize > 0 {
            operatingPoint.stableTargetFrames = operatingPoint.stableTargetFrames.flatMap { $0 > 0 ? $0 : nil }
            operatingPoint.probingTargetFrames = operatingPoint.probingTargetFrames.flatMap { $0 > 0 ? $0 : nil }
            operatingPoint.unstableThroughTargetFrames = operatingPoint.unstableThroughTargetFrames.flatMap {
                $0 > 0 ? $0 : nil
            }
            guard operatingPoint.stableTargetFrames != nil
                    || operatingPoint.probingTargetFrames != nil
                    || operatingPoint.unstableThroughTargetFrames != nil else {
                continue
            }
            if var existing = pointsByFrameSize[operatingPoint.frameSize] {
                existing.stableTargetFrames = maximum(
                    existing.stableTargetFrames,
                    operatingPoint.stableTargetFrames
                )
                existing.probingTargetFrames = maximum(
                    existing.probingTargetFrames,
                    operatingPoint.probingTargetFrames
                )
                existing.unstableThroughTargetFrames = maximum(
                    existing.unstableThroughTargetFrames,
                    operatingPoint.unstableThroughTargetFrames
                )
                pointsByFrameSize[operatingPoint.frameSize] = existing
            } else {
                pointsByFrameSize[operatingPoint.frameSize] = operatingPoint
            }
        }
        return pointsByFrameSize.values.sorted { $0.frameSize < $1.frameSize }
    }

    private static func migrateV1Calibration(
        _ calibration: PersistedPlaybackBufferCalibrationV1
    ) -> PersistedPlaybackBufferCalibration {
        var migrated = PersistedPlaybackBufferCalibration(
            outputUID: calibration.outputUID,
            sampleRate: calibration.sampleRate,
            stableFrameSize: calibration.stableFrameSize,
            probingFrameSize: calibration.probingFrameSize,
            operatingPoints: [],
            events: calibration.events
        )
        if let frameSize = calibration.stableFrameSize,
           let targetFrames = calibration.stableTargetFrames {
            migrated.updateOperatingPoint(for: frameSize) { operatingPoint in
                operatingPoint.stableTargetFrames = targetFrames
            }
        }
        if let frameSize = calibration.probingFrameSize ?? calibration.stableFrameSize,
           let targetFrames = calibration.probingTargetFrames {
            migrated.updateOperatingPoint(for: frameSize) { operatingPoint in
                operatingPoint.probingTargetFrames = targetFrames
            }
        }
        return migrated
    }

    private static func maximum(_ lhs: UInt32?, _ rhs: UInt32?) -> UInt32? {
        switch (lhs, rhs) {
        case let (.some(lhs), .some(rhs)):
            max(lhs, rhs)
        case let (.some(value), .none), let (.none, .some(value)):
            value
        case (.none, .none):
            nil
        }
    }

    private static func recordKey(
        outputUID: String,
        sampleRate: Double,
        tapSampleRate: Double
    ) -> String {
        "\(outputUID)\u{0}\(normalizedSampleRate(sampleRate))\u{0}\(normalizedSampleRate(tapSampleRate))"
    }

    private static func areInAscendingOrder(
        _ lhs: PersistedPlaybackBufferCalibration,
        _ rhs: PersistedPlaybackBufferCalibration
    ) -> Bool {
        if lhs.outputUID == rhs.outputUID {
            if lhs.sampleRate == rhs.sampleRate {
                return (lhs.tapSampleRate ?? lhs.sampleRate) < (rhs.tapSampleRate ?? rhs.sampleRate)
            }
            return lhs.sampleRate < rhs.sampleRate
        }
        return lhs.outputUID < rhs.outputUID
    }

    private static func normalizedSampleRate(_ sampleRate: Double) -> Int {
        Int(sampleRate.rounded())
    }
}

struct AdaptivePlaybackBufferPolicy {
    private static let frameSizeLadder: [UInt32] = [64, 128, 256, 512]
    private static let reservoirStepFrames = 64
    static let maximumReservoirFrames = reservoirStepFrames * 3

    static func nextFrameSize(
        after currentFrameSize: UInt32,
        supportedRange: AudioBufferFrameSizeRange
    ) -> UInt32? {
        let minimum = supportedRange.minimum
        let maximum = min(supportedRange.maximum, frameSizeLadder.last ?? currentFrameSize)
        var candidates = frameSizeLadder.filter { $0 >= minimum && $0 <= maximum }
        if maximum >= minimum, !candidates.contains(maximum) {
            candidates.append(maximum)
        }
        return candidates.sorted().first(where: { $0 > currentFrameSize })
    }

    static func previousFrameSize(
        before currentFrameSize: UInt32,
        supportedRange: AudioBufferFrameSizeRange
    ) -> UInt32? {
        let minimum = supportedRange.minimum
        let maximum = min(supportedRange.maximum, currentFrameSize)
        var candidates = frameSizeLadder.filter { $0 >= minimum && $0 < maximum }
        if minimum < maximum, !candidates.contains(minimum) {
            candidates.append(minimum)
        }
        return candidates.max()
    }

    static func startupFrameSize(
        preferredFrameSize: UInt32,
        calibration: PersistedPlaybackBufferCalibration?,
        supportedRange: AudioBufferFrameSizeRange
    ) -> UInt32 {
        let calibratedFrameSize = calibration?.probingFrameSize
            ?? calibration?.stableFrameSize
            ?? 0
        return min(
            max(max(preferredFrameSize, calibratedFrameSize), supportedRange.minimum),
            supportedRange.maximum
        )
    }

    static func nextTargetFrames(
        callbackFrames: UInt32,
        after currentTargetFrames: Int,
        maximumReservoirFrames: Int = maximumReservoirFrames
    ) -> Int? {
        let callbackFrames = max(Int(callbackFrames), 1)
        let maximumTargetFrames = callbackFrames + max(maximumReservoirFrames, reservoirStepFrames)
        let nextTargetFrames = max(
            currentTargetFrames + reservoirStepFrames,
            minimumTargetFrames(callbackFrames: UInt32(callbackFrames))
        )
        return nextTargetFrames <= maximumTargetFrames ? nextTargetFrames : nil
    }

    static func minimumTargetFrames(callbackFrames: UInt32) -> Int {
        max(Int(callbackFrames) + reservoirStepFrames, reservoirStepFrames * 2)
    }

    static func nextDecayTargetFrames(
        callbackFrames: UInt32,
        stableTargetFrames: Int,
        unstableThroughTargetFrames: UInt32?,
        baselineTargetFrames: Int = 0
    ) -> Int? {
        let candidate = stableTargetFrames - reservoirStepFrames
        let minimum = max(
            minimumTargetFrames(callbackFrames: callbackFrames),
            baselineTargetFrames
        )
        guard candidate >= minimum,
              candidate > Int(unstableThroughTargetFrames ?? 0) else {
            return nil
        }
        return candidate
    }

    static func startupTargetFrames(
        baselineTargetFrames: Int,
        operatingPoint: PersistedPlaybackBufferOperatingPoint?
    ) -> Int {
        guard let operatingPoint else {
            return baselineTargetFrames
        }
        if let probingTargetFrames = operatingPoint.probingTargetFrames {
            return max(baselineTargetFrames, Int(probingTargetFrames))
        }
        return max(baselineTargetFrames, Int(operatingPoint.stableTargetFrames ?? 0))
    }
}

struct OutputCallbackTimestampTracker {
    private var expectedSampleTime: Double?

    mutating func reset() {
        expectedSampleTime = nil
    }

    mutating func observe(sampleTime: Double?, frameCount: Int) -> Bool {
        guard let sampleTime,
              sampleTime.isFinite,
              frameCount > 0 else {
            reset()
            return false
        }

        let discontinuity = expectedSampleTime.map { abs(sampleTime - $0) > 0.5 } ?? false
        expectedSampleTime = sampleTime + Double(frameCount)
        return discontinuity
    }
}
