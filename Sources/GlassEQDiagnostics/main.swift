import Darwin
import Foundation
import GlassEQAudio
import GlassEQCore

let arguments = Array(CommandLine.arguments.dropFirst().drop { $0 == "--" })
if arguments.first == "dsp-benchmark" || arguments.first == "--dsp-benchmark" {
    runDSPBenchmark()
    exit(0)
}

do {
    let options = try DiagnosticsOptions(arguments: arguments)
    exit(Int32(runDiagnostics(options: options)))
} catch let error as DiagnosticsArgumentError {
    print("GlassEQ diagnostics arguments failed: \(error)")
    exit(2)
} catch {
    print("GlassEQ diagnostics failed: \(error)")
    exit(1)
}

private struct DiagnosticsOptions {
    var duration: TimeInterval = 3
    var holdAfterStart: TimeInterval = 3
    var health = false
    var expectPermissionDenied = false
    var intentionalCrashAfterStart = false
    var listOutputs = false
    var clockSourceProbe = false
    var outputObjectID: UInt32?

    init(arguments: [String]) throws {
        var positionalDuration: TimeInterval?
        var explicitHoldAfterStart: TimeInterval?
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--health":
                health = true
            case "--expect-permission-denied":
                expectPermissionDenied = true
            case "--intentional-crash-after-start":
                intentionalCrashAfterStart = true
            case "--list-outputs":
                listOutputs = true
            case "--clock-source-probe":
                clockSourceProbe = true
            case "--output-id":
                index += 1
                guard index < arguments.count else {
                    throw DiagnosticsArgumentError.missingValue(argument)
                }
                outputObjectID = try Self.parseObjectID(arguments[index], option: argument)
            case let value where value.hasPrefix("--output-id="):
                let objectID = String(value.dropFirst("--output-id=".count))
                outputObjectID = try Self.parseObjectID(objectID, option: "--output-id")
            case "--hold-after-start":
                index += 1
                guard index < arguments.count else {
                    throw DiagnosticsArgumentError.missingValue(argument)
                }
                explicitHoldAfterStart = try Self.parseSeconds(arguments[index], option: argument)
            case let value where value.hasPrefix("--hold-after-start="):
                let seconds = String(value.dropFirst("--hold-after-start=".count))
                explicitHoldAfterStart = try Self.parseSeconds(seconds, option: "--hold-after-start")
            case let value where value.hasPrefix("--"):
                throw DiagnosticsArgumentError.unknownOption(value)
            default:
                guard positionalDuration == nil, let seconds = Double(argument), seconds.isFinite else {
                    throw DiagnosticsArgumentError.unexpectedArgument(argument)
                }
                positionalDuration = max(seconds, 0.5)
            }
            index += 1
        }

        duration = positionalDuration ?? 3
        holdAfterStart = explicitHoldAfterStart ?? duration
    }

    private static func parseSeconds(_ value: String, option: String) throws -> TimeInterval {
        guard let seconds = Double(value), seconds.isFinite, seconds >= 0 else {
            throw DiagnosticsArgumentError.invalidSeconds(option: option, value: value)
        }
        return seconds
    }

    private static func parseObjectID(_ value: String, option: String) throws -> UInt32 {
        guard let objectID = UInt32(value), objectID > 0 else {
            throw DiagnosticsArgumentError.invalidObjectID(option: option, value: value)
        }
        return objectID
    }
}

private enum DiagnosticsArgumentError: Error, CustomStringConvertible {
    case missingValue(String)
    case invalidSeconds(option: String, value: String)
    case invalidObjectID(option: String, value: String)
    case unknownOption(String)
    case unexpectedArgument(String)

    var description: String {
        switch self {
        case .missingValue(let option):
            return "\(option) requires a seconds value."
        case .invalidSeconds(let option, let value):
            return "\(option) requires a non-negative seconds value; got \(value)."
        case .invalidObjectID(let option, let value):
            return "\(option) requires a positive Core Audio object ID; got \(value)."
        case .unknownOption(let option):
            return "Unknown option \(option)."
        case .unexpectedArgument(let argument):
            return "Unexpected argument \(argument)."
        }
    }
}

private func runDiagnostics(options: DiagnosticsOptions) -> Int32 {
    let engine = SystemTapAudioEngine()

    do {
        if options.listOutputs {
            for output in try CoreAudioDeviceQuery.outputDevices() {
                print("\(output.id)\t\(output.name)\t\(output.uid)")
            }
            return 0
        }
        let output = if let objectID = options.outputObjectID {
            try CoreAudioDeviceQuery.outputDevice(id: objectID)
        } else {
            try CoreAudioDeviceQuery.defaultOutputDevice()
        }
        print("GlassEQ diagnostics")
        if options.health {
            print("Mode: health")
        }
        print("Output: \(output.name)")
        print("UID: \(output.uid)")
        print("Sample rate: \(output.nominalSampleRate)")
        print("Output channels: \(output.outputChannelCount)")
        print("Buffer frames (before tuning): \(output.bufferFrameSize)")
        if let transportType = output.transportType {
            print("Transport type: \(transportType)")
        }

        if options.clockSourceProbe {
            return runAggregateClockSourceProbe(output: output)
        }

        printAudioEngineStatus(.starting)
        try engine.start(output: output, profile: .flatGraphic31)
        printAudioEngineStatus(engine.status)

        if case .running(let activeOutput) = engine.state {
            print("Active buffer frames: \(activeOutput.bufferFrameSize)")
        }
        if let latencyMetadata = engine.snapshotLatencyMetadata() {
            printLatencyMetadata(latencyMetadata.physicalDevice, label: "Physical device")
            printLatencyMetadata(latencyMetadata.aggregateDevice, label: "Combined aggregate")
        }
        if options.intentionalCrashAfterStart {
            print("Intentional crash requested after engine start. Pending device setting restoration is persisted and retried on the next launch.")
            fflush(stdout)
            abort()
        }

        print("Engine started for \(options.holdAfterStart) seconds. Play system audio now to exercise the tap path.")
        Thread.sleep(forTimeInterval: options.holdAfterStart)
        let metrics = engine.snapshotMetrics()
        engine.stop()
        let timestampProbeRecords = engine.snapshotTimestampProbeRecords()
        printMetrics(metrics, sampleRate: output.nominalSampleRate)
        printTimestampProbeRecords(timestampProbeRecords)
        printAudioEngineStatus(.stopped)
        print("Engine stopped cleanly.")

        if options.expectPermissionDenied {
            print("Expected permission denial, but the engine started successfully.")
            return 1
        }

        if options.health {
            print("Health: passed")
        }
        return 0
    } catch {
        engine.stop()
        let status = audioEngineStatus(from: error)
        printAudioEngineStatus(status)
        print("GlassEQ diagnostics failed: \(error)")

        guard options.expectPermissionDenied else {
            return 1
        }

        if case .permissionRequired = status {
            print("Expected permission denial observed.")
            return 0
        }

        print("Expected permission denial, but observed a different failure.")
        return 1
    }
}

private func printLatencyMetadata(
    _ metadata: AudioDeviceLatencyMetadata,
    label: String
) {
    print("\(label) object ID: \(metadata.objectID)")
    if let device = try? CoreAudioDeviceQuery.outputDevice(id: metadata.objectID) {
        print("\(label) nominal sample rate: \(device.nominalSampleRate)")
    } else {
        print("\(label) nominal sample rate: unavailable")
    }
    print("\(label) buffer frames: \(optionalFrames(metadata.bufferFrameSize))")
    print("\(label) input stream channels: \(optionalChannelCounts(metadata.inputStreamChannelCounts))")
    print("\(label) output stream channels: \(optionalChannelCounts(metadata.outputStreamChannelCounts))")
    print("\(label) input latency: \(optionalFrames(metadata.inputLatencyFrames))")
    print("\(label) input safety offset: \(optionalFrames(metadata.inputSafetyOffsetFrames))")
    print("\(label) input safety offset settable: \(optionalBoolean(metadata.inputSafetyOffsetSettable))")
    print("\(label) output latency: \(optionalFrames(metadata.outputLatencyFrames))")
    print("\(label) output safety offset: \(optionalFrames(metadata.outputSafetyOffsetFrames))")
    print("\(label) output safety offset settable: \(optionalBoolean(metadata.outputSafetyOffsetSettable))")
}

private func optionalFrames(_ frames: UInt32?) -> String {
    frames.map(String.init) ?? "unavailable"
}

private func optionalBoolean(_ value: Bool?) -> String {
    value.map(String.init) ?? "unavailable"
}

private func optionalChannelCounts(_ counts: [Int]?) -> String {
    counts.map { String(describing: $0) } ?? "unavailable"
}

private func audioEngineStatus(from state: AudioEngineState) -> AudioEngineStatus {
    switch state {
    case .stopped:
        return .stopped
    case .running(let output):
        return .running(output: output)
    case .failed(let message):
        return .failed(
            AudioEngineFailure(
                category: .coreAudioOperationFailed,
                userMessage: message,
                operation: "SystemTapAudioEngine"
            )
        )
    }
}

private func audioEngineStatus(from error: Error) -> AudioEngineStatus {
    if let availabilityError = error as? AudioDeviceAvailabilityError {
        let category: AudioEngineFailure.Category
        if case .unsupportedOutputChannelCount = availabilityError {
            category = .deviceFormatUnsupported
        } else {
            category = .outputDeviceUnavailable
        }
        return .failed(
            AudioEngineFailure(
                category: category,
                userMessage: availabilityError.description,
                operation: "CoreAudioDeviceQuery"
            )
        )
    }
    guard let coreAudioError = error as? CoreAudioError else {
        return .failed(
            AudioEngineFailure(
                category: .coreAudioOperationFailed,
                userMessage: String(describing: error),
                operation: "GlassEQDiagnostics"
            )
        )
    }

    let failure = classifyCoreAudioError(coreAudioError)
    if failure.category == .systemAudioCapturePermission {
        return .permissionRequired(failure)
    }
    return .failed(failure)
}

private func printAudioEngineStatus(_ status: AudioEngineStatus) {
    switch status {
    case .stopped:
        print("Status: stopped")
    case .starting:
        print("Status: starting")
    case .running(let output):
        print("Status: running")
        print("Status output: \(output.name)")
    case .permissionRequired(let failure):
        print("Status: permission required")
        printAudioEngineFailure(failure)
    case .failed(let failure):
        print("Status: failed")
        printAudioEngineFailure(failure)
    }
}

private func printAudioEngineFailure(_ failure: AudioEngineFailure) {
    print("Failure category: \(failure.category)")
    print("Failure message: \(failure.userMessage)")
    print("Failure operation: \(failure.operation)")
    if let status = failure.status {
        print("Failure OSStatus: \(formatOSStatus(status))")
    }
    if let statusFourCC = failure.statusFourCC {
        print("Failure FourCC: \(statusFourCC)")
    }
}

private func printMetrics(_ metrics: AudioEngineMetrics, sampleRate: Double) {
    print("Captured frames: \(metrics.capturedFrames)")
    print("Played frames: \(metrics.playedFrames)")
    print("Playback underrun frames: \(metrics.playbackUnderrunFrames)")
    print("Dropped input frames: \(metrics.droppedInputFrames)")
    print("Saturated samples: \(metrics.saturatedSamples)")
    print("Input timestamp jumps: \(metrics.inputTimestampDiscontinuities)")
    print("Output timestamp jumps: \(metrics.outputTimestampDiscontinuities)")
    print("Paired timestamp jumps: \(metrics.pairedTimestampDiscontinuities)")
    if metrics.pairedTimestampDiscontinuities > 0 {
        print(String(
            format: "Last input jump: %+.3f frames, host interval error %+.3f ms",
            metrics.lastInputTimestampJumpFrames,
            Double(metrics.lastInputHostIntervalErrorNanoseconds) / 1_000_000
        ))
        print(String(
            format: "Last output jump: %+.3f frames, host interval error %+.3f ms",
            metrics.lastOutputTimestampJumpFrames,
            Double(metrics.lastOutputHostIntervalErrorNanoseconds) / 1_000_000
        ))
    }
    if metrics.timestampJumpIntervalObservations > 0 {
        print(String(
            format: "Paired jump interval: %.3f ms average, %.3f to %.3f ms",
            metrics.averageTimestampJumpIntervalNanoseconds / 1_000_000,
            Double(metrics.minimumTimestampJumpIntervalNanoseconds) / 1_000_000,
            Double(metrics.maximumTimestampJumpIntervalNanoseconds) / 1_000_000
        ))
    } else {
        print("Paired jump interval: unavailable")
    }
    print("Max capture callback frames: \(metrics.maximumCaptureCallbackFrames)")
    print("Max playback callback frames: \(metrics.maximumPlaybackCallbackFrames)")
    if metrics.tapToOutputLatencyObservations > 0 {
        print(String(
            format: "Tap-to-output latency: %.3f ms average, %.3f to %.3f ms",
            metrics.averageTapToOutputLatencyNanoseconds / 1_000_000,
            Double(metrics.minimumTapToOutputLatencyNanoseconds) / 1_000_000,
            Double(metrics.maximumTapToOutputLatencyNanoseconds) / 1_000_000
        ))
    } else {
        print("Tap-to-output latency: unavailable")
    }
    if metrics.callbackTimingObservations > 0 {
        print(String(
            format: "Input age: %.3f ms average, %.3f frames, %.3f to %.3f ms",
            metrics.averageInputAgeNanoseconds / 1_000_000,
            metrics.averageInputAgeNanoseconds * sampleRate / 1_000_000_000,
            Double(metrics.minimumInputAgeNanoseconds) / 1_000_000,
            Double(metrics.maximumInputAgeNanoseconds) / 1_000_000
        ))
        print(String(
            format: "Output lead: %.3f ms average, %.3f frames, %.3f to %.3f ms",
            metrics.averageOutputLeadNanoseconds / 1_000_000,
            metrics.averageOutputLeadNanoseconds * sampleRate / 1_000_000_000,
            Double(metrics.minimumOutputLeadNanoseconds) / 1_000_000,
            Double(metrics.maximumOutputLeadNanoseconds) / 1_000_000
        ))
    } else {
        print("Input age: unavailable")
        print("Output lead: unavailable")
    }
}

private func printTimestampProbeRecords(_ records: [AudioTimestampProbeRecord]) {
    print("Timestamp probe records: \(records.count)")
    for record in records {
        print(
            "Jump #\(record.sequence) callbacks=\(record.inputFrameCount)/\(record.outputFrameCount) "
                + "inputJump=\(record.inputJumpDetected ? "yes" : "no") "
                + "outputJump=\(record.outputJumpDetected ? "yes" : "no")"
        )
        print(String(
            format: "  input  mSampleTime=%.6f mHostTime=%llu mRateScalar=%.12f mFlags=0x%08X delta=%+.3f frames hostError=%+.3f ms",
            record.inputSampleTime,
            record.inputHostTime,
            record.inputRateScalar,
            record.inputFlags,
            record.inputSampleTimeDeltaFrames,
            Double(record.inputHostIntervalErrorNanoseconds) / 1_000_000
        ))
        print(String(
            format: "  output mSampleTime=%.6f mHostTime=%llu mRateScalar=%.12f mFlags=0x%08X delta=%+.3f frames hostError=%+.3f ms",
            record.outputSampleTime,
            record.outputHostTime,
            record.outputRateScalar,
            record.outputFlags,
            record.outputSampleTimeDeltaFrames,
            Double(record.outputHostIntervalErrorNanoseconds) / 1_000_000
        ))
    }
}

private struct DSPBenchmarkCase {
    var name: String
    var profile: EQProfile
    var sampleRate: Double
    var channelCount: Int
    var frameCount: Int
}

private func runDSPBenchmark() {
    let cases = [
        DSPBenchmarkCase(
            name: "Flat parametric",
            profile: .flatParametric,
            sampleRate: 48_000,
            channelCount: 2,
            frameCount: 16
        ),
        DSPBenchmarkCase(
            name: "31-band graphic at 48 kHz",
            profile: .flatGraphic31,
            sampleRate: 48_000,
            channelCount: 2,
            frameCount: 16
        ),
        DSPBenchmarkCase(
            name: "31-band graphic at 96 kHz",
            profile: .flatGraphic31,
            sampleRate: 96_000,
            channelCount: 2,
            frameCount: 16
        ),
        DSPBenchmarkCase(
            name: "31-band graphic at 192 kHz",
            profile: .flatGraphic31,
            sampleRate: 192_000,
            channelCount: 2,
            frameCount: 16
        ),
        DSPBenchmarkCase(
            name: "Complex stereo",
            profile: complexStereoProfile(),
            sampleRate: 48_000,
            channelCount: 2,
            frameCount: 16
        )
    ]

    print("GlassEQ DSP benchmark")
    print("Measures the 16-frame DSP workload; Core Audio buffering and device latency are not included.")
    print("Biquad EQ is in-place and has no fixed block/sample delay; recursive filters still have frequency-dependent phase/group delay.")
    print("")

    for benchmarkCase in cases {
        run(benchmarkCase)
    }
}

private func run(_ benchmarkCase: DSPBenchmarkCase) {
    let iterations = 20_000
    let warmupIterations = 1_000
    let originalSamples = makeStereoTestBlock(
        frameCount: benchmarkCase.frameCount,
        sampleRate: benchmarkCase.sampleRate
    )
    var samples = originalSamples
    var processor = EQProcessor(
        configuration: EQConfiguration(
            profile: benchmarkCase.profile,
            sampleRate: benchmarkCase.sampleRate,
            channelCount: benchmarkCase.channelCount
        )
    )

    for _ in 0..<warmupIterations {
        samples = originalSamples
        processor.processInterleaved(&samples, channelCount: benchmarkCase.channelCount)
    }

    let start = DispatchTime.now().uptimeNanoseconds
    var saturatedSamples: UInt64 = 0
    for _ in 0..<iterations {
        samples = originalSamples
        saturatedSamples &+= samples.withUnsafeMutableBufferPointer {
            processor.processInterleavedWithDiagnostics(
                $0,
                frameCount: benchmarkCase.frameCount,
                channelCount: benchmarkCase.channelCount
            )
        }
    }
    let elapsed = DispatchTime.now().uptimeNanoseconds - start

    let averageNanoseconds = Double(elapsed) / Double(iterations)
    let averageMicroseconds = averageNanoseconds / 1_000
    let callbackBudgetMicroseconds = Double(benchmarkCase.frameCount) / benchmarkCase.sampleRate * 1_000_000
    let budgetPercent = averageMicroseconds / callbackBudgetMicroseconds * 100
    let perSampleNanoseconds = averageNanoseconds / Double(benchmarkCase.frameCount * benchmarkCase.channelCount)

    print(benchmarkCase.name)
    print(String(format: "  Buffer: %d frames, %d channels, %.0f Hz", benchmarkCase.frameCount, benchmarkCase.channelCount, benchmarkCase.sampleRate))
    print(String(format: "  Avg DSP time: %.3f us/buffer", averageMicroseconds))
    print(String(format: "  Callback budget: %.3f us (%.3f%% used)", callbackBudgetMicroseconds, budgetPercent))
    print(String(format: "  Avg per sample: %.3f ns", perSampleNanoseconds))
    print("  Saturated samples during benchmark: \(saturatedSamples)")
    print("")
}

private func complexStereoProfile() -> EQProfile {
    EQProfile(
        name: "Complex Stereo",
        mode: .parametric,
        channelMode: .stereo,
        preampDB: -3,
        filters: [],
        leftPreampDB: -3,
        leftFilters: [
            EQFilter(kind: .peak, frequency: 55, gainDB: 4.5, q: 4),
            EQFilter(kind: .lowShelf, frequency: 110, gainDB: 2.5, q: 0.8),
            EQFilter(kind: .highShelf, frequency: 9_000, gainDB: -3.5, q: 0.7),
            EQFilter(kind: .highPass, frequency: 24, gainDB: 0, q: 0.707)
        ],
        rightPreampDB: -4,
        rightFilters: [
            EQFilter(kind: .peak, frequency: 1_250, gainDB: -5, q: 7),
            EQFilter(kind: .lowPass, frequency: 18_000, gainDB: 0, q: 0.707),
            EQFilter(kind: .highShelf, frequency: 12_000, gainDB: 2, q: 0.9),
            EQFilter(kind: .peak, frequency: 72, gainDB: 3, q: 5)
        ]
    )
}

private func makeStereoTestBlock(frameCount: Int, sampleRate: Double) -> [Float] {
    var samples = [Float](repeating: 0, count: frameCount * 2)
    for frame in 0..<frameCount {
        let time = Double(frame) / sampleRate
        samples[frame * 2] = Float(0.18 * sin(2 * Double.pi * 73 * time) + 0.07 * sin(2 * Double.pi * 1_007 * time))
        samples[frame * 2 + 1] = Float(0.16 * sin(2 * Double.pi * 211 * time) - 0.05 * sin(2 * Double.pi * 6_300 * time))
    }
    return samples
}
