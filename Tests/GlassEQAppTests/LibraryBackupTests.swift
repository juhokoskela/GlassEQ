import Foundation
import GlassEQCore
import GlassEQSettingsIPC
import Testing
@testable import GlassEQApp

@Suite
struct LibraryBackupFileTests {

    @Test
    func filenamesStayChronologicalAcrossDaylightSavingChanges() throws {
        let parser = ISO8601DateFormatter()
        let before = try #require(parser.date(from: "2026-10-25T00:59:00Z"))
        let after = try #require(parser.date(from: "2026-10-25T01:00:00Z"))
        #expect(LibraryBackupFile.suggestedFilename(createdAt: before) == "GlassEQ Library 2026-10-25T005900.json")
        #expect(
            LibraryBackupFile.suggestedFilename(createdAt: before)
                < LibraryBackupFile.suggestedFilename(createdAt: after))
    }

    @Test
    func pruningUsesCreationDatesForLegacyLocalTimeNames() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let older = directory.appendingPathComponent("GlassEQ Library 2026-10-25T035900.json")
        let newer = directory.appendingPathComponent("GlassEQ Library 2026-10-25T030000.json")
        try Data().write(to: older)
        try Data().write(to: newer)
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: older.path)
        LibraryBackupFile.pruneAutomaticBackups(in: directory, keeping: 1)
        #expect(!FileManager.default.fileExists(atPath: older.path))
        #expect(FileManager.default.fileExists(atPath: newer.path))
    }

    @Test
    func suggestedFilenameIsDatedJSONWithoutColons() {
        let name = LibraryBackupFile.suggestedFilename(createdAt: Date(timeIntervalSince1970: 1_700_000_000))

        #expect(name.hasPrefix("GlassEQ Library 2023-11-1"))
        #expect(name.hasSuffix(".json"))
        #expect(!name.contains(":"))
    }

    @Test
    func pruningKeepsTheNewestAutomaticBackupsAndIgnoresOtherFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlassEQLibraryBackupTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for day in 1...12 {
            let name = "GlassEQ Library 2026-09-\(String(format: "%02d", day))T120000.json"
            let url = directory.appendingPathComponent(name)
            try Data().write(to: url)
            try FileManager.default.setAttributes(
                [.creationDate: Date(timeIntervalSince1970: Double(day))], ofItemAtPath: url.path)
        }
        try Data().write(to: directory.appendingPathComponent("notes.txt"))

        LibraryBackupFile.pruneAutomaticBackups(in: directory, keeping: 10)

        let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        #expect(remaining.count == 11)
        #expect(!remaining.contains("GlassEQ Library 2026-09-01T120000.json"))
        #expect(!remaining.contains("GlassEQ Library 2026-09-02T120000.json"))
        #expect(remaining.contains("GlassEQ Library 2026-09-12T120000.json"))
        #expect(remaining.contains("notes.txt"))
    }

    @Test
    func previewCarriesTheFileFactsAndMergeCounts() {
        let store = ProfileStore(
            profiles: [EQProfile(name: "A", mode: .parametric, filters: [])],
            outputMappings: [])
        let pending = PendingLibraryImport(
            backup: ProfileLibraryBackup(
                createdAt: Date(timeIntervalSince1970: 0), appVersion: "v1.0 (1)", profileStore: store,
                bufferPreferences: Data()),
            filename: "library.json")
        var summary = ProfileLibraryMergeSummary()
        summary.addedProfiles = 1
        summary.skippedMappings = 2
        summary.resultingProfileCount = ProfilePersistence.profileCountRange.upperBound + 1

        let preview = SettingsLibraryImportPreviewDTO(
            filename: pending.filename, createdAt: pending.backup.createdAt, appVersion: pending.backup.appVersion,
            profileCount: 1, outputMappingCount: 0, hasBufferPreferences: true, merge: summary)

        #expect(preview.filename == "library.json")
        #expect(preview.appVersion == "v1.0 (1)")
        #expect(preview.profileCount == 1)
        #expect(preview.hasBufferPreferences)
        #expect(preview.merge.addedProfiles == 1)
        #expect(preview.merge.skippedMappings == 2)
        #expect(preview.merge.exceedsProfileLimit)
    }
}
