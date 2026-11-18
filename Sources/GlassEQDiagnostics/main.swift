import Darwin
import Foundation
import GlassEQAudio
import GlassEQCore

let arguments = Array(CommandLine.arguments.dropFirst().drop { $0 == "--" })
if arguments.first == "dsp-benchmark" || arguments.first == "--dsp-benchmark" {
    let benchmarkArguments = arguments.dropFirst()
    let maximumCallbackBudgetPercent =
        benchmarkArguments.contains("--check")
        ? 50.0
        : nil
    let curvePath = benchmarkArguments.first { $0 != "--check" }
    exit(
        runDSPBenchmark(
            curvePath: curvePath,
            maximumCallbackBudgetPercent: maximumCallbackBudgetPercent
        ) ? 0 : 1)
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
    var explicitOutputClient = false
    var setDefaultOutput = false
    var outputObjectID: UInt32?
    var handoffExperiment: CoreAudioHandoffExperiment?

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
            case "--explicit-output-client":
                explicitOutputClient = true
            case "--set-default-output":
                setDefaultOutput = true
            case "--handoff-experiment":
                index += 1
                guard index < arguments.count else {
                    throw DiagnosticsArgumentError.missingValue(argument)
                }
                handoffExperiment = try Self.parseHandoffExperiment(
                    arguments[index],
                    option: argument
                )
            case let value where value.hasPrefix("--handoff-experiment="):
                let mode = String(value.dropFirst("--handoff-experiment=".count))
                handoffExperiment = try Self.parseHandoffExperiment(
                    mode,
                    option: "--handoff-experiment"
                )
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
        if explicitOutputClient && setDefaultOutput {
            throw DiagnosticsArgumentError.incompatibleOptions(
                "--explicit-output-client",
                "--set-default-output"
            )
        }
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

    private static func parseHandoffExperiment(
        _ value: String,
        option: String
    ) throws -> CoreAudioHandoffExperiment {
        guard let experiment = CoreAudioHandoffExperiment(rawValue: value) else {
            throw DiagnosticsArgumentError.invalidHandoffExperiment(
                option: option,
                value: value
            )
        }
        return experiment
    }
}

private enum DiagnosticsArgumentError: Error, CustomStringConvertible {
    case missingValue(String)
    case invalidSeconds(option: String, value: String)
    case invalidObjectID(option: String, value: String)
    case invalidHandoffExperiment(option: String, value: String)
    case incompatibleOptions(String, String)
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
        case .invalidHandoffExperiment(let option, let value):
            return
                "\(option) requires production-start, combined-incumbent, combined-16, physical-create-only, combined-create-only, combined-output-only, physical-first-live-taps, physical-first-live-taps-16, complete-route-switch, or physical-first-route-switch; got \(value)."
        case .incompatibleOptions(let first, let second):
            return "\(first) and \(second) cannot be used together."
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
        let output =
            if let objectID = options.outputObjectID {
                try CoreAudioDeviceQuery.outputDevice(id: objectID)
            } else {
                try CoreAudioDeviceQuery.defaultOutputDevice()
            }
        if options.setDefaultOutput {
            try setDiagnosticDefaultOutputDevice(output)
            print("Default output: \(output.id)\t\(output.name)\t\(output.uid)")
            return 0
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

        if options.explicitOutputClient {
            return try runExplicitOutputClient(output: output)
        }

        if let handoffExperiment = options.handoffExperiment {
            return try runCoreAudioHandoffExperiment(
                handoffExperiment,
                engine: engine,
                output: output,
                holdDuration: options.holdAfterStart
            )
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
            print(
                "Intentional crash requested after engine start. Pending device setting restoration is persisted and retried on the next launch."
            )
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

func printLatencyMetadata(
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

func printMetrics(_ metrics: AudioEngineMetrics, sampleRate: Double) {
    print("Captured frames: \(metrics.capturedFrames)")
    print("Played frames: \(metrics.playedFrames)")
    print("Playback underrun frames: \(metrics.playbackUnderrunFrames)")
    print("Dropped input frames: \(metrics.droppedInputFrames)")
    print("Saturated samples: \(metrics.saturatedSamples)")
    print("Input timestamp jumps: \(metrics.inputTimestampDiscontinuities)")
    print("Output timestamp jumps: \(metrics.outputTimestampDiscontinuities)")
    print("Paired timestamp jumps: \(metrics.pairedTimestampDiscontinuities)")
    if metrics.pairedTimestampDiscontinuities > 0 {
        print(
            String(
                format: "Last input jump: %+.3f frames, host interval error %+.3f ms",
                metrics.lastInputTimestampJumpFrames,
                Double(metrics.lastInputHostIntervalErrorNanoseconds) / 1_000_000
            ))
        print(
            String(
                format: "Last output jump: %+.3f frames, host interval error %+.3f ms",
                metrics.lastOutputTimestampJumpFrames,
                Double(metrics.lastOutputHostIntervalErrorNanoseconds) / 1_000_000
            ))
    }
    if metrics.timestampJumpIntervalObservations > 0 {
        print(
            String(
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
    print("Render deadline misses: \(metrics.renderDeadlineMisses)")
    print("Start starvations: \(metrics.callbackStartStarvations)")
    print("Render overruns: \(metrics.renderOverruns)")
    printExtremeDuration(
        "Callback start late",
        observations: metrics.renderTiming.callbackStartLatenessObservations,
        p9999Nanoseconds: metrics.renderTiming.callbackStartLatenessP9999Nanoseconds,
        maximumNanoseconds: metrics.renderTiming.maximumCallbackStartLatenessNanoseconds
    )
    if metrics.renderTiming.directHeadObservations > 0 {
        printExtremeDuration(
            "FIR head",
            observations: metrics.renderTiming.directHeadObservations,
            p9999Nanoseconds: metrics.renderTiming.directHeadP9999Nanoseconds,
            maximumNanoseconds: metrics.renderTiming.maximumDirectHeadNanoseconds
        )
        printExtremeDuration(
            "FIR tail",
            observations: metrics.renderTiming.tailWorkObservations,
            p9999Nanoseconds: metrics.renderTiming.tailWorkP9999Nanoseconds,
            maximumNanoseconds: metrics.renderTiming.maximumTailWorkNanoseconds
        )
        print(
            "Tail completion slack: \(metrics.renderTiming.minimumTailCompletionSlackFrames) frames minimum, \(metrics.renderTiming.tailDeadlineMisses) misses"
        )
    }
    printExtremeDuration(
        "Total render",
        observations: metrics.renderTiming.totalRenderObservations,
        p9999Nanoseconds: metrics.renderTiming.totalRenderP9999Nanoseconds,
        maximumNanoseconds: metrics.renderTiming.maximumTotalRenderNanoseconds
    )
    printExtremeDuration(
        "Completion late",
        observations: metrics.renderTiming.completionLatenessObservations,
        p9999Nanoseconds: metrics.renderTiming.completionLatenessP9999Nanoseconds,
        maximumNanoseconds: metrics.renderTiming.maximumCompletionLatenessNanoseconds
    )
    if metrics.tapToOutputLatencyObservations > 0 {
        print(
            String(
                format: "Tap-to-output latency: %.3f ms average, %.3f to %.3f ms",
                metrics.averageTapToOutputLatencyNanoseconds / 1_000_000,
                Double(metrics.minimumTapToOutputLatencyNanoseconds) / 1_000_000,
                Double(metrics.maximumTapToOutputLatencyNanoseconds) / 1_000_000
            ))
    } else {
        print("Tap-to-output latency: unavailable")
    }
    if metrics.callbackTimingObservations > 0 {
        print(
            String(
                format: "Input age: %.3f ms average, %.3f frames, %.3f to %.3f ms",
                metrics.averageInputAgeNanoseconds / 1_000_000,
                metrics.averageInputAgeNanoseconds * sampleRate / 1_000_000_000,
                Double(metrics.minimumInputAgeNanoseconds) / 1_000_000,
                Double(metrics.maximumInputAgeNanoseconds) / 1_000_000
            ))
        print(
            String(
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

private func printExtremeDuration(
    _ label: String,
    observations: UInt64,
    p9999Nanoseconds: UInt64,
    maximumNanoseconds: UInt64
) {
    guard observations > 0 else {
        print("\(label): unavailable")
        return
    }
    print(
        String(
            format: "\(label): %.3f us p99.99, %.3f us maximum over %llu published callbacks",
            Double(p9999Nanoseconds) / 1_000,
            Double(maximumNanoseconds) / 1_000,
            observations
        ))
}

func printTimestampProbeRecords(_ records: [AudioTimestampProbeRecord]) {
    print("Timestamp probe records: \(records.count)")
    for record in records {
        print(
            "Jump #\(record.sequence) callbacks=\(record.inputFrameCount)/\(record.outputFrameCount) "
                + "inputJump=\(record.inputJumpDetected ? "yes" : "no") "
                + "outputJump=\(record.outputJumpDetected ? "yes" : "no")"
        )
        print(
            String(
                format:
                    "  input  mSampleTime=%.6f mHostTime=%llu mRateScalar=%.12f mFlags=0x%08X delta=%+.3f frames hostError=%+.3f ms",
                record.inputSampleTime,
                record.inputHostTime,
                record.inputRateScalar,
                record.inputFlags,
                record.inputSampleTimeDeltaFrames,
                Double(record.inputHostIntervalErrorNanoseconds) / 1_000_000
            ))
        print(
            String(
                format:
                    "  output mSampleTime=%.6f mHostTime=%llu mRateScalar=%.12f mFlags=0x%08X delta=%+.3f frames hostError=%+.3f ms",
                record.outputSampleTime,
                record.outputHostTime,
                record.outputRateScalar,
                record.outputFlags,
                record.outputSampleTimeDeltaFrames,
                Double(record.outputHostIntervalErrorNanoseconds) / 1_000_000
            ))
    }
}
