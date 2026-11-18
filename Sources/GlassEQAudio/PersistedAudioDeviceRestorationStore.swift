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

struct PersistedAudioDeviceRestorationStore {
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
            do {
                try FileManager.default.removeItem(at: url)
            } catch CocoaError.fileNoSuchFile {
                // Another recovery may already have cleared the last record.
            }
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

    static func restoreSampleRate(
        uid: String, to originalSampleRate: Double,
        outputForUID: (String) throws -> AudioOutputDevice? = CoreAudioDeviceQuery.restorationOutputDevice(uid:),
        setSampleRate: (Double, AudioObjectID) throws -> Void = CoreAudioDeviceQuery.setNominalSampleRate(_:objectID:)
    ) -> Bool {
        do {
            guard let output = try outputForUID(uid) else {
                return false
            }
            guard abs(output.nominalSampleRate - originalSampleRate) >= 1 else {
                return true
            }
            try setSampleRate(originalSampleRate, output.id)
            guard let verifiedOutput = try outputForUID(uid) else {
                return false
            }
            return abs(verifiedOutput.nominalSampleRate - originalSampleRate) < 1
        } catch {
            return false
        }
    }

    static func restoreBufferFrameSize(
        uid: String, to originalFrameSize: UInt32,
        outputForUID: (String) throws -> AudioOutputDevice? = CoreAudioDeviceQuery.restorationOutputDevice(uid:),
        setBufferFrameSize: (UInt32, AudioObjectID) throws -> Void = CoreAudioDeviceQuery.setBufferFrameSize(
            _:objectID:)
    ) -> Bool {
        do {
            guard let output = try outputForUID(uid) else {
                return false
            }
            guard output.bufferFrameSize != originalFrameSize else {
                return true
            }
            try setBufferFrameSize(originalFrameSize, output.id)
            guard let verifiedOutput = try outputForUID(uid) else {
                return false
            }
            return verifiedOutput.bufferFrameSize == originalFrameSize
        } catch {
            return false
        }
    }

    private let url: URL
    private var records: [String: PersistedAudioDeviceRestorationRecord]
    private struct Attempt {
        let deviceID: AudioObjectID
        let startedAt: ContinuousClock.Instant
    }

    private var lastAttempts: [String: Attempt] = [:]
    private var needsSave = false

    init(url: URL) {
        self.url = url
        self.records = Self.load(from: url)
    }

    var hasPendingSettings: Bool { !records.isEmpty || needsSave }

    func needsAttempt(for output: AudioOutputDevice) -> Bool {
        records[output.uid] != nil && lastAttempts[output.uid]?.deviceID != output.id
    }

    mutating func observeDeviceInventory(_ devices: Set<AudioObjectID>, capturedAt: ContinuousClock.Instant) {
        // A queued removal can precede a more recent write to the reattached device.
        lastAttempts = lastAttempts.filter { _, attempt in
            attempt.startedAt >= capturedAt || devices.contains(attempt.deviceID)
        }
    }

    /// Returns true when a new write still needs a later readback.
    @discardableResult
    mutating func restoreAvailableDevices(
        verifyOnly: Bool = false,
        excluding activeUID: String? = nil,
        outputForUID: (String) throws -> AudioOutputDevice? = CoreAudioDeviceQuery.restorationOutputDevice(uid:),
        setSampleRate: (Double, AudioObjectID) throws -> Void = CoreAudioDeviceQuery.setNominalSampleRate(_:objectID:),
        setBufferFrameSize: (UInt32, AudioObjectID) throws -> Void = CoreAudioDeviceQuery.setBufferFrameSize(
            _:objectID:)
    ) -> Bool {
        let original = records
        var needsReadback = false
        for (uid, record) in original {
            let output: AudioOutputDevice
            do {
                guard let available = try outputForUID(uid) else {
                    if !verifyOnly { lastAttempts[uid] = nil }
                    continue
                }
                output = available
            } catch {
                // A property read failure does not establish a new physical attachment.
                continue
            }

            var updated = record
            guard !verifyOnly, uid != activeUID, needsAttempt(for: output) else {
                if let rate = updated.originalSampleRate, abs(output.nominalSampleRate - rate) < 1 {
                    updated.originalSampleRate = nil
                }
                if updated.originalBufferFrameSize == output.bufferFrameSize {
                    updated.originalBufferFrameSize = nil
                }
                records[uid] = updated.isEmpty ? nil : updated
                continue
            }
            // HAL can reuse object IDs. Retry writes only after a confirmed absence or a new ID.
            lastAttempts[uid] = Attempt(deviceID: output.id, startedAt: .now)
            func attachedOutput(_ uid: String) throws -> AudioOutputDevice? {
                let current = try outputForUID(uid)
                return current?.id == output.id ? current : nil
            }
            if let originalSampleRate = record.originalSampleRate,
                Self.restoreSampleRate(
                    uid: uid, to: originalSampleRate,
                    outputForUID: attachedOutput,
                    setSampleRate: setSampleRate
                )
            {
                updated.originalSampleRate = nil
            }
            if let originalBufferFrameSize = record.originalBufferFrameSize,
                Self.restoreBufferFrameSize(
                    uid: uid, to: originalBufferFrameSize,
                    outputForUID: attachedOutput,
                    setBufferFrameSize: setBufferFrameSize
                )
            {
                updated.originalBufferFrameSize = nil
            }
            needsReadback = needsReadback || !updated.isEmpty
            records[uid] = updated.isEmpty ? nil : updated
        }

        guard needsSave || records != original else { return needsReadback }
        do {
            try Self.save(records, to: url)
            needsSave = false
        } catch {
            needsSave = true
        }
        return needsReadback
    }
}

/// Installed only while device settings from an earlier GlassEQ release still need restoration.
final class RestorationDeviceListListener {
    private let notificationQueue = DispatchQueue(label: "com.glasseq.device-restoration.notifications")
    private let listener: AudioObjectPropertyListenerBlock
    private var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    init?(onChange: @escaping @Sendable (Set<AudioObjectID>?, ContinuousClock.Instant) -> Void) {
        let recoveryQueue = DispatchQueue(label: "com.glasseq.device-restoration")
        listener = { _, _ in
            // Sample on the notification queue. Graph teardown can outlast a disconnect and reconnect.
            let capturedAt = ContinuousClock.now
            let devices = try? Set(CoreAudioDeviceQuery.audioDeviceIDs())
            recoveryQueue.async { onChange(devices, capturedAt) }
        }
        guard
            AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, notificationQueue, listener
            ) == noErr
        else { return nil }
    }

    deinit {
        _ = AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, notificationQueue, listener
        )
    }
}
