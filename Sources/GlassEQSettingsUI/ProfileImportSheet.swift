import AppKit
import GlassEQCore
import GlassEQSettingsIPC
import SwiftUI
import UniformTypeIdentifiers

private enum ProfileImportRoute: String, CaseIterable, Identifiable {
    case autoEQ
    case text

    var id: String { rawValue }

    var title: String {
        switch self {
        case .autoEQ:
            localized("Search AutoEq")
        case .text:
            localized("Import a File")
        }
    }

    var symbol: String {
        switch self {
        case .autoEQ:
            "headphones"
        case .text:
            "doc.text"
        }
    }
}

struct SettingsFileImportChoice {
    var selection: SettingsFileImportSelectionDTO?
    var errorMessage: String?

    var shouldClearExistingSelection: Bool {
        selection == nil && errorMessage != nil
    }
}

enum ProfileImportNameValidation: Equatable {
    case valid(trimmedName: String)
    case empty
    case tooLong(byteCount: Int, maximum: Int)

    init(_ name: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            self = .empty
            return
        }

        let byteCount = trimmedName.utf8.count
        let maximum = ProfilePersistence.maxProfileNameUTF8Bytes
        guard byteCount <= maximum else {
            self = .tooLong(byteCount: byteCount, maximum: maximum)
            return
        }
        self = .valid(trimmedName: trimmedName)
    }

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

private enum ProfileImportTaskPhase {
    case idle
    case preparing
    case committing
}

struct ProfileImportSheet: View {
    var currentProfile: EQProfile
    var isReadOnly: Bool
    var onImport: (SettingsImportFormat, String, String) async -> String?
    var onImportParsedProfile: (EQProfile) async -> String?
    var onChooseImportFiles: (SettingsFileImportMode) async -> SettingsFileImportChoice

    @Environment(\.dismiss) private var dismiss
    @State private var route = ProfileImportRoute.autoEQ
    @State private var isImportCommitInFlight = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text(localized("Import Profile"))
                    .font(.headline)
                    .padding(.horizontal, 14)
                    .padding(.top, 16)

                List(selection: $route) {
                    ForEach(ProfileImportRoute.allCases) { route in
                        Label(route.title, systemImage: route.symbol)
                            .tag(route)
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .disabled(isImportCommitInFlight)
            }
            .frame(width: 190)
            .background(.regularMaterial)

            Divider()

            Group {
                switch route {
                case .autoEQ:
                    AutoEQImportPane(
                        isReadOnly: isReadOnly,
                        isCommitInFlight: $isImportCommitInFlight,
                        onImport: onImport,
                        onCancel: { dismiss() },
                        onImported: { dismiss() }
                    )
                case .text:
                    TextProfileImportPane(
                        currentProfile: currentProfile,
                        isReadOnly: isReadOnly,
                        isCommitInFlight: $isImportCommitInFlight,
                        onImport: onImport,
                        onImportParsedProfile: onImportParsedProfile,
                        onChooseImportFiles: onChooseImportFiles,
                        onCancel: { dismiss() },
                        onImported: { dismiss() }
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 760, idealWidth: 820, minHeight: 520, idealHeight: 580)
        .interactiveDismissDisabled(isImportCommitInFlight)
    }
}

private struct AutoEQImportPane: View {
    var isReadOnly: Bool
    @Binding var isCommitInFlight: Bool
    var onImport: (SettingsImportFormat, String, String) async -> String?
    var onCancel: () -> Void
    var onImported: () -> Void

    @State private var entries: [AutoEQCatalogueEntry] = []
    @State private var searchText = ""
    @State private var selection: AutoEQCatalogueEntry?
    @State private var profileKind = AutoEQProfileKind.responseCurve
    @State private var isLoading = true
    @State private var importPhase = ProfileImportTaskPhase.idle
    @State private var errorMessage: String?
    @State private var catalogueTask: Task<Void, Never>?
    @State private var importTask: Task<Void, Never>?

    private let client = AutoEQRepositoryClient()

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(localized("Find your headphones"))
                        .font(.title2.weight(.semibold))
                    Text(localized("Search AutoEq's recommended results and add one directly to GlassEQ."))
                        .foregroundStyle(.secondary)
                }

                TextField(localized("Headphone model"), text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .accessibilityHint(Text(localized("Searches the AutoEq headphone catalogue")))

                results

                if let selection {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(localized("How should GlassEQ import this result?"))
                            .font(.headline)

                        Picker(localized("Profile type"), selection: $profileKind) {
                            VStack(alignment: .leading) {
                                Text(localized("Convolution"))
                                Text(localized("Full minimum-phase correction"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .tag(AutoEQProfileKind.responseCurve)

                            VStack(alignment: .leading) {
                                Text(localized("Parametric filters"))
                                Text(localized("Ten editable filters"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .tag(AutoEQProfileKind.parametric)
                        }
                        .pickerStyle(.radioGroup)
                        .labelsHidden()

                        Text(localized("Selected: \(selection.name) · \(selection.detail)"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .padding(14)
                    .background(
                        Color(nsColor: .controlBackgroundColor).opacity(0.7),
                        in: .rect(cornerRadius: 12)
                    )
                }

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Color(nsColor: .systemRed))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Divider()

            HStack {
                Text(localized("Profiles are downloaded from the official AutoEq repository."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(localized("Cancel")) {
                    cancelPendingTasks()
                    onCancel()
                }
                    .keyboardShortcut(.cancelAction)
                    .disabled(importPhase == .committing)
                Button {
                    importSelection()
                } label: {
                    if importPhase != .idle {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text(localized("Add Profile"))
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection == nil || isReadOnly || importPhase != .idle)
            }
            .padding(16)
        }
        .task {
            await loadCatalogue()
        }
        .onDisappear {
            cancelPendingTasks()
        }
        .onChange(of: searchText) { _, _ in
            selection = nil
        }
    }

    @ViewBuilder
    private var results: some View {
        if isLoading {
            VStack(spacing: 10) {
                ProgressView()
                Text(localized("Loading AutoEq catalogue…"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 170)
        } else if entries.isEmpty {
            ContentUnavailableView {
                Label(localized("AutoEq is unavailable"), systemImage: "wifi.exclamationmark")
            } description: {
                Text(errorMessage ?? localized("GlassEQ could not load the headphone catalogue."))
            } actions: {
                Button(localized("Try Again")) {
                    catalogueTask?.cancel()
                    catalogueTask = Task { @MainActor in
                        await loadCatalogue()
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 170)
        } else if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ContentUnavailableView {
                Label(localized("Search AutoEq"), systemImage: "magnifyingglass")
            } description: {
                Text(localized("Type a manufacturer or model name to search \(entries.count) recommended profiles."))
            }
            .frame(maxWidth: .infinity, minHeight: 170)
        } else if filteredEntries.isEmpty {
            ContentUnavailableView.search(text: searchText)
                .frame(maxWidth: .infinity, minHeight: 170)
        } else {
            List(filteredEntries, selection: $selection) { entry in
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.name)
                        .lineLimit(1)
                    Text(entry.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .tag(entry)
                .padding(.vertical, 3)
            }
            .listStyle(.inset)
            .frame(minHeight: 170)
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
    }

    private var filteredEntries: [AutoEQCatalogueEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return []
        }
        return entries.filter {
            $0.name.localizedStandardContains(query)
                || $0.source.localizedStandardContains(query)
        }
    }

    @MainActor
    private func loadCatalogue() async {
        isLoading = true
        errorMessage = nil
        defer {
            isLoading = false
        }
        do {
            entries = try await client.catalogue()
        } catch is CancellationError {
            return
        } catch where Task.isCancelled {
            return
        } catch {
            entries = []
            errorMessage = error.localizedDescription
        }
    }

    private func importSelection() {
        guard let selection, importPhase == .idle else {
            return
        }
        setImportPhase(.preparing)
        errorMessage = nil
        let kind = profileKind
        importTask = Task { @MainActor in
            do {
                try Task.checkCancellation()
                let text = try await client.profileText(for: selection, kind: kind)
                try Task.checkCancellation()
                setImportPhase(.committing)
                if let importError = await onImport(.autoEQ, selection.name, text) {
                    guard !Task.isCancelled else {
                        return
                    }
                    errorMessage = importError
                    setImportPhase(.idle)
                } else {
                    guard !Task.isCancelled else {
                        return
                    }
                    setImportPhase(.idle)
                    onImported()
                }
            } catch is CancellationError {
                setImportPhase(.idle)
            } catch where Task.isCancelled {
                setImportPhase(.idle)
            } catch {
                errorMessage = error.localizedDescription
                setImportPhase(.idle)
            }
        }
    }

    private func setImportPhase(_ phase: ProfileImportTaskPhase) {
        importPhase = phase
        isCommitInFlight = phase == .committing
    }

    private func cancelPendingTasks() {
        catalogueTask?.cancel()
        importTask?.cancel()
    }
}

private struct TextProfileImportPane: View {
    var currentProfile: EQProfile
    var isReadOnly: Bool
    @Binding var isCommitInFlight: Bool
    var onImport: (SettingsImportFormat, String, String) async -> String?
    var onImportParsedProfile: (EQProfile) async -> String?
    var onChooseImportFiles: (SettingsFileImportMode) async -> SettingsFileImportChoice
    var onCancel: () -> Void
    var onImported: () -> Void

    @State private var profileName = localized("Imported Profile")
    @State private var text = ""
    @State private var importedFilename: String?
    @State private var importedImpulseResponse: ImportedImpulseResponse?
    @State private var importedStereoTextPair: ImportedStereoTextPair?
    @State private var isLoadingFile = false
    @State private var importPhase = ProfileImportTaskPhase.idle
    @State private var didCopyCurrentProfile = false
    @State private var errorMessage: String?
    @State private var fileSelectionTask: Task<Void, Never>?
    @State private var importTask: Task<Void, Never>?

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
                        chooseFile()
                    } label: {
                        Label(localized("Select a File…"), systemImage: "doc.badge.plus")
                    }
                    .controlSize(.large)
                    .disabled(isLoadingFile || importPhase != .idle)
                    .help(localized("Opens EQ settings or a WAV impulse response"))

                    Button {
                        chooseSeparatePair()
                    } label: {
                        Label(localized("Select L/R Files…"), systemImage: "rectangle.split.2x1")
                    }
                    .controlSize(.large)
                    .disabled(isLoadingFile || importPhase != .idle)
                    .help(localized("Imports separate text or mono WAV files for the left and right channels"))

                    if let importedFilename {
                        Text(importedFilename)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    Button {
                        do {
                            let exported = try EQProfileTextExporter.exportEqualizerAPO(currentProfile)
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(exported, forType: .string)
                            didCopyCurrentProfile = true
                            errorMessage = nil
                        } catch {
                            didCopyCurrentProfile = false
                            errorMessage = error.localizedDescription
                        }
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

                if let importedImpulseResponse {
                    impulseResponseSummary(importedImpulseResponse)
                } else if let importedStereoTextPair {
                    stereoTextPairSummary(importedStereoTextPair)
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
                        }
                }

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Color(nsColor: .systemRed))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Divider()

            HStack {
                Text(footerText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(localized("Cancel")) {
                    cancelPendingTasks()
                    onCancel()
                }
                    .keyboardShortcut(.cancelAction)
                    .disabled(importPhase == .committing)
                Button {
                    importSelectedProfile()
                } label: {
                    if importPhase != .idle {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text(localized("Add Profile"))
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    isReadOnly
                        || profileNameValidation.errorMessage != nil
                        || (importedImpulseResponse == nil
                            && importedStereoTextPair == nil
                            && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        || isLoadingFile
                        || importPhase != .idle
                )
            }
            .padding(16)
        }
        .onDisappear {
            cancelPendingTasks()
        }
    }

    private var profileNameValidation: ProfileImportNameValidation {
        ProfileImportNameValidation(profileName)
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

    private func impulseResponseSummary(_ imported: ImportedImpulseResponse) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(localized("Impulse response"), systemImage: "waveform")
                    .font(.headline)
                Spacer()
                if imported.channelCount == 2 {
                    Button(localized("Swap L/R")) {
                        importedImpulseResponse?.swapStereoChannels()
                    }
                }
            }
            if imported.channelCount == 1,
               let channel = imported.channels.first {
                LabeledContent(localized("Length"), value: localized("\(channel.frameCount) taps"))
                LabeledContent(localized("Channels"), value: localized("Mono"))
            } else if imported.channels.count == 2 {
                LabeledContent(
                    localized("Left"),
                    value: channelDescription(imported.channels[0])
                )
                LabeledContent(
                    localized("Right"),
                    value: channelDescription(imported.channels[1])
                )
            }
            LabeledContent(
                localized("Sample rate"),
                value: localizedSampleRate(imported.sampleRate)
            )
            Text(localized("GlassEQ will convolve audio with these samples directly; it will not reconstruct or normalize the file."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 230, alignment: .topLeading)
        .background(
            Color(nsColor: .controlBackgroundColor).opacity(0.7),
            in: .rect(cornerRadius: 10)
        )
    }

    private func stereoTextPairSummary(_ imported: ImportedStereoTextPair) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(localized("Separate left and right settings"), systemImage: "slider.horizontal.3")
                    .font(.headline)
                Spacer()
                Button(localized("Swap L/R")) {
                    importedStereoTextPair?.swapChannels()
                }
            }
            LabeledContent(localized("Left"), value: imported.leftFilename)
            LabeledContent(localized("Right"), value: imported.rightFilename)
            LabeledContent(localized("Profile type"), value: imported.profile.mode.importPairTitle)
            Text(localized("GlassEQ parsed each file independently and will keep its filters and preamp on the assigned channel."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 230, alignment: .topLeading)
        .background(
            Color(nsColor: .controlBackgroundColor).opacity(0.7),
            in: .rect(cornerRadius: 10)
        )
    }

    private func channelDescription(_ channel: ImportedImpulseResponse.Channel) -> String {
        localized("\(channel.filename) · \(channel.frameCount) taps")
    }

    private var detectedFormatLabel: String {
        switch ImportedEQTextDetector.format(for: text) {
        case .autoEQ:
            localized("Detected: AutoEq / EqualizerAPO")
        case .rew:
            localized("Detected: REW")
        }
    }

    private func localizedSampleRate(_ sampleRate: Double) -> String {
        if sampleRate >= 1_000 {
            return String(format: "%.1f kHz", sampleRate / 1_000)
        }
        return String(format: "%.0f Hz", sampleRate)
    }

    private func chooseFile() {
        chooseFiles(.single)
    }

    private func chooseSeparatePair() {
        chooseFiles(.stereoPair)
    }

    private func chooseFiles(_ mode: SettingsFileImportMode) {
        guard !isLoadingFile, importPhase == .idle else {
            return
        }
        isLoadingFile = true
        errorMessage = nil
        fileSelectionTask = Task { @MainActor in
            defer {
                isLoadingFile = false
            }
            guard !Task.isCancelled else {
                return
            }
            let choice = await onChooseImportFiles(mode)
            guard !Task.isCancelled else {
                return
            }
            if let selection = choice.selection {
                apply(selection)
            } else if choice.shouldClearExistingSelection {
                clearFileSelection()
            }
            errorMessage = choice.errorMessage
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
            profileName = profile.name
            importedFilename = sourceFileCount == 2
                ? localized("2 files selected")
                : channels.first?.filename
            importedImpulseResponse = ImportedImpulseResponse(
                profile: profile,
                channels: channels.map {
                    ImportedImpulseResponse.Channel(
                        filename: $0.filename,
                        frameCount: $0.frameCount,
                        sampleRate: $0.sampleRate
                    )
                },
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
        if let importedImpulseResponse {
            importParsedProfile(importedImpulseResponse.profile)
        } else if let importedStereoTextPair {
            importParsedProfile(importedStereoTextPair.profile)
        } else {
            importText()
        }
    }

    private func importParsedProfile(_ importedProfile: EQProfile) {
        guard case let .valid(name) = profileNameValidation,
              importPhase == .idle else {
            return
        }
        var profile = importedProfile
        profile.name = name
        setImportPhase(.committing)
        errorMessage = nil
        importTask = Task { @MainActor in
            guard !Task.isCancelled else {
                return
            }
            if let importError = await onImportParsedProfile(profile) {
                guard !Task.isCancelled else {
                    return
                }
                errorMessage = importError
                setImportPhase(.idle)
            } else {
                guard !Task.isCancelled else {
                    return
                }
                setImportPhase(.idle)
                onImported()
            }
        }
    }

    private func importText() {
        guard case let .valid(name) = profileNameValidation,
              importPhase == .idle else {
            return
        }
        let importedText = text
        let format = ImportedEQTextDetector.format(for: importedText)
        setImportPhase(.committing)
        errorMessage = nil
        importTask = Task { @MainActor in
            guard !Task.isCancelled else {
                return
            }
            if let importError = await onImport(format, name, importedText) {
                guard !Task.isCancelled else {
                    return
                }
                errorMessage = importError
                setImportPhase(.idle)
            } else {
                guard !Task.isCancelled else {
                    return
                }
                setImportPhase(.idle)
                onImported()
            }
        }
    }

    private func cancelPendingTasks() {
        fileSelectionTask?.cancel()
        importTask?.cancel()
    }

    private func setImportPhase(_ phase: ProfileImportTaskPhase) {
        importPhase = phase
        isCommitInFlight = phase == .committing
    }
}

func readImportedTextFile(
    _ url: URL,
    maximumBytes: Int = ProfileImportLimits.default.maxUTF8Bytes
) throws -> String {
    let hasAccess = url.startAccessingSecurityScopedResource()
    defer {
        if hasAccess {
            url.stopAccessingSecurityScopedResource()
        }
    }

    let values = try url.resourceValues(forKeys: [.fileSizeKey])
    if let fileSize = values.fileSize,
       fileSize > maximumBytes {
        throw ProfileImportError.inputTooLarge(
            byteCount: fileSize,
            maximum: maximumBytes
        )
    }
    let handle = try FileHandle(forReadingFrom: url)
    defer {
        try? handle.close()
    }
    return try readBoundedImportedText(
        from: handle,
        knownFileSize: values.fileSize,
        maximumBytes: maximumBytes
    )
}

func readBoundedImportedText(
    from handle: FileHandle,
    knownFileSize: Int?,
    maximumBytes: Int
) throws -> String {
    if let knownFileSize, knownFileSize > maximumBytes {
        throw ProfileImportError.inputTooLarge(
            byteCount: knownFileSize,
            maximum: maximumBytes
        )
    }

    var data = Data()
    data.reserveCapacity(min(max(knownFileSize ?? 0, 0), maximumBytes))
    while true {
        try Task.checkCancellation()
        let remainingCapacity = maximumBytes - data.count
        let readCount = min(64 * 1_024, remainingCapacity + 1)
        guard let chunk = try handle.read(upToCount: readCount), !chunk.isEmpty else {
            break
        }
        data.append(chunk)
        guard data.count <= maximumBytes else {
            throw ProfileImportError.inputTooLarge(
                byteCount: data.count,
                maximum: maximumBytes
            )
        }
    }

    guard let text = String(data: data, encoding: .utf8) else {
        throw CocoaError(.fileReadInapplicableStringEncoding)
    }
    return text
}

enum StereoTextPairImportError: Error, LocalizedError {
    case filesMustUseSameFormat
    case filesMustDescribeLinkedChannels
    case profileTypesDoNotMatch(left: EQMode, right: EQMode)
    case missingConvolutionSource

    var errorDescription: String? {
        switch self {
        case .filesMustUseSameFormat:
            "Choose either two text files or two mono WAV files for separate left and right import."
        case .filesMustDescribeLinkedChannels:
            "Each text file must describe one linked channel. Files that already contain separate left and right settings cannot be paired again."
        case let .profileTypesDoNotMatch(left, right):
            "The files contain different profile types: \(left.importPairTitle) and \(right.importPairTitle)."
        case .missingConvolutionSource:
            "One of the text files does not contain a response curve."
        }
    }
}

struct ImportedStereoTextPair: Sendable {
    var profile: EQProfile
    var leftFilename: String
    var rightFilename: String

    mutating func swapChannels() {
        let leftPreamp = profile.leftPreampDB
        profile.leftPreampDB = profile.rightPreampDB
        profile.rightPreampDB = leftPreamp

        let leftFilters = profile.leftFilters
        profile.leftFilters = profile.rightFilters
        profile.rightFilters = leftFilters

        let leftConvolution = profile.leftConvolution
        profile.leftConvolution = profile.rightConvolution
        profile.rightConvolution = leftConvolution
        swap(&leftFilename, &rightFilename)
    }
}

enum StereoTextPairImporter {
    static func load(leftURL: URL, rightURL: URL) throws -> ImportedStereoTextPair {
        let left = try importProfile(from: leftURL)
        let right = try importProfile(from: rightURL)
        guard left.channelMode == .linked,
              right.channelMode == .linked else {
            throw StereoTextPairImportError.filesMustDescribeLinkedChannels
        }
        guard left.mode == right.mode else {
            throw StereoTextPairImportError.profileTypesDoNotMatch(
                left: left.mode,
                right: right.mode
            )
        }

        let name = inferredStereoProfileName(
            leftURL: leftURL,
            rightURL: rightURL,
            fallback: "Imported Stereo EQ"
        )
        let profile: EQProfile
        if left.mode == .convolution {
            guard let leftSource = left.convolution,
                  let rightSource = right.convolution else {
                throw StereoTextPairImportError.missingConvolutionSource
            }
            profile = EQProfile(
                name: name,
                mode: .convolution,
                channelMode: .stereo,
                preampDB: min(left.preampDB, right.preampDB),
                filters: [],
                leftPreampDB: left.preampDB,
                leftFilters: [],
                rightPreampDB: right.preampDB,
                rightFilters: [],
                convolution: nil,
                leftConvolution: leftSource,
                rightConvolution: rightSource
            )
        } else {
            profile = EQProfile(
                name: name,
                mode: left.mode,
                channelMode: .stereo,
                preampDB: min(left.preampDB, right.preampDB),
                filters: [],
                leftPreampDB: left.preampDB,
                leftFilters: left.filters,
                rightPreampDB: right.preampDB,
                rightFilters: right.filters
            )
        }

        return ImportedStereoTextPair(
            profile: profile,
            leftFilename: leftURL.lastPathComponent,
            rightFilename: rightURL.lastPathComponent
        )
    }

    private static func importProfile(from url: URL) throws -> EQProfile {
        let text = try readImportedTextFile(url)
        let name = url.deletingPathExtension().lastPathComponent
        switch ImportedEQTextDetector.format(for: text) {
        case .autoEQ:
            return try EQProfileTextImporter.importAutoEQ(text, profileName: name)
        case .rew:
            return try EQProfileTextImporter.importREW(text, profileName: name)
        }
    }
}

private extension EQMode {
    var importPairTitle: String {
        switch self {
        case .parametric:
            localized("Parametric")
        case .graphic10:
            localized("10-band")
        case .graphic31:
            localized("31-band")
        case .convolution:
            localized("Convolution")
        }
    }
}

// Cancellation handlers may run off-main; the AppKit action is only invoked by a MainActor task.
private final class SettingsFileImportPanelCancellation: @unchecked Sendable {
    private let action: @MainActor () -> Void

    init(_ action: @escaping @MainActor () -> Void) {
        self.action = action
    }

    func cancel() {
        Task { @MainActor in
            action()
        }
    }
}

public enum SettingsFileImportPicker {
    @MainActor
    public static func choose(
        mode: SettingsFileImportMode
    ) async throws -> SettingsFileImportSelectionDTO? {
        let previousApplication = NSWorkspace.shared.frontmostApplication
        NSApplication.shared.activate(ignoringOtherApps: true)
        defer {
            if previousApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                previousApplication?.activate(options: [.activateAllWindows])
            }
        }

        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .wav]
        panel.canChooseDirectories = false

        switch mode {
        case .single:
            panel.title = localized("Import EQ Settings")
            panel.message = localized("Choose EQ settings or a mono or stereo WAV impulse response.")
            panel.prompt = localized("Open")
            panel.allowsMultipleSelection = false
        case .stereoPair:
            panel.title = localized("Import Separate Left and Right Files")
            panel.message = localized("Choose two text files or two mono WAV files. GlassEQ will show their left and right assignment before importing them.")
            panel.prompt = localized("Choose")
            panel.allowsMultipleSelection = true
        }

        let response = try await waitForPanelResponse(
            begin: { completion in
                panel.begin(completionHandler: completion)
            },
            cancel: {
                panel.cancel(nil)
            }
        )
        guard response == .OK else {
            return nil
        }

        let urls = panel.urls
        switch mode {
        case .single:
            guard urls.count == 1 else {
                throw SettingsCommandFailure(message: localized("Select one file to import."))
            }
        case .stereoPair:
            guard urls.count == 2 else {
                throw SettingsCommandFailure(message: localized("Select exactly two files: one for the left channel and one for the right."))
            }
        }

        let loadTask = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let selection = try loadSelection(
                mode: mode,
                urls: urls
            )
            try Task.checkCancellation()
            return selection
        }
        return try await withTaskCancellationHandler {
            let selection = try await loadTask.value
            try Task.checkCancellation()
            return selection
        } onCancel: {
            loadTask.cancel()
        }
    }

    @MainActor
    static func waitForPanelResponse(
        begin: (@escaping (NSApplication.ModalResponse) -> Void) -> Void,
        cancel: @escaping @MainActor () -> Void
    ) async throws -> NSApplication.ModalResponse {
        try Task.checkCancellation()
        let cancellation = SettingsFileImportPanelCancellation(cancel)
        return try await withTaskCancellationHandler {
            let response = await withCheckedContinuation { continuation in
                begin { response in
                    continuation.resume(returning: response)
                }
            }
            try Task.checkCancellation()
            return response
        } onCancel: {
            cancellation.cancel()
        }
    }

    static func loadSelection(
        mode: SettingsFileImportMode,
        urls: [URL]
    ) throws -> SettingsFileImportSelectionDTO {
        switch mode {
        case .single:
            let url = urls[0]
            if url.pathExtension.lowercased() == "wav" {
                return impulseResponseSelection(try ImpulseResponseWAVImporter.load(from: url))
            }
            return .text(
                suggestedName: url.deletingPathExtension().lastPathComponent,
                filename: url.lastPathComponent,
                text: try readImportedTextFile(url)
            )

        case .stereoPair:
            let leftURL = urls[0]
            let rightURL = urls[1]
            let leftIsWAV = leftURL.pathExtension.lowercased() == "wav"
            let rightIsWAV = rightURL.pathExtension.lowercased() == "wav"
            guard leftIsWAV == rightIsWAV else {
                throw StereoTextPairImportError.filesMustUseSameFormat
            }
            if leftIsWAV {
                return impulseResponseSelection(try ImpulseResponseWAVImporter.loadStereoPair(
                    leftURL: leftURL,
                    rightURL: rightURL
                ))
            }
            let imported = try StereoTextPairImporter.load(
                leftURL: leftURL,
                rightURL: rightURL
            )
            return .stereoText(
                profile: imported.profile,
                leftFilename: imported.leftFilename,
                rightFilename: imported.rightFilename
            )
        }
    }

    private static func impulseResponseSelection(
        _ imported: ImportedImpulseResponse
    ) -> SettingsFileImportSelectionDTO {
        .impulseResponse(
            profile: imported.profile,
            channels: imported.channels.map {
                SettingsImpulseResponseChannelDTO(
                    filename: $0.filename,
                    frameCount: $0.frameCount,
                    sampleRate: $0.sampleRate
                )
            },
            sourceFileCount: imported.sourceFileCount
        )
    }
}
