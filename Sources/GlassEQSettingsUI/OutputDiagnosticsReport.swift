import AppKit
import GlassEQSettingsIPC
import SwiftUI

struct OutputDiagnosticsReport {
    enum SectionID: Hashable {
        case observation
        case timing
        case reliability
        case recovery
        case callbackSizes
        case timestamps
        case route
    }

    struct Row: Identifiable {
        let id: String
        var title: String
        var value: String
    }

    struct Section: Identifiable {
        let id: SectionID
        var title: String
        var symbol: String
        var note: String?
        var rows: [Row]
    }

    let snapshot: SettingsSnapshot
    private(set) var sections: [Section] = []

    init(snapshot: SettingsSnapshot) {
        self.snapshot = snapshot
        sections = makeSections()
    }

    var text: String {
        var lines = [
            localized("GlassEQ audio diagnostics"),
            localized("Output: \(snapshot.currentOutputName)"),
            localized("Active profile: \(snapshot.activeProfileName)"),
            localized("Status: \(snapshot.statusMessage)")
        ]
        for section in sections {
            lines.append("")
            lines.append("## \(section.title)")
            for row in section.rows {
                lines.append("\(row.title): \(row.value)")
            }
            if let note = section.note {
                lines.append(note)
            }
        }
        return lines.joined(separator: "\n")
    }

    var addedLatencyLabel: String {
        if usesSeparateClockDiagnostics {
            guard snapshot.metrics.playbackBufferObservations > 0 else {
                return snapshot.isRunning ? localized("Measuring...") : localized("Unavailable")
            }
            return bridgeLatencyLabel
        }
        guard snapshot.metrics.tapToOutputLatencyObservations > 0 else {
            return snapshot.isRunning ? localized("Measuring...") : localized("Unavailable")
        }
        return tapToOutputLatencyLabel
    }

    private func makeSections() -> [Section] {
        [
            Section(
                id: .observation,
                title: localized("Observation"),
                symbol: "clock",
                rows: [
                    Row(id: "reset", title: localized("Reset"), value: diagnosticsResetLabel),
                    Row(id: "observed", title: localized("Observed"), value: observationDurationLabel),
                    Row(id: "currentRuntime", title: localized("Current Runtime"), value: runtimeDurationLabel)
                ]
            ),
            Section(
                id: .timing,
                title: localized("Timing"),
                symbol: "timer",
                note: localized("Values are p50 / p99 / p99.9 / p99.99 / max. Percentiles use bounded realtime histograms and publish every 1,024 callbacks."),
                rows: timingRows
            ),
            Section(
                id: .reliability,
                title: localized("Reliability"),
                symbol: "checkmark.shield",
                note: localized("Failure categories can overlap."),
                rows: reliabilityRows
            ),
            Section(
                id: .recovery,
                title: localized("Recovery"),
                symbol: "arrow.counterclockwise",
                rows: [
                    Row(id: "runtimeRebuilds", title: localized("Runtime Rebuilds"), value: localizedInteger(diagnostics.recovery.runtimeRebuilds)),
                    Row(id: "automaticRecoveries", title: localized("Automatic Recoveries"), value: localizedInteger(diagnostics.recovery.automaticRecoveries)),
                    Row(id: "bufferEscalations", title: localized("Buffer Escalations"), value: localizedInteger(diagnostics.recovery.bufferEscalations)),
                    Row(id: "headsetFallbacks", title: localized("Headset Fallbacks"), value: localizedInteger(diagnostics.recovery.headsetFallbacks)),
                    Row(id: "lastRecovery", title: localized("Last Recovery"), value: lastRecoveryLabel)
                ]
            ),
            Section(
                id: .callbackSizes,
                title: localized("Callback Sizes"),
                symbol: "square.stack.3d.up",
                rows: [
                    Row(id: "capture", title: localized("Capture"), value: callbackSizeHistogramLabel(snapshot.metrics.captureCallbackSizeObservations)),
                    Row(id: "output", title: localized("Output"), value: callbackSizeHistogramLabel(snapshot.metrics.playbackCallbackSizeObservations)),
                    Row(id: "peaks", title: localized("Capture / Output Peak"), value: callbackPeaksLabel)
                ]
            ),
            Section(
                id: .timestamps,
                title: localized("Timestamps"),
                symbol: "waveform.path.ecg",
                rows: [
                    Row(id: "sampleTimeJumps", title: localized("Last Sample-Time Jumps"), value: timestampJumpLabel),
                    Row(id: "hostTimeErrors", title: localized("Last Host-Time Errors"), value: hostIntervalErrorLabel),
                    Row(id: "jumpInterval", title: localized("Jump Interval min / avg / max"), value: timestampJumpIntervalLabel),
                    Row(id: "inputAge", title: localized("Input Age min / avg / max"), value: inputAgeLabel),
                    Row(id: "outputLead", title: localized("Output Lead min / avg / max"), value: outputLeadLabel)
                ]
            ),
            Section(
                id: .route,
                title: localized("Route"),
                symbol: "point.3.connected.trianglepath.dotted",
                rows: [
                    Row(id: "outputUID", title: localized("Output UID"), value: snapshot.currentOutputUID.isEmpty ? localized("Unavailable") : snapshot.currentOutputUID),
                    Row(id: "transport", title: localized("Transport"), value: diagnostics.route.transport),
                    Row(id: "sampleRates", title: localized("Observed / Active Rate"), value: observedAndActiveRateLabel),
                    Row(id: "processingRate", title: localized("Processing Rate"), value: processingRateLabel),
                    Row(id: "nativeOutputStream", title: localized("Native Output Stream"), value: nativeOutputStreamLabel),
                    Row(id: "physicalOutputStreams", title: localized("Physical Output Streams"), value: streamChannelCountsLabel(diagnostics.route.physicalOutputStreamChannelCounts)),
                    Row(id: "aggregateStreams", title: localized("Aggregate Input / Output Streams"), value: aggregateStreamCountsLabel),
                    Row(id: "bufferSizes", title: localized("Physical / Aggregate Buffer"), value: routeBufferSizesLabel),
                    Row(id: "physicalSafetyOffsets", title: localized("Physical Safety Offsets in / out"), value: physicalSafetyOffsetsLabel),
                    Row(id: "aggregateSafetyOffsets", title: localized("Aggregate Safety Offsets in / out"), value: aggregateSafetyOffsetsLabel),
                    Row(
                        id: "sampleRateConversion",
                        title: localized("Sample Rate Conversion"),
                        value: snapshot.metrics.playbackSampleRateConversionActive
                            ? localized("Active")
                            : localized("Inactive")
                    )
                ]
            )
        ]
    }

    private var diagnostics: SettingsAudioDiagnosticsDTO {
        snapshot.metrics.diagnostics
    }

    private var timingRows: [Row] {
        let timing = snapshot.metrics.renderTiming
        var rows = [
            Row(
                id: "callbackStartLateness",
                title: localized("Callback Start Lateness"),
                value: durationPercentilesLabel(
                    observations: timing.callbackStartLatenessObservations,
                    p50: timing.callbackStartLatenessP50Nanoseconds,
                    p99: timing.callbackStartLatenessP99Nanoseconds,
                    p999: timing.callbackStartLatenessP999Nanoseconds,
                    p9999: timing.callbackStartLatenessP9999Nanoseconds,
                    maximum: timing.maximumCallbackStartLatenessNanoseconds
                )
            )
        ]
        if timing.directHeadObservations > 0 {
            rows += [
                Row(
                    id: "firHead",
                    title: localized("FIR Head"),
                    value: durationPercentilesLabel(
                        observations: timing.directHeadObservations,
                        p50: timing.directHeadP50Nanoseconds,
                        p99: timing.directHeadP99Nanoseconds,
                        p999: timing.directHeadP999Nanoseconds,
                        p9999: timing.directHeadP9999Nanoseconds,
                        maximum: timing.maximumDirectHeadNanoseconds
                    )
                ),
                Row(
                    id: "firTail",
                    title: localized("FIR Tail"),
                    value: durationPercentilesLabel(
                        observations: timing.tailWorkObservations,
                        p50: timing.tailWorkP50Nanoseconds,
                        p99: timing.tailWorkP99Nanoseconds,
                        p999: timing.tailWorkP999Nanoseconds,
                        p9999: timing.tailWorkP9999Nanoseconds,
                        maximum: timing.maximumTailWorkNanoseconds
                    )
                ),
                Row(id: "tailSlack", title: localized("Tail Slack Minimum / Misses"), value: tailCompletionSlackLabel),
                Row(id: "firPartitionMisses", title: localized("FIR Partition Misses"), value: localizedInteger(timing.tailDeadlineMisses))
            ]
        }
        rows += [
            Row(
                id: "totalRender",
                title: localized("Total Render"),
                value: durationPercentilesLabel(
                    observations: timing.totalRenderObservations,
                    p50: timing.totalRenderP50Nanoseconds,
                    p99: timing.totalRenderP99Nanoseconds,
                    p999: timing.totalRenderP999Nanoseconds,
                    p9999: timing.totalRenderP9999Nanoseconds,
                    maximum: timing.maximumTotalRenderNanoseconds
                )
            ),
            Row(
                id: "completionLateness",
                title: localized("Completion Lateness"),
                value: durationPercentilesLabel(
                    observations: timing.completionLatenessObservations,
                    p50: timing.completionLatenessP50Nanoseconds,
                    p99: timing.completionLatenessP99Nanoseconds,
                    p999: timing.completionLatenessP999Nanoseconds,
                    p9999: timing.completionLatenessP9999Nanoseconds,
                    maximum: timing.maximumCompletionLatenessNanoseconds
                )
            )
        ]
        return rows
    }

    private var reliabilityRows: [Row] {
        var rows = [
            Row(id: "capturedFrames", title: localized("Captured Frames"), value: localizedInteger(snapshot.metrics.capturedFrames)),
            Row(id: "playedFrames", title: localized("Played Frames"), value: localizedInteger(snapshot.metrics.playedFrames)),
            Row(id: "underruns", title: localized("Underrun Events / Frames"), value: underrunDetailLabel),
            Row(id: "droppedFrames", title: localized("Dropped Input / Buffered"), value: droppedFramesLabel),
            Row(id: "saturatedSamples", title: localized("Saturated Samples"), value: localizedInteger(snapshot.metrics.saturatedSamples)),
            Row(id: "deadlineMisses", title: localized("Deadline Misses"), value: deadlineMissesLabel),
            Row(id: "discontinuities", title: localized("Discontinuities"), value: discontinuityLabel)
        ]
        if usesSeparateClockDiagnostics {
            rows += [
                Row(id: "ringGateFailures", title: localized("Ring Gate Failures"), value: localizedInteger(snapshot.metrics.ringGateContentionFailures)),
                Row(id: "bufferedFrames", title: localized("Buffered / Peak"), value: bufferedFramesLabel),
                Row(id: "clockCorrection", title: localized("Clock Correction"), value: playbackRateCorrectionLabel),
                Row(id: "servoBuffer", title: localized("Servo Buffer"), value: servoBufferLabel),
                Row(id: "bridgeLatency", title: localized("Bridge Latency"), value: bridgeLatencyLabel),
                Row(id: "bridgeLatencyRange", title: localized("Bridge Latency Range"), value: bridgeLatencyRangeLabel)
            ]
        }
        return rows
    }

    private func durationPercentilesLabel(
        observations: UInt64,
        p50: UInt64,
        p99: UInt64,
        p999: UInt64,
        p9999: UInt64,
        maximum: UInt64
    ) -> String {
        guard observations > 0 else {
            return localized("No samples")
        }
        let values = [
            durationPercentileValue(p50, observations: observations, minimum: 2),
            durationPercentileValue(p99, observations: observations, minimum: 100),
            durationPercentileValue(p999, observations: observations, minimum: 1_000),
            durationPercentileValue(p9999, observations: observations, minimum: 10_000),
            durationPercentileValue(maximum, observations: observations, minimum: 1)
        ]
        return localized("\(values.joined(separator: " / ")) µs")
    }

    private func durationPercentileValue(
        _ nanoseconds: UInt64,
        observations: UInt64,
        minimum: UInt64
    ) -> String {
        guard observations >= minimum else {
            return "–"
        }
        return localizedDecimal(
            Double(nanoseconds) / 1_000,
            minimumFractionDigits: 2,
            maximumFractionDigits: 2
        )
    }

    private var tapToOutputLatencyLabel: String {
        guard snapshot.metrics.tapToOutputLatencyObservations > 0 else {
            return localized("No samples")
        }
        return localizedLatency(
            milliseconds: snapshot.metrics.averageTapToOutputLatencyNanoseconds / 1_000_000
        )
    }

    private var usesSeparateClockDiagnostics: Bool {
        diagnostics.status.routeMode == .compatibility
            || diagnostics.status.routeMode == .headsetCompatibility
    }

    private var tailCompletionSlackLabel: String {
        let timing = snapshot.metrics.renderTiming
        guard timing.tailCompletionObservations > 0 else {
            return localized("No completed blocks")
        }
        return localized(
            "\(localizedInteger(timing.minimumTailCompletionSlackFrames)) frames, \(localizedInteger(timing.tailDeadlineMisses)) misses"
        )
    }

    private var diagnosticsResetLabel: String {
        diagnostics.observation.resetAt?.formatted(date: .abbreviated, time: .standard)
            ?? localized("Unknown")
    }

    private var observationDurationLabel: String {
        diagnosticDurationLabel(diagnostics.observation.observationDurationSeconds)
    }

    private var runtimeDurationLabel: String {
        guard let startedAt = diagnostics.observation.runtimeStartedAt else {
            return localized("Not running")
        }
        let duration = diagnosticDurationLabel(
            diagnostics.observation.runtimeDurationSeconds
        )
        return localized(
            "\(duration), since \(startedAt.formatted(date: .omitted, time: .standard))"
        )
    }

    private func diagnosticDurationLabel(_ seconds: Double) -> String {
        let total = max(Int(seconds.rounded(.down)), 0)
        if total < 60 {
            return localized("\(total) seconds")
        }
        if total < 3_600 {
            return localized("\(total / 60) min \(total % 60) sec")
        }
        return localized(
            "\(total / 3_600) hr \((total % 3_600) / 60) min \(total % 60) sec"
        )
    }

    private var underrunDetailLabel: String {
        localized(
            "\(localizedInteger(snapshot.metrics.playbackUnderrunEvents)) / \(localizedInteger(snapshot.metrics.playbackUnderrunFrames))"
        )
    }

    private var droppedFramesLabel: String {
        localized(
            "\(localizedInteger(snapshot.metrics.droppedInputFrames)) / \(localizedInteger(snapshot.metrics.droppedBufferedFrames))"
        )
    }

    private var deadlineMissesLabel: String {
        localized(
            "\(localizedInteger(snapshot.metrics.renderDeadlineMisses)) total, \(localizedInteger(snapshot.metrics.callbackStartStarvations)) start, \(localizedInteger(snapshot.metrics.renderOverruns)) render"
        )
    }

    private var discontinuityLabel: String {
        localized(
            "\(localizedInteger(snapshot.metrics.inputTimestampDiscontinuities)) input, \(localizedInteger(snapshot.metrics.outputTimestampDiscontinuities)) output, \(localizedInteger(snapshot.metrics.pairedTimestampDiscontinuities)) paired, \(localizedInteger(snapshot.metrics.qualifyingPairedTimestampDiscontinuities)) qualifying"
        )
    }

    private var bufferedFramesLabel: String {
        localized(
            "\(localizedInteger(snapshot.metrics.currentBufferedFrames)) / \(localizedInteger(snapshot.metrics.maximumPlaybackBufferedFrames)) frames"
        )
    }

    private var lastRecoveryLabel: String {
        guard let reason = diagnostics.recovery.lastReason,
              let date = diagnostics.recovery.lastRecoveryAt else {
            return localized("None")
        }
        return localized(
            "\(recoveryReasonLabel(reason)), \(date.formatted(date: .omitted, time: .standard))"
        )
    }

    private func recoveryReasonLabel(_ reason: SettingsAudioRecoveryReason) -> String {
        switch reason {
        case .renderStall:
            localized("render stall")
        case .deadlineMisses:
            localized("deadline misses")
        case .timestampDiscontinuity:
            localized("timestamp discontinuity")
        case .headsetInstability:
            localized("headset instability")
        case .playbackUnderrun:
            localized("playback underrun")
        case .adaptiveRenderFailure:
            localized("adaptive render failure")
        }
    }

    private func callbackSizeHistogramLabel(
        _ observations: [SettingsAudioCallbackSizeObservationDTO]
    ) -> String {
        let values = observations.compactMap { observation -> String? in
            guard observation.observations > 0 else {
                return nil
            }
            let frameSize = observation.frameCount.map(localizedInteger)
                ?? localized("Other")
            return "\(frameSize): \(localizedInteger(observation.observations))"
        }
        return values.isEmpty ? localized("No samples") : values.joined(separator: ", ")
    }

    private var callbackPeaksLabel: String {
        localized(
            "\(localizedInteger(snapshot.metrics.maximumCaptureCallbackFrames)) / \(localizedInteger(snapshot.metrics.maximumPlaybackCallbackFrames)) frames"
        )
    }

    private var timestampJumpLabel: String {
        guard snapshot.metrics.inputTimestampDiscontinuities > 0
                || snapshot.metrics.outputTimestampDiscontinuities > 0 else {
            return localized("No samples")
        }
        let input = localizedDecimal(
            snapshot.metrics.lastInputTimestampJumpFrames,
            minimumFractionDigits: 1,
            maximumFractionDigits: 1,
            signed: true
        )
        let output = localizedDecimal(
            snapshot.metrics.lastOutputTimestampJumpFrames,
            minimumFractionDigits: 1,
            maximumFractionDigits: 1,
            signed: true
        )
        return localized("\(input) input / \(output) output frames")
    }

    private var hostIntervalErrorLabel: String {
        guard snapshot.metrics.inputTimestampDiscontinuities > 0
                || snapshot.metrics.outputTimestampDiscontinuities > 0 else {
            return localized("No samples")
        }
        let input = localizedDecimal(
            Double(snapshot.metrics.lastInputHostIntervalErrorNanoseconds) / 1_000,
            minimumFractionDigits: 2,
            maximumFractionDigits: 2,
            signed: true
        )
        let output = localizedDecimal(
            Double(snapshot.metrics.lastOutputHostIntervalErrorNanoseconds) / 1_000,
            minimumFractionDigits: 2,
            maximumFractionDigits: 2,
            signed: true
        )
        return localized("\(input) input / \(output) output µs")
    }

    private var timestampJumpIntervalLabel: String {
        guard snapshot.metrics.timestampJumpIntervalObservations > 0 else {
            return localized("No samples")
        }
        return minAverageMaxMilliseconds(
            minimum: snapshot.metrics.minimumTimestampJumpIntervalNanoseconds,
            average: snapshot.metrics.averageTimestampJumpIntervalNanoseconds,
            maximum: snapshot.metrics.maximumTimestampJumpIntervalNanoseconds
        )
    }

    private var inputAgeLabel: String {
        guard snapshot.metrics.callbackTimingObservations > 0 else {
            return localized("No samples")
        }
        return minAverageMaxMilliseconds(
            minimum: snapshot.metrics.minimumInputAgeNanoseconds,
            average: snapshot.metrics.averageInputAgeNanoseconds,
            maximum: snapshot.metrics.maximumInputAgeNanoseconds
        )
    }

    private var outputLeadLabel: String {
        guard snapshot.metrics.callbackTimingObservations > 0 else {
            return localized("No samples")
        }
        return minAverageMaxMilliseconds(
            minimum: snapshot.metrics.minimumOutputLeadNanoseconds,
            average: snapshot.metrics.averageOutputLeadNanoseconds,
            maximum: snapshot.metrics.maximumOutputLeadNanoseconds
        )
    }

    private func minAverageMaxMilliseconds(
        minimum: UInt64,
        average: Double,
        maximum: UInt64
    ) -> String {
        let values = [Double(minimum), average, Double(maximum)].map {
            localizedDecimal(
                $0 / 1_000_000,
                minimumFractionDigits: 2,
                maximumFractionDigits: 2
            )
        }
        return localized("\(values.joined(separator: " / ")) ms")
    }

    private var observedAndActiveRateLabel: String {
        let observed = frequencyOrUnknown(diagnostics.route.observedDeviceSampleRate)
        let active = frequencyOrUnknown(diagnostics.route.activeDeviceSampleRate)
        return localized("\(observed) / \(active)")
    }

    private var processingRateLabel: String {
        frequencyOrUnknown(diagnostics.route.processingSampleRate)
    }

    private func frequencyOrUnknown(_ sampleRate: Double) -> String {
        sampleRate > 0 ? localizedFrequency(sampleRate) : localized("Unknown")
    }

    private var nativeOutputStreamLabel: String {
        diagnostics.route.nativeOutputStreamIndex.map {
            localized("Stream \($0 + 1)")
        } ?? localized("Unavailable")
    }

    private func streamChannelCountsLabel(_ counts: [Int]) -> String {
        guard !counts.isEmpty else {
            return localized("Unavailable")
        }
        return counts.map(localizedInteger).joined(separator: " + ")
    }

    private var aggregateStreamCountsLabel: String {
        let input = streamChannelCountsLabel(
            diagnostics.route.aggregateInputStreamChannelCounts
        )
        let output = streamChannelCountsLabel(
            diagnostics.route.aggregateOutputStreamChannelCounts
        )
        return localized("\(input) / \(output)")
    }

    private var routeBufferSizesLabel: String {
        let physical = optionalFrameCount(diagnostics.route.physicalDeviceBufferFrameSize)
        let aggregate = optionalFrameCount(diagnostics.route.aggregateBufferFrameSize)
        return localized("\(physical) / \(aggregate)")
    }

    private var physicalSafetyOffsetsLabel: String {
        safetyOffsetsLabel(
            input: diagnostics.route.physicalInputSafetyOffsetFrames,
            output: diagnostics.route.physicalOutputSafetyOffsetFrames
        )
    }

    private var aggregateSafetyOffsetsLabel: String {
        safetyOffsetsLabel(
            input: diagnostics.route.aggregateInputSafetyOffsetFrames,
            output: diagnostics.route.aggregateOutputSafetyOffsetFrames
        )
    }

    private func safetyOffsetsLabel(input: UInt32?, output: UInt32?) -> String {
        localized("\(optionalFrameCount(input)) / \(optionalFrameCount(output))")
    }

    private func optionalFrameCount(_ frames: UInt32?) -> String {
        frames.map(localizedFrameCount) ?? localized("Unavailable")
    }

    private var bridgeLatencyLabel: String {
        localizedLatency(
            milliseconds: playbackFramesToMilliseconds(
                snapshot.metrics.averagePlaybackBufferedFrames,
                bufferSampleRate: snapshot.metrics.playbackBufferSampleRate,
                fallbackSampleRate: snapshot.currentOutputSampleRate
            )
        )
    }

    private var bridgeLatencyRangeLabel: String {
        let minimum = playbackFramesToMilliseconds(
            Double(snapshot.metrics.minimumPlaybackBufferedFrames),
            bufferSampleRate: snapshot.metrics.playbackBufferSampleRate,
            fallbackSampleRate: snapshot.currentOutputSampleRate
        )
        let maximum = playbackFramesToMilliseconds(
            Double(snapshot.metrics.maximumPlaybackBufferedFrames),
            bufferSampleRate: snapshot.metrics.playbackBufferSampleRate,
            fallbackSampleRate: snapshot.currentOutputSampleRate
        )
        return localized(
            "\(localizedLatency(milliseconds: minimum)) to \(localizedLatency(milliseconds: maximum))"
        )
    }

    private var playbackRateCorrectionLabel: String {
        let correction = localizedDecimal(
            snapshot.metrics.playbackRateCorrectionPPM,
            minimumFractionDigits: 1,
            maximumFractionDigits: 1,
            signed: true
        )
        return localized("\(correction) ppm")
    }

    private var servoBufferLabel: String {
        let occupancy = localizedDecimal(
            snapshot.metrics.filteredPlaybackOccupancyFrames,
            minimumFractionDigits: 1,
            maximumFractionDigits: 1
        )
        let target = localizedInteger(snapshot.metrics.playbackOccupancyTargetFrames)
        return localized("\(occupancy) / \(target) frames")
    }
}

struct OutputDiagnosticsSheet: View {
    var report: OutputDiagnosticsReport
    var onReset: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedSectionID = OutputDiagnosticsReport.SectionID.observation
    @State private var didCopy = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text(localized("Stats for Nerds"))
                    .font(.headline)
                    .padding(.horizontal, 14)
                    .padding(.top, 16)

                List(report.sections, selection: $selectedSectionID) { section in
                    Label(section.title, systemImage: section.symbol)
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
            .frame(width: 190)
            .background(.regularMaterial)

            Divider()

            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    if let section = selectedSection {
                        OutputDiagnosticsSectionView(section: section)
                            .id(section.id)
                    }
                }

                Divider()

                HStack(spacing: 10) {
                    Button {
                        copyReport()
                    } label: {
                        Label(didCopy ? localized("Copied") : localized("Copy as Text"), systemImage: didCopy ? "checkmark" : "doc.on.doc")
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .accessibilityHint(Text(localized("Copies every section to the clipboard")))

                    Button(localized("Reset Metrics")) {
                        onReset()
                    }

                    Spacer()

                    Button(localized("Done")) {
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                }
                .controlSize(.large)
                .padding(16)
                .task(id: didCopy) {
                    guard didCopy else { return }
                    try? await Task.sleep(for: .seconds(2))
                    didCopy = false
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 760, idealWidth: 820, minHeight: 520, idealHeight: 580)
    }

    private var selectedSection: OutputDiagnosticsReport.Section? {
        report.sections.first { $0.id == selectedSectionID }
    }

    private func copyReport() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report.text, forType: .string)
        didCopy = true
    }
}

private struct OutputDiagnosticsSectionView: View {
    let section: OutputDiagnosticsReport.Section

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(section.title)
                .font(.title3.weight(.semibold))
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 0) {
                ForEach(section.rows) { row in
                    if row.id != section.rows[0].id {
                        Divider()
                            .gridCellUnsizedAxes(.horizontal)
                    }
                    GridRow {
                        Text(row.title)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text(row.value)
                            .font(.body.monospacedDigit())
                            .multilineTextAlignment(.trailing)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .accessibilityLabel(row.title)
                            .accessibilityValue(row.value)
                    }
                    .padding(.vertical, 9)
                }
            }
            .padding(.horizontal, 12)
            .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            }
            if let note = section.note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}
