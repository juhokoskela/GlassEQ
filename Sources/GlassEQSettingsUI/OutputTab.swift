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
                if snapshot.offersPlaybackHandback || snapshot.equalizer.needsRecoveryAction {
                    PlaybackRecoveryActions(controller: controller)
                } else if snapshot.equalizer != .unavailable {
                    Toggle(
                        localized("Equalizer"),
                        isOn: Binding(
                            get: { snapshot.equalizer == .on }, set: controller.setEqualizerEnabled
                        )
                    )
                    .toggleStyle(.switch)
                    .accessibilityHint(Text(localized("Turns equalization on or off for all outputs and profiles")))
                }
                LabeledContent(
                    snapshot.currentOutputUID.isEmpty ? localized("Last Known Output") : localized("Current Output"),
                    value: snapshot.currentOutputName)
            }

            Section {
                let outputUID = snapshot.currentOutputUID
                Picker(
                    localized("Profile for This Output"),
                    selection: Binding(
                        get: { snapshot.currentOutputMappedProfileID },
                        set: { controller.setOutputAssignment(outputUID: outputUID, profileID: $0) }
                    )
                ) {
                    Text(localized("Use Fallback")).tag(nil as UUID?)
                    Divider()
                    ForEach(snapshot.profiles) { profile in Text(profile.name).tag(Optional(profile.id)) }
                }
                .disabled(outputUID.isEmpty)
                Picker(
                    localized("Fallback Profile"),
                    selection: Binding(
                        get: { snapshot.fallbackProfileID }, set: controller.setFallbackProfile
                    )
                ) {
                    ForEach(snapshot.profiles) { profile in Text(profile.name).tag(profile.id) }
                }
            } header: {
                Text(localized("Profiles"))
            } footer: {
                Text(
                    localized(
                        "A new fallback takes effect the next time GlassEQ starts or reconnects an unassigned output."))
            }
            .disabled(controller.isEditingLocked)

            if snapshot.isRunning {
                Section {
                    LabeledContent(localized("Audio Buffer")) {
                        Picker(localized("Audio Buffer"), selection: $controller.aggregateBufferMode) {
                            Text(localized("Automatic")).tag(SettingsAggregateBufferMode.automatic)
                            Text(localized("16 frames")).tag(SettingsAggregateBufferMode.frames16)
                            Text(localized("32 frames")).tag(SettingsAggregateBufferMode.frames32)
                            Text(localized("64 frames")).tag(SettingsAggregateBufferMode.frames64)
                            Text(localized("128 frames")).tag(SettingsAggregateBufferMode.frames128)
                        }
                        .labelsHidden()

                        if snapshot.aggregateBuffer.mode == .automatic,
                            snapshot.aggregateBuffer.automaticFrameSize > snapshot.aggregateBuffer.defaultFrameSize
                        {
                            Button(localized("Try \(snapshot.aggregateBuffer.defaultFrameSize) Frames Again")) {
                                controller.retryAutomaticAggregateBuffer()
                            }
                        } else if let fixedFrameSize = snapshot.aggregateBuffer.mode.fixedFrameSize,
                            snapshot.currentOutputBufferFrameSize > fixedFrameSize
                        {
                            Button(localized("Try \(fixedFrameSize) Frames Again")) {
                                controller.setAggregateBufferMode(snapshot.aggregateBuffer.mode)
                            }
                        }
                    }

                    .disabled(!snapshot.aggregateBuffer.isAvailable)

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
                    if snapshot.isRunning || snapshot.aggregateBuffer.isAvailable {
                        Text(
                            outputBufferExplanation(
                                aggregateBuffer: snapshot.aggregateBuffer,
                                currentFrameSize: snapshot.currentOutputBufferFrameSize
                            ))
                    }
                }
            }

            Section {
                LabeledContent(localized("Status"), value: statusSummary)
                if snapshot.isRunning {
                    LabeledContent(localized("Active Profile"), value: snapshot.activeProfileName)
                    LabeledContent(localized("Buffer"), value: bufferSummary)
                    LabeledContent(localized("Added Latency"), value: outputAddedLatencyLabel(snapshot))
                    LabeledContent(
                        localized("Underrun Events"),
                        value: snapshot.metrics.playbackUnderrunEvents == 0
                            ? localized("None")
                            : localizedInteger(snapshot.metrics.playbackUnderrunEvents)
                    )
                }
            } header: {
                Text(localized("Engine Status"))
            } footer: {
                if snapshot.equalizer != .off && !snapshot.offersPlaybackHandback
                    && !snapshot.equalizer.needsRecoveryAction
                {
                    Text(snapshot.statusMessage)
                }
            }

            Section {
                HStack {
                    Button(localized("Export Library…")) { controller.exportLibrary() }
                        .disabled(!snapshot.profileStoreProtection.canExportLibrary)
                    Button(localized("Import Backup…")) { controller.chooseLibraryBackup() }
                        .disabled(controller.isEditingLocked)
                    Button(localized("Show Backups in Finder")) { controller.showLibraryBackups() }
                }
                .disabled(controller.isLibraryTransferInProgress)
            } header: {
                Text(localized("Profile Library"))
            } footer: {
                if let message = controller.libraryMessage { Text(message) }
            }

            Section {
                Button(localized("About GlassEQ and Support Report…")) { controller.showAbout() }
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
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $isShowingDiagnostics) {
            OutputDiagnosticsSheet(
                report: OutputDiagnosticsReport(snapshot: snapshot),
                onReset: controller.resetDiagnostics
            )
        }
        .sheet(
            isPresented: Binding(
                get: { controller.libraryImportPreview != nil },
                set: { isPresented in
                    if !isPresented {
                        controller.cancelLibraryImport()
                    }
                }
            )
        ) {
            if let preview = controller.libraryImportPreview {
                LibraryImportSheet(
                    preview: preview,
                    hasUnsavedDraft: controller.hasUnsavedDraft,
                    onMerge: { controller.applyLibraryImport(.merge) },
                    onReplace: { controller.applyLibraryImport(.replace) },
                    onCancel: controller.cancelLibraryImport
                )
            }
        }
    }

    private var diagnostics: SettingsAudioDiagnosticsDTO {
        snapshot.metrics.diagnostics
    }

    private var statusSummary: String {
        switch diagnostics.status.health {
        case .stopped:
            return snapshot.equalizer == .off ? localized("Equalizer off") : localized("Stopped")
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

    private var bufferSummary: String {
        outputBufferSummary(
            aggregateBuffer: snapshot.aggregateBuffer,
            currentFrameSize: snapshot.currentOutputBufferFrameSize
        )
    }
}

struct PlaybackRecoveryActions: View {
    var controller: SettingsController

    var body: some View {
        let snapshot = controller.snapshot
        VStack(alignment: .leading, spacing: 8) {
            Label(
                snapshot.offersPlaybackHandback ? localized("Output is muted") : localized("Equalizer needs attention"),
                systemImage: snapshot.offersPlaybackHandback ? "speaker.slash" : "exclamationmark.triangle"
            )
            .fontWeight(.semibold)
            .foregroundStyle(.orange)
            Text(snapshot.statusMessage)
                .foregroundStyle(.secondary)
            HStack {
                Button(localized("Retry Audio Engine")) { controller.retryAudioEngine() }
                if snapshot.equalizer == .permissionDenied {
                    Button(localized("Open Privacy Settings")) { controller.openPrivacySettings() }
                }
                if snapshot.offersPlaybackHandback {
                    Button(localized("Play Without EQ")) { controller.playWithoutEQ() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
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
            "Automatic starts at \(aggregateBuffer.defaultFrameSize) frames for this output and increases the buffer after repeated interruptions."
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
