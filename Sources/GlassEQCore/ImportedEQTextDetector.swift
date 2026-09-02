import Foundation

public enum ImportedEQTextFormat: Equatable, Sendable {
    case autoEQ
    case rew
}

public enum ImportedEQTextDetector {
    public static func format(for text: String) -> ImportedEQTextFormat {
        let lowercased = text.lowercased()
        if lowercased.contains("room eq wizard")
            || lowercased.contains("equaliser: generic")
            || lowercased.contains("filter settings file")
            || lowercased.contains(" on modal ") {
            return .rew
        }
        return .autoEQ
    }
}
