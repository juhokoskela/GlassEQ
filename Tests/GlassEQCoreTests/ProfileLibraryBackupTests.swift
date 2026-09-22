import Foundation
import GlassEQCore
import Testing

@Suite
struct ProfileLibraryBackupCodecTests {
    private let createdAt = Date(timeIntervalSince1970: 1_704_067_200)

    private func makeLibrary() -> ProfileStore {
        var convolution = EQProfile.flatConvolution
        convolution.name = "Room"
        convolution.convolution = .impulseResponse(
            ImpulseResponseSource(sampleRate: 48_000, samples: [1, 0.5, 0.25, 0.125]))
        let parametric = EQProfile(
            name: "Speakers", mode: .parametric,
            filters: [EQFilter(kind: .peak, frequency: 100, gainDB: 3, q: 1)])
        return ProfileStore(
            profiles: [parametric, convolution],
            outputMappings: [OutputDeviceProfileMapping(outputDeviceUID: "speakers", profileID: parametric.id)],
            fallbackProfileID: convolution.id
        )
    }

    @Test
    func emptyLibraryIsRefusedInsteadOfBecomingDefaults() throws {
        let backup = ProfileLibraryBackup(
            createdAt: createdAt, appVersion: nil, profileStore: ProfileStore(profiles: []))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        #expect(throws: ProfileLibraryBackupError.self) {
            try ProfileLibraryBackupCodec.decode(encoder.encode(backup))
        }
    }

    @Test
    func roundTripsProfilesImpulseResponsesMappingsFallbackAndPreferences() throws {
        let preferences = Data("{\"records\":[]}".utf8)
        let backup = ProfileLibraryBackup(
            createdAt: createdAt, appVersion: "v1.0 (20)", profileStore: makeLibrary(),
            bufferPreferences: preferences)

        let data = try ProfileLibraryBackupCodec.encode(backup)
        let decoded = try ProfileLibraryBackupCodec.decode(data)

        #expect(decoded == backup)
        #expect(decoded.profileStore.profiles[1].convolution == backup.profileStore.profiles[1].convolution)
        let json = try #require(String(bytes: data, encoding: .utf8))
        #expect(json.contains("\"format\":\"glasseq-profile-library\""))
        #expect(json.contains("\"createdAt\":\"2024-01-01T00:00:00Z\""))
    }

    @Test
    func readsFromAFileAndRejectsOversizedFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlassEQCoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let backup = ProfileLibraryBackup(createdAt: createdAt, appVersion: nil, profileStore: makeLibrary())
        let url = directory.appendingPathComponent("library.json")
        try ProfileLibraryBackupCodec.encode(backup).write(to: url)

        #expect(try ProfileLibraryBackupCodec.read(from: url) == backup)

        let oversized = directory.appendingPathComponent("oversized.json")
        try Data(repeating: UInt8(ascii: " "), count: ProfileLibraryBackup.maxBytes + 1).write(to: oversized)
        #expect(
            throws: ProfileLibraryBackupError.inputTooLarge(
                byteCount: ProfileLibraryBackup.maxBytes + 1, maximum: ProfileLibraryBackup.maxBytes)
        ) {
            try ProfileLibraryBackupCodec.read(from: oversized)
        }
    }

    @Test
    func rejectsFilesThatAreNotLibraries() {
        #expect(throws: ProfileLibraryBackupError.notALibraryBackup) {
            try ProfileLibraryBackupCodec.decode(Data("not json".utf8))
        }
        #expect(throws: ProfileLibraryBackupError.notALibraryBackup) {
            try ProfileLibraryBackupCodec.decode(try ProfilePersistence.encode(makeLibrary()))
        }
        #expect(throws: ProfileLibraryBackupError.notALibraryBackup) {
            try ProfileLibraryBackupCodec.decode(Data("{\"format\":\"other\",\"version\":1}".utf8))
        }
    }

    @Test
    func rejectsNewerFormatAndNewerStoreSchema() throws {
        let newerFormat = Data(
            "{\"format\":\"glasseq-profile-library\",\"version\":2,\"createdAt\":\"2024-01-01T00:00:00Z\",\"profileStore\":{}}"
                .utf8)
        #expect(throws: ProfileLibraryBackupError.unsupportedVersion(version: 2, maximum: 1)) {
            try ProfileLibraryBackupCodec.decode(newerFormat)
        }

        let library = makeLibrary()
        let futureStore = ProfileStore(
            schemaVersion: ProfileStore.currentSchemaVersion + 1,
            profiles: library.profiles, outputMappings: library.outputMappings,
            fallbackProfileID: library.fallbackProfileID)
        let backup = ProfileLibraryBackup(createdAt: createdAt, appVersion: nil, profileStore: futureStore)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(backup)
        #expect(
            throws: ProfileLibraryBackupError.unsupportedStoreSchema(
                version: ProfileStore.currentSchemaVersion + 1, maximum: ProfileStore.currentSchemaVersion)
        ) {
            try ProfileLibraryBackupCodec.decode(data)
        }
    }

    @Test
    func rejectsDuplicateProfileIdentifiersAndOversizedPreferences() throws {
        var duplicated = makeLibrary()
        duplicated.profiles.append(duplicated.profiles[0])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(
            ProfileLibraryBackup(createdAt: createdAt, appVersion: nil, profileStore: duplicated))

        #expect {
            try ProfileLibraryBackupCodec.decode(data)
        } throws: { error in
            if case .invalidStore = error as? ProfileLibraryBackupError {
                return true
            }
            return false
        }

        let oversized = ProfileLibraryBackup(
            createdAt: createdAt, appVersion: nil, profileStore: makeLibrary(),
            bufferPreferences: Data(count: ProfileLibraryBackup.maxBufferPreferencesBytes + 1))
        #expect(
            throws: ProfileLibraryBackupError.bufferPreferencesTooLarge(
                byteCount: ProfileLibraryBackup.maxBufferPreferencesBytes + 1,
                maximum: ProfileLibraryBackup.maxBufferPreferencesBytes)
        ) {
            try ProfileLibraryBackupCodec.encode(oversized)
        }
    }

    @Test
    func repairsDanglingReferencesInsteadOfRejectingThem() throws {
        var store = makeLibrary()
        store.outputMappings.append(OutputDeviceProfileMapping(outputDeviceUID: "gone", profileID: UUID()))
        store.fallbackProfileID = UUID()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(ProfileLibraryBackup(createdAt: createdAt, appVersion: nil, profileStore: store))

        let decoded = try ProfileLibraryBackupCodec.decode(data)

        #expect(decoded.profileStore.outputMappings.count == 1)
        #expect(decoded.profileStore.fallbackProfileID == store.profiles[0].id)
    }
}

@Suite
struct ProfileLibraryMergeTests {
    private func profile(_ name: String, gain: Double = 0) -> EQProfile {
        EQProfile(name: name, mode: .parametric, filters: [EQFilter(kind: .peak, frequency: 1_000, gainDB: gain, q: 1)])
    }

    @Test
    func addsNewProfilesCopiesConflictsAndSkipsIdenticalOnes() throws {
        let shared = profile("Shared")
        var edited = shared
        edited.filters[0].gainDB = 6
        let mine = profile("Mine")
        let theirs = profile("Theirs")
        let current = ProfileStore(profiles: [mine, shared], fallbackProfileID: mine.id)
        let incoming = ProfileStore(profiles: [theirs, edited, shared], fallbackProfileID: theirs.id)

        let result = try ProfileLibraryMerge.merge(current: current, incoming: incoming)

        #expect(result.summary.addedProfiles == 1)
        #expect(result.summary.copiedProfiles == 1)
        #expect(result.summary.unchangedProfiles == 1)
        #expect(result.summary.resultingProfileCount == 4)
        #expect(result.store.fallbackProfileID == mine.id)
        #expect(result.store.profiles.map(\.name) == ["Mine", "Shared", "Theirs", "Shared (imported)"])
        let copy = result.store.profiles[3]
        #expect(copy.id != shared.id)
        #expect(copy.filters == edited.filters)
        #expect(result.store.profiles[1] == shared)
    }

    @Test
    func keepsExistingMappingsAndRemapsCopiedProfiles() throws {
        let shared = profile("Shared")
        var edited = shared
        edited.preampDB = -3
        let mine = profile("Mine")
        let current = ProfileStore(
            profiles: [mine, shared],
            outputMappings: [OutputDeviceProfileMapping(outputDeviceUID: "speakers", profileID: mine.id)],
            fallbackProfileID: mine.id)
        let incoming = ProfileStore(
            profiles: [edited],
            outputMappings: [
                OutputDeviceProfileMapping(outputDeviceUID: "speakers", profileID: edited.id),
                OutputDeviceProfileMapping(outputDeviceUID: "headphones", profileID: edited.id),
            ],
            fallbackProfileID: edited.id)

        let result = try ProfileLibraryMerge.merge(current: current, incoming: incoming)

        #expect(result.summary.addedMappings == 1)
        #expect(result.summary.skippedMappings == 1)
        let headphones = try #require(result.store.outputMappings.first { $0.outputDeviceUID == "headphones" })
        #expect(headphones.profileID == result.store.profiles[2].id)
        #expect(result.store.profile(forOutputUID: "speakers") == mine)
    }

    @Test
    func refusesAMergeThatWouldExceedTheProfileLimit() {
        let limit = ProfilePersistence.profileCountRange.upperBound
        let current = ProfileStore(profiles: (0..<limit).map { profile("Current \($0)") })
        let incoming = ProfileStore(profiles: [profile("One more")])

        let preview = ProfileLibraryMerge.preview(current: current, incoming: incoming)
        #expect(preview.exceedsProfileLimit)
        #expect(throws: ProfileLibraryBackupError.tooManyProfiles(count: limit + 1, maximum: limit)) {
            try ProfileLibraryMerge.merge(current: current, incoming: incoming)
        }
    }

    @Test
    func copiedNamesStayWithinTheNameLimit() throws {
        let longName = String(repeating: "x", count: ProfilePersistence.maxProfileNameUTF8Bytes)
        let shared = profile(longName)
        var edited = shared
        edited.preampDB = -1
        let current = ProfileStore(profiles: [shared])

        let result = try ProfileLibraryMerge.merge(current: current, incoming: ProfileStore(profiles: [edited]))

        let copy = result.store.profiles[1]
        #expect(copy.name.utf8.count == ProfilePersistence.maxProfileNameUTF8Bytes)
        #expect(copy.name.hasSuffix(ProfileLibraryMerge.copiedProfileNameSuffix))
    }
}
