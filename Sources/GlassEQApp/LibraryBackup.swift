import AppKit
import Foundation
import GlassEQCore
import GlassEQSettingsIPC
import GlassEQSettingsUI
import UniformTypeIdentifiers

/// A library the user chose to import, kept until they pick merge or replace, or cancel.
struct PendingLibraryImport {
    struct Candidate: Sendable {
        let store: ProfileStore
        let prepared: ProfilePersistence.PreparedSave

        init(_ store: ProfileStore) throws {
            self.store = store
            prepared = try ProfilePersistence.PreparedSave(store)
        }
    }

    let replacement: Candidate?
    let addition: Candidate?
    let preview: SettingsLibraryImportPreviewDTO
    let generation: Int

    @concurrent static func prepare(
        _ backup: ProfileLibraryBackup, filename: String, current: ProfileStore, generation: Int
    ) async throws -> Self {
        var incoming = backup.profileStore
        incoming.fixedBuffers = incoming.fixedBuffers ?? []
        var replacement: Candidate?
        var replaceFailure: String?
        do { replacement = try Candidate(incoming) } catch { replaceFailure = error.localizedDescription }
        var addition: Candidate?
        var summary: ProfileLibraryMergeSummary?
        var mergeFailure: String?
        do {
            let merged = try ProfileLibraryMerge.merge(current: current, incoming: incoming)
            addition = try Candidate(merged.store)
            summary = merged.summary
        } catch {
            mergeFailure = error.localizedDescription
        }
        let preview = SettingsLibraryImportPreviewDTO(
            filename: filename, createdAt: backup.createdAt, appVersion: backup.appVersion,
            profileCount: incoming.profiles.count, outputMappingCount: incoming.outputMappings.count,
            hasBufferPreferences: !(incoming.fixedBuffers ?? []).isEmpty, merge: summary, mergeFailure: mergeFailure,
            replaceFailure: replaceFailure)
        return Self(replacement: replacement, addition: addition, preview: preview, generation: generation)
    }
}

enum LibraryBackupFile {
    static let automaticBackupsDirectoryName = "Backups"
    static let automaticBackupsToKeep = 10
    private static let automaticPrefix = "GlassEQ Before Replace "

    static func suggestedFilename(createdAt: Date, identifier: UUID? = nil) -> String {
        let stamp = createdAt.formatted(
            Date.ISO8601FormatStyle(dateSeparator: .dash, timeSeparator: .omitted, timeZone: .gmt)
                .year().month().day().dateTimeSeparator(.standard).time(includingFractionalSeconds: false)
        )
        let suffix = identifier.map { " \($0.uuidString)" } ?? ""
        let prefix = identifier == nil ? "GlassEQ Library " : automaticPrefix
        return "\(prefix)\(stamp)\(suffix).json"
    }

    static func automaticBackupsDirectory(besideStoreAt storeURL: URL) -> URL {
        storeURL.deletingLastPathComponent().appending(path: automaticBackupsDirectoryName, directoryHint: .isDirectory)
    }

    @concurrent static func pruneAutomaticBackups(in directory: URL, keeping count: Int = automaticBackupsToKeep) async
    {
        guard
            let urls = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.creationDateKey, .isRegularFileKey])
        else { return }
        let backups = urls.compactMap { url -> (url: URL, date: Date)? in
            guard url.lastPathComponent.hasPrefix(automaticPrefix), url.pathExtension == "json",
                let values = try? url.resourceValues(forKeys: [.creationDateKey, .isRegularFileKey]),
                values.isRegularFile == true, let date = values.creationDate
            else { return nil }
            return (url, date)
        }.sorted { $0.date < $1.date }
        for backup in backups.dropLast(count) {
            try? FileManager.default.removeItem(at: backup.url)
        }
    }
}

enum LibraryBackupPanels {
    @MainActor
    static func chooseExportDestination(suggestedName: String) async throws -> URL? {
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

    @MainActor
    static func chooseBackupToImport() async throws -> URL? {
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

enum LibraryBackupIO {
    @concurrent static func stage(_ prepared: ProfilePersistence.PreparedSave, beside url: URL) async throws -> URL {
        let staged = url.deletingLastPathComponent().appending(path: ".library-\(UUID().uuidString).tmp")
        try Task.checkCancellation()
        try prepared.write(to: staged)
        return staged
    }

    @concurrent static func saveBackup(_ backup: ProfileLibraryBackup, to url: URL) async throws {
        let data = try ProfileLibraryBackupCodec.encode(backup)
        try Task.checkCancellation()
        try data.write(to: url, options: .atomic)
    }

    @concurrent static func read(from url: URL) async throws -> ProfileLibraryBackup {
        try Task.checkCancellation()
        return try ProfileLibraryBackupCodec.read(from: url)
    }
}
