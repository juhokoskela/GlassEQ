import Foundation
import Testing
@testable import GlassEQLicensing

@Suite
struct TrustedTimeTests {
    @Test
    func effectiveTimeIsTheGreatestOfWallClockFloorAndAnchor() {
        let state = TrustedTimeState(persistedTrustedTime: 5_000, wallClock: 4_000, now: .seconds(100))

        #expect(state.highestTrustedTime == 5_000)
        #expect(state.effectiveTime(wallClock: 4_000, now: .seconds(100)) == 5_000)
        #expect(state.effectiveTime(wallClock: 6_000, now: .seconds(100)) == 6_000)
        #expect(state.effectiveTime(wallClock: 4_000, now: .seconds(1_600)) == 6_500)
    }

    @Test
    func rollbackDetectionUsesSixHourTolerance() {
        let state = TrustedTimeState(persistedTrustedTime: 100_000, wallClock: 100_000, now: .zero)
        let tolerance = TrustedTimeState.rollbackToleranceSeconds

        #expect(!state.detectsRollback(wallClock: 100_000 - tolerance))
        #expect(!state.detectsRollback(wallClock: 100_000 - tolerance + 1))
        #expect(state.detectsRollback(wallClock: 100_000 - tolerance - 1))
    }

    @Test
    func advanceNeverMovesBackwardsAndAnchorAdvancesWithElapsedTime() {
        var state = TrustedTimeState(persistedTrustedTime: nil, wallClock: 1_000, now: .zero)

        state.advance(to: 900)
        #expect(state.highestTrustedTime == 1_000)

        state.anchor(issuedAt: 2_000, at: .seconds(10))
        #expect(state.highestTrustedTime == 2_000)
        #expect(state.effectiveTime(wallClock: 0, now: .seconds(25)) == 2_015)
        #expect(state.effectiveTime(wallClock: 0, now: .seconds(5)) == 2_000)
    }

    @Test
    func persistenceIsNeededAfterOneHourOfAdvance() {
        var state = TrustedTimeState(persistedTrustedTime: 1_000, wallClock: 1_000, now: .zero)
        let interval = TrustedTimeState.persistenceIntervalSeconds

        #expect(!state.hasUnpersistedAdvance)
        state.advance(to: 1_000 + interval - 1)
        #expect(state.hasUnpersistedAdvance)
        #expect(!state.needsPersistence)
        state.advance(to: 1_000 + interval)
        #expect(state.needsPersistence)
        state.markPersisted()
        #expect(!state.needsPersistence)
        #expect(!state.hasUnpersistedAdvance)
    }

    @Test
    func freshStateWithoutPersistedValueStartsAtTheWallClock() {
        let state = TrustedTimeState(persistedTrustedTime: nil, wallClock: 42, now: .zero)

        #expect(state.highestTrustedTime == 42)
        #expect(state.lastPersistedTrustedTime == 42)
        #expect(!state.hasUnpersistedAdvance)
    }
}

@Suite
struct ActivationStateTests {
    @Test
    func encodesAndDecodesEveryField() throws {
        let state = ActivationState(
            activationToken: "gea_token",
            entitlement: "a.b.c",
            highestAcceptedRevision: 9,
            highestTrustedTime: 1_234,
            clockAnomalyDetectedAt: 1_200,
            serverDeniedAt: 1_230
        )

        let data = try LicenseRecordCodec.encode(state)
        #expect(try LicenseRecordCodec.decode(ActivationState.self, from: data) == state)
    }

    @Test
    func rejectsOversizedAndCorruptRecords() throws {
        let oversized = Data(repeating: 0x20, count: ActivationState.maximumEncodedBytes + 1)
        let corrupt = Data("{\"activationToken\":1}".utf8)

        #expect(throws: LicenseCredentialStoreError.corruptRecord) {
            try LicenseRecordCodec.decode(ActivationState.self, from: oversized)
        }
        #expect(throws: LicenseCredentialStoreError.corruptRecord) {
            try LicenseRecordCodec.decode(ActivationState.self, from: corrupt)
        }
    }
}
