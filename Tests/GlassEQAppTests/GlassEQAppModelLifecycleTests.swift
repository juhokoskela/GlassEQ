import CoreAudio
import Foundation
import GlassEQAudio
import GlassEQCore
import GlassEQLicensing
import GlassEQSettingsIPC
import GlassEQSettingsUI
import Observation
import Testing
@testable import GlassEQApp

@MainActor
@Suite
struct GlassEQAppModelLifecycleTests {
    @Test(arguments: [
        kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE, kAudioDeviceTransportTypeUSB,
    ])
    func outputDiagnosticsPublishBluetoothTransportMetadata(transport: UInt32) async {
        let output = makeOutput(uid: "transport-output", name: "Output", transportType: transport)
        let engine = FakeAudioEngine()
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
            engine: engine,
            lookup: FakeDefaultOutputLookup(.success(output)),
            observers: observers,
            outputDelay: .zero
        )
        model.start()
        observers.observers[0].emit(.success(output))
        await waitUntil { model.lifecycleState == .running }

        #expect(model.settingsSnapshot().metrics.diagnostics.route.isBluetoothTransport == output.isBluetoothTransport)
    }

    @Test
    func outputDiagnosticsDescribeTheRuntimeAndSurviveRebuilds() async throws {
        let output = makeOutput(
            uid: "diagnostic-output",
            name: "Diagnostic Output",
            bufferFrameSize: 16,
            transportType: kAudioDeviceTransportTypeUSB
        )
        let engine = FakeAudioEngine()
        engine.reflectPreferredAggregateBufferFrameSize = true
        engine.latencyMetadata = AudioEngineLatencyMetadata(
            physicalDevice: AudioDeviceLatencyMetadata(
                objectID: output.id,
                bufferFrameSize: 16,
                inputStreamChannelCounts: [],
                outputStreamChannelCounts: [2],
                inputLatencyFrames: 0,
                inputSafetyOffsetFrames: 0,
                inputSafetyOffsetSettable: false,
                outputLatencyFrames: 10,
                outputSafetyOffsetFrames: 71,
                outputSafetyOffsetSettable: false
            ),
            aggregateDevice: AudioDeviceLatencyMetadata(
                objectID: 200,
                bufferFrameSize: 16,
                inputStreamChannelCounts: [2],
                outputStreamChannelCounts: [2],
                inputLatencyFrames: 0,
                inputSafetyOffsetFrames: 32,
                inputSafetyOffsetSettable: false,
                outputLatencyFrames: 0,
                outputSafetyOffsetFrames: 64,
                outputSafetyOffsetSettable: false
            )
        )
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
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

        var diagnostics = model.settingsSnapshot().metrics.diagnostics
        #expect(diagnostics.status.health == .stable)
        #expect(diagnostics.status.routeMode == .lowLatency)
        #expect(!diagnostics.status.isUsingSaferBuffer)
        #expect(diagnostics.route.transport == "USB")
        #expect(diagnostics.route.observedDeviceSampleRate == 48_000)
        #expect(diagnostics.route.activeDeviceSampleRate == 48_000)
        #expect(diagnostics.route.physicalOutputStreamChannelCounts == [2])
        #expect(diagnostics.route.aggregateInputSafetyOffsetFrames == 32)
        #expect(diagnostics.recovery.runtimeRebuilds == 0)
        #expect(diagnostics.observation.runtimeStartedAt != nil)

        try model.setAggregateBufferMode(.frames32)
        await waitUntil {
            engine.startCalls.count == 2 && model.currentOutputBufferFrameSize == 32
        }

        diagnostics = model.settingsSnapshot().metrics.diagnostics
        #expect(diagnostics.recovery.runtimeRebuilds == 1)
        #expect(diagnostics.status.isUsingSaferBuffer == false)

        model.resetDiagnostics()
        diagnostics = model.settingsSnapshot().metrics.diagnostics
        #expect(diagnostics.recovery.runtimeRebuilds == 0)
        #expect(diagnostics.observation.runtimeStartedAt != nil)
        #expect(diagnostics.observation.observationDurationSeconds >= 0)
    }

    @Test
    func playbackInstabilityAddsRecoveryAndEscalationContext() async {
        let output = makeOutput(
            uid: "diagnostic-adaptive-output",
            name: "Diagnostic Adaptive Output",
            bufferFrameSize: 480
        )
        let engine = FakeAudioEngine()
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
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
        model.resetDiagnostics()

        var renegotiatedOutput = output
        renegotiatedOutput.bufferFrameSize = 512
        engine.state = .running(output: renegotiatedOutput)
        engine.emitPlaybackBufferRenegotiation(
            PlaybackBufferRenegotiation(
                outputName: output.name,
                outputUID: output.uid,
                sampleRate: output.nominalSampleRate,
                previousFrameSize: 480,
                frameSize: 512,
                previousPlaybackTargetFrames: 512,
                playbackTargetFrames: 1_024,
                cause: .instability(.underrun)
            ))
        await waitUntil {
            model.currentOutputBufferFrameSize == 512
        }

        let recovery = model.settingsSnapshot().metrics.diagnostics.recovery
        #expect(recovery.automaticRecoveries == 1)
        #expect(recovery.bufferEscalations == 1)
        #expect(recovery.lastReason == .playbackUnderrun)
        #expect(recovery.lastRecoveryAt != nil)
    }

    @Test
    func separateClockRenegotiationRefreshesCurrentOutputMetadata() async {
        let output = makeOutput(
            uid: "adaptive-output",
            name: "Adaptive Output",
            bufferFrameSize: 480
        )
        let engine = FakeAudioEngine()
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
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

        engine.emitPlaybackBufferRenegotiation(
            PlaybackBufferRenegotiation(
                outputName: "Other Output",
                outputUID: "other-output",
                sampleRate: 48_000,
                previousFrameSize: 480,
                frameSize: 128,
                playbackTargetFrames: 512,
                cause: .stableDecay
            ))
        await settleAsyncWork()
        #expect(model.currentOutputBufferFrameSize == 480)

        var renegotiatedOutput = output
        renegotiatedOutput.bufferFrameSize = 256
        engine.state = .running(output: renegotiatedOutput)
        engine.emitPlaybackBufferRenegotiation(
            PlaybackBufferRenegotiation(
                outputName: output.name,
                outputUID: output.uid,
                sampleRate: output.nominalSampleRate,
                previousFrameSize: 480,
                frameSize: 256,
                previousPlaybackTargetFrames: 1_024,
                playbackTargetFrames: 512,
                cause: .stableDecay
            ))
        await waitUntil {
            model.currentOutputBufferFrameSize == 256
        }

        #expect(model.settingsSnapshot().currentOutputBufferFrameSize == 256)
    }

    @Test
    func staleSameUIDRenegotiationCannotOverwriteNewOutputFormatMetadata() async {
        let initialOutput = makeOutput(
            uid: "changing-adaptive-output",
            name: "Changing Adaptive Output",
            nominalSampleRate: 48_000,
            bufferFrameSize: 480
        )
        let changedOutput = makeOutput(
            uid: initialOutput.uid,
            name: initialOutput.name,
            nominalSampleRate: 96_000,
            bufferFrameSize: 512
        )
        let engine = FakeAudioEngine()
        let observers = FakeDefaultOutputObserverFactory()
        let lookup = FakeDefaultOutputLookup(.success(initialOutput))
        let model = makeModel(
            engine: engine,
            lookup: lookup,
            observers: observers,
            outputDelay: .zero
        )
        model.start()
        observers.observers[0].emit(.success(initialOutput))
        await waitUntil {
            model.lifecycleState == .running && engine.startCalls.count == 1
        }

        lookup.result = .success(changedOutput)
        observers.observers[0].emit(.success(changedOutput))
        await waitUntil {
            engine.startCalls.count == 2
                && model.currentOutputSampleRate == changedOutput.nominalSampleRate
                && model.currentOutputBufferFrameSize == changedOutput.bufferFrameSize
        }

        engine.emitPlaybackBufferRenegotiation(
            PlaybackBufferRenegotiation(
                outputName: initialOutput.name,
                outputUID: initialOutput.uid,
                sampleRate: initialOutput.nominalSampleRate,
                previousFrameSize: initialOutput.bufferFrameSize,
                frameSize: 128,
                playbackTargetFrames: 512,
                cause: .stableDecay
            ))
        await settleAsyncWork()

        #expect(model.currentOutputSampleRate == changedOutput.nominalSampleRate)
        #expect(model.currentOutputBufferFrameSize == changedOutput.bufferFrameSize)
    }

    @Test
    func renegotiationCannotOverwriteMetadataDuringSameRouteReplacement() async {
        let initialOutput = makeOutput(
            uid: "replacing-adaptive-output",
            name: "Replacing Adaptive Output",
            bufferFrameSize: 480
        )
        let replacementOutput = makeOutput(
            uid: initialOutput.uid,
            name: initialOutput.name,
            bufferFrameSize: 512
        )
        let engine = FakeAudioEngine()
        let observers = FakeDefaultOutputObserverFactory()
        let lookup = FakeDefaultOutputLookup(.success(initialOutput))
        let model = makeModel(
            engine: engine,
            lookup: lookup,
            observers: observers,
            outputDelay: .zero
        )
        model.start()
        observers.observers[0].emit(.success(initialOutput))
        await waitUntil {
            model.lifecycleState == .running && engine.startCalls.count == 1
        }

        engine.blockStart(for: replacementOutput.uid)
        defer { engine.unblockStart(for: replacementOutput.uid) }
        lookup.result = .success(replacementOutput)
        observers.observers[0].emit(.success(replacementOutput))
        await waitUntil {
            engine.startCalls.count == 2
                && model.currentOutputBufferFrameSize == replacementOutput.bufferFrameSize
        }
        #expect(
            engine.waitUntilStartIsBlocked(
                for: replacementOutput.uid,
                timeout: .now() + 1
            ))

        engine.emitPlaybackBufferRenegotiation(
            PlaybackBufferRenegotiation(
                outputName: initialOutput.name,
                outputUID: initialOutput.uid,
                sampleRate: initialOutput.nominalSampleRate,
                previousFrameSize: 256,
                frameSize: initialOutput.bufferFrameSize,
                playbackTargetFrames: 1_024,
                cause: .stableDecay
            ))
        await settleAsyncWork()

        #expect(model.currentOutputBufferFrameSize == replacementOutput.bufferFrameSize)

        engine.unblockStart(for: replacementOutput.uid)
        await waitUntil {
            model.lifecycleState == .running
                && engine.startCalls.count == 2
                && engine.state == .running(output: replacementOutput)
        }
    }

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
        #expect(
            model.statusMessage
                == localized(
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

        #expect(
            engine.events.prefix(3) == [
                "start:\(output.uid)",
                "stop",
                "start:\(output.uid)",
            ])
        model.stop()
    }

    @Test
    func bluetoothCompatibilityWatchdogPreservesTheFixedAggregatePreference() async throws {
        let storeURL = temporaryAppStoreURL()
        defer { removeTemporaryStoreDirectory(for: storeURL) }
        let output = makeOutput(
            uid: "headset-watchdog",
            name: "AirPods Headset",
            nominalSampleRate: 24_000,
            bufferFrameSize: 480,
            transportType: kAudioDeviceTransportTypeBluetooth
        )
        try AggregateBufferPolicyStore(
            url: storeURL.deletingPathExtension().appendingPathExtension("aggregate-buffer-policy.json")
        ).setMode(
            .frames16,
            for: AggregateAudioRouteFingerprint(
                outputDeviceUID: output.uid,
                nativeOutputStreamIndex: 0,
                nominalSampleRate: output.nominalSampleRate
            ))
        let engine = FakeAudioEngine()
        engine.headsetPromotionCandidateUIDs = [output.uid]
        let model = makeModel(
            storeURL: storeURL,
            engine: engine,
            lookup: FakeDefaultOutputLookup(.success(output)),
            renderWatchdogStallThreshold: .milliseconds(50),
            renderWatchdogRepeatedFailureWindow: .seconds(1),
            renderWatchdogPollInterval: .milliseconds(5)
        )
        model.retryAudioEngine()
        await waitUntil { engine.startCalls.count == 2 && model.lifecycleState == .running }
        #expect(engine.isUsingSeparateClockBackend)
        #expect(!model.settingsSnapshot().aggregateBuffer.isAvailable)
        #expect(engine.startCalls.map(\.aggregateBufferFrameSize) == [16, 16])
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
        defer { engine.unblockStart(for: secondOutput.uid) }
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
                && model.settingsSnapshot().aggregateBuffer.isAvailable
        }

        #expect(engine.startCalls.count == 1)
        #expect(model.statusMessage.contains("low-latency headset path"))
    }

    @Test
    func revertedOutputChangeReconcilesCommittedHeadsetPromotion() async {
        let output = makeOutput(
            uid: "headset-promotion-reconcile",
            name: "AirPods Headset",
            nominalSampleRate: 24_000,
            bufferFrameSize: 480
        )
        let transientOutput = makeOutput(uid: "transient-output", name: "Transient")
        let engine = FakeAudioEngine()
        engine.headsetPromotionCandidateUIDs = [output.uid]
        engine.headsetAggregatePromotionResult = .promoted(output)
        engine.blockHeadsetAggregatePromotion()
        defer { engine.unblockHeadsetAggregatePromotion() }
        let lookup = FakeDefaultOutputLookup(.success(output))
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
            engine: engine,
            lookup: lookup,
            observers: observers,
            outputDelay: .seconds(1),
            aggregateStabilityDelay: .seconds(1),
            headsetAggregatePromotionDelay: .zero
        )

        model.start()
        let observer = observers.observers[0]
        observer.emit(.success(output))
        await waitUntil {
            engine.headsetAggregatePromotionAttemptCount == 1
        }
        #expect(
            engine.waitUntilHeadsetAggregatePromotionIsBlocked(
                timeout: .now() + 1
            ))

        lookup.result = .success(transientOutput)
        observer.emit(.success(transientOutput))
        engine.unblockHeadsetAggregatePromotion()
        await waitUntil {
            engine.isUsingPromotedHeadsetAggregate
        }

        lookup.result = .success(output)
        observer.emit(.success(output))
        let reconciled = await waitUntil {
            model.settingsSnapshot().aggregateBuffer.isAvailable
                && model.statusMessage.contains("low-latency headset path")
        }

        #expect(reconciled)
        #expect(engine.headsetAggregatePromotionAttemptCount == 1)
        #expect(model.currentOutputUID == output.uid)
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
    func duplicateOutputNotificationDoesNotDropAnInFlightColdStartupPromotion() async {
        let output = makeOutput(uid: "in-flight-cold-promotion", name: "D10s")
        var promotedOutput = output
        promotedOutput.bufferFrameSize = 32
        let engine = FakeAudioEngine()
        engine.coldStartupPromotionCandidateUIDs = [output.uid]
        engine.coldStartupAggregatePromotionResult = .promoted(promotedOutput)
        engine.blockColdStartupAggregatePromotion()
        defer { engine.unblockColdStartupAggregatePromotion() }
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
            engine.coldStartupAggregatePromotionAttemptCount == 1
        }
        #expect(
            engine.waitUntilColdStartupAggregatePromotionIsBlocked(
                timeout: .now() + 1
            ))

        observers.observers[0].emit(.success(output))
        engine.unblockColdStartupAggregatePromotion()

        let completed = await waitUntil {
            !engine.isDeferringColdStartupAggregate
                && model.settingsSnapshot().aggregateBuffer.isAvailable
                && model.settingsSnapshot().currentOutputBufferFrameSize == 32
        }
        #expect(completed)
        #expect(engine.coldStartupAggregatePromotionAttemptCount == 1)
        #expect(model.statusMessage.contains("Processing D10s"))
    }

    @Test
    func cancelledTransientOutputChangeDoesNotDropAnInFlightColdStartupPromotion() async {
        let output = makeOutput(uid: "reverted-cold-promotion", name: "D10s")
        let transientOutput = makeOutput(uid: "transient-output", name: "Transient")
        var promotedOutput = output
        promotedOutput.bufferFrameSize = 32
        let engine = FakeAudioEngine()
        engine.coldStartupPromotionCandidateUIDs = [output.uid]
        engine.coldStartupAggregatePromotionResult = .promoted(promotedOutput)
        engine.blockColdStartupAggregatePromotion()
        defer { engine.unblockColdStartupAggregatePromotion() }
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
            engine: engine,
            lookup: FakeDefaultOutputLookup(.success(output)),
            observers: observers,
            outputDelay: .seconds(1),
            coldStartupAggregatePromotionPollInterval: .milliseconds(10)
        )

        model.start()
        observers.observers[0].emit(.success(output))
        await waitUntil {
            engine.coldStartupAggregatePromotionAttemptCount == 1
        }
        #expect(
            engine.waitUntilColdStartupAggregatePromotionIsBlocked(
                timeout: .now() + 1
            ))

        observers.observers[0].emit(.success(transientOutput))
        observers.observers[0].emit(.success(output))
        engine.unblockColdStartupAggregatePromotion()

        let completed = await waitUntil {
            !engine.isDeferringColdStartupAggregate
                && model.settingsSnapshot().aggregateBuffer.isAvailable
                && model.settingsSnapshot().currentOutputBufferFrameSize == 32
        }
        #expect(completed)
        #expect(engine.coldStartupAggregatePromotionAttemptCount == 1)
        #expect(model.currentOutputUID == output.uid)
    }

    @Test
    func formatTransitionDoesNotPublishACommittedColdStartupPromotionAfterStopOwnsTheEngine() async {
        let output = makeOutput(
            uid: "stopped-cold-promotion",
            name: "D10s",
            nominalSampleRate: 48_000
        )
        let changedOutput = makeOutput(
            uid: output.uid,
            name: output.name,
            nominalSampleRate: 44_100
        )
        let engine = FakeAudioEngine()
        engine.coldStartupPromotionCandidateUIDs = [output.uid]
        engine.coldStartupAggregatePromotionResult = .promoted(output)
        engine.blockColdStartupAggregatePromotion()
        defer { engine.unblockColdStartupAggregatePromotion() }
        let lookup = FakeDefaultOutputLookup(.success(output))
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
            engine: engine,
            lookup: lookup,
            observers: observers,
            outputDelay: .seconds(1),
            coldStartupAggregatePromotionPollInterval: .milliseconds(10)
        )

        model.start()
        let observer = observers.observers[0]
        observer.emit(.success(output))
        await waitUntil {
            engine.coldStartupAggregatePromotionAttemptCount == 1
        }
        #expect(
            engine.waitUntilColdStartupAggregatePromotionIsBlocked(
                timeout: .now() + 1
            ))

        lookup.result = .success(changedOutput)
        observer.emit(.success(changedOutput))
        await waitUntil {
            model.lifecycleState == .stopped && !model.isRunning
        }
        engine.coldStartupPromotionCandidateUIDs = []
        engine.unblockColdStartupAggregatePromotion()
        await waitUntil {
            engine.stopCallCount == 1 && engine.state == .stopped
        }

        #expect(model.statusMessage == "Audio output format changed; rebuilding...")
        #expect(!model.settingsSnapshot().aggregateBuffer.isAvailable)

        let rebuilt = await waitUntil(maxAttempts: 150) {
            model.lifecycleState == .running
                && engine.startCalls.count == 2
                && model.currentOutputSampleRate == changedOutput.nominalSampleRate
        }
        #expect(rebuilt)
        #expect(
            engine.events == [
                "start:\(output.uid)",
                "stop",
                "start:\(changedOutput.uid)",
            ])
    }

    @Test
    func deferredColdStartupRebuildKeepsTheStoredAggregateBufferPreference() async throws {
        let storeURL = temporaryAppStoreURL()
        defer { removeTemporaryStoreDirectory(for: storeURL) }
        let output = makeOutput(
            uid: "deferred-buffer-preference",
            name: "D10s",
            bufferFrameSize: 512
        )
        let route = AggregateAudioRouteFingerprint(
            outputDeviceUID: output.uid,
            nativeOutputStreamIndex: 0,
            nominalSampleRate: output.nominalSampleRate
        )
        try AggregateBufferPolicyStore(
            url: storeURL.deletingPathExtension()
                .appendingPathExtension("aggregate-buffer-policy.json")
        ).setMode(.frames64, for: route)

        let engine = FakeAudioEngine()
        engine.coldStartupPromotionCandidateUIDs = [output.uid]
        engine.coldStartupAggregatePromotionResult = .clientsActive
        let lookup = FakeDefaultOutputLookup(.success(output))
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
            storeURL: storeURL,
            engine: engine,
            lookup: lookup,
            observers: observers,
            outputDelay: .zero,
            coldStartupAggregatePromotionPollInterval: .milliseconds(10)
        )

        model.start()
        observers.observers[0].emit(.success(output))
        await waitUntil {
            model.lifecycleState == .running
                && engine.startCalls.count == 1
                && engine.isDeferringColdStartupAggregate
        }

        var changedOutput = output
        changedOutput.bufferFrameSize = 256
        lookup.result = .success(changedOutput)
        observers.observers[0].emit(.success(changedOutput))
        await waitUntil {
            model.lifecycleState == .running && engine.startCalls.count == 2
        }

        #expect(engine.startCalls.map(\.aggregateBufferFrameSize) == [64, 64])
        #expect(!model.settingsSnapshot().aggregateBuffer.isAvailable)
    }

    @Test
    func unstableColdStartupPromotionIsNotRetriedAfterARejectedProfileChange() async throws {
        let running = makeProfile(name: "Cold Start Running")
        let requested = makeProfile(name: "Cold Start Requested")
        let output = makeOutput(uid: "unstable-cold-promotion", name: "D10s")
        let store = ProfileStore(
            profiles: [running, requested],
            fallbackProfileID: running.id
        )
        let engine = FakeAudioEngine()
        engine.coldStartupPromotionCandidateUIDs = [output.uid]
        engine.coldStartupAggregatePromotionResult = .aggregateUnstable
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
            engine.coldStartupAggregatePromotionAttemptCount == 1
                && model.statusMessage.contains("startup path was unstable")
        }

        engine.updateDSPResult = false
        engine.updateError = TestAudioError.updateFailed
        engine.updateErrorPreservesRunningState = true
        try model.apply(profile: requested)
        await waitUntil {
            model.statusMessage.contains("not applied")
        }
        try? await Task.sleep(for: .milliseconds(50))

        #expect(engine.coldStartupAggregatePromotionAttemptCount == 1)
        #expect(engine.state == .running(output: output))
    }

    @Test
    func revertedOutputChangePreservesUnstableColdStartupStatus() async {
        let output = makeOutput(uid: "unstable-status-output", name: "D10s")
        let transientOutput = makeOutput(uid: "transient-output", name: "Transient")
        let engine = FakeAudioEngine()
        engine.coldStartupPromotionCandidateUIDs = [output.uid]
        engine.coldStartupAggregatePromotionResult = .aggregateUnstable
        let lookup = FakeDefaultOutputLookup(.success(output))
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
            engine: engine,
            lookup: lookup,
            observers: observers,
            outputDelay: .seconds(1),
            coldStartupAggregatePromotionPollInterval: .milliseconds(10)
        )

        model.start()
        let observer = observers.observers[0]
        observer.emit(.success(output))
        await waitUntil {
            engine.coldStartupAggregatePromotionAttemptCount == 1
                && model.statusMessage.contains("startup path was unstable")
        }

        lookup.result = .success(transientOutput)
        observer.emit(.success(transientOutput))
        await waitUntil {
            model.statusMessage == "Audio output changed; rebuilding..."
        }
        lookup.result = .success(output)
        observer.emit(.success(output))
        let statusWasRestored = await waitUntil {
            model.statusMessage.contains("startup path was unstable")
        }

        #expect(statusWasRestored)
        #expect(engine.coldStartupAggregatePromotionAttemptCount == 1)
        #expect(model.currentOutputUID == output.uid)
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
                && model.settingsSnapshot().aggregateBuffer.isAvailable
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
    func fixedBufferPromotedHeadsetRouteStillFallsBackAfterAClockJump() async throws {
        let storeURL = temporaryAppStoreURL()
        defer { removeTemporaryStoreDirectory(for: storeURL) }
        let output = makeOutput(
            uid: "fixed-headset-demotion",
            name: "Fixed AirPods Headset",
            nominalSampleRate: 24_000,
            bufferFrameSize: 480,
            transportType: kAudioDeviceTransportTypeBluetooth
        )
        try AggregateBufferPolicyStore(
            url: storeURL.deletingPathExtension().appendingPathExtension("aggregate-buffer-policy.json")
        ).setMode(
            .frames16,
            for: AggregateAudioRouteFingerprint(
                outputDeviceUID: output.uid,
                nativeOutputStreamIndex: 0,
                nominalSampleRate: output.nominalSampleRate
            ))
        let engine = FakeAudioEngine()
        engine.headsetPromotionCandidateUIDs = [output.uid]
        engine.headsetAggregatePromotionResult = .promoted(output)
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
            storeURL: storeURL,
            engine: engine,
            lookup: FakeDefaultOutputLookup(.success(output)),
            observers: observers,
            outputDelay: .zero,
            headsetAggregatePromotionDelay: .zero
        )

        model.start()
        observers.observers[0].emit(.success(output))
        await waitUntil {
            engine.headsetAggregatePromotionAttemptCount == 1
                && engine.isUsingPromotedHeadsetAggregate
                && model.settingsSnapshot().aggregateBuffer.isAvailable
        }
        #expect(engine.startCalls.first?.aggregateBufferFrameSize == 16)
        let route = try engine.aggregateRouteFingerprint(for: output)
        let aggregateRoute = try #require(route)

        try model.setAggregateBufferMode(.frames32)
        await waitUntil {
            engine.startCalls.count == 2
                && engine.isUsingPromotedHeadsetAggregate
        }
        try? await Task.sleep(for: .milliseconds(300))

        var metrics = engine.metrics
        metrics.qualifyingPairedTimestampDiscontinuities = 1
        engine.metrics = metrics
        await waitUntil {
            engine.startCalls.count == 3
                && engine.isUsingTransitionalHeadsetBackend
                && model.statusMessage.hasPrefix("Processing")
                && model.statusMessage.contains("compatibility mode")
        }

        let policyURL = storeURL.deletingPathExtension()
            .appendingPathExtension("aggregate-buffer-policy.json")
        let selection = AggregateBufferPolicyStore(url: policyURL).selection(for: aggregateRoute)
        #expect(selection.mode == .frames32)
    }

    @Test
    func failedPromotedHeadsetDemotionStopsTheRejectedGraph() async throws {
        let storeURL = temporaryAppStoreURL()
        defer { removeTemporaryStoreDirectory(for: storeURL) }
        let output = makeOutput(
            uid: "failed-fixed-headset-demotion",
            name: "Failed Fixed AirPods Headset",
            nominalSampleRate: 24_000,
            bufferFrameSize: 480
        )
        let engine = FakeAudioEngine()
        engine.headsetPromotionCandidateUIDs = [output.uid]
        engine.headsetAggregatePromotionResult = .promoted(output)
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
            storeURL: storeURL,
            engine: engine,
            lookup: FakeDefaultOutputLookup(.success(output)),
            observers: observers,
            outputDelay: .zero,
            headsetAggregatePromotionDelay: .zero
        )

        model.start()
        observers.observers[0].emit(.success(output))
        await waitUntil {
            engine.headsetAggregatePromotionAttemptCount == 1
                && engine.isUsingPromotedHeadsetAggregate
                && model.settingsSnapshot().aggregateBuffer.isAvailable
        }

        try model.setAggregateBufferMode(.frames32)
        await waitUntil {
            engine.startCalls.count == 2
                && engine.isUsingPromotedHeadsetAggregate
        }
        try? await Task.sleep(for: .milliseconds(300))

        engine.startError = TestAudioError.startFailed
        engine.startErrorPreservesRunningState = true
        var metrics = engine.metrics
        metrics.qualifyingPairedTimestampDiscontinuities = 1
        engine.metrics = metrics
        await waitUntil {
            engine.startCalls.count == 3
                && engine.stopCallCount == 1
                && model.lifecycleState == .stopped
        }

        #expect(!model.isRunning)
        #expect(engine.state == .stopped)
        #expect(!engine.isUsingPromotedHeadsetAggregate)
    }

    @Test
    func cancelledHeadsetPromotionDelayCanRetryInTheSameOutputGeneration() async throws {
        let active = makeProfile(name: "Headset Active")
        let applied = makeProfile(name: "Headset Applied")
        let output = makeOutput(
            uid: "cancelled-headset-promotion",
            name: "Cancelled AirPods Headset",
            nominalSampleRate: 24_000,
            bufferFrameSize: 480
        )
        let engine = FakeAudioEngine()
        engine.headsetPromotionCandidateUIDs = [output.uid]
        engine.headsetAggregatePromotionResult = .clockUnstable
        engine.updateDSPResult = false
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
            store: ProfileStore(profiles: [active, applied], fallbackProfileID: active.id),
            engine: engine,
            lookup: FakeDefaultOutputLookup(.success(output)),
            observers: observers,
            outputDelay: .zero,
            headsetAggregatePromotionDelay: .milliseconds(200)
        )

        model.start()
        observers.observers[0].emit(.success(output))
        await waitUntil {
            model.lifecycleState == .running && engine.startCalls.count == 1
        }

        try model.apply(profile: applied)
        await waitUntil {
            engine.updateCalls.count == 1 && model.lifecycleState == .running
        }
        await waitUntil {
            engine.headsetAggregatePromotionAttemptCount == 1
        }

        #expect(engine.headsetAggregatePromotionAttemptCount == 1)
    }

    @Test(arguments: [SettingsAggregateBufferMode.automatic, .frames16, .frames128])
    func enablingBypassedBluetoothLoadsTheSavedBufferPolicy(mode: SettingsAggregateBufferMode) async throws {
        let storeURL = temporaryAppStoreURL()
        defer { removeTemporaryStoreDirectory(for: storeURL) }
        var profile = makeProfile(name: "Bypassed Bluetooth")
        profile.isBypassed = true
        let output = makeOutput(
            uid: "bypassed-bluetooth", name: "AirPods", transportType: kAudioDeviceTransportTypeBluetooth)
        try AggregateBufferPolicyStore(
            url: storeURL.deletingPathExtension().appendingPathExtension("aggregate-buffer-policy.json")
        ).setMode(
            mode,
            for: AggregateAudioRouteFingerprint(
                outputDeviceUID: output.uid,
                nativeOutputStreamIndex: 0,
                nominalSampleRate: output.nominalSampleRate
            ))
        let engine = FakeAudioEngine()
        engine.reflectPreferredAggregateBufferFrameSize = true
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
            store: ProfileStore(profiles: [profile], fallbackProfileID: profile.id),
            storeURL: storeURL,
            engine: engine,
            lookup: FakeDefaultOutputLookup(.success(output)),
            observers: observers,
            outputDelay: .zero
        )
        model.start()
        observers.observers[0].emit(.success(output))
        await waitUntil { model.currentOutputUID == output.uid && model.lifecycleState == .stopped }
        #expect(engine.startCalls.isEmpty)

        model.setBypass(false)
        await waitUntil { model.settingsSnapshot().aggregateBuffer.isAvailable }
        let expected: UInt32 = mode == .automatic ? 64 : mode == .frames16 ? 16 : 128
        #expect(engine.startCalls.first?.aggregateBufferFrameSize == expected)
        #expect(model.settingsSnapshot().aggregateBuffer.mode == mode)
        #expect(model.settingsSnapshot().aggregateBuffer.defaultFrameSize == 64)
    }

    @Test(arguments: [kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE])
    func bluetoothUsesAutomaticSixtyFourAndHonorsFixedBuffers(transport: UInt32) async throws {
        let output = makeOutput(uid: "bluetooth-policy", name: "AirPods", transportType: transport)
        let engine = FakeAudioEngine()
        engine.reflectPreferredAggregateBufferFrameSize = true
        let observers = FakeDefaultOutputObserverFactory()
        let lookup = FakeDefaultOutputLookup(.success(output))
        let notifier = FakeAggregateBufferNotifier()
        let model = makeModel(
            engine: engine,
            lookup: lookup,
            observers: observers,
            outputDelay: .zero,
            aggregateBufferNotifier: notifier
        )

        model.start()
        observers.observers[0].emit(.success(output))
        await waitUntil { model.lifecycleState == .running && engine.startCalls.count == 1 }
        #expect(engine.startCalls.last?.aggregateBufferFrameSize == 64)
        #expect(model.settingsSnapshot().aggregateBuffer.defaultFrameSize == 64)
        #expect(model.settingsMetricsSnapshot().diagnostics.status.health == .stable)

        #expect(notifier.bluetoothNoticeCount == (OnboardingState.isComplete ? 1 : 0))

        try model.setAggregateBufferMode(.frames16)
        await waitUntil { model.settingsSnapshot().aggregateBuffer.isAvailable && engine.startCalls.count == 2 }
        #expect(engine.startCalls.last?.aggregateBufferFrameSize == 16)
        #expect(model.settingsSnapshot().aggregateBuffer.mode == .frames16)

        try model.setAggregateBufferMode(.frames128)
        await waitUntil { model.settingsSnapshot().aggregateBuffer.isAvailable && engine.startCalls.count == 3 }
        #expect(engine.startCalls.last?.aggregateBufferFrameSize == 128)

        try model.retryAutomaticAggregateBuffer()
        await waitUntil { model.settingsSnapshot().aggregateBuffer.isAvailable && engine.startCalls.count == 4 }
        #expect(engine.startCalls.last?.aggregateBufferFrameSize == 64)
        #expect(model.settingsSnapshot().aggregateBuffer.mode == .automatic)

        let usb = makeOutput(uid: "usb-policy", name: "USB DAC", transportType: kAudioDeviceTransportTypeUSB)
        let noticesBeforeUSB = notifier.bluetoothNoticeCount
        lookup.result = .success(usb)
        observers.observers[0].emit(.success(usb))
        await waitUntil { model.lifecycleState == .running && engine.startCalls.count == 5 }
        #expect(engine.startCalls.last?.aggregateBufferFrameSize == 16)
        #expect(model.settingsSnapshot().aggregateBuffer.defaultFrameSize == 16)
        #expect(notifier.bluetoothNoticeCount == noticesBeforeUSB)
    }

    @Test
    func automaticAggregateBufferClimbsToOneTwentyEightAfterQualifyingInterruptions() async throws {
        let output = makeOutput(uid: "adaptive-aggregate", name: "Adaptive Aggregate")
        let engine = FakeAudioEngine()
        engine.reflectPreferredAggregateBufferFrameSize = true
        let notifier = FakeAggregateBufferNotifier()
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
            engine: engine,
            observers: observers,
            outputDelay: .zero,
            renderWatchdogPollInterval: .seconds(30),
            aggregateBufferNotifier: notifier
        )

        model.start()
        observers.observers[0].emit(.success(output))
        try #require(
            await waitUntil {
                model.lifecycleState == .running
                    && engine.startCalls.count == 1
                    && engine.startCalls[0].aggregateBufferFrameSize == 16
            })

        for (index, frameSize) in [UInt32(32), 64, 128].enumerated() {
            let baselineCount = engine.snapshotMetricsCallCount
            try #require(await waitUntil { engine.snapshotMetricsCallCount > baselineCount })

            var metrics = engine.metrics
            metrics.qualifyingPairedTimestampDiscontinuities += 1
            engine.metrics = metrics
            let firstInterruptionCount = engine.snapshotMetricsCallCount
            try #require(await waitUntil { engine.snapshotMetricsCallCount > firstInterruptionCount })
            #expect(engine.startCalls.count == index + 1)

            metrics = engine.metrics
            metrics.qualifyingPairedTimestampDiscontinuities += 1
            engine.metrics = metrics
            try #require(
                await waitUntil {
                    engine.startCalls.count == index + 2
                        && engine.startCalls.last?.aggregateBufferFrameSize == frameSize
                        && notifier.calls.count == index + 1
                        && model.settingsSnapshot().aggregateBuffer.automaticFrameSize == frameSize
                })
        }
        #expect(notifier.calls.count == 3)
        #expect(model.settingsSnapshot().aggregateBuffer.automaticFrameSize == 128)
        await model.cleanupForTerminationAndWait()
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
    func retryAfterFixedBufferRecoveryStopRestoresConfiguredRung() async throws {
        let output = makeOutput(uid: "fixed-stop-retry", name: "Fixed Stop Retry")
        let engine = FakeAudioEngine()
        engine.reflectPreferredAggregateBufferFrameSize = true
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
            engine: engine,
            observers: observers,
            outputDelay: .zero
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

        for (misses, expectedStartCount, expectedFrameSize) in [
            (3, 3, UInt32(16)),
            (6, 4, UInt32(32)),
            (9, 5, UInt32(64)),
            (12, 6, UInt32(128)),
        ] {
            try? await Task.sleep(for: .milliseconds(50))
            var metrics = engine.metrics
            metrics.renderDeadlineMisses = UInt64(misses)
            engine.metrics = metrics
            await waitUntil {
                engine.startCalls.count == expectedStartCount
                    && engine.startCalls.last?.aggregateBufferFrameSize == expectedFrameSize
            }
        }

        try? await Task.sleep(for: .milliseconds(50))
        var metrics = engine.metrics
        metrics.renderDeadlineMisses = 15
        engine.metrics = metrics
        await waitUntil {
            model.lifecycleState == .stopped
        }

        model.retryAudioEngine()
        await waitUntil {
            model.lifecycleState == .running && engine.startCalls.count == 7
        }

        #expect(engine.startCalls[6].aggregateBufferFrameSize == 16)
        #expect(model.settingsSnapshot().aggregateBuffer.mode == .frames16)
        #expect(model.settingsSnapshot().currentOutputBufferFrameSize == 16)
    }

    @Test
    func stopDuringPendingFixedRecoveryRestoresConfiguredRungAfterEngineWork() async throws {
        let output = makeOutput(uid: "fixed-pending-stop", name: "Fixed Pending Stop")
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
                && model.settingsSnapshot().aggregateBuffer.isAvailable
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

        try? await Task.sleep(for: .milliseconds(300))
        engine.blockPreferredAggregateBufferFrameSizeWrite(32)
        defer { engine.unblockPreferredAggregateBufferFrameSizeWrite(32) }
        metrics = engine.metrics
        metrics.renderDeadlineMisses = 6
        engine.metrics = metrics
        try? await Task.sleep(for: .milliseconds(350))
        #expect(
            engine.waitUntilPreferredAggregateBufferFrameSizeWriteIsBlocked(
                32,
                timeout: .now() + 1
            ))

        model.stop()
        engine.unblockPreferredAggregateBufferFrameSizeWrite(32)
        await waitUntil {
            model.lifecycleState == .stopped && engine.stopCallCount >= 1
        }

        model.retryAudioEngine()
        await waitUntil {
            model.lifecycleState == .running
                && engine.startCalls.last?.aggregateBufferFrameSize == 16
        }

        #expect(engine.startCalls.last?.aggregateBufferFrameSize == 16)
        #expect(model.settingsSnapshot().aggregateBuffer.mode == .frames16)
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
        #expect(
            try policyStore.recordAutomaticFailure(
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

    @Test(arguments: [UInt32(64), UInt32(512)])
    func automaticCleanSessionsAtTheFloorDoNotRestartForLargerAppliedFrameSize(
        appliedFrameSize: UInt32
    ) async throws {
        let storeURL = temporaryAppStoreURL()
        defer { removeTemporaryStoreDirectory(for: storeURL) }
        let output = makeOutput(
            uid: "stored-clean-rung-\(appliedFrameSize)",
            name: "Stored Clean Rung"
        )
        let engine = FakeAudioEngine()
        engine.forcedAppliedAggregateBufferFrameSize = appliedFrameSize
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
            storeURL: storeURL,
            engine: engine,
            observers: observers,
            outputDelay: .zero,
            aggregateCleanSessionDuration: .zero,
            renderWatchdogPollInterval: .seconds(30)
        )

        model.start()
        observers.observers[0].emit(.success(output))
        await waitUntil {
            model.lifecycleState == .running
                && engine.startCalls.count == 1
                && model.settingsSnapshot().currentOutputBufferFrameSize == appliedFrameSize
        }

        for expectedStartCount in 2...3 {
            let snapshotCount = engine.snapshotMetricsCallCount
            await waitUntil {
                engine.snapshotMetricsCallCount >= snapshotCount + 2
            }
            try model.setAggregateBufferMode(.automatic)
            await waitUntil {
                engine.startCalls.count == expectedStartCount
            }
        }
        let snapshotCount = engine.snapshotMetricsCallCount
        await waitUntil {
            engine.snapshotMetricsCallCount >= snapshotCount + 2
        }
        await settleAsyncWork()

        #expect(
            engine.startCalls.map(\.aggregateBufferFrameSize)
                == [16, 16, 16]
        )
        let selection = AggregateBufferPolicyStore(
            url: storeURL.deletingPathExtension()
                .appendingPathExtension("aggregate-buffer-policy.json")
        ).selection(
            for: AggregateAudioRouteFingerprint(
                outputDeviceUID: output.uid,
                nativeOutputStreamIndex: 0,
                nominalSampleRate: output.nominalSampleRate
            ))
        #expect(selection.automaticFrameSize == 16)
        #expect(model.settingsSnapshot().currentOutputBufferFrameSize == appliedFrameSize)
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
            outputMappings: [
                OutputDeviceProfileMapping(
                    outputDeviceUID: output.uid,
                    profileID: running.id
                )
            ],
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
        defer { engine.unblockStart(for: secondOutput.uid) }
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
        defer { engine.unblockStart(for: secondOutput.uid) }
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

        engine.blockStart(for: firstOutput.uid)
        defer { engine.unblockStart(for: firstOutput.uid) }
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
            outputMappings: [
                OutputDeviceProfileMapping(
                    outputDeviceUID: secondOutput.uid,
                    profileID: routeProfile.id
                )
            ],
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
        defer { engine.unblockUpdate(for: requestedProfile.id) }
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
        defer { engine.unblockStart(for: secondOutput.uid) }
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
        defer { engine.unblockStart(for: secondOutput.uid) }
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
    func settingsCommandsRaiseTheAboutWindowAndSetupGuideWithoutTouchingAudio() async throws {
        let engine = FakeAudioEngine()
        let model = makeModel(engine: engine)

        let aboutResponse = try await model.performSettingsCommand(.showAbout)
        let guideResponse = try await model.performSettingsCommand(.showSetupGuide)

        #expect(aboutResponse.snapshot == nil)
        #expect(guideResponse.snapshot == nil)
        #expect(model.aboutPresentationGeneration == 1)
        #expect(model.onboardingPresentationGeneration == 1)
        #expect(model.onboardingRequestedStep == .welcome)
        #expect(engine.startCalls.isEmpty)
        #expect(engine.stopCallCount == 0)
    }

    @Test
    func manageLicenseOpensTheGuideAtTheActivationStepAndTheNextRequestResetsIt() {
        let model = makeModel()

        model.requestOnboardingPresentation(step: .license)
        #expect(model.onboardingRequestedStep == .license)
        #expect(model.onboardingPresentationGeneration == 1)

        model.requestOnboardingPresentation()
        #expect(model.onboardingRequestedStep == .welcome)
        #expect(model.onboardingPresentationGeneration == 2)
    }

    @Test
    func supportReportCommandRaisesTheWindowAndTheReportOmitsTheOutputUID() async throws {
        let output = makeOutput(uid: "usb-serial-1234", name: "USB DAC")
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(lookup: FakeDefaultOutputLookup(.success(output)), observers: observers)
        model.start()
        observers.observers[0].emit(.success(output))
        await waitUntil { model.lifecycleState == .running }

        let response = try await model.performSettingsCommand(.showSupportReport)
        let text = SupportReport.text(model.supportReportInputs(generatedAt: Date(timeIntervalSince1970: 0)))

        #expect(response.snapshot == nil)
        #expect(model.supportReportPresentationGeneration == 1)
        #expect(text.contains("Output: USB DAC"))
        #expect(!text.contains("usb-serial-1234"))
        #expect(text.contains("Previous run: no unclean exit recorded"))
        #expect(text.contains("Launch: "))
        #expect(text.contains("Audio start requested"))
        #expect(text.contains("Window requested: support report"))
    }

    @Test
    func aStaleLaunchRecordSurfacesTheUncleanRunUntilDismissedAndACleanShutdownClearsIt() async {
        let recordsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlassEQAppTests-\(UUID().uuidString)")
            .appendingPathComponent(LaunchRecordStore.directoryName)
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        // Process 1 is launchd, which is alive, so a dead identifier is written by hand.
        _ = LaunchRecordStore.beginRun(
            in: recordsDirectory, startedAt: startedAt, version: "v0.9 (1)", processIdentifier: 2_147_483_000,
            isProcessAlive: { _ in false })
        let ownRecordURL = LaunchRecordStore.recordURL(
            in: recordsDirectory, processIdentifier: ProcessInfo.processInfo.processIdentifier)

        let model = makeModel(launchRecordsDirectory: recordsDirectory)

        #expect(model.previousRunEndedUncleanly?.startedAt == startedAt)
        #expect(model.previousRunEndedUncleanly?.version == "v0.9 (1)")
        #expect(FileManager.default.fileExists(atPath: ownRecordURL.path))

        model.dismissUncleanTerminationNotice()
        #expect(!model.showsUncleanTerminationNotice)
        #expect(model.previousRunEndedUncleanly?.startedAt == startedAt)
        #expect(
            SupportReport.text(model.supportReportInputs(generatedAt: Date(timeIntervalSince1970: 0)))
                .contains("Previous run: did not quit cleanly"))

        await model.cleanupForTerminationAndWait()
        #expect(!FileManager.default.fileExists(atPath: ownRecordURL.path))
        #expect(model.lifecycleLog.entries.last?.message == "Shutdown complete")
    }

    @Test
    func exportLibraryWritesTheWholeLibraryToTheChosenFile() async throws {
        let storeURL = temporaryAppStoreURL()
        defer { removeTemporaryStoreDirectory(for: storeURL) }
        let room = makeImpulseResponseProfile(name: "Room", sampleRate: 48_000)
        let flat = makeProfile(name: "Flat")
        let store = ProfileStore(
            profiles: [flat, room],
            outputMappings: [OutputDeviceProfileMapping(outputDeviceUID: "speakers", profileID: room.id)],
            fallbackProfileID: flat.id)
        let model = makeModel(store: store, storeURL: storeURL)
        let exportURL = storeURL.deletingLastPathComponent().appendingPathComponent("export.json")
        let panels = FakeLibraryBackupPanels(exportURL: exportURL)

        let response = try await libraryBackupPanelResponse(
            for: .exportLibrary, model: model, chooseExportDestination: panels.chooseExportDestination,
            chooseBackupToImport: panels.chooseBackupToImport)

        #expect(response?.libraryMessage == "Saved 2 profiles to export.json.")
        #expect(panels.suggestedNames.first?.hasPrefix("GlassEQ Library ") == true)
        let backup = try ProfileLibraryBackupCodec.read(from: exportURL)
        #expect(backup.profileStore == model.profileStore)
        #expect(backup.profileStore.profiles[1].convolution == room.convolution)
        #expect(backup.bufferPreferences != nil)
        #expect(model.pendingLibraryImport == nil)
    }

    @Test
    func cancelledLibraryPanelsChangeNothing() async throws {
        let storeURL = temporaryAppStoreURL()
        defer { removeTemporaryStoreDirectory(for: storeURL) }
        let model = makeModel(storeURL: storeURL)
        let panels = FakeLibraryBackupPanels(exportURL: nil, importURL: nil)

        let export = try await libraryBackupPanelResponse(
            for: .exportLibrary, model: model, chooseExportDestination: panels.chooseExportDestination,
            chooseBackupToImport: panels.chooseBackupToImport)
        let choose = try await libraryBackupPanelResponse(
            for: .chooseLibraryBackup, model: model, chooseExportDestination: panels.chooseExportDestination,
            chooseBackupToImport: panels.chooseBackupToImport)

        #expect(export == SettingsCommandResponse())
        #expect(choose == SettingsCommandResponse())
        #expect(model.pendingLibraryImport == nil)
    }

    @Test
    func importLibraryMergeAddsNewProfilesAndKeepsExistingOnes() async throws {
        let storeURL = temporaryAppStoreURL()
        defer { removeTemporaryStoreDirectory(for: storeURL) }
        let mine = makeProfile(name: "Mine")
        let shared = makeProfile(name: "Shared")
        var editedShared = shared
        editedShared.preampDB = -6
        let theirs = makeProfile(name: "Theirs")
        let model = makeModel(
            store: ProfileStore(profiles: [mine, shared], fallbackProfileID: mine.id), storeURL: storeURL)
        let incoming = ProfileStore(
            profiles: [theirs, editedShared],
            outputMappings: [OutputDeviceProfileMapping(outputDeviceUID: "headphones", profileID: theirs.id)],
            fallbackProfileID: theirs.id)
        let importURL = try writeLibraryFile(incoming, beside: storeURL)
        let panels = FakeLibraryBackupPanels(importURL: importURL)

        let choose = try await libraryBackupPanelResponse(
            for: .chooseLibraryBackup, model: model, chooseExportDestination: panels.chooseExportDestination,
            chooseBackupToImport: panels.chooseBackupToImport)
        let preview = try #require(choose?.libraryImportPreview)
        #expect(preview.filename == "library.json")
        #expect(preview.profileCount == 2)
        #expect(preview.merge.addedProfiles == 1)
        #expect(preview.merge.copiedProfiles == 1)
        #expect(preview.merge.addedMappings == 1)
        #expect(!preview.merge.exceedsProfileLimit)
        #expect(model.pendingLibraryImport?.filename == "library.json")

        let applied = try await model.performSettingsCommand(.applyLibraryImport(.merge))

        #expect(
            applied.libraryMessage
                == "Imported from library.json: added 1 profiles, added 1 as copies, assigned 1 outputs.")
        #expect(model.profileStore.profiles.map(\.name) == ["Mine", "Shared", "Theirs", "Shared (imported)"])
        #expect(model.profileStore.fallbackProfileID == mine.id)
        #expect(model.profileStore.profile(forOutputUID: "headphones") == theirs)
        #expect(model.activeProfile == mine)
        #expect(model.pendingLibraryImport == nil)
        #expect(ProfilePersistence.load(from: storeURL).store == model.profileStore)
    }

    @Test
    func importLibraryReplaceBacksUpTheCurrentLibraryFirst() async throws {
        let storeURL = temporaryAppStoreURL()
        defer { removeTemporaryStoreDirectory(for: storeURL) }
        let mine = makeProfile(name: "Mine")
        let current = ProfileStore(profiles: [mine], fallbackProfileID: mine.id)
        let model = makeModel(store: current, storeURL: storeURL)
        let theirs = makeProfile(name: "Theirs")
        let incoming = ProfileStore(profiles: [theirs], fallbackProfileID: theirs.id)
        let panels = FakeLibraryBackupPanels(importURL: try writeLibraryFile(incoming, beside: storeURL))

        _ = try await libraryBackupPanelResponse(
            for: .chooseLibraryBackup, model: model, chooseExportDestination: panels.chooseExportDestination,
            chooseBackupToImport: panels.chooseBackupToImport)
        let applied = try await model.performSettingsCommand(.applyLibraryImport(.replace))

        #expect(model.profileStore == incoming)
        #expect(model.activeProfile == theirs)
        #expect(model.selectedProfileID == theirs.id)
        #expect(ProfilePersistence.load(from: storeURL).store == incoming)
        let backupsDirectory = LibraryBackupFile.automaticBackupsDirectory(besideStoreAt: storeURL)
        let backups = try FileManager.default.contentsOfDirectory(atPath: backupsDirectory.path)
        #expect(backups.count == 1)
        let backupName = try #require(backups.first)
        #expect(applied.libraryMessage?.hasSuffix("The previous library was saved as \(backupName).") == true)
        let backup = try ProfileLibraryBackupCodec.read(from: backupsDirectory.appendingPathComponent(backupName))
        #expect(backup.profileStore == current)
    }

    @Test
    func aFailedLibrarySaveLeavesTheLibraryUntouched() async throws {
        let storeURL = temporaryAppStoreURL()
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: storeURL.deletingLastPathComponent().path)
            removeTemporaryStoreDirectory(for: storeURL)
        }
        let mine = makeProfile(name: "Mine")
        let current = ProfileStore(profiles: [mine], fallbackProfileID: mine.id)
        let model = makeModel(store: current, storeURL: storeURL)
        let theirs = makeProfile(name: "Theirs")
        let panels = FakeLibraryBackupPanels(
            importURL: try writeLibraryFile(ProfileStore(profiles: [theirs]), beside: storeURL))
        _ = try await libraryBackupPanelResponse(
            for: .chooseLibraryBackup, model: model, chooseExportDestination: panels.chooseExportDestination,
            chooseBackupToImport: panels.chooseBackupToImport)
        try ProfilePersistence.save(current, to: storeURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555], ofItemAtPath: storeURL.deletingLastPathComponent().path)

        await #expect(throws: (any Error).self) {
            _ = try await model.performSettingsCommand(.applyLibraryImport(.merge))
        }

        #expect(model.profileStore == current)
        #expect(model.activeProfile == mine)
        #expect(model.pendingLibraryImport == nil)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: storeURL.deletingLastPathComponent().path)
        #expect(ProfilePersistence.load(from: storeURL).store == current)
    }

    @Test
    func libraryImportNeedsAStagedFileAndCancelDropsIt() async throws {
        let storeURL = temporaryAppStoreURL()
        defer { removeTemporaryStoreDirectory(for: storeURL) }
        let model = makeModel(storeURL: storeURL)
        let before = model.profileStore

        await #expect(throws: SettingsCommandFailure.self) {
            _ = try await model.performSettingsCommand(.applyLibraryImport(.merge))
        }

        let theirs = makeProfile(name: "Theirs")
        let panels = FakeLibraryBackupPanels(
            importURL: try writeLibraryFile(ProfileStore(profiles: [theirs]), beside: storeURL))
        _ = try await libraryBackupPanelResponse(
            for: .chooseLibraryBackup, model: model, chooseExportDestination: panels.chooseExportDestination,
            chooseBackupToImport: panels.chooseBackupToImport)
        #expect(model.pendingLibraryImport != nil)

        _ = try await model.performSettingsCommand(.cancelLibraryImport)

        #expect(model.pendingLibraryImport == nil)
        #expect(model.profileStore == before)
    }

    @Test
    func damagedLibraryFilesAreRefusedWithTheirReason() async throws {
        let storeURL = temporaryAppStoreURL()
        defer { removeTemporaryStoreDirectory(for: storeURL) }
        let model = makeModel(storeURL: storeURL)
        let importURL = storeURL.deletingLastPathComponent().appendingPathComponent("library.json")
        try Data("{\"format\":\"glasseq-profile-library\",\"version\":9}".utf8).write(to: importURL)
        let panels = FakeLibraryBackupPanels(importURL: importURL)

        await #expect(
            throws: ProfileLibraryBackupError.unsupportedVersion(version: 9, maximum: 1)
        ) {
            _ = try await libraryBackupPanelResponse(
                for: .chooseLibraryBackup, model: model, chooseExportDestination: panels.chooseExportDestination,
                chooseBackupToImport: panels.chooseBackupToImport)
        }
        #expect(model.pendingLibraryImport == nil)
    }

    @Test
    func protectedStoreRefusesLibraryExportAndImport() async throws {
        let storeURL = temporaryAppStoreURL()
        defer { removeTemporaryStoreDirectory(for: storeURL) }
        let futureProfile = makeProfile(name: "Future Profile")
        let futureStore = ProfileStore(
            schemaVersion: ProfileStore.currentSchemaVersion + 1,
            profiles: [futureProfile],
            fallbackProfileID: futureProfile.id)
        try FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ProfilePersistence.encoder.encode(futureStore).write(to: storeURL)
        let model = GlassEQAppModel(
            storeURL: storeURL,
            engine: FakeAudioEngine(),
            defaultOutputLookup: FakeDefaultOutputLookup(.success(makeOutput())),
            observerFactory: FakeDefaultOutputObserverFactory(),
            autoStart: false,
            installLifecycleObservers: false,
            registerAppDelegate: false,
            launchRecordsDirectory: storeURL.deletingPathExtension().appendingPathExtension("launch-records")
        )
        #expect(model.settingsSnapshot().profileStoreProtection.isProtected)
        let panels = FakeLibraryBackupPanels(
            exportURL: storeURL.deletingLastPathComponent().appendingPathComponent("export.json"),
            importURL: try writeLibraryFile(ProfileStore(profiles: [makeProfile(name: "Theirs")]), beside: storeURL))

        await #expect(throws: SettingsCommandFailure.self) {
            _ = try await libraryBackupPanelResponse(
                for: .exportLibrary, model: model, chooseExportDestination: panels.chooseExportDestination,
                chooseBackupToImport: panels.chooseBackupToImport)
        }
        await #expect(throws: SettingsCommandFailure.self) {
            _ = try await libraryBackupPanelResponse(
                for: .chooseLibraryBackup, model: model, chooseExportDestination: panels.chooseExportDestination,
                chooseBackupToImport: panels.chooseBackupToImport)
        }
        #expect(panels.suggestedNames.isEmpty)
        #expect(panels.importRequests == 0)
    }

    @Test
    func sourceBuildsHaveNoLicenseSummary() {
        let model = makeModel(licensing: .disabled)

        #expect(model.licenseSummaryMessage == nil)
        #expect(model.onboardingLicenseState == nil)
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
        #expect(engine.programmeComparisonReferences == [draft.filtersOffReference])
        #expect(engine.programmeComparisonSelections == [.equalized])
        #expect(model.activeProfile == active)
        #expect(model.settingsSnapshot().programmeComparison.isActive)

        model.selectProgrammeComparison(.reference)
        #expect(engine.programmeComparisonSelections == [.equalized, .reference])
        #expect(model.settingsSnapshot().programmeComparison.selection == .reference)
        let settingsModel = model.inProcessSettingsViewModel()

        engine.programmeComparisonSnapshot = EQProgrammeComparisonSnapshot(
            isActive: true,
            isReady: true,
            selection: .reference
        )
        await waitUntil {
            model.settingsSnapshot().programmeComparison.isReady
        }
        #expect(settingsModel.snapshot.programmeComparison.isReady)

        let publishedComparison = model.programmeComparison
        let publishedRevision = settingsModel.profileSnapshotRevision
        let nextPoll = engine.snapshotProgrammeComparisonCallCount + 1
        await waitUntil {
            engine.snapshotProgrammeComparisonCallCount >= nextPoll
        }
        #expect(engine.snapshotProgrammeComparisonCallCount >= nextPoll)
        #expect(model.programmeComparison == publishedComparison)
        #expect(settingsModel.profileSnapshotRevision == publishedRevision)

        engine.programmeComparisonSnapshot.isReady = false
        await waitUntil {
            !model.programmeComparison.isReady
        }
        #expect(!settingsModel.snapshot.programmeComparison.isReady)

        model.stopProgrammeComparison()

        #expect(engine.programmeComparisonSelections.last == .equalized)
        #expect(engine.updateDSPCalls.last == active)
        #expect(!model.settingsSnapshot().programmeComparison.isActive)
        #expect(model.activeProfile == active)
    }

    @Test
    func applyingAProfileEndsTheProgrammeComparison() async throws {
        let active = makeProfile(name: "Active")
        let output = makeOutput(uid: "comparison-apply-output", name: "Comparison Apply Output")
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
        try model.startProgrammeComparison(profile: draft)
        model.selectProgrammeComparison(.reference)
        #expect(model.settingsSnapshot().programmeComparison.isActive)

        try model.apply(profile: draft)

        #expect(!model.settingsSnapshot().programmeComparison.isActive)
        #expect(engine.programmeComparisonSelections.last == .equalized)
        #expect(engine.updateDSPCalls.last == draft)
        #expect(model.activeProfile == draft)
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
        model.selectProgrammeComparison(.reference)

        lookup.result = .success(secondOutput)
        observer.emit(.success(secondOutput))
        await waitUntil {
            model.lifecycleState == .running
                && model.currentOutputUID == secondOutput.uid
                && engine.startCalls.count == 2
        }

        #expect(!model.settingsSnapshot().programmeComparison.isActive)
        #expect(model.activeProfile == secondProfile)
        #expect(
            engine.programmeComparisonSelections == [
                .equalized,
                .reference,
                .equalized,
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
        model.selectProgrammeComparison(.reference)

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
    func runningOutputFormatChangeStopsImmediatelyThenRebuildsSettledOutput() async {
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
            engine.stopCallCount == 1
        }
        #expect(engine.muteOutputCallCount == 0)

        await waitUntil {
            engine.startCalls.map(\.output) == [initialOutput, changedOutput]
        }

        #expect(model.currentOutputSampleRate == changedOutput.nominalSampleRate)
        #expect(model.currentOutputBufferFrameSize == changedOutput.bufferFrameSize)
        #expect(engine.events == ["start:\(initialOutput.uid)", "stop", "start:\(changedOutput.uid)"])
    }

    @Test(arguments: [false, true])
    func bypassDuringFormatSettlementPreservesSettledOutput(
        reenableBeforeSettlement: Bool
    ) async {
        let initialOutput = makeOutput(
            uid: "bypass-settlement-output",
            name: "USB DAC",
            nominalSampleRate: 48_000,
            bufferFrameSize: 256
        )
        let changedOutput = makeOutput(
            uid: initialOutput.uid,
            name: initialOutput.name,
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
            outputDelay: .milliseconds(300)
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
            model.lifecycleState == .stopped && engine.stopCallCount == 1
        }

        model.setBypass(true)
        if reenableBeforeSettlement {
            model.setBypass(false)
        }
        try? await Task.sleep(for: .milliseconds(100))

        #expect(engine.startCalls.map(\.output) == [initialOutput])
        #expect(model.currentOutputSampleRate == initialOutput.nominalSampleRate)

        if reenableBeforeSettlement {
            await waitUntil {
                model.lifecycleState == .running
                    && model.currentOutputSampleRate == changedOutput.nominalSampleRate
                    && engine.startCalls.count == 2
            }
            #expect(engine.startCalls.map(\.output) == [initialOutput, changedOutput])
            #expect(
                engine.events == [
                    "start:\(initialOutput.uid)",
                    "stop",
                    "start:\(changedOutput.uid)",
                ])
        } else {
            await waitUntil {
                model.currentOutputSampleRate == changedOutput.nominalSampleRate
            }
            #expect(model.activeProfile.isBypassed)
            #expect(model.lifecycleState == .stopped)
            #expect(engine.startCalls.map(\.output) == [initialOutput])
            #expect(engine.events == ["start:\(initialOutput.uid)", "stop"])
        }
        #expect(model.currentOutputBufferFrameSize == changedOutput.bufferFrameSize)
    }

    @Test(arguments: [
        DefaultOutputDeviceChangeReason.streamConfiguration,
        .deviceAlive,
    ])
    func semanticOutputChangeRebuildsEvenWhenDeviceMetadataIsUnchanged(
        reason: DefaultOutputDeviceChangeReason
    ) async throws {
        let output = makeOutput(
            uid: "semantic-change-output",
            name: "USB DAC",
            id: 200,
            nominalSampleRate: 48_000,
            bufferFrameSize: 256
        )
        let settlement = OutputSettlementGate()
        defer { settlement.release() }
        let engine = FakeAudioEngine()
        let lookup = FakeDefaultOutputLookup(.success(output))
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
            engine: engine,
            lookup: lookup,
            observers: observers,
            outputSleep: { await settlement.sleep(for: $0) }
        )

        model.start()
        let observer = observers.observers[0]
        observer.emit(.success(output))
        await waitUntil {
            model.lifecycleState == .running && engine.startCalls.count == 1
        }

        settlement.hold()
        observer.emit(.success(output), reason: reason)

        try #require(
            await waitUntil {
                engine.stopCallCount == 1 && settlement.waitCount == 1
            })
        #expect(engine.startCalls.count == 1)
        settlement.release()

        await waitUntil {
            engine.startCalls.count == 2 && model.lifecycleState == .running
        }

        #expect(engine.startCalls.map(\.output) == [output, output])
        #expect(engine.events == ["start:\(output.uid)", "stop", "start:\(output.uid)"])
    }

    @Test
    func profileEditDuringStoppedFormatSettlementWaitsForTheSettledRebuild() async throws {
        let profile = makeProfile(name: "Initial")
        let store = ProfileStore(profiles: [profile], fallbackProfileID: profile.id)
        let initialOutput = makeOutput(
            uid: "settling-profile-output",
            name: "USB DAC",
            nominalSampleRate: 48_000
        )
        let changedOutput = makeOutput(
            uid: initialOutput.uid,
            name: initialOutput.name,
            nominalSampleRate: 44_100
        )
        let engine = FakeAudioEngine()
        let lookup = FakeDefaultOutputLookup(.success(initialOutput))
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
            store: store,
            engine: engine,
            lookup: lookup,
            observers: observers,
            outputDelay: .milliseconds(300)
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
            model.lifecycleState == .stopped
                && !model.isRunning
                && engine.stopCallCount == 1
        }

        var editedProfile = profile
        editedProfile.name = "Edited During Settlement"
        engine.updateDSPResult = false
        try model.apply(profile: editedProfile)
        try? await Task.sleep(for: .milliseconds(100))

        #expect(engine.updateDSPCalls.isEmpty)
        #expect(engine.startCalls.count == 1)

        let rebuilt = await waitUntil {
            model.lifecycleState == .running && engine.startCalls.count == 2
        }
        #expect(rebuilt)
        #expect(engine.startCalls[1].profile == editedProfile)
        #expect(
            engine.events == [
                "start:\(initialOutput.uid)",
                "stop",
                "start:\(changedOutput.uid)",
            ])
    }

    @Test
    func formatChangeDuringInFlightStartStopsThatGraphBeforeSettledRebuild() async {
        let initialOutput = makeOutput(
            uid: "in-flight-format-output",
            name: "USB DAC",
            nominalSampleRate: 44_100
        )
        let changedOutput = makeOutput(
            uid: initialOutput.uid,
            name: initialOutput.name,
            nominalSampleRate: 48_000
        )
        let engine = FakeAudioEngine()
        engine.blockStart(for: initialOutput.uid)
        defer { engine.unblockStart(for: initialOutput.uid) }
        let lookup = FakeDefaultOutputLookup(.success(initialOutput))
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
            engine: engine,
            lookup: lookup,
            observers: observers
        )

        model.start()
        let observer = observers.observers[0]
        observer.emit(.success(initialOutput))
        await waitUntil {
            engine.startCalls.count == 1
        }
        #expect(
            engine.waitUntilStartIsBlocked(
                for: initialOutput.uid,
                timeout: .now() + 1
            ))

        lookup.result = .success(changedOutput)
        observer.emit(.success(changedOutput))
        await waitUntil {
            model.lifecycleState == .stopped
                && !model.isRunning
                && model.statusMessage == "Audio output format changed; rebuilding..."
        }
        engine.unblockStart(for: initialOutput.uid)
        await waitUntil {
            engine.stopCallCount == 1
        }
        try? await Task.sleep(for: .milliseconds(100))

        #expect(engine.startCalls.count == 1)
        #expect(engine.events == ["start:\(initialOutput.uid)", "stop"])

        let rebuilt = await waitUntil {
            model.lifecycleState == .running
                && engine.startCalls.count == 2
                && model.currentOutputSampleRate == changedOutput.nominalSampleRate
        }
        #expect(rebuilt)
        #expect(
            engine.events == [
                "start:\(initialOutput.uid)",
                "stop",
                "start:\(changedOutput.uid)",
            ])
    }

    @Test
    func returningToOriginalFormatAfterTransitionStopStillRebuilds() async throws {
        let runningOutput = makeOutput(
            uid: "same-output",
            name: "USB DAC",
            id: 200,
            nominalSampleRate: 44_100
        )
        let transientOutput = makeOutput(
            uid: runningOutput.uid,
            name: runningOutput.name,
            id: runningOutput.id,
            nominalSampleRate: 48_000
        )
        let settlement = OutputSettlementGate()
        defer { settlement.release() }
        let engine = FakeAudioEngine()
        let lookup = FakeDefaultOutputLookup(.success(runningOutput))
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
            engine: engine,
            lookup: lookup,
            observers: observers,
            outputSleep: { await settlement.sleep(for: $0) },
            renderWatchdogPollInterval: .seconds(30)
        )

        model.start()
        let observer = observers.observers[0]
        observer.emit(.success(runningOutput))
        await waitUntil {
            model.lifecycleState == .running && engine.startCalls.count == 1
        }

        settlement.hold()
        lookup.result = .success(transientOutput)
        observer.emit(.success(transientOutput))
        try #require(
            await waitUntil {
                engine.stopCallCount == 1 && settlement.waitCount == 1
            })

        lookup.result = .success(runningOutput)
        observer.emit(.success(runningOutput))
        try #require(await waitUntil { settlement.waitCount == 2 })
        settlement.release()
        await waitUntil {
            engine.startCalls.count == 2 && model.lifecycleState == .running
        }

        #expect(engine.startCalls.map(\.output) == [runningOutput, runningOutput])
        #expect(engine.resumeOutputCallCount == 0)
        #expect(
            engine.events == [
                "start:\(runningOutput.uid)",
                "stop",
                "start:\(runningOutput.uid)",
            ])
        #expect(model.lifecycleState == .running)
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
            outputDelay: .seconds(1)
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
            model.statusMessage == "Audio output changed; rebuilding..."
        }

        lookup.result = .success(runningOutput)
        observer.emit(.success(runningOutput))
        await waitUntil {
            engine.resumeOutputCallCount == 1
        }
        try? await Task.sleep(for: .milliseconds(1_100))

        #expect(engine.startCalls.map(\.output) == [runningOutput])
        #expect(engine.events == ["start:\(runningOutput.uid)", "mute", "resume"])
        #expect(model.lifecycleState == .running)
    }

    @Test
    func revertingUnmutedBufferChangeDoesNotReprimePlayback() async {
        let runningOutput = makeOutput(
            uid: "running-output",
            name: "USB DAC",
            id: 200,
            bufferFrameSize: 256
        )
        let transientOutput = makeOutput(
            uid: runningOutput.uid,
            name: runningOutput.name,
            id: runningOutput.id,
            bufferFrameSize: 512
        )
        let engine = FakeAudioEngine()
        let lookup = FakeDefaultOutputLookup(.success(runningOutput))
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
            engine: engine,
            lookup: lookup,
            observers: observers,
            outputDelay: .seconds(1)
        )

        model.start()
        let observer = observers.observers[0]
        observer.emit(.success(runningOutput))
        await waitUntil {
            model.lifecycleState == .running && engine.startCalls.count == 1
        }

        lookup.result = .success(transientOutput)
        observer.emit(.success(transientOutput))
        await settleAsyncWork()
        lookup.result = .success(runningOutput)
        observer.emit(.success(runningOutput))
        try? await Task.sleep(for: .milliseconds(1_100))

        #expect(engine.startCalls.map(\.output) == [runningOutput])
        #expect(engine.muteOutputCallCount == 0)
        #expect(engine.resumeOutputCallCount == 0)
        #expect(engine.events == ["start:\(runningOutput.uid)"])
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
        defer { engine.unblockStart(for: firstOutput.uid) }
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
                && model.statusMessage
                    == localized(
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
        defer { engine.unblockStart(for: output.uid) }
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
    func sleepAndWakeCreateAFreshObserverGeneration() async {
        let output = makeOutput(uid: "wake-output", name: "Wake Output")
        let fallback = makeProfile(name: "Fallback")
        let store = ProfileStore(profiles: [fallback], fallbackProfileID: fallback.id)
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
        model.start()
        let preSleepObserver = observers.observers[0]

        model.handleWillSleep()
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
        defer { engine.unblockStart(for: output.uid) }
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

        await #expect(
            throws: ProfileStoreValidationError.tooManyFilters(
                profileID: overloaded.id,
                channel: "linked",
                count: ProfilePersistence.maxFiltersPerChannel + 1,
                maximum: ProfilePersistence.maxFiltersPerChannel
            )
        ) {
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

        await #expect(
            throws: ProfileStoreValidationError.invalidProfileCount(
                count: ProfilePersistence.profileCountRange.upperBound + 1,
                allowed: ProfilePersistence.profileCountRange
            )
        ) {
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
    func oversizedStoreIsProtectedFromImplicitWrites() async throws {
        let storeURL = temporaryAppStoreURL()
        defer { removeTemporaryStoreDirectory(for: storeURL) }
        let oversizedData = Data(
            repeating: 0,
            count: ProfilePersistence.maxStoreBytes + 1
        )
        try FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try oversizedData.write(to: storeURL)

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
        #expect(await model.flushStoreBeforeQuit())
        await #expect(throws: SettingsCommandFailure.self) {
            _ = try await model.performSettingsCommand(.createProfile(.parametric))
        }
        #expect(try Data(contentsOf: storeURL) == oversizedData)
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
            outputMappings: [
                OutputDeviceProfileMapping(
                    outputDeviceUID: output.uid,
                    profileID: running.id
                )
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
        engine.blockUpdate(for: requested.id)
        defer { engine.unblockUpdate(for: requested.id) }

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
        defer { engine.unblockUpdate(for: requested.id) }

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
            outputMappings: [
                OutputDeviceProfileMapping(
                    outputDeviceUID: output.uid,
                    profileID: mapped.id
                )
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
        try model.apply(profile: running)
        #expect(model.activeProfile == running)

        engine.updateDSPResult = false
        engine.updateError = TestAudioError.updateFailed
        engine.updateErrorPreservesRunningState = true
        engine.blockUpdate(for: requested.id)
        defer { engine.unblockUpdate(for: requested.id) }
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
        defer { engine.unblockUpdate(for: attempted.id) }

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
        defer { engine.unblockUpdate(for: requested.id) }

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

        await #expect(
            throws: ProfileStoreValidationError.invalidProfileCount(
                count: ProfilePersistence.profileCountRange.upperBound + 1,
                allowed: ProfilePersistence.profileCountRange
            )
        ) {
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
            convolution: .impulseResponse(
                ImpulseResponseSource(
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
    func incompatibleImpulseResponseCannotBeAppliedComparedOrMapped() async throws {
        let fallback = makeProfile(name: "Fallback")
        let impulse = makeImpulseResponseProfile(name: "48 kHz IR", sampleRate: 48_000)
        let store = ProfileStore(
            profiles: [fallback, impulse],
            fallbackProfileID: fallback.id
        )
        let output = makeOutput(
            uid: "rate-mismatch-output",
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

        let applyFailure = #expect(throws: SettingsCommandFailure.self) {
            try model.apply(profile: impulse)
        }
        #expect(throws: SettingsCommandFailure.self) {
            try model.useForCurrentOutput(profile: impulse)
        }

        #expect(throws: SettingsCommandFailure.self) {
            try model.startProgrammeComparison(profile: impulse)
        }
        #expect(model.profileStore == store)
        #expect(model.activeProfile == fallback)
        #expect(engine.updateDSPCalls.isEmpty)
        #expect(engine.programmeComparisonCalls.isEmpty)
        #expect(applyFailure?.message.contains("48") == true)
        #expect(applyFailure?.message.contains("44") == true)
    }

    @Test
    func impulseResponseCompatibilityUsesTheActiveDSPRateForConvertedOutput() throws {
        let fallback = makeProfile(name: "Fallback")
        let compatible = makeImpulseResponseProfile(name: "48 kHz IR", sampleRate: 48_000)
        let incompatible = makeImpulseResponseProfile(name: "24 kHz IR", sampleRate: 24_000)
        let output = makeOutput(
            uid: "converted-output",
            name: "Bluetooth headset",
            nominalSampleRate: 24_000
        )
        let engine = FakeAudioEngine()
        engine.state = .running(output: output)
        engine.processingSampleRate = 48_000
        let model = makeModel(
            store: ProfileStore(profiles: [fallback, compatible, incompatible]),
            engine: engine
        )
        model.currentOutputUID = output.uid
        model.currentOutputSampleRate = output.nominalSampleRate
        model.currentOutputChannelCount = output.outputChannelCount

        try model.apply(profile: compatible)

        #expect(model.activeProfile == compatible)
        #expect(throws: SettingsCommandFailure.self) {
            try model.apply(profile: incompatible)
        }
        #expect(model.activeProfile == compatible)
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

        #expect(model.lifecycleState == .stopped)
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
    func onboardingAudioStateReportsObserverStartupFailure() async {
        let observers = FakeDefaultOutputObserverFactory(
            startError: TestAudioError.startFailed
        )
        let model = makeModel(observers: observers)

        #expect(model.onboardingAudioCaptureState == .idle)
        model.startAudioForOnboarding()
        #expect(model.onboardingAudioCaptureState == .pending)

        await waitUntil {
            if case .failed = model.onboardingAudioCaptureState {
                return true
            }
            return false
        }

        guard case .failed(let message) = model.onboardingAudioCaptureState else {
            Issue.record("Expected observer startup failure")
            return
        }
        #expect(message.contains("Default output observer failed"))
    }

    @Test
    func onboardingAudioStateReportsDefaultOutputFailure() async {
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
            lookup: FakeDefaultOutputLookup(.failure(TestAudioError.defaultOutputUnavailable)),
            observers: observers,
            outputDelay: .zero
        )

        model.startAudioForOnboarding()
        observers.observers[0].emit(.failure(TestAudioError.defaultOutputUnavailable))

        await waitUntil {
            if case .failed = model.onboardingAudioCaptureState {
                return true
            }
            return false
        }

        guard case .failed(let message) = model.onboardingAudioCaptureState else {
            Issue.record("Expected default output failure")
            return
        }
        #expect(message.contains("Default output unavailable"))
    }

    @Test
    func onboardingAudioStateClearsPermissionFailureWhenRetrying() async {
        let output = makeOutput(name: "Permission Output")
        let engine = FakeAudioEngine()
        engine.startError = CoreAudioError(
            operation: "AudioHardwareCreateProcessTap",
            status: kAudioDevicePermissionsError
        )
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
            engine: engine,
            lookup: FakeDefaultOutputLookup(.success(output)),
            observers: observers,
            outputDelay: .zero
        )

        model.startAudioForOnboarding()
        observers.observers[0].emit(.success(output))
        await waitUntil {
            if case .permissionDenied = model.onboardingAudioCaptureState {
                return true
            }
            return false
        }

        #expect(model.onboardingAudioCaptureState == .permissionDenied(settingsError: nil))

        engine.startError = nil
        model.startAudioForOnboarding()
        #expect(model.onboardingAudioCaptureState == .pending)
        await waitUntil {
            model.onboardingAudioCaptureState == .running(outputName: output.name)
        }

        #expect(model.onboardingAudioCaptureState == .running(outputName: output.name))
    }

    @Test
    func onboardingAudioStateReportsBypassedProfile() async {
        var profile = makeProfile(name: "Disabled")
        profile.isBypassed = true
        let output = makeOutput()
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
            store: ProfileStore(profiles: [profile], fallbackProfileID: profile.id),
            lookup: FakeDefaultOutputLookup(.success(output)),
            observers: observers,
            outputDelay: .zero
        )

        model.startAudioForOnboarding()
        observers.observers[0].emit(.success(output))
        await waitUntil {
            model.onboardingAudioCaptureState == .bypassed
        }

        #expect(model.onboardingAudioCaptureState == .bypassed)
    }

    @Test
    func onboardingPrivacySettingsFailureRemainsVisibleUntilOpeningSucceeds() {
        let opener = FakeWorkspaceOpener(results: [false, false, true])
        let model = makeModel(workspaceOpener: opener)

        model.openPrivacySettingsForOnboarding()

        guard case .permissionDenied(let settingsError) = model.onboardingAudioCaptureState else {
            Issue.record("Expected a visible privacy settings failure")
            return
        }
        #expect(settingsError?.contains("Could not open System Settings") == true)

        model.openPrivacySettingsForOnboarding()

        #expect(model.onboardingAudioCaptureState == .permissionDenied(settingsError: nil))
        #expect(opener.openedURLs.count == 3)
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
        #expect(loaded.profiles.contains { $0.name == "New Convolution" })
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
            try await model.performSettingsCommand(
                .importProfile(
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
    func settingsFilePickerIsRejectedAfterShutdownBegins() async {
        let model = makeModel()
        await model.stopAcceptingSettingsCommandsAndWait()
        var pickerCallCount = 0

        await #expect(throws: SettingsCommandFailure.self) {
            _ = try await fileImportPickerResponse(
                for: .chooseImportFiles(mode: .single),
                model: model,
                picker: { _ in
                    pickerCallCount += 1
                    return nil
                }
            )
        }

        #expect(pickerCallCount == 0)
        model.resumeSettingsCommandsAfterCancelledQuit()
    }

    @Test
    func shutdownWaitsForInFlightSettingsFilePicker() async throws {
        let model = makeModel()
        let picker = BlockingSettingsFileImportPicker()

        let pickerTask = Task { @MainActor in
            try await fileImportPickerResponse(
                for: .chooseImportFiles(mode: .single),
                model: model,
                picker: picker.choose(mode:)
            )
        }
        await waitUntil {
            picker.hasEntered
        }

        var shutdownFinished = false
        let shutdownTask = Task { @MainActor in
            await model.stopAcceptingSettingsCommandsAndWait()
            shutdownFinished = true
        }
        try await Task.sleep(for: .milliseconds(20))
        #expect(!shutdownFinished)

        picker.complete(with: nil)
        _ = try await pickerTask.value
        await shutdownTask.value
        #expect(shutdownFinished)
        model.resumeSettingsCommandsAfterCancelledQuit()
    }

    @Test
    func settingsHelperCanCancelAnInFlightFilePicker() async throws {
        let model = makeModel()
        let launcher = ControllableSettingsHelperLauncher()
        let picker = CancellableSettingsFileImportPicker()
        let coordinator = SettingsCoordinator(
            model: model,
            helperLauncher: launcher,
            helperValidator: PermissiveSettingsHelperLaunchValidator(),
            settingsHelperURLProvider: { URL(fileURLWithPath: "/tmp/GlassEQSettings.app") },
            fileImportPicker: picker.choose(mode:)
        )

        let token = try await connectSettingsHelper(coordinator: coordinator, launcher: launcher)
        try launcher.writeHelperMessage(
            .request(
                sessionToken: token,
                id: "file-picker",
                kind: .command,
                command: .chooseImportFiles(mode: .single)
            ))
        await waitUntil {
            picker.hasEntered
        }

        try launcher.writeHelperMessage(
            .request(
                sessionToken: token,
                id: "file-picker",
                kind: .cancel,
                command: nil
            ))

        await waitUntil {
            picker.wasCancelled
        }
        await settleAsyncWork()
        #expect(picker.wasCancelled)
        #expect(
            !launcher.receivedAppMessages.contains { message in
                if case .response(_, "file-picker", _, _) = message {
                    return true
                }
                return false
            })
        await model.stopAcceptingSettingsCommandsAndWait()
        model.resumeSettingsCommandsAfterCancelledQuit()
        coordinator.shutdown()
    }

    @Test
    func quittingCancelsAnInFlightHelperFilePickerBeforeDrainingCommands() async throws {
        let model = makeModel()
        let launcher = ControllableSettingsHelperLauncher()
        let picker = CancellableSettingsFileImportPicker()
        let coordinator = SettingsCoordinator(
            model: model,
            helperLauncher: launcher,
            helperValidator: PermissiveSettingsHelperLaunchValidator(),
            settingsHelperURLProvider: { URL(fileURLWithPath: "/tmp/GlassEQSettings.app") },
            fileImportPicker: picker.choose(mode:)
        )
        model.settingsCoordinator = coordinator

        let token = try await connectSettingsHelper(coordinator: coordinator, launcher: launcher)
        try launcher.writeHelperMessage(
            .request(
                sessionToken: token,
                id: "quit-file-picker",
                kind: .command,
                command: .chooseImportFiles(mode: .single)
            ))
        await waitUntil {
            picker.hasEntered
        }

        await model.stopAcceptingSettingsCommandsAndWait()

        #expect(picker.wasCancelled)
        await waitUntil {
            launcher.receivedAppMessages.contains { message in
                if case let .response(_, "quit-file-picker", _, error) = message {
                    return error == "GlassEQ is shutting down."
                }
                return false
            }
        }
        let pickerResponses = launcher.receivedAppMessages.filter { message in
            if case .response(_, "quit-file-picker", _, _) = message {
                return true
            }
            return false
        }
        #expect(pickerResponses.count == 1)
        #expect(
            pickerResponses.contains { message in
                if case let .response(_, "quit-file-picker", _, error) = message {
                    return error == "GlassEQ is shutting down."
                }
                return false
            })
        model.resumeSettingsCommandsAfterCancelledQuit()
        coordinator.shutdown()
    }

    @Test
    func quittingCancelsAnInFlightInProcessFilePickerBeforeDrainingCommands() async {
        let model = makeModel()
        let picker = CancellableSettingsFileImportPicker()
        let client = CancellableInProcessSettingsClient(
            model: model,
            picker: picker
        )
        let settingsModel = GlassEQSettingsViewModel(client: client)
        model.inProcessSettingsViewModelStorage = settingsModel
        let pickerTask = Task { @MainActor in
            await settingsModel.perform(.chooseImportFiles(mode: .single))
        }
        await waitUntil {
            picker.hasEntered
        }

        await model.stopAcceptingSettingsCommandsAndWait()

        #expect(picker.wasCancelled)
        #expect(await pickerTask.value == nil)
        #expect(settingsModel.commandErrorMessage == nil)
        model.resumeSettingsCommandsAfterCancelledQuit()
    }

    @Test
    func settingsHelperDisconnectCancelsItsInFlightFilePicker() async throws {
        let model = makeModel()
        let launcher = ControllableSettingsHelperLauncher()
        let picker = CancellableSettingsFileImportPicker()
        let coordinator = SettingsCoordinator(
            model: model,
            helperLauncher: launcher,
            helperValidator: PermissiveSettingsHelperLaunchValidator(),
            settingsHelperURLProvider: { URL(fileURLWithPath: "/tmp/GlassEQSettings.app") },
            fileImportPicker: picker.choose(mode:)
        )

        let token = try await connectSettingsHelper(coordinator: coordinator, launcher: launcher)
        try launcher.writeHelperMessage(
            .request(
                sessionToken: token,
                id: "file-picker",
                kind: .command,
                command: .chooseImportFiles(mode: .stereoPair)
            ))
        await waitUntil {
            picker.hasEntered
        }

        _ = model.stageLibraryImport(
            ProfileLibraryBackup(createdAt: Date(), appVersion: nil, profileStore: ProfileStore()),
            filename: "pending.json")
        try launcher.writeHelperMessage(
            .request(
                sessionToken: token,
                id: "disconnect",
                kind: .disconnect,
                command: nil
            ))

        await waitUntil {
            picker.wasCancelled
        }
        #expect(picker.wasCancelled)
        #expect(model.pendingLibraryImport == nil)
        #expect(!coordinator.hasActiveSessionResourcesForTesting)
        await model.stopAcceptingSettingsCommandsAndWait()
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
        try launcher.writeHelperOutput(
            try SettingsPipeCodec.encodeLine(
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
        let requests =
            try SettingsPipeCodec.encodeLine(
                .request(sessionToken: token, id: "connect", kind: .connect, command: nil)
            )
            + SettingsPipeCodec.encodeLine(
                .request(sessionToken: token, id: "ready", kind: .ready, command: nil)
            )
        try launcher.writeHelperOutput(requests)
        for _ in 0..<100 where !coordinator.isHelperReadyForTesting {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(coordinator.isHelperReadyForTesting)
        let baselineMessageCount = launcher.receivedAppMessages.count

        model.engineMetrics = AudioEngineMetrics(capturedFrames: 42)
        let expectedMetrics = model.settingsMetricsSnapshot()
        coordinator.modelDidChange()

        let expectedMessage = SettingsPipeMessage.event(
            sessionToken: token,
            event: .metricsChanged(expectedMetrics)
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
        try launcher.writeHelperMessage(
            .request(
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
        try launcher.writeHelperMessage(
            .request(
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
        try launcher.writeHelperMessage(
            .request(
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
        try launcher.writeHelperMessage(
            .request(
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
        let profileSnapshotRevision = settingsModel.profileSnapshotRevision

        #expect(settingsModel.isConnected)
        #expect(settingsModel.snapshot == model.settingsSnapshot())
        #expect(model.inProcessSettingsViewModel() === settingsModel)
        #expect(settingsModel.profileSnapshotRevision == profileSnapshotRevision)

        let response = await settingsModel.perform(.createProfile(.parametric))
        #expect(response?.snapshot?.profiles.count == 2)
        #expect(settingsModel.snapshot == model.settingsSnapshot())
    }

    @Test
    func settingsHelperValidationChecksContainmentBundleIDAndSigningPolicy() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlassEQHelperValidation-\(UUID().uuidString)", isDirectory: true)
        let hostURL = root.appendingPathComponent("GlassEQ.app", isDirectory: true)
        let helperURL =
            hostURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent("GlassEQSettings.app", isDirectory: true)
        try makeFakeAppBundle(
            at: helperURL,
            bundleIdentifier: SettingsHelperVerifier.helperBundleIdentifier,
            executableName: "GlassEQSettings"
        )
        let validator = FakeCodeSigningValidator(signatures: [
            hostURL.standardizedFileURL.path: SettingsCodeSignatureInfo(
                signingIdentifier: SettingsHelperVerifier.hostBundleIdentifier, teamIdentifier: "TEAMID"),
            helperURL.standardizedFileURL.path: SettingsCodeSignatureInfo(
                signingIdentifier: SettingsHelperVerifier.helperBundleIdentifier, teamIdentifier: "TEAMID"),
        ])

        let executableURL = try SettingsHelperVerifier.validatedExecutableURL(
            for: helperURL,
            hostBundleURL: hostURL,
            codeSigningValidator: validator
        )

        #expect(executableURL.lastPathComponent == "GlassEQSettings")

        let wrongBundleURL =
            hostURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent("WrongSettings.app", isDirectory: true)
        try makeFakeAppBundle(
            at: wrongBundleURL, bundleIdentifier: "com.example.wrong", executableName: "GlassEQSettings")
        #expect(throws: SettingsCommandFailure.self) {
            _ = try SettingsHelperVerifier.validatedExecutableURL(
                for: wrongBundleURL,
                hostBundleURL: hostURL,
                codeSigningValidator: validator
            )
        }

        let outsideURL =
            root
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
            hostURL.standardizedFileURL.path: SettingsCodeSignatureInfo(
                signingIdentifier: SettingsHelperVerifier.hostBundleIdentifier, teamIdentifier: "TEAMID"),
            helperURL.standardizedFileURL.path: SettingsCodeSignatureInfo(
                signingIdentifier: SettingsHelperVerifier.helperBundleIdentifier, teamIdentifier: "OTHERTEAM"),
        ])
        #expect(throws: SettingsCommandFailure.self) {
            _ = try SettingsHelperVerifier.validatedExecutableURL(
                for: helperURL,
                hostBundleURL: hostURL,
                codeSigningValidator: mismatchedTeam
            )
        }

        let adHoc = FakeCodeSigningValidator(signatures: [
            hostURL.standardizedFileURL.path: SettingsCodeSignatureInfo(
                signingIdentifier: SettingsHelperVerifier.hostBundleIdentifier, teamIdentifier: nil),
            helperURL.standardizedFileURL.path: SettingsCodeSignatureInfo(
                signingIdentifier: SettingsHelperVerifier.helperBundleIdentifier, teamIdentifier: nil),
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
        let helperURL =
            hostURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent("GlassEQSettings.app", isDirectory: true)
        try makeFakeAppBundle(
            at: helperURL,
            bundleIdentifier: SettingsHelperVerifier.helperBundleIdentifier,
            executableName: "GlassEQSettings"
        )
        let validator = FakeCodeSigningValidator(signatures: [
            hostURL.standardizedFileURL.path: SettingsCodeSignatureInfo(
                signingIdentifier: SettingsHelperVerifier.hostBundleIdentifier, teamIdentifier: "TEAMID"),
            helperURL.standardizedFileURL.path: SettingsCodeSignatureInfo(
                signingIdentifier: SettingsHelperVerifier.helperBundleIdentifier, teamIdentifier: "TEAMID"),
            "pid:123": SettingsCodeSignatureInfo(
                signingIdentifier: SettingsHelperVerifier.helperBundleIdentifier, teamIdentifier: "TEAMID"),
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
    func settingsHelperRunningValidationRejectsMissingProcessSignature() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlassEQHelperRunningValidation-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let hostURL = root.appendingPathComponent("GlassEQ.app", isDirectory: true)
        let helperURL =
            hostURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent("GlassEQSettings.app", isDirectory: true)
        try makeFakeAppBundle(
            at: helperURL,
            bundleIdentifier: SettingsHelperVerifier.helperBundleIdentifier,
            executableName: "GlassEQSettings"
        )
        let validator = FakeCodeSigningValidator(signatures: [
            hostURL.standardizedFileURL.path: SettingsCodeSignatureInfo(
                signingIdentifier: SettingsHelperVerifier.hostBundleIdentifier, teamIdentifier: "TEAMID"),
            helperURL.standardizedFileURL.path: SettingsCodeSignatureInfo(
                signingIdentifier: SettingsHelperVerifier.helperBundleIdentifier, teamIdentifier: "TEAMID"),
        ])

        #expect(throws: SettingsCommandFailure.self) {
            try SettingsHelperVerifier.validateRunningProcess(
                processIdentifier: 123,
                expectedHelperURL: helperURL,
                hostBundleURL: hostURL,
                runningBundleURL: { _ in nil },
                processExecutableURL: { _ in helperExecutableURL(for: helperURL) },
                codeSigningValidator: validator
            )
        }
    }

    @Test(arguments: ["/Applications/GlassEQ.app/Contents/MacOS/GlassEQ", "/tmp/Ääni 🎧/GlassEQ"])
    func settingsHelperExecutablePathPreservesValidUTF8(_ path: String) {
        #expect(SettingsHelperVerifier.executableURL(pathBytes: path.utf8.map { CChar(bitPattern: $0) })?.path == path)
    }

    @Test(
        arguments: ["/Applications/GlassEQ.app/Contents/MacOS/GlassEQ", "/tmp/Ääni 🎧/GlassEQ"],
        [[CChar(0)], [0, 0, 0], [0, -1, 65]]
    )
    func settingsHelperExecutablePathStopsAtFirstNUL(_ path: String, suffix: [CChar]) {
        let bytes = path.utf8.map { CChar(bitPattern: $0) }
        #expect(SettingsHelperVerifier.executableURL(pathBytes: bytes + suffix)?.path == path)
    }

    @Test(arguments: [[UInt8(0xFF)], [0xC3], [0xC0, 0xAF]])
    func settingsHelperExecutablePathRejectsInvalidUTF8(_ suffix: [UInt8]) {
        let bytes = Array("/Applications/".utf8) + suffix + Array("/GlassEQ".utf8) + [0]
        #expect(SettingsHelperVerifier.executableURL(pathBytes: bytes.map { CChar(bitPattern: $0) }) == nil)
    }

    @Test(arguments: [false, true])
    func settingsHelperRunningValidationAcceptsSymlinkAliases(hasRunningBundleURL: Bool) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlassEQHelperAliasValidation-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let hostURL = root.appendingPathComponent("GlassEQ.app", isDirectory: true)
        let helperURL = hostURL.appendingPathComponent("Contents/Helpers/GlassEQSettings.app", isDirectory: true)
        try makeFakeAppBundle(
            at: helperURL,
            bundleIdentifier: SettingsHelperVerifier.helperBundleIdentifier,
            executableName: "GlassEQSettings"
        )
        let aliasHostURL = root.appendingPathComponent("Alias.app", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: aliasHostURL, withDestinationURL: hostURL)
        let aliasHelperURL = aliasHostURL.appendingPathComponent(
            "Contents/Helpers/GlassEQSettings.app", isDirectory: true)
        let helperSignature = SettingsCodeSignatureInfo(
            signingIdentifier: SettingsHelperVerifier.helperBundleIdentifier, teamIdentifier: "TEAMID")
        let validator = FakeCodeSigningValidator(signatures: [
            aliasHostURL.standardizedFileURL.path: SettingsCodeSignatureInfo(
                signingIdentifier: SettingsHelperVerifier.hostBundleIdentifier, teamIdentifier: "TEAMID"),
            helperURL.standardizedFileURL.path: helperSignature,
            aliasHelperURL.standardizedFileURL.path: helperSignature,
            "pid:123": helperSignature,
        ])

        _ = try SettingsHelperVerifier.validatedExecutableURL(
            for: aliasHelperURL,
            hostBundleURL: aliasHostURL,
            codeSigningValidator: validator
        )
        try SettingsHelperVerifier.validateRunningProcess(
            processIdentifier: 123,
            expectedHelperURL: aliasHelperURL,
            hostBundleURL: aliasHostURL,
            runningBundleURL: { _ in hasRunningBundleURL ? helperURL : nil },
            processExecutableURL: { _ in helperExecutableURL(for: helperURL) },
            codeSigningValidator: validator
        )
    }

    @Test(arguments: [false, true])
    func settingsHelperRunningValidationRejectsDifferentOrMissingExecutable(actualExecutableExists: Bool) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlassEQHelperExecutableValidation-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let hostURL = root.appendingPathComponent("GlassEQ.app", isDirectory: true)
        let helperURL = hostURL.appendingPathComponent("Contents/Helpers/GlassEQSettings.app", isDirectory: true)
        try makeFakeAppBundle(
            at: helperURL,
            bundleIdentifier: SettingsHelperVerifier.helperBundleIdentifier,
            executableName: "GlassEQSettings"
        )
        let otherExecutableURL = root.appendingPathComponent("OtherSettings", isDirectory: false)
        if actualExecutableExists {
            try FileManager.default.copyItem(at: helperExecutableURL(for: helperURL), to: otherExecutableURL)
        }
        let helperSignature = SettingsCodeSignatureInfo(
            signingIdentifier: SettingsHelperVerifier.helperBundleIdentifier, teamIdentifier: "TEAMID")
        let validator = FakeCodeSigningValidator(signatures: [
            hostURL.standardizedFileURL.path: SettingsCodeSignatureInfo(
                signingIdentifier: SettingsHelperVerifier.hostBundleIdentifier, teamIdentifier: "TEAMID"),
            helperURL.standardizedFileURL.path: helperSignature,
            "pid:123": helperSignature,
        ])

        #expect(throws: SettingsCommandFailure.self) {
            try SettingsHelperVerifier.validateRunningProcess(
                processIdentifier: 123,
                expectedHelperURL: helperURL,
                hostBundleURL: hostURL,
                runningBundleURL: { _ in helperURL },
                processExecutableURL: { _ in otherExecutableURL },
                codeSigningValidator: validator
            )
        }
    }

    @Test
    func settingsHelperRunningValidationRejectsMissingResolvedBundleIdentity() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlassEQHelperMissingBundleValidation-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let hostURL = root.appendingPathComponent("GlassEQ.app", isDirectory: true)
        let helperURL = hostURL.appendingPathComponent("Contents/Helpers/GlassEQSettings.app", isDirectory: true)
        try makeFakeAppBundle(
            at: helperURL,
            bundleIdentifier: SettingsHelperVerifier.helperBundleIdentifier,
            executableName: "GlassEQSettings"
        )
        let missingBundleURL = root.appendingPathComponent("Missing.app", isDirectory: true)
        let helperSignature = SettingsCodeSignatureInfo(
            signingIdentifier: SettingsHelperVerifier.helperBundleIdentifier, teamIdentifier: "TEAMID")
        let validator = FakeCodeSigningValidator(signatures: [
            hostURL.standardizedFileURL.path: SettingsCodeSignatureInfo(
                signingIdentifier: SettingsHelperVerifier.hostBundleIdentifier, teamIdentifier: "TEAMID"),
            helperURL.standardizedFileURL.path: helperSignature,
            missingBundleURL.standardizedFileURL.path: helperSignature,
            "pid:123": helperSignature,
        ])

        #expect(throws: SettingsCommandFailure.self) {
            try SettingsHelperVerifier.validateRunningProcess(
                processIdentifier: 123,
                expectedHelperURL: helperURL,
                hostBundleURL: hostURL,
                runningBundleURL: { _ in missingBundleURL },
                processExecutableURL: { _ in helperExecutableURL(for: helperURL) },
                codeSigningValidator: validator
            )
        }
    }

    @Test
    func settingsHelperRunningValidationRejectsUnexpectedResolvedBundleURL() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlassEQHelperRunningValidation-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let hostURL = root.appendingPathComponent("GlassEQ.app", isDirectory: true)
        let helperURL =
            hostURL
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
            hostURL.standardizedFileURL.path: SettingsCodeSignatureInfo(
                signingIdentifier: SettingsHelperVerifier.hostBundleIdentifier, teamIdentifier: "TEAMID"),
            helperURL.standardizedFileURL.path: SettingsCodeSignatureInfo(
                signingIdentifier: SettingsHelperVerifier.helperBundleIdentifier, teamIdentifier: "TEAMID"),
            otherURL.standardizedFileURL.path: SettingsCodeSignatureInfo(
                signingIdentifier: SettingsHelperVerifier.helperBundleIdentifier, teamIdentifier: "TEAMID"),
            "pid:123": SettingsCodeSignatureInfo(
                signingIdentifier: SettingsHelperVerifier.helperBundleIdentifier, teamIdentifier: "TEAMID"),
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

private let appModelTestDirectory: URL = {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("GlassEQAppModelTests-\(UUID().uuidString)")
    atexit { try? FileManager.default.removeItem(at: appModelTestDirectory) }
    return url
}()

@MainActor
private func makeModel(
    store: ProfileStore? = nil,
    storeURL: URL = appModelTestDirectory.appendingPathComponent("\(UUID().uuidString).json"),
    engine: FakeAudioEngine = FakeAudioEngine(),
    lookup: FakeDefaultOutputLookup = FakeDefaultOutputLookup(.success(makeOutput())),
    observers: any DefaultOutputObservingMaking = FakeDefaultOutputObserverFactory(),
    workspaceOpener: any WorkspaceOpening = FakeWorkspaceOpener(results: []),
    profileImportOperation: (@Sendable (ImportFormat, String, String) async -> Result<EQProfile, any Error>)? = nil,
    saveDelay: Duration = .zero,
    writeProfileStore: @escaping @Sendable (ProfileStore, URL) throws -> Void = ProfilePersistence.save,
    outputDelay: Duration? = nil,
    outputSleep: @escaping @MainActor @Sendable (Duration) async throws -> Void = {
        try await Task.sleep(for: $0)
    },
    wakeDelay: Duration? = nil,
    aggregateStabilityDelay: Duration = .zero,
    aggregateCleanSessionDuration: Duration = .seconds(5 * 60),
    headsetAggregatePromotionDelay: Duration = .seconds(6),
    coldStartupAggregatePromotionPollInterval: Duration = .seconds(1),
    renderWatchdogStallThreshold: Duration = AudioRenderWatchdog.defaultStallThreshold,
    renderWatchdogRepeatedFailureWindow: Duration = AudioRenderWatchdog.defaultRepeatedFailureWindow,
    renderWatchdogPollInterval: Duration = .milliseconds(500),
    aggregateBufferNotifier: (any AggregateBufferChangeNotifying)? = nil,
    licensing: LicensingSource = .disabled,
    licenseStopTransitionTimeout: Duration = .milliseconds(500),
    licenseOperationCancellationGrace: Duration = .seconds(3),
    autoStart: Bool = false,
    launchRecordsDirectory: URL? = nil
) -> GlassEQAppModel {
    let store = normalizedStore(store ?? ProfileStore(profiles: [makeProfile(name: "Fallback")]))
    return GlassEQAppModel(
        profileStore: store,
        storeURL: storeURL,
        engine: engine,
        defaultOutputLookup: lookup,
        observerFactory: observers,
        autoStart: autoStart,
        installLifecycleObservers: false,
        registerAppDelegate: false,
        workspaceOpener: workspaceOpener,
        profileImportOperation: profileImportOperation,
        saveDebounceDelay: saveDelay,
        writeProfileStore: writeProfileStore,
        outputChangeSettlingDelayOverride: outputDelay,
        outputChangeSleep: outputSleep,
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
        aggregateBufferNotifier: aggregateBufferNotifier,
        licensing: licensing,
        licenseStopTransitionTimeout: licenseStopTransitionTimeout,
        licenseOperationCancellationGrace: licenseOperationCancellationGrace,
        // The shared temporary directory would otherwise collect one record per test process.
        launchRecordsDirectory: launchRecordsDirectory
            ?? storeURL.deletingPathExtension().appendingPathExtension("launch-records")
    )
}

@MainActor
private final class OutputSettlementGate {
    private var isHeld = false
    private var waiters: [AsyncStream<Void>.Continuation] = []
    private(set) var waitCount = 0

    func hold() {
        isHeld = true
    }

    func sleep(for _: Duration) async {
        guard isHeld else { return }
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        waiters.append(continuation)
        waitCount += 1
        for await _ in stream {}
    }

    func release() {
        isHeld = false
        for waiter in waiters { waiter.finish() }
        waiters.removeAll()
    }
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

@MainActor
private final class BlockingSettingsFileImportPicker {
    private(set) var hasEntered = false
    private var continuation: CheckedContinuation<SettingsFileImportSelectionDTO?, Never>?

    func choose(
        mode: SettingsFileImportMode
    ) async -> SettingsFileImportSelectionDTO? {
        hasEntered = true
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func complete(with selection: SettingsFileImportSelectionDTO?) {
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(returning: selection)
    }
}

@MainActor
private final class CancellableSettingsFileImportPicker {
    private(set) var hasEntered = false
    private(set) var wasCancelled = false

    func choose(
        mode: SettingsFileImportMode
    ) async throws -> SettingsFileImportSelectionDTO? {
        hasEntered = true
        do {
            try await Task.sleep(for: .seconds(30))
            return nil
        } catch is CancellationError {
            wasCancelled = true
            throw CancellationError()
        }
    }
}

@MainActor
private final class CancellableInProcessSettingsClient: SettingsCommanding {
    private weak var model: GlassEQAppModel?
    private let picker: CancellableSettingsFileImportPicker

    init(model: GlassEQAppModel, picker: CancellableSettingsFileImportPicker) {
        self.model = model
        self.picker = picker
    }

    func perform(_ command: SettingsCommand) async throws -> SettingsCommandResponse {
        guard let model else {
            throw SettingsCommandFailure(message: "GlassEQ is shutting down.")
        }
        if let response = try await fileImportPickerResponse(
            for: command,
            model: model,
            picker: picker.choose(mode:)
        ) {
            return response
        }
        return try await model.performSettingsCommand(command)
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
        convolution: .impulseResponse(
            ImpulseResponseSource(
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
        "CFBundlePackageType": "APPL",
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
private func connectSettingsHelper(
    coordinator: SettingsCoordinator,
    launcher: ControllableSettingsHelperLauncher
) async throws -> String {
    #expect(coordinator.openSettings() == .helper)
    await waitUntil {
        launcher.receivedAppMessages.contains { message in
            if case .bootstrap = message {
                return true
            }
            return false
        }
    }
    let bootstrap = try #require(
        launcher.receivedAppMessages.first { message in
            if case .bootstrap = message {
                return true
            }
            return false
        })
    guard case .bootstrap(let token) = bootstrap else {
        throw SettingsCommandFailure(message: "Expected Settings bootstrap message.")
    }
    try launcher.writeHelperMessage(
        .request(
            sessionToken: token,
            id: "connect",
            kind: .connect,
            command: nil
        ))
    try launcher.writeHelperMessage(
        .request(
            sessionToken: token,
            id: "ready",
            kind: .ready,
            command: nil
        ))
    await waitUntil {
        coordinator.isHelperReadyForTesting
    }
    #expect(coordinator.isHelperReadyForTesting)
    return token
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
        guard let signature = signatures["pid:\(processIdentifier)"] else {
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
    private let startError: Error?
    private(set) var observers: [FakeDefaultOutputObserver] = []

    init(startError: Error? = nil) {
        self.startError = startError
    }

    func makeObserver(onChange: @escaping DefaultOutputObserverHandler) -> any DefaultOutputObserving {
        let observer = FakeDefaultOutputObserver(
            onChange: onChange,
            startError: startError
        )
        observers.append(observer)
        return observer
    }
}

private final class FakeDefaultOutputObserver: DefaultOutputObserving, @unchecked Sendable {
    private let onChange: DefaultOutputObserverHandler
    private let lock = NSLock()
    private let startError: Error?
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

    init(
        onChange: @escaping DefaultOutputObserverHandler,
        startError: Error? = nil
    ) {
        self.onChange = onChange
        self.startError = startError
    }

    func start(sendInitialValue: Bool) throws {
        withLock {
            _startCalls.append(sendInitialValue)
        }
        if let startError {
            throw startError
        }
    }

    func stop() {
        withLock {
            _stopCallCount += 1
        }
    }

    func emit(
        _ result: Result<AudioOutputDevice, Error>,
        reason: DefaultOutputDeviceChangeReason = .settled
    ) {
        onChange(result, reason)
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
        let observer = BlockingAsyncDefaultOutputObserver()
        observers.append(observer)
        return observer
    }
}

private final class BlockingAsyncDefaultOutputObserver: DefaultOutputObserving, @unchecked Sendable {
    private let lock = NSLock()
    private var _startCalls: [Bool] = []
    private var _stopCallCount = 0
    private var startContinuation: CheckedContinuation<Void, Never>?

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
    private var _startDelaySeconds: TimeInterval = 0
    private var _startBlockersByUID: [String: FakeStartBlocker] = [:]
    private var _preferredFrameSizeBlockers: [UInt32: FakeStartBlocker] = [:]
    private var _updateBlockersByProfileID: [UUID: FakeStartBlocker] = [:]
    private var _coldStartupPromotionBlocker: FakeStartBlocker?
    private var _headsetPromotionBlocker: FakeStartBlocker?
    private var _startCalls: [StartCall] = []
    private var _updateCalls: [EQProfile] = []
    private var _updateDSPCalls: [EQProfile] = []
    private var _programmeComparisonCalls: [EQProfile] = []
    private var _programmeComparisonReferences: [EQProfile] = []
    private var _programmeComparisonSelections: [EQProgrammeComparisonSelection] = []
    private var _programmeComparisonSnapshot = EQProgrammeComparisonSnapshot()
    private var _snapshotProgrammeComparisonCallCount = 0
    private var _dspTransitionProgress = DSPTransitionProgress()
    private var _pendingDSPTransitionIDs: [UInt64] = []
    private var _deferDSPTransitionCompletion = false
    private var _stopCallCount = 0
    private var _muteOutputCallCount = 0
    private var _resumeOutputCallCount = 0
    private var _metrics = AudioEngineMetrics()
    private var _snapshotMetricsCallCount = 0
    private var _events: [String] = []
    private var _preferredAggregateBufferFrameSize: UInt32 = 16
    private var _nativeOutputStreamIndex = 0
    private var _reflectPreferredAggregateBufferFrameSize = false
    private var _forcedAppliedAggregateBufferFrameSize: UInt32?
    private var _headsetPromotionCandidateUIDs: Set<String> = []
    private var _headsetAggregatePromotionResult = HeadsetAggregatePromotionResult.notApplicable
    private var _headsetAggregatePromotionAttemptCount = 0
    private var _isUsingSeparateClockBackend = false
    private var _isUsingTransitionalHeadsetBackend = false
    private var _isUsingPromotedHeadsetAggregate = false
    private var _promotedHeadsetOutputUID: String?
    private var _coldStartupPromotionCandidateUIDs: Set<String> = []
    private var _coldStartupAggregatePromotionResult = ColdStartupAggregatePromotionResult.notApplicable
    private var _coldStartupAggregatePromotionAttemptCount = 0
    private var _isDeferringColdStartupAggregate = false
    private var _latencyMetadata: AudioEngineLatencyMetadata?
    private var _playbackBufferRenegotiationHandler: (@Sendable (PlaybackBufferRenegotiation) -> Void)?
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

    var isUsingSeparateClockBackend: Bool {
        withLock { _isUsingSeparateClockBackend }
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

    var startDelaySeconds: TimeInterval {
        get { withLock { _startDelaySeconds } }
        set { withLock { _startDelaySeconds = newValue } }
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

    private(set) var programmeComparisonReferences: [EQProfile] {
        get { withLock { _programmeComparisonReferences } }
        set { withLock { _programmeComparisonReferences = newValue } }
    }

    private(set) var programmeComparisonSelections: [EQProgrammeComparisonSelection] {
        get { withLock { _programmeComparisonSelections } }
        set { withLock { _programmeComparisonSelections = newValue } }
    }

    var programmeComparisonSnapshot: EQProgrammeComparisonSnapshot {
        get { withLock { _programmeComparisonSnapshot } }
        set { withLock { _programmeComparisonSnapshot = newValue } }
    }

    var snapshotProgrammeComparisonCallCount: Int {
        withLock { _snapshotProgrammeComparisonCallCount }
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

    var latencyMetadata: AudioEngineLatencyMetadata? {
        get { withLock { _latencyMetadata } }
        set { withLock { _latencyMetadata = newValue } }
    }

    var snapshotMetricsCallCount: Int {
        withLock { _snapshotMetricsCallCount }
    }

    var reflectPreferredAggregateBufferFrameSize: Bool {
        get { withLock { _reflectPreferredAggregateBufferFrameSize } }
        set { withLock { _reflectPreferredAggregateBufferFrameSize = newValue } }
    }

    var forcedAppliedAggregateBufferFrameSize: UInt32? {
        get { withLock { _forcedAppliedAggregateBufferFrameSize } }
        set { withLock { _forcedAppliedAggregateBufferFrameSize = newValue } }
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

    func blockPreferredAggregateBufferFrameSizeWrite(_ frameSize: UInt32) {
        withLock {
            _preferredFrameSizeBlockers[frameSize] = FakeStartBlocker()
        }
    }

    func waitUntilPreferredAggregateBufferFrameSizeWriteIsBlocked(
        _ frameSize: UInt32,
        timeout: DispatchTime
    ) -> Bool {
        withLock {
            _preferredFrameSizeBlockers[frameSize]
        }?.waitUntilEntered(timeout: timeout) ?? false
    }

    func unblockPreferredAggregateBufferFrameSizeWrite(_ frameSize: UInt32) {
        let blocker = withLock {
            _preferredFrameSizeBlockers.removeValue(forKey: frameSize)
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

    func blockColdStartupAggregatePromotion() {
        withLock {
            _coldStartupPromotionBlocker = FakeStartBlocker()
        }
    }

    func waitUntilColdStartupAggregatePromotionIsBlocked(
        timeout: DispatchTime
    ) -> Bool {
        withLock {
            _coldStartupPromotionBlocker
        }?.waitUntilEntered(timeout: timeout) ?? false
    }

    func unblockColdStartupAggregatePromotion() {
        let blocker = withLock {
            let blocker = _coldStartupPromotionBlocker
            _coldStartupPromotionBlocker = nil
            return blocker
        }
        blocker?.unblock()
    }

    func blockHeadsetAggregatePromotion() {
        withLock {
            _headsetPromotionBlocker = FakeStartBlocker()
        }
    }

    func waitUntilHeadsetAggregatePromotionIsBlocked(
        timeout: DispatchTime
    ) -> Bool {
        withLock {
            _headsetPromotionBlocker
        }?.waitUntilEntered(timeout: timeout) ?? false
    }

    func unblockHeadsetAggregatePromotion() {
        let blocker = withLock {
            let blocker = _headsetPromotionBlocker
            _headsetPromotionBlocker = nil
            return blocker
        }
        blocker?.unblock()
    }

    func start(output: AudioOutputDevice, profile: EQProfile) throws {
        let startControl = withLock {
            _events.append("start:\(output.uid)")
            _startCalls.append(
                StartCall(
                    output: output,
                    profile: profile,
                    aggregateBufferFrameSize: _preferredAggregateBufferFrameSize
                ))
            return (
                delay: _startDelaySeconds,
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
            if let forcedAppliedAggregateBufferFrameSize = _forcedAppliedAggregateBufferFrameSize {
                activeOutput.bufferFrameSize = forcedAppliedAggregateBufferFrameSize
            } else if _reflectPreferredAggregateBufferFrameSize {
                activeOutput.bufferFrameSize = _preferredAggregateBufferFrameSize
            }
            _state = .running(output: activeOutput)
            let remainsPromoted =
                _isUsingPromotedHeadsetAggregate
                && _promotedHeadsetOutputUID == output.uid
            _isUsingTransitionalHeadsetBackend =
                !remainsPromoted
                && _headsetPromotionCandidateUIDs.contains(output.uid)
            _isUsingPromotedHeadsetAggregate = remainsPromoted
            if !remainsPromoted {
                _promotedHeadsetOutputUID = nil
            }
            _isDeferringColdStartupAggregate = _coldStartupPromotionCandidateUIDs.contains(output.uid)
            _isUsingSeparateClockBackend =
                _isUsingTransitionalHeadsetBackend
                || _isDeferringColdStartupAggregate
        }
    }

    func attemptColdStartupAggregatePromotion() throws
        -> ColdStartupAggregatePromotionResult
    {
        let attempt = withLock {
            _coldStartupAggregatePromotionAttemptCount += 1
            return (
                result: _coldStartupAggregatePromotionResult,
                blocker: _coldStartupPromotionBlocker
            )
        }
        attempt.blocker?.waitUntilUnblocked()
        return withLock {
            let result = attempt.result
            switch result {
            case .promoted(let output):
                _state = .running(output: output)
                _isDeferringColdStartupAggregate = false
                _isUsingSeparateClockBackend = false
            case .aggregateUnstable:
                _isDeferringColdStartupAggregate = false
            case .clientsActive, .notApplicable:
                break
            }
            return result
        }
    }

    func attemptHeadsetAggregatePromotion() throws -> HeadsetAggregatePromotionResult {
        let attempt = withLock {
            _headsetAggregatePromotionAttemptCount += 1
            return (
                result: _headsetAggregatePromotionResult,
                blocker: _headsetPromotionBlocker
            )
        }
        attempt.blocker?.waitUntilUnblocked()
        return withLock {
            let result = attempt.result
            if case .promoted(let output) = result {
                _state = .running(output: output)
                _isUsingTransitionalHeadsetBackend = false
                _isUsingPromotedHeadsetAggregate = true
                _isUsingSeparateClockBackend = false
                _promotedHeadsetOutputUID = output.uid
            }
            return result
        }
    }

    func rejectHeadsetAggregatePromotion() {
        withLock {
            _isUsingPromotedHeadsetAggregate = false
            _promotedHeadsetOutputUID = nil
        }
    }

    func aggregateRouteFingerprint(
        for output: AudioOutputDevice
    ) throws -> AggregateAudioRouteFingerprint? {
        withLock {
            return AggregateAudioRouteFingerprint(
                outputDeviceUID: output.uid,
                nativeOutputStreamIndex: _nativeOutputStreamIndex,
                nominalSampleRate: output.nominalSampleRate
            )
        }
    }

    func setPreferredAggregateBufferFrameSize(_ frameSize: UInt32) {
        let blocker = withLock {
            _preferredFrameSizeBlockers[frameSize]
        }
        blocker?.waitUntilUnblocked()
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

    var deferDSPTransitionCompletion: Bool {
        get { withLock { _deferDSPTransitionCompletion } }
        set { withLock { _deferDSPTransitionCompletion = newValue } }
    }

    func updateDSP(
        profile: EQProfile
    ) -> DSPTransitionProgress.Target? {
        withLock {
            _events.append("updateDSP:\(profile.id)")
            _updateDSPCalls.append(profile)
            if _updateDSPResult {
                _dspTransitionProgress.published += 1
                _pendingDSPTransitionIDs.append(_dspTransitionProgress.published)
                if !_deferDSPTransitionCompletion {
                    _dspTransitionProgress.completed = _pendingDSPTransitionIDs.removeFirst()
                }
            }
            return _updateDSPResult ? _dspTransitionProgress.latestPublishedTarget : nil
        }
    }

    func dspTransitionProgress() -> DSPTransitionProgress {
        withLock { _dspTransitionProgress }
    }

    /// Lets a deferred bank transition finish, as the render thread would after the blend.
    func completeDSPTransition() {
        withLock {
            _events.append("transitionCompleted")
            if !_pendingDSPTransitionIDs.isEmpty {
                _dspTransitionProgress.completed = _pendingDSPTransitionIDs.removeFirst()
            }
        }
    }

    func beginProgrammeComparison(profile: EQProfile, reference: EQProfile) -> Bool {
        withLock {
            _programmeComparisonCalls.append(profile)
            _programmeComparisonReferences.append(reference)
            _programmeComparisonSnapshot = EQProgrammeComparisonSnapshot(
                isActive: true,
                selection: .equalized
            )
            return true
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
            _snapshotProgrammeComparisonCallCount += 1
            return _programmeComparisonSnapshot
        }
    }

    func muteOutputForTransition() {
        withLock {
            _events.append("mute")
            _muteOutputCallCount += 1
        }
    }

    func setPlaybackBufferRenegotiationHandler(
        _ handler: (@Sendable (PlaybackBufferRenegotiation) -> Void)?
    ) {
        withLock {
            _playbackBufferRenegotiationHandler = handler
        }
    }

    func emitPlaybackBufferRenegotiation(
        _ renegotiation: PlaybackBufferRenegotiation
    ) {
        let handler = withLock {
            _playbackBufferRenegotiationHandler
        }
        handler?(renegotiation)
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
            _isUsingSeparateClockBackend = false
        }
    }

    func snapshotMetrics() -> AudioEngineMetrics {
        withLock {
            _snapshotMetricsCallCount += 1
            return _metrics
        }
    }

    func snapshotLatencyMetadata() -> AudioEngineLatencyMetadata? {
        withLock { _latencyMetadata }
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
    private(set) var bluetoothNoticeCount = 0

    func notifyBluetoothBufferDefault() {
        bluetoothNoticeCount += 1
    }

    func notifyBufferIncrease(
        outputName: String,
        previousFrameSize: UInt32,
        newFrameSize: UInt32
    ) {
        calls.append(
            Call(
                outputName: outputName,
                previousFrameSize: previousFrameSize,
                newFrameSize: newFrameSize
            ))
    }

    func notifyFixedBufferRebuild(
        outputName: String,
        frameSize: UInt32
    ) {
        calls.append(
            Call(
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
        calls.append(
            Call(
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
        release.wait()
    }

    func waitUntilEntered(timeout: DispatchTime) -> Bool {
        entered.wait(timeout: timeout) == .success
    }

    func unblock() {
        release.signal()
    }
}

// MARK: - License enforcement

private let nonPermittingLicenseStates: [LicenseState] = [
    .unlicensed, .monthlyExpired, .invalidEntitlement, .storageUnavailable,
]
private let permittingLicenseStates: [LicenseState] = [
    .perpetual, .monthlyActive, .monthlyRecovery, .monthlyGrace, .verificationNeeded,
]

@MainActor
@Suite
struct LicenseEnforcementTests {

    private struct RunningModel {
        let output: AudioOutputDevice
        let engine: FakeAudioEngine
        let observers: FakeDefaultOutputObserverFactory
        let source: FakeLicenseSnapshotSource
        let model: GlassEQAppModel
    }

    private func makeRunningModel(
        initialState: LicenseState = .monthlyActive,
        outputDelay: Duration = .zero,
        licenseStopTransitionTimeout: Duration = .milliseconds(500),
        configureEngine: (FakeAudioEngine) -> Void = { _ in }
    ) async -> RunningModel {
        let output = makeOutput(uid: "licensed-output", name: "Licensed Output")
        let engine = FakeAudioEngine()
        configureEngine(engine)
        let observers = FakeDefaultOutputObserverFactory()
        let source = FakeLicenseSnapshotSource(initial: makeLicenseSnapshot(state: initialState))
        let model = makeModel(
            engine: engine,
            lookup: FakeDefaultOutputLookup(.success(output)),
            observers: observers,
            outputDelay: outputDelay,
            wakeDelay: .zero,
            licensing: .provider(source),
            licenseStopTransitionTimeout: licenseStopTransitionTimeout
        )
        await waitUntil { model.licenseSnapshot != nil }
        model.start()
        await waitUntil { observers.observers.count == 1 }
        observers.observers[0].emit(.success(output))
        await waitUntil { model.lifecycleState == .running && engine.startCalls.count == 1 }
        return RunningModel(output: output, engine: engine, observers: observers, source: source, model: model)
    }

    private func expiredText() -> String {
        localized("Subscription ended. GlassEQ has returned to unprocessed playback.")
    }

    @Test
    func licensingDisabledStartsAsBefore() async {
        let output = makeOutput()
        let engine = FakeAudioEngine()
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
            engine: engine, lookup: FakeDefaultOutputLookup(.success(output)), observers: observers, outputDelay: .zero)

        model.start()
        observers.observers[0].emit(.success(output))
        await waitUntil { model.lifecycleState == .running }

        #expect(engine.startCalls.count == 1)
        #expect(model.licenseSnapshot == nil)
        #expect(model.licenseStatusMessage == nil)
    }

    @Test(arguments: nonPermittingLicenseStates)
    func initialNonPermittingSnapshotNeverStartsTheTap(state: LicenseState) async {
        let engine = FakeAudioEngine()
        let observers = FakeDefaultOutputObserverFactory()
        let source = FakeLicenseSnapshotSource(initial: makeLicenseSnapshot(state: state))
        let model = makeModel(engine: engine, observers: observers, outputDelay: .zero, licensing: .provider(source))
        await waitUntil { model.licenseSnapshot != nil }

        model.start()
        await settleAsyncWork()

        #expect(engine.startCalls.isEmpty)
        #expect(observers.observers.isEmpty)
        #expect(model.lifecycleState == .stopped)
        #expect(!model.isRunning)
        #expect(model.statusMessage != localized("Stopped"))
        #expect(model.onboardingAudioCaptureState == .failed(message: model.statusMessage))
        #expect(model.licenseStatusMessage == nil)
    }

    @Test(arguments: permittingLicenseStates)
    func permittingSnapshotsStartNormally(state: LicenseState) async {
        let running = await makeRunningModel(initialState: state)

        #expect(running.model.isRunning)
        #expect(running.engine.startCalls.count == 1)
        let expectsSecondaryLine = [.monthlyRecovery, .monthlyGrace, .verificationNeeded].contains(state)
        #expect((running.model.licenseStatusMessage != nil) == expectsSecondaryLine)
    }

    @Test
    func recoveryMessagingClaimsAPaymentProblemOnlyWhenTheServerSaidSo() async {
        let recovering = await makeRunningModel(initialState: .monthlyRecovery)
        let unverified = FakeLicenseSnapshotSource(initial: makeLicenseSnapshot(state: .monthlyRecovery))

        recovering.source.emit(makeLicenseSnapshot(state: .monthlyRecovery, sequence: 2, billingState: .recovering))
        await waitUntil { recovering.model.licenseSnapshot?.sequence == 2 }

        #expect(recovering.model.licenseStatusMessage?.contains("payment details") == true)
        let model = makeModel(licensing: .provider(unverified))
        await waitUntil { model.licenseSnapshot != nil }
        #expect(model.licenseStatusMessage?.contains("payment") == false)
        #expect(model.licenseStatusMessage?.contains("verified") == true)
    }

    @Test
    func startWaitsForTheInitialSnapshot() async {
        let output = makeOutput()
        let engine = FakeAudioEngine()
        let observers = FakeDefaultOutputObserverFactory()
        let source = FakeLicenseSnapshotSource(initial: makeLicenseSnapshot(state: .monthlyActive), gated: true)
        let model = makeModel(
            engine: engine, lookup: FakeDefaultOutputLookup(.success(output)), observers: observers, outputDelay: .zero,
            licensing: .provider(source))

        model.start()
        await settleAsyncWork()
        #expect(observers.observers.isEmpty)
        #expect(model.statusMessage == localized("Checking license..."))
        #expect(model.onboardingAudioCaptureState == .pending)

        source.release()
        await waitUntil { observers.observers.count == 1 }
        observers.observers[0].emit(.success(output))
        await waitUntil { model.lifecycleState == .running }
        #expect(engine.startCalls.count == 1)

        let blockedEngine = FakeAudioEngine()
        let blockedObservers = FakeDefaultOutputObserverFactory()
        let blockedSource = FakeLicenseSnapshotSource(initial: makeLicenseSnapshot(state: .unlicensed), gated: true)
        let blocked = makeModel(
            engine: blockedEngine, observers: blockedObservers, outputDelay: .zero, licensing: .provider(blockedSource))
        blocked.start()
        blockedSource.release()
        await waitUntil { blocked.licenseSnapshot != nil }
        await settleAsyncWork()
        #expect(blockedObservers.observers.isEmpty)
        #expect(blockedEngine.startCalls.isEmpty)
        #expect(blocked.statusMessage == localized("Activate a license to start processing"))
    }

    @Test
    func expiryWhileRunningFadesToIdentityBeforeStopping() async {
        let running = await makeRunningModel()

        running.source.emit(makeLicenseSnapshot(state: .monthlyExpired, sequence: 2))
        await waitUntil { running.engine.stopCallCount >= 1 }

        let identity = running.engine.updateDSPCalls.last
        #expect(identity?.id == running.model.activeProfile.id)
        #expect(identity?.isBypassed == true)
        #expect(identity?.filters == running.model.activeProfile.filters)
        let events = running.engine.events
        let fadeIndex = events.firstIndex(of: "updateDSP:\(running.model.activeProfile.id)")
        let stopIndex = events.firstIndex(of: "stop")
        #expect(fadeIndex != nil && stopIndex != nil && fadeIndex! < stopIndex!)
        #expect(running.engine.muteOutputCallCount == 0)
        #expect(running.engine.resumeOutputCallCount == 0)
        await waitUntil { running.model.statusMessage == expiredText() }
        #expect(running.model.lifecycleState == .stopped)
        #expect(!running.model.isRunning)
        #expect(running.model.statusMessage == expiredText())
    }

    @Test
    func expiryWaitsForTheTransitionToCompleteBeforeStopping() async {
        let running = await makeRunningModel { $0.deferDSPTransitionCompletion = true }

        running.source.emit(makeLicenseSnapshot(state: .monthlyExpired, sequence: 2))
        await waitUntil { running.engine.updateDSPCalls.count == 1 }

        let stoppedEarly = await waitUntil(maxAttempts: 10) { running.engine.stopCallCount > 0 }
        #expect(!stoppedEarly)
        running.engine.completeDSPTransition()
        await waitUntil { running.engine.stopCallCount == 1 }
        #expect(running.engine.events.suffix(2) == ["transitionCompleted", "stop"])
    }

    @Test
    func anEarlierTransitionCannotCompleteTheIdentityFade() async {
        let running = await makeRunningModel { $0.deferDSPTransitionCompletion = true }
        var earlierProfile = running.model.activeProfile
        earlierProfile.preampDB -= 1
        _ = running.engine.updateDSP(profile: earlierProfile)

        running.source.emit(makeLicenseSnapshot(state: .monthlyExpired, sequence: 2))
        await waitUntil { running.engine.updateDSPCalls.count == 2 }

        running.engine.completeDSPTransition()
        let stoppedAfterEarlierTransition = await waitUntil(maxAttempts: 10) {
            running.engine.stopCallCount > 0
        }
        #expect(!stoppedAfterEarlierTransition)

        running.engine.completeDSPTransition()
        await waitUntil { running.engine.stopCallCount == 1 }
    }

    @Test
    func expiryStopsAnywayWhenTheTransitionNeverCompletes() async {
        let running = await makeRunningModel(licenseStopTransitionTimeout: .milliseconds(50)) {
            $0.deferDSPTransitionCompletion = true
        }

        running.source.emit(makeLicenseSnapshot(state: .monthlyExpired, sequence: 2))
        await waitUntil { running.engine.stopCallCount == 1 }

        #expect(running.engine.updateDSPCalls.count == 1)
        await waitUntil { running.model.statusMessage == expiredText() }
        #expect(running.model.statusMessage == expiredText())
    }

    @Test
    func expiryFallsBackToAPlainStopWhenTheHotSwapIsRefused() async {
        let running = await makeRunningModel { $0.updateDSPResult = false }

        running.source.emit(makeLicenseSnapshot(state: .monthlyExpired, sequence: 2))
        await waitUntil(maxAttempts: 20) { running.engine.stopCallCount == 1 }

        #expect(running.engine.stopCallCount == 1)
        #expect(running.engine.events.suffix(2) == ["updateDSP:\(running.model.activeProfile.id)", "stop"])
    }

    @Test
    func expiryDuringABlockedStartDoesNotLeaveTheEngineRunning() async {
        let output = makeOutput(uid: "blocked-output", name: "Blocked Output")
        let engine = FakeAudioEngine()
        engine.blockStart(for: output.uid)
        defer { engine.unblockStart(for: output.uid) }
        let observers = FakeDefaultOutputObserverFactory()
        let source = FakeLicenseSnapshotSource(initial: makeLicenseSnapshot(state: .monthlyActive))
        let model = makeModel(
            engine: engine, lookup: FakeDefaultOutputLookup(.success(output)), observers: observers, outputDelay: .zero,
            licensing: .provider(source))
        await waitUntil { model.licenseSnapshot != nil }
        model.start()
        await waitUntil { observers.observers.count == 1 }
        observers.observers[0].emit(.success(output))
        await waitUntil { engine.startCalls.count == 1 }
        #expect(engine.waitUntilStartIsBlocked(for: output.uid, timeout: .now() + 1))

        source.emit(makeLicenseSnapshot(state: .monthlyExpired, sequence: 2))
        await settleAsyncWork()
        engine.unblockStart(for: output.uid)
        await waitUntil { engine.stopCallCount >= 1 }
        await settleAsyncWork()

        #expect(engine.state == .stopped)
        #expect(engine.startCalls.count == 1)
        #expect(engine.events.last == "stop")
        let events = engine.events
        if let fadeIndex = events.firstIndex(of: "updateDSP:\(model.activeProfile.id)") {
            #expect(fadeIndex < events.firstIndex(of: "stop")!)
        }
        #expect(model.lifecycleState == .stopped)
    }

    @Test
    func expiryDuringAMutedOutputChangeDoesNotResumeOrRestart() async {
        let running = await makeRunningModel(outputDelay: .milliseconds(400))
        let other = makeOutput(uid: "other-output", name: "Other Output", id: 300)

        running.observers.observers[0].emit(.success(other))
        await waitUntil { running.engine.muteOutputCallCount == 1 }
        running.source.emit(makeLicenseSnapshot(state: .monthlyExpired, sequence: 2))
        await waitUntil { running.engine.stopCallCount >= 1 }
        await settleAsyncWork()

        #expect(running.engine.resumeOutputCallCount == 0)
        #expect(running.engine.startCalls.count == 1)
        #expect(running.model.lifecycleState == .stopped)
    }

    @Test
    func expiryDuringAStoppedOutputChangeDoesNotRestartAfterSettling() async {
        let running = await makeRunningModel(outputDelay: .milliseconds(100))
        let changed = makeOutput(
            uid: running.output.uid, name: running.output.name, nominalSampleRate: 44_100, bufferFrameSize: 512)

        running.observers.observers[0].emit(.success(changed))
        await waitUntil { running.engine.stopCallCount == 1 }
        running.source.emit(makeLicenseSnapshot(state: .monthlyExpired, sequence: 2))
        try? await Task.sleep(for: .milliseconds(300))

        #expect(running.engine.startCalls.count == 1)
        #expect(running.model.lifecycleState == .stopped)
        #expect(running.model.statusMessage == expiredText())
    }

    @Test
    func expiryWhileSleepingKeepsTheEngineStoppedThroughWake() async {
        let running = await makeRunningModel()

        running.model.handleWillSleep()
        await waitUntil { running.engine.stopCallCount == 1 }
        running.source.emit(makeLicenseSnapshot(state: .monthlyExpired, sequence: 2))
        await waitUntil { running.model.licenseSnapshot?.sequence == 2 }
        #expect(running.model.lifecycleState == .sleeping)
        running.model.handleDidWake()
        await settleAsyncWork()

        #expect(running.engine.startCalls.count == 1)
        #expect(running.observers.observers.count == 1)
        #expect(running.model.lifecycleState == .stopped)
        #expect(running.model.statusMessage == expiredText())
    }

    @Test
    func renewalDuringSleepAfterAnExpiryFadeResumesOnWake() async throws {
        let running = await makeRunningModel { $0.deferDSPTransitionCompletion = true }

        running.source.emit(makeLicenseSnapshot(state: .monthlyExpired, sequence: 2))
        await waitUntil { running.engine.updateDSPCalls.count == 1 }
        running.model.handleWillSleep()
        await waitUntil { running.engine.stopCallCount == 1 }

        running.source.emit(makeLicenseSnapshot(state: .monthlyActive, sequence: 3))
        await waitUntil { running.model.licenseSnapshot?.sequence == 3 }
        #expect(running.model.lifecycleState == .sleeping)

        running.model.handleDidWake()
        try #require(running.model.lifecycleState == .waking)
        running.engine.completeDSPTransition()
        await settleAsyncWork()
        await waitUntil { running.observers.observers.count == 2 }
        try #require(running.observers.observers.count == 2)
        running.observers.observers[1].emit(.success(running.output))
        await waitUntil {
            running.model.lifecycleState == .running && running.engine.startCalls.count == 2
        }
    }

    @Test
    func expiryDuringTerminationLeavesTerminationToStopTheEngine() async {
        let running = await makeRunningModel()
        let stopCountAtShutdown = StopCountRecorder()
        running.source.onShutdown = { [engine = running.engine] in
            stopCountAtShutdown.record(engine.stopCallCount)
        }

        let termination = Task { await running.model.cleanupForTerminationAndWait() }
        running.source.emit(makeLicenseSnapshot(state: .monthlyExpired, sequence: 2))
        await termination.value
        await settleAsyncWork()

        #expect(running.model.lifecycleState == .terminating)
        #expect(running.engine.state == .stopped)
        #expect(running.engine.startCalls.count == 1)
        #expect(running.source.checkpointCount == 1)
        #expect(stopCountAtShutdown.value == 1)
    }

    @Test
    func runtimeFailureDuringTheFadeStillRestoresDryPlayback() async {
        let running = await makeRunningModel(licenseStopTransitionTimeout: .milliseconds(50)) {
            $0.deferDSPTransitionCompletion = true
        }

        running.source.emit(makeLicenseSnapshot(state: .monthlyExpired, sequence: 2))
        await waitUntil { running.engine.updateDSPCalls.count == 1 }
        running.engine.emitRuntimeFailure(adaptiveRenderFailure)
        await waitUntil { running.engine.stopCallCount == 1 }
        await waitUntil { running.model.statusMessage == expiredText() }

        #expect(running.model.statusMessage == expiredText())
        #expect(running.model.lifecycleState == .stopped)
    }

    @Test
    func restartRequestsWhileUnlicensedNeverStartTheTap() async {
        let engine = FakeAudioEngine()
        let observers = FakeDefaultOutputObserverFactory()
        let source = FakeLicenseSnapshotSource(initial: makeLicenseSnapshot(state: .unlicensed))
        let model = makeModel(
            engine: engine, observers: observers, outputDelay: .zero, wakeDelay: .zero, licensing: .provider(source))
        await waitUntil { model.licenseSnapshot != nil }

        model.start()
        model.retryAudioEngine()
        model.setBypass(true)
        model.setBypass(false)
        model.startAudioForOnboarding()
        model.handleSessionDidBecomeActive()
        await settleAsyncWork()

        #expect(engine.startCalls.isEmpty)
        #expect(observers.observers.isEmpty)
        #expect(model.lifecycleState == .stopped)
        #expect(model.statusMessage == localized("Activate a license to start processing"))
    }

    @Test
    func renewalAfterExpiryResumesThroughTheNormalStartPath() async {
        let running = await makeRunningModel()

        running.source.emit(makeLicenseSnapshot(state: .monthlyExpired, sequence: 2))
        await waitUntil { running.engine.stopCallCount == 1 && running.model.statusMessage == expiredText() }
        running.source.emit(makeLicenseSnapshot(state: .monthlyActive, sequence: 3))
        await waitUntil { running.observers.observers.count == 2 }
        running.observers.observers[1].emit(.success(running.output))
        await waitUntil { running.model.lifecycleState == .running && running.engine.startCalls.count == 2 }

        #expect(running.model.isRunning)
        #expect(running.model.licenseStatusMessage == nil)
        #expect(running.engine.events.suffix(2) == ["stop", "start:\(running.output.uid)"])
    }

    @Test
    func renewalDoesNotRestartAudioAfterTheUserStoppedIt() async {
        let running = await makeRunningModel()

        running.model.stop()
        await waitUntil { running.engine.stopCallCount == 1 }
        running.source.emit(makeLicenseSnapshot(state: .monthlyExpired, sequence: 2))
        await waitUntil { running.model.licenseSnapshot?.sequence == 2 }
        running.source.emit(makeLicenseSnapshot(state: .monthlyActive, sequence: 3))
        await settleAsyncWork()

        #expect(running.engine.startCalls.count == 1)
        #expect(running.observers.observers.count == 1)
        #expect(running.model.lifecycleState == .stopped)
    }

    @Test
    func renewalArrivingDuringTheFadeStartsOnlyAfterTheStop() async {
        let running = await makeRunningModel { $0.deferDSPTransitionCompletion = true }

        running.source.emit(makeLicenseSnapshot(state: .monthlyExpired, sequence: 2))
        await waitUntil { running.engine.updateDSPCalls.count == 1 }
        running.source.emit(makeLicenseSnapshot(state: .monthlyActive, sequence: 3))
        await settleAsyncWork()
        #expect(running.engine.stopCallCount == 0)
        running.engine.completeDSPTransition()
        await waitUntil { running.observers.observers.count == 2 }
        running.observers.observers[1].emit(.success(running.output))
        await waitUntil { running.engine.startCalls.count == 2 }

        let events = running.engine.events
        let fade = events.firstIndex(of: "updateDSP:\(running.model.activeProfile.id)")!
        let stop = events.firstIndex(of: "stop")!
        let restart = events.lastIndex(of: "start:\(running.output.uid)")!
        #expect(fade < stop && stop < restart)
    }

    @Test
    func staleSnapshotSequencesAreIgnored() async {
        let running = await makeRunningModel()

        running.source.emit(makeLicenseSnapshot(state: .monthlyExpired, sequence: 3))
        await waitUntil { running.engine.stopCallCount == 1 && running.model.statusMessage == expiredText() }
        running.source.emit(makeLicenseSnapshot(state: .monthlyActive, sequence: 2))
        await settleAsyncWork()

        #expect(running.model.lifecycleState == .stopped)
        #expect(running.observers.observers.count == 1)
        #expect(running.model.licenseSnapshot?.sequence == 3)
    }

    @Test
    func graceAndRecoverySnapshotsKeepProcessing() async {
        let running = await makeRunningModel()

        running.source.emit(makeLicenseSnapshot(state: .monthlyGrace, sequence: 2, expiresAt: 1_800_000_000))
        await waitUntil { running.model.licenseSnapshot?.sequence == 2 }
        running.source.emit(makeLicenseSnapshot(state: .monthlyRecovery, sequence: 3))
        await waitUntil { running.model.licenseSnapshot?.sequence == 3 }
        await settleAsyncWork()

        #expect(running.model.isRunning)
        #expect(running.engine.updateDSPCalls.isEmpty)
        #expect(running.engine.stopCallCount == 0)
        #expect(running.model.licenseStatusMessage != nil)
    }

    @Test(arguments: [false, true])
    func aRevocationPublishedBeforeTheInitialSnapshotIsNotRewound(autoStart: Bool) async {
        let output = makeOutput()
        let engine = FakeAudioEngine()
        let observers = FakeDefaultOutputObserverFactory()
        let source = FakeLicenseSnapshotSource(
            initial: makeLicenseSnapshot(state: .monthlyActive, sequence: 1),
            emittingBeforeReturning: makeLicenseSnapshot(state: .monthlyExpired, sequence: 2)
        )
        let model = makeModel(
            engine: engine,
            lookup: FakeDefaultOutputLookup(.success(output)),
            observers: observers,
            outputDelay: .zero,
            licensing: .provider(source),
            autoStart: autoStart
        )
        if !autoStart {
            model.start()
        }
        await waitUntil { model.licenseSnapshot != nil }
        await settleAsyncWork()

        #expect(model.licenseSnapshot?.sequence == 2)
        #expect(model.licenseSnapshot?.content.state == .monthlyExpired)
        #expect(engine.startCalls.isEmpty)
        #expect(observers.observers.isEmpty)
        #expect(model.lifecycleState == .stopped)
        #expect(model.statusMessage == expiredText())
    }

    @Test
    func bypassTogglesWhileUnlicensedKeepTheLicensingReason() async {
        let engine = FakeAudioEngine()
        let source = FakeLicenseSnapshotSource(initial: makeLicenseSnapshot(state: .unlicensed))
        let model = makeModel(engine: engine, outputDelay: .zero, licensing: .provider(source))
        await waitUntil { model.licenseSnapshot != nil }
        model.start()

        model.setBypass(true)
        await settleAsyncWork()
        #expect(model.statusMessage == localized("Activate a license to start processing"))
        model.setBypass(false)
        await settleAsyncWork()

        #expect(model.statusMessage == localized("Activate a license to start processing"))
        #expect(engine.startCalls.isEmpty)
    }

    @Test
    func aLicenseStopBeforeSleepKeepsItsReasonAfterWake() async {
        let source = FakeLicenseSnapshotSource(initial: makeLicenseSnapshot(state: .unlicensed))
        let model = makeModel(outputDelay: .zero, wakeDelay: .zero, licensing: .provider(source))
        await waitUntil { model.licenseSnapshot != nil }
        model.start()

        model.handleWillSleep()
        #expect(model.statusMessage == localized("Paused for system sleep"))
        model.handleDidWake()
        await settleAsyncWork()

        #expect(model.lifecycleState == .stopped)
        #expect(model.statusMessage == localized("Activate a license to start processing"))
    }

    @Test
    func invalidConfigurationNeverStartsAndNamesTheProblem() async {
        let engine = FakeAudioEngine()
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
            engine: engine, observers: observers, outputDelay: .zero, licensing: .invalidConfiguration)

        model.start()
        await settleAsyncWork()

        #expect(engine.startCalls.isEmpty)
        #expect(observers.observers.isEmpty)
        #expect(model.statusMessage == localized("This build's license configuration is invalid"))
        #expect(model.onboardingAudioCaptureState == .failed(message: model.statusMessage))
    }
}

private func makeLicenseSnapshot(
    state: LicenseState,
    sequence: UInt64 = 1,
    billingState: MonthlyBillingState? = nil,
    expiresAt: Int64? = nil,
    activation: ActivationAvailability? = nil
) -> LicenseSnapshot {
    let terms: MonthlyTerms? =
        switch state {
        case .perpetual: nil
        case .monthlyActive, .monthlyRecovery, .monthlyGrace, .monthlyExpired, .verificationNeeded:
            MonthlyTerms(
                billingState: billingState ?? .active,
                billingPeriodEnd: 0,
                recoveryUntil: 0,
                refreshAfter: 0,
                expiresAt: expiresAt ?? 0
            )
        case .unlicensed, .invalidEntitlement, .storageUnavailable: nil
        }
    return LicenseSnapshot(
        sequence: sequence,
        content: LicenseSnapshotContent(
            state: state,
            terms: terms,
            activation: activation ?? defaultAvailability(for: state)
        )
    )
}

private func defaultAvailability(for state: LicenseState) -> ActivationAvailability {
    switch state {
    case .unlicensed, .invalidEntitlement: .available
    case .storageUnavailable: .storageUnavailable
    case .perpetual, .monthlyActive, .monthlyRecovery, .monthlyGrace, .monthlyExpired, .verificationNeeded: .activated
    }
}

private final class FakeLicenseSnapshotSource: LicensingProviding, @unchecked Sendable {
    private let lock = NSLock()
    private let initial: LicenseSnapshot
    private var handler: (@Sendable (LicenseSnapshot) -> Void)?
    private var gateIsOpen: Bool
    private var gateWaiters: [CheckedContinuation<Void, Never>] = []
    private var operationGateIsOpen = true
    private var operationWaiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private var _activationResult: Result<LicenseSnapshot, LicensingError> = .failure(.service(.transport(.other)))
    private var _deactivationResult: Result<LicenseSnapshot, LicensingError> = .failure(.service(.transport(.other)))
    private var _activatedKeys: [String] = []
    private var _deactivationCount = 0
    private var _checkpointCount = 0
    private var _onShutdown: (@Sendable () -> Void)?
    /// Delivered through the handler before `subscribe` returns, as a refresh that completes
    /// while the subscriber is still resuming would be.
    private let emittedBeforeReturning: LicenseSnapshot?

    init(initial: LicenseSnapshot, gated: Bool = false, emittingBeforeReturning: LicenseSnapshot? = nil) {
        self.initial = initial
        gateIsOpen = !gated
        emittedBeforeReturning = emittingBeforeReturning
    }

    var checkpointCount: Int { lock.withLock { _checkpointCount } }
    var activatedKeys: [String] { lock.withLock { _activatedKeys } }
    var deactivationCount: Int { lock.withLock { _deactivationCount } }

    var onShutdown: (@Sendable () -> Void)? {
        get { lock.withLock { _onShutdown } }
        set { lock.withLock { _onShutdown = newValue } }
    }

    /// What `activate` does once released: return the snapshot after publishing it, or throw.
    var activationResult: Result<LicenseSnapshot, LicensingError> {
        get { lock.withLock { _activationResult } }
        set { lock.withLock { _activationResult = newValue } }
    }

    var deactivationResult: Result<LicenseSnapshot, LicensingError> {
        get { lock.withLock { _deactivationResult } }
        set { lock.withLock { _deactivationResult = newValue } }
    }

    func subscribe(_ handler: @escaping @Sendable (LicenseSnapshot) -> Void) async -> LicenseSnapshot {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock {
                if gateIsOpen { return true }
                gateWaiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
        lock.withLock { self.handler = handler }
        if let emittedBeforeReturning {
            handler(emittedBeforeReturning)
        }
        return initial
    }

    func release() {
        let waiters = lock.withLock {
            gateIsOpen = true
            defer { gateWaiters.removeAll() }
            return gateWaiters
        }
        waiters.forEach { $0.resume() }
    }

    func emit(_ snapshot: LicenseSnapshot) {
        lock.withLock { handler }?(snapshot)
    }

    /// Holds every operation until `releaseOperations()`. A held operation still honours task
    /// cancellation, like the controller's network call does.
    func holdOperations() {
        lock.withLock { operationGateIsOpen = false }
    }

    func releaseOperations() {
        let waiters = lock.withLock {
            operationGateIsOpen = true
            defer { operationWaiters.removeAll() }
            return Array(operationWaiters.values)
        }
        waiters.forEach { $0.resume() }
    }

    func activate(licenseKey: String) async throws(LicensingError) -> LicenseSnapshot {
        lock.withLock { _activatedKeys.append(licenseKey) }
        try await waitForOperationGate()
        return try complete(activationResult)
    }

    func deactivateCurrent() async throws(LicensingError) -> LicenseSnapshot {
        lock.withLock { _deactivationCount += 1 }
        try await waitForOperationGate()
        return try complete(deactivationResult)
    }

    private func waitForOperationGate() async throws(LicensingError) {
        let id = UUID()
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    let resumeNow = lock.withLock {
                        if operationGateIsOpen { return true }
                        operationWaiters[id] = continuation
                        return false
                    }
                    if resumeNow { continuation.resume() }
                }
            } onCancel: {
                let waiter = lock.withLock { operationWaiters.removeValue(forKey: id) }
                waiter?.resume(throwing: LicensingError.service(.cancelled))
            }
        } catch {
            // The only error the gate resumes with is the cancellation above.
            throw LicensingError.service(.cancelled)
        }
    }

    private func complete(_ result: Result<LicenseSnapshot, LicensingError>) throws(LicensingError) -> LicenseSnapshot {
        switch result {
        case .success(let snapshot):
            // Like the controller: the handler fires from inside the request, before it returns.
            emit(snapshot)
            return snapshot
        case .failure(let error):
            throw error
        }
    }

    func checkpoint() async {
        lock.withLock { _checkpointCount += 1 }
    }

    func shutdown() async {
        onShutdown?()
    }
}

private final class StopCountRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Int?

    var value: Int? { lock.withLock { _value } }

    func record(_ count: Int) {
        lock.withLock { _value = count }
    }
}

@MainActor
@Suite
struct LicenseActivationOnboardingTests {
    private func limitMessage() -> String {
        LicenseOperationFailureMessage.text(
            for: LicensingError.service(.service(code: .activationLimit, retryAfterSeconds: nil))
        )
    }

    @Test
    func sourceBuildsHaveNoActivationStep() {
        let model = makeModel()

        #expect(model.onboardingLicenseState == nil)
    }

    @Test
    func anInvalidPackagedConfigurationShowsAnUnavailableStep() {
        let model = makeModel(licensing: .invalidConfiguration)

        guard case let .unavailable(message, nil)? = model.onboardingLicenseState else {
            Issue.record("expected an unavailable step, got \(String(describing: model.onboardingLicenseState))")
            return
        }
        #expect(message.contains("configuration is invalid"))

        model.activateLicense(key: "GEQ1-KEY")
        #expect(model.onboardingLicenseState?.isSettled == false)
    }

    @Test
    func theStepChecksUntilTheFirstSnapshotThenAsksForAKey() async {
        let source = FakeLicenseSnapshotSource(initial: makeLicenseSnapshot(state: .unlicensed), gated: true)
        let model = makeModel(licensing: .provider(source))

        #expect(model.onboardingLicenseState == .checking)

        source.release()
        await waitUntil { model.licenseSnapshot != nil }

        #expect(model.onboardingLicenseState == .awaitingKey(notice: nil, failure: nil))
    }

    @Test
    func aMalformedStoredRecordCarriesANoticeButStillTakesAKey() async {
        let source = FakeLicenseSnapshotSource(
            initial: makeLicenseSnapshot(state: .invalidEntitlement, activation: .available))
        let model = makeModel(licensing: .provider(source))
        await waitUntil { model.licenseSnapshot != nil }

        #expect(
            model.onboardingLicenseState
                == .awaitingKey(
                    notice: localized("The stored license is invalid. Activate again to continue."),
                    failure: nil
                ))
    }

    @Test
    func anUnusableRecordOffersRemovalInsteadOfAKeyForm() async {
        let source = FakeLicenseSnapshotSource(
            initial: makeLicenseSnapshot(state: .invalidEntitlement, activation: .needsRemoval))
        source.deactivationResult = .success(makeLicenseSnapshot(state: .unlicensed, sequence: 2))
        let model = makeModel(licensing: .provider(source))
        await waitUntil { model.licenseSnapshot != nil }

        guard case .replaceable(_, nil)? = model.onboardingLicenseState else {
            Issue.record("expected the removal offer, got \(String(describing: model.onboardingLicenseState))")
            return
        }

        model.removeStoredLicense()
        await waitUntil { model.onboardingLicenseState == .awaitingKey(notice: nil, failure: nil) }

        #expect(source.deactivationCount == 1)
        #expect(source.activatedKeys.isEmpty)
    }

    @Test
    func recordsThatNeedANewerAppAreNotOfferedForRemoval() async {
        let source = FakeLicenseSnapshotSource(
            initial: makeLicenseSnapshot(state: .invalidEntitlement, activation: .needsAppUpdate))
        let model = makeModel(licensing: .provider(source))
        await waitUntil { model.licenseSnapshot != nil }

        guard case let .unavailable(message, nil)? = model.onboardingLicenseState else {
            Issue.record("expected no action, got \(String(describing: model.onboardingLicenseState))")
            return
        }
        #expect(message.contains("newer version"))
    }

    @Test
    func expiryOffersRenewalUnlessTheSlotWasReleasedElsewhere() async {
        let expired = FakeLicenseSnapshotSource(initial: makeLicenseSnapshot(state: .monthlyExpired))
        let revoked = FakeLicenseSnapshotSource(
            initial: makeLicenseSnapshot(state: .monthlyExpired, activation: .revoked))
        revoked.deactivationResult = .success(makeLicenseSnapshot(state: .unlicensed, sequence: 2))
        let expiredModel = makeModel(licensing: .provider(expired))
        let revokedModel = makeModel(licensing: .provider(revoked))
        await waitUntil { expiredModel.licenseSnapshot != nil && revokedModel.licenseSnapshot != nil }

        guard case let .expired(detail, nil)? = expiredModel.onboardingLicenseState else {
            Issue.record("expected the renewal state, got \(String(describing: expiredModel.onboardingLicenseState))")
            return
        }
        #expect(detail.contains("Renew"))
        #expect(expiredModel.onboardingLicenseState?.isSettled == true)

        guard case let .replaceable(notice, nil)? = revokedModel.onboardingLicenseState else {
            Issue.record("expected the removal offer, got \(String(describing: revokedModel.onboardingLicenseState))")
            return
        }
        #expect(notice.contains("released"))
        #expect(!notice.contains("Renew"))

        revokedModel.removeStoredLicense()
        await waitUntil { revokedModel.onboardingLicenseState == .awaitingKey(notice: nil, failure: nil) }
        #expect(revoked.deactivationCount == 1)

        // An ordinary expired record can also make way for a different key.
        expired.deactivationResult = .success(makeLicenseSnapshot(state: .unlicensed, sequence: 2))
        expiredModel.removeStoredLicense()
        await waitUntil { expiredModel.onboardingLicenseState == .awaitingKey(notice: nil, failure: nil) }
    }

    @Test
    func aPendingReleaseAndAnUnreadableKeychainShowNoForm() async {
        let releasing = FakeLicenseSnapshotSource(
            initial: makeLicenseSnapshot(state: .unlicensed, activation: .releasingPreviousActivation))
        let unreadable = FakeLicenseSnapshotSource(initial: makeLicenseSnapshot(state: .storageUnavailable))
        let releasingModel = makeModel(licensing: .provider(releasing))
        let unreadableModel = makeModel(licensing: .provider(unreadable))
        await waitUntil { releasingModel.licenseSnapshot != nil && unreadableModel.licenseSnapshot != nil }

        guard case let .unavailable(releasingMessage, nil)? = releasingModel.onboardingLicenseState,
            case let .unavailable(unreadableMessage, nil)? = unreadableModel.onboardingLicenseState
        else {
            Issue.record("expected both to hide the key form")
            return
        }
        #expect(releasingMessage.contains("released"))
        #expect(unreadableMessage.contains("Keychain"))
    }

    @Test
    func theMenuBarStatusNamesTheSameRecoveryAsTheStep() async {
        let cases: [(ActivationAvailability, LicenseState)] = [
            (.available, .unlicensed),
            (.available, .invalidEntitlement),
            (.needsRemoval, .invalidEntitlement),
            (.needsAppUpdate, .invalidEntitlement),
            (.releasingPreviousActivation, .unlicensed),
            (.storageUnavailable, .storageUnavailable),
            (.revoked, .monthlyExpired),
        ]
        for (availability, state) in cases {
            let source = FakeLicenseSnapshotSource(initial: makeLicenseSnapshot(state: state, activation: availability))
            let model = makeModel(licensing: .provider(source))
            await waitUntil { model.licenseSnapshot != nil }
            model.start()
            await settleAsyncWork()

            let expected: String
            switch model.onboardingLicenseState {
            case let .awaitingKey(notice, _)?:
                expected = notice ?? localized("Activate a license to start processing")
            case let .replaceable(notice, _)?:
                expected = notice
            case let .unavailable(message, _)?:
                expected = message
            default:
                Issue.record("unexpected step state for \(availability)")
                continue
            }
            #expect(model.statusMessage == expected, "availability \(availability)")
            #expect(!model.statusMessage.contains("Activate again") || availability == .available)
        }
    }

    @Test
    func successfulActivationSettlesTheStepWithTheTrimmedKey() async {
        let source = FakeLicenseSnapshotSource(initial: makeLicenseSnapshot(state: .unlicensed))
        source.activationResult = .success(makeLicenseSnapshot(state: .perpetual, sequence: 2))
        let model = makeModel(licensing: .provider(source))
        await waitUntil { model.licenseSnapshot != nil }

        model.activateLicense(key: "  GEQ1-TEST-KEY \n")
        await waitUntil { model.onboardingLicenseState?.isSettled == true }

        #expect(source.activatedKeys == ["GEQ1-TEST-KEY"])
        #expect(model.licenseSnapshot?.content.state == .perpetual)
        #expect(
            model.onboardingLicenseState
                == .activated(detail: localized("Perpetual license. Every v1 update is included.")))
    }

    @Test
    func activationShowsProgressAndIgnoresASecondRequestWhileInFlight() async {
        let source = FakeLicenseSnapshotSource(initial: makeLicenseSnapshot(state: .unlicensed))
        source.activationResult = .success(makeLicenseSnapshot(state: .monthlyActive, sequence: 2))
        source.holdOperations()
        let model = makeModel(licensing: .provider(source))
        await waitUntil { model.licenseSnapshot != nil }

        model.activateLicense(key: "GEQ1-FIRST")
        #expect(model.onboardingLicenseState == .working(localized("Activating…")))
        model.activateLicense(key: "GEQ1-SECOND")
        model.removeStoredLicense()
        await waitUntil { source.activatedKeys.count == 1 }
        #expect(source.activatedKeys == ["GEQ1-FIRST"])
        #expect(source.deactivationCount == 0)

        source.releaseOperations()
        await waitUntil { model.onboardingLicenseState?.isSettled == true }

        #expect(model.onboardingLicenseState == .activated(detail: localized("Monthly subscription, active.")))
    }

    @Test
    func activationFailureKeepsTheFormAndExplainsIt() async {
        let source = FakeLicenseSnapshotSource(initial: makeLicenseSnapshot(state: .unlicensed))
        source.activationResult = .failure(.service(.service(code: .activationLimit, retryAfterSeconds: nil)))
        let model = makeModel(licensing: .provider(source))
        await waitUntil { model.licenseSnapshot != nil }

        model.activateLicense(key: "GEQ1-FULL")
        await waitUntil { model.onboardingLicenseState == .awaitingKey(notice: nil, failure: limitMessage()) }

        #expect(model.licenseSnapshot?.content.state == .unlicensed)

        // The next attempt clears the old explanation while it runs.
        source.holdOperations()
        model.activateLicense(key: "GEQ1-RETRY")
        #expect(model.onboardingLicenseState == .working(localized("Activating…")))
        source.releaseOperations()
        await waitUntil { model.onboardingLicenseState == .awaitingKey(notice: nil, failure: limitMessage()) }
    }

    @Test
    func aBlankKeyIsRejectedWithoutContactingTheService() async {
        let source = FakeLicenseSnapshotSource(initial: makeLicenseSnapshot(state: .unlicensed))
        let model = makeModel(licensing: .provider(source))
        await waitUntil { model.licenseSnapshot != nil }

        model.activateLicense(key: "   ")

        #expect(source.activatedKeys.isEmpty)
        #expect(
            model.onboardingLicenseState
                == .awaitingKey(
                    notice: nil,
                    failure: LicenseOperationFailureMessage.text(for: LicensingError.service(.invalidLicenseKey))
                ))
    }

    @Test
    func aFreshLaunchKeepsTheCaptureStepIdleUntilAudioIsRequested() async {
        let output = makeOutput()
        let observers = FakeDefaultOutputObserverFactory()
        let source = FakeLicenseSnapshotSource(initial: makeLicenseSnapshot(state: .unlicensed))
        source.activationResult = .success(makeLicenseSnapshot(state: .perpetual, sequence: 2))
        let model = makeModel(
            lookup: FakeDefaultOutputLookup(.success(output)),
            observers: observers,
            outputDelay: .zero,
            licensing: .provider(source)
        )
        await waitUntil { model.licenseSnapshot != nil }

        // Nothing was requested yet, so the capture step must not claim a failure.
        #expect(model.onboardingAudioCaptureState == .idle)
        #expect(model.statusMessage == localized("Activate a license to start processing"))

        model.activateLicense(key: "GEQ1-FRESH")
        await waitUntil { model.onboardingLicenseState?.isSettled == true }
        #expect(model.onboardingAudioCaptureState == .idle)
        #expect(observers.observers.isEmpty)

        model.startAudioForOnboarding()
        #expect(model.onboardingAudioCaptureState == .pending)
        await waitUntil { observers.observers.count == 1 }
    }

    @Test
    func activatingAfterABlockedStartStartsProcessing() async {
        let output = makeOutput()
        let engine = FakeAudioEngine()
        let observers = FakeDefaultOutputObserverFactory()
        let source = FakeLicenseSnapshotSource(initial: makeLicenseSnapshot(state: .unlicensed))
        source.activationResult = .success(makeLicenseSnapshot(state: .perpetual, sequence: 2))
        let model = makeModel(
            engine: engine,
            lookup: FakeDefaultOutputLookup(.success(output)),
            observers: observers,
            outputDelay: .zero,
            licensing: .provider(source)
        )
        await waitUntil { model.licenseSnapshot != nil }

        // The user skipped activation and pressed Allow on the audio step first.
        model.startAudioForOnboarding()
        await settleAsyncWork()
        #expect(observers.observers.isEmpty)
        #expect(model.statusMessage == localized("Activate a license to start processing"))

        model.activateLicense(key: "GEQ1-LATE")
        await waitUntil { observers.observers.count == 1 }
        observers.observers[0].emit(.success(output))
        await waitUntil { model.lifecycleState == .running }

        #expect(engine.startCalls.count == 1)
        #expect(model.onboardingLicenseState?.isSettled == true)
    }

    @Test
    func quitWaitsForAnInFlightActivationToFinish() async {
        let source = FakeLicenseSnapshotSource(initial: makeLicenseSnapshot(state: .unlicensed))
        source.activationResult = .success(makeLicenseSnapshot(state: .perpetual, sequence: 2))
        source.holdOperations()
        let model = makeModel(licensing: .provider(source))
        await waitUntil { model.licenseSnapshot != nil }
        model.activateLicense(key: "GEQ1-QUIT")
        await waitUntil { source.activatedKeys.count == 1 }

        let finished = StopCountRecorder()
        let cleanup = Task { @MainActor in
            await model.cleanupForTerminationAndWait()
            finished.record(1)
        }
        await settleAsyncWork()
        #expect(finished.value == nil)
        #expect(source.checkpointCount == 0)

        source.releaseOperations()
        await cleanup.value

        #expect(model.licenseSnapshot?.content.state == .perpetual)
        #expect(source.checkpointCount == 1)
    }

    @Test
    func quitCancelsAnActivationThatOutlivesItsGracePeriod() async {
        let source = FakeLicenseSnapshotSource(initial: makeLicenseSnapshot(state: .unlicensed))
        source.holdOperations()
        let model = makeModel(licensing: .provider(source), licenseOperationCancellationGrace: .milliseconds(50))
        await waitUntil { model.licenseSnapshot != nil }
        model.activateLicense(key: "GEQ1-SLOW")
        await waitUntil { source.activatedKeys.count == 1 }

        await model.cleanupForTerminationAndWait()

        #expect(source.checkpointCount == 1)
        #expect(
            model.onboardingLicenseState
                == .awaitingKey(
                    notice: nil,
                    failure: LicenseOperationFailureMessage.text(for: LicensingError.service(.cancelled))
                ))
    }

    @Test
    func nothingStartsOnceTerminationHasBegun() async {
        let source = FakeLicenseSnapshotSource(initial: makeLicenseSnapshot(state: .unlicensed))
        source.activationResult = .success(makeLicenseSnapshot(state: .perpetual, sequence: 2))
        let model = makeModel(licensing: .provider(source))
        await waitUntil { model.licenseSnapshot != nil }

        await model.cleanupForTerminationAndWait()
        model.activateLicense(key: "GEQ1-LATE")
        model.removeStoredLicense()
        await settleAsyncWork()

        #expect(source.activatedKeys.isEmpty)
        #expect(source.deactivationCount == 0)
        #expect(model.onboardingLicenseState == .awaitingKey(notice: nil, failure: nil))
    }
}

@MainActor
private final class FakeLibraryBackupPanels {
    private let exportURL: URL?
    private let importURL: URL?
    private(set) var suggestedNames: [String] = []
    private(set) var importRequests = 0

    init(exportURL: URL? = nil, importURL: URL? = nil) {
        self.exportURL = exportURL
        self.importURL = importURL
    }

    func chooseExportDestination(suggestedName: String) async throws -> URL? {
        suggestedNames.append(suggestedName)
        return exportURL
    }

    func chooseBackupToImport() async throws -> URL? {
        importRequests += 1
        return importURL
    }
}

private func writeLibraryFile(_ store: ProfileStore, beside storeURL: URL) throws -> URL {
    let url = storeURL.deletingLastPathComponent().appendingPathComponent("library.json")
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let backup = ProfileLibraryBackup(
        createdAt: Date(timeIntervalSince1970: 1_700_000_000), appVersion: "beta-0.9.3", profileStore: store)
    try ProfileLibraryBackupCodec.encode(backup).write(to: url)
    return url
}

@MainActor @Suite
struct LibraryImportRegressionTests {
    @Test(arguments: [1, 2], [false, true])
    func failedMigrationBackupProtectsTheStoreFromLaterSaves(schema: Int, danglingReferences: Bool) async throws {
        let url = temporaryAppStoreURL()
        let directory = url.deletingLastPathComponent()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
            removeTemporaryStoreDirectory(for: url)
        }
        let profile = makeProfile(name: "Older library")
        let store = ProfileStore(
            schemaVersion: schema, profiles: [profile], fallbackProfileID: danglingReferences ? UUID() : profile.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = try ProfilePersistence.encoder.encode(store)
        try original.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        let model = GlassEQAppModel(
            storeURL: url, engine: FakeAudioEngine(),
            defaultOutputLookup: FakeDefaultOutputLookup(.success(makeOutput())),
            observerFactory: FakeDefaultOutputObserverFactory(), autoStart: false,
            installLifecycleObservers: false, registerAppDelegate: false,
            launchRecordsDirectory: directory.appendingPathComponent("records"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        #expect(model.settingsSnapshot().profileStoreProtection.isProtected)
        #expect(throws: SettingsCommandFailure.self) { try model.createProfile(kind: .parametric) }
        #expect(await model.flushStoreBeforeQuit())
        #expect(try Data(contentsOf: url) == original)
        await model.cleanupForTerminationAndWait()
        #expect(ProfilePersistence.load(from: url).store.schemaVersion == ProfileStore.currentSchemaVersion)
    }

    @Test(arguments: [(1, false, false), (3, false, false), (1, true, false), (3, true, false), (1, false, true)])
    func rejectedReplacementRestoresTheWholeLibrary(
        profileCount: Int, rebuildRoute: Bool, keepsLaterEdit: Bool
    ) async throws {
        let url = temporaryAppStoreURL()
        defer { removeTemporaryStoreDirectory(for: url) }
        let output = makeOutput(uid: "import-output", name: "Import output")
        let originalProfiles = [makeProfile(name: "Original fallback"), makeProfile(name: "Original active")]
        let original = ProfileStore(
            profiles: originalProfiles,
            outputMappings: [
                OutputDeviceProfileMapping(outputDeviceUID: output.uid, profileID: originalProfiles[1].id)
            ],
            fallbackProfileID: originalProfiles[0].id
        )
        let policyURL = url.deletingPathExtension().appendingPathExtension("aggregate-buffer-policy.json")
        let activeRoute = AggregateAudioRouteFingerprint(
            outputDeviceUID: output.uid, nativeOutputStreamIndex: 0, nominalSampleRate: output.nominalSampleRate)
        let removedRoute = AggregateAudioRouteFingerprint(
            outputDeviceUID: "removed-route", nativeOutputStreamIndex: 0, nominalSampleRate: 48_000)
        let originalPolicy = AggregateBufferPolicyStore(url: policyURL)
        try originalPolicy.setMode(.frames32, for: activeRoute)
        try originalPolicy.setMode(.frames64, for: removedRoute)
        let originalPreferences = try originalPolicy.exportDocument()
        let engine = FakeAudioEngine()
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
            store: original, storeURL: url, engine: engine,
            lookup: FakeDefaultOutputLookup(.success(output)), observers: observers)
        model.start()
        observers.observers[0].emit(.success(output))
        try #require(await waitUntil { model.lifecycleState == .running && engine.startCalls.count == 1 })
        var previousSelection = model.selectedProfileID
        var previousDraft = model.draftProfile
        engine.updateDSPResult = false
        engine.updateError = TestAudioError.updateFailed
        engine.updateErrorPreservesRunningState = true
        engine.startError = TestAudioError.startFailed
        engine.startErrorPreservesRunningState = true
        let incoming = makeStore(profileCount: profileCount)
        let importedActive = incoming.profiles[0]
        if keepsLaterEdit { engine.blockUpdate(for: importedActive.id) }
        defer { engine.unblockUpdate(for: importedActive.id) }
        let preferences = AggregateBufferPolicyStore(url: url.appendingPathExtension("imported-policy"))
        try preferences.setMode(rebuildRoute ? .frames128 : .frames32, for: activeRoute)
        try preferences.setMode(
            .frames128,
            for: AggregateAudioRouteFingerprint(
                outputDeviceUID: "imported-route", nativeOutputStreamIndex: 0, nominalSampleRate: 48_000))
        _ = model.stageLibraryImport(
            ProfileLibraryBackup(
                createdAt: Date(), appVersion: nil, profileStore: incoming,
                bufferPreferences: try preferences.exportDocument()), filename: "library.json")

        _ = try await model.performSettingsCommand(.applyLibraryImport(.replace))
        var expectedStore = original
        if keepsLaterEdit {
            try #require(await waitUntil { engine.updateCalls.count == 1 })
            try model.createProfile(kind: .parametric)
            previousSelection = model.selectedProfileID
            previousDraft = model.draftProfile
            expectedStore.profiles.append(model.draftProfile)
            engine.unblockUpdate(for: importedActive.id)
        }
        try #require(await waitUntil { model.statusMessage.contains("not applied") })

        #expect(try AggregateBufferPolicyStore(url: policyURL).exportDocument() == originalPreferences)
        #expect(model.settingsSnapshot().aggregateBuffer.mode == .frames32)
        #expect(model.profileStore == expectedStore)
        #expect(model.activeProfile == originalProfiles[1])
        #expect(model.selectedProfileID == previousSelection)
        #expect(model.draftProfile == previousDraft)
        #expect(engine.state == .running(output: output))
        #expect(await model.flushStoreBeforeQuit())
        await model.cleanupForTerminationAndWait()
        #expect(ProfilePersistence.load(from: url).store == expectedStore)
    }

    @Test(arguments: [true, false])
    func bufferChangeChecksTheImportedProfileBeforeRebuilding(bypassed: Bool) async throws {
        let url = temporaryAppStoreURL()
        defer { removeTemporaryStoreDirectory(for: url) }
        let output = makeOutput(uid: "import-output", name: "Import output")
        let engine = FakeAudioEngine()
        let observers = FakeDefaultOutputObserverFactory()
        let model = makeModel(
            storeURL: url, engine: engine, lookup: FakeDefaultOutputLookup(.success(output)), observers: observers)
        model.start()
        await waitUntil { observers.observers.count == 1 }
        observers.observers[0].emit(.success(output))
        await waitUntil { model.lifecycleState == .running && engine.startCalls.count == 1 }
        var profile =
            bypassed
            ? makeProfile(name: "Bypassed") : makeImpulseResponseProfile(name: "Wrong rate", sampleRate: 44_100)
        profile.isBypassed = bypassed
        let preferences = AggregateBufferPolicyStore(url: url.appendingPathExtension("imported-policy"))
        try preferences.setMode(.frames128, for: try #require(try engine.aggregateRouteFingerprint(for: output)))
        _ = model.stageLibraryImport(
            ProfileLibraryBackup(
                createdAt: Date(), appVersion: nil, profileStore: ProfileStore(profiles: [profile]),
                bufferPreferences: try preferences.exportDocument()), filename: "library.json")
        _ = try await model.performSettingsCommand(.applyLibraryImport(.replace))
        #expect(!model.isRunning)
        #expect(model.lifecycleState == .stopped)
        #expect(engine.startCalls.count == 1)
        await model.cleanupForTerminationAndWait()
    }

    @Test
    func mergeBuildsItsCandidateAfterEarlierSavesFinish() async throws {
        let url = temporaryAppStoreURL()
        defer { removeTemporaryStoreDirectory(for: url) }
        let gate = LibraryWriteGate()
        defer { gate.release() }
        let original = makeProfile(name: "Original")
        let model = makeModel(store: ProfileStore(profiles: [original]), storeURL: url, writeProfileStore: gate.write)
        var earlier = original
        earlier.name = "Imported"
        try model.apply(profile: earlier)
        await gate.waitUntilEntered()
        let incoming = makeProfile(name: "New profile")
        _ = model.stageLibraryImport(
            ProfileLibraryBackup(createdAt: Date(), appVersion: nil, profileStore: ProfileStore(profiles: [incoming])),
            filename: "library.json")
        let consumed = AsyncStream<Void>.makeStream()
        withObservationTracking {
            _ = model.pendingLibraryImport
        } onChange: {
            consumed.continuation.yield(())
        }
        let importing = Task { try await model.performSettingsCommand(.applyLibraryImport(.merge)) }
        for await _ in consumed.stream { break }
        var edited = original
        edited.name = "Later edit"
        try model.apply(profile: edited)
        gate.release()
        _ = try await importing.value
        #expect(model.profileStore.profiles == [edited, incoming])
        #expect(ProfilePersistence.load(from: url).store == model.profileStore)
        await model.cleanupForTerminationAndWait()
    }

    @Test
    func cancellingAnImportDuringItsWriteRestoresTheCurrentLibrary() async throws {
        let url = temporaryAppStoreURL()
        defer { removeTemporaryStoreDirectory(for: url) }
        let gate = LibraryWriteGate()
        defer { gate.release() }
        let original = ProfileStore(profiles: [makeProfile(name: "Original")])
        let model = makeModel(store: original, storeURL: url, writeProfileStore: gate.write)
        let incoming = ProfileStore(profiles: [makeProfile(name: "Imported")])
        _ = model.stageLibraryImport(
            ProfileLibraryBackup(createdAt: Date(), appVersion: nil, profileStore: incoming), filename: "library.json")
        let importing = Task { try await model.performSettingsCommand(.applyLibraryImport(.replace)) }
        await gate.waitUntilEntered()
        importing.cancel()
        gate.release()
        await #expect(throws: CancellationError.self) { try await importing.value }
        #expect(model.profileStore == original)
        #expect(ProfilePersistence.load(from: url).store == original)
        #expect(model.pendingLibraryImport == nil)
        await model.cleanupForTerminationAndWait()
    }

    @Test(arguments: [true, false])
    func aConcurrentEditIsRestoredToDiskBeforeAnImportIsRefused(restoringOriginal: Bool) async throws {
        let url = temporaryAppStoreURL()
        defer { removeTemporaryStoreDirectory(for: url) }
        let gate = LibraryWriteGate()
        defer { gate.release() }
        let original = makeProfile(name: "Original")
        let model = makeModel(
            store: ProfileStore(profiles: [original]), storeURL: url, saveDelay: .seconds(30),
            writeProfileStore: gate.write)
        let imported = makeProfile(name: "Imported")
        _ = model.stageLibraryImport(
            ProfileLibraryBackup(createdAt: Date(), appVersion: nil, profileStore: ProfileStore(profiles: [imported])),
            filename: "library.json")
        let importing = Task { try await model.performSettingsCommand(.applyLibraryImport(.replace)) }
        await gate.waitUntilEntered()
        var edited = original
        edited.name = "Later edit"
        try model.apply(profile: edited)
        if restoringOriginal { try model.apply(profile: original) }
        gate.release()
        await #expect(
            throws: SettingsCommandFailure(message: "The library changed while the import was being saved. Try again.")
        ) {
            try await importing.value
        }
        #expect(model.profileStore.profiles == [restoringOriginal ? original : edited])
        #expect(ProfilePersistence.load(from: url).store == model.profileStore)
        #expect(model.pendingLibraryImport == nil)
        await model.cleanupForTerminationAndWait()
    }
}

/// Holds the filesystem write while the main actor applies a later edit.
private final class LibraryWriteGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var released = false
    private let entered = AsyncStream<Void>.makeStream()

    func write(_ store: ProfileStore, to url: URL) throws {
        if store.profiles.first?.name == "Imported" {
            condition.lock()
            entered.continuation.yield(())
            while !released { condition.wait() }
            condition.unlock()
        }
        try ProfilePersistence.save(store, to: url)
    }

    func waitUntilEntered() async {
        for await _ in entered.stream { return }
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}
