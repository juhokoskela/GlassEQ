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
        case .frames128:
            128
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
        Form {
            Section {
                LabeledContent(localized("Current Output"), value: snapshot.currentOutputName)

                LabeledContent(localized("Audio Buffer")) {
                    Picker(localized("Audio Buffer"), selection: $controller.aggregateBufferMode) {
                        Text(localized("Automatic")).tag(SettingsAggregateBufferMode.automatic)
                        Text(localized("16 frames")).tag(SettingsAggregateBufferMode.frames16)
                        Text(localized("32 frames")).tag(SettingsAggregateBufferMode.frames32)
                        Text(localized("64 frames")).tag(SettingsAggregateBufferMode.frames64)
                        Text(localized("128 frames")).tag(SettingsAggregateBufferMode.frames128)
                    }
                    .labelsHidden()
                    .disabled(!snapshot.aggregateBuffer.isAvailable)

                    if snapshot.aggregateBuffer.mode == .automatic,
                        snapshot.aggregateBuffer.automaticFrameSize > snapshot.aggregateBuffer.defaultFrameSize
                    {
                        Button(localized("Retry \(snapshot.aggregateBuffer.defaultFrameSize) Frames")) {
                            controller.retryAutomaticAggregateBuffer()
                        }
                    } else if let fixedFrameSize = snapshot.aggregateBuffer.mode.fixedFrameSize,
                        snapshot.currentOutputBufferFrameSize > fixedFrameSize
                    {
                        Button(localized("Retry \(fixedFrameSize) Frames")) {
                            controller.setAggregateBufferMode(snapshot.aggregateBuffer.mode)
                        }
                    }
                }

                if shouldShowMacOS27BluetoothBufferNotice(
                    route: diagnostics.route,
                    operatingSystemMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion
                ) {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(localized("macOS 27 Bluetooth audio"), systemImage: "info.circle")
                            .fontWeight(.semibold)
                        Text(
                            localized(
                                "macOS 27 may use a 256-frame buffer for Bluetooth audio even when a smaller size is selected. Retrying may not lower it."
                            )
                        )
                        .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .combine)
                }

                if snapshot.aggregateBuffer.defaultFrameSize > 16 {
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(
                                localized(
                                    "Changing Bluetooth volume from your Mac can briefly delay audio processing. A larger buffer helps absorb those delays."
                                ))
                            Text(localized("On AirPods Pro, adjusting volume using the stems avoided the issue."))
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    } label: {
                        Text(localized("Why a larger buffer?"))
                    }
                }
            } footer: {
                Text(
                    outputBufferExplanation(
                        aggregateBuffer: snapshot.aggregateBuffer,
                        currentFrameSize: snapshot.currentOutputBufferFrameSize
                    ))
            }

            Section(localized("Profile Mapping")) {
                LabeledContent(localized("Mapped Profile"), value: mappedProfileName)
                LabeledContent(controller.draftProfile.name) {
                    Button(localized("Use for This Output")) {
                        controller.useDraftForCurrentOutput()
                    }
                    .disabled(controller.isProfileStoreProtected || !controller.hasCurrentOutput)

                    Button(localized("Set as Fallback")) {
                        controller.setFallbackToDraft()
                    }
                    .disabled(controller.isProfileStoreProtected)
                }
            }

            Section {
                LabeledContent(localized("Status"), value: statusSummary)
                LabeledContent(localized("Mode"), value: routeModeSummary)
                LabeledContent(localized("Active Profile"), value: snapshot.activeProfileName)
                LabeledContent(localized("Buffer"), value: bufferSummary)
                LabeledContent(localized("Added Latency"), value: outputAddedLatencyLabel(snapshot))
                LabeledContent(
                    localized("Underrun Events"),
                    value: snapshot.metrics.playbackUnderrunEvents == 0
                        ? localized("None")
                        : localizedInteger(snapshot.metrics.playbackUnderrunEvents)
                )
                HStack {
                    Button(localized("Retry Audio Engine")) {
                        controller.retryAudioEngine()
                    }
                    Button(localized("Open Privacy Settings")) {
                        controller.openPrivacySettings()
                    }
                }
            } header: {
                Text(localized("Engine Status"))
            } footer: {
                Text(snapshot.statusMessage)
            }

            Section {
                LabeledContent {
                    Button(localized("Open Setup Guide")) {
                        controller.showSetupGuide()
                    }
                    .accessibilityHint(Text(localized("Reopens the first-launch walkthrough in GlassEQ")))
                } label: {
                    Text(localized("Setup Guide"))
                    Text(
                        localized(
                            "Walk through system audio capture permission, Launch at Login, and how GlassEQ follows your output."
                        ))
                }

                LabeledContent {
                    Button(localized("Show Stats")) {
                        isShowingDiagnostics = true
                    }
                    .accessibilityHint(Text(localized("Opens detailed audio engine diagnostics")))
                } label: {
                    Text(localized("Stats for Nerds"))
                    Text(
                        localized(
                            "Render timing percentiles, reliability counters, recovery history, and the Core Audio route behind this output."
                        ))
                }

                LabeledContent {
                    Button(localized("Show Report")) {
                        controller.showSupportReport()
                    }
                    .accessibilityHint(Text(localized("Opens a support report you can review, copy, or save")))
                } label: {
                    Text(localized("Support Report"))
                    Text(
                        localized(
                            "App and macOS versions, engine state, route details, and recent events for a bug report. No profiles or license key."
                        ))
                }

                LabeledContent {
                    Button(localized("Show About")) {
                        controller.showAbout()
                    }
                    .accessibilityHint(Text(localized("Opens the About window in GlassEQ")))
                } label: {
                    Text(localized("About GlassEQ"))
                    Text(localized("Version, license, privacy notes, and credits."))
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $isShowingDiagnostics) {
            OutputDiagnosticsSheet(
                report: OutputDiagnosticsReport(snapshot: snapshot),
                onReset: controller.resetDiagnostics
            )
        }
    }

    private var mappedProfileName: String {
        guard let profileID = snapshot.currentOutputMappedProfileID,
            let profile = snapshot.profiles.first(where: { $0.id == profileID })
        else {
            return localized("Fallback")
        }
        return profile.name
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

func shouldShowMacOS27BluetoothBufferNotice(
    route: SettingsAudioRouteDTO,
    operatingSystemMajorVersion: Int
) -> Bool {
    operatingSystemMajorVersion == 27 && route.isBluetoothTransport == true
}

func outputBufferExplanation(
    aggregateBuffer: SettingsAggregateBufferDTO,
    currentFrameSize: UInt32
) -> String {
    guard aggregateBuffer.isAvailable else {
        return localized("This route uses GlassEQ's compatibility audio path.")
    }
    if aggregateBuffer.mode == .automatic {
        return localized(
            "Automatic starts at \(aggregateBuffer.defaultFrameSize) frames for this output and increases the buffer after repeated interruptions. It is currently \(aggregateBuffer.automaticFrameSize) frames."
        )
    }
    if let fixedFrameSize = aggregateBuffer.mode.fixedFrameSize,
        currentFrameSize > fixedFrameSize
    {
        return localized(
            "The active buffer is \(currentFrameSize) frames. Your \(fixedFrameSize)-frame preference is saved."
        )
    }
    return localized(
        "A fixed buffer keeps this preference. GlassEQ may temporarily use a safer buffer if repeated deadline misses continue after a rebuild."
    )
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
