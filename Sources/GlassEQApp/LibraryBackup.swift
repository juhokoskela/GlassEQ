import AppKit
import Foundation
import GlassEQCore
import GlassEQSettingsIPC
import GlassEQSettingsUI
import UniformTypeIdentifiers

/// A library the user chose to import, kept until they pick merge or replace, or cancel.
struct PendingLibraryImport: Equatable {
    let backup: ProfileLibraryBackup
    let filename: String
}

enum LibraryBackupFile {
    static let automaticBackupsDirectoryName = "Backups"
    static let automaticBackupsToKeep = 10

    static func suggestedFilename(createdAt: Date) -> String {
        let stamp = createdAt.formatted(
            Date.ISO8601FormatStyle(dateSeparator: .dash, timeSeparator: .omitted, timeZone: .current)
                .year().month().day().dateTimeSeparator(.standard).time(includingFractionalSeconds: false)
        )
        return "GlassEQ Library \(stamp).json"
    }

    static func automaticBackupsDirectory(besideStoreAt storeURL: URL) -> URL {
        storeURL.deletingLastPathComponent().appending(path: automaticBackupsDirectoryName, directoryHint: .isDirectory)
    }

    /// Removes the oldest automatic backups beyond the retained count. Names sort by their
    /// timestamp, so lexical order is chronological.
    static func pruneAutomaticBackups(in directory: URL, keeping count: Int = automaticBackupsToKeep) {
        guard
            let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
                .filter({ $0.hasPrefix("GlassEQ Library ") && $0.hasSuffix(".json") })
                .sorted()
        else {
            return
        }
        for name in names.dropLast(count) {
            try? FileManager.default.removeItem(at: directory.appending(path: name))
        }
    }
}

extension SettingsLibraryImportPreviewDTO {
    init(pending: PendingLibraryImport, summary: ProfileLibraryMergeSummary) {
        self.init(
            filename: pending.filename,
            createdAt: pending.backup.createdAt,
            appVersion: pending.backup.appVersion,
            profileCount: pending.backup.profileStore.profiles.count,
            outputMappingCount: pending.backup.profileStore.outputMappings.count,
            hasBufferPreferences: pending.backup.bufferPreferences != nil,
            mergeAddedProfiles: summary.addedProfiles,
            mergeCopiedProfiles: summary.copiedProfiles,
            mergeUnchangedProfiles: summary.unchangedProfiles,
            mergeAddedMappings: summary.addedMappings,
            mergeSkippedMappings: summary.skippedMappings,
            mergeExceedsProfileLimit: summary.exceedsProfileLimit
        )
    }
}

/// The open and save panels behind library export and import. They run in the main app because
/// only it may write the chosen file, and they are a seam so tests can answer them.
@MainActor
protocol LibraryBackupPanelPresenting {
    func chooseExportDestination(suggestedName: String) async throws -> URL?
    func chooseBackupToImport() async throws -> URL?
}

@MainActor
struct LiveLibraryBackupPanels: LibraryBackupPanelPresenting {
    func chooseExportDestination(suggestedName: String) async throws -> URL? {
        try await SettingsFileImportPicker.presentingPanel {
            let panel = NSSavePanel()
            panel.title = localized("Export Library")
            panel.message = localized(
                "Saves every profile with its impulse response, the output assignments, the fallback, and buffer preferences."
            )
            panel.prompt = localized("Export")
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = suggestedName
            panel.canCreateDirectories = true
            let response = try await SettingsFileImportPicker.waitForPanelResponse(
                begin: { completion in panel.begin(completionHandler: completion) },
                cancel: { panel.cancel(nil) }
            )
            return response == .OK ? panel.url : nil
        }
    }

    func chooseBackupToImport() async throws -> URL? {
        try await SettingsFileImportPicker.presentingPanel {
            let panel = NSOpenPanel()
            panel.title = localized("Import Library")
            panel.message = localized(
                "Choose a library exported by GlassEQ. You choose between adding to and replacing yours next.")
            panel.prompt = localized("Open")
            panel.allowedContentTypes = [.json]
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = false
            let response = try await SettingsFileImportPicker.waitForPanelResponse(
                begin: { completion in panel.begin(completionHandler: completion) },
                cancel: { panel.cancel(nil) }
            )
            return response == .OK ? panel.url : nil
        }
    }
}

/// Answers the two library commands that need a panel, or nil for every other command.
@MainActor
func libraryBackupPanelResponse(
    for command: SettingsCommand,
    model: GlassEQAppModel,
    panels: any LibraryBackupPanelPresenting = LiveLibraryBackupPanels()
) async throws -> SettingsCommandResponse? {
    switch command {
    case .exportLibrary:
        try model.beginSettingsCommand()
        defer {
            model.finishSettingsCommand()
        }
        let backup = try model.makeLibraryBackup()
        let data = try ProfileLibraryBackupCodec.encode(backup)
        guard
            let url = try await panels.chooseExportDestination(
                suggestedName: LibraryBackupFile.suggestedFilename(createdAt: backup.createdAt))
        else {
            return SettingsCommandResponse()
        }
        try data.write(to: url, options: .atomic)
        model.lifecycleLog.record("Library exported: \(backup.profileStore.profiles.count) profiles")
        return SettingsCommandResponse(
            libraryMessage: localized(
                "Saved \(backup.profileStore.profiles.count) profiles to \(url.lastPathComponent)."))

    case .chooseLibraryBackup:
        try model.beginSettingsCommand()
        defer {
            model.finishSettingsCommand()
        }
        try model.ensureProfileStoreWritable()
        guard let url = try await panels.chooseBackupToImport() else {
            return SettingsCommandResponse()
        }
        let backup: ProfileLibraryBackup
        do {
            backup = try ProfileLibraryBackupCodec.read(from: url)
        } catch let error as ProfileLibraryBackupError {
            throw SettingsCommandFailure(message: error.localizedDescription)
        }
        let preview = model.stageLibraryImport(backup, filename: url.lastPathComponent)
        return SettingsCommandResponse(libraryImportPreview: preview)

    default:
        return nil
    }
}
