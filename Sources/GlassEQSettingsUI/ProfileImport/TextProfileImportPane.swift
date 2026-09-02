import AppKit
import GlassEQCore
import GlassEQProfileImport
import GlassEQSettingsIPC
import SwiftUI

struct TextProfileImportPane: View {
    var currentProfile: EQProfile
    var isReadOnly: Bool
    var model: ProfileImportModel
    var onImport: (SettingsImportFormat, String, String) async -> String?
    var onImportParsedProfile: (EQProfile) async -> String?
    var onChooseImportFiles: (SettingsFileImportMode) async -> SettingsFileImportChoice

    @Environment(\.dismiss) private var dismiss
    @State private var profileName = localized("Imported Profile")
    @State private var text = ""
    @State private var importedFilename: String?
    @State private var importedImpulseResponse: ImportedImpulseResponse?
    @State private var importedStereoTextPair: ImportedStereoTextPair?
    @State private var isLoadingFile = false
    @State private var didCopyCurrentProfile = false
    @State private var fileSelectionTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(localized("Import a profile"))
                        .font(.title2.weight(.semibold))
                    Text(localized("Select EqualizerAPO, AutoEq, or REW settings, or a WAV impulse response. You can also paste text settings below."))
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button {
                        chooseFiles(.single)
                    } label: {
                        Label(localized("Select a File…"), systemImage: "doc.badge.plus")
                    }
                    .controlSize(.large)
                    .disabled(isLoadingFile || model.isBusy)
                    .help(localized("Opens EQ settings or a WAV impulse response"))

                    Button {
                        chooseFiles(.stereoPair)
                    } label: {
                        Label(localized("Select L/R Files…"), systemImage: "rectangle.split.2x1")
                    }
                    .controlSize(.large)
                    .disabled(isLoadingFile || model.isBusy)
                    .help(localized("Imports separate text or mono WAV files for the left and right channels"))

                    if let importedFilename {
                        Text(importedFilename)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    Button {
                        copyCurrentProfile()
                    } label: {
                        Label(
                            didCopyCurrentProfile
                                ? localized("Copied")
                                : localized("Copy Current Profile"),
                            systemImage: didCopyCurrentProfile ? "checkmark" : "doc.on.doc"
                        )
                    }
                    .help(localized("Copies the selected profile as EqualizerAPO text"))
                }

                Text(localized("Profile name"))
                    .font(.headline)
                TextField(localized("Imported Profile"), text: $profileName)
                    .textFieldStyle(.roundedBorder)
                if let nameError = profileNameValidation.errorMessage {
                    Text(nameError)
                        .font(.caption)
                        .foregroundStyle(Color(nsColor: .systemRed))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(Text(localized("Profile name error: \(nameError)")))
                }

                if let imported = Binding($importedImpulseResponse) {
                    ImportedImpulseResponseSummary(imported: imported)
                } else if let imported = Binding($importedStereoTextPair) {
                    ImportedStereoTextPairSummary(imported: imported)
                } else {
                    HStack {
                        Text(localized("Settings"))
                            .font(.headline)
                        Spacer()
                        if !text.isEmpty {
                            Text(detectedFormatLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    TextEditor(text: $text)
                        .font(.system(.body, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(9)
                        .frame(minHeight: 230)
                        .background(
                            Color(nsColor: .textBackgroundColor).opacity(0.72),
                            in: .rect(cornerRadius: 10)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                                .allowsHitTesting(false)
                        }
                }

                if let errorMessage = model.errorMessage {
                    ProfileImportErrorLabel(message: errorMessage)
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Divider()

            ProfileImportFooter(
                note: footerText,
                canImport: canImport,
                model: model,
                onImport: importSelectedProfile
            )
        }
        .task(id: didCopyCurrentProfile) {
            guard didCopyCurrentProfile else {
                return
            }
            try? await Task.sleep(for: .seconds(2))
            didCopyCurrentProfile = false
        }
        .onDisappear {
            fileSelectionTask?.cancel()
            model.cancel()
        }
    }

    private var profileNameValidation: ProfileImportNameValidation {
        ProfileImportNameValidation(profileName)
    }

    private var hasImportSource: Bool {
        importedImpulseResponse != nil
            || importedStereoTextPair != nil
            || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canImport: Bool {
        !isReadOnly
            && profileNameValidation.errorMessage == nil
            && hasImportSource
            && !isLoadingFile
    }

    private var footerText: String {
        if importedStereoTextPair != nil
            || importedImpulseResponse?.sourceFileCount == 2 {
            return localized("GlassEQ will combine the files as one stereo profile. Existing profiles are not changed.")
        }
        if importedImpulseResponse != nil {
            return localized("The imported impulse response keeps its original phase. Existing profiles are not changed.")
        }
        return localized("Disabled filters are ignored. Existing profiles are not changed.")
    }

    private var detectedFormatLabel: String {
        switch ImportedEQTextDetector.format(for: text) {
        case .autoEQ:
            localized("Detected: AutoEq / EqualizerAPO")
        case .rew:
            localized("Detected: REW")
        }
    }

    private func copyCurrentProfile() {
        do {
            let exported = try EQProfileTextExporter.exportEqualizerAPO(currentProfile)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(exported, forType: .string)
            didCopyCurrentProfile = true
            model.errorMessage = nil
        } catch {
            didCopyCurrentProfile = false
            model.errorMessage = error.localizedDescription
        }
    }

    private func chooseFiles(_ mode: SettingsFileImportMode) {
        guard !isLoadingFile, !model.isBusy else {
            return
        }
        isLoadingFile = true
        model.errorMessage = nil
        fileSelectionTask = Task {
            let choice = await onChooseImportFiles(mode)
            guard !Task.isCancelled else {
                return
            }
            isLoadingFile = false
            if let selection = choice.selection {
                apply(selection)
            } else if choice.shouldClearExistingSelection {
                clearFileSelection()
            }
            model.errorMessage = choice.errorMessage
        }
    }

    private func apply(_ selection: SettingsFileImportSelectionDTO) {
        clearFileSelection()

        switch selection {
        case let .text(suggestedName, filename, importedText):
            profileName = suggestedName
            importedFilename = filename
            text = importedText

        case let .impulseResponse(profile, channels, sourceFileCount):
            guard let importedChannels = ImportedImpulseResponse.Channels(channels) else {
                model.errorMessage = ImpulseResponseWAVImportError
                    .unsupportedChannelCount(channels.count)
                    .localizedDescription
                return
            }
            profileName = profile.name
            importedFilename = sourceFileCount == 2
                ? localized("2 files selected")
                : importedChannels.first.filename
            importedImpulseResponse = ImportedImpulseResponse(
                profile: profile,
                channels: importedChannels,
                sourceFileCount: sourceFileCount
            )

        case let .stereoText(profile, leftFilename, rightFilename):
            profileName = profile.name
            importedFilename = localized("2 files selected")
            importedStereoTextPair = ImportedStereoTextPair(
                profile: profile,
                leftFilename: leftFilename,
                rightFilename: rightFilename
            )
        }
    }

    private func clearFileSelection() {
        importedFilename = nil
        importedImpulseResponse = nil
        importedStereoTextPair = nil
        text = ""
    }

    private func importSelectedProfile() {
        guard case let .valid(name) = profileNameValidation else {
            return
        }
        if let importedImpulseResponse {
            importParsedProfile(importedImpulseResponse.profile, named: name)
        } else if let importedStereoTextPair {
            importParsedProfile(importedStereoTextPair.profile, named: name)
        } else {
            let importedText = text
            let format = ImportedEQTextDetector.format(for: importedText).settingsImportFormat
            model.commit(
                preparing: { importedText },
                { text in await onImport(format, name, text) },
                onSuccess: { dismiss() }
            )
        }
    }

    private func importParsedProfile(_ importedProfile: EQProfile, named name: String) {
        var profile = importedProfile
        profile.name = name
        model.commit(
            preparing: { profile },
            { profile in await onImportParsedProfile(profile) },
            onSuccess: { dismiss() }
        )
    }
}

private extension ProfileImportNameValidation {
    var errorMessage: String? {
        switch self {
        case .valid:
            nil
        case .empty:
            localized("Enter a profile name.")
        case let .tooLong(byteCount, maximum):
            localized("Profile name is \(byteCount) UTF-8 bytes; the maximum is \(maximum).")
        }
    }
}

private extension ImportedEQTextFormat {
    var settingsImportFormat: SettingsImportFormat {
        switch self {
        case .autoEQ:
            .autoEQ
        case .rew:
            .rew
        }
    }
}
