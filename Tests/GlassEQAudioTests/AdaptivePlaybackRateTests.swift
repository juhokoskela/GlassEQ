import AudioToolbox
import Foundation
@testable import GlassEQAudio
import Testing

private final class ConverterTestSource {
    let samples: UnsafeMutableBufferPointer<Float>
    let channelCount: Int
    var frameOffset = 0

    init(sampleRate: Double, frequency: Double, frameCount: Int, channelCount: Int = 2) {
        self.channelCount = channelCount
        self.samples = UnsafeMutableBufferPointer<Float>.allocate(
            capacity: frameCount * channelCount
        )
        for frame in 0..<frameCount {
            let sample = Float(sin(2 * Double.pi * frequency * Double(frame) / sampleRate))
            for channel in 0..<channelCount {
                samples[frame * channelCount + channel] = sample
            }
        }
    }

    deinit {
        samples.deallocate()
    }

    func provide(
        requestedFrames: UnsafeMutablePointer<UInt32>,
        inputData: UnsafeMutablePointer<AudioBufferList>
    ) -> OSStatus {
        let requestedFrameCount = Int(requestedFrames.pointee)
        let availableFrameCount = samples.count / channelCount - frameOffset
        let frameCount = min(requestedFrameCount, availableFrameCount)
        guard frameCount > 0, let baseAddress = samples.baseAddress else {
            requestedFrames.pointee = 0
            return noErr
        }

        requestedFrames.pointee = UInt32(frameCount)
        inputData.pointee = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: UInt32(channelCount),
                mDataByteSize: UInt32(frameCount * channelCount * MemoryLayout<Float>.size),
                mData: baseAddress.advanced(by: frameOffset * channelCount)
            )
        )
        frameOffset += frameCount
        return noErr
    }
}

private let converterTestInputProc: AudioConverterComplexInputDataProcRealtimeSafe = {
    _, requestedFrames, inputData, packetDescriptions, context in
    guard let context else {
        requestedFrames.pointee = 0
        return kAudioConverterErr_UnspecifiedError
    }
    packetDescriptions?.pointee = nil
    return Unmanaged<ConverterTestSource>
        .fromOpaque(context)
        .takeUnretainedValue()
        .provide(requestedFrames: requestedFrames, inputData: inputData)
}

@Suite
struct AdaptivePlaybackRateTests {
    @Test
    func sampleRatePlanMapsOutputCallbacksIntoTapFrameTime() {
        let direct = PlaybackSampleRatePlan(inputSampleRate: 48_000, outputSampleRate: 48_000)
        let headset = PlaybackSampleRatePlan(inputSampleRate: 48_000, outputSampleRate: 24_000)

        #expect(!direct.requiresConversion)
        #expect(direct.inputFrames(forOutputFrames: 512) == 512)
        #expect(headset.requiresConversion)
        #expect(headset.inputFrames(forOutputFrames: 512) == 1_024)
        #expect(headset.inputFrames(forOutputFrames: 513) == 1_026)
    }

    @Test
    func realtimePCMRateConverterPassesSpeechBandAndRejectsAliasingBand() throws {
        let passbandRMS = try convertedRMS(frequency: 1_000)
        let stopbandRMS = try convertedRMS(frequency: 18_000)

        #expect(passbandRMS > 0.6)
        #expect(stopbandRMS < 0.02)
    }

    @Test
    func realtimePCMRateConverterDisablesPriming() throws {
        let converter = try RealtimePCMRateConverter(
            inputSampleRate: 48_000,
            outputSampleRate: 24_000,
            channelCount: 2
        )

        let primeMethod = try converter.configuredPrimeMethod()
        #expect(primeMethod == UInt32(kConverterPrimeMethod_None))
    }

    @Test
    func realtimePCMRateConverterDerivesItsMaximumInputPull() throws {
        let converter = try RealtimePCMRateConverter(
            inputSampleRate: 48_000,
            outputSampleRate: 24_000,
            channelCount: 2
        )

        let inputFrames = try converter.inputFrameCapacity(forOutputFrames: 8_192)
        #expect(inputFrames >= 16_384)
        #expect(inputFrames < SystemTapAudioEngine.runtimeRingCapacityFrames)
    }

    private func convertedRMS(frequency: Double) throws -> Double {
        let channelCount = 2
        let outputFrameCount = 4_096
        let source = ConverterTestSource(
            sampleRate: 48_000,
            frequency: frequency,
            frameCount: 32_768,
            channelCount: channelCount
        )
        let converter = try RealtimePCMRateConverter(
            inputSampleRate: 48_000,
            outputSampleRate: 24_000,
            channelCount: channelCount
        )
        var output = Array(repeating: Float.zero, count: outputFrameCount * channelCount)
        var convertedFrameCount = UInt32(outputFrameCount)
        let status = output.withUnsafeMutableBufferPointer { outputSamples in
            var outputData = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: UInt32(channelCount),
                    mDataByteSize: UInt32(outputSamples.count * MemoryLayout<Float>.size),
                    mData: outputSamples.baseAddress
                )
            )
            return withUnsafeMutablePointer(to: &outputData) { outputData in
                converter.fill(
                    inputProc: converterTestInputProc,
                    inputContext: Unmanaged.passUnretained(source).toOpaque(),
                    outputFrames: &convertedFrameCount,
                    outputData: outputData
                )
            }
        }
        try checkOSStatus(status, operation: "test realtime sample-rate conversion")
        #expect(convertedFrameCount == outputFrameCount)

        let settledSamples = output.dropFirst(1_024 * channelCount)
        let meanSquare = settledSamples.reduce(0.0) { partial, sample in
            partial + Double(sample * sample)
        } / Double(settledSamples.count)
        return sqrt(meanSquare)
    }

    @Test
    func legacyLearnedPlaybackBufferSizesMigrateByDeviceAndSampleRate() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlassEQPlaybackBufferCalibration-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("LearnedPlaybackBuffers.json")
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let legacyJSON = """
        [
          {"outputUID":"output-a","sampleRate":48000,"frameSize":256},
          {"outputUID":"output-a","sampleRate":48000,"frameSize":128},
          {"outputUID":"output-a","sampleRate":44100,"frameSize":128}
        ]
        """
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try #require(legacyJSON.data(using: .utf8)).write(to: url)

        #expect(PersistedPlaybackBufferCalibrationStore.preferredFrameSize(
            outputUID: "output-a",
            sampleRate: 48_000,
            from: url
        ) == 256)
        #expect(PersistedPlaybackBufferCalibrationStore.preferredFrameSize(
            outputUID: "output-a",
            sampleRate: 44_100,
            from: url
        ) == 128)
        #expect(PersistedPlaybackBufferCalibrationStore.preferredFrameSize(
            outputUID: "output-b",
            sampleRate: 48_000,
            from: url
        ) == nil)

        try PersistedPlaybackBufferCalibrationStore.recordStable(
            outputUID: "output-b",
            sampleRate: 48_000,
            frameSize: 64,
            targetFrames: 128,
            at: url
        )
        #expect(PersistedPlaybackBufferCalibrationStore.preferredFrameSize(
            outputUID: "output-a",
            sampleRate: 48_000,
            from: url
        ) == 256)
        #expect(PersistedPlaybackBufferCalibrationStore.preferredFrameSize(
            outputUID: "output-b",
            sampleRate: 48_000,
            from: url
        ) == 64)
    }

    @Test
    func callbackOnlyCalibrationDocumentsAcquireServoTargetsWithoutResetting() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlassEQPlaybackBufferCalibration-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("LearnedPlaybackBuffers.json")
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let callbackOnlyJSON = """
        {
          "schemaVersion": 1,
          "calibrations": [
            {
              "outputUID": "scarlett",
              "sampleRate": 48000,
              "stableFrameSize": 128,
              "events": [
                {
                  "kind": "stabilized",
                  "timestamp": "2026-08-18T07:45:14Z",
                  "resultingFrameSize": 128
                }
              ]
            }
          ]
        }
        """
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try #require(callbackOnlyJSON.data(using: .utf8)).write(to: url)

        let calibration = try #require(PersistedPlaybackBufferCalibrationStore.calibration(
            outputUID: "scarlett",
            sampleRate: 48_000,
            from: url
        ))
        #expect(calibration.stableFrameSize == 128)
        #expect(calibration.operatingPoint(for: 128) == nil)
        #expect(calibration.events.first?.resultingTargetFrames == nil)
        #expect(PlaybackBufferCalibrationPolicy.shouldProbe(
            frameSize: 128,
            targetFrames: 256,
            calibration: calibration
        ))
    }

    @Test
    func scalarServoTargetsMigrateIntoTheirCallbackOperatingPoint() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlassEQPlaybackBufferCalibration-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("LearnedPlaybackBuffers.json")
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let scalarTargetJSON = """
        {
          "schemaVersion": 1,
          "calibrations": [
            {
              "outputUID": "scarlett",
              "sampleRate": 48000,
              "stableFrameSize": 128,
              "stableTargetFrames": 256,
              "events": []
            }
          ]
        }
        """
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try #require(scalarTargetJSON.data(using: .utf8)).write(to: url)

        let calibration = try #require(PersistedPlaybackBufferCalibrationStore.calibration(
            outputUID: "scarlett",
            sampleRate: 48_000,
            from: url
        ))
        #expect(calibration.stableFrameSize == 128)
        #expect(calibration.operatingPoint(for: 128)?.stableTargetFrames == 256)
        #expect(calibration.preferredTargetFrames(for: 64) == nil)
    }

    @Test
    func schemaTwoCalibrationIsDiscardedBeforeRecordingFreshEvidence() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlassEQPlaybackBufferCalibration-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("LearnedPlaybackBuffers.json")
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let contaminatedJSON = """
        {
          "schemaVersion": 2,
          "calibrations": [
            {
              "outputUID": "scarlett",
              "sampleRate": 48000,
              "stableFrameSize": 512,
              "operatingPoints": [
                {
                  "frameSize": 512,
                  "stableTargetFrames": 704
                }
              ],
              "events": []
            }
          ]
        }
        """
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try #require(contaminatedJSON.data(using: .utf8)).write(to: url)

        #expect(PersistedPlaybackBufferCalibrationStore.calibration(
            outputUID: "scarlett",
            sampleRate: 48_000,
            from: url
        ) == nil)

        try PersistedPlaybackBufferCalibrationStore.recordStable(
            outputUID: "scarlett",
            sampleRate: 48_000,
            frameSize: 64,
            targetFrames: 128,
            at: url
        )
        let calibration = try #require(PersistedPlaybackBufferCalibrationStore.calibration(
            outputUID: "scarlett",
            sampleRate: 48_000,
            from: url
        ))
        #expect(calibration.stableFrameSize == 64)
        #expect(calibration.operatingPoint(for: 64)?.stableTargetFrames == 128)
        #expect(calibration.operatingPoint(for: 512) == nil)
    }

    @Test
    func resettingPlaybackBufferCalibrationRemovesOnlyTheSelectedDevice() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlassEQPlaybackBufferCalibration-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("LearnedPlaybackBuffers.json")
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        try PersistedPlaybackBufferCalibrationStore.recordStable(
            outputUID: "scarlett",
            sampleRate: 48_000,
            frameSize: 1_024,
            targetFrames: 2_048,
            at: url
        )
        try PersistedPlaybackBufferCalibrationStore.recordStable(
            outputUID: "scarlett",
            sampleRate: 44_100,
            frameSize: 512,
            targetFrames: 1_024,
            at: url
        )
        try PersistedPlaybackBufferCalibrationStore.recordStable(
            outputUID: "airpods",
            sampleRate: 48_000,
            frameSize: 128,
            targetFrames: 256,
            at: url
        )

        try PersistedPlaybackBufferCalibrationStore.removeCalibrations(
            outputUID: "scarlett",
            at: url
        )

        #expect(PersistedPlaybackBufferCalibrationStore.calibration(
            outputUID: "scarlett",
            sampleRate: 48_000,
            from: url
        ) == nil)
        #expect(PersistedPlaybackBufferCalibrationStore.calibration(
            outputUID: "scarlett",
            sampleRate: 44_100,
            from: url
        ) == nil)
        #expect(PersistedPlaybackBufferCalibrationStore.preferredFrameSize(
            outputUID: "airpods",
            sampleRate: 48_000,
            from: url
        ) == 128)
    }

    @Test
    func playbackBufferCalibrationPersistsProbeFailureAndStableResult() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlassEQPlaybackBufferCalibration-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("LearnedPlaybackBuffers.json")
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        try PersistedPlaybackBufferCalibrationStore.beginProbe(
            outputUID: "airpods",
            sampleRate: 48_000,
            frameSize: 64,
            targetFrames: 128,
            at: url
        )
        var calibration = try #require(PersistedPlaybackBufferCalibrationStore.calibration(
            outputUID: "airpods",
            sampleRate: 48_000,
            from: url
        ))
        #expect(calibration.stableFrameSize == nil)
        #expect(calibration.probingFrameSize == 64)
        #expect(calibration.operatingPoint(for: 64)?.probingTargetFrames == 128)
        #expect(calibration.events.isEmpty)

        try PersistedPlaybackBufferCalibrationStore.recordStable(
            outputUID: "airpods",
            sampleRate: 48_000,
            frameSize: 64,
            targetFrames: 128,
            timestamp: Date(timeIntervalSince1970: 1),
            at: url
        )
        calibration = try #require(PersistedPlaybackBufferCalibrationStore.calibration(
            outputUID: "airpods",
            sampleRate: 48_000,
            from: url
        ))
        #expect(calibration.stableFrameSize == 64)
        #expect(calibration.probingFrameSize == nil)
        #expect(calibration.operatingPoint(for: 64)?.stableTargetFrames == 128)
        #expect(calibration.operatingPoint(for: 64)?.probingTargetFrames == nil)
        #expect(calibration.events.map(\.kind) == [.stabilized])

        try PersistedPlaybackBufferCalibrationStore.recordInstability(
            outputUID: "airpods",
            sampleRate: 48_000,
            previousFrameSize: 64,
            resultingFrameSize: 128,
            previousTargetFrames: 128,
            resultingTargetFrames: 256,
            reason: .underrun,
            timestamp: Date(timeIntervalSince1970: 2),
            at: url
        )
        calibration = try #require(PersistedPlaybackBufferCalibrationStore.calibration(
            outputUID: "airpods",
            sampleRate: 48_000,
            from: url
        ))
        #expect(calibration.stableFrameSize == nil)
        #expect(calibration.probingFrameSize == 128)
        #expect(calibration.operatingPoint(for: 64)?.stableTargetFrames == nil)
        #expect(calibration.operatingPoint(for: 64)?.unstableThroughTargetFrames == 128)
        #expect(calibration.operatingPoint(for: 128)?.probingTargetFrames == 256)
        #expect(calibration.events.last?.kind == .instability)
        #expect(calibration.events.last?.reason == .underrun)
        #expect(calibration.events.last?.previousFrameSize == 64)
        #expect(calibration.events.last?.resultingFrameSize == 128)
        #expect(calibration.events.last?.previousTargetFrames == 128)
        #expect(calibration.events.last?.resultingTargetFrames == 256)

        try PersistedPlaybackBufferCalibrationStore.recordStable(
            outputUID: "airpods",
            sampleRate: 48_000,
            frameSize: 128,
            targetFrames: 256,
            timestamp: Date(timeIntervalSince1970: 3),
            at: url
        )
        calibration = try #require(PersistedPlaybackBufferCalibrationStore.calibration(
            outputUID: "airpods",
            sampleRate: 48_000,
            from: url
        ))
        #expect(calibration.stableFrameSize == 128)
        #expect(calibration.probingFrameSize == nil)
        #expect(calibration.operatingPoint(for: 128)?.stableTargetFrames == 256)
        #expect(calibration.preferredFrameSize == 128)
        #expect(calibration.preferredTargetFrames(for: 128) == 256)
    }

    @Test
    func playbackBufferCalibrationKeepsBoundedPerRouteEventHistory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlassEQPlaybackBufferCalibration-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("LearnedPlaybackBuffers.json")
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        for index in 0..<(PlaybackBufferCalibrationPolicy.maximumEventCount + 4) {
            try PersistedPlaybackBufferCalibrationStore.recordStable(
                outputUID: "output-a",
                sampleRate: 48_000,
                frameSize: 64,
                targetFrames: 128,
                timestamp: Date(timeIntervalSince1970: Double(index)),
                at: url
            )
        }
        try PersistedPlaybackBufferCalibrationStore.recordStable(
            outputUID: "output-b",
            sampleRate: 44_100,
            frameSize: 64,
            targetFrames: 128,
            at: url
        )

        let routeA = try #require(PersistedPlaybackBufferCalibrationStore.calibration(
            outputUID: "output-a",
            sampleRate: 48_000,
            from: url
        ))
        let routeB = try #require(PersistedPlaybackBufferCalibrationStore.calibration(
            outputUID: "output-b",
            sampleRate: 44_100,
            from: url
        ))
        #expect(routeA.events.count == PlaybackBufferCalibrationPolicy.maximumEventCount)
        #expect(routeA.events.first?.timestamp == Date(timeIntervalSince1970: 4))
        #expect(routeB.stableFrameSize == 64)
        #expect(PersistedPlaybackBufferCalibrationStore.calibration(
            outputUID: "output-a",
            sampleRate: 44_100,
            from: url
        ) == nil)
    }

    @Test
    func repeatedUnresolvedInstabilityDoesNotRewriteUnchangedCalibration() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlassEQPlaybackBufferCalibration-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("LearnedPlaybackBuffers.json")
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        try PersistedPlaybackBufferCalibrationStore.recordInstability(
            outputUID: "output-a",
            sampleRate: 48_000,
            previousFrameSize: 512,
            resultingFrameSize: 512,
            previousTargetFrames: 704,
            resultingTargetFrames: 704,
            reason: .underrun,
            timestamp: Date(timeIntervalSince1970: 1),
            at: url
        )
        let firstWrite = try Data(contentsOf: url)

        try PersistedPlaybackBufferCalibrationStore.recordInstability(
            outputUID: "output-a",
            sampleRate: 48_000,
            previousFrameSize: 512,
            resultingFrameSize: 512,
            previousTargetFrames: 704,
            resultingTargetFrames: 704,
            reason: .underrun,
            timestamp: Date(timeIntervalSince1970: 2),
            at: url
        )

        #expect(try Data(contentsOf: url) == firstWrite)
        let calibration = try #require(PersistedPlaybackBufferCalibrationStore.calibration(
            outputUID: "output-a",
            sampleRate: 48_000,
            from: url
        ))
        #expect(calibration.events.count == 1)
        #expect(calibration.events.first?.timestamp == Date(timeIntervalSince1970: 1))
    }

    @Test
    func adaptiveRenderFailureDoesNotInvalidateStableBufferCalibration() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlassEQPlaybackBufferCalibration-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("LearnedPlaybackBuffers.json")
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        try PersistedPlaybackBufferCalibrationStore.recordStable(
            outputUID: "output-a",
            sampleRate: 48_000,
            frameSize: 64,
            targetFrames: 128,
            timestamp: Date(timeIntervalSince1970: 1),
            at: url
        )
        let stableWrite = try Data(contentsOf: url)

        try PersistedPlaybackBufferCalibrationStore.recordInstability(
            outputUID: "output-a",
            sampleRate: 48_000,
            previousFrameSize: 64,
            resultingFrameSize: 64,
            previousTargetFrames: 128,
            resultingTargetFrames: 128,
            reason: .adaptiveRenderFailure,
            timestamp: Date(timeIntervalSince1970: 2),
            at: url
        )

        #expect(try Data(contentsOf: url) == stableWrite)
        let calibration = try #require(PersistedPlaybackBufferCalibrationStore.calibration(
            outputUID: "output-a",
            sampleRate: 48_000,
            from: url
        ))
        #expect(calibration.stableFrameSize == 64)
        #expect(calibration.operatingPoint(for: 64)?.stableTargetFrames == 128)
        #expect(calibration.events.map(\.kind) == [.stabilized])
    }

    @Test
    func playbackBufferProbeRequiresFullProbation() {
        let start = ContinuousClock().now
        let probe = PlaybackBufferCalibrationProbe(
            outputUID: "output-a",
            sampleRate: 48_000,
            frameSize: 64,
            targetFrames: 128,
            startedAt: start
        )

        #expect(!probe.hasCompletedProbation(at: start.advanced(by: .seconds(59))))
        #expect(probe.hasCompletedProbation(at: start.advanced(by: .seconds(60))))
    }

    @Test
    func underrunEvidenceRequiresThreeEpisodesWithinTwoSeconds() {
        let start = ContinuousClock().now
        var evidence = PlaybackBufferUnderrunEvidence()

        let first = evidence.record(eventCount: 1, at: start)
        let second = evidence.record(eventCount: 1, at: start.advanced(by: .seconds(1)))
        let third = evidence.record(eventCount: 1, at: start.advanced(by: .seconds(2)))
        let afterReset = evidence.record(eventCount: 1, at: start.advanced(by: .seconds(2)))
        #expect(!first)
        #expect(!second)
        #expect(third)
        #expect(!afterReset)
    }

    @Test
    func underrunEvidenceExpiresAndAcceptsControllerGenerationDeltas() {
        let start = ContinuousClock().now
        var evidence = PlaybackBufferUnderrunEvidence()

        let first = evidence.record(eventCount: 1, at: start)
        let afterExpiry = evidence.record(
            eventCount: 1,
            at: start.advanced(by: .seconds(2) + .milliseconds(1))
        )
        evidence.reset()
        let batched = evidence.record(eventCount: 3, at: start.advanced(by: .seconds(3)))
        #expect(!first)
        #expect(!afterExpiry)
        #expect(batched)
    }

    @Test
    func adaptationEvidenceRequiresThreeUnderrunEpisodesBeforeEscalating() {
        let start = ContinuousClock().now
        var evidence = PlaybackBufferAdaptationEvidence()
        evidence.reset(instabilityGeneration: 0, timestampDiscontinuities: 0)

        let first = evidence.observe(
            instabilityGeneration: 1,
            reason: .underrun,
            timestampDiscontinuities: 0,
            at: start
        )
        let second = evidence.observe(
            instabilityGeneration: 2,
            reason: .underrun,
            timestampDiscontinuities: 0,
            at: start.advanced(by: .seconds(1))
        )
        let third = evidence.observe(
            instabilityGeneration: 3,
            reason: .underrun,
            timestampDiscontinuities: 0,
            at: start.advanced(by: .seconds(2))
        )

        #expect(first.observedDisturbance)
        #expect(first.escalationReason == nil)
        #expect(second.observedDisturbance)
        #expect(second.escalationReason == nil)
        #expect(third.escalationReason == .underrun)
    }

    @Test
    func adaptationEvidenceTreatsTimestampChangesAsDisturbancesWithoutEscalating() {
        let start = ContinuousClock().now
        var evidence = PlaybackBufferAdaptationEvidence()
        evidence.reset(instabilityGeneration: 4, timestampDiscontinuities: 2)

        let discontinuity = evidence.observe(
            instabilityGeneration: 4,
            reason: .underrun,
            timestampDiscontinuities: 3,
            at: start
        )
        let diagnosticsReset = evidence.observe(
            instabilityGeneration: 4,
            reason: .underrun,
            timestampDiscontinuities: 0,
            at: start.advanced(by: .seconds(1))
        )

        #expect(discontinuity.observedDisturbance)
        #expect(discontinuity.escalationReason == nil)
        #expect(!diagnosticsReset.observedDisturbance)
        #expect(diagnosticsReset.escalationReason == nil)
    }

    @Test
    func adaptationEvidenceEscalatesActiveRenderFailuresImmediately() {
        let start = ContinuousClock().now
        var evidence = PlaybackBufferAdaptationEvidence()
        evidence.reset(instabilityGeneration: 8, timestampDiscontinuities: 0)

        let observation = evidence.observe(
            instabilityGeneration: 9,
            reason: .adaptiveRenderFailure,
            timestampDiscontinuities: 0,
            at: start
        )

        #expect(observation.observedDisturbance)
        #expect(observation.escalationReason == .adaptiveRenderFailure)
    }

    @Test
    func playbackBufferCalibrationOnlyProbesUnconfirmedSizes() {
        let stable = PersistedPlaybackBufferCalibration(
            outputUID: "output-a",
            sampleRate: 48_000,
            stableFrameSize: 128,
            probingFrameSize: nil,
            operatingPoints: [
                PersistedPlaybackBufferOperatingPoint(
                    frameSize: 128,
                    stableTargetFrames: 256,
                    probingTargetFrames: nil,
                    unstableThroughTargetFrames: nil
                )
            ],
            events: []
        )
        var pending = stable
        pending.probingFrameSize = 256
        pending.updateOperatingPoint(for: 256) { operatingPoint in
            operatingPoint.probingTargetFrames = 512
        }

        #expect(PlaybackBufferCalibrationPolicy.shouldProbe(
            frameSize: 64,
            targetFrames: 128,
            calibration: nil
        ))
        #expect(!PlaybackBufferCalibrationPolicy.shouldProbe(
            frameSize: 128,
            targetFrames: 256,
            calibration: stable
        ))
        #expect(PlaybackBufferCalibrationPolicy.shouldProbe(
            frameSize: 256,
            targetFrames: 512,
            calibration: pending
        ))
    }

    @Test
    func underrunsGrowTheReservoirBeforeTheCallbackSizeChanges() {
        #expect(AdaptivePlaybackBufferPolicy.nextTargetFrames(
            callbackFrames: 64,
            after: 128
        ) == 192)
        #expect(AdaptivePlaybackBufferPolicy.nextTargetFrames(
            callbackFrames: 64,
            after: 256
        ) == nil)
        #expect(AdaptivePlaybackBufferPolicy.nextTargetFrames(
            callbackFrames: 128,
            after: 192
        ) == 256)
        #expect(AdaptivePlaybackBufferPolicy.nextTargetFrames(
            callbackFrames: 128,
            after: 320
        ) == nil)
        #expect(AdaptivePlaybackBufferPolicy.nextTargetFrames(
            callbackFrames: 3_072,
            after: 4_096,
            maximumReservoirFrames: 2_048
        ) == 4_160)
    }

    @Test
    func unresolvedInstabilityPersistenceIsDeduplicatedUntilReset() {
        let underrun = UnresolvedPlaybackBufferInstability(
            outputUID: "scarlett",
            sampleRate: 48_000,
            frameSize: 512,
            targetFrames: 704,
            reason: .underrun
        )
        var largerTarget = underrun
        largerTarget.targetFrames = 768
        var gate = PlaybackBufferInstabilityPersistenceGate()

        let firstUnderrun = gate.shouldPersist(underrun)
        let repeatedUnderrun = gate.shouldPersist(underrun)
        let firstLargerTarget = gate.shouldPersist(largerTarget)
        let repeatedLargerTarget = gate.shouldPersist(largerTarget)
        #expect(firstUnderrun)
        #expect(!repeatedUnderrun)
        #expect(firstLargerTarget)
        #expect(!repeatedLargerTarget)

        gate.reset(outputUID: "other-output")
        let afterUnrelatedReset = gate.shouldPersist(largerTarget)
        #expect(!afterUnrelatedReset)

        gate.reset(outputUID: "scarlett")
        let afterMatchingReset = gate.shouldPersist(largerTarget)
        #expect(afterMatchingReset)

        gate.persistenceFailed(for: largerTarget)
        let afterPersistenceFailure = gate.shouldPersist(largerTarget)
        #expect(afterPersistenceFailure)
    }

    @Test
    func adaptiveRenderRecoveryAllowsOneRestartBeforeFailing() {
        #expect(AdaptivePlaybackRenderRecoveryPolicy.shouldRestart(afterCompletedAttempts: 0))
        #expect(!AdaptivePlaybackRenderRecoveryPolicy.shouldRestart(afterCompletedAttempts: 1))
    }

    @Test
    func activeAdaptiveRenderFailureTakesPriorityOverLaterInstability() {
        #expect(AdaptivePlaybackRenderRecoveryPolicy.effectiveInstabilityReason(
            latest: .underrun,
            renderFailureActive: true
        ) == .adaptiveRenderFailure)
        #expect(AdaptivePlaybackRenderRecoveryPolicy.effectiveInstabilityReason(
            latest: .underrun,
            renderFailureActive: false
        ) == .underrun)
    }

    @Test
    func playbackBufferCalibrationKeepsServoTargetsPerCallbackSize() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlassEQPlaybackBufferCalibration-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("LearnedPlaybackBuffers.json")
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        try PersistedPlaybackBufferCalibrationStore.recordStable(
            outputUID: "scarlett",
            sampleRate: 48_000,
            frameSize: 64,
            targetFrames: 256,
            at: url
        )
        try PersistedPlaybackBufferCalibrationStore.recordStable(
            outputUID: "scarlett",
            sampleRate: 48_000,
            frameSize: 128,
            targetFrames: 192,
            at: url
        )

        let calibration = try #require(PersistedPlaybackBufferCalibrationStore.calibration(
            outputUID: "scarlett",
            sampleRate: 48_000,
            from: url
        ))
        #expect(calibration.preferredFrameSize == 128)
        #expect(calibration.preferredTargetFrames(for: 64) == 256)
        #expect(calibration.preferredTargetFrames(for: 128) == 192)
        #expect(calibration.operatingPoints.map(\.frameSize) == [64, 128])
    }

    @Test
    func playbackBufferCalibrationKeepsServoTargetsPerTapRate() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlassEQPlaybackBufferCalibration-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("LearnedPlaybackBuffers.json")
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        try PersistedPlaybackBufferCalibrationStore.recordStable(
            outputUID: "scarlett",
            sampleRate: 48_000,
            tapSampleRate: 24_000,
            frameSize: 64,
            targetFrames: 1_056,
            at: url
        )
        try PersistedPlaybackBufferCalibrationStore.recordStable(
            outputUID: "scarlett",
            sampleRate: 48_000,
            tapSampleRate: 48_000,
            frameSize: 64,
            targetFrames: 192,
            at: url
        )

        let convertedRoute = try #require(PersistedPlaybackBufferCalibrationStore.calibration(
            outputUID: "scarlett",
            sampleRate: 48_000,
            tapSampleRate: 24_000,
            from: url
        ))
        let directRoute = try #require(PersistedPlaybackBufferCalibrationStore.calibration(
            outputUID: "scarlett",
            sampleRate: 48_000,
            tapSampleRate: 48_000,
            from: url
        ))
        #expect(convertedRoute.preferredTargetFrames(for: 64) == 1_056)
        #expect(directRoute.preferredTargetFrames(for: 64) == 192)
    }

    @Test
    func failedDownwardProbeKeepsTheStableTargetAndBlocksAnotherAttempt() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlassEQPlaybackBufferCalibration-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("LearnedPlaybackBuffers.json")
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        try PersistedPlaybackBufferCalibrationStore.recordStable(
            outputUID: "scarlett",
            sampleRate: 48_000,
            frameSize: 128,
            targetFrames: 256,
            at: url
        )
        try PersistedPlaybackBufferCalibrationStore.beginProbe(
            outputUID: "scarlett",
            sampleRate: 48_000,
            frameSize: 128,
            targetFrames: 192,
            at: url
        )
        try PersistedPlaybackBufferCalibrationStore.recordInstability(
            outputUID: "scarlett",
            sampleRate: 48_000,
            previousFrameSize: 128,
            resultingFrameSize: 128,
            previousTargetFrames: 192,
            resultingTargetFrames: 256,
            reason: .underrun,
            at: url
        )

        let calibration = try #require(PersistedPlaybackBufferCalibrationStore.calibration(
            outputUID: "scarlett",
            sampleRate: 48_000,
            from: url
        ))
        let operatingPoint = try #require(calibration.operatingPoint(for: 128))
        #expect(operatingPoint.stableTargetFrames == 256)
        #expect(operatingPoint.probingTargetFrames == 256)
        #expect(operatingPoint.unstableThroughTargetFrames == 192)
        #expect(AdaptivePlaybackBufferPolicy.nextDecayTargetFrames(
            callbackFrames: 128,
            stableTargetFrames: 256,
            unstableThroughTargetFrames: operatingPoint.unstableThroughTargetFrames
        ) == nil)
    }

    @Test
    func targetDecayIsConservativeAndRemembersFailures() {
        #expect(AdaptivePlaybackBufferPolicy.nextDecayTargetFrames(
            callbackFrames: 128,
            stableTargetFrames: 256,
            unstableThroughTargetFrames: nil
        ) == 192)
        #expect(AdaptivePlaybackBufferPolicy.nextDecayTargetFrames(
            callbackFrames: 128,
            stableTargetFrames: 256,
            unstableThroughTargetFrames: 192
        ) == nil)
        #expect(AdaptivePlaybackBufferPolicy.nextDecayTargetFrames(
            callbackFrames: 64,
            stableTargetFrames: 128,
            unstableThroughTargetFrames: nil
        ) == nil)
        #expect(AdaptivePlaybackBufferPolicy.nextDecayTargetFrames(
            callbackFrames: 128,
            stableTargetFrames: 256,
            unstableThroughTargetFrames: nil,
            baselineTargetFrames: 256
        ) == nil)
    }

    @Test
    func startupTargetUsesBaselineOrCurrentCalibrationWithoutProbingDown() {
        let stable = PersistedPlaybackBufferOperatingPoint(
            frameSize: 128,
            stableTargetFrames: 256,
            probingTargetFrames: nil,
            unstableThroughTargetFrames: nil
        )
        #expect(AdaptivePlaybackBufferPolicy.startupTargetFrames(
            baselineTargetFrames: 192,
            operatingPoint: nil
        ) == 192)
        #expect(AdaptivePlaybackBufferPolicy.startupTargetFrames(
            baselineTargetFrames: 192,
            operatingPoint: stable
        ) == 256)
    }

    @Test
    func startupFrameSizeUsesCurrentCalibrationWithoutProbingDown() {
        let calibration = PersistedPlaybackBufferCalibration(
            outputUID: "output-a",
            sampleRate: 48_000,
            stableFrameSize: 256,
            probingFrameSize: nil,
            operatingPoints: [],
            events: []
        )
        let range = AudioBufferFrameSizeRange(minimum: 64, maximum: 512)

        #expect(AdaptivePlaybackBufferPolicy.startupFrameSize(
            preferredFrameSize: 64,
            calibration: calibration,
            supportedRange: range
        ) == 256)

        var probing = calibration
        probing.probingFrameSize = 512
        #expect(AdaptivePlaybackBufferPolicy.startupFrameSize(
            preferredFrameSize: 64,
            calibration: probing,
            supportedRange: range
        ) == 512)
    }

    @Test
    func servoLearnsSteadyClockDriftFromOccupancy() {
        var servo = PlaybackRateServo(sampleRate: 48_000, targetFrames: 1_024)
        servo.didPrime(occupancyFrames: 1_024)
        var occupancy = 1_024.0
        let producerRatio = 1.000_040

        for _ in 0..<Int(180 * 48_000 / 512) {
            let ratio = servo.update(
                occupancyFrames: Int(occupancy.rounded()),
                outputFrames: 512
            )
            occupancy += 512 * (producerRatio - ratio)
        }

        #expect(abs(servo.correctionPartsPerMillion - 40) < 3)
        #expect(abs(occupancy - 1_024) < 3)

        servo.beginPriming()
        servo.didPrime(occupancyFrames: 1_024)
        occupancy = 1_024
        for _ in 0..<Int(30 * 48_000 / 512) {
            let ratio = servo.update(
                occupancyFrames: Int(occupancy.rounded()),
                outputFrames: 512
            )
            occupancy += 512 * (producerRatio - ratio)
        }

        #expect(abs(servo.correctionPartsPerMillion - 40) < 3)
        #expect(abs(occupancy - 1_024) < 3)
    }

    @Test
    func servoLearnsNegativeClockDriftFromOccupancy() {
        var servo = PlaybackRateServo(sampleRate: 48_000, targetFrames: 1_024)
        servo.didPrime(occupancyFrames: 1_024)
        var occupancy = 1_024.0
        let producerRatio = 0.999_960

        for _ in 0..<Int(180 * 48_000 / 512) {
            let ratio = servo.update(
                occupancyFrames: Int(occupancy.rounded()),
                outputFrames: 512
            )
            occupancy += 512 * (producerRatio - ratio)
        }

        #expect(abs(servo.correctionPartsPerMillion + 40) < 3)
        #expect(abs(occupancy - 1_024) < 3)
        #expect(!servo.correctionIsSaturated)
    }

    @Test
    func servoIntegralControlProtectsTheFreshRouteReservoir() {
        var servo = PlaybackRateServo(sampleRate: 48_000, targetFrames: 1_024)
        servo.didPrime(occupancyFrames: 1_024)
        var occupancy = 1_024.0
        var minimumOccupancy = occupancy
        let producerRatio = 0.999_900

        for _ in 0..<Int(180 * 48_000 / 512) {
            let ratio = servo.update(
                occupancyFrames: Int(occupancy.rounded()),
                outputFrames: 512
            )
            occupancy += 512 * (producerRatio - ratio)
            minimumOccupancy = min(minimumOccupancy, occupancy)
        }

        #expect(minimumOccupancy > 960)
        #expect(abs(occupancy - 1_024) < 3)
        #expect(abs(servo.correctionPartsPerMillion + 100) < 3)
    }

    @Test
    func servoClampsExtremeCorrectionsAndPreservesLearningAcrossReprime() {
        var servo = PlaybackRateServo(sampleRate: 48_000, targetFrames: 1_024)
        servo.didPrime(occupancyFrames: 1_024)

        for _ in 0..<Int(10 * 48_000 / 512) {
            _ = servo.update(occupancyFrames: 20_000, outputFrames: 512)
        }

        #expect(abs(servo.correctionPartsPerMillion - 500) < 0.001)
        #expect(servo.correctionIsSaturated)
        let learnedCorrection = servo.correctionPartsPerMillion
        servo.beginPriming()

        #expect(servo.correctionPartsPerMillion == learnedCorrection)

        servo.reset(targetFrames: 1_024)
        #expect(servo.correctionPartsPerMillion == 0)
        #expect(!servo.correctionIsSaturated)
    }

    @Test
    func servoRetargetPreservesCorrectionForTheSameClockPair() {
        var servo = PlaybackRateServo(sampleRate: 48_000, targetFrames: 128)
        servo.didPrime(occupancyFrames: 128)
        for _ in 0..<Int(10 * 48_000 / 64) {
            _ = servo.update(occupancyFrames: 10_000, outputFrames: 64)
        }
        let learnedCorrection = servo.correctionPartsPerMillion

        servo.retarget(192)

        #expect(servo.targetFrames == 192)
        #expect(servo.filteredOccupancyFrames == 192)
        #expect(servo.correctionPartsPerMillion == learnedCorrection)
    }

    @Test
    func reprimeAndRetargetDoNotPromoteProportionalCorrectionIntoLearnedBias() {
        var servo = PlaybackRateServo(sampleRate: 48_000, targetFrames: 128)
        servo.didPrime(occupancyFrames: 128)
        for _ in 0..<Int(48_000 / 64) {
            _ = servo.update(occupancyFrames: 64, outputFrames: 64)
        }
        let learnedCorrection = servo.learnedCorrectionPartsPerMillion
        let activeCorrection = servo.correctionPartsPerMillion
        #expect(abs(activeCorrection - learnedCorrection) > 10)

        var reprimeServo = servo
        reprimeServo.beginPriming()
        #expect(reprimeServo.learnedCorrectionPartsPerMillion == learnedCorrection)
        #expect(reprimeServo.correctionPartsPerMillion == activeCorrection)
        reprimeServo.didPrime(occupancyFrames: 128)
        for _ in 0..<Int(48_000 / 64) {
            _ = reprimeServo.update(occupancyFrames: 128, outputFrames: 64)
        }
        #expect(abs(
            reprimeServo.correctionPartsPerMillion
                - reprimeServo.learnedCorrectionPartsPerMillion
        ) < 0.5)

        servo.retarget(192)
        #expect(servo.learnedCorrectionPartsPerMillion == learnedCorrection)
        #expect(servo.correctionPartsPerMillion == activeCorrection)
    }

    @Test
    func occupancyRecoveryAllowsCallbackJitterButRejectsStepBacklog() {
        #expect(!PlaybackOccupancyRecoveryPolicy.shouldReprime(
            occupancyFrames: 3_072,
            targetFrames: 1_024,
            outputFrames: 512
        ))
        #expect(PlaybackOccupancyRecoveryPolicy.shouldReprime(
            occupancyFrames: 3_073,
            targetFrames: 1_024,
            outputFrames: 512
        ))
        #expect(!PlaybackOccupancyRecoveryPolicy.shouldReprime(
            occupancyFrames: 384,
            targetFrames: 128,
            outputFrames: 64
        ))
        #expect(PlaybackOccupancyRecoveryPolicy.shouldReprime(
            occupancyFrames: 385,
            targetFrames: 128,
            outputFrames: 64
        ))
    }

    @Test
    func backlogReprimePreservesLearnedCorrectionAndRecentersOccupancy() {
        var servo = PlaybackRateServo(sampleRate: 48_000, targetFrames: 1_024)
        servo.didPrime(occupancyFrames: 1_024)
        for _ in 0..<Int(10 * 48_000 / 512) {
            _ = servo.update(occupancyFrames: 2_000, outputFrames: 512)
        }
        let learnedCorrection = servo.correctionPartsPerMillion

        servo.beginPriming()
        servo.didPrime(occupancyFrames: 1_024)

        #expect(servo.correctionPartsPerMillion == learnedCorrection)
        #expect(servo.filteredOccupancyFrames == 1_024)
    }

    @Test
    func hermiteInterpolatorPreservesLinearSignals() {
        for fraction in stride(from: Float(0), through: 1, by: 0.05) {
            let interpolated = HermitePlaybackResampler.interpolate(
                y0: -1,
                y1: 0,
                y2: 1,
                y3: 2,
                fraction: fraction
            )
            #expect(abs(interpolated - fraction) < 0.000_001)
        }
    }

    @Test
    func resamplerCarriesFractionalPhaseAndStereoHistoryAcrossCallbacks() {
        var resampler = HermitePlaybackResampler(channelCount: 2)
        var nextInputFrame = 0
        var renderedSamples: [Float] = []

        for _ in 0..<3 {
            let plan = resampler.inputPlan(outputFrames: 512, ratio: 1)
            var input = Array(repeating: Float.zero, count: plan.combinedFrames * 2)
            let copiedHistory = input.withUnsafeMutableBufferPointer {
                resampler.copyRetainedSamples(into: $0, plan: plan)
            }
            #expect(copiedHistory)

            for frame in 0..<plan.newFrames {
                let inputFrame = plan.prefixFrames + frame
                input[inputFrame * 2] = Float(nextInputFrame)
                input[inputFrame * 2 + 1] = Float(-nextInputFrame)
                nextInputFrame += 1
            }

            var output = Array(repeating: Float.zero, count: 512 * 2)
            let rendered = input.withUnsafeMutableBufferPointer { inputSamples in
                output.withUnsafeMutableBufferPointer { outputSamples in
                    resampler.render(
                        input: inputSamples,
                        plan: plan,
                        output: outputSamples,
                        outputFrames: 512,
                        ratio: 1
                    )
                }
            }
            #expect(rendered)
            renderedSamples.append(contentsOf: output)
        }

        for frame in 0..<(renderedSamples.count / 2) {
            #expect(renderedSamples[frame * 2] == Float(frame))
            #expect(renderedSamples[frame * 2 + 1] == Float(-frame))
        }
    }

    @Test
    func resamplerInputPlanConsumesAtTheRequestedLongTermRatio() {
        var resampler = HermitePlaybackResampler(channelCount: 1)
        var newInputFrames = 0
        let outputFrames = 512
        let ratio = 1.000_4

        for _ in 0..<100 {
            let plan = resampler.inputPlan(outputFrames: outputFrames, ratio: ratio)
            newInputFrames += plan.newFrames
            var input = Array(repeating: Float.zero, count: plan.combinedFrames)
            _ = input.withUnsafeMutableBufferPointer {
                resampler.copyRetainedSamples(into: $0, plan: plan)
            }
            var output = Array(repeating: Float.zero, count: outputFrames)
            let rendered = input.withUnsafeMutableBufferPointer { inputSamples in
                output.withUnsafeMutableBufferPointer { outputSamples in
                    resampler.render(
                        input: inputSamples,
                        plan: plan,
                        output: outputSamples,
                        outputFrames: outputFrames,
                        ratio: ratio
                    )
                }
            }
            #expect(rendered)
        }

        let expectedInputFrames = Double(outputFrames * 100) * ratio
        #expect(abs(Double(newInputFrames - 2) - expectedInputFrames) < 1)
    }

    @Test
    func freshResamplerNeedsTwoLookaheadFramesAtUnity() {
        let resampler = HermitePlaybackResampler(channelCount: 2)

        #expect(resampler.inputPlan(outputFrames: 128, ratio: 1).newFrames == 130)
        #expect(resampler.inputPlan(outputFrames: 512, ratio: 1).newFrames == 514)
    }

    @Test
    func outputTimestampTrackerDetectsAndReanchorsAfterDiscontinuity() {
        var tracker = OutputCallbackTimestampTracker()

        let first = tracker.observe(sampleTime: 1_000, frameCount: 128)
        let contiguous = tracker.observe(sampleTime: 1_128, frameCount: 128)
        let discontinuous = tracker.observe(sampleTime: 1_400, frameCount: 128)
        let reanchored = tracker.observe(sampleTime: 1_528, frameCount: 128)
        #expect(!first)
        #expect(!contiguous)
        #expect(discontinuous)
        #expect(!reanchored)

        tracker.reset()
        let resetBaseline = tracker.observe(sampleTime: 50_000, frameCount: 64)
        #expect(!resetBaseline)
    }

    @Test
    func outputTimestampTrackerIgnoresUnavailableTimestamps() {
        var tracker = OutputCallbackTimestampTracker()

        let first = tracker.observe(sampleTime: 1_000, frameCount: 64)
        let unavailable = tracker.observe(sampleTime: nil, frameCount: 64)
        let newBaseline = tracker.observe(sampleTime: 2_000, frameCount: 64)
        #expect(!first)
        #expect(!unavailable)
        #expect(!newBaseline)
    }

    @Test
    func resamplerKeepsStereoPhaseContinuousAcrossRatioTransitions() {
        let sampleRate = 48_000.0
        let frequency = 1_000.0
        let outputFrames = 512
        let ratios = [
            1.000_040, 0.999_960,
            1.000_100, 0.999_900,
            1.000_500, 0.999_500,
        ]
        var resampler = HermitePlaybackResampler(channelCount: 2)
        var nextInputFrame = 0
        var nextOutputPosition = 0.0
        var maximumError = 0.0
        var maximumStereoPhaseError = 0.0

        for ratio in Array(repeating: ratios, count: 4).flatMap({ $0 }) {
            let plan = resampler.inputPlan(outputFrames: outputFrames, ratio: ratio)
            var input = Array(repeating: Float.zero, count: plan.combinedFrames * 2)
            _ = input.withUnsafeMutableBufferPointer {
                resampler.copyRetainedSamples(into: $0, plan: plan)
            }
            for frame in 0..<plan.newFrames {
                let phase = 2 * Double.pi * frequency * Double(nextInputFrame) / sampleRate
                let inputFrame = plan.prefixFrames + frame
                input[inputFrame * 2] = Float(sin(phase))
                input[inputFrame * 2 + 1] = Float(-sin(phase))
                nextInputFrame += 1
            }

            var output = Array(repeating: Float.zero, count: outputFrames * 2)
            let rendered = input.withUnsafeMutableBufferPointer { inputSamples in
                output.withUnsafeMutableBufferPointer { outputSamples in
                    resampler.render(
                        input: inputSamples,
                        plan: plan,
                        output: outputSamples,
                        outputFrames: outputFrames,
                        ratio: ratio
                    )
                }
            }
            #expect(rendered)

            for frame in 0..<outputFrames {
                let sourcePosition = nextOutputPosition + Double(frame) * ratio
                let phase = 2 * Double.pi * frequency * sourcePosition / sampleRate
                let left = Double(output[frame * 2])
                let right = Double(output[frame * 2 + 1])
                maximumError = max(maximumError, abs(left - sin(phase)))
                maximumStereoPhaseError = max(maximumStereoPhaseError, abs(left + right))
            }
            nextOutputPosition += Double(outputFrames) * ratio
        }

        #expect(maximumError < 0.000_1)
        #expect(maximumStereoPhaseError < 0.000_001)
    }
}
