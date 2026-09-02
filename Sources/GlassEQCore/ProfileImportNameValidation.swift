import Foundation

public enum ProfileImportNameValidation: Equatable, Sendable {
    case valid(trimmedName: String)
    case empty
    case tooLong(byteCount: Int, maximum: Int)

    public init(_ name: String) {
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
}
