import AppKit
import GlassEQAudio
import GlassEQCore
import GlassEQSettingsIPC
import GlassEQSettingsUI
import SwiftUI

private enum GlassEQWindowID {
    static let inProcessSettings = "in-process-settings"
}

@main
struct GlassEQApp: App {
    @NSApplicationDelegateAdaptor(GlassEQAppDelegate.self) private var appDelegate
    @State private var model = GlassEQAppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(model: model)
                .frame(width: 340)
        } label: {
            Image(systemName: model.isRunning ? "slider.horizontal.3" : "slider.horizontal.2.gobackward")
                .accessibilityLabel(Text(model.menuBarAccessibilityLabel))
                .accessibilityValue(Text(model.statusMessage))
                .accessibilityHint(Text(localized("Opens GlassEQ controls")))
                .background {
                    InProcessSettingsPresenter(model: model)
                }
        }
        .menuBarExtraStyle(.window)

        Window(localized("Configure GlassEQ"), id: GlassEQWindowID.inProcessSettings) {
            SettingsView(model: model.inProcessSettingsViewModel())
                .frame(minWidth: 760, minHeight: 500)
                .onAppear {
                    NSApplication.shared.setActivationPolicy(.regular)
                    model.inProcessSettingsDidAppear()
                }
                .onDisappear {
                    model.inProcessSettingsDidDisappear()
                    NSApplication.shared.setActivationPolicy(.accessory)
                }
        }
        .defaultSize(width: 1180, height: 720)
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
    }
}

private struct InProcessSettingsPresenter: View {
    let model: GlassEQAppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: model.inProcessSettingsPresentationGeneration) {
                NSApplication.shared.setActivationPolicy(.regular)
                openWindow(id: GlassEQWindowID.inProcessSettings)
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
    }
}

final class GlassEQAppDelegate: NSObject, NSApplicationDelegate {
    @MainActor weak static var model: GlassEQAppModel?
    private static let allowImmediateTermination = NSLock()
    nonisolated(unsafe) private static var shouldAllowImmediateTermination = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Self.allowImmediateTermination.lock()
        let allowImmediateTermination = Self.shouldAllowImmediateTermination
        Self.shouldAllowImmediateTermination = false
        Self.allowImmediateTermination.unlock()
        if allowImmediateTermination {
            return .terminateNow
        }

        Task { @MainActor in
            guard let model = Self.model else {
                sender.reply(toApplicationShouldTerminate: true)
                return
            }
            await model.stopAcceptingSettingsCommandsAndWait()
            let shouldTerminate = await model.flushStoreBeforeQuit()
            if shouldTerminate {
                await model.cleanupForTerminationAndWait()
            } else {
                model.resumeSettingsCommandsAfterCancelledQuit()
            }
            sender.reply(toApplicationShouldTerminate: shouldTerminate)
        }
        return .terminateLater
    }

    static func allowNextTerminationImmediately() {
        allowImmediateTermination.lock()
        shouldAllowImmediateTermination = true
        allowImmediateTermination.unlock()
    }
}

typealias ImportFormat = SettingsImportFormat
typealias SettingsSnapshot = SettingsSnapshotDTO

extension SettingsImportFormat {
    var title: String {
        switch self {
        case .autoEQ:
            localized("AutoEQ / EqualizerAPO")
        case .rew:
            localized("REW")
        }
    }
}

private extension Notification.Name {
    static let glassEQModelDidChange = Notification.Name("com.glasseq.modelDidChange")
    static let glassEQMetricsDidChange = Notification.Name("com.glasseq.metricsDidChange")
    static let glassEQBringSettingsToFront = Notification.Name("com.glasseq.bringSettingsToFront")
}

private enum AppBuildInfo {
    static var displayVersion: String {
        let bundle = Bundle.main
        if let releaseLabel = bundle.object(forInfoDictionaryKey: "GlassEQReleaseLabel") as? String,
           !releaseLabel.isEmpty {
            return releaseLabel
        }
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.9.1"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "13"
        return "v\(version) (\(build))"
    }
}

private enum WakeReconnectPolicy {
    static let maximumAttempts = 12
    static let retryDelay: Duration = .seconds(1)
}

private enum SessionActivationReconnectPolicy {
    static let reconnectDelay: Duration = .milliseconds(650)
}

private enum OutputChangeReconnectPolicy {
    static let routeSwitchDelay: Duration = .milliseconds(50)
    static let fallbackDelay: Duration = .milliseconds(350)
}

private let appResourcesBundle: Bundle = {
    let resourceBundleName = "GlassEQ_GlassEQApp.bundle"
    let candidates = [
        Bundle.main.resourceURL?.appendingPathComponent(resourceBundleName),
        Bundle.main.bundleURL.appendingPathComponent(resourceBundleName),
        Bundle.main.bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent(resourceBundleName)
    ].compactMap { $0 }

    for candidate in candidates {
        if let bundle = Bundle(url: candidate) {
            return bundle
        }
    }

    return Bundle.main
}()

func localized(_ value: String.LocalizationValue) -> String {
    String(localized: value, bundle: appResourcesBundle)
}

private func localizedDecimal(
    _ value: Double,
    minimumFractionDigits: Int,
    maximumFractionDigits: Int,
    signed: Bool = false
) -> String {
    let formatter = NumberFormatter()
    formatter.locale = .autoupdatingCurrent
    formatter.numberStyle = .decimal
    formatter.minimumFractionDigits = minimumFractionDigits
    formatter.maximumFractionDigits = maximumFractionDigits
    if signed {
        formatter.positivePrefix = formatter.plusSign
    }
    return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
}

private func localizedInteger(_ value: Int) -> String {
    value.formatted(.number.locale(.autoupdatingCurrent))
}

private func localizedInteger(_ value: UInt32) -> String {
    UInt64(value).formatted(.number.locale(.autoupdatingCurrent))
}

private func localizedInteger(_ value: UInt64) -> String {
    value.formatted(.number.locale(.autoupdatingCurrent))
}

private func localizedDecibels(_ value: Double, fractionDigits: Int = 1) -> String {
    let number = localizedDecimal(
        value,
        minimumFractionDigits: fractionDigits,
        maximumFractionDigits: fractionDigits,
        signed: true
    )
    return localized("\(number) dB")
}

private func localizedFrequency(_ value: Double) -> String {
    if value >= 1_000 {
        let number = localizedDecimal(value / 1_000, minimumFractionDigits: 1, maximumFractionDigits: 1)
        return localized("\(number) kHz")
    }
    let number = localizedDecimal(value, minimumFractionDigits: 0, maximumFractionDigits: 0)
    return localized("\(number) Hz")
}

private func localizedFrameCount(_ value: Int) -> String {
    let number = localizedInteger(value)
    return value == 1 ? localized("\(number) frame") : localized("\(number) frames")
}

private func localizedFrameCount(_ value: UInt32) -> String {
    let number = localizedInteger(value)
    return value == 1 ? localized("\(number) frame") : localized("\(number) frames")
}

private var noOutputName: String {
    localized("No output")
}

enum GlassEQAppLifecycleState: Equatable {
    case stopped
    case running
    case sleeping
    case waking
    case terminating
}

protocol AudioEngineControlling: AnyObject, Sendable {
    var state: AudioEngineState { get }
    var isUsingTransitionalHeadsetBackend: Bool { get }
    var isUsingPromotedHeadsetAggregate: Bool { get }

    func start(output: AudioOutputDevice, profile: EQProfile) throws
    func attemptHeadsetAggregatePromotion() throws -> HeadsetAggregatePromotionResult
    func rejectHeadsetAggregatePromotion()
    func aggregateRouteFingerprint(
        for output: AudioOutputDevice
    ) throws -> AggregateAudioRouteFingerprint?
    func setPreferredAggregateBufferFrameSize(_ frameSize: UInt32)
    func update(profile: EQProfile) throws
    @discardableResult func updateDSP(profile: EQProfile) -> Bool
    @discardableResult func beginProgrammeComparison(profile: EQProfile) -> Bool
    func setProgrammeComparisonSelection(_ selection: EQProgrammeComparisonSelection)
    func snapshotProgrammeComparison() -> EQProgrammeComparisonSnapshot
    func muteOutputForTransition()
    func stop()
    func snapshotMetrics() -> AudioEngineMetrics
    func resetDiagnostics()
    func setRuntimeFailureHandler(_ handler: (@Sendable (AudioEngineFailure) -> Void)?)
    #if DEBUG
    func simulateRenderStallForTesting()
    #endif
}

extension AudioEngineControlling {
    func beginProgrammeComparison(profile _: EQProfile) -> Bool { false }

    func setProgrammeComparisonSelection(_: EQProgrammeComparisonSelection) {}

    func snapshotProgrammeComparison() -> EQProgrammeComparisonSnapshot {
        EQProgrammeComparisonSnapshot()
    }

    func setRuntimeFailureHandler(
        _: (@Sendable (AudioEngineFailure) -> Void)?
    ) {}

    #if DEBUG
    func simulateRenderStallForTesting() {}
    #endif
}

extension SystemTapAudioEngine: AudioEngineControlling {}

protocol DefaultOutputLookingUp: Sendable {
    func defaultOutputDevice() throws -> AudioOutputDevice
}

struct CoreAudioDefaultOutputLookup: DefaultOutputLookingUp {
    func defaultOutputDevice() throws -> AudioOutputDevice {
        try CoreAudioDeviceQuery.defaultOutputDevice()
    }
}

typealias DefaultOutputObserverHandler = @Sendable (Result<AudioOutputDevice, Error>) -> Void

protocol DefaultOutputObserving: AnyObject, Sendable {
    func start(sendInitialValue: Bool) throws
    func stop()
    func startAsync(sendInitialValue: Bool) async throws
    func stopAsync() async
}

extension DefaultOutputObserving {
    func startAsync(sendInitialValue: Bool) async throws {
        try start(sendInitialValue: sendInitialValue)
    }

    func stopAsync() async {
        stop()
    }
}

extension DefaultOutputDeviceObserver: DefaultOutputObserving {}

protocol DefaultOutputObservingMaking {
    func makeObserver(onChange: @escaping DefaultOutputObserverHandler) -> any DefaultOutputObserving
}

struct CoreAudioDefaultOutputObserverFactory: DefaultOutputObservingMaking {
    func makeObserver(onChange: @escaping DefaultOutputObserverHandler) -> any DefaultOutputObserving {
        DefaultOutputDeviceObserver(onChange: onChange)
    }
}

@MainActor
protocol WorkspaceOpening {
    func open(_ url: URL) -> Bool
}

extension NSWorkspace: WorkspaceOpening {}

extension SettingsAudioMetricsDTO {
    init(_ metrics: AudioEngineMetrics) {
        self.init(
            capturedFrames: metrics.capturedFrames,
            playedFrames: metrics.playedFrames,
            playbackUnderrunFrames: metrics.playbackUnderrunFrames,
            droppedInputFrames: metrics.droppedInputFrames,
            droppedBufferedFrames: metrics.droppedBufferedFrames,
            ringGateContentionFailures: metrics.ringGateContentionFailures,
            saturatedSamples: metrics.saturatedSamples,
            currentBufferedFrames: metrics.currentBufferedFrames,
            maxBufferedFrames: metrics.maxBufferedFrames,
            maximumPlaybackBufferedFrames: metrics.maximumPlaybackBufferedFrames,
            minimumPlaybackBufferedFrames: metrics.minimumPlaybackBufferedFrames,
            averagePlaybackBufferedFrames: metrics.averagePlaybackBufferedFrames,
            playbackBufferObservations: metrics.playbackBufferObservations,
            inputTimestampDiscontinuities: metrics.inputTimestampDiscontinuities,
            outputTimestampDiscontinuities: metrics.outputTimestampDiscontinuities,
            pairedTimestampDiscontinuities: metrics.pairedTimestampDiscontinuities,
            maximumCaptureCallbackFrames: metrics.maximumCaptureCallbackFrames,
            maximumPlaybackCallbackFrames: metrics.maximumPlaybackCallbackFrames,
            renderDeadlineMisses: metrics.renderDeadlineMisses,
            callbackStartStarvations: metrics.callbackStartStarvations,
            renderOverruns: metrics.renderOverruns,
            playbackTimestampDiscontinuities: metrics.playbackTimestampDiscontinuities,
            playbackBufferRenegotiations: metrics.playbackBufferRenegotiations,
            adaptivePlaybackRenderFailures: metrics.adaptivePlaybackRenderFailures,
            playbackRateCorrectionPPM: metrics.playbackRateCorrectionPPM,
            playbackRateCorrectionSaturated: metrics.playbackRateCorrectionSaturated,
            playbackOccupancyTargetFrames: metrics.playbackOccupancyTargetFrames,
            filteredPlaybackOccupancyFrames: metrics.filteredPlaybackOccupancyFrames,
            playbackBufferSampleRate: metrics.playbackBufferSampleRate,
            playbackSampleRateConversionActive: metrics.playbackSampleRateConversionActive,
            tapToOutputLatencyObservations: metrics.tapToOutputLatencyObservations,
            minimumTapToOutputLatencyNanoseconds: metrics.minimumTapToOutputLatencyNanoseconds,
            maximumTapToOutputLatencyNanoseconds: metrics.maximumTapToOutputLatencyNanoseconds,
            averageTapToOutputLatencyNanoseconds: metrics.averageTapToOutputLatencyNanoseconds,
            renderTiming: SettingsAudioRenderTimingDTO(
                callbackStartLatenessObservations:
                    metrics.renderTiming.callbackStartLatenessObservations,
                callbackStartLatenessP9999Nanoseconds:
                    metrics.renderTiming.callbackStartLatenessP9999Nanoseconds,
                maximumCallbackStartLatenessNanoseconds:
                    metrics.renderTiming.maximumCallbackStartLatenessNanoseconds,
                directHeadObservations: metrics.renderTiming.directHeadObservations,
                directHeadP9999Nanoseconds: metrics.renderTiming.directHeadP9999Nanoseconds,
                maximumDirectHeadNanoseconds: metrics.renderTiming.maximumDirectHeadNanoseconds,
                tailWorkObservations: metrics.renderTiming.tailWorkObservations,
                tailWorkP9999Nanoseconds: metrics.renderTiming.tailWorkP9999Nanoseconds,
                maximumTailWorkNanoseconds: metrics.renderTiming.maximumTailWorkNanoseconds,
                totalRenderObservations: metrics.renderTiming.totalRenderObservations,
                totalRenderP9999Nanoseconds: metrics.renderTiming.totalRenderP9999Nanoseconds,
                maximumTotalRenderNanoseconds: metrics.renderTiming.maximumTotalRenderNanoseconds,
                completionLatenessObservations:
                    metrics.renderTiming.completionLatenessObservations,
                completionLatenessP9999Nanoseconds:
                    metrics.renderTiming.completionLatenessP9999Nanoseconds,
                maximumCompletionLatenessNanoseconds:
                    metrics.renderTiming.maximumCompletionLatenessNanoseconds,
                tailCompletionObservations: metrics.renderTiming.tailCompletionObservations,
                minimumTailCompletionSlackFrames:
                    metrics.renderTiming.minimumTailCompletionSlackFrames,
                tailDeadlineMisses: metrics.renderTiming.tailDeadlineMisses
            )
        )
    }
}

private actor ProfileStoreWriter {
    private let url: URL

    init(url: URL) {
        self.url = url
    }

    func save(_ store: ProfileStore) throws {
        try ProfilePersistence.save(store, to: url)
    }

    func saveAndSynchronize(_ store: ProfileStore) throws {
        try save(store)
        let handle = try FileHandle(forReadingFrom: url)
        defer {
            try? handle.close()
        }
        try handle.synchronize()
    }

    func resetUnsupportedStore(timestamp: Date = Date()) throws -> (store: ProfileStore, backupURL: URL) {
        try ProfilePersistence.resetUnsupportedStore(at: url, timestamp: timestamp)
    }
}

private final class EngineWorkExecutor: @unchecked Sendable {
    private let lock = NSLock()
    private var tail: Task<Void, Never> = Task {}

    @discardableResult
    func enqueue<T: Sendable>(
        priority: TaskPriority? = nil,
        _ operation: @Sendable @escaping () -> T
    ) -> Task<T, Never> {
        lock.lock()
        let previous = tail
        let task = Task(priority: priority) {
            _ = await previous.value
            return operation()
        }
        tail = Task {
            _ = await task.value
        }
        lock.unlock()
        return task
    }
}

@MainActor
@Observable
final class GlassEQAppModel {
    var currentOutputName = noOutputName
    var currentOutputUID = ""
    var currentOutputSampleRate = 0.0
    var currentOutputChannelCount = 0
    var currentOutputBufferFrameSize: UInt32 = 0
    var statusMessage = localized("Stopped")
    var isRunning = false
    var activeProfile: EQProfile
    var profileStore: ProfileStore
    var selectedProfileID: UUID
    var draftProfile: EQProfile
    var importFormat: ImportFormat = .autoEQ
    var importName = localized("Imported Profile")
    var importText = ""
    var engineMetrics = AudioEngineMetrics()
    var previewReturnProfile: EQProfile?
    var programmeComparison = EQProgrammeComparisonSnapshot()
    private var programmeComparisonReturnProfile: EQProfile?
    private(set) var lifecycleState: GlassEQAppLifecycleState = .stopped

    private let engine: any AudioEngineControlling
    private let defaultOutputLookup: any DefaultOutputLookingUp
    private let observerFactory: any DefaultOutputObservingMaking
    private let workspaceOpener: any WorkspaceOpening
    private let profileImportOperation: @Sendable (ImportFormat, String, String) async -> Result<EQProfile, any Error>
    private let outputChangeSettlingDelayOverride: Duration?
    private let wakeReconnectDelayOverride: Duration?
    private let saveDebounceDelay: Duration
    private var observer: (any DefaultOutputObserving)?
    private var metricsTask: Task<Void, Never>?
    private var programmeComparisonTask: Task<Void, Never>?
    private var renderWatchdogTask: Task<Void, Never>?
    private var renderWatchdog: AudioRenderWatchdog
    private let renderWatchdogPollInterval: Duration
    private var aggregateStabilityTask: Task<Void, Never>?
    private var headsetAggregatePromotionTask: Task<Void, Never>?
    private var outputChangeTask: Task<Void, Never>?
    private var engineStartTask: Task<Void, Never>?
    private var activeSettingsCommandCount = 0
    private var acceptsSettingsCommands = true
    private var settingsCommandDrainWaiters: [CheckedContinuation<Void, Never>] = []
    private var pendingSaveTask: Task<Void, Never>?
    private var lifecycleObserverTokens: [NSObjectProtocol] = []
    private var wasRunningBeforeSleep = false
    private var wakeReconnectAttempts = 0
    private var observerCallbackGeneration = 0
    private var outputChangeGeneration = 0
    private var engineStartGeneration = 0
    private var pendingEngineStartOutput: AudioOutputDevice?
    private var activeAggregateRoute: AggregateAudioRouteFingerprint?
    private let aggregateBufferPolicyStore: AggregateBufferPolicyStore
    private let aggregateStabilitySettlingDelay: Duration
    private let aggregateCleanSessionDuration: Duration
    private let headsetAggregatePromotionDelay: Duration
    private var headsetPromotionAttemptedOutputGeneration: Int?
    private let aggregateBufferNotifier: any AggregateBufferChangeNotifying
    private var pendingAggregateBufferIncrease: PendingAggregateBufferIncrease?
    private var fixedBufferRecovery: FixedBufferRecovery?
    private let storeWriter: ProfileStoreWriter
    private var profilePersistenceMode: ProfilePersistenceMode = .normal
    @ObservationIgnored private let engineWorkExecutor = EngineWorkExecutor()
    @ObservationIgnored private let confirmedEngineProfileState = ConfirmedEngineProfileState()
    @ObservationIgnored lazy var settingsCoordinator = SettingsCoordinator(model: self)
    @ObservationIgnored var inProcessSettingsViewModelStorage: GlassEQSettingsViewModel?
    @ObservationIgnored var inProcessSettingsIsPresented = false
    @ObservationIgnored var inProcessSettingsPresentationIsPending = false
    var inProcessSettingsPresentationGeneration = 0

    private enum ProfilePersistenceMode: Equatable, Sendable {
        case normal
        case unsupportedSchema(version: Int, maximumSupported: Int)

        var isProtected: Bool {
            if case .unsupportedSchema = self {
                return true
            }
            return false
        }
    }

    private struct ProfileRollback: Sendable {
        var profileStore: ProfileStore
        var activeProfile: EQProfile
        var selectedProfileID: UUID
        var draftProfile: EQProfile
        var previewReturnProfile: EQProfile?
    }

    private struct PendingAggregateBufferIncrease: Sendable {
        enum Kind: Sendable {
            case automatic
            case fixedRebuild
            case fixedTemporaryIncrease
        }

        var route: AggregateAudioRouteFingerprint
        var outputName: String
        var previousFrameSize: UInt32
        var newFrameSize: UInt32
        var kind: Kind = .automatic
    }

    private struct FixedBufferRecovery: Sendable {
        var route: AggregateAudioRouteFingerprint
        var preferredFrameSize: UInt32
        var session: FixedBufferRecoverySession
    }

    private struct EngineProfileConfirmation: Sendable {
        var activeProfile: EQProfile

        init(_ rollback: ProfileRollback) {
            activeProfile = rollback.activeProfile
        }
    }

    private struct FailedEngineProfileAttempt: Sendable {
        struct MappingChange: Sendable {
            var outputUID: String
            var previous: OutputDeviceProfileMapping?
            var previousIndex: Int?
            var attempted: OutputDeviceProfileMapping?
        }

        var id = UUID()
        var profileID: UUID
        var previousProfile: EQProfile?
        var previousProfileIndex: Int?
        var attemptedProfile: EQProfile?
        var previousSelectedProfileID: UUID
        var attemptedSelectedProfileID: UUID
        var previousDraftProfile: EQProfile
        var attemptedDraftProfile: EQProfile
        var previousPreviewReturnProfile: EQProfile?
        var attemptedPreviewReturnProfile: EQProfile?
        var mappingChanges: [MappingChange]

        init(profileID: UUID, previous: ProfileRollback?, attempted: ProfileRollback) {
            self.profileID = profileID
            attemptedProfile = attempted.profileStore.profiles.first { $0.id == profileID }
            attemptedSelectedProfileID = attempted.selectedProfileID
            attemptedDraftProfile = attempted.draftProfile
            attemptedPreviewReturnProfile = attempted.previewReturnProfile

            guard let previous else {
                previousProfile = attemptedProfile
                previousProfileIndex = attempted.profileStore.profiles.firstIndex { $0.id == profileID }
                previousSelectedProfileID = attempted.selectedProfileID
                previousDraftProfile = attempted.draftProfile
                previousPreviewReturnProfile = attempted.previewReturnProfile
                mappingChanges = []
                return
            }
            previousProfile = previous.profileStore.profiles.first { $0.id == profileID }
            previousProfileIndex = previous.profileStore.profiles.firstIndex { $0.id == profileID }
            previousSelectedProfileID = previous.selectedProfileID
            previousDraftProfile = previous.draftProfile
            previousPreviewReturnProfile = previous.previewReturnProfile
            let outputUIDs = Set(previous.profileStore.outputMappings.map(\.outputDeviceUID))
                .union(attempted.profileStore.outputMappings.map(\.outputDeviceUID))
            mappingChanges = outputUIDs.compactMap { outputUID in
                let previousMapping = previous.profileStore.outputMappings.first {
                    $0.outputDeviceUID == outputUID
                }
                let attemptedMapping = attempted.profileStore.outputMappings.first {
                    $0.outputDeviceUID == outputUID
                }
                guard previousMapping != attemptedMapping else {
                    return nil
                }
                return MappingChange(
                    outputUID: outputUID,
                    previous: previousMapping,
                    previousIndex: previous.profileStore.outputMappings.firstIndex {
                        $0.outputDeviceUID == outputUID
                    },
                    attempted: attemptedMapping
                )
            }
        }
    }

    private struct EngineProfileReconciliation: Sendable {
        var confirmation: EngineProfileConfirmation
        var failedAttempts: [FailedEngineProfileAttempt]
    }

    private final class ConfirmedEngineProfileState: @unchecked Sendable {
        private let lock = NSLock()
        private var confirmation: EngineProfileConfirmation?
        private var failedAttempts: [FailedEngineProfileAttempt] = []

        func reconciliation(
            after failedAttempt: FailedEngineProfileAttempt,
            fallback: EngineProfileConfirmation?
        ) -> EngineProfileReconciliation? {
            lock.withLock {
                appendIfNeeded(failedAttempt)
                guard let confirmation = confirmation ?? fallback else {
                    return nil
                }
                return EngineProfileReconciliation(
                    confirmation: confirmation,
                    failedAttempts: failedAttempts
                )
            }
        }

        func recordCancelledAttempt(_ failedAttempt: FailedEngineProfileAttempt) {
            lock.withLock {
                appendIfNeeded(failedAttempt)
            }
        }

        func activeProfileID() -> UUID? {
            lock.withLock { confirmation?.activeProfile.id }
        }

        func confirm(_ confirmation: EngineProfileConfirmation) {
            lock.withLock {
                self.confirmation = confirmation
                failedAttempts = []
            }
        }

        func acknowledge(_ reconciliation: EngineProfileReconciliation) {
            guard let lastAppliedID = reconciliation.failedAttempts.last?.id else {
                return
            }
            lock.withLock {
                guard let lastAppliedIndex = failedAttempts.firstIndex(where: { $0.id == lastAppliedID }) else {
                    return
                }
                failedAttempts.removeFirst(lastAppliedIndex + 1)
            }
        }

        func clear() {
            lock.withLock {
                confirmation = nil
                failedAttempts = []
            }
        }

        private func appendIfNeeded(_ failedAttempt: FailedEngineProfileAttempt) {
            guard !failedAttempts.contains(where: { $0.id == failedAttempt.id }) else {
                return
            }
            failedAttempts.append(failedAttempt)
        }
    }

    private enum EngineWork: Sendable {
        case start(
            output: AudioOutputDevice,
            profile: EQProfile,
            rollback: ProfileRollback?,
            aggregateBufferFrameSize: UInt32
        )
        case restart(profile: EQProfile, rollback: ProfileRollback?)
        case recoverRenderStall(
            output: AudioOutputDevice,
            profile: EQProfile,
            aggregateBufferFrameSize: UInt32
        )

        var profile: EQProfile {
            switch self {
            case .start(_, let profile, _, _),
                 .restart(let profile, _),
                 .recoverRenderStall(_, let profile, _):
                return profile
            }
        }

        var rollback: ProfileRollback? {
            switch self {
            case .start(_, _, let rollback, _), .restart(_, let rollback):
                return rollback
            case .recoverRenderStall:
                return nil
            }
        }
    }

    private enum EngineWorkResult: Sendable {
        case success(AudioOutputDevice)
        case profileChangeNotApplied(any Error, AudioOutputDevice, EngineProfileReconciliation?)
        case failure(any Error, AudioOutputDevice?)
        case cancelled
    }

    private enum HeadsetPromotionWorkResult: Sendable {
        case success(HeadsetAggregatePromotionResult)
        case failure(String)
    }

    private struct EngineWorkFailure: Error, LocalizedError, Sendable {
        var message: String

        var errorDescription: String? {
            message
        }
    }

    init(
        profileStore providedStore: ProfileStore? = nil,
        storeURL: URL = ProfilePersistence.defaultStoreURL(),
        engine: any AudioEngineControlling = SystemTapAudioEngine(),
        defaultOutputLookup: any DefaultOutputLookingUp = CoreAudioDefaultOutputLookup(),
        observerFactory: any DefaultOutputObservingMaking = CoreAudioDefaultOutputObserverFactory(),
        autoStart: Bool = true,
        installLifecycleObservers shouldInstallLifecycleObservers: Bool = true,
        registerAppDelegate: Bool = true,
        workspaceOpener: any WorkspaceOpening = NSWorkspace.shared,
        profileImportOperation: (@Sendable (ImportFormat, String, String) async -> Result<EQProfile, any Error>)? = nil,
        saveDebounceDelay: Duration = .milliseconds(250),
        outputChangeSettlingDelayOverride: Duration? = nil,
        wakeReconnectDelayOverride: Duration? = nil,
        aggregateBufferPolicyURL: URL? = nil,
        aggregateStabilitySettlingDelay: Duration = .seconds(2),
        aggregateCleanSessionDuration: Duration = .seconds(5 * 60),
        headsetAggregatePromotionDelay: Duration = .seconds(6),
        renderWatchdogStallThreshold: Duration = AudioRenderWatchdog.defaultStallThreshold,
        renderWatchdogRepeatedFailureWindow: Duration = AudioRenderWatchdog.defaultRepeatedFailureWindow,
        renderWatchdogPollInterval: Duration = .milliseconds(500),
        aggregateBufferNotifier: (any AggregateBufferChangeNotifying)? = nil
    ) {
        let loadResult: ProfileStoreLoadResult?
        let loadedStore: ProfileStore
        if let providedStore {
            loadResult = nil
            loadedStore = providedStore
        } else {
            let result = ProfilePersistence.load(from: storeURL)
            loadResult = result
            loadedStore = result.store
        }
        let persistenceMode: ProfilePersistenceMode
        if case let .unsupportedSchemaVersion(version, maximumSupported) = loadResult?.status {
            persistenceMode = .unsupportedSchema(version: version, maximumSupported: maximumSupported)
        } else {
            persistenceMode = .normal
        }
        let initialProfile = loadedStore.profile(forOutputUID: nil)
        self.profileStore = loadedStore
        self.activeProfile = initialProfile
        self.selectedProfileID = initialProfile.id
        self.draftProfile = initialProfile
        self.engine = engine
        self.defaultOutputLookup = defaultOutputLookup
        self.observerFactory = observerFactory
        self.workspaceOpener = workspaceOpener
        self.profileImportOperation = profileImportOperation ?? { format, name, text in
            await Task.detached(priority: .userInitiated) {
                Result<EQProfile, Error> {
                    switch format {
                    case .autoEQ:
                        try EQProfileTextImporter.importAutoEQ(text, profileName: name)
                    case .rew:
                        try EQProfileTextImporter.importREW(text, profileName: name)
                    }
                }
            }.value
        }
        self.saveDebounceDelay = saveDebounceDelay
        self.outputChangeSettlingDelayOverride = outputChangeSettlingDelayOverride
        self.wakeReconnectDelayOverride = wakeReconnectDelayOverride
        self.storeWriter = ProfileStoreWriter(url: storeURL)
        self.aggregateBufferPolicyStore = AggregateBufferPolicyStore(
            url: aggregateBufferPolicyURL ?? AggregateBufferPolicyStore.defaultURL()
        )
        self.aggregateStabilitySettlingDelay = aggregateStabilitySettlingDelay
        self.aggregateCleanSessionDuration = aggregateCleanSessionDuration
        self.headsetAggregatePromotionDelay = headsetAggregatePromotionDelay
        self.renderWatchdog = AudioRenderWatchdog(
            stallThreshold: renderWatchdogStallThreshold,
            repeatedFailureWindow: renderWatchdogRepeatedFailureWindow
        )
        self.renderWatchdogPollInterval = renderWatchdogPollInterval
        self.aggregateBufferNotifier = aggregateBufferNotifier
            ?? (registerAppDelegate
                ? AggregateBufferNotifier.shared
                : NoopAggregateBufferNotifier())
        self.profilePersistenceMode = persistenceMode
        engine.setRuntimeFailureHandler { [weak self] failure in
            Task { @MainActor in
                self?.handleRuntimeAudioEngineFailure(failure)
            }
        }
        if registerAppDelegate {
            GlassEQAppDelegate.model = self
            AggregateBufferNotifier.shared.start()
            lifecycleObserverTokens.append(
                NotificationCenter.default.addObserver(
                    forName: .glassEQOpenOutputSettingsRequest,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in
                        self?.openAggregateBufferSettings()
                    }
                }
            )
        }
        if shouldInstallLifecycleObservers {
            installLifecycleObservers()
        }
        if let loadResult {
            if let loadStatusMessage = Self.profileStoreLoadStatusMessage(loadResult.status) {
                statusMessage = loadStatusMessage
            }
        } else {
            let repairSummary = profileStore.repairReferences()
            if repairSummary.didRepair {
                statusMessage = Self.profileStoreRepairStatus(repairSummary)
                saveStore()
            }
        }

        if autoStart {
            Task { @MainActor [weak self] in
                self?.start()
            }
        }
    }

    var hasUnsavedDraft: Bool {
        draftProfile != selectedProfile
    }

    var selectedProfile: EQProfile {
        profileStore.profiles.first(where: { $0.id == selectedProfileID }) ?? activeProfile
    }

    var menuBarAccessibilityLabel: String {
        if activeProfile.isBypassed {
            return localized("GlassEQ disabled")
        }
        return isRunning ? localized("GlassEQ active") : localized("GlassEQ stopped")
    }

    var currentOutputMappedProfileID: UUID? {
        profileStore.outputMappings.first(where: { $0.outputDeviceUID == currentOutputUID })?.profileID
    }

    func settingsSnapshot() -> SettingsSnapshot {
        SettingsSnapshot(
            profiles: profileStore.profiles,
            selectedProfileID: selectedProfileID,
            draftProfile: draftProfile,
            activeProfileID: activeProfile.id,
            activeProfileName: activeProfile.name,
            currentOutputName: currentOutputName,
            currentOutputUID: currentOutputUID,
            currentOutputSampleRate: currentOutputSampleRate,
            currentOutputChannelCount: currentOutputChannelCount,
            currentOutputBufferFrameSize: currentOutputBufferFrameSize,
            currentOutputMappedProfileID: currentOutputMappedProfileID,
            aggregateBuffer: aggregateBufferSnapshot(),
            fallbackProfileID: profileStore.fallbackProfileID,
            statusMessage: statusMessage,
            metrics: SettingsAudioMetricsDTO(engineMetrics),
            isRunning: isRunning,
            isPreviewing: previewReturnProfile != nil,
            programmeComparison: settingsProgrammeComparisonSnapshot(),
            profileStoreProtection: profileStoreProtectionSnapshot()
        )
    }

    private func settingsProgrammeComparisonSnapshot() -> EQProgrammeComparisonSnapshot {
        guard programmeComparisonReturnProfile != nil else {
            return EQProgrammeComparisonSnapshot()
        }
        var snapshot = programmeComparison
        snapshot.isActive = true
        return snapshot
    }

    private func aggregateBufferSnapshot() -> SettingsAggregateBufferDTO {
        guard let activeAggregateRoute else {
            return SettingsAggregateBufferDTO()
        }
        let selection = aggregateBufferPolicyStore.selection(for: activeAggregateRoute)
        return SettingsAggregateBufferDTO(
            mode: selection.mode,
            automaticFrameSize: selection.automaticFrameSize,
            isAvailable: lifecycleState == .running
                && isRunning
                && engineStartTask == nil
                && engineIsRunning
        )
    }

    private var engineIsRunning: Bool {
        if case .running = engine.state {
            return true
        }
        return false
    }

    private func profileStoreProtectionSnapshot() -> SettingsProfileStoreProtectionDTO {
        switch profilePersistenceMode {
        case .normal:
            return .unprotected
        case let .unsupportedSchema(version, maximumSupported):
            return SettingsProfileStoreProtectionDTO(
                isProtected: true,
                message: localized("Profiles are read-only because this store was written by a newer GlassEQ schema \(version). This build supports schema \(maximumSupported)."),
                resetButtonTitle: localized("Reset profiles for this version")
            )
        }
    }

    func ensureProfileStoreWritable() throws {
        guard !profilePersistenceMode.isProtected else {
            throw SettingsCommandFailure(message: unsupportedProfileStoreEditMessage())
        }
    }

    private func unsupportedProfileStoreEditMessage() -> String {
        switch profilePersistenceMode {
        case .normal:
            return ""
        case .unsupportedSchema:
            return localized("Profile store was written by a newer GlassEQ; reset profiles or use a newer build.")
        }
    }

    func start() {
        guard lifecycleState != .terminating,
              lifecycleState != .sleeping else {
            return
        }
        startObserver(sendInitialValue: true)
    }

    private func startObserver(sendInitialValue: Bool) {
        guard lifecycleState != .terminating,
              lifecycleState != .sleeping else {
            return
        }

        guard observer == nil else {
            if let observer {
                startObserverAsync(observer, generation: observerCallbackGeneration, sendInitialValue: sendInitialValue)
            }
            return
        }

        observerCallbackGeneration += 1
        let generation = observerCallbackGeneration
        let observer = observerFactory.makeObserver { [weak self] result in
            Task { @MainActor in
                self?.scheduleDefaultOutputChange(result, observerGeneration: generation)
            }
        }
        self.observer = observer

        startObserverAsync(observer, generation: generation, sendInitialValue: sendInitialValue)
    }

    private func startObserverAsync(
        _ observer: any DefaultOutputObserving,
        generation: Int,
        sendInitialValue: Bool
    ) {
        Task { @MainActor [weak self, weak observer] in
            guard let self,
                  let observer else {
                return
            }
            do {
                try await observer.startAsync(sendInitialValue: sendInitialValue)
            } catch {
                guard self.observer === observer,
                      self.observerCallbackGeneration == generation else {
                    return
                }
                statusMessage = localized("Default output observer failed: \(error.localizedDescription)")
                if lifecycleState == .waking {
                    scheduleWakeReconnectRetry(status: statusMessage)
                } else {
                    lifecycleState = .stopped
                    isRunning = false
                }
            }
            guard self.observer === observer,
                  self.observerCallbackGeneration == generation else {
                return
            }
            notifyModelDidChange()
        }
    }

    func stop() {
        guard lifecycleState != .terminating else {
            return
        }
        wasRunningBeforeSleep = false
        stopObserver()
        invalidatePendingOutputChange()
        invalidatePendingEngineStart()
        metricsTask?.cancel()
        metricsTask = nil
        renderWatchdogTask?.cancel()
        renderWatchdogTask = nil
        renderWatchdog.reset()
        scheduleEngineStop(updateMetrics: true)
        previewReturnProfile = nil
        clearProgrammeComparisonSession()
        lifecycleState = .stopped
        isRunning = false
        statusMessage = localized("Stopped")
        notifyModelDidChange()
    }

    func selectProfile(_ id: UUID) {
        guard let profile = profileStore.profiles.first(where: { $0.id == id }) else {
            return
        }

        selectedProfileID = id
        draftProfile = profile
        notifyModelDidChange()
    }

    func applyDraft() {
        do {
            try apply(profile: draftProfile)
        } catch {
            reportProfileActionFailure(error)
        }
    }

    func apply(profile: EQProfile) throws {
        try ensureProfileStoreWritable()
        let rollback = profileRollback()
        var store = profileStore
        upsertProfile(profile, in: &store)
        try ProfilePersistence.validateForCommit(store)

        profileStore = store
        activeProfile = profile
        selectedProfileID = profile.id
        draftProfile = profile
        saveStore()
        synchronizeActiveProfileProcessing(rollback: rollback)
        notifyModelDidChange()
    }

    func revertDraft() {
        draftProfile = selectedProfile
    }

    func useDraftForCurrentOutput() {
        do {
            try useForCurrentOutput(profile: draftProfile)
        } catch {
            reportProfileActionFailure(error)
        }
    }

    func useForCurrentOutput(profile: EQProfile) throws {
        try ensureProfileStoreWritable()
        let rollback = profileRollback()
        guard !currentOutputUID.isEmpty else {
            return
        }

        var store = profileStore
        upsertProfile(profile, in: &store)
        store.outputMappings.removeAll { $0.outputDeviceUID == currentOutputUID }
        store.outputMappings.append(
            OutputDeviceProfileMapping(outputDeviceUID: currentOutputUID, profileID: profile.id)
        )
        try ProfilePersistence.validateForCommit(store)

        profileStore = store
        activeProfile = profile
        selectedProfileID = profile.id
        draftProfile = profile
        saveStore()
        synchronizeActiveProfileProcessing(rollback: rollback)
        notifyModelDidChange()
    }

    func setBypass(_ isBypassed: Bool) {
        do {
            try ensureProfileStoreWritable()
        } catch {
            reportProfileActionFailure(error)
            return
        }
        let rollback = profileRollback()
        var profile = activeProfile
        profile.isBypassed = isBypassed
        var store = profileStore
        upsertProfile(profile, in: &store)
        do {
            try ProfilePersistence.validateForCommit(store)
            profileStore = store
            activeProfile = profile
            if draftProfile.id == profile.id {
                draftProfile = profile
            }
            saveStore()
            synchronizeActiveProfileProcessing(rollback: rollback)
            notifyModelDidChange()
        } catch {
            reportProfileActionFailure(error)
        }
    }

    func createGraphic10Profile() {
        do {
            try createProfile(kind: .graphic10)
        } catch {
            reportProfileActionFailure(error)
        }
    }

    func createGraphic31Profile() {
        do {
            try createProfile(kind: .graphic31)
        } catch {
            reportProfileActionFailure(error)
        }
    }

    func createParametricProfile() {
        do {
            try createProfile(kind: .parametric)
        } catch {
            reportProfileActionFailure(error)
        }
    }

    func createConvolutionProfile() {
        do {
            try createProfile(kind: .convolution)
        } catch {
            reportProfileActionFailure(error)
        }
    }

    func duplicateSelectedProfile() {
        do {
            try duplicateProfile(id: selectedProfileID)
        } catch {
            reportProfileActionFailure(error)
        }
    }

    func deleteSelectedProfile() {
        do {
            try deleteProfile(id: selectedProfileID)
        } catch {
            reportProfileActionFailure(error)
        }
    }

    func importProfile() {
        Task { @MainActor in
            if ((try? await importProfile(format: importFormat, name: importName, text: importText)) ?? false) {
                importText = ""
            }
        }
    }

    func importProfile(format: ImportFormat, name: String, text: String) async throws -> Bool {
        try ensureProfileStoreWritable()
        statusMessage = localized("Importing \(format.title)...")
        notifyModelDidChange()

        let result = await profileImportOperation(format, name, text)
        try Task.checkCancellation()
        guard lifecycleState != .terminating else {
            throw CancellationError()
        }

        switch result {
        case .success(let imported):
            do {
                try addProfile(imported, name: imported.name, status: localized("Imported \(imported.name)"))
            } catch {
                statusMessage = localized("Import failed: \(error.localizedDescription)")
                notifyModelDidChange()
                throw error
            }
            statusMessage = localized("Imported \(imported.name)")
            notifyModelDidChange()
            return true
        case .failure(let error):
            statusMessage = localized("Import failed: \(error.localizedDescription)")
            notifyModelDidChange()
            throw error
        }
    }

    func setFallbackToDraft() {
        do {
            try setFallback(profile: draftProfile)
        } catch {
            reportProfileActionFailure(error)
        }
    }

    func setFallback(profile: EQProfile) throws {
        try ensureProfileStoreWritable()
        var store = profileStore
        upsertProfile(profile, in: &store)
        store.fallbackProfileID = profile.id
        try ProfilePersistence.validateForCommit(store)

        profileStore = store
        selectedProfileID = profile.id
        draftProfile = profile
        saveStore()
        statusMessage = localized("Fallback profile set to \(profile.name)")
        notifyModelDidChange()
    }

    func preview(profile: EQProfile) {
        guard programmeComparisonReturnProfile == nil else {
            return
        }
        do {
            try ensureProfileStoreWritable()
        } catch {
            reportProfileActionFailure(error)
            return
        }
        guard profileStore.profiles.contains(where: { $0.id == profile.id }) else {
            reportProfileActionFailure(SettingsCommandFailure(
                message: localized("The selected profile no longer exists. Refresh settings and try again.")
            ))
            return
        }
        let rollback = profileRollback()
        guard lifecycleState != .terminating,
              lifecycleState != .sleeping,
              lifecycleState != .waking else {
            return
        }
        if previewReturnProfile == nil {
            previewReturnProfile = activeProfile
        }
        activeProfile = profile
        selectedProfileID = profile.id
        draftProfile = profile
        if activeProfile.isBypassed {
            disableActiveProfileProcessing(updateMetrics: true)
        } else if hasPendingProfileReplacingEngineWork {
            reschedulePendingEngineStartWithActiveProfile(rollback: rollback)
        } else if engine.updateDSP(profile: profile) {
            confirmedEngineProfileState.confirm(EngineProfileConfirmation(profileRollback()))
            statusMessage = localized("Previewing settings for \(profile.name)")
        } else {
            restartEngineWithActiveProfile(rollback: rollback)
        }
        notifyModelDidChange()
    }

    func stopPreview() {
        guard lifecycleState != .terminating,
              lifecycleState != .sleeping,
              lifecycleState != .waking else {
            return
        }
        guard let profile = previewReturnProfile else {
            return
        }
        let rollback = profileRollback()
        previewReturnProfile = nil
        clearProgrammeComparisonSession()
        activeProfile = profile
        selectedProfileID = profile.id
        draftProfile = profile
        if activeProfile.isBypassed {
            disableActiveProfileProcessing(updateMetrics: true)
        } else if hasPendingProfileReplacingEngineWork {
            reschedulePendingEngineStartWithActiveProfile(rollback: rollback)
        } else if engine.updateDSP(profile: profile) {
            confirmedEngineProfileState.confirm(EngineProfileConfirmation(profileRollback()))
            statusMessage = processingStatus(outputName: currentOutputName, profileName: profile.name)
        } else {
            restartEngineWithActiveProfile(rollback: rollback)
        }
        notifyModelDidChange()
    }

    func startProgrammeComparison(profile: EQProfile) throws {
        guard programmeComparisonReturnProfile == nil else {
            return
        }
        guard previewReturnProfile == nil else {
            throw SettingsCommandFailure(
                message: localized("Stop the profile preview before starting A/B comparison.")
            )
        }
        guard lifecycleState == .running,
              isRunning,
              engineStartTask == nil,
              engineIsRunning else {
            throw SettingsCommandFailure(
                message: localized("Start GlassEQ before comparing the profile.")
            )
        }
        guard !profile.isBypassed else {
            throw SettingsCommandFailure(
                message: localized("Enable the profile before comparing it.")
            )
        }

        engine.setProgrammeComparisonSelection(.equalized)
        guard engine.beginProgrammeComparison(profile: profile) else {
            throw SettingsCommandFailure(
                message: localized("The audio engine could not start A/B comparison.")
            )
        }

        programmeComparisonReturnProfile = activeProfile
        programmeComparison = EQProgrammeComparisonSnapshot(
            isActive: true,
            selection: .equalized
        )
        statusMessage = localized("Comparing EQ with filters off")
        startProgrammeComparisonPolling()
        notifyModelDidChange()
    }

    func selectProgrammeComparison(_ selection: EQProgrammeComparisonSelection) {
        guard programmeComparisonReturnProfile != nil else {
            return
        }
        programmeComparison.selection = selection
        engine.setProgrammeComparisonSelection(selection)
        notifyModelDidChange()
    }

    func stopProgrammeComparison() {
        guard let returnProfile = programmeComparisonReturnProfile else {
            return
        }
        engine.setProgrammeComparisonSelection(.equalized)
        clearProgrammeComparisonSession()
        if lifecycleState == .running,
           isRunning,
           engineStartTask == nil {
            if engine.updateDSP(profile: returnProfile) {
                statusMessage = processingStatus(
                    outputName: currentOutputName,
                    profileName: returnProfile.name
                )
            } else {
                restartEngineWithActiveProfile()
            }
        }
        notifyModelDidChange()
    }

    private func startProgrammeComparisonPolling() {
        programmeComparisonTask?.cancel()
        programmeComparisonTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self,
                      self.programmeComparisonReturnProfile != nil else {
                    return
                }
                var next = self.engine.snapshotProgrammeComparison()
                next.isActive = true
                guard next != self.programmeComparison else {
                    continue
                }
                self.programmeComparison = next
                self.notifyModelDidChange()
            }
        }
    }

    private func clearProgrammeComparisonSession(
        restoringEqualizedRendererIfRunning: Bool = false
    ) {
        if restoringEqualizedRendererIfRunning,
           programmeComparisonReturnProfile != nil,
           case .running = engine.state {
            engine.setProgrammeComparisonSelection(.equalized)
        }
        programmeComparisonTask?.cancel()
        programmeComparisonTask = nil
        programmeComparisonReturnProfile = nil
        programmeComparison = EQProgrammeComparisonSnapshot()
    }

    func resetDiagnostics() {
        engine.resetDiagnostics()
        engineMetrics = engine.snapshotMetrics()
        notifyModelDidChange()
    }

    #if DEBUG
    func simulateRenderStallForTesting() {
        guard lifecycleState == .running,
              isRunning,
              engineStartTask == nil else {
            return
        }
        engine.simulateRenderStallForTesting()
        statusMessage = localized("Debug: render heartbeat frozen for watchdog test")
        notifyModelDidChange()
    }
    #endif

    @discardableResult
    private func addProfile(_ profile: EQProfile, name: String, status: String? = nil) throws -> EQProfile {
        try ensureProfileStoreWritable()
        var profile = profile
        profile.id = UUID()
        profile.name = uniqueProfileName(name)
        var store = profileStore
        store.profiles.append(profile)
        try ProfilePersistence.validateForCommit(store)

        profileStore = store
        selectedProfileID = profile.id
        draftProfile = profile
        saveStore()
        if let status {
            statusMessage = status
        }
        notifyModelDidChange()
        return profile
    }

    func createProfile(kind: SettingsProfileKind) throws {
        switch kind {
        case .graphic10:
            try addProfile(.flatGraphic10, name: localized("New 10-Band"), status: localized("Created New 10-Band"))
        case .graphic31:
            try addProfile(.flatGraphic31, name: localized("New 31-Band"), status: localized("Created New 31-Band"))
        case .parametric:
            var profile = EQProfile.flatParametric
            profile.filters = [
                EQFilter(kind: .peak, frequency: 1_000, gainDB: 0, q: 1)
            ]
            try addProfile(profile, name: localized("New Parametric"), status: localized("Created New Parametric"))
        case .convolution:
            try addProfile(
                .flatConvolution,
                name: localized("New Response Curve"),
                status: localized("Created New Response Curve")
            )
        }
    }

    func duplicateProfile(id: UUID) throws {
        try ensureProfileStoreWritable()
        guard let source = profileStore.profiles.first(where: { $0.id == id }) else {
            throw SettingsCommandFailure(message: localized("The selected profile no longer exists. Refresh settings and try again."))
        }
        var profile = source
        profile.id = UUID()
        try addProfile(profile, name: localized("\(source.name) Copy"), status: localized("Duplicated \(source.name)"))
    }

    func deleteProfile(id: UUID) throws {
        try ensureProfileStoreWritable()
        guard let deletedIndex = profileStore.profiles.firstIndex(where: { $0.id == id }) else {
            throw SettingsCommandFailure(message: localized("The selected profile no longer exists. Refresh settings and try again."))
        }
        guard profileStore.profiles.count > 1 else {
            throw SettingsCommandFailure(message: localized("At least one profile is required."))
        }
        guard id != activeProfile.id,
              id != previewReturnProfile?.id,
              id != confirmedEngineProfileState.activeProfileID() else {
            throw SettingsCommandFailure(message: localized("Switch to another profile before deleting the active profile"))
        }

        let previousSelection = selectedProfileID
        var store = profileStore
        store.profiles.removeAll { $0.id == id }
        store.outputMappings.removeAll { $0.profileID == id }
        if store.fallbackProfileID == id {
            store.fallbackProfileID = activeProfile.id
        }

        let nextSelectionID: UUID
        let nextDraft: EQProfile
        if previousSelection == id {
            let nextIndex = min(deletedIndex, store.profiles.count - 1)
            nextDraft = store.profiles[nextIndex]
            nextSelectionID = nextDraft.id
        } else {
            nextSelectionID = previousSelection
            nextDraft = draftProfile
        }

        try ProfilePersistence.validateForCommit(store)
        profileStore = store
        selectedProfileID = nextSelectionID
        draftProfile = nextDraft
        saveStore()
        statusMessage = localized("Deleted profile")
        notifyModelDidChange()
    }

    private func uniqueProfileName(_ name: String) -> String {
        let existing = Set(profileStore.profiles.map(\.name))
        guard existing.contains(name) else {
            return name
        }

        var index = 2
        while existing.contains(localized("\(name) \(index)")) {
            index += 1
        }
        return localized("\(name) \(index)")
    }

    private func upsertProfile(_ profile: EQProfile, in store: inout ProfileStore) {
        if let index = store.profiles.firstIndex(where: { $0.id == profile.id }) {
            store.profiles[index] = profile
        } else {
            store.profiles.append(profile)
        }
    }

    private func reportProfileActionFailure(_ error: Error) {
        statusMessage = localized("Profile action failed: \(error.localizedDescription)")
        notifyModelDidChange()
    }

    private func profileRollback() -> ProfileRollback {
        ProfileRollback(
            profileStore: profileStore,
            activeProfile: activeProfile,
            selectedProfileID: selectedProfileID,
            draftProfile: draftProfile,
            previewReturnProfile: previewReturnProfile
        )
    }

    private func restartEngineWithActiveProfile(rollback: ProfileRollback? = nil) {
        guard lifecycleState != .terminating,
              lifecycleState != .sleeping,
              lifecycleState != .waking else {
            return
        }

        statusMessage = localized("Reconnecting audio output...")
        scheduleEngineWork(.restart(profile: activeProfile, rollback: rollback))
        notifyModelDidChange()
    }

    private func scheduleDefaultOutputChange(_ result: Result<AudioOutputDevice, Error>, observerGeneration: Int) {
        // Observer callbacks can arrive after stop/sleep/restart; the generation gates them to
        // the observer instance that is currently allowed to drive engine state.
        guard observerGeneration == observerCallbackGeneration,
              lifecycleState != .terminating,
              lifecycleState != .sleeping else {
            return
        }

        outputChangeGeneration += 1
        let generation = outputChangeGeneration
        let settlingDelay = outputChangeSettlingDelay(for: result)
        outputChangeTask?.cancel()
        if shouldMuteForSettlingOutputChange(result) {
            scheduleEngineMuteForTransition()
            statusMessage = outputChangeStatusMessage(for: result)
            notifyModelDidChange()
        }
        outputChangeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: settlingDelay)
            guard !Task.isCancelled,
                  self?.observerCallbackGeneration == observerGeneration else {
                return
            }
            guard self?.outputChangeGeneration == generation else {
                return
            }
            guard self?.lifecycleState != .terminating,
                  self?.lifecycleState != .sleeping else {
                return
            }
            guard let self else {
                return
            }

            let settledResult = Result { try self.defaultOutputLookup.defaultOutputDevice() }
            self.handleDefaultOutputChange(settledResult)
        }
    }

    private func shouldMuteForSettlingOutputChange(_ result: Result<AudioOutputDevice, Error>) -> Bool {
        guard isRunning,
              case .success(let output) = result,
              !currentOutputUID.isEmpty else {
            return false
        }

        return output.uid != currentOutputUID
            || output.nominalSampleRate != currentOutputSampleRate
            || output.bufferFrameSize != currentOutputBufferFrameSize
    }

    private func outputChangeStatusMessage(for result: Result<AudioOutputDevice, Error>) -> String {
        guard case .success(let output) = result else {
            return localized("Audio output changed; rebuilding...")
        }
        if output.uid == currentOutputUID {
            return localized("Audio output format changed; rebuilding...")
        }
        return localized("Audio output changed; rebuilding...")
    }

    private func outputChangeSettlingDelay(for result: Result<AudioOutputDevice, Error>) -> Duration {
        if let outputChangeSettlingDelayOverride {
            return outputChangeSettlingDelayOverride
        }

        guard case .success = result else {
            return OutputChangeReconnectPolicy.fallbackDelay
        }
        return OutputChangeReconnectPolicy.routeSwitchDelay
    }

    private func refreshCurrentOutputMetadata(from output: AudioOutputDevice) {
        currentOutputName = output.name
        currentOutputUID = output.uid
        currentOutputSampleRate = output.nominalSampleRate
        currentOutputChannelCount = output.outputChannelCount
        currentOutputBufferFrameSize = output.bufferFrameSize
    }

    private func handleDefaultOutputChange(_ result: Result<AudioOutputDevice, Error>) {
        guard lifecycleState != .terminating,
              lifecycleState != .sleeping else {
            return
        }

        clearProgrammeComparisonSession(restoringEqualizedRendererIfRunning: true)
        let rollback = profileRollback()
        previewReturnProfile = nil
        switch result {
        case .success(let output):
            refreshCurrentOutputMetadata(from: output)
            activeProfile = profileStore.profile(forOutputUID: output.uid)
            selectedProfileID = activeProfile.id
            draftProfile = activeProfile

            if activeProfile.isBypassed {
                disableActiveProfileProcessing(updateMetrics: false)
            } else {
                scheduleEngineStart(output: output, profile: activeProfile, rollback: rollback)
            }
        case .failure(let error):
            if lifecycleState == .waking {
                scheduleWakeReconnectRetry(status: localized("Waiting for audio output after wake: \(error.localizedDescription)"))
                return
            }
            invalidatePendingEngineStart()
            scheduleEngineStop(updateMetrics: false)
            lifecycleState = .stopped
            isRunning = false
            statusMessage = localized("Default output unavailable: \(error.localizedDescription)")
        }
        notifyModelDidChange()
    }

    private func scheduleEngineWork(_ work: EngineWork) {
        guard lifecycleState != .terminating,
              lifecycleState != .sleeping else {
            return
        }

        engineStartGeneration += 1
        let generation = engineStartGeneration
        renderWatchdogTask?.cancel()
        renderWatchdogTask = nil
        renderWatchdog.pause()
        aggregateStabilityTask?.cancel()
        aggregateStabilityTask = nil
        headsetAggregatePromotionTask?.cancel()
        headsetAggregatePromotionTask = nil
        engineStartTask?.cancel()
        switch work {
        case .start(let output, _, _, _):
            pendingEngineStartOutput = output
        case .restart:
            pendingEngineStartOutput = nil
        case .recoverRenderStall(let output, _, _):
            pendingEngineStartOutput = output
        }

        let engine = engine
        let defaultOutputLookup = defaultOutputLookup
        let engineWorkExecutor = engineWorkExecutor
        let attemptedRollback = profileRollback()
        let confirmation = EngineProfileConfirmation(attemptedRollback)
        let failedAttempt = FailedEngineProfileAttempt(
            profileID: work.profile.id,
            previous: work.rollback,
            attempted: attemptedRollback
        )
        let confirmedEngineProfileState = confirmedEngineProfileState
        let workTask = engineWorkExecutor.enqueue(priority: .userInitiated) {
            Self.performEngineWork(
                work,
                confirmation: confirmation,
                failedAttempt: failedAttempt,
                confirmedState: confirmedEngineProfileState,
                engine: engine,
                defaultOutputLookup: defaultOutputLookup
            )
        }

        engineStartTask = Task { @MainActor [weak self] in
            let result = await withTaskCancellationHandler {
                await workTask.value
            } onCancel: {
                workTask.cancel()
            }
            guard !Task.isCancelled else {
                self?.cleanupCancelledEngineWork(result, generation: generation)
                return
            }
            self?.completeEngineWork(result, generation: generation)
        }
    }

    private func scheduleEngineStart(
        output: AudioOutputDevice,
        profile: EQProfile,
        rollback: ProfileRollback?,
        aggregateBufferFrameSize requestedFrameSize: UInt32? = nil
    ) {
        let route = try? engine.aggregateRouteFingerprint(for: output)
        let frameSize = requestedFrameSize
            ?? route.map { aggregateBufferFrameSize(for: $0) }
            ?? 16
        scheduleEngineWork(.start(
            output: output,
            profile: profile,
            rollback: rollback,
            aggregateBufferFrameSize: frameSize
        ))
    }

    private func aggregateBufferFrameSize(
        for route: AggregateAudioRouteFingerprint
    ) -> UInt32 {
        let selection = aggregateBufferPolicyStore.selection(for: route)
        guard selection.mode != .automatic,
              let fixedBufferRecovery,
              fixedBufferRecovery.route == route,
              fixedBufferRecovery.preferredFrameSize == selection.frameSize else {
            return selection.frameSize
        }
        return fixedBufferRecovery.session.runtimeFrameSize
    }

    private func clearFixedBufferRecoveryAndRestorePreference() {
        guard let fixedBufferRecovery else {
            return
        }
        engine.setPreferredAggregateBufferFrameSize(
            fixedBufferRecovery.preferredFrameSize
        )
        self.fixedBufferRecovery = nil
    }

    private func synchronizeActiveProfileProcessing(rollback: ProfileRollback? = nil) {
        guard lifecycleState != .terminating,
              lifecycleState != .sleeping else {
            return
        }

        guard !activeProfile.isBypassed else {
            disableActiveProfileProcessing(updateMetrics: true)
            return
        }

        if hasPendingProfileReplacingEngineWork {
            reschedulePendingEngineStartWithActiveProfile(rollback: rollback)
            return
        }

        if lifecycleState == .waking {
            reschedulePendingEngineStartWithActiveProfile()
            return
        }

        startObserver(sendInitialValue: false)
        if isRunning {
            if engine.updateDSP(profile: activeProfile) {
                confirmedEngineProfileState.confirm(EngineProfileConfirmation(profileRollback()))
                statusMessage = processingStatus(outputName: currentOutputName, profileName: activeProfile.name)
            } else {
                restartEngineWithActiveProfile(rollback: rollback)
            }
        } else {
            restartEngineWithActiveProfile(rollback: rollback)
        }
    }

    private func disableActiveProfileProcessing(updateMetrics: Bool) {
        clearProgrammeComparisonSession()
        clearFixedBufferRecoveryAndRestorePreference()
        let shouldStopEngine = isRunning || engineStartTask != nil || engineStateNeedsStop
        invalidatePendingOutputChange()
        invalidatePendingEngineStart()
        renderWatchdog.reset()
        if shouldStopEngine {
            scheduleEngineStop(updateMetrics: updateMetrics)
        }
        lifecycleState = .stopped
        isRunning = false
        wakeReconnectAttempts = 0
        wasRunningBeforeSleep = false
        statusMessage = disabledStatus(outputName: currentOutputName)
    }

    private var engineStateNeedsStop: Bool {
        switch engine.state {
        case .running, .failed:
            return true
        case .stopped:
            return false
        }
    }

    private func scheduleEngineStop(updateMetrics: Bool) {
        let stopTask = enqueueEngineStop()
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            let metrics = await stopTask.value
            if updateMetrics {
                engineMetrics = metrics
                notifyModelDidChange()
            }
        }
    }

    private func scheduleEngineMuteForTransition() {
        let engine = engine
        let engineWorkExecutor = engineWorkExecutor
        engineWorkExecutor.enqueue(priority: .userInitiated) {
            engine.muteOutputForTransition()
        }
    }

    private func stopEngineOffMain() async -> AudioEngineMetrics {
        await enqueueEngineStop().value
    }

    private func enqueueEngineStop() -> Task<AudioEngineMetrics, Never> {
        let engine = engine
        let engineWorkExecutor = engineWorkExecutor
        let confirmedEngineProfileState = confirmedEngineProfileState
        return engineWorkExecutor.enqueue(priority: .userInitiated) {
            engine.stop()
            confirmedEngineProfileState.clear()
            return engine.snapshotMetrics()
        }
    }

    nonisolated private static func performEngineWork(
        _ work: EngineWork,
        confirmation: EngineProfileConfirmation,
        failedAttempt: FailedEngineProfileAttempt,
        confirmedState: ConfirmedEngineProfileState,
        engine: any AudioEngineControlling,
        defaultOutputLookup: any DefaultOutputLookingUp
    ) -> EngineWorkResult {
        var attemptedOutput: AudioOutputDevice?
        do {
            let output: AudioOutputDevice
            switch work {
            case .start(
                let requestedOutput,
                let profile,
                let rollback,
                let aggregateBufferFrameSize
            ):
                guard !Task.isCancelled else {
                    confirmedState.recordCancelledAttempt(failedAttempt)
                    return .cancelled
                }
                attemptedOutput = requestedOutput
                do {
                    engine.setPreferredAggregateBufferFrameSize(aggregateBufferFrameSize)
                    try engine.start(output: requestedOutput, profile: profile)
                } catch {
                    if case .running(let activeOutput) = engine.state {
                        return .profileChangeNotApplied(
                            error,
                            activeOutput,
                            confirmedState.reconciliation(
                                after: failedAttempt,
                                fallback: rollback.map(EngineProfileConfirmation.init)
                            )
                        )
                    }
                    throw error
                }
                if case .running(let activeOutput) = engine.state {
                    output = activeOutput
                } else {
                    output = requestedOutput
                }
            case .restart(let profile, let rollback):
                switch engine.state {
                case .running(let runningOutput):
                    guard !Task.isCancelled else {
                        confirmedState.recordCancelledAttempt(failedAttempt)
                        return .cancelled
                    }
                    attemptedOutput = runningOutput
                    do {
                        try engine.update(profile: profile)
                    } catch {
                        if case .running(let activeOutput) = engine.state {
                            return .profileChangeNotApplied(
                                error,
                                activeOutput,
                                confirmedState.reconciliation(
                                    after: failedAttempt,
                                    fallback: rollback.map(EngineProfileConfirmation.init)
                                )
                            )
                        }
                        throw error
                    }
                    guard case .running(let activeOutput) = engine.state else {
                        return .failure(
                            EngineWorkFailure(message: localized("Default output unavailable")),
                            attemptedOutput
                        )
                    }
                    output = activeOutput
                case .stopped, .failed:
                    let defaultOutput = try defaultOutputLookup.defaultOutputDevice()
                    attemptedOutput = defaultOutput
                    if Task.isCancelled {
                        confirmedState.recordCancelledAttempt(failedAttempt)
                        return .cancelled
                    }
                    try engine.start(output: defaultOutput, profile: profile)
                    if case .running(let activeOutput) = engine.state {
                        output = activeOutput
                    } else {
                        output = defaultOutput
                    }
                }
            case .recoverRenderStall(
                let requestedOutput,
                let profile,
                let aggregateBufferFrameSize
            ):
                attemptedOutput = requestedOutput
                engine.stop()
                confirmedState.clear()
                guard !Task.isCancelled else {
                    confirmedState.recordCancelledAttempt(failedAttempt)
                    return .cancelled
                }
                engine.setPreferredAggregateBufferFrameSize(aggregateBufferFrameSize)
                try engine.start(output: requestedOutput, profile: profile)
                if case .running(let activeOutput) = engine.state {
                    output = activeOutput
                } else {
                    output = requestedOutput
                }
            }
            confirmedState.confirm(confirmation)
            return .success(output)
        } catch {
            switch engine.state {
            case .running:
                break
            case .stopped, .failed:
                confirmedState.clear()
            }
            return .failure(error, attemptedOutput)
        }
    }

    private func cleanupCancelledEngineWork(_ result: EngineWorkResult, generation: Int) {
        // Cancellation is cooperative: the detached worker may finish `engine.start` after this
        // model has already moved on. Never let a stale worker stop the shared engine while a
        // newer generation is pending or running; only clean up if the app's current intent is no
        // running engine at all.
        guard generation != engineStartGeneration,
              engineStartTask == nil else {
            return
        }
        guard case .success = result else {
            return
        }
        guard lifecycleState == .stopped
                || lifecycleState == .sleeping
                || lifecycleState == .terminating else {
            return
        }
        scheduleEngineStop(updateMetrics: lifecycleState == .stopped)
    }

    private func completeEngineWork(_ result: EngineWorkResult, generation: Int) {
        guard generation == engineStartGeneration,
              lifecycleState != .terminating,
              lifecycleState != .sleeping else {
            return
        }

        engineStartTask = nil
        pendingEngineStartOutput = nil

        switch result {
        case .success(let output):
            refreshCurrentOutputMetadata(from: output)
            activeAggregateRoute = try? engine.aggregateRouteFingerprint(for: output)
            clearFixedBufferRecoveryIfRouteChanged()
            lifecycleState = .running
            isRunning = true
            wakeReconnectAttempts = 0
            wasRunningBeforeSleep = false
            if engine.isUsingTransitionalHeadsetBackend,
               headsetPromotionAttemptedOutputGeneration == outputChangeGeneration {
                statusMessage = localized(
                    "Processing \(output.name) with \(activeProfile.name) in compatibility mode"
                )
            } else {
                statusMessage = processingStatus(
                    outputName: output.name,
                    profileName: activeProfile.name
                )
            }
            completePendingAggregateBufferIncreaseIfNeeded(output: output)
            startAggregateStabilityMonitoring()
            startHeadsetAggregatePromotionIfNeeded()
        case .profileChangeNotApplied(_, let output, let reconciliation):
            refreshCurrentOutputMetadata(from: output)
            activeAggregateRoute = try? engine.aggregateRouteFingerprint(for: output)
            clearFixedBufferRecoveryIfRouteChanged()
            if let reconciliation {
                restoreEngineProfileReconciliation(reconciliation, persist: true)
                confirmedEngineProfileState.acknowledge(reconciliation)
                statusMessage = localized("Profile change was not applied; audio is still running with \(reconciliation.confirmation.activeProfile.name).")
            } else {
                statusMessage = localized("Profile change was not applied; audio is still running with \(activeProfile.name).")
            }
            lifecycleState = .running
            isRunning = true
            wakeReconnectAttempts = 0
            wasRunningBeforeSleep = false
            pendingAggregateBufferIncrease = nil
            startAggregateStabilityMonitoring()
            startHeadsetAggregatePromotionIfNeeded()
        case .failure(let error, let attemptedOutput):
            if let attemptedOutput {
                refreshCurrentOutputMetadata(from: attemptedOutput)
            }
            if lifecycleState == .waking {
                scheduleWakeReconnectRetry(status: audioEngineStatusMessage(error))
                return
            }
            lifecycleState = .stopped
            isRunning = false
            activeAggregateRoute = nil
            pendingAggregateBufferIncrease = nil
            statusMessage = audioEngineStatusMessage(error)
        case .cancelled:
            return
        }
        if lifecycleState == .running {
            startRenderWatchdog()
        } else {
            renderWatchdog.pause()
        }
        notifyModelDidChange()
    }

    private func clearFixedBufferRecoveryIfRouteChanged() {
        guard let fixedBufferRecovery else {
            return
        }
        let selection = aggregateBufferPolicyStore.selection(for: fixedBufferRecovery.route)
        if activeAggregateRoute != fixedBufferRecovery.route
            || selection.mode == .automatic
            || selection.frameSize != fixedBufferRecovery.preferredFrameSize {
            self.fixedBufferRecovery = nil
        }
    }

    private func startAggregateStabilityMonitoring() {
        aggregateStabilityTask?.cancel()
        aggregateStabilityTask = nil
        guard let route = activeAggregateRoute else {
            return
        }
        let selection = aggregateBufferPolicyStore.selection(for: route)
        let engineGeneration = engineStartGeneration
        let outputGeneration = outputChangeGeneration
        let settlingDelay = aggregateStabilitySettlingDelay
        let cleanSessionDuration = aggregateCleanSessionDuration
        aggregateStabilityTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: settlingDelay)
            guard let self,
                  !Task.isCancelled,
                  self.aggregateRouteIsSettled(
                      route,
                      engineGeneration: engineGeneration,
                      outputGeneration: outputGeneration
                  ) else {
                return
            }
            let initialMetrics = self.engine.snapshotMetrics()
            var qualifyingBaseline = initialMetrics.qualifyingPairedTimestampDiscontinuities
            var deadlineBaseline = initialMetrics.renderDeadlineMisses
            var deadlineBurstDetector = AudioRenderDeadlineBurstDetector()
            var sessionHadQualifyingInterruption = false
            var cleanSessionRecorded = false
            let cleanSessionDeadline = ContinuousClock.now.advanced(
                by: cleanSessionDuration
            )
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled,
                      self.aggregateRouteIsSettled(
                          route,
                          engineGeneration: engineGeneration,
                          outputGeneration: outputGeneration
                      ) else {
                    return
                }
                let metrics = self.engine.snapshotMetrics()
                let nextDeadlineCount = metrics.renderDeadlineMisses
                if selection.mode != .automatic {
                    if nextDeadlineCount > deadlineBaseline {
                        let newMisses = nextDeadlineCount - deadlineBaseline
                        deadlineBaseline = nextDeadlineCount
                        if deadlineBurstDetector.observe(newMisses: newMisses),
                           self.handleFixedAggregateDeadlineBurst(on: route) {
                            return
                        }
                    } else if nextDeadlineCount < deadlineBaseline {
                        deadlineBaseline = nextDeadlineCount
                        deadlineBurstDetector.reset()
                    }
                    continue
                }

                let nextCount = metrics.qualifyingPairedTimestampDiscontinuities
                if nextCount > qualifyingBaseline {
                    let occurrenceCount = nextCount - qualifyingBaseline
                    qualifyingBaseline = nextCount
                    sessionHadQualifyingInterruption = true
                    if self.handleQualifyingAggregateInterruption(
                        on: route,
                        occurrences: occurrenceCount
                    ) {
                        return
                    }
                } else if nextCount < qualifyingBaseline {
                    qualifyingBaseline = nextCount
                }

                if !cleanSessionRecorded,
                   !sessionHadQualifyingInterruption,
                   ContinuousClock.now >= cleanSessionDeadline {
                    cleanSessionRecorded = true
                    if self.handleCleanAggregateSession(on: route) {
                        return
                    }
                }
            }
        }
    }

    private func startHeadsetAggregatePromotionIfNeeded() {
        headsetAggregatePromotionTask?.cancel()
        headsetAggregatePromotionTask = nil
        guard engine.isUsingTransitionalHeadsetBackend,
              headsetPromotionAttemptedOutputGeneration != outputChangeGeneration else {
            return
        }
        headsetPromotionAttemptedOutputGeneration = outputChangeGeneration
        let engineGeneration = engineStartGeneration
        let outputGeneration = outputChangeGeneration
        let delay = headsetAggregatePromotionDelay
        statusMessage = localized(
            "Processing \(currentOutputName) in compatibility mode while its clock settles..."
        )
        headsetAggregatePromotionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self,
                  !Task.isCancelled,
                  self.lifecycleState == .running,
                  self.isRunning,
                  self.engineStartGeneration == engineGeneration,
                  self.outputChangeGeneration == outputGeneration,
                  self.engine.isUsingTransitionalHeadsetBackend else {
                return
            }
            self.statusMessage = localized("Testing the low-latency headset path...")
            self.notifyModelDidChange()
            let engine = self.engine
            let work = self.engineWorkExecutor.enqueue(priority: .userInitiated) {
                do {
                    return HeadsetPromotionWorkResult.success(
                        try engine.attemptHeadsetAggregatePromotion()
                    )
                } catch {
                    return HeadsetPromotionWorkResult.failure(error.localizedDescription)
                }
            }
            let result = await work.value
            guard !Task.isCancelled,
                  self.lifecycleState == .running,
                  self.engineStartGeneration == engineGeneration,
                  self.outputChangeGeneration == outputGeneration else {
                return
            }
            self.headsetAggregatePromotionTask = nil
            self.completeHeadsetAggregatePromotion(result)
        }
    }

    private func completeHeadsetAggregatePromotion(
        _ workResult: HeadsetPromotionWorkResult
    ) {
        switch workResult {
        case .success(.promoted(let output)):
            refreshCurrentOutputMetadata(from: output)
            activeAggregateRoute = try? engine.aggregateRouteFingerprint(for: output)
            engineMetrics = engine.snapshotMetrics()
            statusMessage = localized(
                "Processing \(output.name) with \(activeProfile.name) on the low-latency headset path"
            )
            startAggregateStabilityMonitoring()
        case .success(.clockUnstable):
            statusMessage = localized(
                "The headset clock is still settling; compatibility mode remains active."
            )
        case .success(.aggregateUnstable):
            activeAggregateRoute = nil
            statusMessage = localized(
                "The headset aggregate was still unstable; compatibility mode remains active."
            )
        case .success(.notApplicable):
            statusMessage = processingStatus(
                outputName: currentOutputName,
                profileName: activeProfile.name
            )
        case .failure(let message):
            activeAggregateRoute = nil
            if case .running = engine.state {
                statusMessage = localized(
                    "Could not test the low-latency headset path; compatibility mode remains active: \(message)"
                )
            } else {
                lifecycleState = .stopped
                isRunning = false
                statusMessage = localized("Audio engine failed: \(message)")
            }
        }
        notifyModelDidChange()
    }

    private func aggregateRouteIsSettled(
        _ route: AggregateAudioRouteFingerprint,
        engineGeneration: Int,
        outputGeneration: Int
    ) -> Bool {
        lifecycleState == .running
            && isRunning
            && engineStartTask == nil
            && engineStartGeneration == engineGeneration
            && outputChangeGeneration == outputGeneration
            && activeAggregateRoute == route
            && currentOutputUID == route.outputDeviceUID
            && Int64(currentOutputSampleRate.rounded()) == route.nominalSampleRate
    }

    private func handleFixedAggregateDeadlineBurst(
        on route: AggregateAudioRouteFingerprint
    ) -> Bool {
        guard activeAggregateRoute == route,
              lifecycleState == .running,
              engineStartTask == nil,
              case .running(let output) = engine.state else {
            return false
        }
        let selection = aggregateBufferPolicyStore.selection(for: route)
        guard selection.mode != .automatic else {
            return false
        }

        var recovery: FixedBufferRecovery
        if let fixedBufferRecovery,
           fixedBufferRecovery.route == route,
           fixedBufferRecovery.preferredFrameSize == selection.frameSize {
            recovery = fixedBufferRecovery
        } else {
            recovery = FixedBufferRecovery(
                route: route,
                preferredFrameSize: selection.frameSize,
                session: FixedBufferRecoverySession(
                    runtimeFrameSize: selection.frameSize
                )
            )
        }
        let previousFrameSize = recovery.session.runtimeFrameSize
        let action = recovery.session.observeFailure()
        fixedBufferRecovery = recovery

        switch action {
        case .rebuild(let frameSize):
            pendingAggregateBufferIncrease = PendingAggregateBufferIncrease(
                route: route,
                outputName: output.name,
                previousFrameSize: frameSize,
                newFrameSize: frameSize,
                kind: .fixedRebuild
            )
            statusMessage = localized(
                "Audio deadlines were missed; rebuilding \(output.name) with \(frameSize)-frame buffers..."
            )
            notifyModelDidChange()
            scheduleEngineStart(
                output: output,
                profile: activeProfile,
                rollback: nil,
                aggregateBufferFrameSize: frameSize
            )
        case .temporarilyIncrease(let frameSize):
            pendingAggregateBufferIncrease = PendingAggregateBufferIncrease(
                route: route,
                outputName: output.name,
                previousFrameSize: previousFrameSize,
                newFrameSize: frameSize,
                kind: .fixedTemporaryIncrease
            )
            statusMessage = localized(
                "\(selection.frameSize)-frame processing became unstable; temporarily switching \(output.name) to \(frameSize)-frame buffers..."
            )
            notifyModelDidChange()
            scheduleEngineStart(
                output: output,
                profile: activeProfile,
                rollback: nil,
                aggregateBufferFrameSize: frameSize
            )
        case .stop:
            pendingAggregateBufferIncrease = nil
            invalidatePendingEngineStart()
            scheduleEngineStop(updateMetrics: true)
            lifecycleState = .stopped
            isRunning = false
            renderWatchdog.pause()
            statusMessage = localized(
                "64-frame processing missed audio deadlines again, so GlassEQ stopped processing. Retry the audio engine when ready."
            )
            notifyModelDidChange()
        }
        return true
    }

    private func handleQualifyingAggregateInterruption(
        on route: AggregateAudioRouteFingerprint,
        occurrences: UInt64
    ) -> Bool {
        guard activeAggregateRoute == route,
              lifecycleState == .running,
              engineStartTask == nil,
              case .running(let output) = engine.state else {
            return false
        }
        if engine.isUsingPromotedHeadsetAggregate {
            engine.rejectHeadsetAggregatePromotion()
            pendingAggregateBufferIncrease = nil
            statusMessage = localized(
                "Headset timing became unstable; returning to compatibility mode..."
            )
            notifyModelDidChange()
            scheduleEngineStart(
                output: output,
                profile: activeProfile,
                rollback: nil
            )
            return true
        }
        let previousFrameSize = aggregateBufferPolicyStore.selection(for: route).frameSize
        do {
            guard let nextFrameSize = try aggregateBufferPolicyStore
                .recordAutomaticFailure(
                    for: route,
                    occurrences: occurrences
                ) else {
                return false
            }
            pendingAggregateBufferIncrease = PendingAggregateBufferIncrease(
                route: route,
                outputName: output.name,
                previousFrameSize: previousFrameSize,
                newFrameSize: nextFrameSize
            )
            statusMessage = localized(
                "Timing interruption detected; switching \(output.name) to \(nextFrameSize)-frame buffers..."
            )
            notifyModelDidChange()
            scheduleEngineStart(
                output: output,
                profile: activeProfile,
                rollback: nil,
                aggregateBufferFrameSize: nextFrameSize
            )
            return true
        } catch {
            statusMessage = localized(
                "Could not save the safer audio buffer setting: \(error.localizedDescription)"
            )
            notifyModelDidChange()
            return false
        }
    }

    private func handleCleanAggregateSession(
        on route: AggregateAudioRouteFingerprint
    ) -> Bool {
        guard activeAggregateRoute == route,
              lifecycleState == .running,
              engineStartTask == nil,
              case .running(let output) = engine.state else {
            return false
        }
        do {
            guard let nextFrameSize = try aggregateBufferPolicyStore
                .recordCleanAutomaticSession(for: route) else {
                return false
            }
            pendingAggregateBufferIncrease = nil
            statusMessage = localized(
                "Revalidating \(output.name) with \(nextFrameSize)-frame buffers..."
            )
            notifyModelDidChange()
            scheduleEngineStart(
                output: output,
                profile: activeProfile,
                rollback: nil,
                aggregateBufferFrameSize: nextFrameSize
            )
            return true
        } catch {
            statusMessage = localized(
                "Could not save the lower audio buffer setting: \(error.localizedDescription)"
            )
            notifyModelDidChange()
            return false
        }
    }

    private func completePendingAggregateBufferIncreaseIfNeeded(
        output: AudioOutputDevice
    ) {
        guard let pendingAggregateBufferIncrease,
              activeAggregateRoute == pendingAggregateBufferIncrease.route,
              output.bufferFrameSize == pendingAggregateBufferIncrease.newFrameSize else {
            return
        }
        self.pendingAggregateBufferIncrease = nil
        switch pendingAggregateBufferIncrease.kind {
        case .automatic:
            aggregateBufferNotifier.notifyBufferIncrease(
                outputName: pendingAggregateBufferIncrease.outputName,
                previousFrameSize: pendingAggregateBufferIncrease.previousFrameSize,
                newFrameSize: pendingAggregateBufferIncrease.newFrameSize
            )
        case .fixedRebuild:
            aggregateBufferNotifier.notifyFixedBufferRebuild(
                outputName: pendingAggregateBufferIncrease.outputName,
                frameSize: pendingAggregateBufferIncrease.newFrameSize
            )
        case .fixedTemporaryIncrease:
            let preferredFrameSize = aggregateBufferPolicyStore.selection(
                for: pendingAggregateBufferIncrease.route
            ).frameSize
            aggregateBufferNotifier.notifyTemporaryBufferIncrease(
                outputName: pendingAggregateBufferIncrease.outputName,
                preferredFrameSize: preferredFrameSize,
                runtimeFrameSize: pendingAggregateBufferIncrease.newFrameSize
            )
        }
    }

    private func restoreProfileRollback(_ rollback: ProfileRollback, persist: Bool) {
        profileStore = rollback.profileStore
        activeProfile = rollback.activeProfile
        selectedProfileID = rollback.selectedProfileID
        draftProfile = rollback.draftProfile
        previewReturnProfile = rollback.previewReturnProfile
        if persist {
            saveStore()
        }
    }

    private func restoreEngineProfileReconciliation(
        _ reconciliation: EngineProfileReconciliation,
        persist: Bool
    ) {
        for failedAttempt in reconciliation.failedAttempts.reversed() {
            if failedAttempt.previousProfile != failedAttempt.attemptedProfile,
               profileStore.profiles.first(where: { $0.id == failedAttempt.profileID }) == failedAttempt.attemptedProfile {
                profileStore.profiles.removeAll { $0.id == failedAttempt.profileID }
                if let previousProfile = failedAttempt.previousProfile {
                    let insertionIndex = min(
                        failedAttempt.previousProfileIndex ?? profileStore.profiles.endIndex,
                        profileStore.profiles.endIndex
                    )
                    profileStore.profiles.insert(
                        previousProfile,
                        at: insertionIndex
                    )
                }
            }
            for mappingChange in failedAttempt.mappingChanges.reversed() {
                let currentMapping = profileStore.outputMappings.first {
                    $0.outputDeviceUID == mappingChange.outputUID
                }
                guard currentMapping == mappingChange.attempted else {
                    continue
                }
                profileStore.outputMappings.removeAll {
                    $0.outputDeviceUID == mappingChange.outputUID
                }
                if let previousMapping = mappingChange.previous {
                    profileStore.outputMappings.insert(
                        previousMapping,
                        at: min(
                            mappingChange.previousIndex ?? profileStore.outputMappings.endIndex,
                            profileStore.outputMappings.endIndex
                        )
                    )
                }
            }
            if selectedProfileID == failedAttempt.attemptedSelectedProfileID {
                selectedProfileID = failedAttempt.previousSelectedProfileID
            }
            if draftProfile == failedAttempt.attemptedDraftProfile {
                draftProfile = failedAttempt.previousDraftProfile
            }
            if previewReturnProfile == failedAttempt.attemptedPreviewReturnProfile {
                previewReturnProfile = failedAttempt.previousPreviewReturnProfile
            }
        }
        let confirmation = reconciliation.confirmation
        let profileIDs = Set(profileStore.profiles.map(\.id))
        let storedConfirmation = profileStore.profiles.first {
            $0.id == confirmation.activeProfile.id
        } ?? profileStore.profiles[0]
        profileStore.outputMappings.removeAll { !profileIDs.contains($0.profileID) }
        if !profileIDs.contains(profileStore.fallbackProfileID) {
            profileStore.fallbackProfileID = storedConfirmation.id
        }
        activeProfile = confirmation.activeProfile
        if !profileStore.profiles.contains(where: { $0.id == selectedProfileID }) {
            selectedProfileID = storedConfirmation.id
        }
        if !profileStore.profiles.contains(where: { $0.id == draftProfile.id }) {
            draftProfile = profileStore.profiles.first(where: { $0.id == selectedProfileID })
                ?? storedConfirmation
        }
        if let previewReturnProfile,
           !profileStore.profiles.contains(where: { $0.id == previewReturnProfile.id }) {
            self.previewReturnProfile = nil
        }
        if persist {
            saveStore()
        }
    }

    private func reschedulePendingEngineStartWithActiveProfile(rollback: ProfileRollback? = nil) {
        guard hasPendingProfileReplacingEngineWork else {
            return
        }
        if let output = pendingEngineStartOutput {
            scheduleEngineStart(output: output, profile: activeProfile, rollback: rollback)
        } else {
            scheduleEngineWork(.restart(profile: activeProfile, rollback: rollback))
        }
    }

    private var hasPendingProfileReplacingEngineWork: Bool {
        engineStartTask != nil
    }

    private func scheduleWakeReconnectRetry(status: String) {
        guard lifecycleState == .waking else {
            return
        }
        guard wakeReconnectAttempts < WakeReconnectPolicy.maximumAttempts else {
            invalidatePendingEngineStart()
            scheduleEngineStop(updateMetrics: false)
            lifecycleState = .stopped
            isRunning = false
            statusMessage = status
            notifyModelDidChange()
            return
        }

        statusMessage = status
        notifyModelDidChange()
        outputChangeGeneration += 1
        let generation = outputChangeGeneration
        outputChangeTask?.cancel()
        outputChangeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: self?.wakeReconnectDelayOverride ?? WakeReconnectPolicy.retryDelay)
            guard !Task.isCancelled,
                  self?.outputChangeGeneration == generation,
                  self?.lifecycleState == .waking else {
                return
            }
            self?.requestWakeReconnectAttempt()
        }
    }

    private func saveStore() {
        guard !profilePersistenceMode.isProtected else {
            pendingSaveTask?.cancel()
            pendingSaveTask = nil
            return
        }
        let store = profileStore
        let storeWriter = storeWriter
        let saveDebounceDelay = saveDebounceDelay

        pendingSaveTask?.cancel()
        pendingSaveTask = Task { [weak self] in
            do {
                try await Task.sleep(for: saveDebounceDelay)
                try Task.checkCancellation()
                try await storeWriter.save(store)
            } catch is CancellationError {
            } catch {
                await MainActor.run {
                    self?.statusMessage = localized("Save failed: \(error.localizedDescription)")
                    self?.notifyModelDidChange()
                }
            }
        }
    }

    func flushStoreBeforeQuit() async -> Bool {
        pendingSaveTask?.cancel()
        await pendingSaveTask?.value
        pendingSaveTask = nil
        guard !profilePersistenceMode.isProtected else {
            return true
        }
        do {
            try await storeWriter.saveAndSynchronize(profileStore)
            return true
        } catch {
            statusMessage = localized("Quit canceled: failed to save profiles: \(error.localizedDescription)")
            notifyModelDidChange()
            return false
        }
    }

    func beginSettingsCommand() throws {
        guard acceptsSettingsCommands,
              lifecycleState != .terminating else {
            throw SettingsCommandFailure(message: localized("GlassEQ is shutting down."))
        }
        activeSettingsCommandCount += 1
    }

    func finishSettingsCommand() {
        activeSettingsCommandCount -= 1
        guard activeSettingsCommandCount == 0 else {
            return
        }
        let waiters = settingsCommandDrainWaiters
        settingsCommandDrainWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func stopAcceptingSettingsCommandsAndWait() async {
        acceptsSettingsCommands = false
        guard activeSettingsCommandCount > 0 else {
            return
        }
        await withCheckedContinuation { continuation in
            settingsCommandDrainWaiters.append(continuation)
        }
    }

    func resumeSettingsCommandsAfterCancelledQuit() {
        guard lifecycleState != .terminating else {
            return
        }
        acceptsSettingsCommands = true
    }

    func resetUnsupportedProfileStore() async throws {
        guard profilePersistenceMode.isProtected else {
            throw SettingsCommandFailure(message: localized("Profile store reset is only available for stores written by a newer GlassEQ."))
        }
        pendingSaveTask?.cancel()
        await pendingSaveTask?.value
        pendingSaveTask = nil

        let result = try await storeWriter.resetUnsupportedStore()
        profilePersistenceMode = .normal
        profileStore = result.store
        activeProfile = result.store.profile(forOutputUID: currentOutputUID.isEmpty ? nil : currentOutputUID)
        selectedProfileID = activeProfile.id
        draftProfile = activeProfile
        previewReturnProfile = nil
        clearProgrammeComparisonSession()
        statusMessage = localized("Profiles reset for this GlassEQ version; previous store backed up to \(result.backupURL.lastPathComponent).")
        notifyModelDidChange()
    }

    func requestQuit() {
        Task { @MainActor [weak self] in
            guard let self else {
                NSApplication.shared.terminate(nil)
                return
            }
            await self.stopAcceptingSettingsCommandsAndWait()
            guard await self.flushStoreBeforeQuit() else {
                self.resumeSettingsCommandsAfterCancelledQuit()
                return
            }
            await self.cleanupForTerminationAndWait()
            GlassEQAppDelegate.allowNextTerminationImmediately()
            NSApplication.shared.terminate(nil)
        }
    }

    func retryAudioEngine() {
        guard lifecycleState != .terminating,
              lifecycleState != .sleeping else {
            return
        }
        guard !activeProfile.isBypassed else {
            synchronizeActiveProfileProcessing()
            notifyModelDidChange()
            return
        }
        guard lifecycleState != .waking else {
            requestWakeReconnectAttempt()
            return
        }
        renderWatchdog.reset()
        let restoredFixedFrameSize = fixedBufferRecovery?.preferredFrameSize
        clearFixedBufferRecoveryAndRestorePreference()
        if let restoredFixedFrameSize,
           case .running(let output) = engine.state {
            pendingAggregateBufferIncrease = nil
            statusMessage = localized(
                "Rebuilding \(output.name) with \(restoredFixedFrameSize)-frame buffers..."
            )
            notifyModelDidChange()
            scheduleEngineStart(
                output: output,
                profile: activeProfile,
                rollback: nil,
                aggregateBufferFrameSize: restoredFixedFrameSize
            )
            return
        }
        restartEngineWithActiveProfile()
    }

    func setAggregateBufferMode(_ mode: SettingsAggregateBufferMode) throws {
        guard let activeAggregateRoute,
              lifecycleState == .running,
              isRunning,
              engineStartTask == nil,
              case .running(let output) = engine.state else {
            throw SettingsCommandFailure(
                message: localized("Automatic buffer tuning is unavailable on this output route.")
            )
        }
        fixedBufferRecovery = nil
        try aggregateBufferPolicyStore.setMode(mode, for: activeAggregateRoute)
        let selection = aggregateBufferPolicyStore.selection(for: activeAggregateRoute)
        pendingAggregateBufferIncrease = nil
        statusMessage = localized(
            "Rebuilding \(output.name) with \(selection.frameSize)-frame buffers..."
        )
        notifyModelDidChange()
        scheduleEngineStart(
            output: output,
            profile: activeProfile,
            rollback: nil,
            aggregateBufferFrameSize: selection.frameSize
        )
    }

    func retryAutomaticAggregateBuffer() throws {
        guard let activeAggregateRoute,
              lifecycleState == .running,
              isRunning,
              engineStartTask == nil,
              case .running(let output) = engine.state else {
            throw SettingsCommandFailure(
                message: localized("Automatic buffer tuning is unavailable on this output route.")
            )
        }
        fixedBufferRecovery = nil
        try aggregateBufferPolicyStore.retryAutomaticBuffer(for: activeAggregateRoute)
        pendingAggregateBufferIncrease = nil
        statusMessage = localized(
            "Retrying 16-frame buffers on \(output.name)..."
        )
        notifyModelDidChange()
        scheduleEngineStart(
            output: output,
            profile: activeProfile,
            rollback: nil,
            aggregateBufferFrameSize: 16
        )
    }

    func openPrivacySettings() throws {
        let urls = [
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"),
            URL(string: "x-apple.systempreferences:com.apple.preference.security")
        ].compactMap { $0 }
        for url in urls where workspaceOpener.open(url) {
            return
        }
        throw SettingsCommandFailure(
            message: localized("Could not open System Settings. Open Privacy & Security manually and enable system audio capture for GlassEQ.")
        )
    }

    private func processingStatus(outputName: String, profileName: String) -> String {
        guard !outputName.isEmpty, outputName != noOutputName else {
            return localized("Processing \(profileName)")
        }
        return localized("Processing \(outputName) with \(profileName)")
    }

    private func disabledStatus(outputName: String) -> String {
        guard !outputName.isEmpty, outputName != noOutputName else {
            return localized("Audio processing disabled")
        }
        return localized("Audio processing disabled for \(outputName)")
    }

    func startMetricsPolling() {
        guard lifecycleState != .terminating else {
            return
        }
        guard metricsTask == nil else {
            return
        }

        engineMetrics = engine.snapshotMetrics()
        notifyMetricsDidChange()

        metricsTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else {
                    return
                }
                let nextMetrics = self.engine.snapshotMetrics()
                guard nextMetrics != self.engineMetrics else {
                    continue
                }
                self.engineMetrics = nextMetrics
                self.notifyMetricsDidChange()
            }
        }
    }

    func stopMetricsPolling() {
        metricsTask?.cancel()
        metricsTask = nil
    }

    private func startRenderWatchdog() {
        renderWatchdogTask?.cancel()
        renderWatchdog.pause()
        guard case .running(let output) = engine.state else {
            return
        }
        let generation = engineStartGeneration
        let route = AudioRenderWatchdogRoute(
            outputDeviceUID: output.uid,
            nativeOutputStreamIndex: activeAggregateRoute?.nativeOutputStreamIndex,
            nominalSampleRate: output.nominalSampleRate
        )
        let initialMetrics = engine.snapshotMetrics()
        _ = renderWatchdog.observe(
            generation: generation,
            route: route,
            isRunning: true,
            playedFrames: initialMetrics.playedFrames
        )
        renderWatchdogTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: self?.renderWatchdogPollInterval ?? .milliseconds(500))
                guard let self,
                      !Task.isCancelled,
                      self.lifecycleState == .running,
                      self.isRunning,
                      self.engineStartTask == nil,
                      self.engineStartGeneration == generation else {
                    return
                }
                let metrics = self.engine.snapshotMetrics()
                guard let action = self.renderWatchdog.observe(
                    generation: generation,
                    route: route,
                    isRunning: true,
                    playedFrames: metrics.playedFrames
                ) else {
                    continue
                }
                self.handleRenderWatchdogAction(action, generation: generation)
                return
            }
        }
    }

    private func handleRenderWatchdogAction(
        _ action: AudioRenderWatchdogAction,
        generation: Int
    ) {
        guard lifecycleState == .running,
              isRunning,
              engineStartTask == nil,
              engineStartGeneration == generation,
              case .running(let output) = engine.state else {
            return
        }

        switch action {
        case .restart:
            let frameSize = activeAggregateRoute.map {
                aggregateBufferFrameSize(for: $0)
            } ?? 16
            statusMessage = localized(
                "Audio rendering stalled; rebuilding \(output.name)..."
            )
            notifyModelDidChange()
            scheduleEngineWork(.recoverRenderStall(
                output: output,
                profile: activeProfile,
                aggregateBufferFrameSize: frameSize
            ))
        case .stop:
            invalidatePendingEngineStart()
            scheduleEngineStop(updateMetrics: true)
            lifecycleState = .stopped
            isRunning = false
            statusMessage = localized(
                "Audio rendering stalled again, so GlassEQ stopped processing. Retry the audio engine when ready."
            )
            notifyModelDidChange()
        }
    }

    func notifyModelDidChange() {
        NotificationCenter.default.post(name: .glassEQModelDidChange, object: self)
        settingsCoordinator.modelDidChange()
        refreshInProcessSettingsSnapshot()
    }

    private func notifyMetricsDidChange() {
        NotificationCenter.default.post(name: .glassEQMetricsDidChange, object: self)
        settingsCoordinator.metricsDidChange()
        refreshInProcessSettingsMetrics()
    }

    private func stopObserver() {
        observerCallbackGeneration += 1
        let observerToStop = observer
        observer = nil
        Task {
            await observerToStop?.stopAsync()
        }
    }

    private func invalidatePendingOutputChange() {
        outputChangeGeneration += 1
        outputChangeTask?.cancel()
        outputChangeTask = nil
    }

    private func invalidatePendingEngineStart() {
        engineStartGeneration += 1
        renderWatchdogTask?.cancel()
        renderWatchdogTask = nil
        renderWatchdog.pause()
        aggregateStabilityTask?.cancel()
        aggregateStabilityTask = nil
        headsetAggregatePromotionTask?.cancel()
        headsetAggregatePromotionTask = nil
        engineStartTask?.cancel()
        engineStartTask = nil
        pendingEngineStartOutput = nil
        activeAggregateRoute = nil
        pendingAggregateBufferIncrease = nil
        fixedBufferRecovery = nil
    }

    private func installLifecycleObservers() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        lifecycleObserverTokens.append(
            workspaceCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.handleWillSleep()
                }
            }
        )
        lifecycleObserverTokens.append(
            workspaceCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.handleDidWake()
                }
            }
        )
        lifecycleObserverTokens.append(
            workspaceCenter.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.handleSessionDidBecomeActive()
                }
            }
        )
        lifecycleObserverTokens.append(
            workspaceCenter.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.handleSessionDidBecomeActive()
                }
            }
        )
        lifecycleObserverTokens.append(
            NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    await self?.cleanupForTerminationAndWait()
                }
            }
        )
    }

    func handleWillSleep() {
        guard lifecycleState != .terminating else {
            return
        }

        wasRunningBeforeSleep = isRunning || wasRunningBeforeSleep
        invalidatePendingOutputChange()
        invalidatePendingEngineStart()
        stopObserver()
        scheduleEngineStop(updateMetrics: false)
        previewReturnProfile = nil
        clearProgrammeComparisonSession()
        clearFixedBufferRecoveryAndRestorePreference()
        lifecycleState = .sleeping
        isRunning = false
        statusMessage = localized("Paused for system sleep")
        notifyModelDidChange()
    }

    func handleDidWake() {
        guard lifecycleState != .terminating else {
            return
        }
        guard lifecycleState == .sleeping else {
            return
        }

        guard wasRunningBeforeSleep else {
            wasRunningBeforeSleep = false
            lifecycleState = .stopped
            isRunning = false
            statusMessage = localized("Stopped")
            notifyModelDidChange()
            return
        }
        beginAudioReconnect(
            status: localized("Reconnecting audio output..."),
            initialDelay: wakeReconnectDelayOverride ?? .seconds(1)
        )
    }

    func handleSessionDidBecomeActive() {
        guard lifecycleState != .terminating else {
            return
        }
        guard lifecycleState != .sleeping else {
            handleDidWake()
            return
        }
        guard !wasRunningBeforeSleep else {
            beginAudioReconnect(
                status: localized("Reconnecting audio output..."),
                initialDelay: wakeReconnectDelayOverride ?? SessionActivationReconnectPolicy.reconnectDelay
            )
            return
        }
    }

    private func beginAudioReconnect(status: String, initialDelay: Duration) {
        guard lifecycleState != .waking else {
            statusMessage = status
            notifyModelDidChange()
            return
        }
        invalidatePendingOutputChange()
        let generation = outputChangeGeneration
        wakeReconnectAttempts = 0
        lifecycleState = .waking
        statusMessage = status
        notifyModelDidChange()
        outputChangeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: initialDelay)
            guard !Task.isCancelled,
                  self?.outputChangeGeneration == generation,
                  self?.lifecycleState == .waking else {
                return
            }
            self?.requestWakeReconnectAttempt()
        }
    }

    private func requestWakeReconnectAttempt() {
        guard lifecycleState == .waking else {
            return
        }
        wakeReconnectAttempts += 1
        startObserver(sendInitialValue: true)
    }

    func cleanupForTermination() {
        guard prepareForTermination(shutdownSettings: true) else {
            return
        }
        scheduleEngineStop(updateMetrics: false)
    }

    func cleanupForTerminationAndWait() async {
        await stopAcceptingSettingsCommandsAndWait()
        guard prepareForTermination(shutdownSettings: false) else {
            return
        }
        await settingsCoordinator.shutdownAndWait()
        _ = await stopEngineOffMain()
    }

    private func prepareForTermination(shutdownSettings: Bool) -> Bool {
        guard lifecycleState != .terminating else {
            return false
        }
        lifecycleState = .terminating
        acceptsSettingsCommands = false
        wasRunningBeforeSleep = false
        invalidatePendingOutputChange()
        invalidatePendingEngineStart()
        metricsTask?.cancel()
        metricsTask = nil
        stopObserver()
        previewReturnProfile = nil
        clearProgrammeComparisonSession()
        isRunning = false
        if shutdownSettings {
            settingsCoordinator.shutdown()
        }
        notifyModelDidChange()
        return true
    }

    private func audioEngineStatusMessage(_ error: Error) -> String {
        if let coreAudioError = error as? CoreAudioError {
            return audioEngineStatusMessage(classifyCoreAudioError(coreAudioError))
        }
        if let availabilityError = error as? AudioDeviceAvailabilityError {
            switch availabilityError {
            case .unsupportedOutputChannelCount,
                 .unsupportedOutputBufferFrameSize:
                return localized("Output format unsupported: \(availabilityError.description)")
            default:
                return localized("Default output unavailable: \(availabilityError.description)")
            }
        }
        return localized("Audio engine failed: \(error.localizedDescription)")
    }

    private func audioEngineStatusMessage(_ failure: AudioEngineFailure) -> String {
        switch failure.category {
        case .systemAudioCapturePermission:
            return localized("System audio capture permission required. Enable GlassEQ in System Settings, then retry.")
        case .outputDeviceUnavailable:
            return localized("Default output unavailable: \(failure.userMessage)")
        case .deviceFormatUnsupported:
            return localized("Output format unsupported: \(failure.operation)")
        case .coreAudioOperationFailed:
            if let status = failure.status {
                return localized("Audio engine failed at \(failure.operation) (\(formatOSStatus(status)))")
            }
            return localized("Audio engine failed: \(failure.userMessage)")
        }
    }

    private func handleRuntimeAudioEngineFailure(_ failure: AudioEngineFailure) {
        guard lifecycleState == .running,
              engineStartTask == nil,
              case .failed = engine.state else {
            return
        }
        clearProgrammeComparisonSession(restoringEqualizedRendererIfRunning: true)
        invalidatePendingEngineStart()
        lifecycleState = .stopped
        isRunning = false
        statusMessage = audioEngineStatusMessage(failure)
        notifyModelDidChange()
    }

    private static func profileStoreLoadStatusMessage(_ status: ProfileStoreLoadStatus) -> String? {
        switch status {
        case .loaded, .missingStore:
            return nil
        case .repairedReferences(let summary):
            return profileStoreRepairStatus(summary)
        case .repairedInvalidStore:
            return localized("Profile store was invalid; backed it up and repaired valid profiles")
        case .recoveredDefaults:
            return localized("Profile store was invalid; backed it up and restored defaults")
        case .backupFailed:
            return localized("Profile store was invalid; using defaults, but backup failed")
        case let .unsupportedSchemaVersion(version, maximumSupported):
            return localized("Profile store was written by a newer GlassEQ version (schema \(version)); using defaults without modifying it. This build supports schema \(maximumSupported).")
        }
    }

    private static func profileStoreRepairStatus(_ summary: ProfileStoreRepairSummary) -> String {
        if summary.repairedFallbackProfileID && summary.removedOutputMappings > 0 {
            return localized("Profile store repaired: reset fallback and removed unavailable output mappings")
        }
        if summary.repairedFallbackProfileID {
            return localized("Profile store repaired: fallback reset")
        }
        if summary.removedInvalidProfiles > 0 {
            return localized("Profile store repaired: removed invalid profile")
        }
        if summary.removedOutputMappings > 0 || summary.deduplicatedOutputMappings > 0 {
            return localized("Profile store repaired: removed unavailable output mapping")
        }
        return localized("Profile store repaired")
    }
}

private struct MenuBarView: View {
    @Bindable var model: GlassEQAppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()

            popoverValue(title: localized("Output"), value: model.currentOutputName)

            VStack(alignment: .leading, spacing: 5) {
                Text(localized("Profile"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Picker(localized("Profile"), selection: Binding(
                    get: { model.selectedProfileID },
                    set: { model.selectProfile($0) }
                )) {
                    ForEach(model.profileStore.profiles) { profile in
                        Text(profile.name).tag(profile.id)
                    }
                }
                .labelsHidden()
                .accessibilityLabel(Text(localized("Profile")))
                .accessibilityValue(Text(model.selectedProfile.name))
                .accessibilityHint(Text(localized("Chooses a profile for editing")))
            }

            HStack(spacing: 10) {
                Button {
                    model.setBypass(!model.activeProfile.isBypassed)
                } label: {
                    Label(
                        model.activeProfile.isBypassed ? localized("Enable") : localized("Disable"),
                        systemImage: model.activeProfile.isBypassed ? "speaker.wave.2" : "speaker.slash"
                    )
                        .frame(minWidth: 82, minHeight: 28)
                        .contentShape(.rect)
                }
                .controlSize(.large)
                .buttonStyle(.glass)
                .tint(popoverControlsAreActive ? enableButtonTint : nil)
                .accessibilityLabel(Text(model.activeProfile.isBypassed ? localized("Enable equalizer") : localized("Disable equalizer")))
                .accessibilityValue(Text(statusBadgeTitle))
                .accessibilityHint(Text(localized("Starts or stops system audio processing for the active profile")))

                Button {
                    dismiss()
                    model.openSettings()
                } label: {
                    Label(localized("Settings"), systemImage: "slider.horizontal.3")
                        .frame(minWidth: 86, minHeight: 28)
                        .contentShape(.rect)
                }
                .controlSize(.large)
                .buttonStyle(.glass)

                Button(role: .destructive) {
                    model.requestQuit()
                } label: {
                    Label(localized("Quit"), systemImage: "power")
                        .frame(minWidth: 58, minHeight: 28)
                        .contentShape(.rect)
                }
                .controlSize(.large)
                .buttonStyle(.glass)
                .tint(popoverControlsAreActive ? .macOSSystemRed : nil)
            }

            #if DEBUG
            Button(localized("Test render watchdog")) {
                model.simulateRenderStallForTesting()
            }
            .disabled(!model.isRunning || model.activeProfile.isBypassed)
            .accessibilityHint(Text(localized("Freezes render progress metrics without stopping audio")))
            #endif

            Text(model.statusMessage)
                .font(.caption.weight(.medium))
                .foregroundStyle(model.isRunning ? Color.secondary : Color.macOSSystemRed)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(Text(localized("Status")))
                .accessibilityValue(Text(model.statusMessage))
        }
        .padding()
        .background { PopoverGlassConfigurator() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(localized("GlassEQ"))
                    .font(.title3.weight(.semibold))
                Text(AppBuildInfo.displayVersion)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(statusBadgeTitle)
                .font(.caption.weight(.semibold))
                .foregroundStyle(statusBadgeColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    statusBadgeColor.opacity(0.12),
                    in: .capsule
                )
                .accessibilityLabel(Text(localized("Menu bar state")))
                .accessibilityValue(Text(statusBadgeTitle))
        }
    }

    private var statusBadgeTitle: String {
        if model.activeProfile.isBypassed {
            return localized("Disabled")
        }
        return model.isRunning ? localized("Active") : localized("Stopped")
    }

    private var statusBadgeColor: Color {
        model.isRunning && !model.activeProfile.isBypassed ? .macOSSystemGreen : .macOSSystemRed
    }

    private var enableButtonTint: Color {
        model.activeProfile.isBypassed ? .macOSSystemGreen : .macOSSystemYellow
    }

    private var popoverControlsAreActive: Bool {
        controlActiveState != .inactive
    }

    private func popoverValue(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(value))
    }
}


private enum PopoverGlassAppearance {
    /// Opacity applied to the popover's system Liquid Glass backing (NSGlassView).
    /// 1.0 keeps the full system frost; lower values thin it so more of the desktop shows
    /// through. Our content is a sibling of the backing, so it stays fully opaque regardless.
    static let backingAlpha: CGFloat = 0.2
}

private final class PopoverGlassConfiguringView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else {
            return
        }
        let root = window.contentView?.superview ?? window.contentView
        root.map(Self.dimGlassBacking)
    }

    private static func dimGlassBacking(_ view: NSView) {
        if String(describing: type(of: view)) == "NSGlassView" {
            view.alphaValue = PopoverGlassAppearance.backingAlpha
        }
        for subview in view.subviews {
            dimGlassBacking(subview)
        }
    }
}

private struct PopoverGlassConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> PopoverGlassConfiguringView {
        PopoverGlassConfiguringView()
    }

    func updateNSView(_ nsView: PopoverGlassConfiguringView, context: Context) {}
}

private extension Color {
    static let macOSSystemGreen = Color(nsColor: .systemGreen)
    static let macOSSystemRed = Color(nsColor: .systemRed)
    static let macOSSystemYellow = Color(nsColor: .systemYellow)
}
