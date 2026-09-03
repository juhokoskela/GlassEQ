import AudioToolbox
import CoreAudio
import Foundation
import GlassEQCore
import Synchronization
protocol TopologyRebuildMuteGuarding: AnyObject {
    @discardableResult
    func release() -> Bool
}

struct TopologyRebuildMuteGuardUnavailable: Error, LocalizedError {
    var underlyingError: any Error

    var errorDescription: String? {
        "GlassEQ could not guarantee silence for a profile rebuild, so the current audio engine was left running."
    }
}

private struct SeparateClockAudioEngineInternalError: Error, LocalizedError {
    var message: String

    var errorDescription: String? {
        message
    }
}

public final class SeparateClockAudioBackend: @unchecked Sendable {
    private enum OutputDeviceSettingsPolicy {
        case adaptiveLowLatency
        case preserveCurrent

        var preservesCurrentSettings: Bool {
            self == .preserveCurrent
        }
    }

    private static let preferredBufferFrameSize: UInt32 = 64
    private static let preferredBluetoothBufferFrameSize: UInt32 = 64
    private static let preferredBluetoothPlaybackTargetFrames = 128
    // Leaves one preferred 64-frame capture callback after servicing a 64-frame output pull.
    private static let preferredBluetoothPlaybackReservoirFrames = 64
    private static let preferredLowSampleRateBufferFrameSize: UInt32 = 1024
    // Low-rate routes keep at least one normal runtime callback in reserve. The configured
    // capture callback expands this at startup when the aggregate ignores the 64-frame request.
    private static let preferredLowSampleRatePlaybackReservoirFrames = Int(maximumRuntimeBufferFrameSize)
    private static let preferredCaptureBufferFrameSize: UInt32 = 64
    private static let minimumRingBufferFrames = 2048
    private static let maximumRuntimeBufferFrameSize: UInt32 = 1024
    private static let maximumSupportedCallbackFrames = 8192
    // Capacity planning allows a 4:1 input/output rate ratio (above the current 48→16 kHz case)
    // and retains one additional full converted pull as drift headroom.
    private static let maximumPlannedPlaybackRateRatio = 4
    private static let playbackRingPullCount = 2
    private static let preferredPlaybackPrimeFrames = 128
    private static let lowSampleRateThreshold = 24_000.0
    private static let maximumPlannedPlaybackPrimeFrames =
        maximumSupportedCallbackFrames * maximumPlannedPlaybackRateRatio
            + maximumSupportedCallbackFrames
    static let runtimeRingCapacityFrames = max(
        minimumRingBufferFrames,
        maximumPlannedPlaybackPrimeFrames * playbackRingPullCount
    )

    private struct PlaybackBufferFrameSizeDecayCandidate: Hashable {
        var outputUID: String
        var sampleRate: Int
        var tapSampleRate: Int
        var frameSize: UInt32

        init(output: AudioOutputDevice, tapSampleRate: Double, frameSize: UInt32) {
            self.outputUID = output.uid
            self.sampleRate = Int(output.nominalSampleRate.rounded())
            self.tapSampleRate = Int(tapSampleRate.rounded())
            self.frameSize = frameSize
        }
    }

    private struct ControlState {
        var state: AudioEngineState = .stopped
        var status: AudioEngineStatus = .stopped
        // Persistent capture half (one global muted tap, kept alive across output switches).
        var tapID = AudioObjectID(kAudioObjectUnknown)
        var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        var captureIOProcID: AudioDeviceIOProcID?
        var runtime: AudioRuntime?
        var tapSampleRate: Double = 0
        var tapChannelCount: Int = 0
        var captureRunning = false
        // Swappable output half (rebuilt per output device; low-rate headset modes are converted).
        var outputIOProcID: AudioDeviceIOProcID?
        var preparedOutputHandoff: PreparedOutputHandoff?
        var activeOutput: AudioOutputDevice?
        var activeProfile: EQProfile?
        var activeOutputSettingsPolicy = OutputDeviceSettingsPolicy.adaptiveLowLatency
        var profileRevision: UInt64 = 0
        var bufferFrameSizeRestorations: [String: BufferFrameSizeRestoration] = [:]
        var sampleRateRestorations: [String: SampleRateRestoration] = [:]
        var outputRebuildGeneration = 0
        var playbackBufferAdaptationEvidence = PlaybackBufferAdaptationEvidence()
        var playbackBufferCalibrationProbe: PlaybackBufferCalibrationProbe?
        var playbackBufferStableSince: ContinuousClock.Instant?
        var playbackBufferInstabilityPersistenceGate = PlaybackBufferInstabilityPersistenceGate()
        var failedPlaybackFrameSizeDecayCandidates: Set<PlaybackBufferFrameSizeDecayCandidate> = []
        var adaptivePlaybackRenderRecoveryAttempts = 0
        var adaptivePlaybackRenderRecoveryHealthGeneration: UInt64?
    }

    private struct OutputRebuildPreparation {
        var generation: Int
        var output: AudioOutputDevice
        var profile: EQProfile
        var runtime: AudioRuntime
        var tapSampleRate: Double
        var originalBufferFrameSize: UInt32
        var profileRevision: UInt64
        var outputSettingsPolicy: OutputDeviceSettingsPolicy
    }

    private struct PreparedOutputHandoff {
        var preparation: OutputRebuildPreparation
        var output: AudioOutputDevice
        var profile: EQProfile
        var ioProcID: AudioDeviceIOProcID
    }

    private struct PlaybackBufferRenegotiationPreparation {
        var outputRebuildGeneration: Int
        var reason: PlaybackBufferInstabilityReason
        var output: AudioOutputDevice
        var runtime: AudioRuntime
    }

    private struct PlaybackBufferDecayPreparation {
        var outputRebuildGeneration: Int
        var output: AudioOutputDevice
        var runtime: AudioRuntime
    }

    private struct OutputRebuildExpectation {
        var generation: Int
        var runtime: AudioRuntime
        var profileRevision: UInt64
    }

    private struct PlaybackBufferTargetAdjustment {
        var output: AudioOutputDevice
        var tapSampleRate: Double
        var previousTargetFrames: Int
        var targetFrames: Int
    }

    private enum PlaybackBufferTargetDecayResult {
        case adjusted
        case atBaseline
        case blocked
    }

    private enum PlaybackBufferAdaptationAction {
        case stabilize(PlaybackBufferCalibrationProbe)
        case renegotiate(PlaybackBufferRenegotiationPreparation)
        case decay(PlaybackBufferDecayPreparation)
    }

    private enum AdaptivePlaybackRenderRecoveryAction {
        case restart(output: AudioOutputDevice, profile: EQProfile, expectation: OutputRebuildExpectation)
        case fail(AudioEngineFailure)
    }

    private struct StaleOutputRebuild: Error {}
    private struct StaleProfileRequest: Error {}

    struct BufferFrameSizeRestoration: Equatable, Sendable {
        var uid: String
        var originalFrameSize: UInt32
    }

    struct SampleRateRestoration: Equatable, Sendable {
        var uid: String
        var originalSampleRate: Double
    }

    private final class CoreAudioTopologyRebuildMuteGuard: TopologyRebuildMuteGuarding, @unchecked Sendable {
        private let lock = NSLock()
        private let cleanupLedger: CoreAudioResourceCleanupLedger
        private var tapID: AudioObjectID
        private var aggregateDeviceID: AudioObjectID
        private var ioProcID: AudioDeviceIOProcID?

        init(
            tapID: AudioObjectID,
            aggregateDeviceID: AudioObjectID,
            ioProcID: AudioDeviceIOProcID?,
            cleanupLedger: CoreAudioResourceCleanupLedger
        ) {
            self.tapID = tapID
            self.aggregateDeviceID = aggregateDeviceID
            self.ioProcID = ioProcID
            self.cleanupLedger = cleanupLedger
        }

        deinit {
            _ = release()
        }

        @discardableResult
        func release() -> Bool {
            lock.lock()
            let tapID = self.tapID
            let aggregateDeviceID = self.aggregateDeviceID
            let ioProcID = self.ioProcID
            self.ioProcID = nil
            self.aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
            self.tapID = AudioObjectID(kAudioObjectUnknown)
            lock.unlock()

            var resources = CoreAudioResourceCleanupLedger.PendingResources(
                operation: "dispose topology rebuild mute guard"
            )
            if aggregateDeviceID != kAudioObjectUnknown, let ioProcID {
                resources.ioProcs.append(.init(
                    deviceID: aggregateDeviceID,
                    ioProcID: ioProcID
                ))
            }
            if aggregateDeviceID != kAudioObjectUnknown {
                resources.aggregateDeviceIDs.append(aggregateDeviceID)
            }
            if tapID != kAudioObjectUnknown {
                resources.tapIDs.append(tapID)
            }
            guard !resources.ioProcs.isEmpty
                    || !resources.aggregateDeviceIDs.isEmpty
                    || !resources.tapIDs.isEmpty else {
                return true
            }
            guard !cleanupLedger.dispose(resources) else {
                return true
            }
            for attempt in 0..<3 {
                if cleanupLedger.retryPending() {
                    return true
                }
                if attempt < 2 {
                    Thread.sleep(forTimeInterval: 0.01)
                }
            }
            return false
        }
    }

    private final class PreparedDSPConfigBox: @unchecked Sendable {
        let transitionID: UInt64
        var processor: EQProcessor?
        var comparisonReferenceProcessor: EQProcessor?
        var retiredProcessor: EQProcessor?
        var secondRetiredProcessor: EQProcessor?
        var playbackCompletionFrameOffset: Int?
        var nextRetiredPointer: UInt = 0

        init(config: EQRenderConfiguration, transitionID: UInt64) {
            self.transitionID = transitionID
            self.processor = EQProcessor(renderConfiguration: config)
        }

        init(
            equalizedConfig: EQRenderConfiguration,
            referenceConfig: EQRenderConfiguration,
            transitionID: UInt64
        ) {
            self.transitionID = transitionID
            self.processor = EQProcessor(renderConfiguration: equalizedConfig)
            self.comparisonReferenceProcessor = EQProcessor(
                renderConfiguration: referenceConfig
            )
        }
    }

    private enum AdaptivePlaybackRenderResult {
        case rendered
        case underrun(frames: Int)
        case failed
    }

    final class AudioRuntime: @unchecked Sendable {
        // The cubic playback resampler reads at most four source frames beyond the output
        // position it just rendered. AudioConverter latency is added when conversion is active.
        private static let playbackTransitionReadAheadFrames = 4

        let ringBuffer: RealtimeAudioRingBuffer
        let channelCount: Int
        let sampleRate: Double
        private let configuredCaptureCallbackFrames: Int
        private let playbackPrimeFrames: Atomic<Int>
        private let maxCallbackFrames: Int
        private var dspTransition: RealtimeEQTransition
        private var captureScratchSamples: [Float]
        private var adaptiveInputSamples: [Float]
        private var sampleRateConverterInputSamples: UnsafeMutableBufferPointer<Float>
        private let adaptiveOutputSamples: UnsafeMutableBufferPointer<Float>
        private var playbackRateServo: PlaybackRateServo
        private var playbackResampler: HermitePlaybackResampler
        private var playbackSampleRatePlan: PlaybackSampleRatePlan
        private var playbackSampleRateConverter: RealtimePCMRateConverter?
        private var sampleRateConverterInputRatio = 1.0
        private var sampleRateConverterInputResult = AdaptivePlaybackRenderResult.rendered
        private var outputTimestampTracker = OutputCallbackTimestampTracker()

        private let capturedFrames = Atomic<UInt64>(0)
        private let playedFrames = Atomic<UInt64>(0)
        #if DEBUG
        private let freezePlayedFramesForTesting = Atomic<Bool>(false)
        #endif
        private let playbackUnderrunEvents = Atomic<UInt64>(0)
        private let playbackUnderrunFrames = Atomic<UInt64>(0)
        private let droppedInputFrames = Atomic<UInt64>(0)
        private let droppedBufferedFrames = Atomic<UInt64>(0)
        private let saturatedSamples = Atomic<UInt64>(0)
        private let maxBufferedFrames = Atomic<Int>(0)
        private let maxPlaybackBufferedFrames = Atomic<Int>(0)
        private let minPlaybackBufferedFrames = Atomic<Int>(Int.max)
        private let totalPlaybackBufferedFrames = Atomic<UInt64>(0)
        private let playbackBufferObservations = Atomic<UInt64>(0)
        private let maxCaptureCallbackFrames = Atomic<Int>(0)
        private let maxPlaybackCallbackFrames = Atomic<Int>(0)
        private let captureCallbackSizes = RealtimeCallbackSizeTracker()
        private let playbackCallbackSizes = RealtimeCallbackSizeTracker()
        private let playbackTimestampDiscontinuities = Atomic<UInt64>(0)
        private let playbackBufferRenegotiations = Atomic<UInt64>(0)
        private let adaptivePlaybackRenderFailures = Atomic<UInt64>(0)
        private let adaptivePlaybackRenderFailureActive = Atomic<Bool>(false)
        private let adaptivePlaybackRenderHealthGeneration = Atomic<UInt64>(0)
        private let playbackInstabilityGeneration = Atomic<UInt64>(0)
        private let latestPlaybackInstabilityReason = Atomic<UInt8>(PlaybackBufferInstabilityReason.underrun.rawValue)
        private let adaptivePlaybackTargetFrames: Atomic<Int>
        private let pendingPlaybackClockReset = Atomic<Bool>(true)
        private let pendingPlaybackTargetRetarget = Atomic<Bool>(false)
        private let playbackRateCorrectionPartsPerBillion = Atomic<Int64>(0)
        private let playbackRateCorrectionSaturated = Atomic<Bool>(false)
        private let filteredPlaybackOccupancyMilliFrames = Atomic<Int64>(0)
        private let sampleRateConversionActive = Atomic<Bool>(false)
        private let playbackPriming = Atomic<Bool>(true)
        private let outputMutedForTransition = Atomic<Bool>(false)
        private let pendingPlaybackReset = Atomic<Bool>(false)
        private let pendingOutputTimestampReset = Atomic<Bool>(true)
        private let pendingDSPConfigPointer = Atomic<UInt>(0)
        private let retiredDSPConfigHeadPointer = Atomic<UInt>(0)
        private var activeDSPConfigPointer: UInt = 0
        private let pendingPlaybackDSPTransitionID = Atomic<UInt64>(0)
        private let pendingPlaybackDSPCompletionSequence = Atomic<UInt64>(0)
        private let playbackTransitionLatencyFrames = Atomic<Int>(
            AudioRuntime.playbackTransitionReadAheadFrames
        )
        private var nextDSPTransitionID: UInt64 = 0
        private let publishedDSPTransition = Atomic<UInt64>(0)
        private let completedDSPTransitions = Atomic<UInt64>(0)
        private let programmeComparisonSelection = Atomic<UInt>(
            UInt(EQProgrammeComparisonSelection.equalized.rawValue)
        )
        private let programmeComparisonActive = Atomic<Bool>(false)
        private let programmeComparisonReady = Atomic<Bool>(false)
        private let equalizedAttenuationMilliDB = Atomic<Int64>(0)
        private let filtersOffAttenuationMilliDB = Atomic<Int64>(0)
        private let stopping = Atomic<Bool>(false)
        private let captureInCallback = Atomic<Bool>(false)
        private let playbackInCallback = Atomic<Bool>(false)
        // Packed (left << 32 | right) so the playback callback can never observe a torn pair.
        private let playbackChannelPair = Atomic<UInt64>(SeparateClockAudioBackend.encodedPlaybackChannelPair(left: 0, right: 1))

        init(
            renderConfiguration: EQRenderConfiguration,
            ringCapacityFrames: Int,
            scratchFrames: Int,
            captureCallbackFrames: Int,
            playbackPrimeFrames: Int
        ) {
            self.channelCount = max(renderConfiguration.configuration.channelCount, 1)
            self.sampleRate = renderConfiguration.configuration.sampleRate
            self.configuredCaptureCallbackFrames = max(captureCallbackFrames, 1)
            self.ringBuffer = RealtimeAudioRingBuffer(
                channelCount: self.channelCount,
                capacityFrames: ringCapacityFrames
            )
            self.captureScratchSamples = Array(repeating: 0, count: scratchFrames * self.channelCount)
            self.adaptiveInputSamples = Array(repeating: 0, count: (scratchFrames + 8) * self.channelCount)
            self.sampleRateConverterInputSamples = UnsafeMutableBufferPointer<Float>.allocate(
                capacity: self.channelCount
            )
            self.sampleRateConverterInputSamples.initialize(repeating: 0)
            self.adaptiveOutputSamples = UnsafeMutableBufferPointer<Float>.allocate(
                capacity: SeparateClockAudioBackend.maximumSupportedCallbackFrames * self.channelCount
            )
            self.adaptiveOutputSamples.initialize(repeating: 0)
            self.playbackPrimeFrames = Atomic(max(playbackPrimeFrames, 1))
            self.adaptivePlaybackTargetFrames = Atomic(max(playbackPrimeFrames, 1))
            self.maxCallbackFrames = SeparateClockAudioBackend.maximumSupportedCallbackFrames
            self.playbackRateServo = PlaybackRateServo(
                sampleRate: self.sampleRate,
                targetFrames: playbackPrimeFrames
            )
            self.playbackResampler = HermitePlaybackResampler(channelCount: self.channelCount)
            self.playbackSampleRatePlan = PlaybackSampleRatePlan(
                inputSampleRate: self.sampleRate,
                outputSampleRate: self.sampleRate
            )
            self.dspTransition = RealtimeEQTransition(
                activeProcessor: EQProcessor(
                    renderConfiguration: renderConfiguration
                ),
                maximumFrameCount: scratchFrames,
                channelCount: self.channelCount,
                sampleRate: self.sampleRate
            )
        }

        deinit {
            drainDSPConfigBoxes()
            releaseDSPConfigBox(activeDSPConfigPointer)
            sampleRateConverterInputSamples.deinitialize()
            sampleRateConverterInputSamples.deallocate()
            adaptiveOutputSamples.deinitialize()
            adaptiveOutputSamples.deallocate()
        }

        func markStopping() {
            stopping.store(true, ordering: .releasing)
            outputMutedForTransition.store(true, ordering: .releasing)
            playbackPriming.store(true, ordering: .releasing)
        }

        func muteOutputForTransition() {
            outputMutedForTransition.store(true, ordering: .releasing)
            playbackPriming.store(true, ordering: .releasing)
            pendingOutputTimestampReset.store(true, ordering: .releasing)
        }

        func resumeOutputAfterCancelledTransition() {
            reprimePlayback()
        }

        // Stored by the control thread on every output rebuild, before the new output IOProc
        // starts, so the first callback on the new device already maps to the right channels.
        func setPlaybackChannelPair(left: Int, right: Int) {
            playbackChannelPair.store(
                SeparateClockAudioBackend.encodedPlaybackChannelPair(left: left, right: right),
                ordering: .releasing
            )
        }

        func configurePlayback(
            primeFrames: Int,
            outputSampleRate: Double
        ) throws {
            let targetFrames = min(max(primeFrames, 1), ringBuffer.capacityFrames)
            let sampleRatePlan = PlaybackSampleRatePlan(
                inputSampleRate: sampleRate,
                outputSampleRate: outputSampleRate
            )
            let sampleRateConverter: RealtimePCMRateConverter? = if sampleRatePlan.requiresConversion {
                try RealtimePCMRateConverter(
                    inputSampleRate: sampleRatePlan.inputSampleRate,
                    outputSampleRate: sampleRatePlan.outputSampleRate,
                    channelCount: channelCount
                )
            } else {
                nil
            }
            let inputCapacityFrames = try sampleRateConverter?.inputFrameCapacity(
                forOutputFrames: maxCallbackFrames
            ) ?? 1
            let inputSamples = UnsafeMutableBufferPointer<Float>.allocate(
                capacity: inputCapacityFrames * channelCount
            )
            inputSamples.initialize(repeating: 0)

            sampleRateConverterInputSamples.deinitialize()
            sampleRateConverterInputSamples.deallocate()
            sampleRateConverterInputSamples = inputSamples
            playbackSampleRateConverter = sampleRateConverter
            playbackSampleRatePlan = sampleRatePlan
            playbackTransitionLatencyFrames.store(
                Self.playbackTransitionReadAheadFrames
                    + (sampleRateConverter?.latencyFrames ?? 0),
                ordering: .releasing
            )
            sampleRateConversionActive.store(sampleRateConverter != nil, ordering: .releasing)
            adaptivePlaybackRenderFailureActive.store(false, ordering: .releasing)
            playbackPrimeFrames.store(targetFrames, ordering: .releasing)
            adaptivePlaybackTargetFrames.store(targetFrames, ordering: .releasing)
            pendingPlaybackTargetRetarget.store(false, ordering: .releasing)
            pendingPlaybackClockReset.store(true, ordering: .releasing)
            pendingOutputTimestampReset.store(true, ordering: .releasing)
        }

        func retargetPlayback(primeFrames: Int) {
            let targetFrames = min(max(primeFrames, 1), ringBuffer.capacityFrames)
            playbackPrimeFrames.store(targetFrames, ordering: .releasing)
            adaptivePlaybackTargetFrames.store(targetFrames, ordering: .releasing)
            pendingPlaybackTargetRetarget.store(true, ordering: .releasing)
            pendingOutputTimestampReset.store(true, ordering: .releasing)
        }

        func playbackTargetFrames() -> Int {
            adaptivePlaybackTargetFrames.load(ordering: .acquiring)
        }

        func maximumKnownCaptureCallbackFrames() -> Int {
            max(
                configuredCaptureCallbackFrames,
                maxCaptureCallbackFrames.load(ordering: .relaxed)
            )
        }

        func hasActiveAdaptivePlaybackRenderFailure() -> Bool {
            adaptivePlaybackRenderFailureActive.load(ordering: .acquiring)
        }

        func playbackRenderHealthGeneration() -> UInt64 {
            adaptivePlaybackRenderHealthGeneration.load(ordering: .acquiring)
        }

        func playbackTimestampDiscontinuityCount() -> UInt64 {
            playbackTimestampDiscontinuities.load(ordering: .acquiring)
        }

        // Called when a new output half is started. Clears any transition mute (the runtime
        // persists across output switches now, so the mute flag would otherwise stick on and
        // silence everything) and re-primes so playback re-anchors to the freshest audio.
        func reprimePlayback() {
            pendingPlaybackReset.store(true, ordering: .releasing)
            playbackPriming.store(true, ordering: .releasing)
            pendingOutputTimestampReset.store(true, ordering: .releasing)
            outputMutedForTransition.store(false, ordering: .releasing)
        }

        func playbackInstabilitySnapshot() -> (generation: UInt64, reason: PlaybackBufferInstabilityReason) {
            let generation = playbackInstabilityGeneration.load(ordering: .acquiring)
            let latestReason = PlaybackBufferInstabilityReason(
                rawValue: latestPlaybackInstabilityReason.load(ordering: .relaxed)
            ) ?? .underrun
            let reason = AdaptivePlaybackRenderRecoveryPolicy.effectiveInstabilityReason(
                latest: latestReason,
                renderFailureActive: adaptivePlaybackRenderFailureActive.load(ordering: .acquiring)
            )
            return (generation, reason)
        }

        func recordPlaybackBufferRenegotiation() {
            playbackBufferRenegotiations.wrappingAdd(1, ordering: .relaxed)
        }

        func resetMetrics() {
            capturedFrames.store(0, ordering: .relaxed)
            playedFrames.store(0, ordering: .relaxed)
            playbackUnderrunEvents.store(0, ordering: .relaxed)
            playbackUnderrunFrames.store(0, ordering: .relaxed)
            droppedInputFrames.store(0, ordering: .relaxed)
            droppedBufferedFrames.store(0, ordering: .relaxed)
            saturatedSamples.store(0, ordering: .relaxed)
            maxBufferedFrames.store(0, ordering: .relaxed)
            maxPlaybackBufferedFrames.store(0, ordering: .relaxed)
            minPlaybackBufferedFrames.store(Int.max, ordering: .relaxed)
            totalPlaybackBufferedFrames.store(0, ordering: .relaxed)
            playbackBufferObservations.store(0, ordering: .relaxed)
            maxCaptureCallbackFrames.store(0, ordering: .relaxed)
            maxPlaybackCallbackFrames.store(0, ordering: .relaxed)
            captureCallbackSizes.reset()
            playbackCallbackSizes.reset()
            playbackTimestampDiscontinuities.store(0, ordering: .relaxed)
            playbackBufferRenegotiations.store(0, ordering: .relaxed)
            adaptivePlaybackRenderFailures.store(0, ordering: .relaxed)
            playbackRateCorrectionSaturated.store(false, ordering: .relaxed)
            ringBuffer.resetOverwriteGateContentionFailureCount()
            playbackPriming.store(true, ordering: .releasing)
        }

        func snapshotMetrics() -> AudioEngineMetrics {
            let observations = playbackBufferObservations.load(ordering: .relaxed)
            let minimumBufferedFrames = minPlaybackBufferedFrames.load(ordering: .relaxed)
            return AudioEngineMetrics(
                capturedFrames: capturedFrames.load(ordering: .relaxed),
                playedFrames: playedFrames.load(ordering: .relaxed),
                playbackUnderrunEvents: playbackUnderrunEvents.load(ordering: .relaxed),
                playbackUnderrunFrames: playbackUnderrunFrames.load(ordering: .relaxed),
                droppedInputFrames: droppedInputFrames.load(ordering: .relaxed),
                droppedBufferedFrames: droppedBufferedFrames.load(ordering: .relaxed),
                ringGateContentionFailures: ringBuffer.overwriteGateContentionFailureCount(),
                saturatedSamples: saturatedSamples.load(ordering: .relaxed),
                currentBufferedFrames: ringBuffer.occupancyFrames(),
                maxBufferedFrames: maxBufferedFrames.load(ordering: .relaxed),
                maximumPlaybackBufferedFrames: maxPlaybackBufferedFrames.load(ordering: .relaxed),
                minimumPlaybackBufferedFrames: observations == 0 ? 0 : minimumBufferedFrames,
                averagePlaybackBufferedFrames: observations == 0
                    ? 0
                    : Double(totalPlaybackBufferedFrames.load(ordering: .relaxed)) / Double(observations),
                playbackBufferObservations: observations,
                maximumCaptureCallbackFrames: maxCaptureCallbackFrames.load(ordering: .relaxed),
                maximumPlaybackCallbackFrames: maxPlaybackCallbackFrames.load(ordering: .relaxed),
                captureCallbackSizeObservations: captureCallbackSizes.snapshot(),
                playbackCallbackSizeObservations: playbackCallbackSizes.snapshot(),
                playbackTimestampDiscontinuities: playbackTimestampDiscontinuities.load(ordering: .relaxed),
                playbackBufferRenegotiations: playbackBufferRenegotiations.load(ordering: .relaxed),
                adaptivePlaybackRenderFailures: adaptivePlaybackRenderFailures.load(ordering: .relaxed),
                playbackRateCorrectionPPM: Double(
                    playbackRateCorrectionPartsPerBillion.load(ordering: .relaxed)
                ) / 1_000,
                playbackRateCorrectionSaturated: playbackRateCorrectionSaturated.load(ordering: .relaxed),
                playbackOccupancyTargetFrames: adaptivePlaybackTargetFrames.load(ordering: .relaxed),
                filteredPlaybackOccupancyFrames: Double(
                    filteredPlaybackOccupancyMilliFrames.load(ordering: .relaxed)
                ) / 1_000,
                playbackBufferSampleRate: sampleRate,
                playbackSampleRateConversionActive: sampleRateConversionActive.load(ordering: .acquiring)
            )
        }

        @discardableResult
        func publishPendingDSPConfig(_ config: EQRenderConfiguration) -> DSPTransitionProgress.Target {
            let target = nextDSPTransitionTarget()
            let box = PreparedDSPConfigBox(config: config, transitionID: target.id)
            publishPendingDSPConfigBox(box)
            return target
        }

        @discardableResult
        func publishPendingProgrammeComparison(
            equalizedConfig: EQRenderConfiguration,
            referenceConfig: EQRenderConfiguration
        ) -> DSPTransitionProgress.Target {
            let target = nextDSPTransitionTarget()
            let box = PreparedDSPConfigBox(
                equalizedConfig: equalizedConfig,
                referenceConfig: referenceConfig,
                transitionID: target.id
            )
            publishPendingDSPConfigBox(box)
            return target
        }

        func setProgrammeComparisonSelection(
            _ selection: EQProgrammeComparisonSelection
        ) {
            programmeComparisonSelection.store(
                UInt(selection.rawValue),
                ordering: .releasing
            )
        }

        func dspTransitionProgress() -> DSPTransitionProgress {
            DSPTransitionProgress(
                published: publishedDSPTransition.load(ordering: .acquiring),
                completed: completedDSPTransitions.load(ordering: .acquiring)
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
            let oldPointer = pendingDSPConfigPointer.exchange(rawPointer, ordering: .acquiringAndReleasing)
            publishedDSPTransition.store(box.transitionID, ordering: .releasing)
            releaseDSPConfigBox(oldPointer)
        }

        private func nextDSPTransitionTarget() -> DSPTransitionProgress.Target {
            nextDSPTransitionID &+= 1
            return DSPTransitionProgress.Target(id: nextDSPTransitionID)
        }

        func drainDSPConfigBoxes() {
            releaseDSPConfigBox(pendingDSPConfigPointer.exchange(0, ordering: .acquiringAndReleasing))
            var rawPointer = retiredDSPConfigHeadPointer.exchange(0, ordering: .acquiringAndReleasing)
            while rawPointer != 0 {
                guard let pointer = UnsafeRawPointer(bitPattern: rawPointer) else {
                    return
                }
                let box = Unmanaged<PreparedDSPConfigBox>.fromOpaque(pointer).takeUnretainedValue()
                let nextPointer = box.nextRetiredPointer
                box.nextRetiredPointer = 0
                releaseDSPConfigBox(rawPointer)
                rawPointer = nextPointer
            }
        }

        func capture(inputData: UnsafePointer<AudioBufferList>) {
            guard !stopping.load(ordering: .acquiring),
                  enter(captureInCallback) else {
                return
            }
            defer {
                captureInCallback.store(false, ordering: .releasing)
            }

            let inputBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
            guard let frameCount = inputFrameCount(inputBuffers),
                  frameCount > 0 else {
                return
            }
            updateMax(maxCaptureCallbackFrames, frameCount)
            captureCallbackSizes.record(frameCount)

            if outputMutedForTransition.load(ordering: .acquiring) {
                return
            }

            beginPendingDSPTransitionIfPossible()
            if programmeComparisonActive.load(ordering: .relaxed) {
                dspTransition.setProgrammeComparisonSelection(
                    selectedProgrammeComparisonBranch()
                )
            }

            var saturatedSampleCount: UInt64 = 0
            captureScratchSamples.withUnsafeMutableBufferPointer { scratch in
                let scratchFrames = max(scratch.count / channelCount, 1)
                var frameOffset = 0
                while frameOffset < frameCount {
                    let chunkFrames = min(frameCount - frameOffset, scratchFrames)
                    let chunkSamples = UnsafeMutableBufferPointer(
                        start: scratch.baseAddress,
                        count: chunkFrames * channelCount
                    )
                    copyInput(
                        from: inputBuffers,
                        sourceFrameOffset: frameOffset,
                        into: chunkSamples,
                        frameCount: chunkFrames,
                        channelCount: channelCount
                    )
                    let transitionResult = dspTransition.processInterleavedWithDiagnostics(
                        chunkSamples,
                        frameCount: chunkFrames,
                        channelCount: channelCount
                    )
                    if transitionResult.programmeComparison.isActive
                        || programmeComparisonActive.load(ordering: .relaxed) {
                        publishProgrammeComparisonSnapshot(
                            transitionResult.programmeComparison
                        )
                    }
                    saturatedSampleCount += transitionResult.saturatedSamples
                    prepareCompletedDSPTransition(
                        transitionResult,
                        renderedFrameCount: chunkFrames
                    )
                    let firstWrittenSequence = ringBuffer.nextWriteSequence()
                    let writeResult = ringBuffer.writeInterleaved(
                        UnsafeBufferPointer(chunkSamples),
                        frameCount: chunkFrames,
                        sourceChannelCount: channelCount
                    )
                    recordWriteResult(writeResult)
                    armCompletedDSPTransitionForPlayback(
                        writeResult: writeResult,
                        firstWrittenSequence: firstWrittenSequence
                    )
                    frameOffset += chunkFrames
                }
            }

            if saturatedSampleCount > 0 {
                saturatedSamples.wrappingAdd(saturatedSampleCount, ordering: .relaxed)
            }
            updateMaxBufferedFrames(ringBuffer.occupancyFrames())
            capturedFrames.wrappingAdd(UInt64(frameCount), ordering: .relaxed)
        }

        func playback(
            outputData: UnsafeMutablePointer<AudioBufferList>,
            outputSampleTime: Double?
        ) {
            guard !stopping.load(ordering: .acquiring) else {
                clear(outputData: outputData)
                return
            }
            guard enter(playbackInCallback) else {
                clear(outputData: outputData)
                return
            }
            defer {
                playbackInCallback.store(false, ordering: .releasing)
            }

            let outputBuffers = UnsafeMutableAudioBufferListPointer(outputData)
            guard let frameCount = outputFrameCount(outputBuffers) else {
                clear(outputData: outputData)
                return
            }
            guard frameCount > 0 else {
                return
            }
            updateMax(maxPlaybackCallbackFrames, frameCount)
            playbackCallbackSizes.record(frameCount)

            if pendingOutputTimestampReset.exchange(false, ordering: .acquiringAndReleasing) {
                outputTimestampTracker.reset()
            }

            if pendingPlaybackReset.exchange(false, ordering: .acquiringAndReleasing) {
                _ = ringBuffer.reset()
            }
            if pendingPlaybackClockReset.exchange(false, ordering: .acquiringAndReleasing) {
                pendingPlaybackTargetRetarget.store(false, ordering: .releasing)
                playbackRateServo.reset(
                    targetFrames: adaptivePlaybackTargetFrames.load(ordering: .acquiring)
                )
                playbackResampler.reset()
                publishAdaptivePlaybackMetrics()
            } else if pendingPlaybackTargetRetarget.exchange(false, ordering: .acquiringAndReleasing) {
                playbackRateServo.retarget(
                    adaptivePlaybackTargetFrames.load(ordering: .acquiring)
                )
                playbackResampler.reset()
                publishAdaptivePlaybackMetrics()
            }

            if outputMutedForTransition.load(ordering: .acquiring) {
                clear(outputData: outputData)
                return
            }

            let inputDurationFrames = playbackSampleRatePlan.inputFrames(
                forOutputFrames: frameCount
            )

            // Timeline reanchors and backlog trimming need a fresh prime, but neither proves that
            // the operating point lacks capacity. Only corroborated underruns drive adaptation.
            if outputTimestampTracker.observe(sampleTime: outputSampleTime, frameCount: frameCount) {
                playbackTimestampDiscontinuities.wrappingAdd(1, ordering: .relaxed)
                beginPlaybackReprime()
            } else if !playbackPriming.load(ordering: .acquiring),
                      PlaybackOccupancyRecoveryPolicy.shouldReprime(
                          occupancyFrames: ringBuffer.occupancyFrames(),
                          targetFrames: adaptivePlaybackTargetFrames.load(ordering: .acquiring),
                          outputFrames: inputDurationFrames
                      ) {
                beginPlaybackReprime()
            }

            if playbackPriming.load(ordering: .acquiring) {
                playbackRateServo.beginPriming()
                playbackResampler.reset()
                publishAdaptivePlaybackMetrics()
                let bufferedFrames = ringBuffer.occupancyFrames()
                let primeFrames = playbackPrimeFrames.load(ordering: .acquiring)
                updateMaxBufferedFrames(bufferedFrames)
                guard bufferedFrames >= primeFrames else {
                    clear(outputData: outputData)
                    return
                }
                guard ringBuffer.trimToLatestFrames(primeFrames) else {
                    clear(outputData: outputData)
                    return
                }
                playbackRateServo.didPrime(occupancyFrames: primeFrames)
                publishAdaptivePlaybackMetrics()
                playbackPriming.store(false, ordering: .releasing)
            }

            let bufferedFrames = ringBuffer.occupancyFrames()
            recordPlaybackBufferedFrames(bufferedFrames)

            let (destinationLeftChannel, destinationRightChannel) = SeparateClockAudioBackend.decodedPlaybackChannelPair(
                playbackChannelPair.load(ordering: .acquiring)
            )

            let ratio = playbackRateServo.update(
                occupancyFrames: bufferedFrames,
                outputFrames: inputDurationFrames
            )
            publishAdaptivePlaybackMetrics()
            let result = if playbackSampleRateConverter != nil {
                renderSampleRateConvertedPlayback(
                    outputBuffers: outputBuffers,
                    frameCount: frameCount,
                    ratio: ratio,
                    destinationLeftChannel: destinationLeftChannel,
                    destinationRightChannel: destinationRightChannel
                )
            } else {
                renderAdaptivePlayback(
                    outputBuffers: outputBuffers,
                    frameCount: frameCount,
                    ratio: ratio,
                    destinationLeftChannel: destinationLeftChannel,
                    destinationRightChannel: destinationRightChannel
                )
            }
            var underrunFrames = 0
            var adaptiveRenderFailed = false
            switch result {
            case .rendered:
                adaptivePlaybackRenderFailureActive.store(false, ordering: .releasing)
                adaptivePlaybackRenderHealthGeneration.wrappingAdd(1, ordering: .releasing)
                completeDSPTransitionAfterPlayback()
            case .underrun(let frames):
                adaptivePlaybackRenderFailureActive.store(false, ordering: .releasing)
                adaptivePlaybackRenderHealthGeneration.wrappingAdd(1, ordering: .releasing)
                underrunFrames = frames
            case .failed:
                adaptiveRenderFailed = true
            }

            if underrunFrames > 0 {
                playbackUnderrunEvents.wrappingAdd(1, ordering: .relaxed)
                playbackUnderrunFrames.wrappingAdd(UInt64(underrunFrames), ordering: .relaxed)
                signalPlaybackInstability(.underrun)
            } else if adaptiveRenderFailed {
                adaptivePlaybackRenderFailures.wrappingAdd(1, ordering: .relaxed)
                if !adaptivePlaybackRenderFailureActive.exchange(true, ordering: .acquiringAndReleasing) {
                    signalPlaybackInstability(.adaptiveRenderFailure)
                }
            }
            if underrunFrames > 0 || adaptiveRenderFailed {
                beginPlaybackReprime()
            }
            updateMaxBufferedFrames(ringBuffer.occupancyFrames())
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

        private func beginPlaybackReprime() {
            playbackRateServo.beginPriming()
            playbackResampler.reset()
            publishAdaptivePlaybackMetrics()
            playbackPriming.store(true, ordering: .releasing)
        }

        private func signalPlaybackInstability(_ reason: PlaybackBufferInstabilityReason) {
            latestPlaybackInstabilityReason.store(reason.rawValue, ordering: .relaxed)
            playbackInstabilityGeneration.wrappingAdd(1, ordering: .releasing)
        }

        private func renderAdaptivePlayback(
            outputBuffers: UnsafeMutableAudioBufferListPointer,
            frameCount: Int,
            ratio: Double,
            destinationLeftChannel: Int,
            destinationRightChannel: Int
        ) -> AdaptivePlaybackRenderResult {
            guard frameCount <= adaptiveOutputSamples.count / channelCount else {
                clear(outputBuffers: outputBuffers)
                return .failed
            }
            let outputSamples = UnsafeMutableBufferPointer(
                start: adaptiveOutputSamples.baseAddress,
                count: frameCount * channelCount
            )
            let result = renderAdaptiveFrames(
                into: outputSamples,
                frameCount: frameCount,
                ratio: ratio
            )
            guard case .rendered = result else {
                clear(outputBuffers: outputBuffers)
                return result
            }
            writeInterleaved(
                UnsafeBufferPointer(outputSamples),
                sourceFrameOffset: 0,
                destinationFrameOffset: 0,
                frameCount: frameCount,
                sourceChannelCount: channelCount,
                destinationLeftChannel: destinationLeftChannel,
                destinationRightChannel: destinationRightChannel,
                to: outputBuffers
            )
            return .rendered
        }

        private func renderAdaptiveFrames(
            into outputSamples: UnsafeMutableBufferPointer<Float>,
            frameCount: Int,
            ratio: Double
        ) -> AdaptivePlaybackRenderResult {
            let inputFrameCapacity = adaptiveInputSamples.count / channelCount
            let outputFrameCapacity = outputSamples.count / channelCount
            let chunkFrameCapacity = max(inputFrameCapacity - 8, 1)
            guard inputFrameCapacity > 8, outputFrameCapacity >= frameCount else {
                return .failed
            }

            var outputFrameOffset = 0
            while outputFrameOffset < frameCount {
                let chunkFrames = min(frameCount - outputFrameOffset, chunkFrameCapacity)
                let plan = playbackResampler.inputPlan(outputFrames: chunkFrames, ratio: ratio)
                guard plan.combinedFrames <= inputFrameCapacity else {
                    playbackResampler.reset()
                    return .failed
                }

                var readFrames = 0
                var copiedRetainedSamples = false
                var rendered = false
                adaptiveInputSamples.withUnsafeMutableBufferPointer { inputSamples in
                    copiedRetainedSamples = playbackResampler.copyRetainedSamples(into: inputSamples, plan: plan)
                    guard copiedRetainedSamples, let inputBase = inputSamples.baseAddress else {
                        return
                    }
                    let newInputSamples = UnsafeMutableBufferPointer(
                        start: inputBase.advanced(by: plan.prefixFrames * channelCount),
                        count: plan.newFrames * channelCount
                    )
                    readFrames = ringBuffer.readInterleaved(
                        into: newInputSamples,
                        frameCount: plan.newFrames,
                        destinationChannelCount: channelCount
                    )
                    guard readFrames == plan.newFrames else {
                        return
                    }

                    let outputChunk = UnsafeMutableBufferPointer(
                        start: outputSamples.baseAddress?.advanced(
                            by: outputFrameOffset * channelCount
                        ),
                        count: chunkFrames * channelCount
                    )
                    rendered = playbackResampler.render(
                        input: inputSamples,
                        plan: plan,
                        output: outputChunk,
                        outputFrames: chunkFrames,
                        ratio: ratio
                    )
                }

                guard copiedRetainedSamples else {
                    playbackResampler.reset()
                    return .failed
                }
                guard readFrames == plan.newFrames else {
                    playbackResampler.reset()
                    return .underrun(frames: max(plan.newFrames - readFrames, 1))
                }
                guard rendered else {
                    playbackResampler.reset()
                    return .failed
                }
                outputFrameOffset += chunkFrames
            }

            return .rendered
        }

        private func renderSampleRateConvertedPlayback(
            outputBuffers: UnsafeMutableAudioBufferListPointer,
            frameCount: Int,
            ratio: Double,
            destinationLeftChannel: Int,
            destinationRightChannel: Int
        ) -> AdaptivePlaybackRenderResult {
            guard let sampleRateConverter = playbackSampleRateConverter,
                  frameCount <= adaptiveOutputSamples.count / channelCount,
                  let outputBase = adaptiveOutputSamples.baseAddress else {
                clear(outputBuffers: outputBuffers)
                return .failed
            }

            sampleRateConverterInputRatio = ratio
            sampleRateConverterInputResult = .rendered
            var convertedFrameCount = UInt32(frameCount)
            var convertedData = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: UInt32(channelCount),
                    mDataByteSize: UInt32(frameCount * channelCount * MemoryLayout<Float>.size),
                    mData: outputBase
                )
            )
            let status = withUnsafeMutablePointer(to: &convertedData) { outputData in
                sampleRateConverter.fill(
                    inputProc: Self.sampleRateConverterInputProc,
                    inputContext: Unmanaged.passUnretained(self).toOpaque(),
                    outputFrames: &convertedFrameCount,
                    outputData: outputData
                )
            }
            guard status == noErr else {
                clear(outputBuffers: outputBuffers)
                return switch sampleRateConverterInputResult {
                case .rendered:
                    .failed
                case .underrun(let frames):
                    .underrun(frames: frames)
                case .failed:
                    .failed
                }
            }
            guard convertedFrameCount == frameCount else {
                clear(outputBuffers: outputBuffers)
                return .failed
            }

            let outputSamples = UnsafeBufferPointer(
                start: outputBase,
                count: frameCount * channelCount
            )
            writeInterleaved(
                outputSamples,
                sourceFrameOffset: 0,
                destinationFrameOffset: 0,
                frameCount: frameCount,
                sourceChannelCount: channelCount,
                destinationLeftChannel: destinationLeftChannel,
                destinationRightChannel: destinationRightChannel,
                to: outputBuffers
            )
            return .rendered
        }

        private static let sampleRateConverterInputProc: AudioConverterComplexInputDataProcRealtimeSafe = {
            _, requestedFrames, inputData, packetDescriptions, context in
            guard let context else {
                requestedFrames.pointee = 0
                return kAudioConverterErr_UnspecifiedError
            }
            packetDescriptions?.pointee = nil
            return Unmanaged<AudioRuntime>
                .fromOpaque(context)
                .takeUnretainedValue()
                .provideSampleRateConverterInput(
                    requestedFrames: requestedFrames,
                    inputData: inputData
                )
        }

        private func provideSampleRateConverterInput(
            requestedFrames: UnsafeMutablePointer<UInt32>,
            inputData: UnsafeMutablePointer<AudioBufferList>
        ) -> OSStatus {
            let frameCount = Int(requestedFrames.pointee)
            guard frameCount > 0,
                  frameCount <= sampleRateConverterInputSamples.count / channelCount,
                  let inputBase = sampleRateConverterInputSamples.baseAddress else {
                requestedFrames.pointee = 0
                sampleRateConverterInputResult = .failed
                return kAudioConverterErr_InvalidInputSize
            }

            let inputSamples = UnsafeMutableBufferPointer(
                start: inputBase,
                count: frameCount * channelCount
            )
            let result = renderAdaptiveFrames(
                into: inputSamples,
                frameCount: frameCount,
                ratio: sampleRateConverterInputRatio
            )
            sampleRateConverterInputResult = result
            guard case .rendered = result else {
                requestedFrames.pointee = 0
                return kAudioConverterErr_UnspecifiedError
            }

            inputData.pointee = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: UInt32(channelCount),
                    mDataByteSize: UInt32(frameCount * channelCount * MemoryLayout<Float>.size),
                    mData: inputBase
                )
            )
            return noErr
        }

        private func publishAdaptivePlaybackMetrics() {
            playbackRateCorrectionPartsPerBillion.store(
                Int64((playbackRateServo.correctionPartsPerMillion * 1_000).rounded()),
                ordering: .relaxed
            )
            playbackRateCorrectionSaturated.store(
                playbackRateServo.correctionIsSaturated,
                ordering: .relaxed
            )
            filteredPlaybackOccupancyMilliFrames.store(
                Int64((playbackRateServo.filteredOccupancyFrames * 1_000).rounded()),
                ordering: .relaxed
            )
        }

        func clear(outputData: UnsafeMutablePointer<AudioBufferList>) {
            clear(outputBuffers: UnsafeMutableAudioBufferListPointer(outputData))
        }

        private func clear(outputBuffers: UnsafeMutableAudioBufferListPointer) {
            for buffer in outputBuffers {
                guard let data = buffer.mData,
                      let byteCount = validatedClearByteCount(for: buffer) else {
                    continue
                }
                data.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
            }
        }

        private func recordWriteResult(_ result: RingBufferWriteResult) {
            if result.droppedInputFrames > 0 {
                droppedInputFrames.wrappingAdd(UInt64(result.droppedInputFrames), ordering: .relaxed)
            }
            if result.droppedBufferedFrames > 0 {
                droppedBufferedFrames.wrappingAdd(UInt64(result.droppedBufferedFrames), ordering: .relaxed)
            }
        }

        private func beginPendingDSPTransitionIfPossible() {
            guard activeDSPConfigPointer == 0,
                  pendingPlaybackDSPTransitionID.load(ordering: .acquiring) == 0,
                  !dspTransition.isTransitioning else {
                return
            }
            let rawPointer = pendingDSPConfigPointer.exchange(0, ordering: .acquiringAndReleasing)
            guard rawPointer != 0 else {
                return
            }

            let pointer = UnsafeRawPointer(bitPattern: rawPointer)!
            let box = Unmanaged<PreparedDSPConfigBox>.fromOpaque(pointer).takeUnretainedValue()
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

        private func prepareCompletedDSPTransition(
            _ result: EQTransitionRenderResult,
            renderedFrameCount: Int
        ) {
            guard result.completedTransition,
                  activeDSPConfigPointer != 0,
                  let pointer = UnsafeRawPointer(bitPattern: activeDSPConfigPointer),
                  let blendStartFrame = result.blendStartFrame,
                  result.blendFrameCount > 0,
                  renderedFrameCount > 0 else {
                return
            }
            let box = Unmanaged<PreparedDSPConfigBox>.fromOpaque(pointer).takeUnretainedValue()
            box.retiredProcessor = result.retiredProcessor
            box.secondRetiredProcessor = result.secondRetiredProcessor
            box.playbackCompletionFrameOffset = min(
                max(result.blendFrameCount - blendStartFrame - 1, 0),
                renderedFrameCount - 1
            )
        }

        private func armCompletedDSPTransitionForPlayback(
            writeResult: RingBufferWriteResult,
            firstWrittenSequence: UInt64
        ) {
            guard activeDSPConfigPointer != 0,
                  let pointer = UnsafeRawPointer(bitPattern: activeDSPConfigPointer) else {
                return
            }
            let box = Unmanaged<PreparedDSPConfigBox>.fromOpaque(pointer).takeUnretainedValue()
            guard let completionFrameOffset = box.playbackCompletionFrameOffset else {
                return
            }
            guard writeResult.writtenFrames > 0 else {
                box.playbackCompletionFrameOffset = 0
                return
            }

            let retainedCompletionOffset = max(
                completionFrameOffset - writeResult.droppedInputFrames,
                0
            )
            guard retainedCompletionOffset < writeResult.writtenFrames else {
                box.playbackCompletionFrameOffset = 0
                return
            }
            box.playbackCompletionFrameOffset = nil
            pendingPlaybackDSPCompletionSequence.store(
                firstWrittenSequence &+ UInt64(retainedCompletionOffset) &+ 1,
                ordering: .releasing
            )

            let rawPointer = activeDSPConfigPointer
            activeDSPConfigPointer = 0
            pendingPlaybackDSPTransitionID.store(box.transitionID, ordering: .releasing)
            pushRetiredDSPConfigBox(rawPointer)
        }

        private func completeDSPTransitionAfterPlayback() {
            let transitionID = pendingPlaybackDSPTransitionID.load(ordering: .acquiring)
            guard transitionID != 0 else {
                return
            }
            let latencyFrames = UInt64(max(
                playbackTransitionLatencyFrames.load(ordering: .acquiring),
                0
            ))
            let requiredSequence = pendingPlaybackDSPCompletionSequence.load(ordering: .acquiring)
                &+ latencyFrames
            guard ringBuffer.nextReadSequence() >= requiredSequence else {
                return
            }
            guard pendingPlaybackDSPTransitionID.compareExchange(
                expected: transitionID,
                desired: 0,
                ordering: .acquiringAndReleasing
            ).exchanged else {
                return
            }
            completedDSPTransitions.store(transitionID, ordering: .releasing)
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

        private func pushRetiredDSPConfigBox(_ rawPointer: UInt) {
            guard rawPointer != 0,
                  let pointer = UnsafeRawPointer(bitPattern: rawPointer) else {
                return
            }
            let box = Unmanaged<PreparedDSPConfigBox>.fromOpaque(pointer).takeUnretainedValue()
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

        private func updateMaxBufferedFrames(_ occupancy: Int) {
            updateMax(maxBufferedFrames, occupancy)
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

        private func recordPlaybackBufferedFrames(_ frames: Int) {
            totalPlaybackBufferedFrames.wrappingAdd(UInt64(max(frames, 0)), ordering: .relaxed)
            playbackBufferObservations.wrappingAdd(1, ordering: .relaxed)
            updateMax(maxPlaybackBufferedFrames, frames)

            var current = minPlaybackBufferedFrames.load(ordering: .relaxed)
            while frames < current {
                let result = minPlaybackBufferedFrames.compareExchange(
                    expected: current,
                    desired: frames,
                    ordering: .relaxed
                )
                if result.exchanged {
                    return
                }
                current = result.original
            }
        }

        private func inputFrameCount(_ buffers: UnsafeMutableAudioBufferListPointer) -> Int? {
            guard let buffer = buffers.first else {
                return 0
            }
            guard validatedClearByteCount(for: buffer) != nil else {
                return nil
            }
            let channels = Int(buffer.mNumberChannels)
            let bytesPerFrame = MemoryLayout<Float>.stride * channels
            let frameCount = Int(buffer.mDataByteSize) / bytesPerFrame
            guard frameCount <= maxCallbackFrames else {
                return nil
            }
            return frameCount
        }

        private func outputFrameCount(_ buffers: UnsafeMutableAudioBufferListPointer) -> Int? {
            guard let buffer = buffers.first else {
                return 0
            }
            guard validatedClearByteCount(for: buffer) != nil else {
                return nil
            }
            let channels = Int(buffer.mNumberChannels)
            let bytesPerFrame = MemoryLayout<Float>.stride * channels
            let frameCount = Int(buffer.mDataByteSize) / bytesPerFrame
            guard frameCount <= maxCallbackFrames else {
                return nil
            }
            return frameCount
        }

        private func validatedClearByteCount(for buffer: AudioBuffer) -> Int? {
            guard buffer.mData != nil else {
                return nil
            }
            let channels = Int(buffer.mNumberChannels)
            guard channels > 0,
                  channels <= CoreAudioDeviceQuery.maxChannelCount else {
                return nil
            }
            let bytesPerFrame = MemoryLayout<Float>.stride * channels
            let byteCount = Int(buffer.mDataByteSize)
            guard byteCount >= 0,
                  byteCount % bytesPerFrame == 0 else {
                return nil
            }
            let frameCount = byteCount / bytesPerFrame
            guard frameCount <= maxCallbackFrames else {
                return nil
            }
            return byteCount
        }

        private func copyInput(
            from buffers: UnsafeMutableAudioBufferListPointer,
            sourceFrameOffset: Int,
            into samples: UnsafeMutableBufferPointer<Float>,
            frameCount: Int,
            channelCount: Int
        ) {
            if buffers.count == 1,
               let data = buffers[0].mData?.assumingMemoryBound(to: Float.self),
               Int(buffers[0].mNumberChannels) == channelCount,
               frameCount > 0,
               sourceFrameOffset >= 0 {
                let sourceSampleStart = sourceFrameOffset * channelCount
                let copySamples = frameCount * channelCount
                let availableSamples = Int(buffers[0].mDataByteSize) / MemoryLayout<Float>.stride
                if samples.count >= copySamples,
                   sourceSampleStart + copySamples <= availableSamples,
                   let destination = samples.baseAddress {
                    destination.update(from: data.advanced(by: sourceSampleStart), count: copySamples)
                    return
                }
            }

            for frameIndex in 0..<frameCount {
                let sourceFrame = sourceFrameOffset + frameIndex
                let sampleBase = frameIndex * channelCount
                for channel in 0..<channelCount {
                    samples[sampleBase + channel] = sample(from: buffers, frame: sourceFrame, channel: channel)
                }
            }
        }

        private func sample(
            from buffers: UnsafeMutableAudioBufferListPointer,
            frame: Int,
            channel: Int
        ) -> Float {
            if buffers.count == 1,
               let data = buffers[0].mData?.assumingMemoryBound(to: Float.self) {
                let channelCount = max(Int(buffers[0].mNumberChannels), 1)
                let index = frame * channelCount + min(channel, channelCount - 1)
                guard index >= 0,
                      index < Int(buffers[0].mDataByteSize) / MemoryLayout<Float>.stride else {
                    return 0
                }
                return data[index]
            }

            let bufferIndex = min(channel, buffers.count - 1)
            guard bufferIndex >= 0,
                  let data = buffers[bufferIndex].mData?.assumingMemoryBound(to: Float.self),
                  frame >= 0,
                  frame < Int(buffers[bufferIndex].mDataByteSize) / MemoryLayout<Float>.stride else {
                return 0
            }
            return data[frame]
        }

        private func writeInterleaved(
            _ samples: UnsafeBufferPointer<Float>,
            sourceFrameOffset: Int,
            destinationFrameOffset: Int,
            frameCount: Int,
            sourceChannelCount: Int,
            destinationLeftChannel: Int,
            destinationRightChannel: Int,
            to buffers: UnsafeMutableAudioBufferListPointer
        ) {
            SeparateClockAudioBackend.copyInterleavedSamples(
                samples,
                sourceFrameOffset: sourceFrameOffset,
                destinationFrameOffset: destinationFrameOffset,
                frameCount: frameCount,
                sourceChannelCount: sourceChannelCount,
                destinationLeftChannel: destinationLeftChannel,
                destinationRightChannel: destinationRightChannel,
                to: buffers
            )
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
    private let playbackBufferRenegotiationHandler = Mutex<(@Sendable (PlaybackBufferRenegotiation) -> Void)?>(nil)
    private let runtimeFailureHandler = Mutex<(@Sendable (AudioEngineFailure) -> Void)?>(nil)
    private let diagnosticTrace = Mutex<AudioEngineDiagnosticTrace?>(nil)
    private let cleanupLedger = CoreAudioResourceCleanupLedger()
    private let restorationStoreURL: URL
    private let playbackBufferCalibrationStoreURL: URL
    private let playbackBufferAdaptationQueue = DispatchQueue(
        label: "com.glasseq.playback-buffer-adaptation",
        qos: .userInitiated
    )
    private let playbackBufferAdaptationQueueKey = DispatchSpecificKey<Void>()
    private let playbackBufferAdaptationTimer: DispatchSourceTimer
    private let playbackBufferAdaptationTimerRunning = Mutex(false)

    public var state: AudioEngineState {
        control.withLock { $0.state }
    }

    public var status: AudioEngineStatus {
        control.withLock { $0.status }
    }

    func activeOutputAndProfile() -> (output: AudioOutputDevice, profile: EQProfile)? {
        control.withLock { state in
            guard case .running = state.state,
                  let output = state.activeOutput,
                  let profile = state.activeProfile else {
                return nil
            }
            return (output, profile)
        }
    }

    public init(restorationStoreURL: URL? = nil) {
        let restorationStoreURL = restorationStoreURL ?? PersistedAudioDeviceRestorationStore.defaultURL()
        self.restorationStoreURL = restorationStoreURL
        self.playbackBufferCalibrationStoreURL = PersistedPlaybackBufferCalibrationStore.defaultURL(
            nextTo: restorationStoreURL
        )
        let timer = DispatchSource.makeTimerSource(queue: playbackBufferAdaptationQueue)
        self.playbackBufferAdaptationTimer = timer
        playbackBufferAdaptationQueue.setSpecific(key: playbackBufferAdaptationQueueKey, value: ())
        Self.restorePersistedDeviceSettings(at: restorationStoreURL)
        timer.setEventHandler { [weak self] in
            self?.serviceAdaptivePlaybackBuffering()
        }
        timer.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250), leeway: .milliseconds(50))
    }

    func setDiagnosticTrace(_ trace: AudioEngineDiagnosticTrace?) {
        diagnosticTrace.withLock { $0 = trace }
    }

    private func traceDiagnostic(
        hostTimeNanoseconds: UInt64? = nil,
        _ message: () -> String
    ) {
        guard let trace = diagnosticTrace.withLock({ $0 }) else {
            return
        }
        trace(hostTimeNanoseconds, message())
    }

    deinit {
        stop()
        playbackBufferAdaptationTimer.setEventHandler {}
        playbackBufferAdaptationTimerRunning.withLock { isRunning in
            if !isRunning {
                playbackBufferAdaptationTimer.resume()
            }
            isRunning = false
        }
        playbackBufferAdaptationTimer.cancel()
    }

    public func start(output: AudioOutputDevice, profile: EQProfile) throws {
        try start(
            output: output,
            profile: profile,
            expectation: nil,
            outputSettingsPolicy: .adaptiveLowLatency
        )
    }

    func startForCombinedStartupStaging(
        output: AudioOutputDevice,
        profile: EQProfile
    ) throws {
        try start(
            output: output,
            profile: profile,
            expectation: nil,
            outputSettingsPolicy: .preserveCurrent
        )
    }

    func prepareOutputForHandoff(
        output: AudioOutputDevice,
        profile: EQProfile
    ) throws {
        try requireCompletedCoreAudioCleanup(operation: "prepare an output handoff")
        pausePlaybackBufferAdaptation()
        defer {
            updatePlaybackBufferAdaptationTimer()
        }

        do {
            var preparation = try control.withLock { state in
                guard state.outputIOProcID == nil,
                      state.preparedOutputHandoff == nil else {
                    throw SeparateClockAudioEngineInternalError(
                        message: "The compatibility output is already active."
                    )
                }
                state.status = .starting
                try ensureCaptureHalfLocked(&state, output: output, profile: profile)
                state.profileRevision &+= 1
                return try prepareOutputRebuildLocked(
                    &state,
                    output: output,
                    profile: profile,
                    profileRevision: state.profileRevision,
                    outputSettingsPolicy: .adaptiveLowLatency
                )
            }
            let refreshedOutput = try CoreAudioDeviceQuery.outputDevice(id: preparation.output.id)
            preparation.output = refreshedOutput
            preparation.originalBufferFrameSize = refreshedOutput.bufferFrameSize
            let matchedOutput = try preparePlaybackOutput(
                tapSampleRate: preparation.tapSampleRate,
                output: preparation.output,
                settingsPolicy: preparation.outputSettingsPolicy
            ) { restoration in
                try control.withLock { state in
                    guard state.outputRebuildGeneration == preparation.generation,
                          state.runtime === preparation.runtime,
                          state.captureRunning else {
                        throw StaleOutputRebuild()
                    }
                    try recordSampleRateRestorationIfNeeded(restoration, state: &state)
                }
            }
            try control.withLock { state in
                state.preparedOutputHandoff = try prepareOutputHandoffLocked(
                    &state,
                    preparation: preparation,
                    matchedOutput: matchedOutput
                )
            }
        } catch {
            control.withLock { state in
                stopLocked(&state)
            }
            throw error
        }
    }

    @discardableResult
    func activatePreparedOutputHandoff() throws -> AudioOutputDevice {
        pausePlaybackBufferAdaptation()
        defer {
            updatePlaybackBufferAdaptationTimer()
        }

        do {
            let result = try control.withLock {
                state -> (AudioOutputDevice, PlaybackBufferCalibrationProbe?) in
                guard let handoff = state.preparedOutputHandoff else {
                    throw SeparateClockAudioEngineInternalError(
                        message: "The compatibility output was not prepared."
                    )
                }
                state.preparedOutputHandoff = nil
                let output = try activatePreparedOutputHandoffLocked(
                    &state,
                    handoff: handoff
                )
                state.state = .running(output: output)
                state.status = .running(output: output)
                return (output, state.playbackBufferCalibrationProbe)
            }
            if let probe = result.1 {
                try? PersistedPlaybackBufferCalibrationStore.beginProbe(
                    outputUID: probe.outputUID,
                    sampleRate: probe.sampleRate,
                    tapSampleRate: probe.tapSampleRate,
                    frameSize: probe.frameSize,
                    targetFrames: probe.targetFrames,
                    at: playbackBufferCalibrationStoreURL
                )
            }
            return result.0
        } catch {
            control.withLock { state in
                stopLocked(&state)
                let failure = audioEngineFailure(from: error)
                state.state = .failed(failure.description)
                state.status = .failed(failure)
            }
            throw error
        }
    }

    func quiesceOutputForCombinedHandoff() throws {
        traceDiagnostic { "compatibility quiesce begin" }
        pausePlaybackBufferAdaptation()
        control.withLock { state in
            state.runtime?.muteOutputForTransition()
            stopOutputHalfLocked(&state)
            state.state = .stopped
            state.status = .starting
        }
        try requireCompletedCoreAudioCleanup(operation: "quiesce compatibility output")
        traceDiagnostic { "compatibility quiesce end" }
    }

    func completeCombinedHandoff() {
        control.withLock { state in
            stopLocked(&state)
        }
        retryCoreAudioCleanup()
        updatePlaybackBufferAdaptationTimer()
    }

    private func start(
        output: AudioOutputDevice,
        profile: EQProfile,
        expectation: OutputRebuildExpectation?,
        outputSettingsPolicy: OutputDeviceSettingsPolicy = .adaptiveLowLatency
    ) throws {
        try requireCompletedCoreAudioCleanup(operation: "start compatibility audio")
        pausePlaybackBufferAdaptation()
        defer {
            updatePlaybackBufferAdaptationTimer()
        }
        var previousState = AudioEngineState.stopped
        var previousStatus = AudioEngineStatus.stopped
        var activePreparation: OutputRebuildPreparation?

        do {
            var preparation = try control.withLock { state in
                if let expectation {
                    guard state.outputRebuildGeneration == expectation.generation,
                          state.runtime === expectation.runtime,
                          state.activeOutput?.uid == output.uid else {
                        throw StaleOutputRebuild()
                    }
                }
                guard let requestedProfile = Self.requestedOutputRebuildProfile(
                    requestedProfile: profile,
                    expectedProfileRevision: expectation?.profileRevision,
                    activeProfile: state.activeProfile,
                    activeProfileRevision: state.profileRevision
                ) else {
                    throw StaleProfileRequest()
                }
                previousState = state.state
                previousStatus = state.status
                state.status = .starting
                // Keep capture alive while its rate remains valid. Normal-rate changes refresh it
                // under the same mute guard used for topology changes so the bridge never retains
                // a tap runtime configured for the preceding device clock.
                try ensureCaptureHalfLocked(&state, output: output, profile: requestedProfile)
                state.profileRevision &+= 1
                return try prepareOutputRebuildLocked(
                    &state,
                    output: output,
                    profile: requestedProfile,
                    profileRevision: state.profileRevision,
                    outputSettingsPolicy: outputSettingsPolicy
                )
            }
            let refreshedOutput = try CoreAudioDeviceQuery.outputDevice(id: preparation.output.id)
            preparation.output = refreshedOutput
            preparation.originalBufferFrameSize = refreshedOutput.bufferFrameSize
            activePreparation = preparation
            let matchedOutput = try preparePlaybackOutput(
                tapSampleRate: preparation.tapSampleRate,
                output: preparation.output,
                settingsPolicy: preparation.outputSettingsPolicy
            ) { restoration in
                try control.withLock { state in
                    guard state.outputRebuildGeneration == preparation.generation,
                          state.runtime === preparation.runtime,
                          state.captureRunning else {
                        throw StaleOutputRebuild()
                    }
                    try recordSampleRateRestorationIfNeeded(restoration, state: &state)
                }
            }
            let calibrationProbe = try control.withLock { state -> PlaybackBufferCalibrationProbe? in
                try finishOutputRebuildLocked(&state, preparation: preparation, matchedOutput: matchedOutput)
                let active = state.activeOutput ?? output
                state.state = .running(output: active)
                state.status = .running(output: active)
                return state.playbackBufferCalibrationProbe
            }
            if let calibrationProbe {
                try? PersistedPlaybackBufferCalibrationStore.beginProbe(
                    outputUID: calibrationProbe.outputUID,
                    sampleRate: calibrationProbe.sampleRate,
                    tapSampleRate: calibrationProbe.tapSampleRate,
                    frameSize: calibrationProbe.frameSize,
                    targetFrames: calibrationProbe.targetFrames,
                    at: playbackBufferCalibrationStoreURL
                )
            }
        } catch is StaleOutputRebuild {
            return
        } catch is StaleProfileRequest {
            return
        } catch {
            var shouldRethrow = true
            control.withLock { state in
                if let activePreparation,
                   state.outputRebuildGeneration != activePreparation.generation {
                    shouldRethrow = false
                    return
                }
                if error is TopologyRebuildMuteGuardUnavailable {
                    state.state = previousState
                    state.status = previousStatus
                    return
                }
                let failure = audioEngineFailure(from: error)
                // Any failure tears the tap down too, so the system is never left muted
                // with nothing replaying.
                stopLocked(&state)
                state.state = .failed(failure.description)
                if failure.category == .systemAudioCapturePermission {
                    state.status = .permissionRequired(failure)
                } else {
                    state.status = .failed(failure)
                }
            }
            if shouldRethrow {
                throw error
            }
        }
    }

    public func update(profile: EQProfile) throws {
        // Prefer a lock-free hot-swap that leaves the persistent tap untouched.
        if updateDSP(profile: profile) != nil {
            return
        }
        // Topology-incompatible change: rebuild around the persistent tap (the tap rate is
        // constant, so start() keeps the capture half and only swaps the DSP graph + output).
        let output = try Self.profileUpdateOutput(control.withLock { $0.activeOutput })
        let freshOutput = try CoreAudioDeviceQuery.outputDevice(id: output.id)
        try start(output: freshOutput, profile: profile)
        let didApplyProfile = control.withLock { state in
            state.activeProfile == profile
        }
        guard didApplyProfile else {
            throw TopologyRebuildMuteGuardUnavailable(
                underlyingError: SeparateClockAudioEngineInternalError(message: "Profile rebuild was not applied.")
            )
        }
    }

    @discardableResult
    public func updateDSP(
        profile: EQProfile
    ) -> DSPTransitionProgress.Target? {
        guard let preparation = control.withLock({ state -> (AudioRuntime, EQProfile, UInt64, Double)? in
            guard let runtime = state.runtime,
                  let activeProfile = state.activeProfile else {
                return nil
            }
            let maximumUsableFrequency = EQRouteFrequencyPolicy.maximumUsableFrequency(
                sampleRate: state.activeOutput?.nominalSampleRate ?? runtime.sampleRate
            )
            return (runtime, activeProfile, state.profileRevision, maximumUsableFrequency)
        }) else {
            return nil
        }
        let (runtime, activeProfile, profileRevision, maximumUsableFrequency) = preparation
        guard let preparedConfig = try? EQRenderConfiguration.prepare(
            profile: profile,
            sampleRate: runtime.sampleRate,
            channelCount: runtime.channelCount,
            maximumUsableFrequency: maximumUsableFrequency
        ) else {
            return nil
        }
        return control.withLock { state in
            guard state.runtime === runtime,
                  state.activeProfile == activeProfile,
                  state.profileRevision == profileRevision else {
                return nil
            }
            return updateDSPLocked(
                &state,
                profile: profile,
                preparedConfig: preparedConfig
            )
        }
    }

    @discardableResult
    public func beginProgrammeComparison(profile: EQProfile) -> Bool {
        guard !profile.isBypassed else {
            return false
        }
        guard let preparation = control.withLock({ state -> (AudioRuntime, UInt64, Double)? in
            guard let runtime = state.runtime else {
                return nil
            }
            let maximumUsableFrequency = EQRouteFrequencyPolicy.maximumUsableFrequency(
                sampleRate: state.activeOutput?.nominalSampleRate ?? runtime.sampleRate
            )
            return (runtime, state.profileRevision, maximumUsableFrequency)
        }) else {
            return false
        }
        let (runtime, profileRevision, maximumUsableFrequency) = preparation
        guard let equalizedConfig = try? EQRenderConfiguration.prepare(
            profile: profile,
            sampleRate: runtime.sampleRate,
            channelCount: runtime.channelCount,
            maximumUsableFrequency: maximumUsableFrequency
        ),
        let referenceConfig = try? EQRenderConfiguration.prepare(
            profile: profile.programmeComparisonReference,
            sampleRate: runtime.sampleRate,
            channelCount: runtime.channelCount,
            maximumUsableFrequency: maximumUsableFrequency
        ) else {
            return false
        }
        return control.withLock { state in
            guard state.runtime === runtime,
                  state.profileRevision == profileRevision else {
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
        control.withLock { state in
            state.runtime?.setProgrammeComparisonSelection(selection)
        }
    }

    public func snapshotProgrammeComparison() -> EQProgrammeComparisonSnapshot {
        control.withLock { $0.runtime }?.snapshotProgrammeComparison()
            ?? EQProgrammeComparisonSnapshot()
    }

    public func dspTransitionProgress() -> DSPTransitionProgress {
        control.withLock { $0.runtime }?.dspTransitionProgress() ?? DSPTransitionProgress()
    }

    private func updateDSPLocked(
        _ state: inout ControlState,
        profile: EQProfile,
        preparedConfig: EQRenderConfiguration? = nil,
        incrementsProfileRevision: Bool = true
    ) -> DSPTransitionProgress.Target? {
        guard let runtime = state.runtime,
              let activeProfile = state.activeProfile else {
            return nil
        }
        let maximumUsableFrequency = EQRouteFrequencyPolicy.maximumUsableFrequency(
            sampleRate: state.activeOutput?.nominalSampleRate ?? runtime.sampleRate
        )

        guard let preparedConfig = preparedConfig ?? (try? EQRenderConfiguration.prepare(
            profile: profile,
            sampleRate: runtime.sampleRate,
            channelCount: runtime.channelCount,
            maximumUsableFrequency: maximumUsableFrequency
        )),
        Self.canHotSwapDSP(
            from: activeProfile,
            to: profile,
            sampleRate: runtime.sampleRate,
            channelCount: runtime.channelCount,
            maximumUsableFrequency: maximumUsableFrequency,
            preparedConfiguration: preparedConfig
        ) else {
            return nil
        }
        runtime.setProgrammeComparisonSelection(.equalized)
        runtime.drainDSPConfigBoxes()
        let target = runtime.publishPendingDSPConfig(preparedConfig)
        state.activeProfile = profile
        if incrementsProfileRevision {
            state.profileRevision &+= 1
        }
        return target
    }

    static func canHotSwapDSP(
        from _: EQProfile,
        to nextProfile: EQProfile,
        sampleRate: Double,
        channelCount: Int,
        maximumUsableFrequency: Double? = nil,
        preparedConfiguration: EQRenderConfiguration? = nil
    ) -> Bool {
        if let preparedConfiguration {
            return preparedConfiguration.isNumericallySafe
        }
        return (try? EQRenderConfiguration.prepare(
            profile: nextProfile,
            sampleRate: sampleRate,
            channelCount: channelCount,
            maximumUsableFrequency: maximumUsableFrequency
        )) != nil
    }

    public func muteOutputForTransition() {
        control.withLock { state in
            state.runtime?.muteOutputForTransition()
        }
    }

    public func resumeOutputAfterCancelledTransition() {
        control.withLock { state in
            state.runtime?.resumeOutputAfterCancelledTransition()
        }
    }

    public func stop() {
        pausePlaybackBufferAdaptation()
        control.withLock { state in
            stopLocked(&state)
        }
        retryCoreAudioCleanup()
        updatePlaybackBufferAdaptationTimer()
    }

    public func snapshotMetrics() -> AudioEngineMetrics {
        let runtime = control.withLock { $0.runtime }
        return runtime?.snapshotMetrics() ?? AudioEngineMetrics()
    }

    func diagnosticDeviceIDs() -> (physical: AudioObjectID, aggregate: AudioObjectID)? {
        control.withLock { state in
            guard let output = state.activeOutput,
                  state.aggregateDeviceID != kAudioObjectUnknown else {
                return nil
            }
            return (output.id, state.aggregateDeviceID)
        }
    }

    var processingSampleRate: Double? {
        control.withLock { $0.runtime?.sampleRate }
    }

    public func resetDiagnostics() {
        let runtime = control.withLock { $0.runtime }
        runtime?.resetMetrics()
    }

    public func setPlaybackBufferRenegotiationHandler(
        _ handler: (@Sendable (PlaybackBufferRenegotiation) -> Void)?
    ) {
        playbackBufferRenegotiationHandler.withLock { currentHandler in
            currentHandler = handler
        }
    }

    public func setRuntimeFailureHandler(
        _ handler: (@Sendable (AudioEngineFailure) -> Void)?
    ) {
        runtimeFailureHandler.withLock { currentHandler in
            currentHandler = handler
        }
    }

    #if DEBUG
    func simulateRenderStallForTesting() {
        control.withLock { $0.runtime }?.simulateRenderStallForTesting()
    }
    #endif

    private func stopLocked(_ state: inout ControlState) {
        state.runtime?.markStopping()
        stopOutputHalfLocked(&state)
        stopCaptureHalfLocked(&state)
        state.activeProfile = nil
        state.profileRevision &+= 1
        state.playbackBufferAdaptationEvidence = PlaybackBufferAdaptationEvidence()
        state.playbackBufferStableSince = nil
        state.adaptivePlaybackRenderRecoveryAttempts = 0
        state.adaptivePlaybackRenderRecoveryHealthGeneration = nil
        state.playbackBufferInstabilityPersistenceGate.reset()
        state.failedPlaybackFrameSizeDecayCandidates.removeAll()
        state.state = .stopped
        state.status = .stopped
    }

    // MARK: - Capture half (persistent global muted tap @ the tap rate)

    private func ensureCaptureHalfLocked(
        _ state: inout ControlState,
        output: AudioOutputDevice,
        profile: EQProfile
    ) throws {
        if state.captureRunning, state.runtime != nil {
            let shouldRefreshCapture = Self.shouldRefreshCaptureForOutput(
                tapSampleRate: state.tapSampleRate,
                output: output
            )
            if !shouldRefreshCapture,
               updateDSPLocked(&state, profile: profile, incrementsProfileRevision: false) != nil {
                return
            }
            // Hold a second global muted tap while capture is recreated, so HAL-level muting
            // never lapses during topology changes or low-rate capture refreshes.
            try Self.performTopologyRebuild(
                acquireMuteGuard: { try createTopologyRebuildMuteGuard() }
            ) {
                stopOutputHalfLocked(&state)
                stopCaptureHalfLocked(&state)
                try requireCompletedCoreAudioCleanup(
                    operation: "rebuild compatibility capture"
                )
                try createCaptureHalfLocked(&state, profile: profile)
            }
            return
        }
        try createCaptureHalfLocked(&state, profile: profile)
    }

    private func createCaptureHalfLocked(_ state: inout ControlState, profile: EQProfile) throws {
        traceDiagnostic { "compatibility capture create begin" }
        let tapID = try createSystemTap()
        state.tapID = tapID

        let format = try tapStreamFormat(tapID)
        let tapSampleRate = format.mSampleRate > 0 ? format.mSampleRate : 48_000
        let tapChannelCount = min(max(Int(format.mChannelsPerFrame), 1), 2)
        state.tapSampleRate = tapSampleRate
        state.tapChannelCount = tapChannelCount

        let runtimeBufferFrameSize = Int(Self.maximumRuntimeBufferFrameSize)
        // Low-latency tuning: a 128-frame prime (~2.7 ms @ 48k) — about 2x the tap's callback
        // once we request a 64-frame capture buffer below. Capacity is sized from the largest
        // runtime output callback so every supported prime retains equal drift headroom.
        let playbackPrimeFrames = Self.preferredPlaybackPrimeFrames
        let ringCapacityFrames = Self.runtimeRingCapacityFrames
        let scratchFrames = max(runtimeBufferFrameSize, Self.minimumRingBufferFrames)

        state.aggregateDeviceID = try createPrivateAggregateDevice(tapID: tapID)
        // Ask the capture aggregate for small callbacks to cut latency. The write is best-effort,
        // so size the initial playback reservoir from the value the aggregate actually reports.
        traceDiagnostic {
            "set compatibility capture buffer begin device=\(state.aggregateDeviceID) requested=\(Self.preferredCaptureBufferFrameSize)"
        }
        do {
            try CoreAudioDeviceQuery.setBufferFrameSize(
                Self.preferredCaptureBufferFrameSize,
                objectID: state.aggregateDeviceID
            )
            traceDiagnostic {
                "set compatibility capture buffer return status=0 device=\(state.aggregateDeviceID)"
            }
        } catch {
            traceDiagnostic {
                "set compatibility capture buffer failed device=\(state.aggregateDeviceID) error=\(error)"
            }
        }
        let reportedCaptureCallbackFrames = try? CoreAudioDeviceQuery.getUInt32Property(
            objectID: state.aggregateDeviceID,
            selector: kAudioDevicePropertyBufferFrameSize,
            scope: kAudioObjectPropertyScopeGlobal
        )
        let captureCallbackFrames = Self.startupCaptureCallbackFrames(
            reportedFrames: reportedCaptureCallbackFrames
        )

        let renderConfiguration = try EQRenderConfiguration.prepare(
            profile: profile,
            sampleRate: tapSampleRate,
            channelCount: tapChannelCount
        )
        let runtime = AudioRuntime(
            renderConfiguration: renderConfiguration,
            ringCapacityFrames: ringCapacityFrames,
            scratchFrames: scratchFrames,
            captureCallbackFrames: captureCallbackFrames,
            playbackPrimeFrames: playbackPrimeFrames
        )
        state.runtime = runtime
        state.activeProfile = profile

        state.captureIOProcID = try createCaptureIOProc(deviceID: state.aggregateDeviceID, runtime: runtime)
        traceDiagnostic {
            "AudioDeviceStart(compatibility capture) begin device=\(state.aggregateDeviceID) buffer=\(captureCallbackFrames)"
        }
        let startStatus = AudioDeviceStart(state.aggregateDeviceID, state.captureIOProcID)
        traceDiagnostic {
            "AudioDeviceStart(compatibility capture) return status=\(startStatus) device=\(state.aggregateDeviceID)"
        }
        try checkOSStatus(startStatus, operation: "AudioDeviceStart(capture tap)")
        state.captureRunning = true
        traceDiagnostic { "compatibility capture create end device=\(state.aggregateDeviceID)" }
    }

    private func stopCaptureHalfLocked(_ state: inout ControlState) {
        state.runtime?.markStopping()
        var resources = CoreAudioResourceCleanupLedger.PendingResources(
            operation: "dispose compatibility capture"
        )
        if state.aggregateDeviceID != kAudioObjectUnknown, let captureIOProcID = state.captureIOProcID {
            resources.ioProcs.append(.init(
                deviceID: state.aggregateDeviceID,
                ioProcID: captureIOProcID
            ))
        }
        if state.aggregateDeviceID != kAudioObjectUnknown {
            resources.aggregateDeviceIDs.append(state.aggregateDeviceID)
        }
        if state.tapID != kAudioObjectUnknown {
            resources.tapIDs.append(state.tapID)
        }
        if (!resources.ioProcs.isEmpty
            || !resources.aggregateDeviceIDs.isEmpty
            || !resources.tapIDs.isEmpty),
           !cleanupLedger.dispose(resources) {
            traceDiagnostic {
                "Core Audio cleanup deferred operation=dispose compatibility capture pending=\(cleanupLedger.pendingCount)"
            }
        }

        state.captureIOProcID = nil
        state.aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        state.tapID = AudioObjectID(kAudioObjectUnknown)
        state.runtime = nil
        state.tapSampleRate = 0
        state.tapChannelCount = 0
        state.captureRunning = false
    }

    // MARK: - Output half (swappable; direct-rate or converted low-rate playback)

    private func prepareOutputRebuildLocked(
        _ state: inout ControlState,
        output: AudioOutputDevice,
        profile: EQProfile,
        profileRevision: UInt64,
        outputSettingsPolicy: OutputDeviceSettingsPolicy
    ) throws -> OutputRebuildPreparation {
        guard let runtime = state.runtime else {
            throw CoreAudioError(operation: "rebuildOutputHalf(missing runtime)", status: kAudioHardwareNotRunningError)
        }
        // Low-rate endpoints and cold-start staging keep device-owned sample rates and receive
        // realtime sample-rate conversion in the playback callback.
        let originalBufferFrameSize = output.bufferFrameSize
        _ = try Self.supportedRuntimeChannelCount(for: output)
        stopOutputHalfLocked(&state)
        try requireCompletedCoreAudioCleanup(operation: "replace compatibility output")
        return OutputRebuildPreparation(
            generation: state.outputRebuildGeneration,
            output: output,
            profile: profile,
            runtime: runtime,
            tapSampleRate: state.tapSampleRate,
            originalBufferFrameSize: originalBufferFrameSize,
            profileRevision: profileRevision,
            outputSettingsPolicy: outputSettingsPolicy
        )
    }

    private func finishOutputRebuildLocked(
        _ state: inout ControlState,
        preparation: OutputRebuildPreparation,
        matchedOutput: AudioOutputDevice
    ) throws {
        let handoff = try prepareOutputHandoffLocked(
            &state,
            preparation: preparation,
            matchedOutput: matchedOutput
        )
        _ = try activatePreparedOutputHandoffLocked(&state, handoff: handoff)
    }

    private func prepareOutputHandoffLocked(
        _ state: inout ControlState,
        preparation: OutputRebuildPreparation,
        matchedOutput: AudioOutputDevice
    ) throws -> PreparedOutputHandoff {
        guard state.outputRebuildGeneration == preparation.generation,
              state.runtime === preparation.runtime,
              state.captureRunning else {
            throw StaleOutputRebuild()
        }
        let runtime = preparation.runtime
        let output = preparation.output
        let effectiveProfile = Self.effectiveOutputRebuildProfile(
            preparedProfile: preparation.profile,
            preparedProfileRevision: preparation.profileRevision,
            activeProfile: state.activeProfile,
            activeProfileRevision: state.profileRevision
        )
        _ = try Self.supportedRuntimeChannelCount(for: matchedOutput)
        if preparation.outputSettingsPolicy == .adaptiveLowLatency,
           state.bufferFrameSizeRestorations[output.uid] == nil {
            let restoration = BufferFrameSizeRestoration(
                uid: output.uid,
                originalFrameSize: preparation.originalBufferFrameSize
            )
            try PersistedAudioDeviceRestorationStore.recordBufferFrameSize(
                uid: restoration.uid,
                originalFrameSize: restoration.originalFrameSize,
                at: restorationStoreURL
            )
            state.bufferFrameSizeRestorations[output.uid] = restoration
        }

        // Keep our replay muted while we claim and reconfigure the device. The ORDER matters:
        // start our output IOProc (so GlassEQ owns the device) BEFORE writing the buffer size.
        // Writing the buffer size restarts the device's hardware stream; doing it after we own
        // the device means that restart re-engages our (muted) IOProc instead of briefly
        // replaying the un-muted system mix. The buffer write's own property-change notification
        // is ignored via CoreAudioSelfChangeGuard, so it no longer triggers a rebuild loop.
        runtime.muteOutputForTransition()

        // Multi-channel devices play the stereo stream on their preferred stereo pair (the same
        // channels macOS routes system audio to); every other channel receives silence. The pair
        // must be stored before AudioDeviceStart so the first callback already maps correctly.
        let preferredChannels = try? CoreAudioDeviceQuery.preferredStereoChannels(objectID: matchedOutput.id)
        let channelPair = Self.playbackStereoPair(
            preferredChannels: preferredChannels,
            outputChannelCount: matchedOutput.outputChannelCount
        )
        runtime.setPlaybackChannelPair(left: channelPair.left, right: channelPair.right)

        guard let outputIOProcID = try createOutputIOProc(deviceID: matchedOutput.id, runtime: runtime) else {
            throw CoreAudioError(operation: "AudioDeviceCreateIOProcID(default output)", status: kAudioHardwareUnspecifiedError)
        }
        do {
            let targetFrames = preferredPlaybackTargetFrames(
                for: matchedOutput,
                tapSampleRate: runtime.sampleRate,
                captureCallbackFrames: runtime.maximumKnownCaptureCallbackFrames()
            )
            runtime.drainDSPConfigBoxes()
            runtime.publishPendingDSPConfig(try EQRenderConfiguration.prepare(
                profile: effectiveProfile,
                sampleRate: runtime.sampleRate,
                channelCount: runtime.channelCount,
                maximumUsableFrequency: EQRouteFrequencyPolicy.maximumUsableFrequency(
                    sampleRate: matchedOutput.nominalSampleRate
                )
            ))
            try runtime.configurePlayback(
                primeFrames: targetFrames,
                outputSampleRate: matchedOutput.nominalSampleRate
            )
        } catch {
            disposeOutputIOProc(
                deviceID: matchedOutput.id,
                ioProcID: outputIOProcID,
                operation: "discard unconfigured physical output"
            )
            throw error
        }

        return PreparedOutputHandoff(
            preparation: preparation,
            output: matchedOutput,
            profile: effectiveProfile,
            ioProcID: outputIOProcID
        )
    }

    private func activatePreparedOutputHandoffLocked(
        _ state: inout ControlState,
        handoff: PreparedOutputHandoff
    ) throws -> AudioOutputDevice {
        let preparation = handoff.preparation
        guard state.outputRebuildGeneration == preparation.generation,
              state.runtime === preparation.runtime,
              state.captureRunning else {
            disposeOutputIOProc(
                deviceID: handoff.output.id,
                ioProcID: handoff.ioProcID,
                operation: "discard stale physical output"
            )
            throw StaleOutputRebuild()
        }
        let runtime = preparation.runtime
        do {
            traceDiagnostic {
                "AudioDeviceStart(physical output) begin device=\(handoff.output.id) buffer=\(handoff.output.bufferFrameSize)"
            }
            let status = AudioDeviceStart(handoff.output.id, handoff.ioProcID)
            traceDiagnostic {
                "AudioDeviceStart(physical output) return status=\(status) device=\(handoff.output.id)"
            }
            try checkOSStatus(status, operation: "AudioDeviceStart(default output)")
        } catch {
            disposeOutputIOProc(
                deviceID: handoff.output.id,
                ioProcID: handoff.ioProcID,
                operation: "discard failed physical output"
            )
            throw error
        }
        state.outputIOProcID = handoff.ioProcID
        // Keep IOProc ownership paired with its device so failure cleanup can stop it.
        state.activeOutput = handoff.output

        // Compatibility mode applies its low-latency setting only after claiming the device.
        // Cold-start staging instead preserves the sample rate and buffer used by active clients;
        // changing either shared setting can destabilize a client before the aggregate takes over.
        let tunedOutput = switch preparation.outputSettingsPolicy {
        case .adaptiveLowLatency:
            tuneBufferFrameSize(
                for: handoff.output,
                tapSampleRate: runtime.sampleRate
            )
        case .preserveCurrent:
            handoff.output
        }
        try Self.validatePlaybackCallbackCapacity(for: tunedOutput)
        try Self.validatePlaybackConversionCapacity(
            for: tunedOutput,
            tapSampleRate: runtime.sampleRate,
            captureCallbackFrames: runtime.maximumKnownCaptureCallbackFrames(),
            preservingOutputSampleRate: preparation.outputSettingsPolicy.preservesCurrentSettings
        )
        state.activeOutput = tunedOutput
        state.activeOutputSettingsPolicy = preparation.outputSettingsPolicy
        let targetFrames = preferredPlaybackTargetFrames(
            for: tunedOutput,
            tapSampleRate: runtime.sampleRate,
            captureCallbackFrames: runtime.maximumKnownCaptureCallbackFrames()
        )
        runtime.retargetPlayback(primeFrames: targetFrames)
        state.playbackBufferAdaptationEvidence.reset(
            instabilityGeneration: runtime.playbackInstabilitySnapshot().generation,
            timestampDiscontinuities: runtime.playbackTimestampDiscontinuityCount()
        )
        state.playbackBufferCalibrationProbe = preparation.outputSettingsPolicy == .adaptiveLowLatency
            ? playbackBufferCalibrationProbe(
                for: tunedOutput,
                tapSampleRate: runtime.sampleRate,
                targetFrames: targetFrames
            )
            : nil
        state.playbackBufferStableSince = state.playbackBufferCalibrationProbe == nil
            ? ContinuousClock().now
            : nil

        // Unmute and re-anchor playback to the freshest captured audio on the new device.
        runtime.reprimePlayback()

        state.activeProfile = handoff.profile
        return tunedOutput
    }

    private func stopOutputHalfLocked(_ state: inout ControlState) {
        state.outputRebuildGeneration += 1
        if let prepared = state.preparedOutputHandoff {
            traceDiagnostic {
                "AudioDeviceDestroyIOProcID(prepared physical output) begin device=\(prepared.output.id)"
            }
            disposeOutputIOProc(
                deviceID: prepared.output.id,
                ioProcID: prepared.ioProcID,
                operation: "dispose prepared physical output"
            )
            traceDiagnostic {
                "AudioDeviceDestroyIOProcID(prepared physical output) submitted device=\(prepared.output.id)"
            }
            state.preparedOutputHandoff = nil
        }
        if let output = state.activeOutput, let outputIOProcID = state.outputIOProcID {
            traceDiagnostic {
                "AudioDeviceStop(physical output) begin device=\(output.id) buffer=\(output.bufferFrameSize)"
            }
            traceDiagnostic {
                "AudioDeviceDestroyIOProcID(physical output) begin device=\(output.id)"
            }
            disposeOutputIOProc(
                deviceID: output.id,
                ioProcID: outputIOProcID,
                operation: "dispose physical output"
            )
            traceDiagnostic {
                "AudioDeviceDestroyIOProcID(physical output) submitted device=\(output.id)"
            }
        }
        state.outputIOProcID = nil
        traceDiagnostic {
            "restore compatibility device settings begin sampleRateRecords=\(state.sampleRateRestorations.count) bufferRecords=\(state.bufferFrameSizeRestorations.count)"
        }
        restoreDeviceSettingsIfNeeded(&state)
        traceDiagnostic {
            "restore compatibility device settings end sampleRateRecords=\(state.sampleRateRestorations.count) bufferRecords=\(state.bufferFrameSizeRestorations.count)"
        }
        state.activeOutput = nil
        state.activeOutputSettingsPolicy = .adaptiveLowLatency
        state.playbackBufferCalibrationProbe = nil
    }

    private func forceSampleRate(
        _ sampleRate: Double,
        on output: AudioOutputDevice,
        recordRestoration: (SampleRateRestoration) throws -> Void
    ) throws -> AudioOutputDevice {
        guard sampleRate > 0, abs(output.nominalSampleRate - sampleRate) >= 1 else {
            return output
        }
        try Self.setSampleRateAfterRecordingRestoration(
            sampleRate,
            on: output,
            recordRestoration: recordRestoration,
            setSampleRate: CoreAudioDeviceQuery.setNominalSampleRate(_:objectID:)
        )
        for _ in 0..<3 {
            let freshOutput = try CoreAudioDeviceQuery.outputDevice(id: output.id)
            if abs(freshOutput.nominalSampleRate - sampleRate) < 1 {
                return freshOutput
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        let freshOutput = try CoreAudioDeviceQuery.outputDevice(id: output.id)
        throw AudioDeviceAvailabilityError.invalidDeviceMetadata(
            output.id,
            "output sample rate \(freshOutput.nominalSampleRate) does not match tap sample rate \(sampleRate)"
        )
    }

    private func preparePlaybackOutput(
        tapSampleRate: Double,
        output: AudioOutputDevice,
        settingsPolicy: OutputDeviceSettingsPolicy,
        recordRestoration: (SampleRateRestoration) throws -> Void
    ) throws -> AudioOutputDevice {
        if Self.shouldUseSampleRateConversion(
            tapSampleRate: tapSampleRate,
            output: output,
            preservingOutputSampleRate: settingsPolicy.preservesCurrentSettings
        ) {
            return output
        }
        return try forceSampleRate(
            tapSampleRate,
            on: output,
            recordRestoration: recordRestoration
        )
    }

    private func recordSampleRateRestorationIfNeeded(
        _ restoration: SampleRateRestoration,
        state: inout ControlState
    ) throws {
        guard state.sampleRateRestorations[restoration.uid] == nil else {
            return
        }
        try PersistedAudioDeviceRestorationStore.recordSampleRate(
            uid: restoration.uid,
            originalSampleRate: restoration.originalSampleRate,
            at: restorationStoreURL
        )
        state.sampleRateRestorations[restoration.uid] = restoration
    }

    static func setSampleRateAfterRecordingRestoration(
        _ sampleRate: Double,
        on output: AudioOutputDevice,
        recordRestoration: (SampleRateRestoration) throws -> Void,
        setSampleRate: (Double, AudioObjectID) throws -> Void
    ) throws {
        let restoration = SampleRateRestoration(
            uid: output.uid,
            originalSampleRate: output.nominalSampleRate
        )
        try recordRestoration(restoration)
        try setSampleRate(sampleRate, output.id)
    }

    private func restoreDeviceSettingsIfNeeded(_ state: inout ControlState) {
        var restoredSampleRateUIDs: [String] = []
        for (uid, restoration) in state.sampleRateRestorations {
            if Self.restoreSampleRateRestoration(restoration) {
                try? PersistedAudioDeviceRestorationStore.clearSampleRate(uid: uid, at: restorationStoreURL)
                restoredSampleRateUIDs.append(uid)
            }
        }
        for uid in restoredSampleRateUIDs {
            state.sampleRateRestorations.removeValue(forKey: uid)
        }

        var restoredBufferFrameSizeUIDs: [String] = []
        for (uid, restoration) in state.bufferFrameSizeRestorations {
            if Self.restoreBufferFrameSizeRestoration(restoration) {
                try? PersistedAudioDeviceRestorationStore.clearBufferFrameSize(uid: uid, at: restorationStoreURL)
                restoredBufferFrameSizeUIDs.append(uid)
            }
        }
        for uid in restoredBufferFrameSizeUIDs {
            state.bufferFrameSizeRestorations.removeValue(forKey: uid)
        }
    }

    static func restoreSampleRateRestoration(
        _ restoration: SampleRateRestoration,
        outputForUID: (String) throws -> AudioOutputDevice? = CoreAudioDeviceQuery.outputDevice(uid:),
        setSampleRate: (Double, AudioObjectID) throws -> Void = CoreAudioDeviceQuery.setNominalSampleRate(_:objectID:)
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
            return abs(verifiedOutput.nominalSampleRate - restoration.originalSampleRate) < 1
        } catch {
            return false
        }
    }

    static func restoreBufferFrameSizeRestoration(
        _ restoration: BufferFrameSizeRestoration,
        outputForUID: (String) throws -> AudioOutputDevice? = CoreAudioDeviceQuery.outputDevice(uid:),
        setBufferFrameSize: (UInt32, AudioObjectID) throws -> Void = CoreAudioDeviceQuery.setBufferFrameSize(_:objectID:)
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
        outputForUID: (String) throws -> AudioOutputDevice? = CoreAudioDeviceQuery.outputDevice(uid:),
        setSampleRate: (Double, AudioObjectID) throws -> Void = CoreAudioDeviceQuery.setNominalSampleRate(_:objectID:),
        setBufferFrameSize: (UInt32, AudioObjectID) throws -> Void = CoreAudioDeviceQuery.setBufferFrameSize(_:objectID:)
    ) {
        var records = PersistedAudioDeviceRestorationStore.load(from: url)
        guard !records.isEmpty else {
            return
        }

        for (uid, record) in records {
            var updated = record
            if let originalSampleRate = record.originalSampleRate,
               restoreSampleRateRestoration(
                   SampleRateRestoration(uid: uid, originalSampleRate: originalSampleRate),
                   outputForUID: outputForUID,
                   setSampleRate: setSampleRate
               ) {
                updated.originalSampleRate = nil
            }
            if let originalBufferFrameSize = record.originalBufferFrameSize,
               restoreBufferFrameSizeRestoration(
                   BufferFrameSizeRestoration(uid: uid, originalFrameSize: originalBufferFrameSize),
                   outputForUID: outputForUID,
                   setBufferFrameSize: setBufferFrameSize
               ) {
                updated.originalBufferFrameSize = nil
            }
            records[uid] = updated.isEmpty ? nil : updated
        }

        try? PersistedAudioDeviceRestorationStore.save(records, to: url)
    }

    private func audioEngineFailure(from error: Error) -> AudioEngineFailure {
        if let coreAudioError = error as? CoreAudioError {
            return classifyCoreAudioError(coreAudioError)
        }
        if let availabilityError = error as? AudioDeviceAvailabilityError {
            switch availabilityError {
            case .unsupportedOutputChannelCount,
                 .unsupportedOutputBufferFrameSize,
                 .unsupportedPlaybackConversionBuffer:
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
            operation: "SeparateClockAudioBackend"
        )
    }

    static func supportedRuntimeChannelCount(for output: AudioOutputDevice) throws -> Int {
        guard output.outputChannelCount > 0 else {
            throw AudioDeviceAvailabilityError.outputDeviceHasNoOutputChannels(output.id)
        }
        // getChannelCount sums per-buffer mNumberChannels without bounding them, so a broken
        // device can still report absurd counts; the playback mapper handles anything below this.
        guard output.outputChannelCount <= CoreAudioDeviceQuery.maxChannelCount else {
            throw AudioDeviceAvailabilityError.unsupportedOutputChannelCount(output.id, output.outputChannelCount)
        }
        return output.outputChannelCount
    }

    static func validatePlaybackCallbackCapacity(for output: AudioOutputDevice) throws {
        guard output.bufferFrameSize <= UInt32(maximumSupportedCallbackFrames) else {
            throw AudioDeviceAvailabilityError.unsupportedOutputBufferFrameSize(
                output.id,
                output.bufferFrameSize,
                maximum: UInt32(maximumSupportedCallbackFrames)
            )
        }
    }

    static func validatePlaybackConversionCapacity(
        for output: AudioOutputDevice,
        tapSampleRate: Double,
        captureCallbackFrames: Int = preferredLowSampleRatePlaybackReservoirFrames,
        preservingOutputSampleRate: Bool = false
    ) throws {
        guard shouldUseSampleRateConversion(
            tapSampleRate: tapSampleRate,
            output: output,
            preservingOutputSampleRate: preservingOutputSampleRate
        ) else {
            return
        }
        let requiredPrimeFrames = preferredPlaybackPrimeFrames(
            for: output,
            tapSampleRate: tapSampleRate,
            captureCallbackFrames: captureCallbackFrames
        )
        let maximumPrimeFrames = runtimeRingCapacityFrames / playbackRingPullCount
        guard requiredPrimeFrames <= maximumPrimeFrames else {
            throw AudioDeviceAvailabilityError.unsupportedPlaybackConversionBuffer(
                output.id,
                requiredPrimeFrames: requiredPrimeFrames,
                maximumPrimeFrames: maximumPrimeFrames
            )
        }
    }

    /// Normalizes a device-reported preferred stereo pair (1-based channel numbers; the HAL
    /// reports zeros when the pair was never configured) into 0-based destination channel
    /// indices. Falls back to the first two channels whenever the report is missing or
    /// inconsistent; mono devices collapse to (0, 0).
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
        return (Int(preferredChannels.left) - 1, Int(preferredChannels.right) - 1)
    }

    static func encodedPlaybackChannelPair(left: Int, right: Int) -> UInt64 {
        let maxChannelIndex = CoreAudioDeviceQuery.maxChannelCount - 1
        let clampedLeft = UInt64(min(max(left, 0), maxChannelIndex))
        let clampedRight = UInt64(min(max(right, 0), maxChannelIndex))
        return (clampedLeft << 32) | clampedRight
    }

    static func decodedPlaybackChannelPair(_ encoded: UInt64) -> (left: Int, right: Int) {
        (Int(encoded >> 32), Int(encoded & 0xFFFF_FFFF))
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
        let sampleBaseResult = frame.multipliedReportingOverflow(by: sourceChannelCount)
        guard !sampleBaseResult.overflow else {
            return 0
        }
        let sampleBase = sampleBaseResult.partialValue
        guard sampleBase >= 0,
              sampleBase < samples.count else {
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
            let destinationSamples = Int(buffers[0].mDataByteSize) / MemoryLayout<Float>.stride
            for frameIndex in 0..<frameCount where destinationFrameOffset + frameIndex < destinationSamples {
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
            let destinationSamples = Int(buffers[0].mDataByteSize) / MemoryLayout<Float>.stride
            if sourceSampleStart + copySamples <= samples.count,
               destinationSampleStart + copySamples <= destinationSamples,
               let source = samples.baseAddress {
                data.advanced(by: destinationSampleStart)
                    .update(from: source.advanced(by: sourceSampleStart), count: copySamples)
                return
            }
        }

        // General mapped case: the destination pair channels receive source L/R (mono sources
        // feed both); every other channel gets explicit zeros. Never trust HAL pre-zeroing —
        // stray signal would leak into a multi-channel interface's DAW/loopback channels.
        // Walks the AudioBufferList with a running global channel offset so interleaved,
        // multi-stream, and per-channel-buffer layouts all map correctly.
        guard frameCount > 0, sourceFrameOffset >= 0, destinationFrameOffset >= 0 else {
            return
        }
        let sourceRightChannel = min(1, sourceChannelCount - 1)
        var globalChannelOffset = 0
        for bufferIndex in buffers.indices {
            let bufferChannels = Int(buffers[bufferIndex].mNumberChannels)
            guard bufferChannels > 0,
                  let data = buffers[bufferIndex].mData?.assumingMemoryBound(to: Float.self) else {
                globalChannelOffset += max(bufferChannels, 0)
                continue
            }
            let destinationSampleCount = Int(buffers[bufferIndex].mDataByteSize) / MemoryLayout<Float>.stride
            let zeroStart = destinationFrameOffset * bufferChannels
            let zeroEnd = min((destinationFrameOffset + frameCount) * bufferChannels, destinationSampleCount)
            if zeroStart < zeroEnd {
                data.advanced(by: zeroStart).update(repeating: 0, count: zeroEnd - zeroStart)
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
            let sourceIndex = (sourceFrameOffset + frameIndex) * sourceChannelCount + sourceChannel
            guard sourceIndex < samples.count else {
                continue
            }
            let destinationIndex = (destinationFrameOffset + frameIndex) * bufferChannels + localChannel
            guard destinationIndex < destinationSampleCount else {
                continue
            }
            data[destinationIndex] = samples[sourceIndex]
        }
    }

    static func performTopologyRebuild<T>(
        acquireMuteGuard: () throws -> any TopologyRebuildMuteGuarding,
        rebuild: () throws -> T
    ) throws -> T {
        let muteGuard: any TopologyRebuildMuteGuarding
        do {
            muteGuard = try acquireMuteGuard()
        } catch {
            throw TopologyRebuildMuteGuardUnavailable(underlyingError: error)
        }
        let result: T
        do {
            result = try rebuild()
        } catch {
            muteGuard.release()
            throw error
        }
        guard muteGuard.release() else {
            throw CoreAudioError(
                operation: "Release profile rebuild mute guard",
                status: kAudioHardwareUnspecifiedError
            )
        }
        return result
    }

    private func tuneBufferFrameSize(
        for output: AudioOutputDevice,
        tapSampleRate: Double
    ) -> AudioOutputDevice {
        do {
            let range = try CoreAudioDeviceQuery.bufferFrameSizeRangeValue(objectID: output.id)
            let calibration = PersistedPlaybackBufferCalibrationStore.calibration(
                outputUID: output.uid,
                sampleRate: output.nominalSampleRate,
                tapSampleRate: tapSampleRate,
                from: playbackBufferCalibrationStoreURL
            )
            let requested = AdaptivePlaybackBufferPolicy.startupFrameSize(
                preferredFrameSize: Self.preferredBufferFrameSize(for: output),
                calibration: calibration,
                supportedRange: range
            )
            guard requested != output.bufferFrameSize else {
                return output
            }
            try CoreAudioDeviceQuery.setBufferFrameSize(requested, objectID: output.id)
            return try CoreAudioDeviceQuery.outputDevice(id: output.id)
        } catch {
            return output
        }
    }

    private func playbackBufferCalibrationProbe(
        for output: AudioOutputDevice,
        tapSampleRate: Double,
        targetFrames: Int,
        startedAt: ContinuousClock.Instant = ContinuousClock().now
    ) -> PlaybackBufferCalibrationProbe? {
        guard Self.shouldAdaptPlaybackBuffer(for: output) else {
            return nil
        }
        let calibration = PersistedPlaybackBufferCalibrationStore.calibration(
            outputUID: output.uid,
            sampleRate: output.nominalSampleRate,
            tapSampleRate: tapSampleRate,
            from: playbackBufferCalibrationStoreURL
        )
        guard PlaybackBufferCalibrationPolicy.shouldProbe(
            frameSize: output.bufferFrameSize,
            targetFrames: targetFrames,
            calibration: calibration
        ) else {
            return nil
        }
        return PlaybackBufferCalibrationProbe(
            outputUID: output.uid,
            sampleRate: output.nominalSampleRate,
            tapSampleRate: tapSampleRate,
            frameSize: output.bufferFrameSize,
            targetFrames: targetFrames,
            startedAt: startedAt
        )
    }

    private func preferredPlaybackTargetFrames(
        for output: AudioOutputDevice,
        tapSampleRate: Double,
        captureCallbackFrames: Int
    ) -> Int {
        let baseline = Self.preferredPlaybackPrimeFrames(
            for: output,
            tapSampleRate: tapSampleRate,
            captureCallbackFrames: captureCallbackFrames
        )
        guard Self.shouldAdaptPlaybackBuffer(for: output) else {
            return baseline
        }
        let calibration = PersistedPlaybackBufferCalibrationStore.calibration(
            outputUID: output.uid,
            sampleRate: output.nominalSampleRate,
            tapSampleRate: tapSampleRate,
            from: playbackBufferCalibrationStoreURL
        )
        let targetFrames = AdaptivePlaybackBufferPolicy.startupTargetFrames(
            baselineTargetFrames: baseline,
            operatingPoint: calibration?.operatingPoint(for: output.bufferFrameSize)
        )
        return min(targetFrames, Self.runtimeRingCapacityFrames / 2)
    }

    private func updatePlaybackBufferAdaptationTimer() {
        let shouldRun = control.withLock { state in
            guard case .running = state.state,
                  state.activeOutputSettingsPolicy == .adaptiveLowLatency,
                  let output = state.activeOutput else {
                return false
            }
            return Self.shouldAdaptPlaybackBuffer(for: output)
        }
        setPlaybackBufferAdaptationTimerRunning(shouldRun)
    }

    private func pausePlaybackBufferAdaptation() {
        setPlaybackBufferAdaptationTimerRunning(false)
        if DispatchQueue.getSpecific(key: playbackBufferAdaptationQueueKey) == nil {
            playbackBufferAdaptationQueue.sync {}
        }
    }

    private func setPlaybackBufferAdaptationTimerRunning(_ shouldRun: Bool) {
        playbackBufferAdaptationTimerRunning.withLock { isRunning in
            guard isRunning != shouldRun else {
                return
            }
            isRunning = shouldRun
            if shouldRun {
                playbackBufferAdaptationTimer.resume()
            } else {
                playbackBufferAdaptationTimer.suspend()
            }
        }
    }

    private func serviceAdaptivePlaybackBuffering() {
        let now = ContinuousClock().now
        guard let action = control.withLock({ state -> PlaybackBufferAdaptationAction? in
            guard let runtime = state.runtime,
                  let output = state.activeOutput,
                  state.activeOutputSettingsPolicy == .adaptiveLowLatency,
                  Self.shouldAdaptPlaybackBuffer(for: output) else {
                return nil
            }

            if let recoveryGeneration = state.adaptivePlaybackRenderRecoveryHealthGeneration,
               runtime.playbackRenderHealthGeneration() != recoveryGeneration {
                state.adaptivePlaybackRenderRecoveryAttempts = 0
                state.adaptivePlaybackRenderRecoveryHealthGeneration = nil
            }

            let instability = runtime.playbackInstabilitySnapshot()
            let evidence = state.playbackBufferAdaptationEvidence.observe(
                instabilityGeneration: instability.generation,
                reason: instability.reason,
                timestampDiscontinuities: runtime.playbackTimestampDiscontinuityCount(),
                at: now
            )
            if evidence.observedDisturbance {
                if state.playbackBufferCalibrationProbe != nil {
                    state.playbackBufferCalibrationProbe?.startedAt = now
                    state.playbackBufferStableSince = nil
                } else {
                    state.playbackBufferStableSince = now
                }
            }
            if let reason = evidence.escalationReason {
                state.playbackBufferStableSince = nil
                return .renegotiate(PlaybackBufferRenegotiationPreparation(
                    outputRebuildGeneration: state.outputRebuildGeneration,
                    reason: reason,
                    output: output,
                    runtime: runtime
                ))
            }

            if let probe = state.playbackBufferCalibrationProbe,
               probe.hasCompletedProbation(at: now) {
                return .stabilize(probe)
            }
            if let stableSince = state.playbackBufferStableSince,
               stableSince.duration(to: now) >= PlaybackBufferAdaptationPolicy.decayDelay {
                state.playbackBufferStableSince = nil
                return .decay(PlaybackBufferDecayPreparation(
                    outputRebuildGeneration: state.outputRebuildGeneration,
                    output: output,
                    runtime: runtime
                ))
            }
            return nil
        }) else {
            return
        }

        let preparation: PlaybackBufferRenegotiationPreparation
        switch action {
        case .stabilize(let probe):
            do {
                try PersistedPlaybackBufferCalibrationStore.recordStable(
                    outputUID: probe.outputUID,
                    sampleRate: probe.sampleRate,
                    tapSampleRate: probe.tapSampleRate,
                    frameSize: probe.frameSize,
                    targetFrames: probe.targetFrames,
                    at: playbackBufferCalibrationStoreURL
                )
            } catch {
                return
            }
            control.withLock { state in
                if state.playbackBufferCalibrationProbe == probe {
                    state.playbackBufferCalibrationProbe = nil
                    state.playbackBufferStableSince = now
                    state.playbackBufferInstabilityPersistenceGate.reset(outputUID: probe.outputUID)
                }
            }
            return
        case .decay(let preparation):
            decayPlaybackBufferIfPossible(preparation)
            return
        case .renegotiate(let pendingRenegotiation):
            preparation = pendingRenegotiation
        }

        if preparation.reason == .adaptiveRenderFailure {
            recoverAdaptivePlaybackRenderFailure(preparation)
            return
        }

        if increasePlaybackTargetIfPossible(preparation) {
            return
        }

        let range: AudioBufferFrameSizeRange
        do {
            range = try CoreAudioDeviceQuery.bufferFrameSizeRangeValue(objectID: preparation.output.id)
        } catch {
            continueCalibrationAfterUnresolvedInstability(preparation)
            return
        }
        guard let nextFrameSize = AdaptivePlaybackBufferPolicy.nextFrameSize(
            after: preparation.output.bufferFrameSize,
            supportedRange: range
        ) else {
            continueCalibrationAfterUnresolvedInstability(preparation)
            return
        }
        var proposedOutput = preparation.output
        proposedOutput.bufferFrameSize = nextFrameSize
        do {
            try Self.validatePlaybackConversionCapacity(
                for: proposedOutput,
                tapSampleRate: preparation.runtime.sampleRate,
                captureCallbackFrames: preparation.runtime.maximumKnownCaptureCallbackFrames()
            )
        } catch {
            continueCalibrationAfterUnresolvedInstability(preparation)
            return
        }

        let updatedOutput: AudioOutputDevice
        do {
            guard let result = try Self.renegotiatedPlaybackOutput(
                preparation.output,
                supportedRange: range,
                setBufferFrameSize: { [self] frameSize, objectID in
                    try control.withLock { state in
                        guard state.outputRebuildGeneration == preparation.outputRebuildGeneration,
                              state.runtime === preparation.runtime,
                              state.activeOutput == preparation.output else {
                            throw StaleOutputRebuild()
                        }
                        preparation.runtime.muteOutputForTransition()
                        try CoreAudioDeviceQuery.setBufferFrameSize(
                            frameSize,
                            objectID: objectID
                        )
                    }
                }
            ) else {
                recoverFailedPlaybackBufferRenegotiation(preparation)
                continueCalibrationAfterUnresolvedInstability(preparation)
                return
            }
            updatedOutput = result
        } catch {
            recoverFailedPlaybackBufferRenegotiation(preparation)
            continueCalibrationAfterUnresolvedInstability(preparation)
            return
        }

        let completedRenegotiation = control.withLock { state -> PlaybackBufferRenegotiation? in
            guard state.outputRebuildGeneration == preparation.outputRebuildGeneration,
                  state.runtime === preparation.runtime,
                  state.activeOutput == preparation.output else {
                return nil
            }

            let previousTargetFrames = preparation.runtime.playbackTargetFrames()
            let targetFrames = preferredPlaybackTargetFrames(
                for: updatedOutput,
                tapSampleRate: preparation.runtime.sampleRate,
                captureCallbackFrames: preparation.runtime.maximumKnownCaptureCallbackFrames()
            )
            preparation.runtime.retargetPlayback(
                primeFrames: targetFrames
            )
            preparation.runtime.recordPlaybackBufferRenegotiation()
            preparation.runtime.reprimePlayback()

            state.activeOutput = updatedOutput
            state.state = .running(output: updatedOutput)
            state.status = .running(output: updatedOutput)
            state.playbackBufferAdaptationEvidence.reset(
                instabilityGeneration: preparation.runtime.playbackInstabilitySnapshot().generation,
                timestampDiscontinuities: preparation.runtime.playbackTimestampDiscontinuityCount()
            )
            state.playbackBufferStableSince = nil
            state.playbackBufferCalibrationProbe = PlaybackBufferCalibrationProbe(
                outputUID: updatedOutput.uid,
                sampleRate: updatedOutput.nominalSampleRate,
                tapSampleRate: preparation.runtime.sampleRate,
                frameSize: updatedOutput.bufferFrameSize,
                targetFrames: targetFrames,
                startedAt: ContinuousClock().now
            )
            return PlaybackBufferRenegotiation(
                outputName: updatedOutput.name,
                outputUID: updatedOutput.uid,
                sampleRate: updatedOutput.nominalSampleRate,
                previousFrameSize: preparation.output.bufferFrameSize,
                frameSize: updatedOutput.bufferFrameSize,
                previousPlaybackTargetFrames: previousTargetFrames,
                playbackTargetFrames: targetFrames,
                cause: .instability(preparation.reason)
            )
        }
        guard let completedRenegotiation else {
            return
        }
        try? PersistedPlaybackBufferCalibrationStore.recordInstability(
            outputUID: completedRenegotiation.outputUID,
            sampleRate: completedRenegotiation.sampleRate,
            tapSampleRate: preparation.runtime.sampleRate,
            previousFrameSize: completedRenegotiation.previousFrameSize,
            resultingFrameSize: completedRenegotiation.frameSize,
            previousTargetFrames: completedRenegotiation.previousPlaybackTargetFrames,
            resultingTargetFrames: completedRenegotiation.playbackTargetFrames,
            reason: preparation.reason,
            at: playbackBufferCalibrationStoreURL
        )
        let handler = playbackBufferRenegotiationHandler.withLock { $0 }
        handler?(completedRenegotiation)
    }

    private func increasePlaybackTargetIfPossible(
        _ preparation: PlaybackBufferRenegotiationPreparation
    ) -> Bool {
        let adjustment = control.withLock { state -> PlaybackBufferTargetAdjustment? in
            guard state.outputRebuildGeneration == preparation.outputRebuildGeneration,
                  state.runtime === preparation.runtime,
                  state.activeOutput == preparation.output else {
                return nil
            }
            let previousTargetFrames = preparation.runtime.playbackTargetFrames()
            guard let targetFrames = AdaptivePlaybackBufferPolicy.nextTargetFrames(
                callbackFrames: Self.playbackInputCallbackFrames(
                    for: preparation.output,
                    tapSampleRate: preparation.runtime.sampleRate
                ),
                after: previousTargetFrames,
                maximumReservoirFrames: Self.maximumPlaybackReservoirFrames(
                    for: preparation.output,
                    tapSampleRate: preparation.runtime.sampleRate,
                    maximumKnownCaptureCallbackFrames: preparation.runtime
                        .maximumKnownCaptureCallbackFrames()
                )
            ) else {
                return nil
            }

            preparation.runtime.retargetPlayback(
                primeFrames: targetFrames
            )
            preparation.runtime.recordPlaybackBufferRenegotiation()
            preparation.runtime.reprimePlayback()
            state.playbackBufferAdaptationEvidence.reset(
                instabilityGeneration: preparation.runtime.playbackInstabilitySnapshot().generation,
                timestampDiscontinuities: preparation.runtime.playbackTimestampDiscontinuityCount()
            )
            state.playbackBufferStableSince = nil
            state.playbackBufferCalibrationProbe = PlaybackBufferCalibrationProbe(
                outputUID: preparation.output.uid,
                sampleRate: preparation.output.nominalSampleRate,
                tapSampleRate: preparation.runtime.sampleRate,
                frameSize: preparation.output.bufferFrameSize,
                targetFrames: targetFrames,
                startedAt: ContinuousClock().now
            )
            return PlaybackBufferTargetAdjustment(
                output: preparation.output,
                tapSampleRate: preparation.runtime.sampleRate,
                previousTargetFrames: previousTargetFrames,
                targetFrames: targetFrames
            )
        }
        guard let adjustment else {
            return false
        }

        try? PersistedPlaybackBufferCalibrationStore.recordInstability(
            outputUID: adjustment.output.uid,
            sampleRate: adjustment.output.nominalSampleRate,
            tapSampleRate: adjustment.tapSampleRate,
            previousFrameSize: adjustment.output.bufferFrameSize,
            resultingFrameSize: adjustment.output.bufferFrameSize,
            previousTargetFrames: adjustment.previousTargetFrames,
            resultingTargetFrames: adjustment.targetFrames,
            reason: .underrun,
            at: playbackBufferCalibrationStoreURL
        )
        return true
    }

    private func decayPlaybackBufferIfPossible(
        _ preparation: PlaybackBufferDecayPreparation
    ) {
        switch decayPlaybackTargetIfPossible(preparation) {
        case .adjusted, .blocked:
            return
        case .atBaseline:
            break
        }

        let range: AudioBufferFrameSizeRange
        do {
            range = try CoreAudioDeviceQuery.bufferFrameSizeRangeValue(objectID: preparation.output.id)
        } catch {
            resumePlaybackBufferDecayAfterFailure(preparation)
            return
        }
        guard let frameSize = AdaptivePlaybackBufferPolicy.previousFrameSize(
            before: preparation.output.bufferFrameSize,
            supportedRange: range
        ),
              frameSize >= Self.preferredBufferFrameSize(for: preparation.output) else {
            return
        }

        var proposedOutput = preparation.output
        proposedOutput.bufferFrameSize = frameSize
        do {
            try Self.validatePlaybackConversionCapacity(
                for: proposedOutput,
                tapSampleRate: preparation.runtime.sampleRate,
                captureCallbackFrames: preparation.runtime.maximumKnownCaptureCallbackFrames()
            )
        } catch {
            return
        }

        let calibration = PersistedPlaybackBufferCalibrationStore.calibration(
            outputUID: proposedOutput.uid,
            sampleRate: proposedOutput.nominalSampleRate,
            tapSampleRate: preparation.runtime.sampleRate,
            from: playbackBufferCalibrationStoreURL
        )
        let operatingPoint = calibration?.operatingPoint(for: frameSize)
        let baselineTargetFrames = Self.preferredPlaybackPrimeFrames(
            for: proposedOutput,
            tapSampleRate: preparation.runtime.sampleRate,
            captureCallbackFrames: preparation.runtime.maximumKnownCaptureCallbackFrames()
        )
        let targetFrames = max(
            baselineTargetFrames,
            Int(operatingPoint?.stableTargetFrames ?? 0)
        )
        guard targetFrames > Int(operatingPoint?.unstableThroughTargetFrames ?? 0) else {
            return
        }

        let candidate = PlaybackBufferFrameSizeDecayCandidate(
            output: preparation.output,
            tapSampleRate: preparation.runtime.sampleRate,
            frameSize: frameSize
        )
        let shouldAttemptDecay = control.withLock { state in
            guard state.outputRebuildGeneration == preparation.outputRebuildGeneration,
                  state.runtime === preparation.runtime,
                  state.activeOutput == preparation.output else {
                return false
            }
            return !state.failedPlaybackFrameSizeDecayCandidates.contains(candidate)
        }
        guard shouldAttemptDecay else {
            return
        }

        let updatedOutput: AudioOutputDevice
        do {
            guard let result = try Self.decayedPlaybackOutput(
                preparation.output,
                supportedRange: range,
                setBufferFrameSize: { [self] frameSize, objectID in
                    try control.withLock { state in
                        guard state.outputRebuildGeneration == preparation.outputRebuildGeneration,
                              state.runtime === preparation.runtime,
                              state.activeOutput == preparation.output,
                              !state.failedPlaybackFrameSizeDecayCandidates.contains(candidate) else {
                            throw StaleOutputRebuild()
                        }
                        preparation.runtime.muteOutputForTransition()
                        try CoreAudioDeviceQuery.setBufferFrameSize(
                            frameSize,
                            objectID: objectID
                        )
                    }
                }
            ) else {
                failPlaybackBufferFrameSizeDecay(preparation, candidate: candidate)
                return
            }
            updatedOutput = result
        } catch {
            failPlaybackBufferFrameSizeDecay(preparation, candidate: candidate)
            return
        }

        let completedRenegotiation = control.withLock { state -> PlaybackBufferRenegotiation? in
            guard state.outputRebuildGeneration == preparation.outputRebuildGeneration,
                  state.runtime === preparation.runtime,
                  state.activeOutput == preparation.output else {
                return nil
            }
            let previousTargetFrames = preparation.runtime.playbackTargetFrames()
            preparation.runtime.retargetPlayback(primeFrames: targetFrames)
            preparation.runtime.recordPlaybackBufferRenegotiation()
            preparation.runtime.reprimePlayback()

            state.activeOutput = updatedOutput
            state.state = .running(output: updatedOutput)
            state.status = .running(output: updatedOutput)
            state.playbackBufferAdaptationEvidence.reset(
                instabilityGeneration: preparation.runtime.playbackInstabilitySnapshot().generation,
                timestampDiscontinuities: preparation.runtime.playbackTimestampDiscontinuityCount()
            )
            state.playbackBufferStableSince = nil
            state.playbackBufferCalibrationProbe = PlaybackBufferCalibrationProbe(
                outputUID: updatedOutput.uid,
                sampleRate: updatedOutput.nominalSampleRate,
                tapSampleRate: preparation.runtime.sampleRate,
                frameSize: updatedOutput.bufferFrameSize,
                targetFrames: targetFrames,
                startedAt: ContinuousClock().now
            )
            return PlaybackBufferRenegotiation(
                outputName: updatedOutput.name,
                outputUID: updatedOutput.uid,
                sampleRate: updatedOutput.nominalSampleRate,
                previousFrameSize: preparation.output.bufferFrameSize,
                frameSize: updatedOutput.bufferFrameSize,
                previousPlaybackTargetFrames: previousTargetFrames,
                playbackTargetFrames: targetFrames,
                cause: .stableDecay
            )
        }
        guard let completedRenegotiation else {
            return
        }
        try? PersistedPlaybackBufferCalibrationStore.beginProbe(
            outputUID: completedRenegotiation.outputUID,
            sampleRate: completedRenegotiation.sampleRate,
            tapSampleRate: preparation.runtime.sampleRate,
            frameSize: completedRenegotiation.frameSize,
            targetFrames: completedRenegotiation.playbackTargetFrames,
            at: playbackBufferCalibrationStoreURL
        )
        playbackBufferRenegotiationHandler.withLock { $0 }?(completedRenegotiation)
    }

    private func decayPlaybackTargetIfPossible(
        _ preparation: PlaybackBufferDecayPreparation
    ) -> PlaybackBufferTargetDecayResult {
        let calibration = PersistedPlaybackBufferCalibrationStore.calibration(
            outputUID: preparation.output.uid,
            sampleRate: preparation.output.nominalSampleRate,
            tapSampleRate: preparation.runtime.sampleRate,
            from: playbackBufferCalibrationStoreURL
        )
        var probe: PlaybackBufferCalibrationProbe?
        let result = control.withLock { state -> PlaybackBufferTargetDecayResult in
            guard state.outputRebuildGeneration == preparation.outputRebuildGeneration,
                  state.runtime === preparation.runtime,
                  state.activeOutput == preparation.output else {
                return .blocked
            }
            let currentTargetFrames = preparation.runtime.playbackTargetFrames()
            let baselineTargetFrames = Self.preferredPlaybackPrimeFrames(
                for: preparation.output,
                tapSampleRate: preparation.runtime.sampleRate,
                captureCallbackFrames: preparation.runtime.maximumKnownCaptureCallbackFrames()
            )
            guard currentTargetFrames >= baselineTargetFrames else {
                return .blocked
            }
            guard currentTargetFrames > baselineTargetFrames else {
                return .atBaseline
            }
            guard let targetFrames = AdaptivePlaybackBufferPolicy.nextDecayTargetFrames(
                callbackFrames: Self.playbackInputCallbackFrames(
                    for: preparation.output,
                    tapSampleRate: preparation.runtime.sampleRate
                ),
                stableTargetFrames: currentTargetFrames,
                unstableThroughTargetFrames: calibration?
                    .operatingPoint(for: preparation.output.bufferFrameSize)?
                    .unstableThroughTargetFrames,
                baselineTargetFrames: baselineTargetFrames
            ) else {
                return .blocked
            }

            preparation.runtime.retargetPlayback(primeFrames: targetFrames)
            preparation.runtime.recordPlaybackBufferRenegotiation()
            preparation.runtime.reprimePlayback()
            state.playbackBufferAdaptationEvidence.reset(
                instabilityGeneration: preparation.runtime.playbackInstabilitySnapshot().generation,
                timestampDiscontinuities: preparation.runtime.playbackTimestampDiscontinuityCount()
            )
            state.playbackBufferStableSince = nil
            probe = PlaybackBufferCalibrationProbe(
                outputUID: preparation.output.uid,
                sampleRate: preparation.output.nominalSampleRate,
                tapSampleRate: preparation.runtime.sampleRate,
                frameSize: preparation.output.bufferFrameSize,
                targetFrames: targetFrames,
                startedAt: ContinuousClock().now
            )
            state.playbackBufferCalibrationProbe = probe
            return .adjusted
        }
        if let probe {
            try? PersistedPlaybackBufferCalibrationStore.beginProbe(
                outputUID: probe.outputUID,
                sampleRate: probe.sampleRate,
                tapSampleRate: probe.tapSampleRate,
                frameSize: probe.frameSize,
                targetFrames: probe.targetFrames,
                at: playbackBufferCalibrationStoreURL
            )
        }
        return result
    }

    private func resumePlaybackBufferDecayAfterFailure(
        _ preparation: PlaybackBufferDecayPreparation
    ) {
        control.withLock { state in
            guard state.outputRebuildGeneration == preparation.outputRebuildGeneration,
                  state.runtime === preparation.runtime,
                  state.activeOutput == preparation.output else {
                return
            }
            state.playbackBufferStableSince = ContinuousClock().now
        }
    }

    private func failPlaybackBufferFrameSizeDecay(
        _ preparation: PlaybackBufferDecayPreparation,
        candidate: PlaybackBufferFrameSizeDecayCandidate
    ) {
        control.withLock { state in
            guard state.outputRebuildGeneration == preparation.outputRebuildGeneration,
                  state.runtime === preparation.runtime,
                  state.activeOutput == preparation.output else {
                return
            }
            state.failedPlaybackFrameSizeDecayCandidates.insert(candidate)
            state.playbackBufferStableSince = nil
            preparation.runtime.reprimePlayback()
        }
    }

    private func continueCalibrationAfterUnresolvedInstability(
        _ preparation: PlaybackBufferRenegotiationPreparation
    ) {
        let targetFrames = preparation.runtime.playbackTargetFrames()
        let instability = UnresolvedPlaybackBufferInstability(
            outputUID: preparation.output.uid,
            sampleRate: preparation.output.nominalSampleRate,
            tapSampleRate: preparation.runtime.sampleRate,
            frameSize: preparation.output.bufferFrameSize,
            targetFrames: targetFrames,
            reason: preparation.reason
        )
        let shouldPersist = control.withLock { state -> Bool? in
            guard state.outputRebuildGeneration == preparation.outputRebuildGeneration,
                  state.runtime === preparation.runtime,
                  state.activeOutput == preparation.output else {
                return nil
            }
            state.playbackBufferCalibrationProbe = PlaybackBufferCalibrationProbe(
                outputUID: preparation.output.uid,
                sampleRate: preparation.output.nominalSampleRate,
                tapSampleRate: preparation.runtime.sampleRate,
                frameSize: preparation.output.bufferFrameSize,
                targetFrames: targetFrames,
                startedAt: ContinuousClock().now
            )
            return state.playbackBufferInstabilityPersistenceGate.shouldPersist(instability)
        }
        guard shouldPersist == true else {
            return
        }
        do {
            try PersistedPlaybackBufferCalibrationStore.recordInstability(
                outputUID: preparation.output.uid,
                sampleRate: preparation.output.nominalSampleRate,
                tapSampleRate: preparation.runtime.sampleRate,
                previousFrameSize: preparation.output.bufferFrameSize,
                resultingFrameSize: preparation.output.bufferFrameSize,
                previousTargetFrames: targetFrames,
                resultingTargetFrames: targetFrames,
                reason: preparation.reason,
                at: playbackBufferCalibrationStoreURL
            )
        } catch {
            control.withLock { state in
                state.playbackBufferInstabilityPersistenceGate.persistenceFailed(for: instability)
            }
        }
    }

    private func recoverFailedPlaybackBufferRenegotiation(
        _ preparation: PlaybackBufferRenegotiationPreparation
    ) {
        control.withLock { state in
            guard state.outputRebuildGeneration == preparation.outputRebuildGeneration,
                  state.runtime === preparation.runtime,
                  state.activeOutput == preparation.output else {
                return
            }
            preparation.runtime.reprimePlayback()
        }
    }

    private func recoverAdaptivePlaybackRenderFailure(
        _ preparation: PlaybackBufferRenegotiationPreparation
    ) {
        let action = control.withLock { state -> AdaptivePlaybackRenderRecoveryAction? in
            guard state.outputRebuildGeneration == preparation.outputRebuildGeneration,
                  state.runtime === preparation.runtime,
                  state.activeOutput == preparation.output,
                  preparation.runtime.hasActiveAdaptivePlaybackRenderFailure(),
                  let profile = state.activeProfile else {
                return nil
            }
            if AdaptivePlaybackRenderRecoveryPolicy.shouldRestart(
                afterCompletedAttempts: state.adaptivePlaybackRenderRecoveryAttempts
            ) {
                state.adaptivePlaybackRenderRecoveryAttempts += 1
                state.adaptivePlaybackRenderRecoveryHealthGeneration = preparation.runtime
                    .playbackRenderHealthGeneration()
                return .restart(
                    output: preparation.output,
                    profile: profile,
                    expectation: OutputRebuildExpectation(
                        generation: state.outputRebuildGeneration,
                        runtime: preparation.runtime,
                        profileRevision: state.profileRevision
                    )
                )
            }

            let failure = AudioEngineFailure(
                category: .coreAudioOperationFailed,
                userMessage: "Adaptive playback rendering repeatedly failed, so GlassEQ stopped processing audio.",
                operation: "AdaptivePlaybackRender"
            )
            stopLocked(&state)
            state.state = .failed(failure.description)
            state.status = .failed(failure)
            return .fail(failure)
        }
        guard let action else {
            return
        }

        switch action {
        case .restart(let output, let profile, let expectation):
            do {
                try start(
                    output: output,
                    profile: profile,
                    expectation: expectation
                )
            } catch {
                let failure = control.withLock { state in
                    if case .failed(let failure) = state.status {
                        return failure
                    }
                    return audioEngineFailure(from: error)
                }
                runtimeFailureHandler.withLock { $0 }?(failure)
            }
        case .fail(let failure):
            updatePlaybackBufferAdaptationTimer()
            runtimeFailureHandler.withLock { $0 }?(failure)
        }
    }

    static func renegotiatedPlaybackOutput(
        _ output: AudioOutputDevice,
        supportedRange: AudioBufferFrameSizeRange,
        setBufferFrameSize: (UInt32, AudioObjectID) throws -> Void = CoreAudioDeviceQuery.setBufferFrameSize(_:objectID:),
        queryOutput: (AudioObjectID) throws -> AudioOutputDevice = CoreAudioDeviceQuery.outputDevice(id:),
        waitForPropertySettlement: () -> Void = { Thread.sleep(forTimeInterval: 0.01) }
    ) throws -> AudioOutputDevice? {
        guard let requestedFrameSize = AdaptivePlaybackBufferPolicy.nextFrameSize(
            after: output.bufferFrameSize,
            supportedRange: supportedRange
        ) else {
            return nil
        }

        try setBufferFrameSize(requestedFrameSize, output.id)
        for attempt in 0..<3 {
            let updatedOutput = try queryOutput(output.id)
            if updatedOutput.id == output.id,
               updatedOutput.bufferFrameSize > output.bufferFrameSize {
                return updatedOutput
            }
            if attempt < 2 {
                waitForPropertySettlement()
            }
        }
        return nil
    }

    static func decayedPlaybackOutput(
        _ output: AudioOutputDevice,
        supportedRange: AudioBufferFrameSizeRange,
        setBufferFrameSize: (UInt32, AudioObjectID) throws -> Void = CoreAudioDeviceQuery.setBufferFrameSize(_:objectID:),
        queryOutput: (AudioObjectID) throws -> AudioOutputDevice = CoreAudioDeviceQuery.outputDevice(id:),
        waitForPropertySettlement: () -> Void = { Thread.sleep(forTimeInterval: 0.01) }
    ) throws -> AudioOutputDevice? {
        guard let requestedFrameSize = AdaptivePlaybackBufferPolicy.previousFrameSize(
            before: output.bufferFrameSize,
            supportedRange: supportedRange
        ) else {
            return nil
        }

        try setBufferFrameSize(requestedFrameSize, output.id)
        for attempt in 0..<3 {
            let updatedOutput = try queryOutput(output.id)
            if updatedOutput.id == output.id,
               updatedOutput.bufferFrameSize < output.bufferFrameSize {
                return updatedOutput
            }
            if attempt < 2 {
                waitForPropertySettlement()
            }
        }
        return nil
    }

    static func preferredBufferFrameSize(for output: AudioOutputDevice) -> UInt32 {
        if isLowSampleRateRoute(output) {
            return Self.preferredLowSampleRateBufferFrameSize
        }
        if output.isBluetoothTransport {
            return Self.preferredBluetoothBufferFrameSize
        }
        // Low-latency: request a small output buffer rather than keeping the device's larger
        // default. Clamped to the device's supported range by the caller (tuneBufferFrameSize).
        return Self.preferredBufferFrameSize
    }

    static func preferredPlaybackPrimeFrames(
        for output: AudioOutputDevice,
        tapSampleRate: Double? = nil,
        captureCallbackFrames: Int = preferredLowSampleRatePlaybackReservoirFrames
    ) -> Int {
        let outputCallbackFrames = max(Int(output.bufferFrameSize), 1)
        let sampleRatePlan = PlaybackSampleRatePlan(
            inputSampleRate: tapSampleRate ?? output.nominalSampleRate,
            outputSampleRate: output.nominalSampleRate
        )
        if sampleRatePlan.requiresConversion {
            let hasLowRateEndpoint = hasLowSampleRateEndpoint(
                tapSampleRate: sampleRatePlan.inputSampleRate,
                output: output
            )
            let minimumReservoirFrames = hasLowRateEndpoint
                ? Self.preferredLowSampleRatePlaybackReservoirFrames
                : Int(Self.preferredCaptureBufferFrameSize)
            let reservoirFrames = min(
                max(captureCallbackFrames, minimumReservoirFrames),
                Self.maximumSupportedCallbackFrames
            )
            let referenceOutputFrames = hasLowRateEndpoint
                ? Int(Self.preferredLowSampleRateBufferFrameSize)
                : outputCallbackFrames
            return max(
                sampleRatePlan.inputFrames(forOutputFrames: referenceOutputFrames),
                sampleRatePlan.inputFrames(forOutputFrames: outputCallbackFrames)
                    + reservoirFrames
            )
        }
        if output.isBluetoothTransport {
            return max(
                Self.preferredBluetoothPlaybackTargetFrames,
                outputCallbackFrames + Self.preferredBluetoothPlaybackReservoirFrames
            )
        }
        return max(
            Self.preferredPlaybackPrimeFrames,
            outputCallbackFrames + Int(Self.preferredCaptureBufferFrameSize)
        )
    }

    static func shouldAdaptPlaybackBuffer(for output: AudioOutputDevice) -> Bool {
        output.nominalSampleRate > 0
    }

    static func playbackInputCallbackFrames(
        for output: AudioOutputDevice,
        tapSampleRate: Double
    ) -> UInt32 {
        UInt32(clamping: PlaybackSampleRatePlan(
            inputSampleRate: tapSampleRate,
            outputSampleRate: output.nominalSampleRate
        ).inputFrames(forOutputFrames: Int(output.bufferFrameSize)))
    }

    static func startupCaptureCallbackFrames(reportedFrames: UInt32?) -> Int {
        guard let reportedFrames,
              reportedFrames > 0,
              reportedFrames <= UInt32(maximumSupportedCallbackFrames) else {
            return maximumSupportedCallbackFrames
        }
        return Int(reportedFrames)
    }

    static func shouldUseSampleRateConversion(
        tapSampleRate: Double,
        output: AudioOutputDevice,
        preservingOutputSampleRate: Bool = false
    ) -> Bool {
        abs(tapSampleRate - output.nominalSampleRate) >= 1
            && (preservingOutputSampleRate
                || hasLowSampleRateEndpoint(tapSampleRate: tapSampleRate, output: output))
    }

    static func effectiveOutputRebuildProfile(
        preparedProfile: EQProfile,
        preparedProfileRevision: UInt64,
        activeProfile: EQProfile?,
        activeProfileRevision: UInt64
    ) -> EQProfile {
        guard activeProfileRevision != preparedProfileRevision,
              let activeProfile else {
            return preparedProfile
        }
        return activeProfile
    }

    static func requestedOutputRebuildProfile(
        requestedProfile: EQProfile,
        expectedProfileRevision: UInt64?,
        activeProfile: EQProfile?,
        activeProfileRevision: UInt64
    ) -> EQProfile? {
        guard let expectedProfileRevision,
              activeProfileRevision != expectedProfileRevision else {
            return requestedProfile
        }
        return activeProfile
    }

    static func profileUpdateOutput(_ output: AudioOutputDevice?) throws -> AudioOutputDevice {
        guard let output else {
            throw AudioEngineProfileUpdateUnavailable()
        }
        return output
    }

    static func shouldRefreshCaptureForOutput(
        tapSampleRate: Double,
        output: AudioOutputDevice
    ) -> Bool {
        !isLowSampleRateRoute(output)
            && abs(tapSampleRate - output.nominalSampleRate) >= 1
    }

    static func maximumPlaybackReservoirFrames(
        for output: AudioOutputDevice,
        tapSampleRate: Double,
        maximumKnownCaptureCallbackFrames: Int
    ) -> Int {
        guard hasLowSampleRateEndpoint(tapSampleRate: tapSampleRate, output: output) else {
            return AdaptivePlaybackBufferPolicy.maximumReservoirFrames
        }
        return max(
            Self.preferredLowSampleRatePlaybackReservoirFrames,
            maximumKnownCaptureCallbackFrames
        )
    }

    private static func isLowSampleRateRoute(_ output: AudioOutputDevice) -> Bool {
        isLowSampleRate(output.nominalSampleRate)
    }

    private static func isLowSampleRate(_ sampleRate: Double) -> Bool {
        sampleRate > 0 && sampleRate <= Self.lowSampleRateThreshold
    }

    private static func hasLowSampleRateEndpoint(
        tapSampleRate: Double,
        output: AudioOutputDevice
    ) -> Bool {
        isLowSampleRate(tapSampleRate) || isLowSampleRateRoute(output)
    }

    private func createTopologyRebuildMuteGuard() throws -> any TopologyRebuildMuteGuarding {
        let tapID = try createSystemTap(name: "GlassEQ Profile Rebuild Mute Tap")
        var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        var ioProcID: AudioDeviceIOProcID?

        do {
            aggregateDeviceID = try createPrivateAggregateDevice(tapID: tapID)
            ioProcID = try createSilenceIOProc(deviceID: aggregateDeviceID)
            try checkOSStatus(
                AudioDeviceStart(aggregateDeviceID, ioProcID),
                operation: "AudioDeviceStart(profile rebuild mute tap)"
            )
            return CoreAudioTopologyRebuildMuteGuard(
                tapID: tapID,
                aggregateDeviceID: aggregateDeviceID,
                ioProcID: ioProcID,
                cleanupLedger: cleanupLedger
            )
        } catch {
            var resources = CoreAudioResourceCleanupLedger.PendingResources(
                operation: "discard failed topology rebuild mute guard"
            )
            if aggregateDeviceID != kAudioObjectUnknown, let ioProcID {
                resources.ioProcs.append(.init(
                    deviceID: aggregateDeviceID,
                    ioProcID: ioProcID
                ))
            }
            if aggregateDeviceID != kAudioObjectUnknown {
                resources.aggregateDeviceIDs.append(aggregateDeviceID)
            }
            if tapID != kAudioObjectUnknown {
                resources.tapIDs.append(tapID)
            }
            if !resources.ioProcs.isEmpty
                || !resources.aggregateDeviceIDs.isEmpty
                || !resources.tapIDs.isEmpty {
                cleanupLedger.dispose(resources)
            }
            throw error
        }
    }

    private func disposeOutputIOProc(
        deviceID: AudioObjectID,
        ioProcID: AudioDeviceIOProcID,
        operation: String
    ) {
        let resources = CoreAudioResourceCleanupLedger.PendingResources(
            operation: operation,
            ioProcs: [.init(deviceID: deviceID, ioProcID: ioProcID)]
        )
        if !cleanupLedger.dispose(resources) {
            traceDiagnostic {
                "Core Audio cleanup deferred operation=\(operation) pending=\(cleanupLedger.pendingCount)"
            }
        }
    }

    private func requireCompletedCoreAudioCleanup(operation: String) throws {
        for attempt in 0..<3 {
            if cleanupLedger.retryPending() {
                return
            }
            if attempt < 2 {
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        traceDiagnostic {
            "Core Audio cleanup still pending before \(operation) count=\(cleanupLedger.pendingCount)"
        }
        throw CoreAudioError(
            operation: "Complete prior Core Audio cleanup before \(operation)",
            status: kAudioHardwareUnspecifiedError
        )
    }

    private func retryCoreAudioCleanup() {
        do {
            try requireCompletedCoreAudioCleanup(operation: "finish stopping compatibility audio")
        } catch {
            traceDiagnostic { "Core Audio cleanup remains owned for retry error=\(error)" }
        }
    }

    private func createSystemTap(name: String = "GlassEQ System Output Tap") throws -> AudioObjectID {
        let ownProcess = try currentAudioProcessObjectID()
        // Global tap (not bound to a device): once its IOProc starts reading, one tap removes
        // the dry system mix from every output device and survives default-output switches.
        // This prevents dry audio from leaking during handoff without muting active clients
        // while the replacement output path is still being constructed.
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [ownProcess])
        description.name = name
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = CATapMuteBehavior.mutedWhenTapped

        var tapID = AudioObjectID(kAudioObjectUnknown)
        traceDiagnostic { "AudioHardwareCreateProcessTap(compatibility) begin" }
        let status = AudioHardwareCreateProcessTap(description, &tapID)
        traceDiagnostic {
            "AudioHardwareCreateProcessTap(compatibility) return status=\(status) tap=\(tapID)"
        }
        try checkOSStatus(status, operation: "AudioHardwareCreateProcessTap")
        return tapID
    }

    private func tapStreamFormat(_ tapID: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try checkOSStatus(
            AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &asbd),
            operation: "AudioObjectGetPropertyData(tap format)"
        )
        try CoreAudioDeviceQuery.validatePropertySize(
            actual: size,
            expected: UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
            operation: "AudioObjectGetPropertyData(tap format)",
            objectID: tapID
        )
        return asbd
    }

    private func createPrivateAggregateDevice(tapID: AudioObjectID) throws -> AudioObjectID {
        let tapUID = try tapUID(tapID)
        let aggregateUID = "com.glasseq.aggregate.\(UUID().uuidString)"
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "GlassEQ Private Tap Device",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUID
                ]
            ]
        ]

        var deviceID = AudioObjectID(kAudioObjectUnknown)
        traceDiagnostic { "AudioHardwareCreateAggregateDevice(compatibility capture) begin" }
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &deviceID)
        traceDiagnostic {
            "AudioHardwareCreateAggregateDevice(compatibility capture) return status=\(status) device=\(deviceID)"
        }
        try checkOSStatus(status, operation: "AudioHardwareCreateAggregateDevice")
        return deviceID
    }

    private func createCaptureIOProc(deviceID: AudioObjectID, runtime: AudioRuntime) throws -> AudioDeviceIOProcID? {
        var ioProcID: AudioDeviceIOProcID?

        traceDiagnostic {
            "AudioDeviceCreateIOProcIDWithBlock(compatibility capture) begin device=\(deviceID)"
        }
        let status = AudioDeviceCreateIOProcIDWithBlock(
            &ioProcID,
            deviceID,
            nil
        ) { _, inputData, _, outputData, _ in
            runtime.capture(inputData: inputData)
            runtime.clear(outputData: outputData)
        }
        traceDiagnostic {
            "AudioDeviceCreateIOProcIDWithBlock(compatibility capture) return status=\(status) device=\(deviceID)"
        }
        try checkOSStatus(status, operation: "AudioDeviceCreateIOProcIDWithBlock(capture)")

        return ioProcID
    }

    private func createSilenceIOProc(deviceID: AudioObjectID) throws -> AudioDeviceIOProcID? {
        var ioProcID: AudioDeviceIOProcID?

        try checkOSStatus(
            AudioDeviceCreateIOProcIDWithBlock(&ioProcID, deviceID, nil) { _, _, _, outputData, _ in
                Self.clear(outputData: outputData)
            },
            operation: "AudioDeviceCreateIOProcIDWithBlock(profile rebuild mute tap)"
        )

        return ioProcID
    }

    private func createOutputIOProc(deviceID: AudioObjectID, runtime: AudioRuntime) throws -> AudioDeviceIOProcID? {
        var ioProcID: AudioDeviceIOProcID?

        traceDiagnostic {
            "AudioDeviceCreateIOProcIDWithBlock(physical output) begin device=\(deviceID)"
        }
        let status = AudioDeviceCreateIOProcIDWithBlock(
            &ioProcID,
            deviceID,
            nil
        ) { _, _, _, outputData, outputTime in
            let outputTimestamp = outputTime.pointee
            let sampleTime: Double? = if outputTimestamp.mFlags.contains(.sampleTimeValid) {
                outputTimestamp.mSampleTime
            } else {
                nil
            }
            runtime.playback(outputData: outputData, outputSampleTime: sampleTime)
        }
        traceDiagnostic {
            "AudioDeviceCreateIOProcIDWithBlock(physical output) return status=\(status) device=\(deviceID)"
        }
        try checkOSStatus(status, operation: "AudioDeviceCreateIOProcIDWithBlock(output)")

        return ioProcID
    }

    private static func clear(outputData: UnsafeMutablePointer<AudioBufferList>) {
        for buffer in UnsafeMutableAudioBufferListPointer(outputData) {
            guard let data = buffer.mData else {
                continue
            }
            let byteCount = Int(buffer.mDataByteSize)
            let maxByteCount = Int(CoreAudioDeviceQuery.maxBufferFrameSize)
                * CoreAudioDeviceQuery.maxChannelCount
                * MemoryLayout<Float>.stride
            guard byteCount >= 0,
                  byteCount <= maxByteCount else {
                continue
            }
            data.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
        }
    }

    private func tapUID(_ tapID: AudioObjectID) throws -> String {
        try CoreAudioDeviceQuery.getStringProperty(
            objectID: tapID,
            selector: kAudioTapPropertyUID,
            scope: kAudioObjectPropertyScopeGlobal
        )
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
        let qualifierSize = UInt32(MemoryLayout<pid_t>.size)

        try checkOSStatus(
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                qualifierSize,
                &pid,
                &size,
                &processID
            ),
            operation: "AudioObjectGetPropertyData(translate pid)"
        )

        guard processID != kAudioObjectUnknown else {
            throw AudioDeviceAvailabilityError.invalidDeviceMetadata(
                AudioObjectID(kAudioObjectSystemObject),
                "current audio process object is unknown"
            )
        }
        return processID
    }
}
