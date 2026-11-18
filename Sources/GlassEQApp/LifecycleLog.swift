import Foundation
import GlassEQSettingsIPC

/// Recent startup and playback status, kept in memory for the support report.
@MainActor
final class LifecycleLog {
    private struct Entry {
        let date: Date
        let message: String
    }

    static let capacity = 200

    private let debugWriter: DispatchSemaphore?
    private var entries: [Entry] = []
    private static let timestampFormat = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    init() {
        debugWriter = CommandLine.arguments.dropFirst().contains("--debug") ? DispatchSemaphore(value: 1) : nil
        if debugWriter != nil { SettingsPipeProcessSignalPolicy.ignoreBrokenPipeSignal() }
    }

    func record(_ message: String) {
        let entry = Entry(date: Date(), message: message)
        entries.append(entry)
        if entries.count > Self.capacity {
            entries.removeFirst(entries.count - Self.capacity)
        }
        // Drop terminal output while a previous write is blocked. Playback never waits for stderr.
        if let debugWriter, debugWriter.wait(timeout: .now()) == .success {
            let data = Data("\(Self.line(for: entry))\n".utf8)
            DispatchQueue.global(qos: .utility).async {
                defer { debugWriter.signal() }
                try? FileHandle.standardError.write(contentsOf: data)
            }
        }
    }

    var text: String {
        entries.map(Self.line(for:)).joined(separator: "\n")
    }

    private static func line(for entry: Entry) -> String {
        "\(entry.date.formatted(timestampFormat)) \(entry.message)"
    }
}
