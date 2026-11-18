import CoreAudio
import Foundation
@testable import GlassEQAudio
import GlassEQCore
import Synchronization
import Testing

@Suite
struct CoreAudioDeviceTests {
    @Test
    func protectedStartupChecksTheLiveRouteBeforeActivation() throws {
        let expected = output(channelCount: 2)
        try SystemTapAudioEngine.validateDefaultOutput(expected) { output(channelCount: 2, bufferFrameSize: 512) }
        for changed in [
            output(id: 43, channelCount: 2),
            output(uid: "another-output", channelCount: 2),
            output(channelCount: 1),
            output(channelCount: 2, sampleRate: 24_000),
        ] {
            #expect(throws: (any Error).self) {
                try SystemTapAudioEngine.validateDefaultOutput(expected) { changed }
            }
        }
    }

    @Test
    func cancelledStartupCannotActivateEvenIfTheOriginalRouteHasReturned() async {
        let expected = output(channelCount: 2)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try SystemTapAudioEngine.validateDefaultOutput(expected) { expected }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test
    func coreAudioCleanupRetainsFailedResourcesForRetry() {
        let counts = Mutex((aggregateDestroyAttempts: 0, tapDestroyAttempts: 0, completionCount: 0))
        let operations = CoreAudioResourceCleanupLedger.Operations(
            stopIOProc: { _, _ in noErr },
            destroyIOProc: { _, _ in noErr },
            destroyAggregate: { _ in
                counts.withLock { counts in
                    counts.aggregateDestroyAttempts += 1
                    return counts.aggregateDestroyAttempts == 1
                        ? kAudioHardwareUnspecifiedError
                        : noErr
                }
            },
            destroyTap: { _ in
                counts.withLock { $0.tapDestroyAttempts += 1 }
                return noErr
            }
        )
        let ledger = CoreAudioResourceCleanupLedger(
            operations: operations,
            preservesFailuresOnDeinit: false,
            automaticRetryDelaysMilliseconds: []
        )

        #expect(
            !ledger.dispose(
                CoreAudioResourceCleanupLedger.PendingResources(
                    operation: "test",
                    aggregateDeviceIDs: [42],
                    tapIDs: [43],
                    completion: { counts.withLock { $0.completionCount += 1 } }
                )))
        #expect(ledger.pendingCount == 1)
        #expect(counts.withLock { $0.tapDestroyAttempts } == 1)
        #expect(counts.withLock { $0.completionCount } == 0)

        #expect(ledger.retryPending())
        #expect(counts.withLock { $0.aggregateDestroyAttempts } == 2)
        #expect(counts.withLock { $0.tapDestroyAttempts } == 1)
        #expect(counts.withLock { $0.completionCount } == 1)
    }

    @Test
    func coreAudioCleanupAutomaticallyRetriesRetainedResources() {
        let attempts = Mutex(0)
        let completed = DispatchSemaphore(value: 0)
        let operations = CoreAudioResourceCleanupLedger.Operations(
            stopIOProc: { _, _ in noErr },
            destroyIOProc: { _, _ in noErr },
            destroyAggregate: { _ in noErr },
            destroyTap: { _ in
                attempts.withLock { attempts in
                    attempts += 1
                    return attempts < 3 ? kAudioHardwareUnspecifiedError : noErr
                }
            }
        )
        let ledger = CoreAudioResourceCleanupLedger(
            operations: operations,
            preservesFailuresOnDeinit: false
        )

        #expect(
            !ledger.dispose(
                CoreAudioResourceCleanupLedger.PendingResources(
                    operation: "destroy muted process tap",
                    tapIDs: [42],
                    completion: { completed.signal() }
                )))
        #expect(completed.wait(timeout: .now() + 2) == .success)
        #expect(attempts.withLock { $0 } == 3)
        #expect(ledger.pendingCount == 0)
    }

    @Test
    func coreAudioCleanupDoesNotHoldStateLockAcrossDestruction() throws {
        let tapOneAttempts = Mutex(0)
        let retryEnteredHAL = DispatchSemaphore(value: 0)
        let releaseHAL = DispatchSemaphore(value: 0)
        let retryFinished = DispatchSemaphore(value: 0)
        let concurrentDisposeFinished = DispatchSemaphore(value: 0)
        let concurrentDisposeResult = Mutex<Bool?>(nil)
        let retryQueue = DispatchQueue(
            label: "com.glasseq.tests.core-audio-cleanup-retry",
            qos: .userInitiated
        )
        let disposeQueue = DispatchQueue(
            label: "com.glasseq.tests.core-audio-cleanup-dispose",
            qos: .userInitiated
        )
        let operations = CoreAudioResourceCleanupLedger.Operations(
            stopIOProc: { _, _ in noErr },
            destroyIOProc: { _, _ in noErr },
            destroyAggregate: { _ in noErr },
            destroyTap: { tapID in
                guard tapID == 1 else {
                    return noErr
                }
                let attempt = tapOneAttempts.withLock { attempts in
                    attempts += 1
                    return attempts
                }
                guard attempt > 1 else {
                    return kAudioHardwareUnspecifiedError
                }
                retryEnteredHAL.signal()
                releaseHAL.wait()
                return noErr
            }
        )
        let ledger = CoreAudioResourceCleanupLedger(
            operations: operations,
            preservesFailuresOnDeinit: false,
            automaticRetryDelaysMilliseconds: []
        )

        #expect(
            !ledger.dispose(
                CoreAudioResourceCleanupLedger.PendingResources(
                    operation: "retain first tap",
                    tapIDs: [1]
                )))
        retryQueue.async {
            _ = ledger.retryPending()
            retryFinished.signal()
        }
        let retryStarted = retryEnteredHAL.wait(timeout: .now() + 5) == .success
        if !retryStarted {
            releaseHAL.signal()
        }
        try #require(retryStarted)

        disposeQueue.async {
            let completed = ledger.dispose(
                CoreAudioResourceCleanupLedger.PendingResources(
                    operation: "queue second tap",
                    tapIDs: [2]
                ))
            concurrentDisposeResult.withLock { $0 = completed }
            concurrentDisposeFinished.signal()
        }
        let disposeReturnedWithoutWaitingForHAL =
            concurrentDisposeFinished.wait(
                timeout: .now() + 5
            ) == .success
        releaseHAL.signal()
        if !disposeReturnedWithoutWaitingForHAL {
            _ = retryFinished.wait(timeout: .now() + 5)
            _ = concurrentDisposeFinished.wait(timeout: .now() + 5)
        }

        try #require(disposeReturnedWithoutWaitingForHAL)
        try #require(retryFinished.wait(timeout: .now() + 5) == .success)
        #expect(concurrentDisposeResult.withLock { $0 } == false)
        #expect(ledger.pendingCount == 1)
        #expect(ledger.retryPending())
        #expect(ledger.pendingCount == 0)
    }

    @Test
    func coreAudioCleanupTreatsAlreadyDestroyedObjectsAsTerminal() {
        #expect(CoreAudioResourceCleanupLedger.isTerminalDestructionStatus(noErr))
        #expect(
            CoreAudioResourceCleanupLedger.isTerminalDestructionStatus(
                kAudioHardwareBadObjectError
            ))
        #expect(
            !CoreAudioResourceCleanupLedger.isTerminalDestructionStatus(
                kAudioHardwareUnspecifiedError
            ))
    }

    @Test
    func realtimeOutputFadeStartsMutedAndReachesUnity() {
        var fade = RealtimeOutputFade(
            sampleRate: 4,
            durationSeconds: 1
        )
        var samples = Array(repeating: Float(1), count: 8)

        fade.setMuted(false)
        samples.withUnsafeMutableBufferPointer {
            fade.apply(to: $0, frameCount: 4, channelCount: 2)
        }

        #expect(samples == [0, 0, 0.15625, 0.15625, 0.5, 0.5, 0.84375, 0.84375])
        #expect(fade.gain == 1)
        #expect(!fade.isMuted)

        samples = [1, 1]
        samples.withUnsafeMutableBufferPointer {
            fade.apply(to: $0, frameCount: 1, channelCount: 2)
        }
        #expect(samples == [1, 1])
    }

    @Test
    func realtimeOutputFadeEndsAtSilence() {
        var fade = RealtimeOutputFade(
            sampleRate: 4,
            initiallyMuted: false,
            durationSeconds: 1
        )
        var samples = Array(repeating: Float(1), count: 4)

        fade.setMuted(true)
        samples.withUnsafeMutableBufferPointer {
            fade.apply(to: $0, frameCount: 4, channelCount: 1)
        }

        #expect(samples == [1, 0.84375, 0.5, 0.15625])
        #expect(fade.gain == 0)
        #expect(fade.isMuted)

        samples = [1]
        samples.withUnsafeMutableBufferPointer {
            fade.apply(to: $0, frameCount: 1, channelCount: 1)
        }
        #expect(samples == [0])
    }

    @Test
    func realtimeOutputFadeReversesWithoutGainJump() {
        var fade = RealtimeOutputFade(
            sampleRate: 4,
            durationSeconds: 1
        )
        var fadeInSamples = Array(repeating: Float(1), count: 2)

        fade.setMuted(false)
        fadeInSamples.withUnsafeMutableBufferPointer {
            fade.apply(to: $0, frameCount: 2, channelCount: 1)
        }
        #expect(fadeInSamples == [0, 0.15625])
        #expect(fade.gain == 0.5)

        var fadeOutSamples = Array(repeating: Float(1), count: 4)
        fade.setMuted(true)
        fadeOutSamples.withUnsafeMutableBufferPointer {
            fade.apply(to: $0, frameCount: 4, channelCount: 1)
        }

        #expect(fadeOutSamples == [0.5, 0.421875, 0.25, 0.078125])
        #expect(fade.isMuted)
    }

    @Test
    func realtimeOutputDeclickerSmoothsAcrossCallbacks() {
        var declicker = RealtimeOutputDeclicker(
            sampleRate: 4,
            channelCount: 1,
            durationSeconds: 1
        )
        var previous = [Float(2)]
        previous.withUnsafeMutableBufferPointer {
            declicker.apply(to: $0, frameCount: 1, channelCount: 1)
        }

        declicker.markDiscontinuity()
        var firstCallback = [Float](repeating: 10, count: 2)
        firstCallback.withUnsafeMutableBufferPointer {
            declicker.apply(to: $0, frameCount: 2, channelCount: 1)
        }
        var secondCallback = [Float](repeating: 10, count: 2)
        secondCallback.withUnsafeMutableBufferPointer {
            declicker.apply(to: $0, frameCount: 2, channelCount: 1)
        }

        #expect(abs(firstCallback[0] - 2) < 0.000_001)
        #expect(abs(firstCallback[1] - 4.074_074) < 0.000_001)
        #expect(abs(secondCallback[0] - 7.925_926) < 0.000_001)
        #expect(abs(secondCallback[1] - 10) < 0.000_001)

        var steadyState = [Float(11)]
        steadyState.withUnsafeMutableBufferPointer {
            declicker.apply(to: $0, frameCount: 1, channelCount: 1)
        }
        #expect(steadyState == [11])
    }

    @Test
    func realtimeOutputDeclickerTreatsChannelsIndependently() {
        var declicker = RealtimeOutputDeclicker(
            sampleRate: 4,
            channelCount: 2,
            durationSeconds: 1
        )
        var previous: [Float] = [2, -3]
        previous.withUnsafeMutableBufferPointer {
            declicker.apply(to: $0, frameCount: 1, channelCount: 2)
        }

        declicker.markDiscontinuity()
        var samples: [Float] = [10, 20, 10, 20, 10, 20, 10, 20]
        samples.withUnsafeMutableBufferPointer {
            declicker.apply(to: $0, frameCount: 4, channelCount: 2)
        }

        #expect(abs(samples[0] - 2) < 0.000_001)
        #expect(abs(samples[1] + 3) < 0.000_001)
        #expect(abs(samples[6] - 10) < 0.000_001)
        #expect(abs(samples[7] - 20) < 0.000_001)
    }

    @Test
    func realtimeOutputDeclickerRestartsFromLastEmittedSample() {
        var declicker = RealtimeOutputDeclicker(
            sampleRate: 4,
            channelCount: 1,
            durationSeconds: 1
        )
        var previous = [Float(2)]
        previous.withUnsafeMutableBufferPointer {
            declicker.apply(to: $0, frameCount: 1, channelCount: 1)
        }

        declicker.markDiscontinuity()
        var interrupted = [Float](repeating: 10, count: 2)
        interrupted.withUnsafeMutableBufferPointer {
            declicker.apply(to: $0, frameCount: 2, channelCount: 1)
        }

        declicker.markDiscontinuity()
        var restarted = [Float](repeating: -5, count: 4)
        restarted.withUnsafeMutableBufferPointer {
            declicker.apply(to: $0, frameCount: 4, channelCount: 1)
        }

        #expect(abs(restarted[0] - interrupted[1]) < 0.000_001)
        #expect(abs(restarted[3] + 5) < 0.000_001)
    }

    @Test
    func realtimeOutputDeclickerDoesNotOvershootReversingWaveform() {
        var declicker = RealtimeOutputDeclicker(
            sampleRate: 4,
            channelCount: 1,
            durationSeconds: 1
        )
        var previous = [Float(1)]
        previous.withUnsafeMutableBufferPointer {
            declicker.apply(to: $0, frameCount: 1, channelCount: 1)
        }

        declicker.markDiscontinuity()
        var samples: [Float] = [-1, 1, -1, 1]
        samples.withUnsafeMutableBufferPointer {
            declicker.apply(to: $0, frameCount: 4, channelCount: 1)
        }

        #expect(samples.allSatisfy { (-1...1).contains($0) })
    }

    @Test
    func defaultOutputQueryDoesNotCrash() throws {
        let device = try CoreAudioDeviceQuery.defaultOutputDevice()

        #expect(!device.name.isEmpty)
        #expect(!device.uid.isEmpty)
        #expect(device.nominalSampleRate > 0)
    }

    @Test
    func systemTapRestoresDryPlaybackWhenItsReaderStops() {
        let description = SystemTapAudioEngine.makeSystemTapDescription(
            excluding: [42],
            outputUID: "test-output",
            streamIndex: 1
        )

        #expect(description.processes == [42])
        #expect(description.bundleIDs == ["systemsoundserverd"])
        #expect(description.isExclusive)
        #expect(description.muteBehavior == .mutedWhenTapped)
        #expect(description.isProcessRestoreEnabled)
    }

    @Test
    func systemSoundTapRestoresDryPlaybackWhenItsReaderStops() {
        let description = SystemTapAudioEngine.makeSystemSoundTapDescription(
            outputUID: "test-output",
            streamIndex: 1
        )

        #expect(description.processes.isEmpty)
        #expect(description.bundleIDs == ["systemsoundserverd"])
        #expect(!description.isExclusive)
        #expect(description.muteBehavior == .mutedWhenTapped)
        #expect(!description.isMixdown)
        #expect(description.isProcessRestoreEnabled)
    }

    @Test
    func combinedTapReuseRequiresTheSameNominalSampleRate() {
        let output = output(
            uid: "same-device",
            channelCount: 2,
            sampleRate: 48_000
        )

        #expect(
            SystemTapAudioEngine.combinedTapMatchesRoute(
                existingOutputUID: output.uid,
                existingOutputStreamIndex: 1,
                existingNominalSampleRate: 48_000,
                output: output,
                outputStreamIndex: 1
            ))
        #expect(
            !SystemTapAudioEngine.combinedTapMatchesRoute(
                existingOutputUID: output.uid,
                existingOutputStreamIndex: 1,
                existingNominalSampleRate: 44_100,
                output: output,
                outputStreamIndex: 1
            ))
    }

    @Test
    func processTapSampleRateMustMatchThePhysicalOutput() {
        #expect(
            SystemTapAudioEngine.tapSampleRateMatchesOutput(
                tapSampleRate: 48_000,
                outputSampleRate: 48_000
            ))
        #expect(
            !SystemTapAudioEngine.tapSampleRateMatchesOutput(
                tapSampleRate: 44_100,
                outputSampleRate: 48_000
            ))
        #expect(
            !SystemTapAudioEngine.tapSampleRateMatchesOutput(
                tapSampleRate: 0,
                outputSampleRate: 48_000
            ))
    }

    @Test
    func aggregateStartupRequiresMatchingFramesAndStableTimestamps() {
        #expect(
            SystemTapAudioEngine.startupCallbackIsValid(
                mainInputFrameCount: 16,
                systemSoundInputFrameCount: 0,
                outputFrameCount: 16,
                expectedFrameCount: 16,
                timestampsAreStable: true
            ))
        #expect(
            SystemTapAudioEngine.startupCallbackIsValid(
                mainInputFrameCount: 16,
                systemSoundInputFrameCount: 16,
                outputFrameCount: 16,
                expectedFrameCount: 16,
                timestampsAreStable: true
            ))
        #expect(
            !SystemTapAudioEngine.startupCallbackIsValid(
                mainInputFrameCount: 512,
                systemSoundInputFrameCount: 512,
                outputFrameCount: 512,
                expectedFrameCount: 16,
                timestampsAreStable: true
            ))
        #expect(
            !SystemTapAudioEngine.startupCallbackIsValid(
                mainInputFrameCount: 16,
                systemSoundInputFrameCount: 16,
                outputFrameCount: 16,
                expectedFrameCount: 16,
                timestampsAreStable: false
            ))
    }

    @Test
    func physicalFirstStartupUsesTheAppliedCallbackSize() {
        let expectation = SystemTapAudioEngine.AggregateCallbackFrameExpectation(
            frameCount: 16
        )

        expectation.update(appliedFrameCount: 32)
        #expect(
            expectation.validateCallback(
                mainInputFrameCount: 32,
                systemSoundInputFrameCount: 32,
                outputFrameCount: 32,
                timestampsAreStable: true
            ).isValid)
        #expect(
            !expectation.validateCallback(
                mainInputFrameCount: 16,
                systemSoundInputFrameCount: 16,
                outputFrameCount: 16,
                timestampsAreStable: true
            ).isValid)

        expectation.update(appliedFrameCount: 512)
        #expect(
            !SystemTapAudioEngine.startupAttemptFrameSizes(
                requestedFrameSize: 16
            ).contains(512))
        #expect(
            expectation.validateCallback(
                mainInputFrameCount: 512,
                systemSoundInputFrameCount: 512,
                outputFrameCount: 512,
                timestampsAreStable: true
            ).isValid)
    }

    @Test
    func appliedCallbackSizeInvalidatesInFlightStartupValidation() {
        let expectation = SystemTapAudioEngine.AggregateCallbackFrameExpectation(
            frameCount: 16
        )
        let staleValidation = expectation.validateCallback(
            mainInputFrameCount: 16,
            systemSoundInputFrameCount: 16,
            outputFrameCount: 16,
            timestampsAreStable: true
        )

        expectation.update(appliedFrameCount: 32)
        expectation.recordCallback(staleValidation, metDeadlines: true)
        #expect(expectation.validCallbackStreak == 0)

        let appliedValidation = expectation.validateCallback(
            mainInputFrameCount: 32,
            systemSoundInputFrameCount: 32,
            outputFrameCount: 32,
            timestampsAreStable: true
        )
        expectation.recordCallback(appliedValidation, metDeadlines: true)
        expectation.recordCallback(staleValidation, metDeadlines: true)
        #expect(expectation.validCallbackStreak == 1)
    }

    @Test
    func aggregateStartupProbationCountsOnlyCallbacksFromTheNewGeneration() {
        let expectation = SystemTapAudioEngine.AggregateCallbackFrameExpectation(
            frameCount: 16
        )
        for _ in 0..<40 {
            let validation = expectation.validateCallback(
                mainInputFrameCount: 16,
                systemSoundInputFrameCount: 16,
                outputFrameCount: 16,
                timestampsAreStable: true
            )
            expectation.recordCallback(validation, metDeadlines: true)
        }
        let inFlightValidation = expectation.validateCallback(
            mainInputFrameCount: 16,
            systemSoundInputFrameCount: 16,
            outputFrameCount: 16,
            timestampsAreStable: true
        )

        expectation.beginProbation()
        expectation.recordCallback(inFlightValidation, metDeadlines: true)

        #expect(expectation.validCallbackStreak == 0)
        for _ in 0..<7 {
            let validation = expectation.validateCallback(
                mainInputFrameCount: 16,
                systemSoundInputFrameCount: 16,
                outputFrameCount: 16,
                timestampsAreStable: true
            )
            expectation.recordCallback(validation, metDeadlines: true)
        }
        #expect(expectation.validCallbackStreak == 7)
        let validation = expectation.validateCallback(
            mainInputFrameCount: 16,
            systemSoundInputFrameCount: 16,
            outputFrameCount: 16,
            timestampsAreStable: true
        )
        expectation.recordCallback(validation, metDeadlines: true)
        #expect(expectation.validCallbackStreak == 8)
    }

    @Test
    func aggregateStartupRetriesBeforeUsingOneSaferBufferRung() {
        #expect(
            SystemTapAudioEngine.startupAttemptFrameSizes(
                requestedFrameSize: 16
            ) == [16, 16, 32])
        #expect(
            SystemTapAudioEngine.startupAttemptFrameSizes(
                requestedFrameSize: 32
            ) == [32, 32, 64])
        #expect(
            SystemTapAudioEngine.startupAttemptFrameSizes(
                requestedFrameSize: 64
            ) == [64, 64, 128])
        #expect(
            SystemTapAudioEngine.startupAttemptFrameSizes(
                requestedFrameSize: 128
            ) == [128, 128])
    }

    @Test
    func unsettledProcessTapFormatIsRetryableDuringAggregateStartup() throws {
        let error = SystemTapAudioEngine.ProcessTapFormatNotSettledError(
            expectedSampleRate: 96_000,
            mainSampleRate: 44_100,
            systemSoundSampleRate: 44_100
        )
        var attempts: [UInt32] = []
        var waitCount = 0

        try SystemTapAudioEngine.runCombinedStartupAttempts(
            frameSizes: [16, 16],
            attempt: { frameSize in
                attempts.append(frameSize)
                if attempts.count == 1 {
                    throw error
                }
            },
            waitBeforeRetry: {
                waitCount += 1
            }
        )

        #expect(attempts == [16, 16])
        #expect(waitCount == 1)
    }

    @Test
    func aggregateStartupTimeoutScalesForLongCallbacks() {
        #expect(
            SystemTapAudioEngine.startupQualificationTimeout(
                frameCount: 16,
                sampleRate: 48_000,
                minimumConsecutiveCallbacks: 32
            ) == 0.25)
        #expect(
            SystemTapAudioEngine.startupQualificationTimeout(
                frameCount: 480,
                sampleRate: 24_000,
                minimumConsecutiveCallbacks: 32
            ) > 1.5)
    }

    @Test
    func aggregateTapValidationReturnsHALStreamOrder() {
        let systemSounds = aggregateTapEntry(uid: "system-sounds")
        let main = aggregateTapEntry(uid: "main")

        let order = SystemTapAudioEngine.validatedAggregateTapUIDOrder(
            [systemSounds, main],
            expectedTapDriftCompensation: ["main": true, "system-sounds": true]
        )

        #expect(order == ["system-sounds", "main"])
    }

    @Test
    func aggregateTapValidationRejectsUnknownOrUncompensatedTap() {
        let main = aggregateTapEntry(uid: "main")
        let unknown = aggregateTapEntry(uid: "unknown")
        let uncompensated = aggregateTapEntry(uid: "system-sounds", drift: false)

        #expect(
            SystemTapAudioEngine.validatedAggregateTapUIDOrder(
                [main, unknown],
                expectedTapDriftCompensation: ["main": true, "system-sounds": true]
            ) == nil)
        #expect(
            SystemTapAudioEngine.validatedAggregateTapUIDOrder(
                [main, uncompensated],
                expectedTapDriftCompensation: ["main": true, "system-sounds": true]
            ) == nil)
    }

    @Test
    func systemSoundPreampUsesPerChannelProfileGains() {
        let profile = EQProfile(
            name: "Stereo",
            mode: .parametric,
            channelMode: .stereo,
            filters: [],
            leftPreampDB: -6,
            rightPreampDB: -12
        )
        let configuration = EQRenderConfiguration(
            profile: profile,
            sampleRate: 48_000,
            channelCount: 2
        )

        let gains = SystemTapAudioEngine.systemSoundPreampGains(for: configuration)

        #expect(abs(gains.left - Float(pow(10, -6.0 / 20))) < 0.000_001)
        #expect(abs(gains.right - Float(pow(10, -12.0 / 20))) < 0.000_001)
    }

    @Test
    func systemSoundPreampUsesUnityGainForBypassedProfile() {
        var profile = EQProfile(
            name: "Bypassed",
            mode: .parametric,
            preampDB: -24,
            filters: []
        )
        profile.isBypassed = true
        let configuration = EQRenderConfiguration(
            profile: profile,
            sampleRate: 48_000,
            channelCount: 2
        )

        let gains = SystemTapAudioEngine.systemSoundPreampGains(for: configuration)

        #expect(gains.left == 1)
        #expect(gains.right == 1)
    }

    @Test
    func metadataValidationRejectsInvalidScalarValues() throws {
        expectInvalidMetadata {
            _ = try CoreAudioDeviceQuery.validatedSampleRate(.infinity, objectID: 42)
        }
        expectInvalidMetadata {
            _ = try CoreAudioDeviceQuery.validatedSampleRate(0, objectID: 42)
        }
        expectInvalidMetadata {
            _ = try CoreAudioDeviceQuery.validatedBufferFrameSize(0, objectID: 42)
        }
        expectInvalidMetadata {
            _ = try CoreAudioDeviceQuery.validatedBufferFrameSize(
                CoreAudioDeviceQuery.maxBufferFrameSize + 1,
                objectID: 42
            )
        }

        #expect(try CoreAudioDeviceQuery.validatedSampleRate(48_000, objectID: 42) == 48_000)
        #expect(try CoreAudioDeviceQuery.validatedBufferFrameSize(256, objectID: 42) == 256)
    }

    @Test
    func availabilityErrorsProvideLocalizedDescriptions() {
        #expect(
            AudioDeviceAvailabilityError.noDefaultOutput.localizedDescription == "No default output device is available"
        )
        #expect(
            AudioDeviceAvailabilityError.outputDeviceNotAlive(42).localizedDescription
                == "Output device 42 is not available")
    }

    @Test
    func engineRuntimeChannelPolicyAcceptsUpToMaxChannelCount() throws {
        #expect(try SystemTapAudioEngine.supportedRuntimeChannelCount(for: output(channelCount: 1)) == 1)
        #expect(try SystemTapAudioEngine.supportedRuntimeChannelCount(for: output(channelCount: 2)) == 2)
        #expect(try SystemTapAudioEngine.supportedRuntimeChannelCount(for: output(channelCount: 6)) == 6)
        #expect(
            try SystemTapAudioEngine.supportedRuntimeChannelCount(
                for: output(channelCount: CoreAudioDeviceQuery.maxChannelCount)
            ) == CoreAudioDeviceQuery.maxChannelCount)

        do {
            _ = try SystemTapAudioEngine.supportedRuntimeChannelCount(for: output(channelCount: 0))
            Issue.record("Expected zero-channel output to be rejected")
        } catch let error as AudioDeviceAvailabilityError {
            #expect(error == .outputDeviceHasNoOutputChannels(42))
        } catch {
            Issue.record("Expected no-output-channels error, got \(error)")
        }

        do {
            _ = try SystemTapAudioEngine.supportedRuntimeChannelCount(
                for: output(channelCount: CoreAudioDeviceQuery.maxChannelCount + 1)
            )
            Issue.record("Expected out-of-range channel count to be rejected")
        } catch let error as AudioDeviceAvailabilityError {
            #expect(error == .unsupportedOutputChannelCount(42, CoreAudioDeviceQuery.maxChannelCount + 1))
        } catch {
            Issue.record("Expected unsupported channel count error, got \(error)")
        }
    }

    @Test
    func playbackCallbackCapacityRejectsFramesAboveFixedRenderStorage() throws {
        try SystemTapAudioEngine.validatePlaybackCallbackCapacity(
            for: output(channelCount: 2, bufferFrameSize: 8_192)
        )

        do {
            try SystemTapAudioEngine.validatePlaybackCallbackCapacity(
                for: output(channelCount: 2, bufferFrameSize: 8_193)
            )
            Issue.record("Expected oversized playback callback to be rejected")
        } catch let error as AudioDeviceAvailabilityError {
            #expect(error == .unsupportedOutputBufferFrameSize(42, 8_193, maximum: 8_192))
        } catch {
            Issue.record("Expected unsupported buffer frame size error, got \(error)")
        }
    }

    @Test
    func tapToOutputLatencyUsesValidHostTimestamps() throws {
        var inputTime = AudioTimeStamp()
        inputTime.mHostTime = AudioConvertNanosToHostTime(1_000_000_000)
        inputTime.mFlags = .hostTimeValid

        let latencyHostTime = AudioConvertNanosToHostTime(2_500_000)
        var outputTime = AudioTimeStamp()
        outputTime.mHostTime = inputTime.mHostTime + latencyHostTime
        outputTime.mFlags = .hostTimeValid

        #expect(
            SystemTapAudioEngine.tapToOutputLatencyNanoseconds(
                inputTime: inputTime,
                outputTime: outputTime
            ) == AudioConvertHostTimeToNanos(latencyHostTime))

        var invalidInputTime = inputTime
        invalidInputTime.mFlags = []
        #expect(
            SystemTapAudioEngine.tapToOutputLatencyNanoseconds(
                inputTime: invalidInputTime,
                outputTime: outputTime
            ) == nil)

        outputTime.mHostTime = inputTime.mHostTime - 1
        #expect(
            SystemTapAudioEngine.tapToOutputLatencyNanoseconds(
                inputTime: inputTime,
                outputTime: outputTime
            ) == nil)
    }

    @Test
    func callbackTimingSplitsInputAgeFromOutputLead() throws {
        var inputTime = AudioTimeStamp()
        inputTime.mHostTime = AudioConvertNanosToHostTime(1_000_000_000)
        inputTime.mFlags = .hostTimeValid

        let inputAgeHostTime = AudioConvertNanosToHostTime(1_875_000)
        let outputLeadHostTime = AudioConvertNanosToHostTime(625_000)
        let callbackHostTime = inputTime.mHostTime + inputAgeHostTime
        var outputTime = AudioTimeStamp()
        outputTime.mHostTime = callbackHostTime + outputLeadHostTime
        outputTime.mFlags = .hostTimeValid

        let timing = try #require(
            SystemTapAudioEngine.callbackTimingNanoseconds(
                inputTime: inputTime,
                callbackHostTime: callbackHostTime,
                outputTime: outputTime
            ))
        #expect(timing.inputAge == AudioConvertHostTimeToNanos(inputAgeHostTime))
        #expect(timing.outputLead == AudioConvertHostTimeToNanos(outputLeadHostTime))

        var invalidInputTime = inputTime
        invalidInputTime.mFlags = []
        #expect(
            SystemTapAudioEngine.callbackTimingNanoseconds(
                inputTime: invalidInputTime,
                callbackHostTime: callbackHostTime,
                outputTime: outputTime
            ) == nil)
        #expect(
            SystemTapAudioEngine.callbackTimingNanoseconds(
                inputTime: inputTime,
                callbackHostTime: inputTime.mHostTime - 1,
                outputTime: outputTime
            ) == nil)
        #expect(
            SystemTapAudioEngine.callbackTimingNanoseconds(
                inputTime: inputTime,
                callbackHostTime: outputTime.mHostTime + 1,
                outputTime: outputTime
            ) == nil)
    }

    @Test
    func outputDeviceUIDLookupResolvesDefaultOutput() throws {
        let defaultOutput = try CoreAudioDeviceQuery.defaultOutputDevice()
        let resolvedOutput = try #require(try CoreAudioDeviceQuery.outputDevice(uid: defaultOutput.uid))

        #expect(resolvedOutput.uid == defaultOutput.uid)
        #expect(resolvedOutput.outputChannelCount > 0)
        #expect(try CoreAudioDeviceQuery.outputDevice(uid: "") == nil)
    }

    @Test
    func sampleRateRestorationUsesFreshUIDDeviceAndVerifiesWrite() {
        var currentSampleRate = 44_100.0
        var setCalls: [(sampleRate: Double, objectID: AudioObjectID)] = []
        let deviceUID = "restored-output"

        let restored = PersistedAudioDeviceRestorationStore.restoreSampleRate(
            uid: deviceUID, to: 48_000,
            outputForUID: { uid in
                #expect(uid == deviceUID)
                return output(
                    id: 9_001,
                    uid: uid,
                    channelCount: 2,
                    sampleRate: currentSampleRate
                )
            },
            setSampleRate: { sampleRate, objectID in
                setCalls.append((sampleRate, objectID))
                currentSampleRate = sampleRate
            }
        )

        #expect(restored)
        #expect(setCalls.count == 1)
        #expect(setCalls.first?.sampleRate == 48_000)
        #expect(setCalls.first?.objectID == 9_001)
    }

    @Test
    func sampleRateRestorationIsRetainedWhenDeviceIsAbsentOrWriteCannotBeVerified() {
        var setCallCount = 0
        let deviceUID = "missing-output"

        let absentRestored = PersistedAudioDeviceRestorationStore.restoreSampleRate(
            uid: deviceUID, to: 48_000,
            outputForUID: { _ in nil },
            setSampleRate: { _, _ in setCallCount += 1 }
        )

        #expect(!absentRestored)
        #expect(setCallCount == 0)

        let unverifiedRestored = PersistedAudioDeviceRestorationStore.restoreSampleRate(
            uid: deviceUID, to: 48_000,
            outputForUID: { uid in
                output(id: 9_002, uid: uid, channelCount: 2, sampleRate: 44_100)
            },
            setSampleRate: { _, _ in setCallCount += 1 }
        )

        #expect(!unverifiedRestored)
        #expect(setCallCount == 1)
    }

    @Test
    func bufferFrameSizeRestorationUsesFreshUIDDeviceAndVerifiesWrite() {
        var currentFrameSize: UInt32 = 512
        var setCalls: [(frameSize: UInt32, objectID: AudioObjectID)] = []
        let deviceUID = "buffer-output"

        let restored = PersistedAudioDeviceRestorationStore.restoreBufferFrameSize(
            uid: deviceUID, to: 256,
            outputForUID: { uid in
                #expect(uid == deviceUID)
                return output(
                    id: 9_003,
                    uid: uid,
                    channelCount: 2,
                    bufferFrameSize: currentFrameSize
                )
            },
            setBufferFrameSize: { frameSize, objectID in
                setCalls.append((frameSize, objectID))
                currentFrameSize = frameSize
            }
        )

        #expect(restored)
        #expect(setCalls.count == 1)
        #expect(setCalls.first?.frameSize == 256)
        #expect(setCalls.first?.objectID == 9_003)
    }

    @Test
    func bufferFrameSizeRestorationSkipsAlreadyRestoredDevice() {
        var didSet = false
        let deviceUID = "already-restored-buffer-output"

        let restored = PersistedAudioDeviceRestorationStore.restoreBufferFrameSize(
            uid: deviceUID, to: 256,
            outputForUID: { uid in
                output(id: 9_004, uid: uid, channelCount: 2, bufferFrameSize: 256)
            },
            setBufferFrameSize: { _, _ in didSet = true }
        )

        #expect(restored)
        #expect(!didSet)
    }

    @Test
    func persistedDeviceRestorationRestoresAndClearsVerifiedSettings() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlassEQDeviceRestoration-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: url)
        }
        try Data(#"[{"uid":"dac","originalSampleRate":48000,"originalBufferFrameSize":256}]"#.utf8).write(to: url)
        var sampleRate = 44_100.0
        var frameSize: UInt32 = 512

        PersistedAudioDeviceRestorationStore.restorePersistedDeviceSettings(
            at: url,
            outputForUID: { uid in
                output(uid: uid, channelCount: 2, sampleRate: sampleRate, bufferFrameSize: frameSize)
            },
            setSampleRate: { nextSampleRate, _ in
                sampleRate = nextSampleRate
            },
            setBufferFrameSize: { nextFrameSize, _ in
                frameSize = nextFrameSize
            }
        )

        #expect(PersistedAudioDeviceRestorationStore.load(from: url).isEmpty)
        #expect(sampleRate == 48_000)
        #expect(frameSize == 256)
    }

    @Test
    func persistedDeviceRestorationKeepsUnavailableDeviceRecords() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlassEQDeviceRestoration-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: url)
        }
        try Data(#"[{"uid":"missing","originalSampleRate":48000}]"#.utf8).write(to: url)

        PersistedAudioDeviceRestorationStore.restorePersistedDeviceSettings(
            at: url,
            outputForUID: { _ in nil },
            setSampleRate: { _, _ in Issue.record("Unexpected sample-rate write") },
            setBufferFrameSize: { _, _ in Issue.record("Unexpected buffer-size write") }
        )

        #expect(PersistedAudioDeviceRestorationStore.load(from: url)["missing"]?.originalSampleRate == 48_000)
    }

    @Test
    func persistedDeviceRestorationFoldsDuplicateUIDRecordsWithoutTrapping() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlassEQDeviceRestoration-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: url)
        }
        let records = [
            PersistedAudioDeviceRestorationRecord(uid: "dac", originalSampleRate: 48_000),
            PersistedAudioDeviceRestorationRecord(uid: "dac", originalSampleRate: 44_100),
            PersistedAudioDeviceRestorationRecord(uid: "dac", originalBufferFrameSize: 256),
            PersistedAudioDeviceRestorationRecord(uid: "dac", originalBufferFrameSize: 512),
            PersistedAudioDeviceRestorationRecord(uid: "headphones", originalBufferFrameSize: 1_024),
        ]
        try JSONEncoder().encode(records).write(to: url)

        let loaded = PersistedAudioDeviceRestorationStore.load(from: url)

        let dac = try #require(loaded["dac"])
        #expect(dac.originalSampleRate == 48_000)
        #expect(dac.originalBufferFrameSize == 256)
        #expect(loaded["headphones"]?.originalBufferFrameSize == 1_024)
    }

    @Test
    func persistedDeviceRestorationRejectsOversizedAndInvalidStores() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlassEQDeviceRestoration-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: url)
        }

        try Data(
            repeating: 0x20,
            count: PersistedAudioDeviceRestorationStore.maximumStoreBytes + 1
        ).write(to: url)
        #expect(PersistedAudioDeviceRestorationStore.load(from: url).isEmpty)

        let invalidRecords = [
            PersistedAudioDeviceRestorationRecord(
                uid: String(repeating: "x", count: 513),
                originalSampleRate: 48_000
            ),
            PersistedAudioDeviceRestorationRecord(
                uid: "invalid-rate",
                originalSampleRate: .infinity
            ),
            PersistedAudioDeviceRestorationRecord(
                uid: "invalid-buffer",
                originalBufferFrameSize: UInt32.max
            ),
        ]
        let encoder = JSONEncoder()
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "Infinity",
            negativeInfinity: "-Infinity",
            nan: "NaN"
        )
        try encoder.encode(invalidRecords).write(to: url)

        #expect(PersistedAudioDeviceRestorationStore.load(from: url).isEmpty)
    }

    @Test
    func monoRuntimeOutputDownmixesStereoInsteadOfUsingLeftOnly() {
        let samples: [Float] = [
            1, 3,
            -2, 4,
            10, -4,
        ]

        samples.withUnsafeBufferPointer { pointer in
            #expect(SystemTapAudioEngine.monoDownmix(pointer, frame: 0, sourceChannelCount: 2) == 2)
            #expect(SystemTapAudioEngine.monoDownmix(pointer, frame: 1, sourceChannelCount: 2) == 1)
            #expect(SystemTapAudioEngine.monoDownmix(pointer, frame: 2, sourceChannelCount: 2) == 3)
            #expect(SystemTapAudioEngine.monoDownmix(pointer, frame: -1, sourceChannelCount: 2) == 0)
            #expect(SystemTapAudioEngine.monoDownmix(pointer, frame: 99, sourceChannelCount: 2) == 0)
        }
    }

    @Test
    func monoSourceDuplicatesIntoSingleInterleavedStereoOutputBuffer() {
        let samples: [Float] = [1, 2]
        var destination: [Float] = [-1, -1, -1, -1, -1, -1]

        samples.withUnsafeBufferPointer { source in
            destination.withUnsafeMutableBufferPointer { destinationBuffer in
                let audioBuffer = AudioBuffer(
                    mNumberChannels: 2,
                    mDataByteSize: UInt32(destinationBuffer.count * MemoryLayout<Float>.stride),
                    mData: destinationBuffer.baseAddress
                )
                var audioBufferList = AudioBufferList(mNumberBuffers: 1, mBuffers: audioBuffer)
                withUnsafeMutablePointer(to: &audioBufferList) { audioBufferListPointer in
                    SystemTapAudioEngine.copyInterleavedSamples(
                        source,
                        sourceFrameOffset: 0,
                        destinationFrameOffset: 1,
                        frameCount: 2,
                        sourceChannelCount: 1,
                        to: UnsafeMutableAudioBufferListPointer(audioBufferListPointer)
                    )
                }
            }
        }

        #expect(destination == [-1, -1, 1, 1, 2, 2])
    }

    @Test
    func renderDeadlineMissesRequireAtLeastTwoCallbackPeriods() {
        #expect(
            SystemTapAudioEngine.missedRenderDeadlines(
                elapsedNanoseconds: 650_000,
                frameCount: 16,
                sampleRate: 48_000
            ) == 0)
        #expect(
            SystemTapAudioEngine.missedRenderDeadlines(
                elapsedNanoseconds: 700_000,
                frameCount: 16,
                sampleRate: 48_000
            ) == 1)
        #expect(
            SystemTapAudioEngine.missedRenderDeadlines(
                elapsedNanoseconds: 4_500_000,
                frameCount: 16,
                sampleRate: 48_000
            ) == 12)
    }

    @Test
    func renderOverrunBeginsAfterOneCallbackPeriod() {
        #expect(
            !SystemTapAudioEngine.renderOverranPeriod(
                elapsedNanoseconds: 333_333,
                frameCount: 16,
                sampleRate: 48_000
            ))
        #expect(
            SystemTapAudioEngine.renderOverranPeriod(
                elapsedNanoseconds: 333_334,
                frameCount: 16,
                sampleRate: 48_000
            ))
    }

    @Test
    func extremeDurationTrackerPublishesPercentilesAndResetsWithoutClearingOnControlThread() {
        let tracker = RealtimeExtremeDurationTracker()
        for microseconds in 1...1_024 {
            tracker.record(UInt64(microseconds) * 1_000)
        }

        let measured = tracker.snapshot()
        #expect(measured.observations == 1_024)
        #expect(measured.p50Nanoseconds == 516_000)
        #expect(measured.p99Nanoseconds == 1_016_000)
        #expect(measured.p999Nanoseconds == 1_024_000)
        #expect(measured.p9999Nanoseconds == 1_024_000)
        #expect(measured.maximumNanoseconds == 1_024_000)

        tracker.reset()
        #expect(tracker.snapshot().observations == 0)

        tracker.record(250)
        let afterReset = tracker.snapshot()
        #expect(afterReset.observations == 1)
        #expect(afterReset.p50Nanoseconds == 250)
        #expect(afterReset.p99Nanoseconds == 250)
        #expect(afterReset.p999Nanoseconds == 250)
        #expect(afterReset.p9999Nanoseconds == 250)
        #expect(afterReset.maximumNanoseconds == 250)
    }

    @Test
    func callbackSizeTrackerUsesBoundedBucketsAndResets() {
        let tracker = RealtimeCallbackSizeTracker()
        tracker.record(16)
        tracker.record(16)
        tracker.record(512)
        tracker.record(17)

        #expect(
            tracker.snapshot() == [
                AudioCallbackSizeObservation(frameCount: 16, observations: 2),
                AudioCallbackSizeObservation(frameCount: 512, observations: 1),
                AudioCallbackSizeObservation(frameCount: nil, observations: 1),
            ])

        tracker.reset()

        #expect(tracker.snapshot().isEmpty)
    }

    @Test
    func aggregateTimestampSlopeQualificationRequiresStableNominalTiming() {
        #expect(
            SystemTapAudioEngine.timestampSlopeAgrees(
                frameCount: 16,
                sampleRate: 48_000,
                sampleTimeDeltaFrames: 0,
                hostIntervalErrorNanoseconds: 40_000,
                rateScalar: 1.000005752,
                rateScalarIsValid: true
            ))
        #expect(
            !SystemTapAudioEngine.timestampSlopeAgrees(
                frameCount: 16,
                sampleRate: 48_000,
                sampleTimeDeltaFrames: 1,
                hostIntervalErrorNanoseconds: 40_000,
                rateScalar: 1,
                rateScalarIsValid: true
            ))
        #expect(
            !SystemTapAudioEngine.timestampSlopeAgrees(
                frameCount: 16,
                sampleRate: 48_000,
                sampleTimeDeltaFrames: 0,
                hostIntervalErrorNanoseconds: 100_000,
                rateScalar: 1,
                rateScalarIsValid: true
            ))
        #expect(
            !SystemTapAudioEngine.timestampSlopeAgrees(
                frameCount: 16,
                sampleRate: 48_000,
                sampleTimeDeltaFrames: 0,
                hostIntervalErrorNanoseconds: 0,
                rateScalar: 1.02,
                rateScalarIsValid: true
            ))
    }

    @Test
    func headsetProbationCoversThreeQuartersOfASecondAtTheAppliedBufferSize() {
        func callbacks(at rate: Double, frames: UInt32) -> UInt64 {
            SystemTapAudioEngine.probationCallbackCount(
                for: output(
                    channelCount: 1, sampleRate: rate, bufferFrameSize: frames,
                    transportType: kAudioDeviceTransportTypeBluetooth
                ))
        }
        #expect(callbacks(at: 24_000, frames: 480) == 38)
        #expect(callbacks(at: 16_000, frames: 64) == 188)
        #expect(callbacks(at: 48_000, frames: 64) == 8)
    }

    @Test
    func headsetQualificationRequiresDeviceClockToMatchTheNominalRate() {
        #expect(
            SystemTapAudioEngine.deviceClockSlopeAgrees(
                sampleTimeDeltaFrames: 2_400,
                hostTimeDeltaNanoseconds: 100_000_000,
                nominalSampleRate: 24_000,
                rateScalar: 1,
                rateScalarIsValid: true
            ))
        #expect(
            !SystemTapAudioEngine.deviceClockSlopeAgrees(
                sampleTimeDeltaFrames: 4_800,
                hostTimeDeltaNanoseconds: 100_000_000,
                nominalSampleRate: 24_000,
                rateScalar: 1,
                rateScalarIsValid: true
            ))
        #expect(
            !SystemTapAudioEngine.deviceClockSlopeAgrees(
                sampleTimeDeltaFrames: 2_400,
                hostTimeDeltaNanoseconds: 100_000_000,
                nominalSampleRate: 24_000,
                rateScalar: 1.03,
                rateScalarIsValid: true
            ))
    }

    @Test
    func profileUpdateRejectsTheTemporaryGapInAnOutputRebuild() throws {
        #expect(throws: AudioEngineProfileUpdateUnavailable.self) {
            _ = try SystemTapAudioEngine.profileUpdateOutput(nil)
        }

        let activeOutput = output(uid: "profile-update-output", channelCount: 2)
        #expect(try SystemTapAudioEngine.profileUpdateOutput(activeOutput) == activeOutput)
    }

    @Test
    func selfChangeGuardSuppressesOnlyMatchingDevice() {
        let changeGuard = CoreAudioSelfChangeGuard(windowMilliseconds: 1_000)

        changeGuard.beginSelfChange(deviceID: 42)

        #expect(changeGuard.isSelfChange(deviceID: 42))
        #expect(!changeGuard.isSelfChange(deviceID: 43))
    }

    @Test
    func selfChangeGuardExpires() async throws {
        let changeGuard = CoreAudioSelfChangeGuard(windowMilliseconds: 1)

        changeGuard.beginSelfChange(deviceID: 42)
        try await Task.sleep(nanoseconds: 5_000_000)

        #expect(!changeGuard.isSelfChange(deviceID: 42))
    }

    @Test
    func outputObserverNeverSuppressesDeviceAliveNotifications() {
        let changeGuard = CoreAudioSelfChangeGuard(windowMilliseconds: 1_000)
        changeGuard.beginSelfChange(deviceID: 42)

        #expect(
            DefaultOutputDeviceObserver.shouldSuppressSelfInducedOutputChange(
                selector: kAudioDevicePropertyBufferFrameSize,
                deviceID: 42,
                selfChangeGuard: changeGuard
            ))
        #expect(
            !DefaultOutputDeviceObserver.shouldSuppressSelfInducedOutputChange(
                selector: kAudioDevicePropertyDeviceIsAlive,
                deviceID: 42,
                selfChangeGuard: changeGuard
            ))
    }

    @Test
    func outputObserverRefreshesRateAndStreamChangesImmediately() {
        #expect(
            DefaultOutputDeviceObserver.shouldRefreshImmediately(
                selector: kAudioDevicePropertyNominalSampleRate
            ))
        #expect(
            DefaultOutputDeviceObserver.shouldRefreshImmediately(
                selector: kAudioDevicePropertyStreamConfiguration
            ))
        #expect(
            DefaultOutputDeviceObserver.shouldRefreshImmediately(
                selector: kAudioDevicePropertyDeviceIsAlive
            ))
        #expect(
            !DefaultOutputDeviceObserver.shouldRefreshImmediately(
                selector: kAudioDevicePropertyBufferFrameSize
            ))
    }

    @Test
    func outputObserverReportsEachObservedConfigurationOnce() {
        var tracker = DefaultOutputChangeTracker()
        let initialOutput = output(channelCount: 2, sampleRate: 96_000)
        var changedOutput = initialOutput
        changedOutput.nominalSampleRate = 44_100

        let skippedInitialValue = tracker.shouldSendChange(
            for: initialOutput,
            sendChange: false,
            reason: .initial
        )
        let sentChangedValue = tracker.shouldSendChange(
            for: changedOutput,
            sendChange: true,
            reason: .settled
        )
        let sentStreamEvent = tracker.shouldSendChange(
            for: changedOutput,
            sendChange: true,
            reason: .streamConfiguration
        )
        let skippedCoalescedDuplicate = tracker.shouldSendChange(
            for: changedOutput,
            sendChange: true,
            reason: .settled
        )

        #expect(!skippedInitialValue)
        #expect(sentChangedValue)
        #expect(sentStreamEvent)
        #expect(!skippedCoalescedDuplicate)

        tracker.reset()
        let sentAfterReset = tracker.shouldSendChange(
            for: changedOutput,
            sendChange: true,
            reason: .settled
        )
        #expect(sentAfterReset)
    }

    @Test
    func refreshCoalescerRunsOnlyLatestScheduledAction() {
        let queue = DispatchQueue(label: "com.glasseq.tests.refresh-coalescer")
        let coalescer = DispatchRefreshCoalescer(queue: queue, delay: .milliseconds(10))
        let counter = LockedCounter()
        let completed = DispatchSemaphore(value: 0)

        queue.sync {
            coalescer.schedule {
                counter.increment()
            }
            coalescer.schedule {
                counter.increment()
            }
            coalescer.schedule {
                counter.increment()
                completed.signal()
            }
        }

        #expect(completed.wait(timeout: .now() + 1) == .success)
        queue.sync {}

        #expect(counter.value == 1)
    }

    @Test
    func refreshCoalescerCancelSuppressesPendingAction() {
        let queue = DispatchQueue(label: "com.glasseq.tests.refresh-coalescer-cancel")
        let coalescer = DispatchRefreshCoalescer(queue: queue, delay: .milliseconds(10))
        let counter = LockedCounter()

        queue.sync {
            coalescer.schedule {
                counter.increment()
            }
            coalescer.cancelPending()
        }

        Thread.sleep(forTimeInterval: 0.05)
        queue.sync {}

        #expect(counter.value == 0)
    }

    @Test
    func dspHotSwapAllowsSameTopologyParameterAndBypassChanges() {
        let active = EQProfile(
            name: "Active",
            mode: .graphic10,
            preampDB: -3,
            filters: EQProfile.flatGraphic10.filters
        )
        var next = active
        next.preampDB = -4
        next.filters[0].gainDB = 3
        next.filters[1].frequency = 70
        next.isBypassed = true

        #expect(
            SystemTapAudioEngine.canHotSwapDSP(
                from: active,
                to: next,
                sampleRate: 48_000,
                channelCount: 2
            ))
    }

    @Test
    func dspHotSwapAllowsWholeBankTopologyChanges() {
        let graphic = EQProfile(
            name: "Graphic",
            mode: .graphic10,
            filters: EQProfile.flatGraphic10.filters
        )

        var disabledBand = graphic
        disabledBand.filters[0].isEnabled = false
        #expect(
            SystemTapAudioEngine.canHotSwapDSP(
                from: graphic,
                to: disabledBand,
                sampleRate: 48_000,
                channelCount: 2
            ))

        let parametric = EQProfile(
            name: "Parametric",
            mode: .parametric,
            filters: [EQFilter(kind: .peak, frequency: 1_000, gainDB: 0, q: 1)]
        )
        var addedFilter = parametric
        addedFilter.filters.append(EQFilter(kind: .peak, frequency: 2_000, gainDB: 0, q: 1))
        #expect(
            SystemTapAudioEngine.canHotSwapDSP(
                from: parametric,
                to: addedFilter,
                sampleRate: 48_000,
                channelCount: 2
            ))

        let modeSwitch = EQProfile(
            name: "Parametric Same Count",
            mode: .parametric,
            filters: graphic.filters
        )
        #expect(
            SystemTapAudioEngine.canHotSwapDSP(
                from: graphic,
                to: modeSwitch,
                sampleRate: 48_000,
                channelCount: 2
            ))

        var stereoSwitch = graphic
        stereoSwitch.channelMode = .stereo
        #expect(
            SystemTapAudioEngine.canHotSwapDSP(
                from: graphic,
                to: stereoSwitch,
                sampleRate: 48_000,
                channelCount: 2
            ))
    }

    @Test
    func dspHotSwapRejectsNumericallyUnsafeBank() {
        let active = EQProfile.flatParametric
        var unsafe = active
        unsafe.preampDB = .nan

        #expect(
            !SystemTapAudioEngine.canHotSwapDSP(
                from: active,
                to: unsafe,
                sampleRate: 48_000,
                channelCount: 2
            ))
    }

    @Test
    func metadataValidationRejectsInvalidRangesAndSizes() throws {
        expectInvalidMetadata {
            _ = try CoreAudioDeviceQuery.validatedBufferFrameSizeRange(
                AudioValueRange(mMinimum: 512, mMaximum: 256),
                objectID: 42
            )
        }
        expectInvalidMetadata {
            try CoreAudioDeviceQuery.validateStreamConfigurationSize(4, objectID: 42)
        }
        expectInvalidMetadata {
            try CoreAudioDeviceQuery.validateAudioBufferListStorage(
                bufferCount: 1,
                byteCount: 8,
                objectID: 42
            )
        }
        expectInvalidMetadata {
            try CoreAudioDeviceQuery.validateStreamConfigurationSize(
                CoreAudioDeviceQuery.maxStreamConfigurationBytes + 1,
                objectID: 42
            )
        }
        expectInvalidMetadata {
            _ = try CoreAudioDeviceQuery.checkedSampleCount(
                frames: Int(CoreAudioDeviceQuery.maxBufferFrameSize) + 1,
                channels: CoreAudioDeviceQuery.maxChannelCount,
                objectID: 42
            )
        }

        let range = try CoreAudioDeviceQuery.validatedBufferFrameSizeRange(
            AudioValueRange(mMinimum: 127.2, mMaximum: 256.8),
            objectID: 42
        )
        #expect(range == AudioBufferFrameSizeRange(minimum: 128, maximum: 256))
    }

    @Test
    func zeroBufferStreamConfigurationIsValidForOutputOnlyDevice() throws {
        try CoreAudioDeviceQuery.validateStreamConfigurationSize(8, objectID: 42)
        try CoreAudioDeviceQuery.validateAudioBufferListStorage(
            bufferCount: 0,
            byteCount: 8,
            objectID: 42
        )
    }

    private func expectInvalidMetadata(_ operation: () throws -> Void) {
        do {
            try operation()
            Issue.record("Expected invalid Core Audio metadata to be rejected")
        } catch let error as AudioDeviceAvailabilityError {
            guard case .invalidDeviceMetadata = error else {
                Issue.record("Expected invalid metadata error, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected invalid metadata error, got \(error)")
        }
    }

    private func aggregateTapEntry(
        uid: String,
        drift: Bool = true
    ) -> NSDictionary {
        [
            kAudioSubTapUIDKey: uid,
            kAudioSubTapDriftCompensationKey: NSNumber(value: drift),
            kAudioSubTapDriftCompensationQualityKey:
                NSNumber(value: kAudioAggregateDriftCompensationHighQuality),
        ] as NSDictionary
    }

    private func output(
        id: AudioObjectID = 42,
        uid: String = "test-output",
        channelCount: Int,
        sampleRate: Double = 48_000,
        bufferFrameSize: UInt32 = 256,
        transportType: UInt32? = nil
    ) -> AudioOutputDevice {
        AudioOutputDevice(
            id: id,
            uid: uid,
            name: "Test Output",
            nominalSampleRate: sampleRate,
            outputChannelCount: channelCount,
            bufferFrameSize: bufferFrameSize,
            transportType: transportType
        )
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer {
            lock.unlock()
        }
        return count
    }
}
