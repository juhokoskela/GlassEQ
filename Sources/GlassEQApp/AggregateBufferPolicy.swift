import Foundation
import GlassEQAudio
import GlassEQSettingsIPC

struct AggregateBufferSelection: Equatable, Sendable {
    var mode: SettingsAggregateBufferMode
    var frameSize: UInt32
    var automaticFrameSize: UInt32
}

@MainActor
final class AggregateBufferPolicyStore {
    static let maximumStoreBytes = 262_144
    static let maximumRecordCount = 256

    private enum PersistenceError: Error {
        case storeTooLarge
        case tooManyRecords
    }

    private struct Record: Codable, Equatable {
        var route: AggregateAudioRouteFingerprint
        var mode: SettingsAggregateBufferMode
        var automaticFrameSize: UInt32
        var failureWindowStartedAt: Date?
        var failureCount: Int
        var cleanSessionCount: Int

        init(
            route: AggregateAudioRouteFingerprint,
            mode: SettingsAggregateBufferMode,
            automaticFrameSize: UInt32,
            failureWindowStartedAt: Date? = nil,
            failureCount: Int = 0,
            cleanSessionCount: Int = 0
        ) {
            self.route = route
            self.mode = mode
            self.automaticFrameSize = automaticFrameSize
            self.failureWindowStartedAt = failureWindowStartedAt
            self.failureCount = failureCount
            self.cleanSessionCount = cleanSessionCount
        }

        private enum CodingKeys: String, CodingKey {
            case route
            case mode
            case automaticFrameSize
            case failureWindowStartedAt
            case failureCount
            case cleanSessionCount
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            route = try container.decode(
                AggregateAudioRouteFingerprint.self,
                forKey: .route
            )
            mode = try container.decode(SettingsAggregateBufferMode.self, forKey: .mode)
            automaticFrameSize = try container.decode(UInt32.self, forKey: .automaticFrameSize)
            failureWindowStartedAt = try container.decodeIfPresent(
                Date.self,
                forKey: .failureWindowStartedAt
            )
            failureCount = try container.decodeIfPresent(Int.self, forKey: .failureCount) ?? 0
            cleanSessionCount = try container.decodeIfPresent(
                Int.self,
                forKey: .cleanSessionCount
            ) ?? 0
        }
    }

    private struct Document: Codable {
        static let schemaVersion = 2

        var schemaVersion: Int
        var records: [Record]
    }

    private let url: URL
    private var records: [Record]

    static let failureWindow: TimeInterval = 5 * 60
    static let cleanSessionsBeforeRetry = 3

    init(url: URL) {
        self.url = url
        self.records = Self.load(from: url)
    }

    static func defaultURL() -> URL {
        let baseURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return baseURL
            .appendingPathComponent("GlassEQ", isDirectory: true)
            .appendingPathComponent("aggregate-buffer-policy.json")
    }

    func selection(for route: AggregateAudioRouteFingerprint) -> AggregateBufferSelection {
        let record = record(for: route)
        let mode = record?.mode ?? .automatic
        let automaticFrameSize = Self.validatedAutomaticFrameSize(
            record?.automaticFrameSize ?? 16
        )
        let frameSize: UInt32 = switch mode {
        case .automatic:
            automaticFrameSize
        case .frames16:
            16
        case .frames32:
            32
        case .frames64:
            64
        }
        return AggregateBufferSelection(
            mode: mode,
            frameSize: frameSize,
            automaticFrameSize: automaticFrameSize
        )
    }

    func setMode(
        _ mode: SettingsAggregateBufferMode,
        for route: AggregateAudioRouteFingerprint
    ) throws {
        try update(route: route) { record in
            guard record.mode != mode else {
                return
            }
            record.mode = mode
            record.failureWindowStartedAt = nil
            record.failureCount = 0
            record.cleanSessionCount = 0
        }
    }

    @discardableResult
    func recordAutomaticFailure(
        for route: AggregateAudioRouteFingerprint,
        occurrences: UInt64 = 1,
        at now: Date = Date()
    ) throws -> UInt32? {
        guard occurrences > 0,
              selection(for: route).mode == .automatic else {
            return nil
        }
        var resultingFrameSize: UInt32?
        try update(route: route) { record in
            let windowAge = record.failureWindowStartedAt.map {
                now.timeIntervalSince($0)
            }
            if let windowAge,
               windowAge >= 0,
               windowAge <= Self.failureWindow {
                record.failureCount += Int(clamping: occurrences)
            } else {
                record.failureWindowStartedAt = now
                record.failureCount = Int(clamping: occurrences)
            }
            record.cleanSessionCount = 0

            guard record.failureCount >= 2 else {
                return
            }
            record.failureWindowStartedAt = nil
            record.failureCount = 0
            guard let nextFrameSize = Self.nextAutomaticFrameSize(
                after: record.automaticFrameSize
            ) else {
                return
            }
            record.automaticFrameSize = nextFrameSize
            resultingFrameSize = nextFrameSize
        }
        return resultingFrameSize
    }

    @discardableResult
    func recordCleanAutomaticSession(
        for route: AggregateAudioRouteFingerprint
    ) throws -> UInt32? {
        let selection = selection(for: route)
        guard selection.mode == .automatic,
              selection.automaticFrameSize > 16 else {
            return nil
        }
        var resultingFrameSize: UInt32?
        try update(route: route) { record in
            record.failureWindowStartedAt = nil
            record.failureCount = 0
            record.cleanSessionCount += 1
            guard record.cleanSessionCount >= Self.cleanSessionsBeforeRetry,
                  let previousFrameSize = Self.previousAutomaticFrameSize(
                      before: record.automaticFrameSize
                  ) else {
                return
            }
            record.automaticFrameSize = previousFrameSize
            record.cleanSessionCount = 0
            resultingFrameSize = previousFrameSize
        }
        return resultingFrameSize
    }

    func retryAutomaticBuffer(for route: AggregateAudioRouteFingerprint) throws {
        try update(route: route) { record in
            record.mode = .automatic
            record.automaticFrameSize = 16
            record.failureWindowStartedAt = nil
            record.failureCount = 0
            record.cleanSessionCount = 0
        }
    }

    private func record(for route: AggregateAudioRouteFingerprint) -> Record? {
        records.first { $0.route == route }
    }

    private func update(
        route: AggregateAudioRouteFingerprint,
        _ update: (inout Record) -> Void
    ) throws {
        guard route.isValid else {
            return
        }
        let index: Int
        let inserted: Bool
        if let existingIndex = records.firstIndex(where: { $0.route == route }) {
            index = existingIndex
            inserted = false
        } else {
            guard records.count < Self.maximumRecordCount else {
                throw PersistenceError.tooManyRecords
            }
            records.append(Record(
                route: route,
                mode: .automatic,
                automaticFrameSize: 16
            ))
            index = records.index(before: records.endIndex)
            inserted = true
        }

        let previous = records[index]
        update(&records[index])
        guard records[index] != previous else {
            return
        }
        do {
            try write()
        } catch {
            if inserted {
                records.remove(at: index)
            } else {
                records[index] = previous
            }
            throw error
        }
    }

    private func write() throws {
        guard records.count <= Self.maximumRecordCount else {
            throw PersistenceError.tooManyRecords
        }
        let document = Document(
            schemaVersion: Document.schemaVersion,
            records: records.sorted {
                if $0.route.outputDeviceUID != $1.route.outputDeviceUID {
                    return $0.route.outputDeviceUID < $1.route.outputDeviceUID
                }
                if $0.route.nativeOutputStreamIndex != $1.route.nativeOutputStreamIndex {
                    return $0.route.nativeOutputStreamIndex < $1.route.nativeOutputStreamIndex
                }
                return $0.route.nominalSampleRate < $1.route.nominalSampleRate
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        guard data.count <= Self.maximumStoreBytes else {
            throw PersistenceError.storeTooLarge
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    private static func load(from url: URL) -> [Record] {
        guard let data = try? readBoundedData(from: url),
              let document = try? JSONDecoder().decode(Document.self, from: data),
              [1, Document.schemaVersion].contains(document.schemaVersion),
              document.records.count <= maximumRecordCount else {
            return []
        }
        return document.records.compactMap { record in
            guard record.route.isValid,
                  [16, 32, 64].contains(record.automaticFrameSize) else {
                return nil
            }
            var record = record
            if document.schemaVersion == 1 {
                // Schema 1 raised a route after one event, so its learned rung cannot satisfy
                // the new two-event policy. Preserve explicit fixed modes but relearn Automatic.
                record.automaticFrameSize = 16
            }
            record.failureCount = min(max(record.failureCount, 0), 1)
            record.cleanSessionCount = min(
                max(record.cleanSessionCount, 0),
                Self.cleanSessionsBeforeRetry - 1
            )
            return record
        }
    }

    private static func readBoundedData(from url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while data.count <= maximumStoreBytes {
            let remaining = maximumStoreBytes + 1 - data.count
            guard let chunk = try handle.read(upToCount: remaining), !chunk.isEmpty else {
                break
            }
            data.append(chunk)
        }
        guard data.count <= maximumStoreBytes else {
            throw PersistenceError.storeTooLarge
        }
        return data
    }

    private static func validatedAutomaticFrameSize(_ frameSize: UInt32) -> UInt32 {
        [16, 32, 64].contains(frameSize) ? frameSize : 16
    }

    private static func nextAutomaticFrameSize(after frameSize: UInt32) -> UInt32? {
        switch frameSize {
        case ..<32:
            32
        case 32..<64:
            64
        default:
            nil
        }
    }

    private static func previousAutomaticFrameSize(before frameSize: UInt32) -> UInt32? {
        switch frameSize {
        case 64...:
            32
        case 32..<64:
            16
        default:
            nil
        }
    }
}
