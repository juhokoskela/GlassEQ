import Darwin
import Foundation
import SwiftUI

/// Written when a run starts and removed when it ends cleanly, so the next launch can tell that the
/// previous one crashed or was killed. macOS tears the process tap down with the process, so the
/// record is guidance for the user, not a recovery step.
struct LaunchRecord: Codable, Equatable {
    let startedAt: Date
    let version: String?
    let processIdentifier: Int32
}

enum LaunchRecordStore {
    static let filename = "LaunchRecord.json"

    static func defaultURL(besideStoreAt storeURL: URL) -> URL {
        storeURL.deletingLastPathComponent().appending(path: filename)
    }

    /// Replaces any record with this run's and returns the previous run's record when that run
    /// never ended cleanly. A record whose process is still alive belongs to another running copy
    /// and is not an unclean termination.
    static func beginRun(
        at url: URL,
        startedAt: Date = Date(),
        version: String?,
        processIdentifier: Int32 = ProcessInfo.processInfo.processIdentifier,
        isProcessAlive: (Int32) -> Bool = { kill($0, 0) == 0 }
    ) -> LaunchRecord? {
        let previous = read(at: url)
        write(
            LaunchRecord(startedAt: startedAt, version: version, processIdentifier: processIdentifier),
            to: url
        )
        guard let previous, previous.processIdentifier != processIdentifier else {
            return nil
        }
        return isProcessAlive(previous.processIdentifier) ? nil : previous
    }

    static func endRun(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private static func read(at url: URL) -> LaunchRecord? {
        guard let data = try? Data(contentsOf: url), data.count <= 4096 else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(LaunchRecord.self, from: data)
    }

    private static func write(_ record: LaunchRecord, to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(record) else {
            return
        }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

/// Shown in the menu bar popover after a run that crashed or was killed. macOS drops the tap with
/// the process, so playback already came back; the notice says what to do if it did not.
struct UncleanTerminationNotice: View {
    let previousRun: LaunchRecord
    let showSupportReport: () -> Void
    let dismissNotice: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(Color.macOSSystemOrange)
                    .accessibilityHidden(true)
                Text(
                    localized(
                        "GlassEQ did not quit normally last time. If your output still sounds wrong, retry the audio engine in Settings. If it keeps happening, send a support report."
                    )
                )
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button(action: dismissNotice) {
                    Image(systemName: "xmark")
                        .frame(width: 20, height: 20)
                        .contentShape(.rect)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text(localized("Dismiss")))
            }
            Button(localized("Support Report…"), action: showSupportReport)
                .controlSize(.small)
        }
        .font(.caption)
        .padding(10)
        .background(Color.macOSSystemOrange.opacity(0.12), in: .rect(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(localized("Previous run did not quit normally")))
    }
}
