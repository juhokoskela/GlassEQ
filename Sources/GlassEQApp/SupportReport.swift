import AppKit
import GlassEQSettingsUI
import SwiftUI
import UniformTypeIdentifiers

struct SupportReportView: View {
    let model: GlassEQAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
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
                        "Read it before sending. It includes profile and output names, app state, and recent events, which may contain filenames or error details. It excludes EQ settings, impulse responses, and license keys. Send it to contact@juhokoskela.fi or attach it to a GitHub issue."
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
                    Task { await save() }
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

    }

    private static var architecture: String {
        #if arch(arm64)
            "arm64"
        #else
            "x86_64"
        #endif
    }

    private func regenerate() {
        let generatedAt = Date()
        let snapshot = model.supportSnapshot()
        text = [
            "GlassEQ support report · \(generatedAt.formatted(.iso8601))",
            AppBuildInfo.current.versionLine,
            "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Architecture: \(Self.architecture)",
            "Playback: \(model.supportPlaybackDescription)",
            "Output: \(snapshot.currentOutputName)",
            "Active profile: \(snapshot.activeProfileName)",
            "Status: \(snapshot.statusMessage)",
            OutputDiagnosticsReport(snapshot: snapshot).supportText,
            "Recent status changes\n\(model.lifecycleLog.text)",
        ].joined(separator: "\n\n")
        saveFailure = nil
    }

    private func save() async {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "GlassEQ Support Report.txt"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        do {
            try await Self.write(text, to: url)
            saveFailure = nil

        } catch {
            saveFailure = localized("Could not save: \(error.localizedDescription)")
        }
    }
    @concurrent private static func write(_ text: String, to url: URL) async throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}
