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
        #expect(try store.recordAutomaticFailure(
            for: route,
            at: start.addingTimeInterval(1)
        ) == 32)
        #expect(try store.recordAutomaticFailure(
            for: route,
            at: start.addingTimeInterval(2)
        ) == nil)
        #expect(try store.recordAutomaticFailure(
            for: route,
            at: start.addingTimeInterval(3)
        ) == 64)
        #expect(try store.recordAutomaticFailure(
            for: route,
            occurrences: 2,
            at: start.addingTimeInterval(4)
        ) == nil)

        let reloaded = AggregateBufferPolicyStore(url: url)
        #expect(reloaded.selection(for: route).automaticFrameSize == 64)
        #expect(reloaded.selection(for: route).frameSize == 64)
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
        #expect(try store.recordAutomaticFailure(
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
        #expect(try reloaded.recordAutomaticFailure(
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

        #expect(try store.recordCleanAutomaticSession(for: route, runtimeFrameSize: 64) == nil)
        #expect(try store.recordCleanAutomaticSession(for: route, runtimeFrameSize: 64) == nil)
        #expect(try store.recordCleanAutomaticSession(for: route, runtimeFrameSize: 64) == 32)
        #expect(try store.recordCleanAutomaticSession(for: route, runtimeFrameSize: 32) == nil)
        #expect(try store.recordCleanAutomaticSession(for: route, runtimeFrameSize: 32) == nil)
        #expect(try store.recordCleanAutomaticSession(for: route, runtimeFrameSize: 32) == 16)
        #expect(try store.recordCleanAutomaticSession(for: route, runtimeFrameSize: 16) == nil)
    }

    @Test
    func aFailureResetsCleanSessionProgress() throws {
        let store = AggregateBufferPolicyStore(url: temporaryPolicyURL())
        let route = fingerprint(uid: "reset-clean", stream: 0, sampleRate: 48_000)
        let start = Date(timeIntervalSince1970: 4_000)

        #expect(try store.recordAutomaticFailure(
            for: route,
            occurrences: 2,
            at: start
        ) == 32)
        #expect(try store.recordCleanAutomaticSession(for: route, runtimeFrameSize: 32) == nil)
        #expect(try store.recordCleanAutomaticSession(for: route, runtimeFrameSize: 32) == nil)
        #expect(try store.recordAutomaticFailure(
            for: route,
            at: start.addingTimeInterval(1)
        ) == nil)
        #expect(try store.recordCleanAutomaticSession(for: route, runtimeFrameSize: 32) == nil)
        #expect(try store.recordCleanAutomaticSession(for: route, runtimeFrameSize: 32) == nil)
        #expect(try store.recordCleanAutomaticSession(for: route, runtimeFrameSize: 32) == 16)
    }

    @Test
    func cleanSessionsRetryBelowTheAcceptedRuntimeRung() throws {
        let store = AggregateBufferPolicyStore(url: temporaryPolicyURL())
        let route = fingerprint(uid: "accepted-rung", stream: 0, sampleRate: 48_000)

        #expect(try store.recordAutomaticFailure(for: route, occurrences: 2) == 32)
        #expect(try store.recordCleanAutomaticSession(for: route, runtimeFrameSize: 64) == nil)
        #expect(try store.recordCleanAutomaticSession(for: route, runtimeFrameSize: 64) == nil)
        #expect(try store.recordCleanAutomaticSession(for: route, runtimeFrameSize: 64) == 32)
        #expect(store.selection(for: route).automaticFrameSize == 32)
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
