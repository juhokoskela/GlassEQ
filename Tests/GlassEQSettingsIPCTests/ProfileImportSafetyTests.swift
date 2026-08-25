import Foundation
import GlassEQCore
import Testing
@testable import GlassEQSettingsUI

@Suite
struct ProfileImportSafetyTests {
    @Test
    func profileNameValidationUsesCommittedUTF8Bytes() {
        let exactName = String(repeating: "é", count: 60)
        #expect(ProfileImportNameValidation("  \(exactName)\n") == .valid(trimmedName: exactName))
        #expect(ProfileImportNameValidation(" \n\t ") == .empty)
        #expect(ProfileImportNameValidation(String(repeating: "é", count: 61)) == .tooLong(
            byteCount: 122,
            maximum: ProfilePersistence.maxProfileNameUTF8Bytes
        ))
    }

    @Test
    func boundedTextReadAcceptsExactLimitWithoutKnownSize() throws {
        let url = try temporaryTextFile(Data("12345678".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let text = try readBoundedImportedText(
            from: handle,
            knownFileSize: nil,
            maximumBytes: 8
        )

        #expect(text == "12345678")
    }

    @Test
    func boundedTextReadRejectsContentBeyondStaleKnownSize() throws {
        let url = try temporaryTextFile(Data("12345678".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        #expect(throws: ProfileImportError.inputTooLarge(byteCount: 8, maximum: 7)) {
            try readBoundedImportedText(
                from: handle,
                knownFileSize: 3,
                maximumBytes: 7
            )
        }
    }

    @Test
    func boundedTextReadHonorsCancellationBeforeReading() async throws {
        let url = try temporaryTextFile(Data("profile".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        let task = Task.detached {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            withUnsafeCurrentTask { task in
                task?.cancel()
            }
            return try readBoundedImportedText(
                from: handle,
                knownFileSize: nil,
                maximumBytes: 32
            )
        }

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    private func temporaryTextFile(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlassEQ-import-safety-\(UUID().uuidString).txt")
        try data.write(to: url)
        return url
    }
}
