import CoreAudio
import Foundation
import GlassEQAudio
import GlassEQCore
import GlassEQSettingsIPC
import Testing
@testable import GlassEQApp

@MainActor
@Suite
struct GlassEQAppModelLifecycleTests {
    @Test
    func runtimeEngineFailureStopsTheModelAndSurfacesItsStatus() async {
        let output = makeOutput(uid: "runtime-output", name: "Runtime Output")
        let engine = FakeAudioEngine()
        engine.state = .running(output: output)
        let model = makeModel(engine: engine)

        model.retryAudioEngine()
        await waitUntil {
            model.lifecycleState == .running
        }
        engine.emitRuntimeFailure(adaptiveRenderFailure)
        await waitUntil {
            model.lifecycleState == .stopped
        }

        #expect(!model.isRunning)
        #expect(model.statusMessage == localized(
            "Audio engine failed: \(adaptiveRenderFailure.userMessage)"
        ))
    }

    @Test
    func renderWatchdogStopsTapBeforeOneAutomaticRebuild() async {
        let output = makeOutput(uid: "watchdog-rebuild", name: "Watchdog Rebuild")
        let engine = FakeAudioEngine()
        let model = makeModel(
            engine: engine,
            lookup: FakeDefaultOutputLookup(.success(output)),
            renderWatchdogStallThreshold: .milliseconds(50),
            renderWatchdogRepeatedFailureWindow: .seconds(1),
            renderWatchdogPollInterval: .milliseconds(5)
        )

        model.retryAudioEngine()
        await waitUntil {
            engine.startCalls.count == 2 && model.lifecycleState == .running
        }

        #expect(engine.events.prefix(3) == [
            "start:\(output.uid)",
            "stop",
            "start:\(output.uid)"
        ])
        model.stop()
    }

    @Test
    func repeatedRenderStallFailsOpenAndLeavesRetryAvailable() async {
        let output = makeOutput(uid: "watchdog-stop", name: "Watchdog Stop")
        let engine = FakeAudioEngine()
        let model = makeModel(
            engine: engine,
            lookup: FakeDefaultOutputLookup(.success(output)),
            renderWatchdogStallThreshold: .milliseconds(20),
            renderWatchdogRepeatedFailureWindow: .seconds(1),
            renderWatchdogPollInterval: .milliseconds(5)
        )

        model.retryAudioEngine()
        await waitUntil {
            engine.startCalls.count == 2
                && engine.stopCallCount == 2
                && model.lifecycleState == .stopped
        }

        #expect(!model.isRunning)
        #expect(model.statusMessage.contains("stalled again"))
    }

    @Test
    func runtimeFailureDoesNotCancelNewerPendingRouteStart() async {
        let firstOutput = makeOutput(uid: "runtime-first", name: "Runtime First", id: 200)
        let secondOutput = makeOutput(uid: "runtime-second", name: "Runtime Second", id: 300)
        let engine = FakeAudioEngine()
        let lookup = FakeDefaultOutputLookup(.success(firstOutput))
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
            engine: engine,
            lookup: lookup,
            observers: observers,
            outputDelay: .zero
        )

        model.start()
        let observer = observers.observers[0]
        observer.emit(.success(firstOutput))
        await waitUntil {
            model.lifecycleState == .running && engine.startCalls.count == 1
        }

        engine.blockStart(for: secondOutput.uid)
        lookup.result = .success(secondOutput)
        observer.emit(.success(secondOutput))
        await waitUntil {
            engine.startCalls.contains { $0.output == secondOutput }
        }
        #expect(engine.waitUntilStartIsBlocked(for: secondOutput.uid, timeout: .now() + 1))

        engine.emitRuntimeFailure(adaptiveRenderFailure)
        await settleAsyncWork()
        #expect(model.lifecycleState == .running)

        engine.unblockStart(for: secondOutput.uid)
        await waitUntil {
            model.lifecycleState == .running
                && model.currentOutputUID == secondOutput.uid
                && engine.state == .running(output: secondOutput)
        }
    }

    @Test
    func staleRuntimeFailureDoesNotStopCompletedNewerRoute() async {
        let firstOutput = makeOutput(uid: "stale-runtime-first", name: "Stale Runtime First", id: 200)
        let secondOutput = makeOutput(uid: "stale-runtime-second", name: "Stale Runtime Second", id: 300)
        let engine = FakeAudioEngine()
        let lookup = FakeDefaultOutputLookup(.success(firstOutput))
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
            engine: engine,
            lookup: lookup,
            observers: observers,
            outputDelay: .zero
        )

        model.start()
        let observer = observers.observers[0]
        observer.emit(.success(firstOutput))
        await waitUntil {
            model.lifecycleState == .running && engine.startCalls.count == 1
        }
        lookup.result = .success(secondOutput)
        observer.emit(.success(secondOutput))
        await waitUntil {
            model.lifecycleState == .running
                && model.currentOutputUID == secondOutput.uid
                && engine.state == .running(output: secondOutput)
        }

        engine.emitRuntimeFailure(adaptiveRenderFailure, markEngineFailed: false)
        await settleAsyncWork()

        #expect(model.lifecycleState == .running)
        #expect(model.isRunning)
        #expect(model.currentOutputUID == secondOutput.uid)
        #expect(engine.state == .running(output: secondOutput))
    }

    @Test
    func settledHeadsetRoutePromotesToCombinedAggregate() async {
        let output = makeOutput(
            uid: "headset-promotion",
            name: "AirPods Headset",
            nominalSampleRate: 24_000,
            bufferFrameSize: 480
        )
        let engine = FakeAudioEngine()
        engine.headsetPromotionCandidateUIDs = [output.uid]
        engine.headsetAggregatePromotionResult = .promoted(output)
        let lookup = FakeDefaultOutputLookup(.success(output))
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
            engine: engine,
            lookup: lookup,
            observers: observers,
            outputDelay: .zero,
            aggregateStabilityDelay: .seconds(1),
            headsetAggregatePromotionDelay: .zero
        )

        model.start()
        observers.observers[0].emit(.success(output))
        await waitUntil {
            engine.headsetAggregatePromotionAttemptCount == 1
                && engine.isUsingPromotedHeadsetAggregate
        }

        #expect(engine.startCalls.count == 1)
        #expect(model.statusMessage.contains("low-latency headset path"))
    }

    @Test
    func coldStartupCompatibilityWaitsForActivePlaybackBeforePromotion() async {
        let output = makeOutput(uid: "cold-start-promotion", name: "D10s")
        let engine = FakeAudioEngine()
        engine.coldStartupPromotionCandidateUIDs = [output.uid]
        engine.coldStartupAggregatePromotionResult = .clientsActive
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
            engine: engine,
            lookup: FakeDefaultOutputLookup(.success(output)),
            observers: observers,
            outputDelay: .zero,
            coldStartupAggregatePromotionPollInterval: .milliseconds(10)
        )

        model.start()
        observers.observers[0].emit(.success(output))
        await waitUntil {
            engine.coldStartupAggregatePromotionAttemptCount > 0
                && model.statusMessage.contains("until active playback releases the output")
        }

        engine.coldStartupAggregatePromotionResult = .promoted(output)
        await waitUntil {
            !engine.isDeferringColdStartupAggregate
                && model.statusMessage.contains("Processing D10s")
        }

        #expect(engine.startCalls.count == 1)
        #expect(engine.coldStartupAggregatePromotionAttemptCount >= 2)
    }

    @Test
    func rejectedProfileChangeRestartsColdStartupPromotion() async throws {
        let running = makeProfile(name: "Cold Start Running")
        let requested = makeProfile(name: "Cold Start Requested")
        let output = makeOutput(uid: "cold-start-profile-failure", name: "D10s")
        let store = ProfileStore(
            profiles: [running, requested],
            fallbackProfileID: running.id
        )
        let engine = FakeAudioEngine()
        engine.coldStartupPromotionCandidateUIDs = [output.uid]
        engine.coldStartupAggregatePromotionResult = .clientsActive
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
            store: store,
            engine: engine,
            lookup: FakeDefaultOutputLookup(.success(output)),
            observers: observers,
            outputDelay: .zero,
            coldStartupAggregatePromotionPollInterval: .milliseconds(10)
        )

        model.start()
        observers.observers[0].emit(.success(output))
        await waitUntil {
            model.lifecycleState == .running
                && engine.coldStartupAggregatePromotionAttemptCount > 0
        }

        engine.updateDSPResult = false
        engine.updateError = TestAudioError.updateFailed
        engine.updateErrorPreservesRunningState = true
        try model.apply(profile: requested)
        await waitUntil {
            model.statusMessage.contains("not applied")
        }

        engine.coldStartupAggregatePromotionResult = .promoted(output)
        await waitUntil {
            !engine.isDeferringColdStartupAggregate
        }

        #expect(model.activeProfile == running)
        #expect(engine.state == .running(output: output))
    }

    @Test
    func promotedHeadsetRouteFallsBackAfterOneSteadyStateJump() async {
        let output = makeOutput(
            uid: "headset-demotion",
            name: "AirPods Headset",
            nominalSampleRate: 24_000,
            bufferFrameSize: 480
        )
        let engine = FakeAudioEngine()
        engine.headsetPromotionCandidateUIDs = [output.uid]
        engine.headsetAggregatePromotionResult = .promoted(output)
        let lookup = FakeDefaultOutputLookup(.success(output))
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
            engine: engine,
            lookup: lookup,
            observers: observers,
            outputDelay: .zero,
            headsetAggregatePromotionDelay: .zero
        )

        model.start()
        observers.observers[0].emit(.success(output))
        await waitUntil {
            engine.headsetAggregatePromotionAttemptCount == 1
                && engine.isUsingPromotedHeadsetAggregate
        }
        try? await Task.sleep(for: .milliseconds(300))

        var metrics = engine.metrics
        metrics.qualifyingPairedTimestampDiscontinuities = 1
        engine.metrics = metrics
        await waitUntil {
            engine.startCalls.count == 2
                && engine.isUsingTransitionalHeadsetBackend
        }

        try? await Task.sleep(for: .milliseconds(100))
        #expect(engine.headsetAggregatePromotionAttemptCount == 1)
        #expect(model.statusMessage.contains("compatibility mode"))
    }

    @Test
    func automaticAggregateBufferClimbsToSixtyFourAfterQualifyingInterruptions() async {
        let output = makeOutput(uid: "adaptive-aggregate", name: "Adaptive Aggregate")
        let engine = FakeAudioEngine()
        engine.reflectPreferredAggregateBufferFrameSize = true
        let notifier = FakeAggregateBufferNotifier()
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
            engine: engine,
            observers: observers,
            outputDelay: .zero,
            aggregateBufferNotifier: notifier
        )

        model.start()
        observers.observers[0].emit(.success(output))
        await waitUntil {
            model.lifecycleState == .running
                && engine.startCalls.count == 1
                && engine.startCalls[0].aggregateBufferFrameSize == 16
        }
        try? await Task.sleep(for: .milliseconds(30))

        var metrics = engine.metrics
        metrics.qualifyingPairedTimestampDiscontinuities = 1
        engine.metrics = metrics
        try? await Task.sleep(for: .milliseconds(350))
        #expect(engine.startCalls.count == 1)

        metrics = engine.metrics
        metrics.qualifyingPairedTimestampDiscontinuities = 2
        engine.metrics = metrics
        await waitUntil {
            engine.startCalls.count == 2
                && engine.startCalls[1].aggregateBufferFrameSize == 32
                && notifier.calls.count == 1
        }
        try? await Task.sleep(for: .milliseconds(30))

        metrics = engine.metrics
        metrics.qualifyingPairedTimestampDiscontinuities = 3
        engine.metrics = metrics
        try? await Task.sleep(for: .milliseconds(350))
        #expect(engine.startCalls.count == 2)

        metrics = engine.metrics
        metrics.qualifyingPairedTimestampDiscontinuities = 4
        engine.metrics = metrics
        await waitUntil {
            engine.startCalls.count == 3
                && engine.startCalls[2].aggregateBufferFrameSize == 64
                && notifier.calls.count == 2
        }

        metrics = engine.metrics
        metrics.qualifyingPairedTimestampDiscontinuities = 6
        engine.metrics = metrics
        try? await Task.sleep(for: .milliseconds(350))

        #expect(engine.startCalls.count == 3)
        #expect(model.settingsSnapshot().aggregateBuffer.automaticFrameSize == 64)
    }

    @Test
    func fixedBufferRebuildsOnceThenUsesTemporarySaferRung() async throws {
        let output = makeOutput(uid: "fixed-recovery", name: "Fixed Recovery")
        let engine = FakeAudioEngine()
        engine.reflectPreferredAggregateBufferFrameSize = true
        let notifier = FakeAggregateBufferNotifier()
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
            engine: engine,
            observers: observers,
            outputDelay: .zero,
            aggregateBufferNotifier: notifier
        )

        model.start()
        observers.observers[0].emit(.success(output))
        await waitUntil {
            model.lifecycleState == .running && engine.startCalls.count == 1
        }
        try model.setAggregateBufferMode(.frames16)
        await waitUntil {
            engine.startCalls.count == 2
                && engine.startCalls[1].aggregateBufferFrameSize == 16
        }
        try? await Task.sleep(for: .milliseconds(50))

        var metrics = engine.metrics
        metrics.renderDeadlineMisses = 3
        engine.metrics = metrics
        await waitUntil {
            engine.startCalls.count == 3
                && engine.startCalls[2].aggregateBufferFrameSize == 16
                && notifier.calls.last?.kind == .fixedRebuild
        }
        try? await Task.sleep(for: .milliseconds(50))

        metrics = engine.metrics
        metrics.renderDeadlineMisses = 6
        engine.metrics = metrics
        await waitUntil {
            engine.startCalls.count == 4
                && engine.startCalls[3].aggregateBufferFrameSize == 32
                && notifier.calls.last?.kind == .fixedTemporaryIncrease
        }

        let temporarySnapshot = model.settingsSnapshot()
        #expect(temporarySnapshot.aggregateBuffer.mode == .frames16)
        #expect(temporarySnapshot.currentOutputBufferFrameSize == 32)

        model.retryAudioEngine()
        await waitUntil {
            engine.startCalls.count == 5
                && engine.startCalls[4].aggregateBufferFrameSize == 16
                && model.settingsSnapshot().currentOutputBufferFrameSize == 16
        }
        #expect(model.settingsSnapshot().aggregateBuffer.mode == .frames16)
        #expect(model.settingsSnapshot().currentOutputBufferFrameSize == 16)
    }

    @Test
    func automaticAggregateBufferIgnoresInterruptionsBeforeRouteSettles() async {
        let output = makeOutput(uid: "settling-aggregate", name: "Settling Aggregate")
        let engine = FakeAudioEngine()
        engine.reflectPreferredAggregateBufferFrameSize = true
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
            engine: engine,
            observers: observers,
            outputDelay: .zero,
            aggregateStabilityDelay: .seconds(1)
        )

        model.start()
        observers.observers[0].emit(.success(output))
        await waitUntil {
            model.lifecycleState == .running && engine.startCalls.count == 1
        }
        var metrics = engine.metrics
        metrics.qualifyingPairedTimestampDiscontinuities = 1
        engine.metrics = metrics
        try? await Task.sleep(for: .milliseconds(350))

        #expect(engine.startCalls.count == 1)
        #expect(model.settingsSnapshot().aggregateBuffer.automaticFrameSize == 16)
    }

    @Test
    func automaticAggregateBufferRetriesLowerRungAfterThreeCleanRuns() async throws {
        let storeURL = temporaryAppStoreURL()
        defer { removeTemporaryStoreDirectory(for: storeURL) }
        let output = makeOutput(uid: "clean-aggregate", name: "Clean Aggregate")
        let route = AggregateAudioRouteFingerprint(
            outputDeviceUID: output.uid,
            nativeOutputStreamIndex: 0,
            nominalSampleRate: output.nominalSampleRate
        )
        let policyStoreURL = storeURL.deletingPathExtension()
            .appendingPathExtension("aggregate-buffer-policy.json")
        let policyStore = AggregateBufferPolicyStore(url: policyStoreURL)
        #expect(try policyStore.recordAutomaticFailure(
            for: route,
            occurrences: 2
        ) == 32)
        #expect(try policyStore.recordCleanAutomaticSession(for: route) == nil)
        #expect(try policyStore.recordCleanAutomaticSession(for: route) == nil)
        #expect(AggregateBufferPolicyStore(url: policyStoreURL).selection(for: route).frameSize == 32)

        let engine = FakeAudioEngine()
        #expect(try engine.aggregateRouteFingerprint(for: output) == route)
        engine.reflectPreferredAggregateBufferFrameSize = true
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
            storeURL: storeURL,
            engine: engine,
            lookup: FakeDefaultOutputLookup(.success(output)),
            observers: observers,
            outputDelay: .zero,
            aggregateCleanSessionDuration: .zero
        )

        model.start()
        observers.observers[0].emit(.success(output))
        let scheduledRetry = await waitUntil(maxAttempts: 500) {
            engine.startCalls.count == 2
        }
        let completedRetry = await waitUntil(maxAttempts: 500) {
            model.settingsSnapshot().currentOutputBufferFrameSize == 16
        }

        #expect(scheduledRetry)
        #expect(completedRetry)
        #expect(engine.startCalls.count == 2)
        #expect(engine.startCalls.first?.aggregateBufferFrameSize == 32)
        #expect(engine.startCalls.last?.aggregateBufferFrameSize == 16)
        #expect(model.settingsSnapshot().currentOutputBufferFrameSize == 16)
        #expect(model.settingsSnapshot().aggregateBuffer.automaticFrameSize == 16)
    }

    @Test
    func aggregateBufferControlsAreUnavailableDuringARebuild() async throws {
        let output = makeOutput(uid: "rebuilding-aggregate", name: "Rebuilding Aggregate")
        let engine = FakeAudioEngine()
        engine.reflectPreferredAggregateBufferFrameSize = true
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(engine: engine, observers: observers, outputDelay: .zero)

        model.start()
        observers.observers[0].emit(.success(output))
        await waitUntil {
            model.lifecycleState == .running && engine.startCalls.count == 1
        }
        #expect(model.settingsSnapshot().aggregateBuffer.isAvailable)

        engine.startDelaySeconds = 0.1
        try model.setAggregateBufferMode(.frames32)

        #expect(!model.settingsSnapshot().aggregateBuffer.isAvailable)
        #expect(throws: SettingsCommandFailure.self) {
            try model.setAggregateBufferMode(.frames64)
        }

        await waitUntil {
            engine.startCalls.count == 2
                && model.settingsSnapshot().aggregateBuffer.isAvailable
        }
        #expect(model.settingsSnapshot().aggregateBuffer.isAvailable)
    }

    @Test
    func retryRunningEngineUpdatesActiveProfileWithoutDefaultLookup() async {
        let runningOutput = makeOutput(uid: "running-output", name: "Running Output")
        let defaultOutput = makeOutput(uid: "default-output", name: "Default Output")
        let engine = FakeAudioEngine()
        engine.state = .running(output: runningOutput)
        let lookup = FakeDefaultOutputLookup(.success(defaultOutput))
        let model = makeModel(engine: engine, lookup: lookup)

        model.retryAudioEngine()
        await waitUntil {
            model.lifecycleState == .running && engine.updateCalls.count == 1
        }

        #expect(engine.updateCalls.map(\.id) == [model.activeProfile.id])
        #expect(engine.startCalls.isEmpty)
        #expect(lookup.defaultOutputCalls == 0)
        #expect(model.currentOutputUID == runningOutput.uid)
        #expect(model.currentOutputName == runningOutput.name)
        #expect(model.isRunning)
        #expect(model.lifecycleState == .running)
    }

    @Test
    func preservingRetryFailureDoesNotMutateTheProfileStore() async {
        let running = makeProfile(name: "Retry Running")
        let inactive = makeProfile(name: "Retry Inactive")
        let output = makeOutput(uid: "retry-preserved-output", name: "Retry Preserved Output")
        let store = ProfileStore(
            profiles: [running, inactive],
            outputMappings: [OutputDeviceProfileMapping(
                outputDeviceUID: output.uid,
                profileID: running.id
            )],
            fallbackProfileID: inactive.id
        )
        let engine = FakeAudioEngine()
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
            store: store,
            engine: engine,
            lookup: FakeDefaultOutputLookup(.success(output)),
            observers: observers,
            outputDelay: .zero
        )

        model.start()
        observers.observers[0].emit(.success(output))
        await waitUntil {
            model.lifecycleState == .running && engine.startCalls.count == 1
        }
        engine.updateError = TestAudioError.updateFailed
        engine.updateErrorPreservesRunningState = true

        model.retryAudioEngine()

        await waitUntil {
            engine.updateCalls.count == 1 && model.statusMessage.contains("not applied")
        }

        #expect(model.profileStore == store)
        #expect(model.activeProfile == running)
        #expect(engine.state == .running(output: output))
    }

    @Test
    func retryStoppedEngineQueriesDefaultOutputAndStarts() async {
        let output = makeOutput(uid: "default-output", name: "Default Output")
        let engine = FakeAudioEngine()
        let lookup = FakeDefaultOutputLookup(.success(output))
        let model = makeModel(engine: engine, lookup: lookup)

        model.retryAudioEngine()
        await waitUntil {
            model.lifecycleState == .running && engine.startCalls.count == 1
        }

        #expect(lookup.defaultOutputCalls == 1)
        #expect(engine.updateCalls.isEmpty)
        #expect(engine.startCalls.map(\.output) == [output])
        #expect(model.currentOutputUID == output.uid)
        #expect(model.currentOutputName == output.name)
        #expect(model.isRunning)
        #expect(model.lifecycleState == .running)
    }

    @Test
    func retryFailedEngineKeepsOutputMetadataWhenStartFails() async {
        let output = makeOutput(uid: "metadata-output", name: "Metadata Output")
        let engine = FakeAudioEngine()
        engine.state = .failed("Previous failure")
        engine.startError = TestAudioError.startFailed
        let lookup = FakeDefaultOutputLookup(.success(output))
        let model = makeModel(engine: engine, lookup: lookup)

        model.retryAudioEngine()
        await waitUntil {
            lookup.defaultOutputCalls == 1
                && engine.startCalls.count == 1
                && model.lifecycleState == .stopped
                && model.currentOutputUID == output.uid
        }

        #expect(lookup.defaultOutputCalls == 1)
        #expect(engine.startCalls.map(\.output) == [output])
        #expect(model.currentOutputUID == output.uid)
        #expect(model.currentOutputName == output.name)
        #expect(!model.isRunning)
        #expect(model.lifecycleState == .stopped)
    }

    @Test
    func profileAppliedDuringRouteStartIsRepublishedAfterTheRouteSettles() async throws {
        let firstOutput = makeOutput(uid: "profile-first", name: "Profile First", id: 200)
        let secondOutput = makeOutput(uid: "profile-second", name: "Profile Second", id: 300)
        let initialProfile = makeProfile(name: "Initial")
        let appliedProfile = makeProfile(name: "Applied During Route Start")
        let store = ProfileStore(
            profiles: [initialProfile, appliedProfile],
            fallbackProfileID: initialProfile.id
        )
        let engine = FakeAudioEngine()
        let lookup = FakeDefaultOutputLookup(.success(firstOutput))
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
            store: store,
            engine: engine,
            lookup: lookup,
            observers: observers,
            outputDelay: .zero
        )

        model.start()
        let observer = observers.observers[0]
        observer.emit(.success(firstOutput))
        await waitUntil {
            model.lifecycleState == .running && engine.startCalls.count == 1
        }

        engine.blockStart(for: secondOutput.uid)
        lookup.result = .success(secondOutput)
        observer.emit(.success(secondOutput))
        await waitUntil {
            engine.startCalls.count == 2
        }
        #expect(engine.waitUntilStartIsBlocked(for: secondOutput.uid, timeout: .now() + 1))

        try model.apply(profile: appliedProfile)
        #expect(engine.updateDSPCalls.isEmpty)

        engine.unblockStart(for: secondOutput.uid)
        await waitUntil {
            model.lifecycleState == .running
                && model.currentOutputUID == secondOutput.uid
                && engine.startCalls.count == 3
                && engine.startCalls.last?.profile == appliedProfile
                && model.activeProfile == appliedProfile
                && model.statusMessage
                    == localized("Processing \(secondOutput.name) with \(appliedProfile.name)")
        }

        #expect(engine.startCalls.last?.profile == appliedProfile)
        #expect(model.activeProfile == appliedProfile)
        #expect(model.statusMessage == localized("Processing \(secondOutput.name) with \(appliedProfile.name)"))
    }

    @Test
    func profilePreviewedDuringRouteStartIsRepublishedAfterTheRouteSettles() async {
        let firstOutput = makeOutput(uid: "preview-first", name: "Preview First", id: 200)
        let secondOutput = makeOutput(uid: "preview-second", name: "Preview Second", id: 300)
        let initialProfile = makeProfile(name: "Initial")
        let previewProfile = makeProfile(name: "Preview During Route Start")
        let store = ProfileStore(
            profiles: [initialProfile, previewProfile],
            fallbackProfileID: initialProfile.id
        )
        let engine = FakeAudioEngine()
        let lookup = FakeDefaultOutputLookup(.success(firstOutput))
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
            store: store,
            engine: engine,
            lookup: lookup,
            observers: observers,
            outputDelay: .zero
        )

        model.start()
        let observer = observers.observers[0]
        observer.emit(.success(firstOutput))
        await waitUntil {
            model.lifecycleState == .running && engine.startCalls.count == 1
        }

        engine.blockStart(for: secondOutput.uid)
        lookup.result = .success(secondOutput)
        observer.emit(.success(secondOutput))
        await waitUntil {
            engine.startCalls.count == 2
        }
        #expect(engine.waitUntilStartIsBlocked(for: secondOutput.uid, timeout: .now() + 1))

        model.preview(profile: previewProfile)
        #expect(engine.updateDSPCalls.isEmpty)

        engine.unblockStart(for: secondOutput.uid)
        await waitUntil {
            model.lifecycleState == .running
                && model.currentOutputUID == secondOutput.uid
                && engine.startCalls.count == 3
        }

        #expect(engine.startCalls.last?.profile == previewProfile)
        #expect(model.activeProfile == previewProfile)
        #expect(model.previewReturnProfile == initialProfile)
    }

    @Test
    func profileStartFailureDuringPendingRouteRestoresTheRunningProfile() async throws {
        let firstOutput = makeOutput(uid: "rollback-first", name: "Rollback First", id: 200)
        let secondOutput = makeOutput(uid: "rollback-second", name: "Rollback Second", id: 300)
        let initialProfile = makeProfile(name: "Initial")
        let requestedProfile = makeProfile(name: "Requested During Route Start")
        let store = ProfileStore(
            profiles: [initialProfile, requestedProfile],
            fallbackProfileID: initialProfile.id
        )
        let engine = FakeAudioEngine()
        let lookup = FakeDefaultOutputLookup(.success(firstOutput))
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
            store: store,
            engine: engine,
            lookup: lookup,
            observers: observers,
            outputDelay: .zero
        )

        model.start()
        let observer = observers.observers[0]
        observer.emit(.success(firstOutput))
        await waitUntil {
            model.lifecycleState == .running && engine.startCalls.count == 1
        }

        engine.blockStart(for: secondOutput.uid)
        lookup.result = .success(secondOutput)
        observer.emit(.success(secondOutput))
        await waitUntil {
            engine.startCalls.count == 2
        }
        #expect(engine.waitUntilStartIsBlocked(for: secondOutput.uid, timeout: .now() + 1))

        engine.startError = TestAudioError.startFailed
        engine.startErrorProfileID = requestedProfile.id
        engine.startErrorPreservesRunningState = true
        try model.apply(profile: requestedProfile)
        engine.unblockStart(for: secondOutput.uid)

        await waitUntil {
            engine.startCalls.count == 3
                && model.lifecycleState == .running
                && model.statusMessage.contains("not applied")
        }

        #expect(engine.startCalls.last?.profile == requestedProfile)
        #expect(engine.state == .running(output: secondOutput))
        #expect(model.activeProfile == initialProfile)
        #expect(model.selectedProfileID == initialProfile.id)
        #expect(model.draftProfile == initialProfile)
        #expect(model.profileStore == store)
    }

    @Test
    func routeStartFailureRestoresTheProfileRunningOnThePreviousOutput() async {
        let firstOutput = makeOutput(uid: "route-rollback-first", name: "Route Rollback First", id: 200)
        let secondOutput = makeOutput(uid: "route-rollback-second", name: "Route Rollback Second", id: 300)
        let firstProfile = makeProfile(name: "First Output Profile")
        let secondProfile = makeProfile(name: "Second Output Profile")
        let store = ProfileStore(
            profiles: [firstProfile, secondProfile],
            outputMappings: [OutputDeviceProfileMapping(
                outputDeviceUID: secondOutput.uid,
                profileID: secondProfile.id
            )],
            fallbackProfileID: firstProfile.id
        )
        let engine = FakeAudioEngine()
        let lookup = FakeDefaultOutputLookup(.success(firstOutput))
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
            store: store,
            engine: engine,
            lookup: lookup,
            observers: observers,
            outputDelay: .zero
        )

        model.start()
        let observer = observers.observers[0]
        observer.emit(.success(firstOutput))
        await waitUntil {
            model.lifecycleState == .running && engine.startCalls.count == 1
        }

        engine.startError = TestAudioError.startFailed
        engine.startErrorProfileID = secondProfile.id
        engine.startErrorPreservesRunningState = true
        lookup.result = .success(secondOutput)
        observer.emit(.success(secondOutput))

        await waitUntil {
            engine.startCalls.count == 2
                && model.lifecycleState == .running
                && model.statusMessage.contains("not applied")
        }

        #expect(engine.state == .running(output: firstOutput))
        #expect(model.currentOutputUID == firstOutput.uid)
        #expect(model.activeProfile == firstProfile)
        #expect(model.selectedProfileID == firstProfile.id)
        #expect(model.draftProfile == firstProfile)
        #expect(model.profileStore == store)
    }

    @Test
    func routeStartFailureAfterPendingInitialStartRestoresItsProfile() async {
        let firstOutput = makeOutput(uid: "pending-rollback-first", name: "Pending Rollback First", id: 200)
        let secondOutput = makeOutput(uid: "pending-rollback-second", name: "Pending Rollback Second", id: 300)
        let firstProfile = makeProfile(name: "Pending First Profile")
        let secondProfile = makeProfile(name: "Pending Second Profile")
        let store = ProfileStore(
            profiles: [firstProfile, secondProfile],
            outputMappings: [OutputDeviceProfileMapping(
                outputDeviceUID: secondOutput.uid,
                profileID: secondProfile.id
            )],
            fallbackProfileID: firstProfile.id
        )
        let engine = FakeAudioEngine()
        let lookup = FakeDefaultOutputLookup(.success(firstOutput))
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
            store: store,
            engine: engine,
            lookup: lookup,
            observers: observers,
            outputDelay: .zero
        )

        engine.blockStart(for: firstOutput.uid)
        model.start()
        let observer = observers.observers[0]
        observer.emit(.success(firstOutput))
        await waitUntil {
            engine.startCalls.count == 1
        }
        #expect(engine.waitUntilStartIsBlocked(for: firstOutput.uid, timeout: .now() + 1))
        #expect(!model.isRunning)

        engine.startError = TestAudioError.startFailed
        engine.startErrorProfileID = secondProfile.id
        engine.startErrorPreservesRunningState = true
        lookup.result = .success(secondOutput)
        observer.emit(.success(secondOutput))
        await settleAsyncWork()
        engine.unblockStart(for: firstOutput.uid)

        await waitUntil {
            engine.startCalls.count == 2
                && model.lifecycleState == .running
                && model.statusMessage.contains("not applied")
        }

        #expect(engine.state == .running(output: firstOutput))
        #expect(model.currentOutputUID == firstOutput.uid)
        #expect(model.activeProfile == firstProfile)
        #expect(model.selectedProfileID == firstProfile.id)
        #expect(model.draftProfile == firstProfile)
        #expect(model.profileStore == store)
    }

    @Test
    func chainedProfileAndRouteFailuresRestoreTheLastConfirmedProfile() async throws {
        let firstOutput = makeOutput(uid: "confirmed-first", name: "Confirmed First", id: 200)
        let secondOutput = makeOutput(uid: "confirmed-second", name: "Confirmed Second", id: 300)
        let confirmedProfile = makeProfile(name: "Confirmed Profile")
        var requestedProfile = confirmedProfile
        requestedProfile.name = "Requested Profile"
        let routeProfile = makeProfile(name: "Route Profile")
        let store = ProfileStore(
            profiles: [confirmedProfile, routeProfile],
            outputMappings: [OutputDeviceProfileMapping(
                outputDeviceUID: secondOutput.uid,
                profileID: routeProfile.id
            )],
            fallbackProfileID: confirmedProfile.id
        )
        let engine = FakeAudioEngine()
        let lookup = FakeDefaultOutputLookup(.success(firstOutput))
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
            store: store,
            engine: engine,
            lookup: lookup,
            observers: observers,
            outputDelay: .zero
        )

        model.start()
        let observer = observers.observers[0]
        observer.emit(.success(firstOutput))
        await waitUntil {
            model.lifecycleState == .running && engine.startCalls.count == 1
        }

        try model.createProfile(kind: .graphic10)
        let createdProfile = model.draftProfile

        engine.updateDSPResult = false
        engine.updateError = TestAudioError.updateFailed
        engine.updateErrorPreservesRunningState = true
        engine.blockUpdate(for: requestedProfile.id)
        try model.apply(profile: requestedProfile)
        await waitUntil {
            engine.updateCalls.count == 1
        }
        #expect(engine.waitUntilUpdateIsBlocked(for: requestedProfile.id, timeout: .now() + 1))

        engine.startError = TestAudioError.startFailed
        engine.startErrorProfileID = routeProfile.id
        engine.startErrorPreservesRunningState = true
        lookup.result = .success(secondOutput)
        observer.emit(.success(secondOutput))
        await settleAsyncWork()
        engine.unblockUpdate(for: requestedProfile.id)

        await waitUntil {
            engine.startCalls.count == 2
                && model.lifecycleState == .running
                && model.statusMessage.contains("not applied")
        }

        #expect(engine.state == .running(output: firstOutput))
        #expect(model.currentOutputUID == firstOutput.uid)
        #expect(model.activeProfile == confirmedProfile)
        #expect(model.selectedProfileID == createdProfile.id)
        #expect(model.draftProfile == createdProfile)
        #expect(model.profileStore.profiles.contains(createdProfile))
        #expect(model.profileStore.profiles.count == store.profiles.count + 1)
        #expect(model.profileStore.outputMappings == store.outputMappings)
        #expect(model.profileStore.fallbackProfileID == store.fallbackProfileID)
    }

    @Test
    func cancelledQueuedProfileChangeStillRollsBackIfItsReplacementFails() async throws {
        let firstOutput = makeOutput(uid: "queued-first", name: "Queued First", id: 200)
        let secondOutput = makeOutput(uid: "queued-second", name: "Queued Second", id: 300)
        let confirmed = makeProfile(name: "Queued Confirmed")
        var intermediate = confirmed
        intermediate.name = "Queued Intermediate"
        var final = confirmed
        final.name = "Queued Final"
        let store = ProfileStore(profiles: [confirmed], fallbackProfileID: confirmed.id)
        let engine = FakeAudioEngine()
        let lookup = FakeDefaultOutputLookup(.success(firstOutput))
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
            store: store,
            engine: engine,
            lookup: lookup,
            observers: observers,
            outputDelay: .zero
        )

        model.start()
        let observer = observers.observers[0]
        observer.emit(.success(firstOutput))
        await waitUntil {
            model.lifecycleState == .running && engine.startCalls.count == 1
        }

        engine.blockStart(for: secondOutput.uid)
        lookup.result = .success(secondOutput)
        observer.emit(.success(secondOutput))
        await waitUntil { engine.startCalls.count == 2 }
        #expect(engine.waitUntilStartIsBlocked(for: secondOutput.uid, timeout: .now() + 1))

        try model.apply(profile: intermediate)
        await settleAsyncWork()
        #expect(engine.startCalls.count == 2)
        try model.apply(profile: final)
        engine.startError = TestAudioError.startFailed
        engine.startErrorProfileID = final.id
        engine.startErrorPreservesRunningState = true
        engine.unblockStart(for: secondOutput.uid)

        await waitUntil {
            engine.startCalls.count == 3
                && model.lifecycleState == .running
                && model.statusMessage.contains("not applied")
        }

        #expect(engine.startCalls.map(\.profile.name) == [confirmed.name, confirmed.name, final.name])
        #expect(engine.state == .running(output: secondOutput))
        #expect(model.activeProfile == confirmed)
        #expect(model.profileStore == store)
    }

    @Test
    func chainedMappingRollbackPassesThroughADeletedIntermediateProfile() async throws {
        let firstOutput = makeOutput(uid: "mapping-chain-first", name: "Mapping Chain First", id: 200)
        let secondOutput = makeOutput(uid: "mapping-chain-second", name: "Mapping Chain Second", id: 300)
        let confirmed = makeProfile(name: "Mapping Chain Confirmed")
        let intermediate = makeProfile(name: "Mapping Chain Intermediate")
        let final = makeProfile(name: "Mapping Chain Final")
        let originalMapping = OutputDeviceProfileMapping(
            outputDeviceUID: secondOutput.uid,
            profileID: confirmed.id
        )
        let store = ProfileStore(
            profiles: [confirmed, intermediate, final],
            outputMappings: [originalMapping],
            fallbackProfileID: confirmed.id
        )
        let engine = FakeAudioEngine()
        let lookup = FakeDefaultOutputLookup(.success(firstOutput))
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
            store: store,
            engine: engine,
            lookup: lookup,
            observers: observers,
            outputDelay: .zero
        )

        model.start()
        let observer = observers.observers[0]
        observer.emit(.success(firstOutput))
        await waitUntil {
            model.lifecycleState == .running && engine.startCalls.count == 1
        }

        engine.blockStart(for: secondOutput.uid)
        lookup.result = .success(secondOutput)
        observer.emit(.success(secondOutput))
        await waitUntil { engine.startCalls.count == 2 }
        #expect(engine.waitUntilStartIsBlocked(for: secondOutput.uid, timeout: .now() + 1))

        try model.useForCurrentOutput(profile: intermediate)
        await settleAsyncWork()
        #expect(engine.startCalls.count == 2)
        try model.useForCurrentOutput(profile: final)
        try model.deleteProfile(id: intermediate.id)
        engine.startError = TestAudioError.startFailed
        engine.startErrorProfileID = final.id
        engine.startErrorPreservesRunningState = true
        engine.unblockStart(for: secondOutput.uid)

        await waitUntil {
            engine.startCalls.count == 3
                && model.lifecycleState == .running
                && model.statusMessage.contains("not applied")
        }

        #expect(model.activeProfile == confirmed)
        #expect(model.profileStore.outputMappings == [originalMapping])
        #expect(!model.profileStore.profiles.contains(where: { $0.id == intermediate.id }))
        #expect(model.profileStore.profile(forOutputUID: secondOutput.uid) == confirmed)
        #expect(engine.state == .running(output: secondOutput))
    }

    @Test
    func settingsRetryDisabledActiveProfileDoesNotStartEngine() async throws {
        var disabled = makeProfile(name: "Disabled")
        disabled.isBypassed = true
        let output = makeOutput(uid: "retry-disabled-output", name: "Retry Disabled Output")
        let engine = FakeAudioEngine()
        let lookup = FakeDefaultOutputLookup(.success(output))
        let model = makeModel(
            store: ProfileStore(profiles: [disabled], fallbackProfileID: disabled.id),
            engine: engine,
            lookup: lookup
        )

        let response = try await model.performSettingsCommand(.retryAudioEngine)
        await settleAsyncWork()

        let snapshot = try #require(response.snapshot)
        #expect(snapshot.statusMessage == localized("Audio processing disabled"))
        #expect(snapshot.activeProfileID == disabled.id)
        #expect(engine.startCalls.isEmpty)
        #expect(engine.updateCalls.isEmpty)
        #expect(engine.updateDSPCalls.isEmpty)
        #expect(engine.stopCallCount == 0)
        #expect(lookup.defaultOutputCalls == 0)
        #expect(!model.isRunning)
        #expect(model.lifecycleState == .stopped)
    }

    @Test
    func outputChangeClearsPreviewAndStopPreviewIsNoOp() async {
        let fallback = makeProfile(name: "Fallback")
        let preview = makeProfile(name: "Preview")
        let mapped = makeProfile(name: "Mapped")
        let output = makeOutput(uid: "mapped-output", name: "Mapped Output")
        let store = ProfileStore(
            profiles: [fallback, preview, mapped],
            outputMappings: [
                OutputDeviceProfileMapping(outputDeviceUID: output.uid, profileID: mapped.id)
            ],
            fallbackProfileID: fallback.id
        )
        let engine = FakeAudioEngine()
        let lookup = FakeDefaultOutputLookup(.success(output))
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
            store: store,
            engine: engine,
            lookup: lookup,
            observers: observers,
            outputDelay: .zero
        )

        model.preview(profile: preview)
        #expect(model.previewReturnProfile?.id == fallback.id)

        model.start()
        observers.observers[0].emit(.success(output))
        await waitUntil {
            model.previewReturnProfile == nil
                && model.activeProfile.id == mapped.id
                && model.lifecycleState == .running
        }

        #expect(model.previewReturnProfile == nil)
        #expect(model.activeProfile.id == mapped.id)
        #expect(model.lifecycleState == .running)

        model.stopPreview()

        #expect(model.activeProfile.id == mapped.id)
        #expect(model.previewReturnProfile == nil)
    }

    @Test
    func programmeComparisonKeepsTheActiveProfileAndReturnsThroughDSPTransition() async throws {
        let active = makeProfile(name: "Active")
        let output = makeOutput(uid: "comparison-output", name: "Comparison Output")
        let engine = FakeAudioEngine()
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
            store: ProfileStore(profiles: [active], fallbackProfileID: active.id),
            engine: engine,
            lookup: FakeDefaultOutputLookup(.success(output)),
            observers: observers,
            outputDelay: .zero
        )
        model.start()
        observers.observers[0].emit(.success(output))
        await waitUntil {
            model.lifecycleState == .running && engine.startCalls.count == 1
        }

        var draft = active
        draft.preampDB = -6
        draft.filters = [
            EQFilter(kind: .peak, frequency: 1_000, gainDB: 5, q: 1)
        ]
        try model.startProgrammeComparison(profile: draft)

        #expect(engine.programmeComparisonCalls == [draft])
        #expect(engine.programmeComparisonSelections == [.equalized])
        #expect(model.activeProfile == active)
        #expect(model.settingsSnapshot().programmeComparison.isActive)

        model.selectProgrammeComparison(.filtersOff)
        #expect(engine.programmeComparisonSelections == [.equalized, .filtersOff])
        #expect(model.settingsSnapshot().programmeComparison.selection == .filtersOff)

        engine.programmeComparisonSnapshot = EQProgrammeComparisonSnapshot(
            isActive: true,
            isReady: true,
            selection: .filtersOff,
            equalizedAttenuationDB: -3.25
        )
        await waitUntil {
            model.settingsSnapshot().programmeComparison.isReady
        }
        #expect(
            abs(
                model.settingsSnapshot().programmeComparison.equalizedAttenuationDB
                    + 3.25
            ) < 0.001
        )

        model.stopProgrammeComparison()

        #expect(engine.programmeComparisonSelections.last == .equalized)
        #expect(engine.updateDSPCalls.last == active)
        #expect(!model.settingsSnapshot().programmeComparison.isActive)
        #expect(model.activeProfile == active)
    }

    @Test
    func outputChangeClearsProgrammeComparisonWithoutRestoringThePreviousRouteProfile() async throws {
        let firstProfile = makeProfile(name: "First Route")
        let secondProfile = makeProfile(name: "Second Route")
        let firstOutput = makeOutput(uid: "comparison-first-output", name: "First Output")
        let secondOutput = makeOutput(uid: "comparison-second-output", name: "Second Output")
        let store = ProfileStore(
            profiles: [firstProfile, secondProfile],
            outputMappings: [
                OutputDeviceProfileMapping(
                    outputDeviceUID: secondOutput.uid,
                    profileID: secondProfile.id
                )
            ],
            fallbackProfileID: firstProfile.id
        )
        let engine = FakeAudioEngine()
        let lookup = FakeDefaultOutputLookup(.success(firstOutput))
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
            store: store,
            engine: engine,
            lookup: lookup,
            observers: observers,
            outputDelay: .zero
        )

        model.start()
        let observer = observers.observers[0]
        observer.emit(.success(firstOutput))
        await waitUntil {
            model.lifecycleState == .running && engine.startCalls.count == 1
        }

        var comparisonProfile = firstProfile
        comparisonProfile.preampDB = -6
        try model.startProgrammeComparison(profile: comparisonProfile)
        model.selectProgrammeComparison(.filtersOff)

        lookup.result = .success(secondOutput)
        observer.emit(.success(secondOutput))
        await waitUntil {
            model.lifecycleState == .running
                && model.currentOutputUID == secondOutput.uid
                && engine.startCalls.count == 2
        }

        #expect(!model.settingsSnapshot().programmeComparison.isActive)
        #expect(model.activeProfile == secondProfile)
        #expect(engine.programmeComparisonSelections == [
            .equalized,
            .filtersOff,
            .equalized
        ])

        let updatesBeforeStop = engine.updateDSPCalls
        model.stopProgrammeComparison()

        #expect(engine.updateDSPCalls == updatesBeforeStop)
        #expect(model.activeProfile == secondProfile)
    }

    @Test
    func runtimeFailureClearsProgrammeComparisonAndLaterStopIsNoOp() async throws {
        let active = makeProfile(name: "Runtime Comparison")
        let output = makeOutput(uid: "runtime-comparison-output", name: "Runtime Output")
        let engine = FakeAudioEngine()
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
            store: ProfileStore(profiles: [active], fallbackProfileID: active.id),
            engine: engine,
            lookup: FakeDefaultOutputLookup(.success(output)),
            observers: observers,
            outputDelay: .zero
        )

        model.start()
        observers.observers[0].emit(.success(output))
        await waitUntil {
            model.lifecycleState == .running && engine.startCalls.count == 1
        }

        var comparisonProfile = active
        comparisonProfile.preampDB = -6
        try model.startProgrammeComparison(profile: comparisonProfile)
        model.selectProgrammeComparison(.filtersOff)

        engine.emitRuntimeFailure(adaptiveRenderFailure)
        await waitUntil {
            model.lifecycleState == .stopped
        }

        #expect(!model.settingsSnapshot().programmeComparison.isActive)
        #expect(model.activeProfile == active)

        let updatesBeforeStop = engine.updateDSPCalls
        model.stopProgrammeComparison()

        #expect(engine.updateDSPCalls == updatesBeforeStop)
        #expect(model.activeProfile == active)
    }

    @Test
    func outputChangeToBypassedProfileDoesNotStartEngine() async {
        let fallback = makeProfile(name: "Fallback")
        var disabled = makeProfile(name: "Disabled")
        disabled.isBypassed = true
        let output = makeOutput(uid: "disabled-output", name: "Disabled Output")
        let store = ProfileStore(
            profiles: [fallback, disabled],
            outputMappings: [
                OutputDeviceProfileMapping(outputDeviceUID: output.uid, profileID: disabled.id)
            ],
            fallbackProfileID: fallback.id
        )
        let engine = FakeAudioEngine()
        let lookup = FakeDefaultOutputLookup(.success(output))
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(store: store, engine: engine, lookup: lookup, observers: observers, outputDelay: .zero)

        model.start()
        observers.observers[0].emit(.success(output))
        await waitUntil {
            model.activeProfile.id == disabled.id
                && model.lifecycleState == .stopped
                && model.statusMessage == localized("Audio processing disabled for \(output.name)")
        }

        #expect(engine.startCalls.isEmpty)
        #expect(engine.stopCallCount == 0)
        #expect(!model.isRunning)
        #expect(model.activeProfile.isBypassed)
    }

    @Test
    func startDoesNotBlockOnAsyncObserverStart() async throws {
        let observers = BlockingAsyncDefaultOutputObserverFactory()
        let model = makeModel(observers: observers, outputDelay: .zero)

        let start = Date()
        model.start()
        let elapsed = Date().timeIntervalSince(start)

        #expect(elapsed < 0.05)
        let observer = try #require(observers.observers.first)
        await waitUntil {
            observer.startCalls == [true]
        }
        #expect(model.lifecycleState == .stopped)

        model.stop()
        observer.resumeStart()
        await waitUntil {
            observer.stopCallCount == 1
        }

        #expect(observer.stopCallCount == 1)
    }

    @Test
    func availabilityFailureDuringRouteSwitchStartsSettledDefaultOutput() async {
        let airPods = makeOutput(
            uid: "airpods-output",
            name: "AirPods",
            id: 100,
            transportType: kAudioDeviceTransportTypeBluetooth
        )
        let speakers = makeOutput(uid: "speaker-output", name: "Mac Speakers", id: 200)
        let engine = FakeAudioEngine()
        let lookup = FakeDefaultOutputLookup(.success(airPods))
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
            engine: engine,
            lookup: lookup,
            observers: observers,
            outputDelay: .zero
        )

        model.start()
        let observer = observers.observers[0]
        observer.emit(.success(airPods))
        await waitUntil {
            model.lifecycleState == .running && engine.startCalls.count == 1
        }

        lookup.result = .success(speakers)
        observer.emit(.failure(AudioDeviceAvailabilityError.outputDeviceNotAlive(airPods.id)))

        await waitUntil {
            model.lifecycleState == .running
                && engine.startCalls.count == 2
                && model.currentOutputUID == speakers.uid
                && model.statusMessage == localized("Processing \(speakers.name) with \(model.activeProfile.name)")
        }

        #expect(model.isRunning)
        #expect(model.currentOutputName == speakers.name)
        #expect(engine.startCalls.map(\.output) == [airPods, speakers])
        #expect(model.statusMessage == localized("Processing \(speakers.name) with \(model.activeProfile.name)"))
    }

    @Test
    func runningOutputUIDChangeMutesImmediatelyThenRebuildsSettledOutput() async {
        let speakers = makeOutput(uid: "speaker-output", name: "Mac Speakers", id: 200)
        let scarlett = makeOutput(uid: "scarlett-output", name: "Scarlett Solo", id: 300)
        let engine = FakeAudioEngine()
        let lookup = FakeDefaultOutputLookup(.success(speakers))
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
            engine: engine,
            lookup: lookup,
            observers: observers,
            outputDelay: .milliseconds(200)
        )

        model.start()
        let observer = observers.observers[0]
        observer.emit(.success(speakers))
        await waitUntil {
            model.lifecycleState == .running && engine.startCalls.count == 1
        }

        lookup.result = .success(scarlett)
        observer.emit(.success(scarlett))

        await waitUntil {
            engine.muteOutputCallCount == 1
        }
        #expect(engine.muteOutputCallCount == 1)

        await waitUntil {
            engine.startCalls.map(\.output) == [speakers, scarlett]
        }

        #expect(model.currentOutputUID == scarlett.uid)
        #expect(model.lifecycleState == .running)
        #expect(engine.events == ["start:\(speakers.uid)", "mute", "start:\(scarlett.uid)"])
    }

    @Test
    func runningOutputFormatChangeMutesImmediatelyThenRebuildsSettledOutput() async {
        let initialOutput = makeOutput(
            uid: "same-output",
            name: "USB DAC",
            id: 200,
            nominalSampleRate: 48_000,
            bufferFrameSize: 256
        )
        let changedOutput = makeOutput(
            uid: "same-output",
            name: "USB DAC",
            id: 200,
            nominalSampleRate: 44_100,
            bufferFrameSize: 512
        )
        let engine = FakeAudioEngine()
        let lookup = FakeDefaultOutputLookup(.success(initialOutput))
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
            engine: engine,
            lookup: lookup,
            observers: observers,
            outputDelay: .milliseconds(200)
        )

        model.start()
        let observer = observers.observers[0]
        observer.emit(.success(initialOutput))
        await waitUntil {
            model.lifecycleState == .running && engine.startCalls.count == 1
        }

        lookup.result = .success(changedOutput)
        observer.emit(.success(changedOutput))

        await waitUntil {
            engine.muteOutputCallCount == 1
        }
        #expect(engine.muteOutputCallCount == 1)

        await waitUntil {
            engine.startCalls.map(\.output) == [initialOutput, changedOutput]
        }

        #expect(model.currentOutputSampleRate == changedOutput.nominalSampleRate)
        #expect(model.currentOutputBufferFrameSize == changedOutput.bufferFrameSize)
        #expect(engine.events == ["start:\(initialOutput.uid)", "mute", "start:\(changedOutput.uid)"])
    }

    @Test
    func returningToRunningOutputBeforeSettlementCancelsPendingRebuild() async {
        let runningOutput = makeOutput(uid: "running-output", name: "USB DAC", id: 200)
        let transientOutput = makeOutput(uid: "transient-output", name: "Display", id: 300)
        let engine = FakeAudioEngine()
        let lookup = FakeDefaultOutputLookup(.success(runningOutput))
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
            engine: engine,
            lookup: lookup,
            observers: observers,
            outputDelay: .milliseconds(100)
        )

        model.start()
        let observer = observers.observers[0]
        observer.emit(.success(runningOutput))
        await waitUntil {
            model.lifecycleState == .running && engine.startCalls.count == 1
        }

        lookup.result = .success(transientOutput)
        observer.emit(.success(transientOutput))
        await waitUntil {
            engine.muteOutputCallCount == 1
        }

        lookup.result = .success(runningOutput)
        observer.emit(.success(runningOutput))
        await waitUntil {
            engine.resumeOutputCallCount == 1
        }
        try? await Task.sleep(for: .milliseconds(150))

        #expect(engine.startCalls.map(\.output) == [runningOutput])
        #expect(engine.events == ["start:\(runningOutput.uid)", "mute", "resume"])
        #expect(model.lifecycleState == .running)
    }

    @Test
    func redundantRunningOutputNotificationDoesNotMuteOrRebuild() async {
        let output = makeOutput(
            uid: "stable-output",
            name: "USB DAC",
            id: 201,
            nominalSampleRate: 48_000,
            bufferFrameSize: 512
        )
        let engine = FakeAudioEngine()
        let lookup = FakeDefaultOutputLookup(.success(output))
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
            engine: engine,
            lookup: lookup,
            observers: observers,
            outputDelay: .zero
        )

        model.start()
        let observer = observers.observers[0]
        observer.emit(.success(output))
        await waitUntil {
            model.lifecycleState == .running && engine.startCalls.count == 1
        }

        observer.emit(.success(output))
        await settleAsyncWork()

        #expect(engine.muteOutputCallCount == 0)
        #expect(engine.startCalls.map(\.output) == [output])
        #expect(model.lifecycleState == .running)
    }

    @Test
    func physicalBufferChangeRebuildsWithoutMutingBeforeSettlement() async {
        let initialOutput = makeOutput(
            uid: "buffer-change-output",
            name: "USB DAC",
            id: 202,
            nominalSampleRate: 48_000,
            bufferFrameSize: 256
        )
        let changedOutput = makeOutput(
            uid: "buffer-change-output",
            name: "USB DAC",
            id: 202,
            nominalSampleRate: 48_000,
            bufferFrameSize: 512
        )
        let engine = FakeAudioEngine()
        let lookup = FakeDefaultOutputLookup(.success(initialOutput))
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
            engine: engine,
            lookup: lookup,
            observers: observers,
            outputDelay: .zero
        )

        model.start()
        let observer = observers.observers[0]
        observer.emit(.success(initialOutput))
        await waitUntil {
            model.lifecycleState == .running && engine.startCalls.count == 1
        }

        lookup.result = .success(changedOutput)
        observer.emit(.success(changedOutput))
        await waitUntil {
            engine.startCalls.count == 2
        }

        #expect(engine.muteOutputCallCount == 0)
        #expect(engine.startCalls.map(\.output) == [initialOutput, changedOutput])
        #expect(model.currentOutputBufferFrameSize == changedOutput.bufferFrameSize)
    }

    @Test
    func settingsSnapshotUsesTheActiveDSPRateForAConvertedOutput() {
        let output = makeOutput(
            uid: "converted-output",
            name: "Bluetooth headset",
            nominalSampleRate: 24_000
        )
        let engine = FakeAudioEngine()
        engine.state = .running(output: output)
        engine.processingSampleRate = 48_000
        let model = makeModel(engine: engine)
        model.currentOutputUID = output.uid
        model.currentOutputSampleRate = output.nominalSampleRate

        let snapshot = model.settingsSnapshot()

        #expect(snapshot.currentOutputSampleRate == 24_000)
        #expect(snapshot.currentProcessingSampleRate == 48_000)
    }

    @Test
    func settingsSnapshotPreservesTheDSPRateWhileTheSameRouteIsStopped() {
        let output = makeOutput(
            uid: "converted-output",
            name: "Bluetooth headset",
            nominalSampleRate: 24_000
        )
        let engine = FakeAudioEngine()
        engine.state = .running(output: output)
        engine.processingSampleRate = 48_000
        let model = makeModel(engine: engine)
        model.currentOutputUID = output.uid
        model.currentOutputSampleRate = output.nominalSampleRate

        #expect(model.settingsSnapshot().currentProcessingSampleRate == 48_000)

        engine.state = .stopped
        engine.processingSampleRate = nil

        #expect(model.settingsSnapshot().currentProcessingSampleRate == 48_000)

        model.currentOutputSampleRate = 44_100

        #expect(model.settingsSnapshot().currentProcessingSampleRate == 0)
    }

    @Test
    func settingsSnapshotDoesNotSubstituteAnUnknownDSPRate() {
        let output = makeOutput(
            uid: "converted-output",
            name: "Bluetooth headset",
            nominalSampleRate: 24_000
        )
        let model = makeModel(engine: FakeAudioEngine())
        model.currentOutputUID = output.uid
        model.currentOutputSampleRate = output.nominalSampleRate

        let snapshot = model.settingsSnapshot()

        #expect(snapshot.currentOutputSampleRate == 24_000)
        #expect(snapshot.currentProcessingSampleRate == 0)
    }

    @Test
    func settingsSnapshotDoesNotAssociateAStaleRuntimeWithANewRoute() {
        let oldOutput = makeOutput(
            uid: "old-output",
            name: "Speakers",
            nominalSampleRate: 48_000
        )
        let newOutput = makeOutput(
            uid: "new-output",
            name: "Bluetooth headset",
            nominalSampleRate: 24_000
        )
        let engine = FakeAudioEngine()
        engine.state = .running(output: oldOutput)
        engine.processingSampleRate = 48_000
        let model = makeModel(engine: engine)
        model.currentOutputUID = newOutput.uid
        model.currentOutputSampleRate = newOutput.nominalSampleRate

        #expect(model.settingsSnapshot().currentProcessingSampleRate == 0)
    }

    @Test
    func incompatibleImpulseResponsePreviewPreservesWorkingEngine() async {
        let active = makeProfile(name: "Active")
        let impulse = makeImpulseResponseProfile(name: "48 kHz IR", sampleRate: 48_000)
        let store = ProfileStore(
            profiles: [active, impulse],
            fallbackProfileID: active.id
        )
        let output = makeOutput(
            uid: "preview-rate-mismatch",
            name: "44.1 kHz Output",
            nominalSampleRate: 44_100
        )
        let engine = FakeAudioEngine()
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
            store: store,
            engine: engine,
            lookup: FakeDefaultOutputLookup(.success(output)),
            observers: observers,
            outputDelay: .zero
        )
        model.start()
        observers.observers[0].emit(.success(output))
        await waitUntil {
            model.lifecycleState == .running && engine.startCalls.count == 1
        }

        model.preview(profile: impulse)

        #expect(model.lifecycleState == .running)
        #expect(model.isRunning)
        #expect(engine.state == .running(output: output))
        #expect(engine.stopCallCount == 0)
        #expect(engine.updateDSPCalls.isEmpty)
        #expect(model.profileStore == store)
        #expect(model.activeProfile == active)
        #expect(model.selectedProfileID == active.id)
        #expect(model.draftProfile == active)
        #expect(model.previewReturnProfile == nil)
        #expect(model.statusMessage.contains("48"))
        #expect(model.statusMessage.contains("44"))
    }

    @Test
    func incompatibleMappedImpulseResponseStaysDryUntilTheRouteMatches() async {
        let fallback = makeProfile(name: "Fallback")
        let impulse = makeImpulseResponseProfile(name: "Mapped IR", sampleRate: 48_000)
        let incompatibleOutput = makeOutput(
            uid: "mapped-ir-output",
            name: "Mapped Output",
            nominalSampleRate: 44_100
        )
        let store = ProfileStore(
            profiles: [fallback, impulse],
            outputMappings: [
                OutputDeviceProfileMapping(
                    outputDeviceUID: incompatibleOutput.uid,
                    profileID: impulse.id
                )
            ],
            fallbackProfileID: fallback.id
        )
        let engine = FakeAudioEngine()
        let lookup = FakeDefaultOutputLookup(.success(incompatibleOutput))
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
            store: store,
            engine: engine,
            lookup: lookup,
            observers: observers,
            outputDelay: .zero
        )

        model.start()
        let observer = observers.observers[0]
        observer.emit(.success(incompatibleOutput))
        await waitUntil {
            model.currentOutputUID == incompatibleOutput.uid
                && model.currentOutputSampleRate == 44_100
                && model.lifecycleState == .stopped
                && model.statusMessage.contains(impulse.name)
        }

        #expect(!model.isRunning)
        #expect(engine.startCalls.isEmpty)
        #expect(model.activeProfile == impulse)
        #expect(model.profileStore.outputMappings == store.outputMappings)
        #expect(model.statusMessage.contains("48"))
        #expect(model.statusMessage.contains("44"))

        model.retryAudioEngine()
        await settleAsyncWork()
        #expect(engine.startCalls.isEmpty)
        #expect(model.lifecycleState == .stopped)

        var compatibleOutput = incompatibleOutput
        compatibleOutput.nominalSampleRate = 48_000
        lookup.result = .success(compatibleOutput)
        observer.emit(.success(compatibleOutput))
        await waitUntil {
            model.lifecycleState == .running
                && engine.startCalls.count == 1
        }

        #expect(engine.startCalls[0].profile == impulse)
        #expect(model.profileStore.outputMappings == store.outputMappings)
    }

    @Test
    func unknownSeparateClockImpulseResponseStaysDryAcrossRetries() async throws {
        let fallback = makeProfile(name: "Fallback")
        let impulse = makeImpulseResponseProfile(name: "Cold Route IR", sampleRate: 48_000)
        let output = makeOutput(
            uid: "cold-ir-output",
            name: "Bluetooth headset",
            nominalSampleRate: 24_000,
            transportType: kAudioDeviceTransportTypeBluetooth
        )
        let store = ProfileStore(
            profiles: [fallback, impulse],
            outputMappings: [
                OutputDeviceProfileMapping(
                    outputDeviceUID: output.uid,
                    profileID: impulse.id
                )
            ],
            fallbackProfileID: fallback.id
        )
        let engine = FakeAudioEngine()
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
            store: store,
            engine: engine,
            lookup: FakeDefaultOutputLookup(.success(output)),
            observers: observers,
            outputDelay: .zero
        )

        model.start()
        observers.observers[0].emit(.success(output))
        await waitUntil {
            model.currentOutputUID == output.uid
                && model.lifecycleState == .stopped
                && model.statusMessage.contains(impulse.name)
        }

        #expect(!model.isRunning)
        #expect(engine.startCalls.isEmpty)
        #expect(model.profileStore.outputMappings == store.outputMappings)
        #expect(model.statusMessage.contains("not measured"))

        model.retryAudioEngine()
        await settleAsyncWork()

        #expect(engine.startCalls.isEmpty)
        #expect(model.lifecycleState == .stopped)
        #expect(model.statusMessage.contains("not measured"))

        try model.apply(profile: fallback)
        await waitUntil {
            model.lifecycleState == .running && engine.startCalls.count == 1
        }
        engine.processingSampleRate = 48_000

        try model.apply(profile: impulse)

        #expect(model.activeProfile == impulse)
        #expect(engine.updateDSPCalls.last == impulse)
    }

    @Test
    func stopThenImmediateRestartEnqueuesStopBeforeNewStart() async {
        let output = makeOutput(uid: "restart-output", name: "Restart Output")
        let engine = FakeAudioEngine()
        let lookup = FakeDefaultOutputLookup(.success(output))
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
            engine: engine,
            lookup: lookup,
            observers: observers,
            outputDelay: .zero
        )

        model.start()
        observers.observers[0].emit(.success(output))
        await waitUntil {
            model.lifecycleState == .running && engine.startCalls.count == 1
        }

        model.stop()
        model.start()
        observers.observers.last?.emit(.success(output))

        await waitUntil {
            engine.stopCallCount == 1
                && engine.startCalls.count == 2
                && model.lifecycleState == .running
        }

        #expect(engine.events == ["start:\(output.uid)", "stop", "start:\(output.uid)"])
        #expect(model.lifecycleState == .running)
    }

    @Test
    func staleAsyncStartCompletionDoesNotReplaceNewerRouteSwitch() async {
        let firstOutput = makeOutput(uid: "first-output", name: "First Output", id: 200)
        let secondOutput = makeOutput(uid: "second-output", name: "Second Output", id: 300)
        let engine = FakeAudioEngine()
        engine.blockStart(for: firstOutput.uid)
        let lookup = FakeDefaultOutputLookup(.success(firstOutput))
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
            engine: engine,
            lookup: lookup,
            observers: observers,
            outputDelay: .zero
        )

        model.start()
        let observer = observers.observers[0]
        observer.emit(.success(firstOutput))
        await waitUntil {
            engine.startCalls.count == 1
        }
        #expect(engine.waitUntilStartIsBlocked(for: firstOutput.uid, timeout: .now() + 1))

        lookup.result = .success(secondOutput)
        observer.emit(.success(secondOutput))
        engine.unblockStart(for: firstOutput.uid)
        await waitUntil {
            model.lifecycleState == .running
                && model.currentOutputUID == secondOutput.uid
                && engine.state == .running(output: secondOutput)
                && model.statusMessage == localized(
                    "Processing \(secondOutput.name) with \(model.activeProfile.name)"
                )
        }

        #expect(model.currentOutputUID == secondOutput.uid)
        #expect(model.currentOutputName == secondOutput.name)
        #expect(model.statusMessage == localized("Processing \(secondOutput.name) with \(model.activeProfile.name)"))
        #expect(engine.stopCallCount == 0)

        try? await Task.sleep(for: .milliseconds(120))
        #expect(engine.state == .running(output: secondOutput))
    }

    @Test
    func userStopDuringSlowStartCleansUpAfterCancelledStartFinishes() async {
        let output = makeOutput(uid: "slow-start-output", name: "Slow Start Output", id: 200)
        let engine = FakeAudioEngine()
        engine.blockStart(for: output.uid)
        let lookup = FakeDefaultOutputLookup(.success(output))
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
            engine: engine,
            lookup: lookup,
            observers: observers,
            outputDelay: .zero
        )

        model.start()
        observers.observers[0].emit(.success(output))
        await waitUntil {
            engine.startCalls.count == 1
        }
        #expect(engine.waitUntilStartIsBlocked(for: output.uid, timeout: .now() + 1))

        model.stop()
        engine.unblockStart(for: output.uid)

        await waitUntil {
            engine.stopCallCount == 2
        }

        #expect(engine.stopCallCount == 2)
        #expect(engine.state == .stopped)
        #expect(!model.isRunning)
        #expect(model.lifecycleState == .stopped)
    }

    @Test
    func staleObserverCallbackAfterStopAndRestartIsIgnored() async {
        let staleOutput = makeOutput(uid: "stale-output", name: "Stale Output")
        let liveOutput = makeOutput(uid: "live-output", name: "Live Output")
        let engine = FakeAudioEngine()
        let lookup = FakeDefaultOutputLookup(.success(liveOutput))
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
            engine: engine,
            lookup: lookup,
            observers: observers,
            outputDelay: .zero
        )

        model.start()
        let firstObserver = observers.observers[0]
        model.stop()
        model.start()
        let secondObserver = observers.observers[1]

        firstObserver.emit(.success(staleOutput))
        await settleAsyncWork()

        #expect(engine.startCalls.isEmpty)
        #expect(lookup.defaultOutputCalls == 0)

        secondObserver.emit(.success(liveOutput))
        await waitUntil {
            engine.startCalls.map(\.output) == [liveOutput]
                && model.currentOutputUID == liveOutput.uid
                && model.lifecycleState == .running
        }

        #expect(engine.startCalls.map(\.output) == [liveOutput])
        #expect(model.currentOutputUID == liveOutput.uid)
        #expect(model.lifecycleState == .running)
    }

    @Test
    func pendingDebounceIsCancelledByStop() async {
        let output = makeOutput(uid: "delayed-output", name: "Delayed Output")
        let engine = FakeAudioEngine()
        let lookup = FakeDefaultOutputLookup(.success(output))
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
            engine: engine,
            lookup: lookup,
            observers: observers,
            outputDelay: .milliseconds(80)
        )

        model.start()
        observers.observers[0].emit(.success(output))
        model.stop()
        try? await Task.sleep(for: .milliseconds(120))

        #expect(engine.startCalls.isEmpty)
        #expect(lookup.defaultOutputCalls == 0)
        #expect(model.lifecycleState == .stopped)
    }

    @Test
    func staleDeletedProfileCannotBePreviewed() {
        let running = makeProfile(name: "Preview Current")
        let stale = makeProfile(name: "Preview Deleted")
        let store = ProfileStore(profiles: [running], fallbackProfileID: running.id)
        let engine = FakeAudioEngine()
        let model = makeModel(store: store, engine: engine)

        model.preview(profile: stale)

        #expect(model.activeProfile == running)
        #expect(model.profileStore == store)
        #expect(model.previewReturnProfile == nil)
        #expect(engine.updateDSPCalls.isEmpty)
        #expect(model.statusMessage.contains("no longer exists"))
    }

    @Test
    func sleepClearsPreviewAndWakeCreatesFreshObserverGeneration() async {
        let output = makeOutput(uid: "wake-output", name: "Wake Output")
        let fallback = makeProfile(name: "Fallback")
        let preview = makeProfile(name: "Preview")
        let store = ProfileStore(profiles: [fallback, preview], fallbackProfileID: fallback.id)
        let engine = FakeAudioEngine()
        let lookup = FakeDefaultOutputLookup(.success(output))
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
            store: store,
            engine: engine,
            lookup: lookup,
            observers: observers,
            outputDelay: .zero,
            wakeDelay: .zero
        )

        model.retryAudioEngine()
        await waitUntil {
            model.lifecycleState == .running && engine.startCalls.count == 1
        }
        model.preview(profile: preview)
        model.start()
        let preSleepObserver = observers.observers[0]

        model.handleWillSleep()
        #expect(model.previewReturnProfile == nil)
        #expect(model.lifecycleState == .sleeping)

        model.handleDidWake()
        await waitUntil {
            observers.observers.count == 2
        }
        #expect(model.lifecycleState == .waking)
        #expect(observers.observers.count == 2)

        preSleepObserver.emit(.success(output))
        await settleAsyncWork()
        #expect(engine.startCalls.count == 1)

        observers.observers[1].emit(.success(output))
        await waitUntil {
            engine.startCalls.count == 2 && model.lifecycleState == .running
        }
        #expect(engine.startCalls.count == 2)
        #expect(model.lifecycleState == .running)
    }

    @Test
    func wakeReconnectRetriesAfterTransientOutputFailure() async {
        let output = makeOutput(uid: "wake-retry-output", name: "Wake Retry Output")
        let engine = FakeAudioEngine()
        let lookup = FakeDefaultOutputLookup(.success(output))
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
            engine: engine,
            lookup: lookup,
            observers: observers,
            outputDelay: .zero,
            wakeDelay: .zero
        )

        model.retryAudioEngine()
        await waitUntil {
            model.lifecycleState == .running && engine.startCalls.count == 1
        }
        model.start()
        model.handleWillSleep()
        model.handleDidWake()
        await waitUntil {
            observers.observers.count == 2 && observers.observers[1].startCalls.count == 1
        }

        let wakeObserver = observers.observers[1]
        lookup.result = .failure(TestAudioError.defaultOutputUnavailable)
        wakeObserver.emit(.failure(TestAudioError.defaultOutputUnavailable))
        await waitUntil {
            wakeObserver.startCalls.count == 2 && model.lifecycleState == .waking
        }
        lookup.result = .success(output)
        wakeObserver.emit(.success(output))
        await waitUntil {
            model.lifecycleState == .running && engine.startCalls.count == 2
        }

        #expect(model.lifecycleState == .running)
        #expect(model.isRunning)
        #expect(engine.startCalls.map(\.output) == [output, output])
    }

    @Test
    func sessionActivationRecoversSleepingStateWhenDidWakeIsMissed() async {
        let output = makeOutput(uid: "missed-wake-output", name: "Missed Wake Output")
        let engine = FakeAudioEngine()
        let lookup = FakeDefaultOutputLookup(.success(output))
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
            engine: engine,
            lookup: lookup,
            observers: observers,
            outputDelay: .zero,
            wakeDelay: .zero
        )

        model.start()
        observers.observers[0].emit(.success(output))
        await waitUntil {
            model.lifecycleState == .running && engine.startCalls.count == 1
        }

        model.handleWillSleep()
        #expect(model.lifecycleState == .sleeping)

        model.handleSessionDidBecomeActive()
        await waitUntil {
            observers.observers.count == 2 && observers.observers[1].startCalls == [true]
        }

        observers.observers[1].emit(.success(output))
        await waitUntil {
            model.lifecycleState == .running && engine.startCalls.count == 2
        }

        #expect(model.isRunning)
        #expect(model.statusMessage == localized("Processing \(output.name) with \(model.activeProfile.name)"))
    }

    @Test
    func sessionActivationDuringPendingSleepReconnectDoesNotResetRetryBudget() async {
        let output = makeOutput(uid: "late-session-wake-output", name: "Late Session Wake Output")
        let engine = FakeAudioEngine()
        let lookup = FakeDefaultOutputLookup(.success(output))
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
            engine: engine,
            lookup: lookup,
            observers: observers,
            outputDelay: .zero,
            wakeDelay: .zero
        )

        model.start()
        observers.observers[0].emit(.success(output))
        await waitUntil {
            model.lifecycleState == .running && engine.startCalls.count == 1
        }

        model.handleWillSleep()
        model.handleDidWake()
        await waitUntil {
            observers.observers.count == 2 && observers.observers[1].startCalls == [true]
        }

        model.handleSessionDidBecomeActive()
        await settleAsyncWork()
        #expect(observers.observers[1].startCalls == [true])

        observers.observers[1].emit(.success(output))
        await waitUntil {
            model.lifecycleState == .running && engine.startCalls.count == 2
        }

        #expect(model.isRunning)
        #expect(model.statusMessage == localized("Processing \(output.name) with \(model.activeProfile.name)"))
    }

    @Test
    func repeatedSleepWakeCyclesCreateFreshObserversAndReconnect() async {
        let output = makeOutput(uid: "repeated-wake-output", name: "Repeated Wake Output")
        let engine = FakeAudioEngine()
        let lookup = FakeDefaultOutputLookup(.success(output))
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
            engine: engine,
            lookup: lookup,
            observers: observers,
            outputDelay: .zero,
            wakeDelay: .zero
        )

        model.start()
        observers.observers[0].emit(.success(output))
        await waitUntil {
            model.lifecycleState == .running && engine.startCalls.count == 1
        }

        model.handleWillSleep()
        model.handleDidWake()
        await waitUntil {
            observers.observers.count == 2 && observers.observers[1].startCalls == [true]
        }
        observers.observers[1].emit(.success(output))
        await waitUntil {
            model.lifecycleState == .running && engine.startCalls.count == 2
        }

        model.handleWillSleep()
        model.handleDidWake()
        await waitUntil {
            observers.observers.count == 3 && observers.observers[2].startCalls == [true]
        }
        observers.observers[1].emit(.success(output))
        await settleAsyncWork()
        #expect(engine.startCalls.count == 2)

        observers.observers[2].emit(.success(output))
        await waitUntil {
            model.lifecycleState == .running && engine.startCalls.count == 3
        }

        #expect(observers.observers[0].stopCallCount == 1)
        #expect(observers.observers[1].stopCallCount == 1)
        #expect(model.isRunning)
        #expect(model.statusMessage == localized("Processing \(output.name) with \(model.activeProfile.name)"))
    }

    @Test
    func sleepDuringPendingWakeReconnectPreservesResumeIntent() async {
        let output = makeOutput(uid: "nested-sleep-output", name: "Nested Sleep Output")
        let engine = FakeAudioEngine()
        let lookup = FakeDefaultOutputLookup(.success(output))
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
            engine: engine,
            lookup: lookup,
            observers: observers,
            outputDelay: .zero,
            wakeDelay: .zero
        )

        model.start()
        observers.observers[0].emit(.success(output))
        await waitUntil {
            model.lifecycleState == .running && engine.startCalls.count == 1
        }

        model.handleWillSleep()
        model.handleDidWake()
        await waitUntil {
            observers.observers.count == 2 && observers.observers[1].startCalls == [true]
        }

        model.handleWillSleep()
        model.handleDidWake()
        await waitUntil {
            observers.observers.count == 3 && observers.observers[2].startCalls == [true]
        }

        observers.observers[2].emit(.success(output))
        await waitUntil {
            model.lifecycleState == .running && engine.startCalls.count == 2
        }

        #expect(model.isRunning)
        #expect(model.statusMessage == localized("Processing \(output.name) with \(model.activeProfile.name)"))
    }

    @Test
    func wakeAfterStoppedSleepClearsPausedStatus() {
        let model = makeModel()

        model.handleWillSleep()
        #expect(model.lifecycleState == .sleeping)
        #expect(model.statusMessage == localized("Paused for system sleep"))

        model.handleDidWake()

        #expect(model.lifecycleState == .stopped)
        #expect(!model.isRunning)
        #expect(model.statusMessage == localized("Stopped"))
    }

    @Test
    func sessionActivationDoesNotRebuildRunningOutputWithoutSleepIntent() async {
        let output = makeOutput(uid: "unlock-output", name: "Unlock Output")
        let engine = FakeAudioEngine()
        let lookup = FakeDefaultOutputLookup(.success(output))
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
            engine: engine,
            lookup: lookup,
            observers: observers,
            outputDelay: .zero,
            wakeDelay: .zero
        )

        model.start()
        let observer = observers.observers[0]
        observer.emit(.success(output))
        await waitUntil {
            model.lifecycleState == .running && engine.startCalls.count == 1
        }
        let lookupCallsBeforeActivation = lookup.defaultOutputCalls

        model.handleSessionDidBecomeActive()
        await settleAsyncWork()

        #expect(engine.muteOutputCallCount == 0)
        #expect(model.lifecycleState == .running)
        #expect(observer.startCalls == [true])
        #expect(observers.observers.count == 1)
        #expect(engine.startCalls.map(\.output) == [output])
        #expect(lookup.defaultOutputCalls == lookupCallsBeforeActivation)
        #expect(model.isRunning)
    }

    @Test
    func wakingProfileActionsUpdateStateWithoutDirectEngineMutation() async throws {
        let output = makeOutput(uid: "waking-profile-output", name: "Waking Profile Output")
        let fallback = makeProfile(name: "Fallback")
        let applied = makeProfile(name: "Applied During Wake")
        let mapped = makeProfile(name: "Mapped During Wake")
        let store = ProfileStore(
            profiles: [fallback, applied, mapped],
            fallbackProfileID: fallback.id
        )
        let engine = FakeAudioEngine()
        let lookup = FakeDefaultOutputLookup(.success(output))
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
            store: store,
            engine: engine,
            lookup: lookup,
            observers: observers,
            outputDelay: .zero,
            wakeDelay: .zero
        )

        model.start()
        observers.observers[0].emit(.success(output))
        await waitUntil {
            model.lifecycleState == .running && engine.startCalls.count == 1
        }

        engine.blockStart(for: output.uid)
        model.handleWillSleep()
        model.handleDidWake()
        await waitUntil {
            observers.observers.count == 2 && observers.observers[1].startCalls == [true]
        }
        observers.observers[1].emit(.success(output))
        await waitUntil {
            model.lifecycleState == .waking && engine.startCalls.count == 2
        }
        #expect(engine.waitUntilStartIsBlocked(for: output.uid, timeout: .now() + 1))

        try model.apply(profile: applied)
        try model.useForCurrentOutput(profile: mapped)
        model.setBypass(true)

        #expect(model.lifecycleState == .stopped)
        #expect(model.activeProfile.id == mapped.id)
        #expect(model.activeProfile.isBypassed)
        #expect(model.previewReturnProfile == nil)
        #expect(engine.updateCalls.isEmpty)
        #expect(engine.updateDSPCalls.isEmpty)
        #expect(model.profileStore.profile(forOutputUID: output.uid).id == mapped.id)

        engine.unblockStart(for: output.uid)
        await waitUntil {
            engine.stopCallCount == 1
        }

        #expect(!model.isRunning)
        #expect(model.lifecycleState == .stopped)
        #expect(model.statusMessage == localized("Audio processing disabled for \(output.name)"))
    }

    @Test
    func userStoppedEngineBeforeSleepDoesNotReconnectOnWake() async {
        let output = makeOutput(uid: "stopped-before-sleep-output", name: "Stopped Before Sleep Output")
        let engine = FakeAudioEngine()
        let lookup = FakeDefaultOutputLookup(.success(output))
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
            engine: engine,
            lookup: lookup,
            observers: observers,
            outputDelay: .zero,
            wakeDelay: .zero
        )

        model.start()
        let observer = observers.observers[0]
        observer.emit(.success(output))
        await waitUntil {
            model.lifecycleState == .running && engine.startCalls.count == 1
        }

        model.stop()
        model.handleWillSleep()
        model.handleDidWake()
        await settleAsyncWork()

        #expect(engine.startCalls.map(\.output) == [output])
        #expect(observers.observers.count == 1)
        #expect(observer.stopCallCount == 1)
        #expect(!model.isRunning)
        #expect(model.lifecycleState == .stopped)
        #expect(model.statusMessage == localized("Stopped"))
    }

    @Test
    func cleanupForTerminationIsTerminal() async {
        let output = makeOutput(uid: "terminal-output", name: "Terminal Output")
        let engine = FakeAudioEngine()
        let lookup = FakeDefaultOutputLookup(.success(output))
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
            engine: engine,
            lookup: lookup,
            observers: observers,
            outputDelay: .zero
        )

        model.start()
        let observer = observers.observers[0]
        model.cleanupForTermination()
        model.start()
        model.retryAudioEngine()
        observer.emit(.success(output))
        await settleAsyncWork()

        #expect(model.lifecycleState == .terminating)
        #expect(!model.isRunning)
        #expect(engine.startCalls.isEmpty)
        #expect(lookup.defaultOutputCalls == 0)
    }

    @Test
    func settingsCreateProfileCommandReturnsUpdatedSnapshot() async throws {
        let model = makeModel()
        let initialCount = model.profileStore.profiles.count

        let response = try await model.performSettingsCommand(.createProfile(.parametric))

        let snapshot = try #require(response.snapshot)
        #expect(snapshot.profiles.count == initialCount + 1)
        #expect(snapshot.draftProfile.mode == .parametric)
        #expect(snapshot.selectedProfileID == snapshot.draftProfile.id)
    }

    @Test
    func settingsApplyProfileCommandRejectsInvalidProfile() async throws {
        let model = makeModel()
        var invalid = model.activeProfile
        invalid.name = "   "

        await #expect(throws: ProfileStoreValidationError.self) {
            _ = try await model.performSettingsCommand(.applyProfile(invalid))
        }
    }

    @Test
    func settingsApplyProfileRejectsDisabledFilterOverloadWithoutMutation() async throws {
        let model = makeModel()
        let initialStore = model.profileStore
        let initialActiveProfile = model.activeProfile
        var overloaded = model.activeProfile
        overloaded.filters = (0...ProfilePersistence.maxFiltersPerChannel).map {
            EQFilter(kind: .peak, frequency: Double($0 + 1), gainDB: 0, q: 1, isEnabled: false)
        }

        await #expect(throws: ProfileStoreValidationError.tooManyFilters(
            profileID: overloaded.id,
            channel: "linked",
            count: ProfilePersistence.maxFiltersPerChannel + 1,
            maximum: ProfilePersistence.maxFiltersPerChannel
        )) {
            _ = try await model.performSettingsCommand(.applyProfile(overloaded))
        }

        #expect(model.profileStore == initialStore)
        #expect(model.activeProfile == initialActiveProfile)
    }

    @Test
    func settingsCreateProfileAtLimitThrowsWithoutMutation() async throws {
        let store = makeStore(profileCount: ProfilePersistence.profileCountRange.upperBound)
        let model = makeModel(store: store)
        let initialSelection = model.selectedProfileID

        await #expect(throws: ProfileStoreValidationError.invalidProfileCount(
            count: ProfilePersistence.profileCountRange.upperBound + 1,
            allowed: ProfilePersistence.profileCountRange
        )) {
            _ = try await model.performSettingsCommand(.createProfile(.parametric))
        }

        #expect(model.profileStore == store)
        #expect(model.selectedProfileID == initialSelection)
    }

    @Test
    func settingsDuplicateUsesExplicitProfileID() async throws {
        let first = makeProfile(name: "First")
        let second = makeProfile(name: "Second")
        let store = ProfileStore(profiles: [first, second], fallbackProfileID: first.id)
        let model = makeModel(store: store)
        model.selectProfile(first.id)

        let response = try await model.performSettingsCommand(.duplicateProfile(second.id))

        let snapshot = try #require(response.snapshot)
        #expect(snapshot.profiles.count == 3)
        #expect(snapshot.draftProfile.name == "Second Copy")
        #expect(snapshot.draftProfile.id != second.id)
        #expect(snapshot.selectedProfileID == snapshot.draftProfile.id)
    }

    @Test
    func settingsDuplicateStaleIDThrowsWithoutDuplicatingSelectedProfile() async throws {
        let model = makeModel()
        let initialStore = model.profileStore

        await #expect(throws: SettingsCommandFailure.self) {
            _ = try await model.performSettingsCommand(.duplicateProfile(UUID()))
        }

        #expect(model.profileStore == initialStore)
    }

    @Test
    func bypassAfterSelectingDifferentDraftOnlyTogglesActiveProfileAndStopsEngine() async {
        let active = makeProfile(name: "Active")
        let draft = makeProfile(name: "Draft")
        let output = makeOutput(uid: "bypass-output", name: "Bypass Output")
        let store = ProfileStore(profiles: [active, draft], fallbackProfileID: active.id)
        let engine = FakeAudioEngine()
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(store: store, engine: engine, observers: observers, outputDelay: .zero)

        model.start()
        observers.observers[0].emit(.success(output))
        await waitUntil {
            model.lifecycleState == .running && engine.startCalls.count == 1
        }
        model.selectProfile(draft.id)

        model.setBypass(true)
        await waitUntil {
            engine.stopCallCount == 1
        }

        #expect(model.activeProfile.id == active.id)
        #expect(model.activeProfile.isBypassed)
        #expect(model.selectedProfileID == draft.id)
        #expect(model.draftProfile.id == draft.id)
        #expect(!model.draftProfile.isBypassed)
        #expect(model.profileStore.profiles.first { $0.id == active.id }?.isBypassed == true)
        #expect(model.profileStore.profiles.first { $0.id == draft.id }?.isBypassed == false)
        #expect(engine.updateDSPCalls.isEmpty)
        #expect(engine.stopCallCount == 1)
        #expect(!model.isRunning)
        #expect(model.lifecycleState == .stopped)
    }

    @Test
    func bypassMirrorsDraftWhenSelectedProfileIsActiveProfileAndStopsEngine() async {
        let active = makeProfile(name: "Active")
        let output = makeOutput(uid: "active-bypass-output", name: "Active Bypass Output")
        let store = ProfileStore(profiles: [active], fallbackProfileID: active.id)
        let engine = FakeAudioEngine()
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(store: store, engine: engine, observers: observers, outputDelay: .zero)

        model.start()
        observers.observers[0].emit(.success(output))
        await waitUntil {
            model.lifecycleState == .running && engine.startCalls.count == 1
        }

        model.setBypass(true)
        await waitUntil {
            engine.stopCallCount == 1
        }

        #expect(model.activeProfile.id == active.id)
        #expect(model.activeProfile.isBypassed)
        #expect(model.draftProfile.id == active.id)
        #expect(model.draftProfile.isBypassed)
        #expect(model.profileStore.profiles.first { $0.id == active.id }?.isBypassed == true)
        #expect(engine.updateDSPCalls.isEmpty)
        #expect(engine.stopCallCount == 1)
        #expect(!model.isRunning)
        #expect(model.lifecycleState == .stopped)
    }

    @Test
    func unsupportedSchemaStoreIsProtectedUntilExplicitReset() async throws {
        let storeURL = temporaryAppStoreURL()
        defer { removeTemporaryStoreDirectory(for: storeURL) }
        let futureProfile = makeProfile(name: "Future Profile")
        let futureStore = ProfileStore(
            schemaVersion: ProfileStore.currentSchemaVersion + 1,
            profiles: [futureProfile],
            fallbackProfileID: futureProfile.id
        )
        let futureData = try ProfilePersistence.encoder.encode(futureStore)
        try FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try futureData.write(to: storeURL)

        let model = GlassEQAppModel(
            storeURL: storeURL,
            engine: FakeAudioEngine(),
            defaultOutputLookup: FakeDefaultOutputLookup(.success(makeOutput())),
            observerFactory: FakeDefaultOutputObserverFactory(),
            autoStart: false,
            installLifecycleObservers: false,
            registerAppDelegate: false
        )

        #expect(model.settingsSnapshot().profileStoreProtection.isProtected)
        #expect(model.profileStore.profiles == ProfileStore.defaultProfiles)
        #expect(await model.flushStoreBeforeQuit())
        #expect(try Data(contentsOf: storeURL) == futureData)

        await #expect(throws: SettingsCommandFailure.self) {
            _ = try await model.performSettingsCommand(.createProfile(.parametric))
        }
        await #expect(throws: SettingsCommandFailure.self) {
            _ = try await model.performSettingsCommand(.applyProfile(model.activeProfile))
        }
        #expect(try Data(contentsOf: storeURL) == futureData)

        let response = try await model.performSettingsCommand(.resetUnsupportedProfileStore)
        let snapshot = try #require(response.snapshot)
        #expect(!snapshot.profileStoreProtection.isProtected)
        #expect(try ProfilePersistence.decode(Data(contentsOf: storeURL)).profiles == ProfileStore.defaultProfiles)

        let backups = try FileManager.default.contentsOfDirectory(
            at: storeURL.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        )
            .filter { $0.lastPathComponent.hasPrefix("Profiles.invalid-") }
        #expect(backups.count == 1)
        if let backup = backups.first {
            #expect(try Data(contentsOf: backup) == futureData)
        }

        _ = try await model.performSettingsCommand(.createProfile(.parametric))
        #expect(model.profileStore.profiles.count == ProfileStore.defaultProfiles.count + 1)
    }

    @Test
    func preservedRunningProfileUpdateFailureRevertsModelToRunningProfile() async throws {
        let running = makeProfile(name: "Running")
        let requested = makeProfile(name: "Requested")
        let output = makeOutput(uid: "preserved-output", name: "Preserved Output")
        let store = ProfileStore(profiles: [running, requested], fallbackProfileID: running.id)
        let engine = FakeAudioEngine()
        let observers = FakeDefaultOutputObserverFactory()
        let lookup = FakeDefaultOutputLookup(.success(output))
        let model = makeModel(
            store: store,
            engine: engine,
            lookup: lookup,
            observers: observers,
            outputDelay: .zero
        )

        model.start()
        observers.observers[0].emit(.success(output))
        await waitUntil {
            model.lifecycleState == .running && engine.startCalls.count == 1
        }
        engine.updateDSPResult = false
        engine.updateError = TestAudioError.updateFailed
        engine.updateErrorPreservesRunningState = true

        try model.apply(profile: requested)

        await waitUntil {
            engine.updateCalls.count == 1 && model.statusMessage.contains("not applied")
        }

        #expect(model.lifecycleState == .running)
        #expect(model.isRunning)
        #expect(model.currentOutputUID == output.uid)
        #expect(model.activeProfile == running)
        #expect(model.selectedProfileID == running.id)
        #expect(model.draftProfile == running)
        #expect(model.profileStore == store)
        #expect(engine.state == .running(output: output))
    }

    @Test
    func failedCurrentOutputProfileChangeRestoresOnlyItsMapping() async throws {
        let running = makeProfile(name: "Mapped Running")
        let requested = makeProfile(name: "Mapped Requested")
        let unrelated = makeProfile(name: "Unrelated")
        let output = makeOutput(uid: "mapping-failure-output", name: "Mapping Failure Output")
        let unrelatedOutputUID = "unrelated-output"
        let store = ProfileStore(
            profiles: [running, requested, unrelated],
            outputMappings: [
                OutputDeviceProfileMapping(outputDeviceUID: output.uid, profileID: running.id),
                OutputDeviceProfileMapping(outputDeviceUID: unrelatedOutputUID, profileID: unrelated.id),
            ],
            fallbackProfileID: running.id
        )
        let engine = FakeAudioEngine()
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
            store: store,
            engine: engine,
            lookup: FakeDefaultOutputLookup(.success(output)),
            observers: observers,
            outputDelay: .zero
        )

        model.start()
        observers.observers[0].emit(.success(output))
        await waitUntil {
            model.lifecycleState == .running && engine.startCalls.count == 1
        }
        engine.updateDSPResult = false
        engine.updateError = TestAudioError.updateFailed
        engine.updateErrorPreservesRunningState = true

        try model.useForCurrentOutput(profile: requested)

        await waitUntil {
            engine.updateCalls.count == 1 && model.statusMessage.contains("not applied")
        }

        #expect(model.activeProfile == running)
        #expect(model.profileStore.outputMappings == store.outputMappings)
        #expect(model.profileStore.profiles.contains(requested))
        #expect(engine.state == .running(output: output))
    }

    @Test
    func confirmedRunningProfileCannotBeDeletedDuringPendingSwitch() async throws {
        let running = makeProfile(name: "Delete Guard Running")
        let requested = makeProfile(name: "Delete Guard Requested")
        let output = makeOutput(uid: "delete-guard-output", name: "Delete Guard Output")
        let store = ProfileStore(
            profiles: [running, requested],
            outputMappings: [OutputDeviceProfileMapping(
                outputDeviceUID: output.uid,
                profileID: running.id
            )],
            fallbackProfileID: running.id
        )
        let engine = FakeAudioEngine()
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
            store: store,
            engine: engine,
            lookup: FakeDefaultOutputLookup(.success(output)),
            observers: observers,
            outputDelay: .zero
        )

        model.start()
        observers.observers[0].emit(.success(output))
        await waitUntil {
            model.lifecycleState == .running && engine.startCalls.count == 1
        }
        engine.updateDSPResult = false
        engine.updateError = TestAudioError.updateFailed
        engine.updateErrorPreservesRunningState = true
        engine.blockUpdate(for: requested.id)

        try model.useForCurrentOutput(profile: requested)
        await waitUntil { engine.updateCalls.count == 1 }
        #expect(engine.waitUntilUpdateIsBlocked(for: requested.id, timeout: .now() + 1))

        #expect(throws: SettingsCommandFailure.self) {
            try model.deleteProfile(id: running.id)
        }
        engine.unblockUpdate(for: requested.id)
        await waitUntil { model.statusMessage.contains("not applied") }

        #expect(model.activeProfile == running)
        #expect(model.profileStore == store)
        #expect(engine.state == .running(output: output))
    }

    @Test
    func failedProfileChangeDoesNotRestoreADeletedSelection() async throws {
        let running = makeProfile(name: "Selection Running")
        let deleted = makeProfile(name: "Selection Deleted")
        let requested = makeProfile(name: "Selection Requested")
        let output = makeOutput(uid: "selection-delete-output", name: "Selection Delete Output")
        let store = ProfileStore(
            profiles: [running, deleted, requested],
            fallbackProfileID: running.id
        )
        let engine = FakeAudioEngine()
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
            store: store,
            engine: engine,
            lookup: FakeDefaultOutputLookup(.success(output)),
            observers: observers,
            outputDelay: .zero
        )

        model.start()
        observers.observers[0].emit(.success(output))
        await waitUntil {
            model.lifecycleState == .running && engine.startCalls.count == 1
        }
        model.selectProfile(deleted.id)
        engine.updateDSPResult = false
        engine.updateError = TestAudioError.updateFailed
        engine.updateErrorPreservesRunningState = true
        engine.blockUpdate(for: requested.id)

        try model.apply(profile: requested)
        await waitUntil { engine.updateCalls.count == 1 }
        #expect(engine.waitUntilUpdateIsBlocked(for: requested.id, timeout: .now() + 1))
        try model.deleteProfile(id: deleted.id)
        engine.unblockUpdate(for: requested.id)
        await waitUntil { model.statusMessage.contains("not applied") }

        #expect(model.activeProfile == running)
        #expect(model.selectedProfileID == running.id)
        #expect(model.draftProfile == running)
        #expect(!model.profileStore.profiles.contains(where: { $0.id == deleted.id }))
        #expect(engine.state == .running(output: output))
    }

    @Test
    func failedCurrentOutputChangeDoesNotRestoreMappingToDeletedProfile() async throws {
        let mapped = makeProfile(name: "Deleted Mapping")
        let running = makeProfile(name: "Mapping Confirmed")
        let requested = makeProfile(name: "Mapping Requested")
        let output = makeOutput(uid: "deleted-mapping-output", name: "Deleted Mapping Output")
        let store = ProfileStore(
            profiles: [mapped, running, requested],
            outputMappings: [OutputDeviceProfileMapping(
                outputDeviceUID: output.uid,
                profileID: mapped.id
            )],
            fallbackProfileID: running.id
        )
        let engine = FakeAudioEngine()
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
            store: store,
            engine: engine,
            lookup: FakeDefaultOutputLookup(.success(output)),
            observers: observers,
            outputDelay: .zero
        )

        model.start()
        observers.observers[0].emit(.success(output))
        await waitUntil {
            model.lifecycleState == .running && engine.startCalls.count == 1
        }
        try model.apply(profile: running)
        #expect(model.activeProfile == running)

        engine.updateDSPResult = false
        engine.updateError = TestAudioError.updateFailed
        engine.updateErrorPreservesRunningState = true
        engine.blockUpdate(for: requested.id)
        try model.useForCurrentOutput(profile: requested)
        await waitUntil { engine.updateCalls.count == 1 }
        #expect(engine.waitUntilUpdateIsBlocked(for: requested.id, timeout: .now() + 1))

        try model.deleteProfile(id: mapped.id)
        engine.unblockUpdate(for: requested.id)
        await waitUntil { model.statusMessage.contains("not applied") }

        #expect(model.activeProfile == running)
        #expect(model.profileStore.profiles == [running, requested])
        #expect(model.profileStore.outputMappings.isEmpty)
        #expect(model.profileStore.profile(forOutputUID: output.uid) == running)
        #expect(engine.state == .running(output: output))
    }

    @Test
    func failedProfileChangePreservesLaterSavedEditToTheSameProfile() async throws {
        let running = makeProfile(name: "Initially Running")
        var attempted = running
        attempted.name = "Attempted Apply"
        var laterSaved = running
        laterSaved.name = "Saved While Apply Was Pending"
        let output = makeOutput(uid: "later-edit-output", name: "Later Edit Output")
        let store = ProfileStore(profiles: [running], fallbackProfileID: running.id)
        let engine = FakeAudioEngine()
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
            store: store,
            engine: engine,
            lookup: FakeDefaultOutputLookup(.success(output)),
            observers: observers,
            outputDelay: .zero
        )

        model.start()
        observers.observers[0].emit(.success(output))
        await waitUntil {
            model.lifecycleState == .running && engine.startCalls.count == 1
        }
        engine.updateDSPResult = false
        engine.updateError = TestAudioError.updateFailed
        engine.updateErrorPreservesRunningState = true
        engine.blockUpdate(for: attempted.id)

        try model.apply(profile: attempted)
        await waitUntil { engine.updateCalls.count == 1 }
        #expect(engine.waitUntilUpdateIsBlocked(for: attempted.id, timeout: .now() + 1))

        try model.setFallback(profile: laterSaved)
        engine.unblockUpdate(for: attempted.id)

        await waitUntil { model.statusMessage.contains("not applied") }

        #expect(model.activeProfile == running)
        #expect(model.profileStore.profiles == [laterSaved])
        #expect(model.profileStore.fallbackProfileID == laterSaved.id)
        #expect(engine.state == .running(output: output))
    }

    @Test
    func failedNewProfileChangeDoesNotLeaveDanglingFallback() async throws {
        let running = makeProfile(name: "Fallback Running")
        let requested = makeProfile(name: "Fallback Requested")
        let output = makeOutput(uid: "fallback-failure-output", name: "Fallback Failure Output")
        let store = ProfileStore(profiles: [running], fallbackProfileID: running.id)
        let engine = FakeAudioEngine()
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
            store: store,
            engine: engine,
            lookup: FakeDefaultOutputLookup(.success(output)),
            observers: observers,
            outputDelay: .zero
        )

        model.start()
        observers.observers[0].emit(.success(output))
        await waitUntil {
            model.lifecycleState == .running && engine.startCalls.count == 1
        }
        engine.updateDSPResult = false
        engine.updateError = TestAudioError.updateFailed
        engine.updateErrorPreservesRunningState = true
        engine.blockUpdate(for: requested.id)

        try model.apply(profile: requested)
        await waitUntil { engine.updateCalls.count == 1 }
        #expect(engine.waitUntilUpdateIsBlocked(for: requested.id, timeout: .now() + 1))
        try model.setFallback(profile: requested)
        engine.unblockUpdate(for: requested.id)
        await waitUntil { model.statusMessage.contains("not applied") }

        #expect(model.activeProfile == running)
        #expect(model.profileStore == store)
        #expect(engine.state == .running(output: output))
    }

    @Test
    func settingsDeleteStaleAndActiveIDsThrowWithoutMutation() async throws {
        let inactive = makeProfile(name: "Inactive")
        let store = ProfileStore(profiles: [makeProfile(name: "Active"), inactive])
        let model = makeModel(store: store)
        let initialStore = model.profileStore

        await #expect(throws: SettingsCommandFailure.self) {
            _ = try await model.performSettingsCommand(.deleteProfile(UUID()))
        }
        await #expect(throws: SettingsCommandFailure.self) {
            _ = try await model.performSettingsCommand(.deleteProfile(model.activeProfile.id))
        }

        #expect(model.profileStore == initialStore)
    }

    @Test
    func settingsImportAtProfileLimitThrowsWithoutAppending() async throws {
        let store = makeStore(profileCount: ProfilePersistence.profileCountRange.upperBound)
        let model = makeModel(store: store)
        let text = "Filter 1: ON PK Fc 1000 Hz Gain 1 dB Q 1"

        await #expect(throws: ProfileStoreValidationError.invalidProfileCount(
            count: ProfilePersistence.profileCountRange.upperBound + 1,
            allowed: ProfilePersistence.profileCountRange
        )) {
            _ = try await model.performSettingsCommand(.importProfile(format: .autoEQ, name: "Imported", text: text))
        }

        #expect(model.profileStore == store)
    }

    @Test
    func settingsImportsImpulseResponseProfileWithoutChangingActiveAudio() async throws {
        let model = makeModel()
        let activeProfile = model.activeProfile
        let initialProfileCount = model.profileStore.profiles.count
        let imported = EQProfile(
            name: "Room IR",
            mode: .convolution,
            filters: [],
            convolution: .impulseResponse(ImpulseResponseSource(
                sampleRate: 48_000,
                samples: [1, 0.25, -0.125]
            ))
        )

        let response = try await model.performSettingsCommand(
            .importParsedProfile(imported)
        )

        #expect(response.importSucceeded == true)
        #expect(model.activeProfile == activeProfile)
        #expect(model.profileStore.profiles.count == initialProfileCount + 1)
        #expect(model.draftProfile.name == "Room IR")
        guard case .impulseResponse(let source) = model.draftProfile.convolution else {
            Issue.record("Expected imported impulse response")
            return
        }
        #expect(source.samples == [1, 0.25, -0.125])
    }

    @Test
    func metricsPollingCommandReturnsNoSnapshotAndPublishesImmediateMetrics() async throws {
        let engine = FakeAudioEngine()
        engine.metrics = AudioEngineMetrics(
            capturedFrames: 123,
            playedFrames: 100,
            droppedInputFrames: 2
        )
        let model = makeModel(engine: engine)

        let response = try await model.performSettingsCommand(.startMetricsPolling)

        #expect(response.snapshot == nil)
        #expect(model.engineMetrics.capturedFrames == 123)
        #expect(model.engineMetrics.playedFrames == 100)
        #expect(model.engineMetrics.droppedInputFrames == 2)
        #expect(model.settingsSnapshot().metrics.droppedInputFrames == 2)
        model.stopMetricsPolling()
    }

    @Test
    func openPrivacySettingsReportsFailureWhenSystemSettingsCannotOpen() async throws {
        let opener = FakeWorkspaceOpener(results: [false, false])
        let model = makeModel(workspaceOpener: opener)

        await #expect(throws: SettingsCommandFailure.self) {
            _ = try await model.performSettingsCommand(.openPrivacySettings)
        }

        #expect(opener.openedURLs.count == 2)
    }

    @Test
    func openPrivacySettingsAllowsFallbackURLSuccess() async throws {
        let opener = FakeWorkspaceOpener(results: [false, true])
        let model = makeModel(workspaceOpener: opener)

        _ = try await model.performSettingsCommand(.openPrivacySettings)

        #expect(opener.openedURLs.count == 2)
    }

    @Test
    func debouncedProfileSavesCoalesceAndFlushPersistsLatestState() async throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlassEQAppTests-\(UUID().uuidString).json")
        let model = makeModel(storeURL: storeURL, saveDelay: .milliseconds(100))

        try model.createProfile(kind: .parametric)
        try model.createProfile(kind: .graphic10)
        try model.createProfile(kind: .convolution)
        try? await Task.sleep(for: .milliseconds(20))

        #expect(!FileManager.default.fileExists(atPath: storeURL.path))
        #expect(await model.flushStoreBeforeQuit())

        let loaded = ProfilePersistence.load(from: storeURL).store
        #expect(loaded.profiles.count == 4)
        #expect(loaded.profiles.contains { $0.name == "New Parametric" })
        #expect(loaded.profiles.contains { $0.name == "New 10-Band" })
        #expect(loaded.profiles.contains { $0.name == "New Response Curve" })
    }

    @Test
    func quitWaitsForInFlightImportBeforeFlushingProfiles() async throws {
        let storeURL = temporaryAppStoreURL()
        defer { removeTemporaryStoreDirectory(for: storeURL) }
        let importer = BlockingProfileImportOperation()
        let importedProfile = makeProfile(name: "Imported Before Quit")
        let model = makeModel(
            storeURL: storeURL,
            profileImportOperation: { format, name, text in
                await importer.run(format: format, name: name, text: text)
            }
        )

        let importTask = Task {
            try await model.performSettingsCommand(.importProfile(
                format: .autoEQ,
                name: importedProfile.name,
                text: "1 0"
            ))
        }
        await waitUntil {
            importer.hasEntered
        }

        let flushTask = Task {
            await model.stopAcceptingSettingsCommandsAndWait()
            return await model.flushStoreBeforeQuit()
        }
        try await Task.sleep(for: .milliseconds(20))
        #expect(!FileManager.default.fileExists(atPath: storeURL.path))

        importer.complete(with: .success(importedProfile))
        _ = try await importTask.value
        #expect(await flushTask.value)

        let loaded = ProfilePersistence.load(from: storeURL).store
        #expect(loaded.profiles.contains { $0.name == importedProfile.name })
        model.resumeSettingsCommandsAfterCancelledQuit()
    }

    @Test
    func settingsLaunchValidationFailureTerminatesPartiallyStartedHelper() async throws {
        let model = makeModel()
        let launcher = SleepingSettingsHelperLauncher()
        let coordinator = SettingsCoordinator(
            model: model,
            helperLauncher: launcher,
            helperValidator: FailingSettingsHelperLaunchValidator(),
            settingsHelperURLProvider: { URL(fileURLWithPath: "/tmp/GlassEQSettings.app") }
        )

        let disposition = coordinator.openSettings()

        let process = try #require(launcher.launchedProcesses.first)
        defer {
            if process.isRunning {
                process.terminate()
            }
        }
        #expect(!coordinator.hasActiveSessionResourcesForTesting)
        if case .inProcessFallback(let reason) = disposition {
            #expect(reason.contains("Intentional post-launch validation failure"))
        } else {
            Issue.record("Expected in-process Settings fallback")
        }
        for _ in 0..<250 {
            if !process.isRunning {
                break
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(!process.isRunning)
    }

    @Test
    func settingsLaunchPermissionFailureRequestsInProcessFallback() {
        let model = makeModel()
        let coordinator = SettingsCoordinator(
            model: model,
            helperLauncher: PermissionDeniedSettingsHelperLauncher(),
            helperValidator: PermissiveSettingsHelperLaunchValidator(),
            settingsHelperURLProvider: { URL(fileURLWithPath: "/tmp/GlassEQSettings.app") }
        )

        let disposition = coordinator.openSettings()

        #expect(!coordinator.hasActiveSessionResourcesForTesting)
        if case .inProcessFallback(let reason) = disposition {
            #expect(reason.contains("Operation not permitted"))
        } else {
            Issue.record("Expected in-process Settings fallback after EPERM")
        }
    }

    @Test
    func settingsHelperExitBeforeConnectingRequestsInProcessFallback() async throws {
        let model = makeModel()
        let coordinator = SettingsCoordinator(
            model: model,
            helperLauncher: ProcessSettingsHelperLauncher(),
            helperValidator: PermissiveSettingsHelperLaunchValidator(),
            settingsHelperURLProvider: { URL(fileURLWithPath: "/tmp/GlassEQSettings.app") }
        )

        #expect(coordinator.openSettings() == .helper)

        for _ in 0..<100 where model.inProcessSettingsPresentationGeneration == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.inProcessSettingsPresentationGeneration == 1)
        #expect(model.statusMessage.contains("exited before connecting"))
        #expect(!coordinator.hasActiveSessionResourcesForTesting)
    }

    @Test
    func settingsHelperExitAfterConnectBeforeReadyRequestsInProcessFallback() async throws {
        let model = makeModel()
        let launcher = ControllableSettingsHelperLauncher()
        let coordinator = SettingsCoordinator(
            model: model,
            helperLauncher: launcher,
            helperValidator: PermissiveSettingsHelperLaunchValidator(),
            settingsHelperURLProvider: { URL(fileURLWithPath: "/tmp/GlassEQSettings.app") }
        )

        #expect(coordinator.openSettings() == .helper)
        await waitUntil {
            launcher.receivedAppMessages.contains { message in
                if case .bootstrap = message {
                    return true
                }
                return false
            }
        }
        let bootstrap = try #require(launcher.receivedAppMessages.first)
        guard case .bootstrap(let token) = bootstrap else {
            Issue.record("Expected Settings bootstrap message")
            return
        }
        try launcher.writeHelperOutput(try SettingsPipeCodec.encodeLine(
            .request(sessionToken: token, id: "connect", kind: .connect, command: nil)
        ))
        try launcher.closeHelperOutput()

        for _ in 0..<100 where model.inProcessSettingsPresentationGeneration == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.inProcessSettingsPresentationGeneration == 1)
        #expect(model.statusMessage.contains("exited before connecting"))
        #expect(!coordinator.hasActiveSessionResourcesForTesting)
    }

    @Test
    func malformedSettingsIPCBeforeConnectingRequestsInProcessFallback() async throws {
        let model = makeModel()
        let launcher = ControllableSettingsHelperLauncher()
        let coordinator = SettingsCoordinator(
            model: model,
            helperLauncher: launcher,
            helperValidator: PermissiveSettingsHelperLaunchValidator(),
            settingsHelperURLProvider: { URL(fileURLWithPath: "/tmp/GlassEQSettings.app") }
        )

        #expect(coordinator.openSettings() == .helper)
        try launcher.writeHelperOutput(Data("not-json\n".utf8))

        for _ in 0..<100 where model.inProcessSettingsPresentationGeneration == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.inProcessSettingsPresentationGeneration == 1)
        #expect(model.statusMessage.contains("IPC failed before connecting"))
        #expect(!coordinator.hasActiveSessionResourcesForTesting)
    }

    @Test
    func settingsModelNotificationPublishesMetricsOnlyChanges() async throws {
        let model = makeModel()
        let launcher = ControllableSettingsHelperLauncher()
        let coordinator = SettingsCoordinator(
            model: model,
            helperLauncher: launcher,
            helperValidator: PermissiveSettingsHelperLaunchValidator(),
            settingsHelperURLProvider: { URL(fileURLWithPath: "/tmp/GlassEQSettings.app") }
        )

        #expect(coordinator.openSettings() == .helper)
        await waitUntil {
            launcher.receivedAppMessages.contains { message in
                if case .bootstrap = message {
                    return true
                }
                return false
            }
        }
        let bootstrap = try #require(launcher.receivedAppMessages.first)
        guard case .bootstrap(let token) = bootstrap else {
            Issue.record("Expected Settings bootstrap message")
            return
        }
        let requests = try SettingsPipeCodec.encodeLine(
            .request(sessionToken: token, id: "connect", kind: .connect, command: nil)
        ) + SettingsPipeCodec.encodeLine(
            .request(sessionToken: token, id: "ready", kind: .ready, command: nil)
        )
        try launcher.writeHelperOutput(requests)
        for _ in 0..<100 where !coordinator.isHelperReadyForTesting {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(coordinator.isHelperReadyForTesting)
        let baselineMessageCount = launcher.receivedAppMessages.count

        model.engineMetrics = AudioEngineMetrics(capturedFrames: 42)
        coordinator.modelDidChange()

        let expectedMessage = SettingsPipeMessage.event(
            sessionToken: token,
            event: .metricsChanged(SettingsAudioMetricsDTO(capturedFrames: 42))
        )
        await waitUntil {
            launcher.receivedAppMessages
                .dropFirst(baselineMessageCount)
                .contains(expectedMessage)
        }
        #expect(launcher.receivedAppMessages.contains(expectedMessage))
        coordinator.shutdown()
    }

    @Test
    func settingsReadyPublishesChangesThatOccurredAfterConnect() async throws {
        let model = makeModel()
        let launcher = ControllableSettingsHelperLauncher()
        let coordinator = SettingsCoordinator(
            model: model,
            helperLauncher: launcher,
            helperValidator: PermissiveSettingsHelperLaunchValidator(),
            settingsHelperURLProvider: { URL(fileURLWithPath: "/tmp/GlassEQSettings.app") }
        )

        #expect(coordinator.openSettings() == .helper)
        await waitUntil {
            launcher.receivedAppMessages.contains { message in
                if case .bootstrap = message {
                    return true
                }
                return false
            }
        }
        let bootstrap = try #require(launcher.receivedAppMessages.first)
        guard case .bootstrap(let token) = bootstrap else {
            Issue.record("Expected Settings bootstrap message")
            return
        }
        try launcher.writeHelperMessage(.request(
            sessionToken: token,
            id: "connect",
            kind: .connect,
            command: nil
        ))
        await waitUntil {
            launcher.receivedAppMessages.contains { message in
                if case .response(_, "connect", _, _) = message {
                    return true
                }
                return false
            }
        }

        model.statusMessage = "Changed before ready"
        model.engineMetrics = AudioEngineMetrics(capturedFrames: 42)
        coordinator.modelDidChange()
        coordinator.metricsDidChange()
        try launcher.writeHelperMessage(.request(
            sessionToken: token,
            id: "ready",
            kind: .ready,
            command: nil
        ))

        await waitUntil {
            launcher.receivedAppMessages.contains { message in
                guard case .event(_, .snapshotChanged(let snapshot)) = message else {
                    return false
                }
                return snapshot.statusMessage == "Changed before ready"
                    && snapshot.metrics.capturedFrames == 42
            }
        }
        #expect(coordinator.isHelperReadyForTesting)
        coordinator.shutdown()
    }

    @Test
    func settingsReadyAcknowledgmentFailureRequestsInProcessFallback() async throws {
        let model = makeModel()
        let launcher = ControllableSettingsHelperLauncher()
        let coordinator = SettingsCoordinator(
            model: model,
            helperLauncher: launcher,
            helperValidator: PermissiveSettingsHelperLaunchValidator(),
            settingsHelperURLProvider: { URL(fileURLWithPath: "/tmp/GlassEQSettings.app") }
        )

        #expect(coordinator.openSettings() == .helper)
        await waitUntil {
            launcher.receivedAppMessages.contains { message in
                if case .bootstrap = message {
                    return true
                }
                return false
            }
        }
        let bootstrap = try #require(launcher.receivedAppMessages.first)
        guard case .bootstrap(let token) = bootstrap else {
            Issue.record("Expected Settings bootstrap message")
            return
        }
        try launcher.writeHelperMessage(.request(
            sessionToken: token,
            id: "connect",
            kind: .connect,
            command: nil
        ))
        await waitUntil {
            launcher.receivedAppMessages.contains { message in
                if case .response(_, "connect", _, _) = message {
                    return true
                }
                return false
            }
        }

        try launcher.closeHelperInput()
        try launcher.writeHelperMessage(.request(
            sessionToken: token,
            id: "ready",
            kind: .ready,
            command: nil
        ))

        await waitUntil {
            model.inProcessSettingsPresentationGeneration == 1
        }
        #expect(model.statusMessage.contains("IPC failed before connecting"))
        #expect(!coordinator.isHelperReadyForTesting)
        #expect(!coordinator.hasActiveSessionResourcesForTesting)
    }

    @Test
    func settingsBootstrapWriteFailureRequestsInProcessFallback() async throws {
        let model = makeModel()
        let coordinator = SettingsCoordinator(
            model: model,
            helperLauncher: try ClosedInputSettingsHelperLauncher(),
            helperValidator: PermissiveSettingsHelperLaunchValidator(),
            settingsHelperURLProvider: { URL(fileURLWithPath: "/tmp/GlassEQSettings.app") }
        )

        #expect(coordinator.openSettings() == .helper)

        for _ in 0..<100 where model.inProcessSettingsPresentationGeneration == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.inProcessSettingsPresentationGeneration == 1)
        #expect(model.statusMessage.contains("IPC failed before connecting"))
        #expect(!coordinator.hasActiveSessionResourcesForTesting)
    }

    @Test
    func activeInProcessSettingsFallbackIsReusedWithoutLaunchingHelper() {
        let model = makeModel()

        model.inProcessSettingsDidAppear()
        #expect(model.openSettings() == .activeInProcessFallback)

        model.inProcessSettingsDidDisappear()
    }

    @Test
    func pendingInProcessSettingsFallbackIsReusedWithoutLaunchingHelper() {
        let model = makeModel()

        model.requestInProcessSettingsPresentation()
        let firstGeneration = model.inProcessSettingsPresentationGeneration

        #expect(model.openSettings() == .activeInProcessFallback)
        #expect(model.inProcessSettingsPresentationGeneration == firstGeneration + 1)
    }

    @Test
    func aggregateBufferNotificationOpensSettingsInTheMainProcess() {
        let model = makeModel()

        model.openAggregateBufferSettings()

        #expect(model.inProcessSettingsPresentationIsPending)
        #expect(model.inProcessSettingsPresentationGeneration == 1)
        #expect(!model.settingsCoordinator.hasActiveSessionResourcesForTesting)
    }

    @Test
    func inProcessSettingsFallbackPerformsCommandsAndTracksModelChanges() async throws {
        let model = makeModel()
        let settingsModel = model.inProcessSettingsViewModel()
        let snapshotVersion = settingsModel.snapshotVersion

        #expect(settingsModel.isConnected)
        #expect(settingsModel.snapshot == model.settingsSnapshot())
        #expect(model.inProcessSettingsViewModel() === settingsModel)
        #expect(settingsModel.snapshotVersion == snapshotVersion)

        let response = await settingsModel.perform(.createProfile(.parametric))
        #expect(response?.snapshot?.profiles.count == 2)
        #expect(settingsModel.snapshot == model.settingsSnapshot())
    }

    @Test
    func settingsHelperValidationChecksContainmentBundleIDAndSigningPolicy() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlassEQHelperValidation-\(UUID().uuidString)", isDirectory: true)
        let hostURL = root.appendingPathComponent("GlassEQ.app", isDirectory: true)
        let helperURL = hostURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent("GlassEQSettings.app", isDirectory: true)
        try makeFakeAppBundle(
            at: helperURL,
            bundleIdentifier: SettingsHelperVerifier.helperBundleIdentifier,
            executableName: "GlassEQSettings"
        )
        let validator = FakeCodeSigningValidator(signatures: [
            hostURL.standardizedFileURL.path: SettingsCodeSignatureInfo(signingIdentifier: SettingsHelperVerifier.hostBundleIdentifier, teamIdentifier: "TEAMID"),
            helperURL.standardizedFileURL.path: SettingsCodeSignatureInfo(signingIdentifier: SettingsHelperVerifier.helperBundleIdentifier, teamIdentifier: "TEAMID")
        ])

        let executableURL = try SettingsHelperVerifier.validatedExecutableURL(
            for: helperURL,
            hostBundleURL: hostURL,
            codeSigningValidator: validator
        )

        #expect(executableURL.lastPathComponent == "GlassEQSettings")

        let wrongBundleURL = hostURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent("WrongSettings.app", isDirectory: true)
        try makeFakeAppBundle(at: wrongBundleURL, bundleIdentifier: "com.example.wrong", executableName: "GlassEQSettings")
        #expect(throws: SettingsCommandFailure.self) {
            _ = try SettingsHelperVerifier.validatedExecutableURL(
                for: wrongBundleURL,
                hostBundleURL: hostURL,
                codeSigningValidator: validator
            )
        }

        let outsideURL = root
            .appendingPathComponent("Outside", isDirectory: true)
            .appendingPathComponent("GlassEQSettings.app", isDirectory: true)
        try makeFakeAppBundle(
            at: outsideURL,
            bundleIdentifier: SettingsHelperVerifier.helperBundleIdentifier,
            executableName: "GlassEQSettings"
        )
        #expect(throws: SettingsCommandFailure.self) {
            _ = try SettingsHelperVerifier.validatedExecutableURL(
                for: outsideURL,
                hostBundleURL: hostURL,
                codeSigningValidator: validator
            )
        }

        let mismatchedTeam = FakeCodeSigningValidator(signatures: [
            hostURL.standardizedFileURL.path: SettingsCodeSignatureInfo(signingIdentifier: SettingsHelperVerifier.hostBundleIdentifier, teamIdentifier: "TEAMID"),
            helperURL.standardizedFileURL.path: SettingsCodeSignatureInfo(signingIdentifier: SettingsHelperVerifier.helperBundleIdentifier, teamIdentifier: "OTHERTEAM")
        ])
        #expect(throws: SettingsCommandFailure.self) {
            _ = try SettingsHelperVerifier.validatedExecutableURL(
                for: helperURL,
                hostBundleURL: hostURL,
                codeSigningValidator: mismatchedTeam
            )
        }

        let adHoc = FakeCodeSigningValidator(signatures: [
            hostURL.standardizedFileURL.path: SettingsCodeSignatureInfo(signingIdentifier: SettingsHelperVerifier.hostBundleIdentifier, teamIdentifier: nil),
            helperURL.standardizedFileURL.path: SettingsCodeSignatureInfo(signingIdentifier: SettingsHelperVerifier.helperBundleIdentifier, teamIdentifier: nil)
        ])
        _ = try SettingsHelperVerifier.validatedExecutableURL(
            for: helperURL,
            hostBundleURL: hostURL,
            codeSigningValidator: adHoc
        )
    }

    @Test
    func settingsHelperRunningValidationFallsBackWhenLaunchServicesHasNoBundleURL() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlassEQHelperRunningValidation-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let hostURL = root.appendingPathComponent("GlassEQ.app", isDirectory: true)
        let helperURL = hostURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent("GlassEQSettings.app", isDirectory: true)
        try makeFakeAppBundle(
            at: helperURL,
            bundleIdentifier: SettingsHelperVerifier.helperBundleIdentifier,
            executableName: "GlassEQSettings"
        )
        let validator = FakeCodeSigningValidator(signatures: [
            hostURL.standardizedFileURL.path: SettingsCodeSignatureInfo(signingIdentifier: SettingsHelperVerifier.hostBundleIdentifier, teamIdentifier: "TEAMID"),
            helperURL.standardizedFileURL.path: SettingsCodeSignatureInfo(signingIdentifier: SettingsHelperVerifier.helperBundleIdentifier, teamIdentifier: "TEAMID"),
            "pid:123": SettingsCodeSignatureInfo(signingIdentifier: SettingsHelperVerifier.helperBundleIdentifier, teamIdentifier: "TEAMID")
        ])

        try SettingsHelperVerifier.validateRunningProcess(
            processIdentifier: 123,
            expectedHelperURL: helperURL,
            hostBundleURL: hostURL,
            runningBundleURL: { _ in nil },
            processExecutableURL: { _ in helperExecutableURL(for: helperURL) },
            codeSigningValidator: validator
        )
    }

    @Test
    func settingsHelperRunningValidationRejectsUnexpectedResolvedBundleURL() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlassEQHelperRunningValidation-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let hostURL = root.appendingPathComponent("GlassEQ.app", isDirectory: true)
        let helperURL = hostURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent("GlassEQSettings.app", isDirectory: true)
        let otherURL = root.appendingPathComponent("OtherSettings.app", isDirectory: true)
        try makeFakeAppBundle(
            at: helperURL,
            bundleIdentifier: SettingsHelperVerifier.helperBundleIdentifier,
            executableName: "GlassEQSettings"
        )
        try makeFakeAppBundle(
            at: otherURL,
            bundleIdentifier: SettingsHelperVerifier.helperBundleIdentifier,
            executableName: "GlassEQSettings"
        )
        let validator = FakeCodeSigningValidator(signatures: [
            hostURL.standardizedFileURL.path: SettingsCodeSignatureInfo(signingIdentifier: SettingsHelperVerifier.hostBundleIdentifier, teamIdentifier: "TEAMID"),
            helperURL.standardizedFileURL.path: SettingsCodeSignatureInfo(signingIdentifier: SettingsHelperVerifier.helperBundleIdentifier, teamIdentifier: "TEAMID"),
            otherURL.standardizedFileURL.path: SettingsCodeSignatureInfo(signingIdentifier: SettingsHelperVerifier.helperBundleIdentifier, teamIdentifier: "TEAMID"),
            "pid:123": SettingsCodeSignatureInfo(signingIdentifier: SettingsHelperVerifier.helperBundleIdentifier, teamIdentifier: "TEAMID")
        ])

        #expect(throws: SettingsCommandFailure.self) {
            try SettingsHelperVerifier.validateRunningProcess(
                processIdentifier: 123,
                expectedHelperURL: helperURL,
                hostBundleURL: hostURL,
                runningBundleURL: { _ in otherURL },
                processExecutableURL: { _ in helperExecutableURL(for: otherURL) },
                codeSigningValidator: validator
            )
        }
    }
}

@MainActor
private func makeModel(
    store: ProfileStore? = nil,
    storeURL: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("GlassEQAppTests-\(UUID().uuidString).json"),
    engine: FakeAudioEngine = FakeAudioEngine(),
    lookup: FakeDefaultOutputLookup = FakeDefaultOutputLookup(.success(makeOutput())),
    observers: any DefaultOutputObservingMaking = FakeDefaultOutputObserverFactory(),
    workspaceOpener: any WorkspaceOpening = FakeWorkspaceOpener(results: []),
    profileImportOperation: (@Sendable (ImportFormat, String, String) async -> Result<EQProfile, any Error>)? = nil,
    saveDelay: Duration = .zero,
    outputDelay: Duration? = nil,
    wakeDelay: Duration? = nil,
    aggregateStabilityDelay: Duration = .zero,
    aggregateCleanSessionDuration: Duration = .seconds(5 * 60),
    headsetAggregatePromotionDelay: Duration = .seconds(6),
    coldStartupAggregatePromotionPollInterval: Duration = .seconds(1),
    renderWatchdogStallThreshold: Duration = AudioRenderWatchdog.defaultStallThreshold,
    renderWatchdogRepeatedFailureWindow: Duration = AudioRenderWatchdog.defaultRepeatedFailureWindow,
    renderWatchdogPollInterval: Duration = .milliseconds(500),
    aggregateBufferNotifier: (any AggregateBufferChangeNotifying)? = nil
) -> GlassEQAppModel {
    let store = normalizedStore(store ?? ProfileStore(profiles: [makeProfile(name: "Fallback")]))
    return GlassEQAppModel(
        profileStore: store,
        storeURL: storeURL,
        engine: engine,
        defaultOutputLookup: lookup,
        observerFactory: observers,
        autoStart: false,
        installLifecycleObservers: false,
        registerAppDelegate: false,
        workspaceOpener: workspaceOpener,
        profileImportOperation: profileImportOperation,
        saveDebounceDelay: saveDelay,
        outputChangeSettlingDelayOverride: outputDelay,
        wakeReconnectDelayOverride: wakeDelay,
        aggregateBufferPolicyURL: storeURL.deletingPathExtension()
            .appendingPathExtension("aggregate-buffer-policy.json"),
        aggregateStabilitySettlingDelay: aggregateStabilityDelay,
        aggregateCleanSessionDuration: aggregateCleanSessionDuration,
        headsetAggregatePromotionDelay: headsetAggregatePromotionDelay,
        coldStartupAggregatePromotionPollInterval: coldStartupAggregatePromotionPollInterval,
        renderWatchdogStallThreshold: renderWatchdogStallThreshold,
        renderWatchdogRepeatedFailureWindow: renderWatchdogRepeatedFailureWindow,
        renderWatchdogPollInterval: renderWatchdogPollInterval,
        aggregateBufferNotifier: aggregateBufferNotifier
    )
}

private final class BlockingProfileImportOperation: @unchecked Sendable {
    private let lock = NSLock()
    private var entered = false
    private var continuation: CheckedContinuation<Result<EQProfile, any Error>, Never>?

    var hasEntered: Bool {
        lock.withLock { entered }
    }

    func run(
        format: ImportFormat,
        name: String,
        text: String
    ) async -> Result<EQProfile, any Error> {
        await withCheckedContinuation { continuation in
            lock.withLock {
                self.continuation = continuation
                entered = true
            }
        }
    }

    func complete(with result: Result<EQProfile, any Error>) {
        let continuation = lock.withLock {
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume(returning: result)
    }
}

private func normalizedStore(_ store: ProfileStore) -> ProfileStore {
    guard store.profiles.contains(where: { $0.id == store.fallbackProfileID }) else {
        return ProfileStore(profiles: store.profiles)
    }
    return store
}

private func makeProfile(name: String) -> EQProfile {
    EQProfile(name: name, mode: .parametric, filters: [])
}

private func makeImpulseResponseProfile(
    name: String,
    sampleRate: Double
) -> EQProfile {
    EQProfile(
        name: name,
        mode: .convolution,
        filters: [],
        convolution: .impulseResponse(ImpulseResponseSource(
            sampleRate: sampleRate,
            samples: [1, 0.25, -0.125]
        ))
    )
}

private func makeStore(profileCount: Int) -> ProfileStore {
    let profiles = (0..<profileCount).map { index in
        makeProfile(name: "Profile \(index)")
    }
    return ProfileStore(profiles: profiles, fallbackProfileID: profiles[0].id)
}

private func makeOutput(
    uid: String = "output",
    name: String = "Output",
    id: AudioObjectID = 100,
    nominalSampleRate: Double = 48_000,
    bufferFrameSize: UInt32 = 256,
    transportType: UInt32? = nil
) -> AudioOutputDevice {
    AudioOutputDevice(
        id: id,
        uid: uid,
        name: name,
        nominalSampleRate: nominalSampleRate,
        outputChannelCount: 2,
        bufferFrameSize: bufferFrameSize,
        transportType: transportType
    )
}

private func temporaryAppStoreURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("GlassEQAppTests-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("Profiles.json")
}

private func removeTemporaryStoreDirectory(for url: URL) {
    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
}

private func makeFakeAppBundle(
    at appURL: URL,
    bundleIdentifier: String,
    executableName: String
) throws {
    let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
    let macOSURL = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
    try FileManager.default.createDirectory(at: macOSURL, withIntermediateDirectories: true)
    let info: NSDictionary = [
        "CFBundleIdentifier": bundleIdentifier,
        "CFBundleExecutable": executableName,
        "CFBundlePackageType": "APPL"
    ]
    let plistURL = contentsURL.appendingPathComponent("Info.plist")
    guard info.write(to: plistURL, atomically: true) else {
        Issue.record("Failed to write fake app Info.plist")
        return
    }
    let executableURL = macOSURL.appendingPathComponent(executableName, isDirectory: false)
    FileManager.default.createFile(atPath: executableURL.path, contents: Data("#!/bin/sh\n".utf8))
}

private func helperExecutableURL(for helperURL: URL) -> URL {
    helperURL
        .appendingPathComponent("Contents", isDirectory: true)
        .appendingPathComponent("MacOS", isDirectory: true)
        .appendingPathComponent("GlassEQSettings", isDirectory: false)
        .standardizedFileURL
}

private func settleAsyncWork() async {
    try? await Task.sleep(for: .milliseconds(20))
}

@MainActor
@discardableResult
private func waitUntil(
    maxAttempts: Int = 100,
    _ predicate: @MainActor () -> Bool
) async -> Bool {
    for _ in 0..<maxAttempts {
        if predicate() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return predicate()
}

private enum TestAudioError: Error, Equatable {
    case startFailed
    case updateFailed
    case defaultOutputUnavailable
}

private let adaptiveRenderFailure = AudioEngineFailure(
    category: .coreAudioOperationFailed,
    userMessage: "Adaptive playback rendering repeatedly failed.",
    operation: "AdaptivePlaybackRender"
)

@MainActor
private final class FakeWorkspaceOpener: WorkspaceOpening {
    private var results: [Bool]
    private(set) var openedURLs: [URL] = []

    init(results: [Bool]) {
        self.results = results
    }

    func open(_ url: URL) -> Bool {
        openedURLs.append(url)
        guard !results.isEmpty else {
            return true
        }
        return results.removeFirst()
    }
}

private struct FakeCodeSigningValidator: SettingsCodeSigningValidating {
    var signatures: [String: SettingsCodeSignatureInfo]

    func signatureInfo(for url: URL) throws -> SettingsCodeSignatureInfo {
        guard let signature = signatures[url.standardizedFileURL.path] else {
            throw SettingsCommandFailure(message: "Missing fake signature")
        }
        return signature
    }

    func signatureInfo(forProcessIdentifier processIdentifier: pid_t) throws -> SettingsCodeSignatureInfo {
        guard let signature = signatures["pid:\(processIdentifier)"] ?? signatures.values.first else {
            throw SettingsCommandFailure(message: "Missing fake process signature")
        }
        return signature
    }
}

private struct FailingSettingsHelperLaunchValidator: SettingsHelperLaunchValidating {
    func validatedExecutableURL(for helperURL: URL) throws -> URL {
        URL(fileURLWithPath: "/bin/sleep")
    }

    func validateRunningProcess(processIdentifier: pid_t, expectedHelperURL: URL) throws {
        throw SettingsCommandFailure(message: "Intentional post-launch validation failure")
    }
}

private struct PermissiveSettingsHelperLaunchValidator: SettingsHelperLaunchValidating {
    func validatedExecutableURL(for helperURL: URL) throws -> URL {
        URL(fileURLWithPath: "/usr/bin/true")
    }

    func validateRunningProcess(processIdentifier: pid_t, expectedHelperURL: URL) throws {}
}

private struct PermissionDeniedSettingsHelperLauncher: SettingsHelperLaunching {
    func launch(
        executableURL: URL,
        arguments: [String],
        terminationHandler: @escaping @Sendable (Process) -> Void
    ) throws -> SettingsHelperLaunch {
        throw POSIXError(.EPERM)
    }
}

private final class ControllableSettingsHelperLauncher: SettingsHelperLaunching, @unchecked Sendable {
    private let input = Pipe()
    private let output = Pipe()
    private let error = Pipe()
    private let messagesLock = NSLock()
    private var messages: [SettingsPipeMessage] = []
    private var appReadPump: SettingsPipeReadPump?

    var receivedAppMessages: [SettingsPipeMessage] {
        messagesLock.withLock { messages }
    }

    func launch(
        executableURL: URL,
        arguments: [String],
        terminationHandler: @escaping @Sendable (Process) -> Void
    ) throws -> SettingsHelperLaunch {
        let pump = SettingsPipeReadPump(
            label: "com.glasseq.tests.settings-helper-input",
            onMessages: { [weak self] result in
                guard let self, case .success(let messages) = result else {
                    return
                }
                messagesLock.withLock {
                    self.messages.append(contentsOf: messages)
                }
            },
            onEndOfFile: {}
        )
        appReadPump = pump
        pump.install(on: input.fileHandleForReading)
        return SettingsHelperLaunch(process: Process(), input: input, output: output, error: error)
    }

    func writeHelperOutput(_ data: Data) throws {
        try output.fileHandleForWriting.write(contentsOf: data)
    }

    func writeHelperMessage(_ message: SettingsPipeMessage) throws {
        try writeHelperOutput(SettingsPipeCodec.encodeLine(message))
    }

    func closeHelperOutput() throws {
        try output.fileHandleForWriting.close()
    }

    func closeHelperInput() throws {
        appReadPump?.invalidate(handle: input.fileHandleForReading)
        appReadPump = nil
        try input.fileHandleForReading.close()
    }

}

private final class ClosedInputSettingsHelperLauncher: SettingsHelperLaunching {
    private let input = Pipe()
    private let output = Pipe()
    private let error = Pipe()

    init() throws {
        try input.fileHandleForReading.close()
    }

    func launch(
        executableURL: URL,
        arguments: [String],
        terminationHandler: @escaping @Sendable (Process) -> Void
    ) throws -> SettingsHelperLaunch {
        SettingsHelperLaunch(process: Process(), input: input, output: output, error: error)
    }
}

private final class SleepingSettingsHelperLauncher: SettingsHelperLaunching {
    private(set) var launchedProcesses: [Process] = []

    func launch(
        executableURL: URL,
        arguments: [String],
        terminationHandler: @escaping @Sendable (Process) -> Void
    ) throws -> SettingsHelperLaunch {
        let process = Process()
        let helperInput = Pipe()
        let helperOutput = Pipe()
        let helperError = Pipe()
        process.executableURL = executableURL
        process.arguments = ["60"]
        process.standardInput = helperInput.fileHandleForReading
        process.standardOutput = helperOutput.fileHandleForWriting
        process.standardError = helperError.fileHandleForWriting
        process.terminationHandler = terminationHandler
        try process.run()
        launchedProcesses.append(process)
        return SettingsHelperLaunch(
            process: process,
            input: helperInput,
            output: helperOutput,
            error: helperError
        )
    }
}

private final class FakeDefaultOutputLookup: DefaultOutputLookingUp, @unchecked Sendable {
    private let lock = NSLock()
    private var _defaultOutputCalls = 0
    private var _result: Result<AudioOutputDevice, Error>

    private(set) var defaultOutputCalls: Int {
        get { withLock { _defaultOutputCalls } }
        set { withLock { _defaultOutputCalls = newValue } }
    }

    var result: Result<AudioOutputDevice, Error> {
        get { withLock { _result } }
        set { withLock { _result = newValue } }
    }

    init(_ result: Result<AudioOutputDevice, Error>) {
        self._result = result
    }

    func defaultOutputDevice() throws -> AudioOutputDevice {
        let result = withLock {
            _defaultOutputCalls += 1
            return _result
        }
        return try result.get()
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class FakeDefaultOutputObserverFactory: DefaultOutputObservingMaking {
    private(set) var observers: [FakeDefaultOutputObserver] = []

    func makeObserver(onChange: @escaping DefaultOutputObserverHandler) -> any DefaultOutputObserving {
        let observer = FakeDefaultOutputObserver(onChange: onChange)
        observers.append(observer)
        return observer
    }
}

private final class FakeDefaultOutputObserver: DefaultOutputObserving, @unchecked Sendable {
    private let onChange: DefaultOutputObserverHandler
    private let lock = NSLock()
    private var _startCalls: [Bool] = []
    private var _stopCallCount = 0

    var startCalls: [Bool] {
        withLock {
            _startCalls
        }
    }

    var stopCallCount: Int {
        withLock {
            _stopCallCount
        }
    }

    init(onChange: @escaping DefaultOutputObserverHandler) {
        self.onChange = onChange
    }

    func start(sendInitialValue: Bool) throws {
        withLock {
            _startCalls.append(sendInitialValue)
        }
    }

    func stop() {
        withLock {
            _stopCallCount += 1
        }
    }

    func emit(_ result: Result<AudioOutputDevice, Error>) {
        onChange(result)
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer {
            lock.unlock()
        }
        return body()
    }
}

private final class BlockingAsyncDefaultOutputObserverFactory: DefaultOutputObservingMaking {
    private(set) var observers: [BlockingAsyncDefaultOutputObserver] = []

    func makeObserver(onChange: @escaping DefaultOutputObserverHandler) -> any DefaultOutputObserving {
        let observer = BlockingAsyncDefaultOutputObserver(onChange: onChange)
        observers.append(observer)
        return observer
    }
}

private final class BlockingAsyncDefaultOutputObserver: DefaultOutputObserving, @unchecked Sendable {
    private let onChange: DefaultOutputObserverHandler
    private let lock = NSLock()
    private var _startCalls: [Bool] = []
    private var _stopCallCount = 0
    private var startContinuation: CheckedContinuation<Void, Never>?

    init(onChange: @escaping DefaultOutputObserverHandler) {
        self.onChange = onChange
    }

    var startCalls: [Bool] {
        withLock {
            _startCalls
        }
    }

    var stopCallCount: Int {
        withLock {
            _stopCallCount
        }
    }

    func start(sendInitialValue: Bool) throws {
        withLock {
            _startCalls.append(sendInitialValue)
        }
    }

    func startAsync(sendInitialValue: Bool) async throws {
        try start(sendInitialValue: sendInitialValue)
        await withCheckedContinuation { continuation in
            withLock {
                startContinuation = continuation
            }
        }
    }

    func stop() {
        withLock {
            _stopCallCount += 1
        }
    }

    func stopAsync() async {
        stop()
    }

    func emit(_ result: Result<AudioOutputDevice, Error>) {
        onChange(result)
    }

    func resumeStart() {
        let continuation = withLock {
            let continuation = startContinuation
            startContinuation = nil
            return continuation
        }
        continuation?.resume()
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer {
            lock.unlock()
        }
        return body()
    }
}

private final class FakeAudioEngine: AudioEngineControlling, @unchecked Sendable {
    struct StartCall: Equatable {
        var output: AudioOutputDevice
        var profile: EQProfile
        var aggregateBufferFrameSize: UInt32
    }

    private let lock = NSLock()
    private var _state: AudioEngineState = .stopped
    private var _processingSampleRate: Double?
    private var _startError: Error?
    private var _startErrorProfileID: UUID?
    private var _startErrorPreservesRunningState = false
    private var _updateError: Error?
    private var _updateErrorPreservesRunningState = false
    private var _updateDSPResult = true
    private var _beginProgrammeComparisonResult = true
    private var _startDelaySeconds: TimeInterval = 0
    private var _startDelaySecondsByUID: [String: TimeInterval] = [:]
    private var _startBlockersByUID: [String: FakeStartBlocker] = [:]
    private var _updateBlockersByProfileID: [UUID: FakeStartBlocker] = [:]
    private var _startCalls: [StartCall] = []
    private var _updateCalls: [EQProfile] = []
    private var _updateDSPCalls: [EQProfile] = []
    private var _programmeComparisonCalls: [EQProfile] = []
    private var _programmeComparisonSelections: [EQProgrammeComparisonSelection] = []
    private var _programmeComparisonSnapshot = EQProgrammeComparisonSnapshot()
    private var _stopCallCount = 0
    private var _muteOutputCallCount = 0
    private var _resumeOutputCallCount = 0
    private var _metrics = AudioEngineMetrics()
    private var _events: [String] = []
    private var _preferredAggregateBufferFrameSize: UInt32 = 16
    private var _nativeOutputStreamIndex = 0
    private var _reflectPreferredAggregateBufferFrameSize = false
    private var _headsetPromotionCandidateUIDs: Set<String> = []
    private var _headsetAggregatePromotionResult = HeadsetAggregatePromotionResult.notApplicable
    private var _headsetAggregatePromotionAttemptCount = 0
    private var _isUsingTransitionalHeadsetBackend = false
    private var _isUsingPromotedHeadsetAggregate = false
    private var _coldStartupPromotionCandidateUIDs: Set<String> = []
    private var _coldStartupAggregatePromotionResult = ColdStartupAggregatePromotionResult.notApplicable
    private var _coldStartupAggregatePromotionAttemptCount = 0
    private var _isDeferringColdStartupAggregate = false
    private var _runtimeFailureHandler: (@Sendable (AudioEngineFailure) -> Void)?

    var state: AudioEngineState {
        get { withLock { _state } }
        set { withLock { _state = newValue } }
    }

    var processingSampleRate: Double? {
        get { withLock { _processingSampleRate } }
        set { withLock { _processingSampleRate = newValue } }
    }

    var isUsingTransitionalHeadsetBackend: Bool {
        withLock { _isUsingTransitionalHeadsetBackend }
    }

    var isUsingPromotedHeadsetAggregate: Bool {
        withLock { _isUsingPromotedHeadsetAggregate }
    }

    var isDeferringColdStartupAggregate: Bool {
        withLock { _isDeferringColdStartupAggregate }
    }

    var startError: Error? {
        get { withLock { _startError } }
        set { withLock { _startError = newValue } }
    }

    var startErrorProfileID: UUID? {
        get { withLock { _startErrorProfileID } }
        set { withLock { _startErrorProfileID = newValue } }
    }

    var startErrorPreservesRunningState: Bool {
        get { withLock { _startErrorPreservesRunningState } }
        set { withLock { _startErrorPreservesRunningState = newValue } }
    }

    var updateError: Error? {
        get { withLock { _updateError } }
        set { withLock { _updateError = newValue } }
    }

    var updateErrorPreservesRunningState: Bool {
        get { withLock { _updateErrorPreservesRunningState } }
        set { withLock { _updateErrorPreservesRunningState = newValue } }
    }

    var updateDSPResult: Bool {
        get { withLock { _updateDSPResult } }
        set { withLock { _updateDSPResult = newValue } }
    }

    var beginProgrammeComparisonResult: Bool {
        get { withLock { _beginProgrammeComparisonResult } }
        set { withLock { _beginProgrammeComparisonResult = newValue } }
    }

    var startDelaySeconds: TimeInterval {
        get { withLock { _startDelaySeconds } }
        set { withLock { _startDelaySeconds = newValue } }
    }

    var startDelaySecondsByUID: [String: TimeInterval] {
        get { withLock { _startDelaySecondsByUID } }
        set { withLock { _startDelaySecondsByUID = newValue } }
    }

    private(set) var startCalls: [StartCall] {
        get { withLock { _startCalls } }
        set { withLock { _startCalls = newValue } }
    }

    private(set) var updateCalls: [EQProfile] {
        get { withLock { _updateCalls } }
        set { withLock { _updateCalls = newValue } }
    }

    private(set) var updateDSPCalls: [EQProfile] {
        get { withLock { _updateDSPCalls } }
        set { withLock { _updateDSPCalls = newValue } }
    }

    private(set) var programmeComparisonCalls: [EQProfile] {
        get { withLock { _programmeComparisonCalls } }
        set { withLock { _programmeComparisonCalls = newValue } }
    }

    private(set) var programmeComparisonSelections: [EQProgrammeComparisonSelection] {
        get { withLock { _programmeComparisonSelections } }
        set { withLock { _programmeComparisonSelections = newValue } }
    }

    var programmeComparisonSnapshot: EQProgrammeComparisonSnapshot {
        get { withLock { _programmeComparisonSnapshot } }
        set { withLock { _programmeComparisonSnapshot = newValue } }
    }

    private(set) var stopCallCount: Int {
        get { withLock { _stopCallCount } }
        set { withLock { _stopCallCount = newValue } }
    }

    private(set) var muteOutputCallCount: Int {
        get { withLock { _muteOutputCallCount } }
        set { withLock { _muteOutputCallCount = newValue } }
    }

    private(set) var resumeOutputCallCount: Int {
        get { withLock { _resumeOutputCallCount } }
        set { withLock { _resumeOutputCallCount = newValue } }
    }

    var metrics: AudioEngineMetrics {
        get { withLock { _metrics } }
        set { withLock { _metrics = newValue } }
    }

    var reflectPreferredAggregateBufferFrameSize: Bool {
        get { withLock { _reflectPreferredAggregateBufferFrameSize } }
        set { withLock { _reflectPreferredAggregateBufferFrameSize = newValue } }
    }

    var headsetPromotionCandidateUIDs: Set<String> {
        get { withLock { _headsetPromotionCandidateUIDs } }
        set { withLock { _headsetPromotionCandidateUIDs = newValue } }
    }

    var headsetAggregatePromotionResult: HeadsetAggregatePromotionResult {
        get { withLock { _headsetAggregatePromotionResult } }
        set { withLock { _headsetAggregatePromotionResult = newValue } }
    }

    var headsetAggregatePromotionAttemptCount: Int {
        withLock { _headsetAggregatePromotionAttemptCount }
    }

    var coldStartupPromotionCandidateUIDs: Set<String> {
        get { withLock { _coldStartupPromotionCandidateUIDs } }
        set { withLock { _coldStartupPromotionCandidateUIDs = newValue } }
    }

    var coldStartupAggregatePromotionResult: ColdStartupAggregatePromotionResult {
        get { withLock { _coldStartupAggregatePromotionResult } }
        set { withLock { _coldStartupAggregatePromotionResult = newValue } }
    }

    var coldStartupAggregatePromotionAttemptCount: Int {
        withLock { _coldStartupAggregatePromotionAttemptCount }
    }

    var events: [String] {
        withLock { _events }
    }

    func blockStart(for outputUID: String) {
        withLock {
            _startBlockersByUID[outputUID] = FakeStartBlocker()
        }
    }

    func waitUntilStartIsBlocked(for outputUID: String, timeout: DispatchTime) -> Bool {
        withLock {
            _startBlockersByUID[outputUID]
        }?.waitUntilEntered(timeout: timeout) ?? false
    }

    func unblockStart(for outputUID: String) {
        let blocker = withLock {
            _startBlockersByUID.removeValue(forKey: outputUID)
        }
        blocker?.unblock()
    }

    func blockUpdate(for profileID: UUID) {
        withLock {
            _updateBlockersByProfileID[profileID] = FakeStartBlocker()
        }
    }

    func waitUntilUpdateIsBlocked(for profileID: UUID, timeout: DispatchTime) -> Bool {
        withLock {
            _updateBlockersByProfileID[profileID]
        }?.waitUntilEntered(timeout: timeout) ?? false
    }

    func unblockUpdate(for profileID: UUID) {
        let blocker = withLock {
            _updateBlockersByProfileID.removeValue(forKey: profileID)
        }
        blocker?.unblock()
    }

    func start(output: AudioOutputDevice, profile: EQProfile) throws {
        let startControl = withLock {
            _events.append("start:\(output.uid)")
            _startCalls.append(StartCall(
                output: output,
                profile: profile,
                aggregateBufferFrameSize: _preferredAggregateBufferFrameSize
            ))
            return (
                delay: _startDelaySecondsByUID[output.uid] ?? _startDelaySeconds,
                blocker: _startBlockersByUID[output.uid],
                error: _startErrorProfileID == nil || _startErrorProfileID == profile.id
                    ? _startError
                    : nil,
                preservesRunningState: _startErrorPreservesRunningState
            )
        }
        startControl.blocker?.waitUntilUnblocked()
        if startControl.delay > 0 {
            Thread.sleep(forTimeInterval: startControl.delay)
        }
        if let startError = startControl.error {
            if !startControl.preservesRunningState {
                withLock {
                    _state = .failed("Start failed")
                }
            }
            throw startError
        }
        withLock {
            var activeOutput = output
            if _reflectPreferredAggregateBufferFrameSize {
                activeOutput.bufferFrameSize = _preferredAggregateBufferFrameSize
            }
            _state = .running(output: activeOutput)
            _isUsingTransitionalHeadsetBackend = _headsetPromotionCandidateUIDs.contains(output.uid)
            _isUsingPromotedHeadsetAggregate = false
            _isDeferringColdStartupAggregate = _coldStartupPromotionCandidateUIDs.contains(output.uid)
        }
    }

    func attemptColdStartupAggregatePromotion() throws
        -> ColdStartupAggregatePromotionResult {
        withLock {
            _coldStartupAggregatePromotionAttemptCount += 1
            let result = _coldStartupAggregatePromotionResult
            if case .promoted(let output) = result {
                _state = .running(output: output)
                _isDeferringColdStartupAggregate = false
            }
            return result
        }
    }

    func attemptHeadsetAggregatePromotion() throws -> HeadsetAggregatePromotionResult {
        withLock {
            _headsetAggregatePromotionAttemptCount += 1
            let result = _headsetAggregatePromotionResult
            if case .promoted(let output) = result {
                _state = .running(output: output)
                _isUsingTransitionalHeadsetBackend = false
                _isUsingPromotedHeadsetAggregate = true
            }
            return result
        }
    }

    func rejectHeadsetAggregatePromotion() {
        withLock {
            _isUsingPromotedHeadsetAggregate = false
        }
    }

    func aggregateRouteFingerprint(
        for output: AudioOutputDevice
    ) throws -> AggregateAudioRouteFingerprint? {
        withLock {
            if _isUsingTransitionalHeadsetBackend || _isDeferringColdStartupAggregate {
                return nil
            }
            return AggregateAudioRouteFingerprint(
                outputDeviceUID: output.uid,
                nativeOutputStreamIndex: _nativeOutputStreamIndex,
                nominalSampleRate: output.nominalSampleRate
            )
        }
    }

    func setPreferredAggregateBufferFrameSize(_ frameSize: UInt32) {
        withLock {
            _preferredAggregateBufferFrameSize = frameSize
        }
    }

    func update(profile: EQProfile) throws {
        let update = withLock {
            _events.append("update:\(profile.id)")
            _updateCalls.append(profile)
            return (
                blocker: _updateBlockersByProfileID[profile.id],
                error: _updateError,
                preservesRunningState: _updateErrorPreservesRunningState
            )
        }
        update.blocker?.waitUntilUnblocked()
        if let updateError = update.error {
            if !update.preservesRunningState {
                withLock {
                    _state = .failed("Update failed")
                }
            }
            throw updateError
        }
        withLock {
            if case .running(let output) = _state {
                _state = .running(output: output)
            }
        }
    }

    func updateDSP(profile: EQProfile) -> Bool {
        withLock {
            _events.append("updateDSP:\(profile.id)")
            _updateDSPCalls.append(profile)
            return _updateDSPResult
        }
    }

    func beginProgrammeComparison(profile: EQProfile) -> Bool {
        withLock {
            _programmeComparisonCalls.append(profile)
            if _beginProgrammeComparisonResult {
                _programmeComparisonSnapshot = EQProgrammeComparisonSnapshot(
                    isActive: true,
                    selection: .equalized
                )
            }
            return _beginProgrammeComparisonResult
        }
    }

    func setProgrammeComparisonSelection(
        _ selection: EQProgrammeComparisonSelection
    ) {
        withLock {
            _programmeComparisonSelections.append(selection)
            _programmeComparisonSnapshot.selection = selection
        }
    }

    func snapshotProgrammeComparison() -> EQProgrammeComparisonSnapshot {
        withLock {
            _programmeComparisonSnapshot
        }
    }

    func muteOutputForTransition() {
        withLock {
            _events.append("mute")
            _muteOutputCallCount += 1
        }
    }

    func resumeOutputAfterCancelledTransition() {
        withLock {
            _events.append("resume")
            _resumeOutputCallCount += 1
        }
    }

    func setRuntimeFailureHandler(
        _ handler: (@Sendable (AudioEngineFailure) -> Void)?
    ) {
        withLock {
            _runtimeFailureHandler = handler
        }
    }

    func emitRuntimeFailure(_ failure: AudioEngineFailure, markEngineFailed: Bool = true) {
        let handler = withLock {
            if markEngineFailed {
                _state = .failed(failure.description)
            }
            return _runtimeFailureHandler
        }
        handler?(failure)
    }

    func stop() {
        withLock {
            _events.append("stop")
            _stopCallCount += 1
            _state = .stopped
            _isUsingTransitionalHeadsetBackend = false
            _isUsingPromotedHeadsetAggregate = false
            _isDeferringColdStartupAggregate = false
        }
    }

    func snapshotMetrics() -> AudioEngineMetrics {
        withLock {
            _metrics
        }
    }

    func resetDiagnostics() {
        withLock {
            _metrics = AudioEngineMetrics()
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

@MainActor
private final class FakeAggregateBufferNotifier: AggregateBufferChangeNotifying {
    struct Call: Equatable {
        enum Kind: Equatable {
            case automatic
            case fixedRebuild
            case fixedTemporaryIncrease
        }

        var outputName: String
        var previousFrameSize: UInt32
        var newFrameSize: UInt32
        var kind: Kind = .automatic
    }

    private(set) var calls: [Call] = []

    func notifyBufferIncrease(
        outputName: String,
        previousFrameSize: UInt32,
        newFrameSize: UInt32
    ) {
        calls.append(Call(
            outputName: outputName,
            previousFrameSize: previousFrameSize,
            newFrameSize: newFrameSize
        ))
    }

    func notifyFixedBufferRebuild(
        outputName: String,
        frameSize: UInt32
    ) {
        calls.append(Call(
            outputName: outputName,
            previousFrameSize: frameSize,
            newFrameSize: frameSize,
            kind: .fixedRebuild
        ))
    }

    func notifyTemporaryBufferIncrease(
        outputName: String,
        preferredFrameSize: UInt32,
        runtimeFrameSize: UInt32
    ) {
        calls.append(Call(
            outputName: outputName,
            previousFrameSize: preferredFrameSize,
            newFrameSize: runtimeFrameSize,
            kind: .fixedTemporaryIncrease
        ))
    }
}

private final class FakeStartBlocker: @unchecked Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)

    func waitUntilUnblocked() {
        entered.signal()
        _ = release.wait(timeout: .now() + 5)
    }

    func waitUntilEntered(timeout: DispatchTime) -> Bool {
        entered.wait(timeout: timeout) == .success
    }

    func unblock() {
        release.signal()
    }
}
