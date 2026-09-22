import AppKit
import Darwin
import Foundation

/// Written when a run starts and removed when it ends cleanly, so the next launch can tell that a
/// previous one crashed or was killed. macOS tears the process tap down with the process, so the
/// record is guidance for the user, not a recovery step.
struct LaunchRecord: Codable, Equatable {
    let startedAt: Date
    let version: String
    let processIdentifier: Int32
}

/// One record file per process, named by its identifier, so two running copies never overwrite or
/// remove each other's marker.
enum LaunchRecordStore {
    static let directoryName = "LaunchRecords"
    static let maximumRecordBytes = 4_096

    static func defaultDirectory(besideStoreAt storeURL: URL) -> URL {
        storeURL.deletingLastPathComponent().appending(path: directoryName, directoryHint: .isDirectory)
    }

    /// Writes this run's record and returns the newest record of a run that never ended cleanly.
    /// Records of processes that are still alive belong to other running copies and are kept;
    /// records of dead processes are removed once read.
    static func beginRun(
        in directory: URL,
        startedAt: Date = Date(),
        version: String,
        processIdentifier: Int32 = ProcessInfo.processInfo.processIdentifier,
        isProcessAlive: (LaunchRecord) -> Bool = isRunning
    ) -> LaunchRecord? {
        let dead = existingRecords(in: directory).filter { !isProcessAlive($0.1) }
        for (url, _) in dead {
            try? FileManager.default.removeItem(at: url)
        }
        write(
            LaunchRecord(startedAt: startedAt, version: version, processIdentifier: processIdentifier),
            to: recordURL(in: directory, processIdentifier: processIdentifier)
        )
        return dead.map(\.1).max { $0.startedAt < $1.startedAt }
    }

    static func isRunning(_ record: LaunchRecord) -> Bool {
        // The sandbox hides peer launch dates. Ignore markers from before this boot, then
        // identify the application without kill(pid, 0), which reports EPERM for live peers.
        var bootTime = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &bootTime, &size, nil, 0) == 0,
            record.startedAt.timeIntervalSince1970 >= TimeInterval(bootTime.tv_sec),
            let bundleIdentifier = Bundle.main.bundleIdentifier
        else {
            return false
        }
        return NSRunningApplication(processIdentifier: record.processIdentifier)?.bundleIdentifier == bundleIdentifier
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
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }
        var data = Data()
        do {
            while data.count <= maximumRecordBytes {
                guard let chunk = try handle.read(upToCount: maximumRecordBytes + 1 - data.count), !chunk.isEmpty else {
                    break
                }
                data.append(chunk)
            }
        } catch {
            return nil
        }
        guard data.count <= maximumRecordBytes else { return nil }
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
