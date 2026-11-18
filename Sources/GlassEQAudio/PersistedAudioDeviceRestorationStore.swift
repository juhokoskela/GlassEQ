import CoreAudio
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
            records.count <= maximumRecordCount
        else {
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

    private static func isValid(_ record: PersistedAudioDeviceRestorationRecord) -> Bool {
        guard isValidUID(record.uid) else {
            return false
        }
        if let sampleRate = record.originalSampleRate,
            !sampleRate.isFinite || sampleRate <= 0 || sampleRate > CoreAudioDeviceQuery.maxSampleRate
        {
            return false
        }
        if let frameSize = record.originalBufferFrameSize,
            frameSize == 0 || frameSize > CoreAudioDeviceQuery.maxBufferFrameSize
        {
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

    struct BufferFrameSizeRestoration: Equatable, Sendable {
        var uid: String
        var originalFrameSize: UInt32
    }

    struct SampleRateRestoration: Equatable, Sendable {
        var uid: String
        var originalSampleRate: Double
    }

    static func restoreSampleRateRestoration(
        _ restoration: SampleRateRestoration,
        outputForUID: (String) throws -> AudioOutputDevice? = CoreAudioDeviceQuery.outputDevice(uid:),
        setSampleRate: (Double, AudioObjectID) throws -> Void = CoreAudioDeviceQuery.setNominalSampleRate(_:objectID:)
    ) -> Bool {
        do {
            guard let output = try outputForUID(restoration.uid) else {
                return false
            }
            guard abs(output.nominalSampleRate - restoration.originalSampleRate) >= 1 else {
                return true
            }
            try setSampleRate(restoration.originalSampleRate, output.id)
            guard let verifiedOutput = try outputForUID(restoration.uid) else {
                return false
            }
            return abs(verifiedOutput.nominalSampleRate - restoration.originalSampleRate) < 1
        } catch {
            return false
        }
    }

    static func restoreBufferFrameSizeRestoration(
        _ restoration: BufferFrameSizeRestoration,
        outputForUID: (String) throws -> AudioOutputDevice? = CoreAudioDeviceQuery.outputDevice(uid:),
        setBufferFrameSize: (UInt32, AudioObjectID) throws -> Void = CoreAudioDeviceQuery.setBufferFrameSize(
            _:objectID:)
    ) -> Bool {
        do {
            guard let output = try outputForUID(restoration.uid) else {
                return false
            }
            guard output.bufferFrameSize != restoration.originalFrameSize else {
                return true
            }
            try setBufferFrameSize(restoration.originalFrameSize, output.id)
            guard let verifiedOutput = try outputForUID(restoration.uid) else {
                return false
            }
            return verifiedOutput.bufferFrameSize == restoration.originalFrameSize
        } catch {
            return false
        }
    }

    static func restorePersistedDeviceSettings(
        at url: URL,
        outputForUID: (String) throws -> AudioOutputDevice? = CoreAudioDeviceQuery.outputDevice(uid:),
        setSampleRate: (Double, AudioObjectID) throws -> Void = CoreAudioDeviceQuery.setNominalSampleRate(_:objectID:),
        setBufferFrameSize: (UInt32, AudioObjectID) throws -> Void = CoreAudioDeviceQuery.setBufferFrameSize(
            _:objectID:)
    ) {
        var records = PersistedAudioDeviceRestorationStore.load(from: url)
        guard !records.isEmpty else {
            return
        }

        for (uid, record) in records {
            var updated = record
            if let originalSampleRate = record.originalSampleRate,
                restoreSampleRateRestoration(
                    SampleRateRestoration(uid: uid, originalSampleRate: originalSampleRate),
                    outputForUID: outputForUID,
                    setSampleRate: setSampleRate
                )
            {
                updated.originalSampleRate = nil
            }
            if let originalBufferFrameSize = record.originalBufferFrameSize,
                restoreBufferFrameSizeRestoration(
                    BufferFrameSizeRestoration(uid: uid, originalFrameSize: originalBufferFrameSize),
                    outputForUID: outputForUID,
                    setBufferFrameSize: setBufferFrameSize
                )
            {
                updated.originalBufferFrameSize = nil
            }
            records[uid] = updated.isEmpty ? nil : updated
        }

        try? PersistedAudioDeviceRestorationStore.save(records, to: url)
    }
}
