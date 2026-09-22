import Foundation
import GlassEQCore
import GlassEQSettingsIPC
import Testing
@testable import GlassEQApp

@Suite
struct LibraryBackupFileTests {
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
            try Data().write(to: directory.appendingPathComponent(name))
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

        let preview = SettingsLibraryImportPreviewDTO(pending: pending, summary: summary)

        #expect(preview.filename == "library.json")
        #expect(preview.appVersion == "v1.0 (1)")
        #expect(preview.profileCount == 1)
        #expect(preview.hasBufferPreferences)
        #expect(preview.mergeAddedProfiles == 1)
        #expect(preview.mergeSkippedMappings == 2)
        #expect(preview.mergeExceedsProfileLimit)
    }
}
