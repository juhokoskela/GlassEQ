import Foundation
import OSLog

/// A bounded, timestamped record of what the app did: launches, windows, route changes, engine
/// failures, license state, and shutdown. The support report includes it, and a process launched
/// with `--debug` also streams every entry to stderr so a Terminal launch shows what an invisible
/// menu bar app is doing.
@MainActor
final class LifecycleLog {
    struct Entry: Equatable {
        let date: Date
        let message: String
    }

    static let capacity = 200
    nonisolated static let debugFlag = "--debug"

    let streamsToStandardError: Bool
    private(set) var entries: [Entry] = []
    private let now: () -> Date
    private let logger = Logger(subsystem: "com.glasseq.app", category: "Lifecycle")
    private static let timestampFormat = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    init(streamsToStandardError: Bool = false, now: @escaping () -> Date = Date.init) {
        self.streamsToStandardError = streamsToStandardError
        self.now = now
    }

    nonisolated static func isDebugLaunch(arguments: [String] = CommandLine.arguments) -> Bool {
        arguments.dropFirst().contains(debugFlag)
    }

    func record(_ message: String) {
        let entry = Entry(date: now(), message: message)
        entries.append(entry)
        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }
        logger.info("\(message, privacy: .private)")
        if streamsToStandardError {
            let line = "\(Self.line(for: entry))\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
    }

    var text: String {
        entries.map(Self.line(for:)).joined(separator: "\n")
    }

    private static func line(for entry: Entry) -> String {
        "\(entry.date.formatted(timestampFormat)) \(entry.message)"
    }
}
