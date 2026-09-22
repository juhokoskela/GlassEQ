import Darwin
import Foundation
import SwiftUI

/// Written when a run starts and removed when it ends cleanly, so the next launch can tell that a
/// previous one crashed or was killed. macOS tears the process tap down with the process, so the
/// record is guidance for the user, not a recovery step.
struct LaunchRecord: Codable, Equatable {
    let startedAt: Date
    let version: String?
    let processIdentifier: Int32
}

/// One record file per process, named by its identifier, so two running copies never overwrite or
/// remove each other's marker.
enum LaunchRecordStore {
    static let directoryName = "LaunchRecords"

    static func defaultDirectory(besideStoreAt storeURL: URL) -> URL {
        storeURL.deletingLastPathComponent().appending(path: directoryName, directoryHint: .isDirectory)
    }

    /// Writes this run's record and returns the newest record of a run that never ended cleanly.
    /// Records of processes that are still alive belong to other running copies and are kept;
    /// records of dead processes are removed once read.
    static func beginRun(
        in directory: URL,
        startedAt: Date = Date(),
        version: String?,
        processIdentifier: Int32 = ProcessInfo.processInfo.processIdentifier,
        isProcessAlive: (Int32) -> Bool = { kill($0, 0) == 0 }
    ) -> LaunchRecord? {
        var unclean: LaunchRecord?
        for (url, record) in existingRecords(in: directory) where !isProcessAlive(record.processIdentifier) {
            try? FileManager.default.removeItem(at: url)
            if unclean.map({ record.startedAt > $0.startedAt }) ?? true {
                unclean = record
            }
        }
        write(
            LaunchRecord(startedAt: startedAt, version: version, processIdentifier: processIdentifier),
            to: recordURL(in: directory, processIdentifier: processIdentifier)
        )
        return unclean
    }

    static func endRun(
        in directory: URL,
        processIdentifier: Int32 = ProcessInfo.processInfo.processIdentifier
    ) {
        try? FileManager.default.removeItem(at: recordURL(in: directory, processIdentifier: processIdentifier))
    }

    static func recordURL(in directory: URL, processIdentifier: Int32) -> URL {
        directory.appending(path: "\(processIdentifier).json")
    }

    private static func existingRecords(in directory: URL) -> [(URL, LaunchRecord)] {
        guard
            let urls = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else {
            return []
        }
        return urls.compactMap { url in
            guard url.pathExtension == "json", let record = read(at: url) else {
                return nil
            }
            return (url, record)
        }
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
