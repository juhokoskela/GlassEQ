import Foundation
import GlassEQCore
import Testing

@Suite
struct ProfilePersistenceTests {
    private let timestamp = Date(timeIntervalSince1970: 1_704_067_200)

    @Test
    func loadBacksUpValidationInvalidStoreAndWritesDefaults() throws {
        let url = try temporaryStoreURL()
        defer { removeTemporaryStoreDirectory(for: url) }
        let invalidStore = ProfileStore(
            profiles: [EQProfile(name: "", mode: .parametric, filters: [])],
            fallbackProfileID: UUID()
        )
        let invalidData = try ProfilePersistence.encoder.encode(invalidStore)
        try invalidData.write(to: url)

        let result = ProfilePersistence.load(from: url, timestamp: timestamp)

        guard case .recoveredDefaults(let backupURL) = result.status else {
            Issue.record("Expected invalid store recovery, got \(result.status)")
            return
        }
        #expect(result.store.profiles == ProfileStore.defaultProfiles)
        #expect(try Data(contentsOf: backupURL) == invalidData)

        let savedStore = try ProfilePersistence.decode(Data(contentsOf: url))
        #expect(savedStore.profiles == ProfileStore.defaultProfiles)
    }

    @Test
    func loadUsesUniqueInvalidBackupNameWhenTimestampCollides() throws {
        let url = try temporaryStoreURL()
        defer { removeTemporaryStoreDirectory(for: url) }
        let invalidData = Data("not json".utf8)
        try invalidData.write(to: url)
        let backupURL = ProfilePersistence.invalidStoreBackupURL(for: url, timestamp: timestamp)
        let collisionData = Data("existing backup".utf8)
        try collisionData.write(to: backupURL)

        let result = ProfilePersistence.load(from: url, timestamp: timestamp)

        guard case .recoveredDefaults(let recoveredBackupURL) = result.status else {
            Issue.record("Expected invalid store recovery, got \(result.status)")
            return
        }
        #expect(result.store.profiles == ProfileStore.defaultProfiles)
        #expect(recoveredBackupURL != backupURL)
        #expect(recoveredBackupURL.lastPathComponent.contains("-2"))
        #expect(try Data(contentsOf: recoveredBackupURL) == invalidData)
        #expect(try Data(contentsOf: backupURL) == collisionData)
    }

    @Test
    func loadBacksUpOversizedStoreBeforeDecode() throws {
        let url = try temporaryStoreURL()
        defer { removeTemporaryStoreDirectory(for: url) }
        let oversizedData = Data(repeating: 0, count: ProfilePersistence.maxStoreBytes + 1)
        try oversizedData.write(to: url)

        let result = ProfilePersistence.load(from: url, timestamp: timestamp)

        guard case .recoveredDefaults(let backupURL) = result.status else {
            Issue.record("Expected oversized store recovery, got \(result.status)")
            return
        }
        #expect((try Data(contentsOf: backupURL)).count == oversizedData.count)
        #expect(try ProfilePersistence.decode(Data(contentsOf: url)).profiles == ProfileStore.defaultProfiles)
    }

    @Test
    func loadFutureSchemaUsesDefaultsWithoutModifyingStore() throws {
        let url = try temporaryStoreURL()
        defer { removeTemporaryStoreDirectory(for: url) }
        let profile = EQProfile(name: "Future", mode: .parametric, filters: [])
        let futureStore = ProfileStore(
            schemaVersion: ProfileStore.currentSchemaVersion + 1,
            profiles: [profile],
            fallbackProfileID: profile.id
        )
        let data = try ProfilePersistence.encoder.encode(futureStore)
        try data.write(to: url)

        let result = ProfilePersistence.load(from: url, timestamp: timestamp)

        #expect(result.store.profiles == ProfileStore.defaultProfiles)
        #expect(result.status == .unsupportedSchemaVersion(
            version: ProfileStore.currentSchemaVersion + 1,
            maximumSupported: ProfileStore.currentSchemaVersion
        ))
        #expect(try Data(contentsOf: url) == data)
    }

    @Test
    func loadRepairsInvalidProfileWithoutDroppingValidProfiles() throws {
        let url = try temporaryStoreURL()
        defer { removeTemporaryStoreDirectory(for: url) }
        let valid = EQProfile(name: "Valid", mode: .parametric, filters: [])
        let invalid = EQProfile(name: "", mode: .parametric, filters: [])
        let store = ProfileStore(
            profiles: [valid, invalid],
            outputMappings: [
                OutputDeviceProfileMapping(outputDeviceUID: "speaker", profileID: valid.id),
                OutputDeviceProfileMapping(outputDeviceUID: "broken", profileID: invalid.id)
            ],
            fallbackProfileID: invalid.id
        )
        let invalidData = try ProfilePersistence.encoder.encode(store)
        try invalidData.write(to: url)

        let result = ProfilePersistence.load(from: url, timestamp: timestamp)

        guard case .repairedInvalidStore(let backupURL, let summary) = result.status else {
            Issue.record("Expected invalid profile repair, got \(result.status)")
            return
        }
        #expect(try Data(contentsOf: backupURL) == invalidData)
        #expect(result.store.profiles == [valid])
        #expect(result.store.outputMappings == [OutputDeviceProfileMapping(outputDeviceUID: "speaker", profileID: valid.id)])
        #expect(result.store.fallbackProfileID == valid.id)
        #expect(summary.removedInvalidProfiles == 1)
        #expect(summary.repairedFallbackProfileID)
        #expect(summary.removedOutputMappings == 1)
    }

    @Test
    func loadDropsProfileWithMalformedFilterWithoutResettingStore() throws {
        let url = try temporaryStoreURL()
        defer { removeTemporaryStoreDirectory(for: url) }
        let valid = EQProfile(name: "Valid", mode: .parametric, filters: [])
        let invalid = EQProfile(
            name: "Malformed",
            mode: .parametric,
            filters: [EQFilter(kind: .peak, frequency: 1_000, gainDB: 1, q: 1)]
        )
        var invalidObject = try profileJSONObject(invalid)
        var filters = try #require(invalidObject["filters"] as? [[String: Any]])
        filters[0]["frequency"] = "not-a-number"
        invalidObject["filters"] = filters
        let invalidData = try rawStoreData(
            profiles: [
                try profileJSONObject(valid),
                invalidObject
            ],
            outputMappings: [
                OutputDeviceProfileMapping(outputDeviceUID: "speaker", profileID: valid.id),
                OutputDeviceProfileMapping(outputDeviceUID: "broken", profileID: invalid.id)
            ],
            fallbackProfileID: invalid.id
        )
        try invalidData.write(to: url)

        let result = ProfilePersistence.load(from: url, timestamp: timestamp)

        guard case .repairedInvalidStore(let backupURL, let summary) = result.status else {
            Issue.record("Expected malformed profile repair, got \(result.status)")
            return
        }
        #expect(try Data(contentsOf: backupURL) == invalidData)
        #expect(result.store.profiles == [valid])
        #expect(result.store.outputMappings == [
            OutputDeviceProfileMapping(outputDeviceUID: "speaker", profileID: valid.id)
        ])
        #expect(result.store.fallbackProfileID == valid.id)
        #expect(summary.removedInvalidProfiles == 1)
        #expect(summary.removedOutputMappings == 1)
        #expect(summary.repairedFallbackProfileID)
        #expect(try ProfilePersistence.decode(Data(contentsOf: url)) == result.store)
    }

    @Test
    func loadRecoversDefaultsWhenAllProfilesFailRepairableDecode() throws {
        let url = try temporaryStoreURL()
        defer { removeTemporaryStoreDirectory(for: url) }
        let invalid = EQProfile(
            name: "Malformed",
            mode: .parametric,
            filters: [EQFilter(kind: .peak, frequency: 1_000, gainDB: 1, q: 1)]
        )
        var invalidObject = try profileJSONObject(invalid)
        var filters = try #require(invalidObject["filters"] as? [[String: Any]])
        filters[0]["q"] = "bad-q"
        invalidObject["filters"] = filters
        let invalidData = try rawStoreData(
            profiles: [invalidObject],
            outputMappings: [
                OutputDeviceProfileMapping(outputDeviceUID: "broken", profileID: invalid.id)
            ],
            fallbackProfileID: invalid.id
        )
        try invalidData.write(to: url)

        let result = ProfilePersistence.load(from: url, timestamp: timestamp)

        guard case .recoveredDefaults(let backupURL) = result.status else {
            Issue.record("Expected malformed store recovery, got \(result.status)")
            return
        }
        #expect(try Data(contentsOf: backupURL) == invalidData)
        #expect(result.store.profiles == ProfileStore.defaultProfiles)
        #expect(try ProfilePersistence.decode(Data(contentsOf: url)).profiles == ProfileStore.defaultProfiles)
    }

    @Test
    func loadRepairsDuplicateProfileIDsByKeepingFirstProfile() throws {
        let url = try temporaryStoreURL()
        defer { removeTemporaryStoreDirectory(for: url) }
        let duplicateID = UUID()
        let first = EQProfile(id: duplicateID, name: "First", mode: .parametric, filters: [])
        let duplicate = EQProfile(id: duplicateID, name: "Duplicate", mode: .parametric, filters: [])
        let valid = EQProfile(name: "Valid", mode: .parametric, filters: [])
        let missingProfileID = UUID()
        let store = ProfileStore(
            profiles: [first, duplicate, valid],
            outputMappings: [
                OutputDeviceProfileMapping(outputDeviceUID: "speaker", profileID: duplicateID),
                OutputDeviceProfileMapping(outputDeviceUID: "missing", profileID: missingProfileID)
            ],
            fallbackProfileID: missingProfileID
        )
        let invalidData = try ProfilePersistence.encoder.encode(store)
        try invalidData.write(to: url)

        let result = ProfilePersistence.load(from: url, timestamp: timestamp)

        guard case .repairedInvalidStore(let backupURL, let summary) = result.status else {
            Issue.record("Expected invalid store repair, got \(result.status)")
            return
        }
        #expect(try Data(contentsOf: backupURL) == invalidData)
        #expect(result.store.profiles == [first, valid])
        #expect(result.store.outputMappings == [
            OutputDeviceProfileMapping(outputDeviceUID: "speaker", profileID: duplicateID)
        ])
        #expect(result.store.fallbackProfileID == first.id)
        #expect(summary.removedInvalidProfiles == 1)
        #expect(summary.repairedFallbackProfileID)
        #expect(summary.removedOutputMappings == 1)
        #expect(try ProfilePersistence.decode(Data(contentsOf: url)) == result.store)
    }

    @Test
    func loadRepairsReferencesAndSavesRepairedStore() throws {
        let url = try temporaryStoreURL()
        defer { removeTemporaryStoreDirectory(for: url) }
        let first = EQProfile(name: "First", mode: .parametric, filters: [])
        let second = EQProfile(name: "Second", mode: .parametric, filters: [])
        let missingProfileID = UUID()
        let store = ProfileStore(
            profiles: [first, second],
            outputMappings: [
                OutputDeviceProfileMapping(outputDeviceUID: "", profileID: first.id),
                OutputDeviceProfileMapping(outputDeviceUID: "dac", profileID: missingProfileID),
                OutputDeviceProfileMapping(outputDeviceUID: "dac", profileID: first.id),
                OutputDeviceProfileMapping(outputDeviceUID: "dac", profileID: second.id)
            ],
            fallbackProfileID: missingProfileID
        )
        try ProfilePersistence.encoder.encode(store).write(to: url)

        let result = ProfilePersistence.load(from: url, timestamp: timestamp)

        guard case .repairedReferences(let summary) = result.status else {
            Issue.record("Expected repaired references, got \(result.status)")
            return
        }
        #expect(summary.repairedFallbackProfileID)
        #expect(summary.removedOutputMappings == 2)
        #expect(summary.deduplicatedOutputMappings == 1)
        #expect(result.store.outputMappings == [
            OutputDeviceProfileMapping(outputDeviceUID: "dac", profileID: second.id)
        ])

        let savedStore = try ProfilePersistence.decode(Data(contentsOf: url))
        #expect(savedStore == result.store)
    }

    @Test
    func decodeRejectsProfileStoreOutsideSizeLimit() throws {
        let oversizedData = Data(repeating: 0, count: ProfilePersistence.maxStoreBytes + 1)

        do {
            _ = try ProfilePersistence.decode(oversizedData)
            Issue.record("Expected oversized profile store to fail")
        } catch let error as ProfileStoreValidationError {
            #expect(error == .inputTooLarge(
                byteCount: oversizedData.count,
                maximum: ProfilePersistence.maxStoreBytes
            ))
        }
    }

    @Test
    func decodeRejectsProfileStoreValidationFailures() throws {
        try expectValidationFailure(
            ProfileStore(profiles: [], fallbackProfileID: UUID()),
            expected: .invalidProfileCount(count: 0, allowed: ProfilePersistence.profileCountRange)
        )

        let profile = EQProfile(name: "Valid", mode: .parametric, filters: [])
        let missingFallbackID = UUID()
        try expectValidationFailure(
            ProfileStore(profiles: [profile], fallbackProfileID: missingFallbackID),
            expected: .missingFallbackProfile(profileID: missingFallbackID)
        )

        let duplicateID = UUID()
        let firstDuplicate = EQProfile(id: duplicateID, name: "First", mode: .parametric, filters: [])
        let secondDuplicate = EQProfile(id: duplicateID, name: "Second", mode: .parametric, filters: [])
        try expectValidationFailure(
            ProfileStore(profiles: [firstDuplicate, secondDuplicate], fallbackProfileID: duplicateID),
            expected: .duplicateProfileID(profileID: duplicateID)
        )

        let tooManyMappings = (0...ProfilePersistence.outputMappingCountRange.upperBound).map {
            OutputDeviceProfileMapping(outputDeviceUID: "output-\($0)", profileID: EQProfile.flatParametric.id)
        }
        try expectValidationFailure(
            ProfileStore(outputMappings: tooManyMappings),
            expected: .invalidOutputMappingCount(
                count: ProfilePersistence.outputMappingCountRange.upperBound + 1,
                allowed: ProfilePersistence.outputMappingCountRange
            )
        )

        let longNameProfile = EQProfile(
            name: String(repeating: "a", count: ProfilePersistence.maxProfileNameUTF8Bytes + 1),
            mode: .parametric,
            filters: []
        )
        try expectValidationFailure(
            ProfileStore(profiles: [longNameProfile], fallbackProfileID: longNameProfile.id),
            expected: .profileNameTooLong(
                profileID: longNameProfile.id,
                byteCount: ProfilePersistence.maxProfileNameUTF8Bytes + 1,
                maximum: ProfilePersistence.maxProfileNameUTF8Bytes
            )
        )

        try expectValidationFailure(
            ProfileStore(outputMappings: [
                OutputDeviceProfileMapping(
                    outputDeviceUID: String(repeating: "u", count: ProfilePersistence.maxOutputUIDUTF8Bytes + 1),
                    profileID: ProfileStore.defaultProfiles[0].id
                )
            ]),
            expected: .outputUIDTooLong(
                mappingIndex: 0,
                byteCount: ProfilePersistence.maxOutputUIDUTF8Bytes + 1,
                maximum: ProfilePersistence.maxOutputUIDUTF8Bytes
            )
        )
    }

    @Test
    func saveRejectsInvalidStoreAndLeavesExistingFileUntouched() throws {
        let url = try temporaryStoreURL()
        defer { removeTemporaryStoreDirectory(for: url) }
        let validProfile = EQProfile(name: "Valid", mode: .parametric, filters: [])
        let validStore = ProfileStore(profiles: [validProfile], fallbackProfileID: validProfile.id)
        try ProfilePersistence.save(validStore, to: url)
        let originalData = try Data(contentsOf: url)

        let missingFallbackID = UUID()
        let invalidStore = ProfileStore(profiles: [validProfile], fallbackProfileID: missingFallbackID)

        #expect(throws: ProfileStoreValidationError.missingFallbackProfile(profileID: missingFallbackID)) {
            try ProfilePersistence.save(invalidStore, to: url)
        }
        #expect(try Data(contentsOf: url) == originalData)
        #expect(try ProfilePersistence.decode(Data(contentsOf: url)) == validStore)
    }

    @Test
    func decodeRejectsInvalidFilterBoundsAndCounts() throws {
        let invalidFrequency = EQProfile(
            name: "Invalid Frequency",
            mode: .parametric,
            filters: [EQFilter(kind: .peak, frequency: 0, gainDB: 0, q: 1)]
        )
        try expectValidationFailure(
            ProfileStore(profiles: [invalidFrequency], fallbackProfileID: invalidFrequency.id),
            expected: .valueOutOfRange(
                profileID: invalidFrequency.id,
                field: "frequency",
                value: 0,
                range: ProfilePersistence.frequencyRange
            )
        )

        let abovePolicyFrequency = EQProfile(
            name: "Above Policy Frequency",
            mode: .parametric,
            filters: [EQFilter(kind: .peak, frequency: 24_001, gainDB: 0, q: 1)]
        )
        try expectValidationFailure(
            ProfileStore(profiles: [abovePolicyFrequency], fallbackProfileID: abovePolicyFrequency.id),
            expected: .valueOutOfRange(
                profileID: abovePolicyFrequency.id,
                field: "frequency",
                value: 24_001,
                range: ProfilePersistence.frequencyRange
            )
        )

        let tooManyFilters = EQProfile(
            name: "Too Many",
            mode: .parametric,
            filters: (0...ProfilePersistence.maxActiveFiltersPerChannel).map {
                EQFilter(kind: .peak, frequency: Double($0 + 1), gainDB: 0, q: 1)
            }
        )
        try expectValidationFailure(
            ProfileStore(profiles: [tooManyFilters], fallbackProfileID: tooManyFilters.id),
            expected: .tooManyActiveFilters(
                profileID: tooManyFilters.id,
                channel: "linked",
                count: ProfilePersistence.maxActiveFiltersPerChannel + 1,
                maximum: ProfilePersistence.maxActiveFiltersPerChannel
            )
        )

        let tooManyDisabledFilters = EQProfile(
            name: "Too Many Disabled",
            mode: .parametric,
            filters: (0...ProfilePersistence.maxFiltersPerChannel).map {
                EQFilter(kind: .peak, frequency: Double($0 + 1), gainDB: 0, q: 1, isEnabled: false)
            }
        )
        try expectValidationFailure(
            ProfileStore(profiles: [tooManyDisabledFilters], fallbackProfileID: tooManyDisabledFilters.id),
            expected: .tooManyFilters(
                profileID: tooManyDisabledFilters.id,
                channel: "linked",
                count: ProfilePersistence.maxFiltersPerChannel + 1,
                maximum: ProfilePersistence.maxFiltersPerChannel
            )
        )
    }

    @Test
    func decodeRejectsGraphicProfilesWithoutExactActiveBandCount() throws {
        var filters = EQProfile.flatGraphic10.filters
        filters[0].isEnabled = false
        let profile = EQProfile(name: "Broken Graphic", mode: .graphic10, filters: filters)

        try expectValidationFailure(
            ProfileStore(profiles: [profile], fallbackProfileID: profile.id),
            expected: .invalidGraphicBandCount(
                profileID: profile.id,
                channel: "linked",
                count: 9,
                expected: 10
            )
        )
    }

    @Test
    func convolutionProfileRoundTripsMagnitudeCurveSource() throws {
        var profile = EQProfile.flatConvolution
        profile.name = "Room Curve"
        profile.preampDB = -5.5
        profile.convolution = .magnitudeCurve(MagnitudeCurveSource(points: [
            EQMagnitudePoint(frequency: 20, gainDB: 4),
            EQMagnitudePoint(frequency: 1_000, gainDB: -2),
            EQMagnitudePoint(frequency: 20_000, gainDB: 1)
        ]))
        let store = ProfileStore(profiles: [profile], fallbackProfileID: profile.id)

        let decoded = try ProfilePersistence.decode(ProfilePersistence.encode(store))

        #expect(decoded == store)
    }

    @Test
    func decodeRejectsConvolutionProfileWithoutSource() throws {
        let profile = EQProfile(
            name: "Missing Curve",
            mode: .convolution,
            filters: []
        )

        try expectValidationFailure(
            ProfileStore(profiles: [profile], fallbackProfileID: profile.id),
            expected: .missingConvolutionSource(
                profileID: profile.id,
                channel: "linked"
            )
        )
    }

    @Test
    func decodeRejectsUnsupportedConvolutionSynthesisVersion() throws {
        var profile = EQProfile.flatConvolution
        profile.convolution = .magnitudeCurve(MagnitudeCurveSource(
            synthesisVersion: MinimumPhaseFIRCompiler.synthesisVersion + 1,
            points: [
                EQMagnitudePoint(frequency: 20, gainDB: 0),
                EQMagnitudePoint(frequency: 20_000, gainDB: 0)
            ]
        ))

        try expectValidationFailure(
            ProfileStore(profiles: [profile], fallbackProfileID: profile.id),
            expected: .unsupportedSynthesisVersion(
                profileID: profile.id,
                version: MinimumPhaseFIRCompiler.synthesisVersion + 1
            )
        )
    }

    @Test
    func decodeRejectsConvolutionCurveWithDuplicateFrequency() throws {
        var profile = EQProfile.flatConvolution
        profile.convolution = .magnitudeCurve(MagnitudeCurveSource(points: [
            EQMagnitudePoint(frequency: 100, gainDB: 1),
            EQMagnitudePoint(frequency: 100, gainDB: -1)
        ]))

        try expectValidationFailure(
            ProfileStore(profiles: [profile], fallbackProfileID: profile.id),
            expected: .duplicateMagnitudeFrequency(
                profileID: profile.id,
                channel: "linked",
                frequency: 100
            )
        )
    }

    private func expectValidationFailure(
        _ store: ProfileStore,
        expected: ProfileStoreValidationError
    ) throws {
        do {
            _ = try ProfilePersistence.decode(ProfilePersistence.encoder.encode(store))
            Issue.record("Expected profile store validation to fail")
        } catch let error as ProfileStoreValidationError {
            #expect(error == expected)
        }
    }

    private func temporaryStoreURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlassEQCoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("Profiles.json")
    }

    private func removeTemporaryStoreDirectory(for url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    private func profileJSONObject(_ profile: EQProfile) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: ProfilePersistence.encoder.encode(profile))
        return try #require(object as? [String: Any])
    }

    private func rawStoreData(
        profiles: [[String: Any]],
        outputMappings: [OutputDeviceProfileMapping],
        fallbackProfileID: UUID
    ) throws -> Data {
        let mappingObject = try JSONSerialization.jsonObject(
            with: ProfilePersistence.encoder.encode(outputMappings)
        )
        let object: [String: Any] = [
            "schemaVersion": ProfileStore.currentSchemaVersion,
            "profiles": profiles,
            "outputMappings": try #require(mappingObject as? [[String: Any]]),
            "fallbackProfileID": fallbackProfileID.uuidString
        ]
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }
}
