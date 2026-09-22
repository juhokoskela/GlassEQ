import AppKit
import Foundation
import GlassEQCore
import GlassEQSettingsUI
import UniformTypeIdentifiers

/// A library the user chose to import, kept until they pick merge or replace, or cancel.
struct PendingLibraryImport {
    let backup: ProfileLibraryBackup
    let filename: String
}

enum LibraryBackupFile {
    static let automaticBackupsDirectoryName = "Backups"
    static let automaticBackupsToKeep = 10

    static func suggestedFilename(createdAt: Date, identifier: UUID? = nil) -> String {
        let stamp = createdAt.formatted(
            Date.ISO8601FormatStyle(dateSeparator: .dash, timeSeparator: .omitted, timeZone: .gmt)
                .year().month().day().dateTimeSeparator(.standard).time(includingFractionalSeconds: false)
        )
        let suffix = identifier.map { " \($0.uuidString)" } ?? ""
        return "GlassEQ Library \(stamp)\(suffix).json"
    }

    static func automaticBackupsDirectory(besideStoreAt storeURL: URL) -> URL {
        storeURL.deletingLastPathComponent().appending(path: automaticBackupsDirectoryName, directoryHint: .isDirectory)
    }

    static func pruneAutomaticBackups(in directory: URL, keeping count: Int = automaticBackupsToKeep) {
        guard
            let urls = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.creationDateKey])
        else { return }
        let backups = urls.compactMap { url -> (url: URL, date: Date)? in
            guard url.lastPathComponent.hasPrefix("GlassEQ Library "), url.pathExtension == "json",
                let date = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate
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
    @concurrent static func encode(_ backup: ProfileLibraryBackup) async throws -> Data {
        try Task.checkCancellation()
        return try ProfileLibraryBackupCodec.encode(backup)
    }

    @concurrent static func read(from url: URL) async throws -> ProfileLibraryBackup {
        try Task.checkCancellation()
        return try ProfileLibraryBackupCodec.read(from: url)
    }

    @concurrent static func write(_ data: Data, to url: URL) async throws {
        try Task.checkCancellation()
        try data.write(to: url, options: .atomic)
    }
}
