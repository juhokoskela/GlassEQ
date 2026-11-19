import Foundation
import GlassEQCore
import Testing
@testable import GlassEQApp

@Suite
struct LibraryBackupFileTests {
    @Test
    func combinedMappingLimitBlocksOnlyAdd() async throws {
        let profile = EQProfile(name: "Shared", mode: .parametric, filters: [])
        var current = ProfileStore(profiles: [profile])
        current.outputMappings = (0..<ProfilePersistence.outputMappingCountRange.upperBound).map {
            OutputDeviceProfileMapping(outputDeviceUID: "device-\($0)", profileID: profile.id)
        }
        var incoming = ProfileStore(profiles: [profile])
        incoming.outputMappings = [OutputDeviceProfileMapping(outputDeviceUID: "one-more", profileID: profile.id)]
        let backup = ProfileLibraryBackup(createdAt: Date(), appVersion: nil, profileStore: incoming)
        let pending = try await PendingLibraryImport.prepare(
            backup, filename: "Library.json", current: current, generation: 0)
        #expect(pending.preview.mergeFailure != nil)
        #expect(pending.preview.replaceFailure == nil)
        #expect(pending.addition == nil)
        #expect(pending.replacement != nil)
    }

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
    func pruningUsesCreationDatesInsteadOfFilenameOrder() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let older = directory.appendingPathComponent("GlassEQ Before Replace 2026-10-25T035900.json")
        let newer = directory.appendingPathComponent("GlassEQ Before Replace 2026-10-25T030000.json")
        try Data().write(to: older)
        try Data().write(to: newer)
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: older.path)
        await LibraryBackupFile.pruneAutomaticBackups(in: directory, keeping: 1)
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
    func pruningKeepsTheNewestAutomaticBackupsAndIgnoresOtherFiles() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlassEQLibraryBackupTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for day in 1...12 {
            let name = "GlassEQ Before Replace 2026-09-\(String(format: "%02d", day))T120000.json"
            let url = directory.appendingPathComponent(name)
            try Data().write(to: url)
            try FileManager.default.setAttributes(
                [.creationDate: Date(timeIntervalSince1970: Double(day))], ofItemAtPath: url.path)
        }
        try Data().write(to: directory.appendingPathComponent("GlassEQ Library 2026-01-01T120000.json"))

        await LibraryBackupFile.pruneAutomaticBackups(in: directory, keeping: 10)

        let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        #expect(remaining.count == 11)
        #expect(!remaining.contains("GlassEQ Before Replace 2026-09-01T120000.json"))
        #expect(!remaining.contains("GlassEQ Before Replace 2026-09-02T120000.json"))
        #expect(remaining.contains("GlassEQ Before Replace 2026-09-12T120000.json"))
        #expect(remaining.contains("GlassEQ Library 2026-01-01T120000.json"))
    }

}
