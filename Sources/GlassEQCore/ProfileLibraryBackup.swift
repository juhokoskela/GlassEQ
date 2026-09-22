import Foundation

/// A complete profile library as one portable document: every profile with its embedded impulse
/// response, the output mappings, the fallback profile, and the app's per-route buffer preferences.
/// Core carries the preferences as an opaque document; the app decides what they mean.
public struct ProfileLibraryBackup: Codable, Equatable, Sendable {
    public static let formatIdentifier = "glasseq-profile-library"
    public static let currentVersion = 1
    public static let maxBufferPreferencesBytes = 262_144
    /// The store's own limit plus room for the envelope, pretty printing, and buffer preferences.
    public static let maxBytes = ProfilePersistence.maxStoreBytes + maxBufferPreferencesBytes + 262_144

    public let format: String
    public let version: Int
    public var createdAt: Date
    public var appVersion: String?
    public var profileStore: ProfileStore
    public var bufferPreferences: Data?

    public init(
        createdAt: Date,
        appVersion: String?,
        profileStore: ProfileStore,
        bufferPreferences: Data? = nil
    ) {
        format = Self.formatIdentifier
        version = Self.currentVersion
        self.createdAt = createdAt
        self.appVersion = appVersion
        self.profileStore = profileStore
        self.bufferPreferences = bufferPreferences
    }
}

public enum ProfileLibraryBackupError: Error, Equatable, Sendable, LocalizedError {
    case inputTooLarge(byteCount: Int, maximum: Int)
    case notALibraryBackup
    case unsupportedVersion(version: Int, maximum: Int)
    case unsupportedStoreSchema(version: Int, maximum: Int)
    case invalidStore(String)
    case bufferPreferencesTooLarge(byteCount: Int, maximum: Int)
    case tooManyProfiles(count: Int, maximum: Int)

    public var errorDescription: String? {
        switch self {
        case let .inputTooLarge(byteCount, maximum):
            "The file is \(byteCount) bytes, above the \(maximum)-byte limit for a GlassEQ library."
        case .notALibraryBackup:
            "The file is not a GlassEQ profile library."
        case let .unsupportedVersion(version, maximum):
            "The library was saved by a newer GlassEQ (format \(version)). This version reads format \(maximum) and earlier."
        case let .unsupportedStoreSchema(version, maximum):
            "The library's profiles use schema \(version), newer than the schema \(maximum) this version reads."
        case let .invalidStore(reason):
            "The library's profiles are damaged: \(reason)"
        case let .bufferPreferencesTooLarge(byteCount, maximum):
            "The library's buffer preferences are \(byteCount) bytes, above the \(maximum)-byte limit."
        case let .tooManyProfiles(count, maximum):
            "Importing would leave \(count) profiles, above the limit of \(maximum)."
        }
    }
}

public enum ProfileLibraryBackupCodec {
    private struct Envelope: Decodable {
        var format: String
        var version: Int
    }

    public static func encode(_ backup: ProfileLibraryBackup) throws -> Data {
        try ProfilePersistence.validate(backup.profileStore)
        if let bufferPreferences = backup.bufferPreferences,
            bufferPreferences.count > ProfileLibraryBackup.maxBufferPreferencesBytes
        {
            throw ProfileLibraryBackupError.bufferPreferencesTooLarge(
                byteCount: bufferPreferences.count,
                maximum: ProfileLibraryBackup.maxBufferPreferencesBytes
            )
        }
        var committed = backup
        committed.profileStore.upgradeSchema()
        // Compact output: a pretty-printed store nested one level deeper would grow past the
        // store's own size limit before the backup limit allows for it.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(committed)
        guard data.count <= ProfileLibraryBackup.maxBytes else {
            throw ProfileLibraryBackupError.inputTooLarge(byteCount: data.count, maximum: ProfileLibraryBackup.maxBytes)
        }
        return data
    }

    /// Decodes untrusted input. The envelope is checked before the payload so a newer format fails
    /// with its version rather than a decoding error, and the store is validated and its references
    /// repaired exactly as a loaded store would be.
    public static func decode(_ data: Data) throws -> ProfileLibraryBackup {
        guard data.count <= ProfileLibraryBackup.maxBytes else {
            throw ProfileLibraryBackupError.inputTooLarge(byteCount: data.count, maximum: ProfileLibraryBackup.maxBytes)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let envelope = try? decoder.decode(Envelope.self, from: data),
            envelope.format == ProfileLibraryBackup.formatIdentifier
        else {
            throw ProfileLibraryBackupError.notALibraryBackup
        }
        guard envelope.version >= 1, envelope.version <= ProfileLibraryBackup.currentVersion else {
            throw ProfileLibraryBackupError.unsupportedVersion(
                version: envelope.version, maximum: ProfileLibraryBackup.currentVersion)
        }
        var backup: ProfileLibraryBackup
        do {
            backup = try decoder.decode(ProfileLibraryBackup.self, from: data)
        } catch {
            throw ProfileLibraryBackupError.invalidStore(String(describing: error))
        }
        guard (1...ProfileStore.currentSchemaVersion).contains(backup.profileStore.schemaVersion) else {
            throw ProfileLibraryBackupError.unsupportedStoreSchema(
                version: backup.profileStore.schemaVersion, maximum: ProfileStore.currentSchemaVersion)
        }
        if let bufferPreferences = backup.bufferPreferences,
            bufferPreferences.count > ProfileLibraryBackup.maxBufferPreferencesBytes
        {
            throw ProfileLibraryBackupError.bufferPreferencesTooLarge(
                byteCount: bufferPreferences.count,
                maximum: ProfileLibraryBackup.maxBufferPreferencesBytes
            )
        }
        guard !backup.profileStore.profiles.isEmpty else {
            throw ProfileLibraryBackupError.invalidStore(
                ProfileStoreValidationError.invalidProfileCount(count: 0, allowed: ProfilePersistence.profileCountRange)
                    .localizedDescription)
        }
        _ = backup.profileStore.repairReferences()
        backup.profileStore.upgradeSchema()
        do {
            try ProfilePersistence.validate(backup.profileStore)
        } catch {
            throw ProfileLibraryBackupError.invalidStore(error.localizedDescription)
        }
        return backup
    }

    /// Reads at most the size limit plus one byte so an oversized file is rejected without being
    /// loaded whole.
    public static func read(from url: URL) throws -> ProfileLibraryBackup {
        do {
            return try decode(ProfilePersistence.readStoreData(from: url, maxBytes: ProfileLibraryBackup.maxBytes))
        } catch let ProfileStoreValidationError.inputTooLarge(byteCount, maximum) {
            throw ProfileLibraryBackupError.inputTooLarge(byteCount: byteCount, maximum: maximum)
        }
    }
}

public struct ProfileLibraryMergeSummary: Codable, Equatable, Sendable {
    /// Profiles whose identifier was new to the library.
    public var addedProfiles = 0
    /// Profiles whose identifier already existed with different contents; they were added under a
    /// new identifier so nothing in the current library changed.
    public var copiedProfiles = 0
    /// Profiles identical to one already in the library.
    public var unchangedProfiles = 0
    /// Output mappings for outputs that had no mapping.
    public var addedMappings = 0
    /// Output mappings left alone because the output already had one.
    public var skippedMappings = 0
    public var resultingProfileCount = 0

    public init() {}

    public var exceedsProfileLimit: Bool {
        resultingProfileCount > ProfilePersistence.profileCountRange.upperBound
    }
}

/// Adds a saved library to the current one without replacing anything already there.
public enum ProfileLibraryMerge {
    public static let copiedProfileNameSuffix = " (imported)"

    public static func preview(current: ProfileStore, incoming: ProfileStore) -> ProfileLibraryMergeSummary {
        plan(current: current, incoming: incoming).summary
    }

    public static func merge(current: ProfileStore, incoming: ProfileStore) throws -> (
        store: ProfileStore, summary: ProfileLibraryMergeSummary
    ) {
        let planned = plan(current: current, incoming: incoming)
        guard !planned.summary.exceedsProfileLimit else {
            throw ProfileLibraryBackupError.tooManyProfiles(
                count: planned.summary.resultingProfileCount,
                maximum: ProfilePersistence.profileCountRange.upperBound
            )
        }
        try ProfilePersistence.validate(planned.store)
        return (planned.store, planned.summary)
    }

    private static func plan(current: ProfileStore, incoming: ProfileStore) -> (
        store: ProfileStore, summary: ProfileLibraryMergeSummary
    ) {
        var store = current
        var summary = ProfileLibraryMergeSummary()
        var remappedIDs: [UUID: UUID] = [:]

        for profile in incoming.profiles {
            if let existing = current.profiles.first(where: { $0.id == profile.id }) {
                if existing == profile {
                    summary.unchangedProfiles += 1
                    continue
                }
                var copy = profile
                copy.id = UUID()
                copy.name = copiedName(for: profile.name)
                remappedIDs[profile.id] = copy.id
                store.profiles.append(copy)
                summary.copiedProfiles += 1
            } else {
                store.profiles.append(profile)
                summary.addedProfiles += 1
            }
        }

        let mappedUIDs = Set(current.outputMappings.map(\.outputDeviceUID))
        for mapping in incoming.outputMappings {
            guard !mappedUIDs.contains(mapping.outputDeviceUID) else {
                summary.skippedMappings += 1
                continue
            }
            let profileID = remappedIDs[mapping.profileID] ?? mapping.profileID
            guard store.profiles.contains(where: { $0.id == profileID }) else {
                summary.skippedMappings += 1
                continue
            }
            store.outputMappings.append(
                OutputDeviceProfileMapping(outputDeviceUID: mapping.outputDeviceUID, profileID: profileID))
            summary.addedMappings += 1
        }

        summary.resultingProfileCount = store.profiles.count
        return (store, summary)
    }

    private static func copiedName(for name: String) -> String {
        let suffix = copiedProfileNameSuffix
        let budget = ProfilePersistence.maxProfileNameUTF8Bytes - suffix.utf8.count
        var base = name
        while base.utf8.count > budget, !base.isEmpty {
            base.removeLast()
        }
        return base + suffix
    }
}
