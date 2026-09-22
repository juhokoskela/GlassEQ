import Foundation
import GlassEQAudio
import GlassEQSettingsIPC
import Testing
@testable import GlassEQApp

@MainActor
@Suite
struct AggregateBufferPolicyTests {
    @Test
    func automaticBufferClimbsTheReliabilityLadderAndPersists() throws {
        let url = temporaryPolicyURL()
        let route = fingerprint(uid: "route", stream: 1, sampleRate: 48_000)
        let store = AggregateBufferPolicyStore(url: url)
        let start = Date(timeIntervalSince1970: 1_000)

        #expect(store.selection(for: route).frameSize == 16)
        #expect(try store.recordAutomaticFailure(for: route, at: start) == nil)
        #expect(
            try store.recordAutomaticFailure(
                for: route,
                at: start.addingTimeInterval(1)
            ) == 32)
        #expect(
            try store.recordAutomaticFailure(
                for: route,
                at: start.addingTimeInterval(2)
            ) == nil)
        #expect(
            try store.recordAutomaticFailure(
                for: route,
                at: start.addingTimeInterval(3)
            ) == 64)
        #expect(
            try store.recordAutomaticFailure(
                for: route,
                occurrences: 2,
                at: start.addingTimeInterval(4)
            ) == 128)
        #expect(try store.recordAutomaticFailure(for: route, occurrences: 2) == nil)

        let reloaded = AggregateBufferPolicyStore(url: url)
        #expect(reloaded.selection(for: route).automaticFrameSize == 128)
        #expect(reloaded.selection(for: route).frameSize == 128)
    }

    @Test
    func bluetoothAutomaticStartsAtSixtyFourAndNeverLearnsBelowIt() throws {
        let url = temporaryPolicyURL()
        let route = fingerprint(uid: "bluetooth", stream: 0, sampleRate: 48_000)
        let store = AggregateBufferPolicyStore(url: url)

        #expect(store.selection(for: route, isBluetooth: true).frameSize == 64)
        // A previously learned smaller request must also respect the Bluetooth floor.
        #expect(try store.recordAutomaticFailure(for: route, occurrences: 2) == 32)
        #expect(store.selection(for: route, isBluetooth: true).frameSize == 64)
        #expect(try store.recordAutomaticFailure(for: route, isBluetooth: true, occurrences: 2) == 128)

        let reloaded = AggregateBufferPolicyStore(url: url)
        #expect(reloaded.selection(for: route, isBluetooth: true).frameSize == 128)
        #expect(try reloaded.recordCleanAutomaticSession(for: route, isBluetooth: true) == nil)
        #expect(try reloaded.recordCleanAutomaticSession(for: route, isBluetooth: true) == nil)
        #expect(try reloaded.recordCleanAutomaticSession(for: route, isBluetooth: true) == 64)
        for _ in 0..<4 {
            #expect(try reloaded.recordCleanAutomaticSession(for: route, isBluetooth: true) == nil)
        }
        #expect(reloaded.selection(for: route, isBluetooth: true).frameSize == 64)
        #expect(try reloaded.recordAutomaticFailure(for: route, isBluetooth: true, occurrences: 2) == 128)
        try reloaded.retryAutomaticBuffer(for: route, isBluetooth: true)
        #expect(reloaded.selection(for: route, isBluetooth: true).frameSize == 64)
    }

    @Test(arguments: [SettingsAggregateBufferMode.frames16, .frames32, .frames64, .frames128])
    func bluetoothFixedChoicesSurviveReloadAndOverrideTheDefault(mode: SettingsAggregateBufferMode) throws {
        let url = temporaryPolicyURL()
        let route = fingerprint(uid: "fixed-bluetooth", stream: 0, sampleRate: 48_000)
        try AggregateBufferPolicyStore(url: url).setMode(mode, for: route)
        let reloaded = AggregateBufferPolicyStore(url: url)
        let selection = reloaded.selection(for: route, isBluetooth: true)
        #expect(selection.mode == mode)
        #expect(selection.frameSize == reloaded.selection(for: route).frameSize)
        #expect(selection.automaticFrameSize == 64)
        #expect(try reloaded.recordAutomaticFailure(for: route, isBluetooth: true, occurrences: 2) == nil)
        try reloaded.setMode(.automatic, for: route)
        #expect(reloaded.selection(for: route, isBluetooth: true).frameSize == 64)
    }

    @Test
    func learningIsIsolatedByDeviceStreamAndSampleRate() throws {
        let store = AggregateBufferPolicyStore(url: temporaryPolicyURL())
        let learned = fingerprint(uid: "device", stream: 0, sampleRate: 48_000)
        let otherStream = fingerprint(uid: "device", stream: 1, sampleRate: 48_000)
        let otherRate = fingerprint(uid: "device", stream: 0, sampleRate: 96_000)

        #expect(try store.recordAutomaticFailure(for: learned, occurrences: 2) == 32)

        #expect(store.selection(for: learned).frameSize == 32)
        #expect(store.selection(for: otherStream).frameSize == 16)
        #expect(store.selection(for: otherRate).frameSize == 16)
    }

    @Test
    func fixedModeSuppressesLearningAndRetryRestoresAutomaticSixteen() throws {
        let store = AggregateBufferPolicyStore(url: temporaryPolicyURL())
        let route = fingerprint(uid: "fixed", stream: 0, sampleRate: 48_000)

        try store.setMode(.frames16, for: route)
        #expect(try store.recordAutomaticFailure(for: route) == nil)
        #expect(store.selection(for: route).mode == .frames16)

        try store.setMode(.automatic, for: route)
        #expect(try store.recordAutomaticFailure(for: route) == nil)
        #expect(try store.recordAutomaticFailure(for: route) == 32)
        try store.retryAutomaticBuffer(for: route)

        #expect(store.selection(for: route).mode == .automatic)
        #expect(store.selection(for: route).frameSize == 16)
    }

    @Test
    func failedPersistenceDoesNotChangeTheInMemorySelection() {
        let store = AggregateBufferPolicyStore(
            url: URL(fileURLWithPath: "/dev/null/aggregate-buffer-policy.json")
        )
        let route = fingerprint(uid: "unwritable", stream: 0, sampleRate: 48_000)

        #expect(throws: (any Error).self) {
            try store.recordAutomaticFailure(for: route)
        }
        #expect(store.selection(for: route).frameSize == 16)
    }

    @Test
    func isolatedFailuresOutsideTheFiveMinuteWindowDoNotIncreaseTheBuffer() throws {
        let store = AggregateBufferPolicyStore(url: temporaryPolicyURL())
        let route = fingerprint(uid: "isolated", stream: 0, sampleRate: 48_000)
        let start = Date(timeIntervalSince1970: 2_000)

        #expect(try store.recordAutomaticFailure(for: route, at: start) == nil)
        #expect(
            try store.recordAutomaticFailure(
                for: route,
                at: start.addingTimeInterval(AggregateBufferPolicyStore.failureWindow + 1)
            ) == nil)
        #expect(store.selection(for: route).frameSize == 16)
    }

    @Test
    func failureEvidenceSurvivesRelaunchWithinTheWindow() throws {
        let url = temporaryPolicyURL()
        let route = fingerprint(uid: "persisted-evidence", stream: 0, sampleRate: 48_000)
        let start = Date(timeIntervalSince1970: 3_000)
        let store = AggregateBufferPolicyStore(url: url)

        #expect(try store.recordAutomaticFailure(for: route, at: start) == nil)

        let reloaded = AggregateBufferPolicyStore(url: url)
        #expect(
            try reloaded.recordAutomaticFailure(
                for: route,
                at: start.addingTimeInterval(10)
            ) == 32)
    }

    @Test
    func threeCleanSessionsRetryOneLowerRungAtATime() throws {
        let store = AggregateBufferPolicyStore(url: temporaryPolicyURL())
        let route = fingerprint(uid: "clean", stream: 0, sampleRate: 48_000)

        #expect(try store.recordAutomaticFailure(for: route, occurrences: 2) == 32)
        #expect(try store.recordAutomaticFailure(for: route, occurrences: 2) == 64)

        #expect(try store.recordCleanAutomaticSession(for: route) == nil)
        #expect(try store.recordCleanAutomaticSession(for: route) == nil)
        #expect(try store.recordCleanAutomaticSession(for: route) == 32)
        #expect(try store.recordCleanAutomaticSession(for: route) == nil)
        #expect(try store.recordCleanAutomaticSession(for: route) == nil)
        #expect(try store.recordCleanAutomaticSession(for: route) == 16)
        #expect(try store.recordCleanAutomaticSession(for: route) == nil)
    }

    @Test
    func aFailureResetsCleanSessionProgress() throws {
        let store = AggregateBufferPolicyStore(url: temporaryPolicyURL())
        let route = fingerprint(uid: "reset-clean", stream: 0, sampleRate: 48_000)
        let start = Date(timeIntervalSince1970: 4_000)

        #expect(
            try store.recordAutomaticFailure(
                for: route,
                occurrences: 2,
                at: start
            ) == 32)
        #expect(try store.recordCleanAutomaticSession(for: route) == nil)
        #expect(try store.recordCleanAutomaticSession(for: route) == nil)
        #expect(
            try store.recordAutomaticFailure(
                for: route,
                at: start.addingTimeInterval(1)
            ) == nil)
        #expect(try store.recordCleanAutomaticSession(for: route) == nil)
        #expect(try store.recordCleanAutomaticSession(for: route) == nil)
        #expect(try store.recordCleanAutomaticSession(for: route) == 16)
    }

    @Test
    func cleanSessionsDescendFromTheStoredAutomaticRung() throws {
        let store = AggregateBufferPolicyStore(url: temporaryPolicyURL())
        let route = fingerprint(uid: "stored-rung", stream: 0, sampleRate: 48_000)

        #expect(try store.recordAutomaticFailure(for: route, occurrences: 2) == 32)
        #expect(try store.recordCleanAutomaticSession(for: route) == nil)
        #expect(try store.recordCleanAutomaticSession(for: route) == nil)
        #expect(try store.recordCleanAutomaticSession(for: route) == 16)
        #expect(store.selection(for: route).automaticFrameSize == 16)
    }

    @Test
    func cleanSessionsStopOnceTheStoredRequestReachesTheFloor() throws {
        let store = AggregateBufferPolicyStore(url: temporaryPolicyURL())
        let route = fingerprint(uid: "floor", stream: 0, sampleRate: 48_000)

        for _ in 0..<6 {
            #expect(try store.recordCleanAutomaticSession(for: route) == nil)
        }
        #expect(store.selection(for: route).automaticFrameSize == 16)
    }

    @Test
    func legacyOneShotLearningIsResetButFixedModeIsPreserved() throws {
        let url = temporaryPolicyURL()
        let data = Data(
            """
            {
              "records" : [
                {
                  "automaticFrameSize" : 64,
                  "mode" : "automatic",
                  "route" : {
                    "nativeOutputStreamIndex" : 0,
                    "nominalSampleRate" : 48000,
                    "outputDeviceUID" : "legacy-automatic"
                  }
                },
                {
                  "automaticFrameSize" : 64,
                  "mode" : "frames32",
                  "route" : {
                    "nativeOutputStreamIndex" : 0,
                    "nominalSampleRate" : 48000,
                    "outputDeviceUID" : "legacy-fixed"
                  }
                }
              ],
              "schemaVersion" : 1
            }
            """.utf8
        )
        try data.write(to: url)

        let store = AggregateBufferPolicyStore(url: url)
        let automatic = fingerprint(
            uid: "legacy-automatic",
            stream: 0,
            sampleRate: 48_000
        )
        let fixed = fingerprint(uid: "legacy-fixed", stream: 0, sampleRate: 48_000)

        #expect(store.selection(for: automatic).mode == .automatic)
        #expect(store.selection(for: automatic).frameSize == 16)
        #expect(store.selection(for: fixed).mode == .frames32)
        #expect(store.selection(for: fixed).frameSize == 32)
    }

    @Test
    func persistedPolicyRejectsOversizedFilesAndRecordAmplification() throws {
        let url = temporaryPolicyURL()
        defer {
            try? FileManager.default.removeItem(at: url)
        }
        let route = fingerprint(uid: "route-0", stream: 0, sampleRate: 48_000)

        try Data(
            repeating: 0x20,
            count: AggregateBufferPolicyStore.maximumStoreBytes + 1
        ).write(to: url)
        #expect(AggregateBufferPolicyStore(url: url).selection(for: route).frameSize == 16)

        let records: [[String: Any]] = (0...AggregateBufferPolicyStore.maximumRecordCount).map { index in
            [
                "automaticFrameSize": 64,
                "mode": "automatic",
                "route": [
                    "nativeOutputStreamIndex": 0,
                    "nominalSampleRate": 48_000,
                    "outputDeviceUID": "route-\(index)",
                ],
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "records": records,
            "schemaVersion": 2,
        ])
        try data.write(to: url)

        #expect(AggregateBufferPolicyStore(url: url).selection(for: route).frameSize == 16)
    }

    @Test(arguments: [true, false])
    func unreadableImportsPreservePreferences(replacing: Bool) throws {
        let url = temporaryPolicyURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AggregateBufferPolicyStore(url: url)
        let route = fingerprint(uid: "saved", stream: 0, sampleRate: 48_000)
        try store.setMode(.frames128, for: route)
        let original = try store.exportDocument()
        for data in [
            Data("bad JSON".utf8), Data(#"{"schemaVersion":999,"records":[]}"#.utf8),
            Data(repeating: 0, count: AggregateBufferPolicyStore.maximumStoreBytes + 1),
        ] {
            #expect(throws: (any Error).self) { try store.importDocument(data, replacingExisting: replacing) }
            #expect(try store.exportDocument() == original)
            #expect(try Data(contentsOf: url) == original)
        }
    }

    @Test(arguments: [true, false])
    func importedRoutesAreUniqueAndExistingMergePreferencesWin(replacing: Bool) throws {
        let url = temporaryPolicyURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let route = fingerprint(uid: "saved", stream: 0, sampleRate: 48_000)
        let store = AggregateBufferPolicyStore(url: url)
        try store.setMode(.frames128, for: route)
        let data = Data(
            #"{"schemaVersion":2,"records":[{"route":{"outputDeviceUID":"saved","nativeOutputStreamIndex":0,"nominalSampleRate":48000},"mode":"frames32","automaticFrameSize":16},{"route":{"outputDeviceUID":"new","nativeOutputStreamIndex":0,"nominalSampleRate":48000},"mode":"frames64","automaticFrameSize":16},{"route":{"outputDeviceUID":"new","nativeOutputStreamIndex":0,"nominalSampleRate":48000},"mode":"frames128","automaticFrameSize":16}]}"#
                .utf8)
        try store.importDocument(data, replacingExisting: replacing)
        #expect(store.selection(for: route).mode == (replacing ? .frames32 : .frames128))
        let newRoute = fingerprint(uid: "new", stream: 0, sampleRate: 48_000)
        #expect(store.selection(for: newRoute).mode == .frames64)
        let document = try #require(JSONSerialization.jsonObject(with: store.exportDocument()) as? [String: Any])
        #expect((document["records"] as? [Any])?.count == 2)
        try store.importDocument(Data(#"{"schemaVersion":2,"records":[]}"#.utf8), replacingExisting: true)
        #expect(store.selectionSnapshot().isEmpty)
    }

    private func fingerprint(
        uid: String,
        stream: Int,
        sampleRate: Double
    ) -> AggregateAudioRouteFingerprint {
        AggregateAudioRouteFingerprint(
            outputDeviceUID: uid,
            nativeOutputStreamIndex: stream,
            nominalSampleRate: sampleRate
        )
    }

    private func temporaryPolicyURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("AggregateBufferPolicyTests-\(UUID().uuidString).json")
    }
}
