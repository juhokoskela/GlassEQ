import Foundation

struct PersistedAudioDeviceRestorationRecord: Codable, Equatable, Sendable {
    var uid: String
    var originalSampleRate: Double?
    var originalBufferFrameSize: UInt32?

    var isEmpty: Bool {
        originalSampleRate == nil && originalBufferFrameSize == nil
    }
}

enum PersistedAudioDeviceRestorationStore {
    static let maximumStoreBytes = 262_144
    static let maximumRecordCount = 128
    static let maximumUIDUTF8Bytes = 512

    private enum PersistenceError: Error {
        case invalidRecord
        case storeTooLarge
        case tooManyRecords
    }

    static func defaultURL(
        applicationSupportDirectory: URL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
    ) -> URL {
        applicationSupportDirectory
            .appendingPathComponent("GlassEQ", isDirectory: true)
            .appendingPathComponent("DeviceRestorations.json", isDirectory: false)
    }

    static func load(from url: URL) -> [String: PersistedAudioDeviceRestorationRecord] {
        guard let data = try? readBoundedData(from: url),
              let records = try? JSONDecoder().decode([PersistedAudioDeviceRestorationRecord].self, from: data),
              records.count <= maximumRecordCount else {
            return [:]
        }
        var recordsByUID: [String: PersistedAudioDeviceRestorationRecord] = [:]
        for record in records {
            guard isValid(record) else {
                continue
            }
            if var existing = recordsByUID[record.uid] {
                if existing.originalSampleRate == nil {
                    existing.originalSampleRate = record.originalSampleRate
                }
                if existing.originalBufferFrameSize == nil {
                    existing.originalBufferFrameSize = record.originalBufferFrameSize
                }
                recordsByUID[record.uid] = existing
            } else {
                recordsByUID[record.uid] = record
            }
        }
        return recordsByUID
    }

    static func save(_ recordsByUID: [String: PersistedAudioDeviceRestorationRecord], to url: URL) throws {
        let records = recordsByUID.values
            .filter { !$0.isEmpty }
            .sorted { $0.uid < $1.uid }
        guard records.count <= maximumRecordCount else {
            throw PersistenceError.tooManyRecords
        }
        guard records.allSatisfy(isValid) else {
            throw PersistenceError.invalidRecord
        }
        guard !records.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(records)
        guard data.count <= maximumStoreBytes else {
            throw PersistenceError.storeTooLarge
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    static func recordSampleRate(uid: String, originalSampleRate: Double, at url: URL) throws {
        guard isValidUID(uid),
              originalSampleRate.isFinite,
              originalSampleRate > 0,
              originalSampleRate <= CoreAudioDeviceQuery.maxSampleRate else {
            throw PersistenceError.invalidRecord
        }
        var records = load(from: url)
        var record = records[uid] ?? PersistedAudioDeviceRestorationRecord(uid: uid)
        if record.originalSampleRate == nil {
            record.originalSampleRate = originalSampleRate
        }
        records[uid] = record
        try save(records, to: url)
    }

    static func recordBufferFrameSize(uid: String, originalFrameSize: UInt32, at url: URL) throws {
        guard isValidUID(uid),
              originalFrameSize > 0,
              originalFrameSize <= CoreAudioDeviceQuery.maxBufferFrameSize else {
            throw PersistenceError.invalidRecord
        }
        var records = load(from: url)
        var record = records[uid] ?? PersistedAudioDeviceRestorationRecord(uid: uid)
        if record.originalBufferFrameSize == nil {
            record.originalBufferFrameSize = originalFrameSize
        }
        records[uid] = record
        try save(records, to: url)
    }

    static func clearSampleRate(uid: String, at url: URL) throws {
        try update(uid: uid, at: url) { $0.originalSampleRate = nil }
    }

    static func clearBufferFrameSize(uid: String, at url: URL) throws {
        try update(uid: uid, at: url) { $0.originalBufferFrameSize = nil }
    }

    private static func update(
        uid: String,
        at url: URL,
        mutation: (inout PersistedAudioDeviceRestorationRecord) -> Void
    ) throws {
        var records = load(from: url)
        guard var record = records[uid] else {
            return
        }
        mutation(&record)
        records[uid] = record.isEmpty ? nil : record
        try save(records, to: url)
    }

    private static func isValid(_ record: PersistedAudioDeviceRestorationRecord) -> Bool {
        guard isValidUID(record.uid) else {
            return false
        }
        if let sampleRate = record.originalSampleRate,
           !sampleRate.isFinite || sampleRate <= 0 || sampleRate > CoreAudioDeviceQuery.maxSampleRate {
            return false
        }
        if let frameSize = record.originalBufferFrameSize,
           frameSize == 0 || frameSize > CoreAudioDeviceQuery.maxBufferFrameSize {
            return false
        }
        return true
    }

    private static func isValidUID(_ uid: String) -> Bool {
        !uid.isEmpty && uid.utf8.count <= maximumUIDUTF8Bytes
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
}
