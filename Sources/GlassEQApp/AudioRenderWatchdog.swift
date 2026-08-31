import Foundation

enum AudioRenderWatchdogAction: Equatable, Sendable {
    case restart
    case stop
}

struct AudioRenderWatchdogRoute: Equatable, Sendable {
    var outputDeviceUID: String
    var nativeOutputStreamIndex: Int?
    var nominalSampleRate: Int64

    init(
        outputDeviceUID: String,
        nativeOutputStreamIndex: Int? = nil,
        nominalSampleRate: Double
    ) {
        self.outputDeviceUID = outputDeviceUID
        self.nativeOutputStreamIndex = nativeOutputStreamIndex
        self.nominalSampleRate = Int64(nominalSampleRate.rounded())
    }
}

struct AudioRenderWatchdog: Sendable {
    static let defaultStallThreshold: Duration = .seconds(3)
    static let defaultRepeatedFailureWindow: Duration = .seconds(60)

    private let stallThreshold: Duration
    private let repeatedFailureWindow: Duration
    private var observedGeneration: Int?
    private var lastPlayedFrames: UInt64?
    private var lastProgressAt: ContinuousClock.Instant?
    private var actionIssuedForGeneration: Int?
    private var lastAutomaticRecoveryAt: ContinuousClock.Instant?
    private var lastAutomaticRecoveryRoute: AudioRenderWatchdogRoute?

    init(
        stallThreshold: Duration = Self.defaultStallThreshold,
        repeatedFailureWindow: Duration = Self.defaultRepeatedFailureWindow
    ) {
        self.stallThreshold = stallThreshold
        self.repeatedFailureWindow = repeatedFailureWindow
    }

    mutating func observe(
        generation: Int,
        route: AudioRenderWatchdogRoute,
        isRunning: Bool,
        playedFrames: UInt64,
        at now: ContinuousClock.Instant = .now
    ) -> AudioRenderWatchdogAction? {
        guard isRunning else {
            pause()
            return nil
        }

        guard observedGeneration == generation else {
            observedGeneration = generation
            lastPlayedFrames = playedFrames
            lastProgressAt = now
            actionIssuedForGeneration = nil
            return nil
        }

        guard lastPlayedFrames == playedFrames else {
            lastPlayedFrames = playedFrames
            lastProgressAt = now
            return nil
        }
        guard actionIssuedForGeneration != generation,
              let lastProgressAt,
              lastProgressAt.duration(to: now) >= stallThreshold else {
            return nil
        }

        actionIssuedForGeneration = generation
        if lastAutomaticRecoveryRoute == route,
           let lastAutomaticRecoveryAt,
           lastAutomaticRecoveryAt.duration(to: now) < repeatedFailureWindow {
            return .stop
        }
        lastAutomaticRecoveryAt = now
        lastAutomaticRecoveryRoute = route
        return .restart
    }

    mutating func pause() {
        observedGeneration = nil
        lastPlayedFrames = nil
        lastProgressAt = nil
        actionIssuedForGeneration = nil
    }

    mutating func reset() {
        pause()
        lastAutomaticRecoveryAt = nil
        lastAutomaticRecoveryRoute = nil
    }
}
