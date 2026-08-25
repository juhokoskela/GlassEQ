import Foundation

enum AudioRenderWatchdogAction: Equatable, Sendable {
    case restart
    case stop
}

struct AudioRenderDeadlineBurstDetector: Sendable {
    static let defaultRequiredMisses: UInt64 = 3
    static let defaultWindow: Duration = .seconds(1)

    private let requiredMisses: UInt64
    private let window: Duration
    private var windowStartedAt: ContinuousClock.Instant?
    private var missesInWindow: UInt64 = 0

    init(
        requiredMisses: UInt64 = Self.defaultRequiredMisses,
        window: Duration = Self.defaultWindow
    ) {
        self.requiredMisses = max(requiredMisses, 1)
        self.window = window
    }

    mutating func observe(
        newMisses: UInt64,
        at now: ContinuousClock.Instant = .now
    ) -> Bool {
        guard newMisses > 0 else {
            return false
        }
        if let windowStartedAt,
           windowStartedAt.duration(to: now) <= window {
            let sum = missesInWindow.addingReportingOverflow(newMisses)
            missesInWindow = sum.overflow
                ? requiredMisses
                : min(sum.partialValue, requiredMisses)
        } else {
            windowStartedAt = now
            missesInWindow = newMisses
        }
        guard missesInWindow >= requiredMisses else {
            return false
        }
        reset()
        return true
    }

    mutating func reset() {
        windowStartedAt = nil
        missesInWindow = 0
    }
}

enum FixedBufferRecoveryAction: Equatable, Sendable {
    case rebuild(frameSize: UInt32)
    case temporarilyIncrease(frameSize: UInt32)
    case stop
}

struct FixedBufferRecoverySession: Sendable {
    static let defaultRepeatedFailureWindow: Duration = .seconds(60)

    private(set) var runtimeFrameSize: UInt32
    private let repeatedFailureWindow: Duration
    private var lastFailureAt: ContinuousClock.Instant?

    init(
        runtimeFrameSize: UInt32,
        repeatedFailureWindow: Duration = Self.defaultRepeatedFailureWindow
    ) {
        self.runtimeFrameSize = runtimeFrameSize
        self.repeatedFailureWindow = repeatedFailureWindow
    }

    mutating func observeFailure(
        at now: ContinuousClock.Instant = .now
    ) -> FixedBufferRecoveryAction {
        guard let lastFailureAt,
              lastFailureAt.duration(to: now) <= repeatedFailureWindow else {
            self.lastFailureAt = now
            return .rebuild(frameSize: runtimeFrameSize)
        }
        self.lastFailureAt = now
        switch runtimeFrameSize {
        case ..<32:
            runtimeFrameSize = 32
            return .temporarilyIncrease(frameSize: 32)
        case 32..<64:
            runtimeFrameSize = 64
            return .temporarilyIncrease(frameSize: 64)
        default:
            return .stop
        }
    }
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
