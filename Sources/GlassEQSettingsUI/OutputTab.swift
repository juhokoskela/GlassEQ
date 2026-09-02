import GlassEQSettingsIPC
import SwiftUI

extension SettingsAggregateBufferMode {
    var fixedFrameSize: UInt32? {
        switch self {
        case .automatic:
            nil
        case .frames16:
            16
        case .frames32:
            32
        case .frames64:
            64
        }
    }
}

struct OutputTab: View {
    @Bindable var controller: SettingsController
    @State private var isShowingDiagnostics = false

    private var snapshot: SettingsSnapshot {
        controller.snapshot
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(localized("Current Output"))
                        .font(.headline)
                    Text(snapshot.currentOutputName)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .cardPanel(padding: 16)

                VStack(alignment: .leading, spacing: 10) {
                    Text(localized("Audio Buffer"))
                        .font(.headline)
                    Picker(localized("Audio Buffer"), selection: $controller.aggregateBufferMode) {
                        Text(localized("Automatic")).tag(SettingsAggregateBufferMode.automatic)
                        Text(localized("16 frames")).tag(SettingsAggregateBufferMode.frames16)
                        Text(localized("32 frames")).tag(SettingsAggregateBufferMode.frames32)
                        Text(localized("64 frames")).tag(SettingsAggregateBufferMode.frames64)
                    }
                    .labelsHidden()
                    .disabled(!snapshot.aggregateBuffer.isAvailable)

                    Text(aggregateBufferExplanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if snapshot.aggregateBuffer.mode == .automatic,
                       snapshot.aggregateBuffer.automaticFrameSize > 16 {
                        Button(localized("Retry 16 Frames")) {
                            controller.retryAutomaticAggregateBuffer()
                        }
                        .controlSize(.large)
                    } else if let fixedFrameSize = snapshot.aggregateBuffer.mode.fixedFrameSize,
                              snapshot.currentOutputBufferFrameSize > fixedFrameSize {
                        Button(localized("Retry \(fixedFrameSize) Frames")) {
                            controller.setAggregateBufferMode(snapshot.aggregateBuffer.mode)
                        }
                        .controlSize(.large)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .cardPanel(padding: 16)

                VStack(alignment: .leading, spacing: 10) {
                    Text(localized("Profile Mapping"))
                        .font(.headline)
                    LabeledContent(localized("Mapped Profile"), value: mappedProfileName)
                    HStack {
                        Button(localized("Use for This Output")) {
                            controller.useDraftForCurrentOutput()
                        }
                        .disabled(controller.isProfileStoreProtected || !controller.hasCurrentOutput)
                        .controlSize(.large)

                        Button(localized("Set as Fallback")) {
                            controller.setFallbackToDraft()
                        }
                        .disabled(controller.isProfileStoreProtected)
                        .controlSize(.large)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .cardPanel(padding: 16)

                VStack(alignment: .leading, spacing: 10) {
                    Text(localized("Setup Guide"))
                        .font(.headline)
                    Text(localized("Walk through system audio capture permission, Launch at Login, and how GlassEQ follows your output."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        controller.showSetupGuide()
                    } label: {
                        Label(localized("Open Setup Guide"), systemImage: "questionmark.circle")
                    }
                    .controlSize(.large)
                    .accessibilityHint(Text(localized("Reopens the first-launch walkthrough in GlassEQ")))
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .cardPanel(padding: 16)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)

            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(localized("Engine Status"))
                        .font(.headline)
                    LabeledContent(localized("Status"), value: statusSummary)
                    LabeledContent(localized("Mode"), value: routeModeSummary)
                    LabeledContent(localized("Current Output"), value: snapshot.currentOutputName)
                    LabeledContent(localized("Active Profile"), value: snapshot.activeProfileName)
                    LabeledContent(localized("Buffer"), value: bufferSummary)
                    LabeledContent(localized("Added Latency"), value: outputAddedLatencyLabel(snapshot))
                    LabeledContent(
                        localized("Underrun Events"),
                        value: snapshot.metrics.playbackUnderrunEvents == 0
                            ? localized("None")
                            : localizedInteger(snapshot.metrics.playbackUnderrunEvents)
                    )
                    Text(snapshot.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button(localized("Retry Audio Engine")) {
                            controller.retryAudioEngine()
                        }
                        .controlSize(.large)

                        Button(localized("Open Privacy Settings")) {
                            controller.openPrivacySettings()
                        }
                        .controlSize(.large)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .cardPanel(padding: 16)

                VStack(alignment: .leading, spacing: 10) {
                    Text(localized("Stats for Nerds"))
                        .font(.headline)
                    Text(localized("Render timing percentiles, reliability counters, recovery history, and the Core Audio route behind this output."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        isShowingDiagnostics = true
                    } label: {
                        Label(localized("Show Stats"), systemImage: "waveform.path.ecg.rectangle")
                    }
                    .controlSize(.large)
                    .accessibilityHint(Text(localized("Opens detailed audio engine diagnostics")))
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .cardPanel(padding: 16)
                .sheet(isPresented: $isShowingDiagnostics) {
                    OutputDiagnosticsSheet(
                        report: OutputDiagnosticsReport(snapshot: snapshot),
                        onReset: controller.resetDiagnostics
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var mappedProfileName: String {
        guard let profileID = snapshot.currentOutputMappedProfileID,
              let profile = snapshot.profiles.first(where: { $0.id == profileID }) else {
            return localized("Fallback")
        }
        return profile.name
    }

    private var aggregateBufferExplanation: String {
        guard snapshot.aggregateBuffer.isAvailable else {
            return localized("This route uses GlassEQ's compatibility audio path.")
        }
        if snapshot.aggregateBuffer.mode == .automatic {
            return localized(
                "Automatic uses the smallest buffer proven reliable for this device stream and sample rate. It is currently \(snapshot.aggregateBuffer.automaticFrameSize) frames."
            )
        }
        if let fixedFrameSize = snapshot.aggregateBuffer.mode.fixedFrameSize,
           snapshot.currentOutputBufferFrameSize > fixedFrameSize {
            return localized(
                "The fixed \(fixedFrameSize)-frame setting became unstable. GlassEQ is temporarily using \(snapshot.currentOutputBufferFrameSize) frames for this session."
            )
        }
        return localized(
            "A fixed buffer keeps this preference. GlassEQ may temporarily use a safer buffer if repeated deadline misses continue after a rebuild."
        )
    }

    private var diagnostics: SettingsAudioDiagnosticsDTO {
        snapshot.metrics.diagnostics
    }

    private var statusSummary: String {
        switch diagnostics.status.health {
        case .stopped:
            return localized("Stopped")
        case .stable:
            return diagnostics.status.isUsingSaferBuffer
                ? localized("Stable, using safer buffer")
                : localized("Stable")
        case .recovering:
            return localized("Recovering")
        case .needsAttention:
            return localized("Needs attention")
        }
    }

    private var routeModeSummary: String {
        switch diagnostics.status.routeMode {
        case .unavailable:
            return localized("Unavailable")
        case .lowLatency:
            return localized("Low-latency path")
        case .compatibility:
            return localized("Compatibility path")
        case .headsetCompatibility:
            return localized("Headset compatibility path")
        }
    }

    private var bufferSummary: String {
        outputBufferSummary(
            aggregateBuffer: snapshot.aggregateBuffer,
            currentFrameSize: snapshot.currentOutputBufferFrameSize
        )
    }
}

func outputBufferSummary(
    aggregateBuffer: SettingsAggregateBufferDTO,
    currentFrameSize: UInt32
) -> String {
    guard aggregateBuffer.isAvailable else {
        guard currentFrameSize > 0 else {
            return localized("Unavailable")
        }
        return localized("\(currentFrameSize) frames, compatibility path")
    }
    guard let selected = aggregateBuffer.mode.fixedFrameSize else {
        return localized(
            "Automatic, \(aggregateBuffer.automaticFrameSize) frames active"
        )
    }
    if currentFrameSize != selected {
        return localized(
            "\(selected) selected, \(currentFrameSize) frames active"
        )
    }
    return localized("\(selected) frames")
}
