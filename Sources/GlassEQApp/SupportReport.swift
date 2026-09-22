import AppKit
import Darwin
import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Everything the support report prints. The model fills it from state it already owns; nothing
/// here is a profile's contents, an impulse response, a device UID, or a license credential.
struct SupportReportInputs {
    var generatedAt: Date
    var build: AppBuildInfo
    var operatingSystemVersion: String
    var architecture: String
    var modelIdentifier: String?
    var launchedWithDebugFlag: Bool
    var lifecycleState: String
    var statusMessage: String
    var isRunning: Bool
    var onboardingIsComplete: Bool
    var audioCaptureState: String
    var launchAtLoginStatus: String
    var licenseSummary: String?
    var previousRun: LaunchRecord?
    var profileCount: Int
    var activeProfileName: String
    var activeProfileMode: String
    var activeProfileIsBypassed: Bool
    var currentOutputIsMapped: Bool
    var fallbackProfileName: String
    var audioDiagnostics: String
    var recentEvents: String
}

enum SupportReport {
    static func text(_ inputs: SupportReportInputs) -> String {
        let dateFormat = Date.ISO8601FormatStyle(includingFractionalSeconds: false)
        var lines = [
            "# GlassEQ support report",
            "Generated: \(inputs.generatedAt.formatted(dateFormat))",
            "",
            "## App",
            "Version: \(inputs.build.versionLine)",
            "Launched with \(LifecycleLog.debugFlag): \(yesNo(inputs.launchedWithDebugFlag))",
            "",
            "## Mac",
            "macOS: \(inputs.operatingSystemVersion)",
            "Architecture: \(inputs.architecture)",
        ]
        if let modelIdentifier = inputs.modelIdentifier {
            lines.append("Model identifier: \(modelIdentifier)")
        }
        lines += [
            "",
            "## State",
            "Lifecycle: \(inputs.lifecycleState)",
            "Processing: \(yesNo(inputs.isRunning))",
            "Status: \(inputs.statusMessage)",
            "Setup guide completed: \(yesNo(inputs.onboardingIsComplete))",
            "Audio capture step: \(inputs.audioCaptureState)",
            "Launch at Login: \(inputs.launchAtLoginStatus)",
        ]
        if let licenseSummary = inputs.licenseSummary {
            lines.append("License: \(licenseSummary)")
        }
        if let previousRun = inputs.previousRun {
            let version = previousRun.version ?? "unknown version"
            lines.append(
                "Previous run: did not quit cleanly (started \(previousRun.startedAt.formatted(dateFormat)), \(version))"
            )
        } else {
            lines.append("Previous run: quit cleanly")
        }
        lines += [
            "",
            "## Profiles",
            "Profiles in library: \(inputs.profileCount)",
            "Active profile: \(inputs.activeProfileName) (\(inputs.activeProfileMode)\(inputs.activeProfileIsBypassed ? ", disabled" : ""))",
            "Current output has a mapped profile: \(yesNo(inputs.currentOutputIsMapped))",
            "Fallback profile: \(inputs.fallbackProfileName)",
            "",
            "## Audio diagnostics",
            inputs.audioDiagnostics,
            "",
            "## Recent events",
            inputs.recentEvents.isEmpty ? "None recorded" : inputs.recentEvents,
        ]
        return lines.joined(separator: "\n")
    }

    static func suggestedFilename(generatedAt: Date) -> String {
        let stamp = generatedAt.formatted(
            Date.ISO8601FormatStyle(dateSeparator: .dash, timeSeparator: .omitted, timeZone: .current)
                .year().month().day().dateTimeSeparator(.standard).time(includingFractionalSeconds: false)
        )
        return "GlassEQ Support Report \(stamp).txt"
    }

    static var architecture: String {
        #if arch(arm64)
            "arm64"
        #else
            "x86_64"
        #endif
    }

    static var modelIdentifier: String? {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 1 else {
            return nil
        }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else {
            return nil
        }
        return String(bytes: buffer.prefix { $0 != 0 }, encoding: .utf8)
    }

    private static func yesNo(_ value: Bool) -> String {
        value ? "yes" : "no"
    }
}

struct SupportReportView: View {
    let model: GlassEQAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var generatedAt = Date()
    @State private var didCopy = false
    @State private var saveFailure: String?

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(localized("Support Report"))
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(
                    localized(
                        "Read it before sending. It names your output device and lists recent app events, but never your profiles, imported files, or license key. Send it to contact@juhokoskela.fi or attach it to a GitHub issue."
                    )
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)

            Divider()

            ScrollView {
                Text(verbatim: text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .background(Color.macOSControlBackground)
            .accessibilityLabel(Text(localized("Report text")))

            Divider()

            HStack(spacing: 10) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    didCopy = true
                } label: {
                    Label(
                        didCopy ? localized("Copied") : localized("Copy"),
                        systemImage: didCopy ? "checkmark" : "doc.on.doc"
                    )
                    .contentTransition(.symbolEffect(.replace))
                }
                .accessibilityHint(Text(localized("Copies the whole report to the clipboard")))

                Button(localized("Save…")) {
                    save()
                }
                .accessibilityHint(Text(localized("Saves the report as a text file you choose")))

                Button(localized("Refresh")) {
                    regenerate()
                }

                if let saveFailure {
                    Text(saveFailure)
                        .font(.caption)
                        .foregroundStyle(Color.macOSSystemRed)
                        .lineLimit(2)
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
        .frame(minWidth: 640, idealWidth: 720, minHeight: 480, idealHeight: 600)
        .background(Color.macOSWindowBackground)
        .onAppear {
            regenerate()
        }
        .onChange(of: model.supportReportPresentationGeneration) {
            regenerate()
        }
    }

    private func regenerate() {
        generatedAt = Date()
        text = SupportReport.text(model.supportReportInputs(generatedAt: generatedAt))
        saveFailure = nil
    }

    private func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = SupportReport.suggestedFilename(generatedAt: generatedAt)
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        do {
            try Data(text.utf8).write(to: url, options: .atomic)
            saveFailure = nil
            model.lifecycleLog.record("Support report saved")
        } catch {
            saveFailure = localized("Could not save: \(error.localizedDescription)")
        }
    }
}
