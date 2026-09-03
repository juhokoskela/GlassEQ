import Foundation
import Testing
@testable import GlassEQLicensing

@Suite
struct LicensingControllerTests {
    private func notEligible() -> LicenseServiceError {
        .service(code: .licenseNotEligible, retryAfterSeconds: nil)
    }

    @Test
    func futureIssuedEntitlementNamesTheClockProblem() {
        let error = LicensingError.entitlement(.issuedInFuture)

        #expect(error.errorDescription == "Check this Mac's date and time, then try activating again.")
    }

    // MARK: Loading

    @Test
    func emptyStoreIsUnlicensedWithoutNetworkOrScheduling() async throws {
        let harness = ControllerHarness(fixture: try EntitlementFixture(), identity: false)

        let snapshot = await harness.subscribe()

        #expect(snapshot.content.state == .unlicensed)
        #expect(!snapshot.content.permitsProcessing)
        #expect(snapshot.sequence == 1)
        #expect(harness.service.calls.isEmpty)
        for _ in 0 ..< 20 { await Task.yield() }
        #expect(harness.clock.requestedDeadlines.isEmpty)
    }

    @Test
    func storageReadFailureFailsClosedAndRecoversOnRetry() async throws {
        let fixture = try EntitlementFixture()
        let harness = ControllerHarness(fixture: fixture, activation: try fixture.monthlyActivationState())
        harness.store.loadFailure = .keychain(-25_300)

        let snapshot = await harness.subscribe()
        #expect(snapshot.content.state == .storageUnavailable)
        #expect(snapshot.content.storageFailure == .keychain(-25_300))
        #expect(!snapshot.content.permitsProcessing)

        let deadline = try #require(await harness.clock.waitForSleeper())
        #expect(deadline == .seconds(60))
        harness.store.loadFailure = nil
        harness.advance(seconds: 60)

        let recovered = try #require(await harness.recorder.waitForSnapshot(state: .monthlyActive))
        #expect(recovered.content.storageFailure == nil)
        #expect(recovered.content.permitsProcessing)
    }

    @Test(arguments: [
        (LicenseState.monthlyActive, Int64(0)),
        (.monthlyRecovery, 0),
        (.monthlyGrace, 0),
        (.monthlyExpired, 0)
    ])
    func timelineStatesFollowEffectiveTime(expected: LicenseState, _: Int64) async throws {
        let fixture = try EntitlementFixture()
        let times: [LicenseState: [Int64]] = [
            .monthlyActive: [fixture.issuedAt, fixture.billingPeriodEnd - 1],
            .monthlyRecovery: [fixture.billingPeriodEnd, fixture.recoveryUntil - 1],
            .monthlyGrace: [fixture.recoveryUntil, fixture.expiresAt - 1],
            .monthlyExpired: [fixture.expiresAt, fixture.expiresAt + 1]
        ]
        for time in times[expected]! {
            let harness = ControllerHarness(
                fixture: fixture,
                activation: try fixture.monthlyActivationState(highestTrustedTime: time),
                wallTime: time
            )
            let snapshot = await harness.subscribe()
            #expect(snapshot.content.state == expected, "at \(time)")
            #expect(snapshot.content.permitsProcessing == expected.permitsProcessing)
            #expect(snapshot.content.terms == MonthlyTerms(
                billingState: .active,
                billingPeriodEnd: fixture.billingPeriodEnd,
                recoveryUntil: fixture.recoveryUntil,
                refreshAfter: fixture.refreshAfter,
                expiresAt: fixture.expiresAt
            ))
        }
    }

    @Test
    func perpetualEntitlementNeverSchedulesOrRefreshes() async throws {
        let fixture = try EntitlementFixture()
        let harness = ControllerHarness(
            fixture: fixture,
            activation: try fixture.perpetualActivationState(),
            wallTime: fixture.expiresAt + 1_000_000
        )

        let snapshot = await harness.subscribe()

        #expect(snapshot.content.state == .perpetual)
        #expect(snapshot.content.terms == nil)
        for _ in 0 ..< 20 { await Task.yield() }
        #expect(harness.clock.requestedDeadlines.isEmpty)
        #expect(harness.service.calls.isEmpty)
    }

    @Test
    func corruptRecordAndForeignInstallationAreInvalidEntitlements() async throws {
        let fixture = try EntitlementFixture()
        let corrupt = ControllerHarness(fixture: fixture)
        corrupt.store.activationLoadFailure = .corruptRecord
        let foreign = ControllerHarness(
            fixture: fixture,
            activation: try fixture.monthlyActivationState(installationID: UUID())
        )

        let corruptSnapshot = await corrupt.subscribe()
        let foreignSnapshot = await foreign.subscribe()

        #expect(corruptSnapshot.content.state == .invalidEntitlement)
        #expect(foreignSnapshot.content.state == .invalidEntitlement)
        #expect(!foreignSnapshot.content.permitsProcessing)
        #expect(corrupt.store.clearCount == 0)
        #expect(foreign.store.clearCount == 0)
        #expect(foreign.store.activation != nil)
    }

    // MARK: Activation

    @Test
    func snapshotsReportWhatActivationWouldDoWithTheStoredRecord() async throws {
        let fixture = try EntitlementFixture()

        let empty = ControllerHarness(fixture: fixture)
        #expect(await empty.controller.currentSnapshot().content.activation == .available)

        let corrupt = ControllerHarness(fixture: fixture)
        corrupt.store.activationLoadFailure = .corruptRecord
        #expect(await corrupt.controller.currentSnapshot().content.activation == .available)

        let newer = ControllerHarness(fixture: fixture)
        newer.store.activationLoadFailure = .unsupportedSchemaVersion(2)
        #expect(await newer.controller.currentSnapshot().content.activation == .needsAppUpdate)

        let unreadable = ControllerHarness(fixture: fixture)
        unreadable.store.loadFailure = .keychain(-1)
        #expect(await unreadable.controller.currentSnapshot().content.activation == .storageUnavailable)

        let foreign = ControllerHarness(
            fixture: fixture,
            activation: try fixture.monthlyActivationState(installationID: UUID())
        )
        let foreignSnapshot = await foreign.controller.currentSnapshot()
        #expect(foreignSnapshot.content.state == .invalidEntitlement)
        #expect(foreignSnapshot.content.activation == .needsRemoval)

        let unknownKey = ControllerHarness(fixture: fixture, activation: ActivationState(
            activationToken: "gea_test",
            entitlement: try fixture.sign(
                header: """
                {"alg":"EdDSA","kid":"entitlement-2030-01","typ":"glasseq-entitlement+jwt"}
                """,
                payload: fixture.perpetualPayload()
            ),
            highestAcceptedRevision: 7,
            highestTrustedTime: fixture.issuedAt
        ))
        let unknownKeySnapshot = await unknownKey.controller.currentSnapshot()
        #expect(unknownKeySnapshot.content.state == .invalidEntitlement)
        #expect(unknownKeySnapshot.content.activation == .needsAppUpdate)

        let active = ControllerHarness(fixture: fixture)
        active.service.onActivate { _, installationID, _ in
            ActivationResponse(
                activationToken: "gea_new",
                entitlement: try fixture.sign(payload: fixture.perpetualPayload(installationID: installationID))
            )
        }
        let activated = try await active.controller.activate(licenseKey: "GEQ1-KEY")
        #expect(activated.content.state == .perpetual)
        #expect(activated.content.activation == .activated)

        active.service.onDeactivate { _ in throw LicenseServiceError.transport(.offline) }
        await #expect(throws: LicensingError.self) {
            try await active.controller.deactivateCurrent()
        }
        let tombstoned = await active.controller.currentSnapshot()
        #expect(tombstoned.content.state == .unlicensed)
        #expect(tombstoned.content.activation == .releasingPreviousActivation)
    }

    @Test
    func aCorruptIdentityKeepsTheActivationUntilItsTokenReleasesTheSlot() async throws {
        let fixture = try EntitlementFixture()
        let harness = ControllerHarness(fixture: fixture, activation: try fixture.monthlyActivationState())
        harness.store.identityLoadFailure = .corruptRecord
        harness.service.onDeactivate { _ in }
        harness.service.onActivate { _, installationID, _ in
            ActivationResponse(
                activationToken: "gea_new",
                entitlement: try fixture.sign(payload: fixture.perpetualPayload(installationID: installationID))
            )
        }

        let loaded = await harness.controller.currentSnapshot()
        #expect(loaded.content.state == .invalidEntitlement)
        #expect(loaded.content.activation == .needsRemoval)

        // Activation must not replace the record and burn a second slot for the same Mac.
        await #expect(throws: LicensingError.activationAlreadyExists) {
            try await harness.controller.activate(licenseKey: "GEQ1-KEY")
        }
        #expect(harness.store.activation?.activationToken == "gea_test")
        #expect(harness.service.calls.isEmpty)

        let released = try await harness.controller.deactivateCurrent()
        #expect(harness.service.calls == [.deactivate(activationToken: "gea_test")])
        #expect(released.content.activation == .available)

        let activated = try await harness.controller.activate(licenseKey: "GEQ1-KEY")
        #expect(activated.content.state == .perpetual)
        #expect(harness.store.identity != nil)
    }

    @Test
    func operationsAreRefusedAfterShutdown() async throws {
        let fixture = try EntitlementFixture()
        let harness = ControllerHarness(fixture: fixture)
        harness.service.onActivate { _, _, _ in
            Issue.record("the service must not be called after shutdown")
            throw LicenseServiceError.transport(.other)
        }

        await harness.controller.shutdown()

        await #expect(throws: LicensingError.shutDown) {
            try await harness.controller.activate(licenseKey: "GEQ1-KEY")
        }
        await #expect(throws: LicensingError.shutDown) {
            try await harness.controller.deactivateCurrent()
        }
    }

    @Test
    func activationCreatesTheIdentityOnceAndStoresTheEntitlement() async throws {
        let fixture = try EntitlementFixture()
        let harness = ControllerHarness(fixture: fixture, identity: false)
        harness.service.onActivate { _, installationID, _ in
            ActivationResponse(
                activationToken: "gea_new",
                entitlement: try fixture.sign(payload: fixture.monthlyPayload(installationID: installationID))
            )
        }
        _ = await harness.subscribe()

        try await harness.controller.activate(licenseKey: "GEQ1-KEY")

        let identity = try #require(harness.store.identity)
        let calls = harness.service.calls
        #expect(calls.count == 1)
        guard case let .activate(licenseKey, installationID, _) = calls[0] else {
            Issue.record("expected an activation call")
            return
        }
        #expect(licenseKey == "GEQ1-KEY")
        #expect(installationID == identity.installationID)
        let stored = try #require(harness.store.activation)
        #expect(stored.activationToken == "gea_new")
        #expect(stored.highestAcceptedRevision == 7)
        #expect(stored.highestTrustedTime == fixture.issuedAt)
        let snapshot = try #require(await harness.recorder.waitForSnapshot(state: .monthlyActive))
        #expect(snapshot.sequence == 2)
        #expect(snapshot.content.terms != nil)
    }

    @Test
    func activationRetriesOnceAfterATimeoutWithTheSameIdempotencyKey() async throws {
        let fixture = try EntitlementFixture()
        let harness = ControllerHarness(fixture: fixture)
        let attempts = AttemptCounter()
        harness.service.onActivate { _, installationID, _ in
            if attempts.next() == 1 {
                throw LicenseServiceError.transport(.timedOut)
            }
            return ActivationResponse(
                activationToken: "gea_new",
                entitlement: try fixture.sign(payload: fixture.perpetualPayload(installationID: installationID))
            )
        }

        try await harness.controller.activate(licenseKey: "GEQ1-KEY")

        let calls = harness.service.calls
        #expect(calls.count == 2)
        guard case let .activate(_, _, firstKey) = calls[0],
              case let .activate(_, _, secondKey) = calls[1] else {
            Issue.record("expected two activation calls")
            return
        }
        #expect(firstKey == secondKey)
        #expect(await harness.controller.currentSnapshot().content.state == .perpetual)
    }

    @Test
    func activationFailuresAreSurfacedAndLeaveTheStoreUntouched() async throws {
        let fixture = try EntitlementFixture()
        let harness = ControllerHarness(fixture: fixture)
        let limit = LicenseServiceError.service(
            code: .activationLimit, retryAfterSeconds: nil
        )
        harness.service.onActivate { _, _, _ in throw limit }

        await #expect(throws: LicensingError.service(limit)) {
            try await harness.controller.activate(licenseKey: "GEQ1-KEY")
        }
        #expect(harness.store.activation == nil)

        harness.service.onActivate { _, _, _ in
            ActivationResponse(activationToken: "gea_new", entitlement: try fixture.sign(payload: fixture.monthlyPayload()))
        }
        harness.service.onDeactivate { _ in }
        harness.store.saveFailure = .keychain(-25_291)
        await #expect(throws: LicensingError.storage(.keychain(-25_291))) {
            try await harness.controller.activate(licenseKey: "GEQ1-KEY")
        }
        #expect(await harness.controller.currentSnapshot().content.state == .unlicensed)
        #expect(harness.service.calls.last == .deactivate(activationToken: "gea_new"))

        harness.store.saveFailure = nil
        harness.service.onActivate { _, _, _ in
            ActivationResponse(
                activationToken: "gea_unverifiable",
                entitlement: try fixture.sign(payload: fixture.monthlyPayload(installationID: UUID()))
            )
        }
        await #expect(throws: LicensingError.entitlement(.installationMismatch)) {
            try await harness.controller.activate(licenseKey: "GEQ1-KEY")
        }
        #expect(harness.service.calls.last == .deactivate(activationToken: "gea_unverifiable"))
    }

    @Test
    func failedVerificationRetainsTheActivationTokenUntilCleanupSucceeds() async throws {
        let fixture = try EntitlementFixture()
        let harness = ControllerHarness(fixture: fixture)
        harness.service.onActivate { _, _, _ in
            ActivationResponse(
                activationToken: "gea_unverifiable",
                entitlement: try fixture.sign(payload: fixture.monthlyPayload(installationID: UUID()))
            )
        }
        harness.service.onDeactivate { _ in throw LicenseServiceError.transport(.offline) }

        await #expect(throws: LicensingError.entitlement(.installationMismatch)) {
            try await harness.controller.activate(licenseKey: "GEQ1-KEY")
        }

        let tombstone = try #require(harness.store.activation)
        #expect(tombstone.activationToken == "gea_unverifiable")
        #expect(tombstone.deactivationRequestedAt == fixture.issuedAt)
        #expect(await harness.controller.currentSnapshot().content.state == .unlicensed)
        #expect(try #require(await harness.clock.waitForSleeper()) == .seconds(60))

        harness.service.onDeactivate { _ in }
        harness.advance(seconds: 60)

        #expect(await waitUntil { harness.store.activation == nil })
        #expect(harness.service.calls.filter {
            $0 == .deactivate(activationToken: "gea_unverifiable")
        }.count == 2)
    }

    @Test
    func failedActivationSaveKeepsCleanupAliveUntilStorageRecovers() async throws {
        let fixture = try EntitlementFixture()
        let harness = ControllerHarness(fixture: fixture)
        harness.service.onActivate { _, installationID, _ in
            ActivationResponse(
                activationToken: "gea_unsaved",
                entitlement: try fixture.sign(payload: fixture.monthlyPayload(installationID: installationID))
            )
        }
        harness.service.onDeactivate { _ in throw LicenseServiceError.transport(.offline) }
        harness.store.saveFailure = .keychain(-25_291)

        await #expect(throws: LicensingError.storage(.keychain(-25_291))) {
            try await harness.controller.activate(licenseKey: "GEQ1-KEY")
        }

        #expect(harness.store.activation == nil)
        #expect(await harness.controller.currentSnapshot().content.state == .unlicensed)
        #expect(try #require(await harness.clock.waitForSleeper()) == .seconds(60))

        harness.store.saveFailure = nil
        harness.service.onDeactivate { _ in }
        harness.advance(seconds: 60)

        #expect(await waitUntil { harness.store.clearCount == 1 })
        #expect(harness.store.activation == nil)
        #expect(harness.service.calls.filter {
            $0 == .deactivate(activationToken: "gea_unsaved")
        }.count == 2)
    }

    @Test
    func overlappingExclusiveOperationsAreRejected() async throws {
        let fixture = try EntitlementFixture()
        let harness = ControllerHarness(fixture: fixture)
        let gate = AsyncGate()
        harness.service.onActivate { _, installationID, _ in
            await gate.wait()
            return ActivationResponse(
                activationToken: "gea_new",
                entitlement: try fixture.sign(payload: fixture.monthlyPayload(installationID: installationID))
            )
        }

        let first = Task { try await harness.controller.activate(licenseKey: "GEQ1-KEY") }
        #expect(await waitUntil { harness.service.calls.count == 1 })

        await #expect(throws: LicensingError.operationInProgress) {
            try await harness.controller.activate(licenseKey: "GEQ1-OTHER")
        }
        await #expect(throws: LicensingError.operationInProgress) {
            try await harness.controller.deactivateCurrent()
        }
        gate.open()
        try await first.value
        #expect(harness.service.calls.count == 1)
    }

    // MARK: Refresh scheduling

    @Test
    func refreshRunsAtRefreshAfterAndStoresTheNewRevision() async throws {
        let fixture = try EntitlementFixture()
        let start = fixture.refreshAfter - 10
        let harness = ControllerHarness(
            fixture: fixture,
            activation: try fixture.monthlyActivationState(highestTrustedTime: start),
            wallTime: start
        )
        harness.serveMonthlyRefresh(revision: 8, startingAt: fixture.refreshAfter)
        _ = await harness.subscribe()

        let deadline = try #require(await harness.clock.waitForSleeper())
        #expect(deadline == .seconds(10))
        harness.advance(seconds: 10)

        #expect(await waitUntil { harness.store.activation?.highestAcceptedRevision == 8 })
        #expect(harness.service.refreshCallCount == 1)
        let stored = try #require(harness.store.activation)
        #expect(stored.highestTrustedTime == fixture.refreshAfter)
        #expect(stored.serverDeniedAt == nil)
        let snapshot = try #require(await harness.recorder.waitForSnapshot {
            guard let terms = $0.content.terms else { return false }
            return terms.billingPeriodEnd != fixture.billingPeriodEnd
        })
        #expect(snapshot.content.state == .monthlyActive)
        #expect(snapshot.content.lastRefreshFailure == nil)
    }

    @Test
    func overdueRefreshAtLaunchRunsImmediately() async throws {
        let fixture = try EntitlementFixture()
        let start = fixture.refreshAfter + 5
        let harness = ControllerHarness(
            fixture: fixture,
            activation: try fixture.monthlyActivationState(highestTrustedTime: start),
            wallTime: start
        )
        harness.serveMonthlyRefresh(revision: 8)

        let snapshot = await harness.subscribe()

        #expect(snapshot.content.state == .monthlyActive)
        #expect(await waitUntil { harness.store.activation?.highestAcceptedRevision == 8 })
        #expect(harness.clock.requestedDeadlines.first == .zero)
        #expect(harness.service.refreshCallCount == 1)
        // The refreshed schedule is in the future again, so the next wake is the hourly checkpoint.
        let deadline = try #require(await harness.clock.waitForSleeper())
        #expect(deadline == .seconds(TrustedTimeState.persistenceIntervalSeconds))
    }

    @Test
    func aRefreshedScheduleThatIsAlreadyDueRetriesAtTheCapInsteadOfLooping() async throws {
        let fixture = try EntitlementFixture()
        let start = fixture.refreshAfter + 5
        let harness = ControllerHarness(
            fixture: fixture,
            activation: try fixture.monthlyActivationState(highestTrustedTime: start),
            wallTime: start
        )
        harness.service.onRefresh { _, installationID in
            try fixture.sign(payload: fixture.monthlyPayload(revision: 8, installationID: installationID))
        }

        _ = await harness.subscribe()

        #expect(await waitUntil { harness.store.activation?.highestAcceptedRevision == 8 })
        let deadline = try #require(await harness.clock.waitForSleeper())
        #expect(deadline == .seconds(3_600))
        #expect(harness.service.refreshCallCount == 1)
    }

    @Test
    func signedExpiryIsPublishedWhileARefreshIsStillInFlight() async throws {
        let fixture = try EntitlementFixture()
        let start = fixture.expiresAt - 1
        let harness = ControllerHarness(
            fixture: fixture,
            activation: try fixture.monthlyActivationState(highestTrustedTime: start),
            wallTime: start
        )
        let gate = AsyncGate()
        harness.service.onRefresh { _, installationID in
            await gate.wait()
            return try fixture.sign(payload: fixture.monthlyPayload(
                startingAt: fixture.expiresAt,
                revision: 8,
                installationID: installationID
            ))
        }
        _ = await harness.subscribe()

        #expect(await waitUntil { harness.service.refreshCallCount == 1 })
        let expiryDeadline = try #require(await harness.clock.waitForSleeper())
        #expect(expiryDeadline == .seconds(1), "Scheduled \(expiryDeadline) instead of the signed expiry")

        harness.advance(seconds: 1)
        let expired = try #require(await harness.recorder.waitForSnapshot(state: .monthlyExpired))
        #expect(!expired.content.permitsProcessing)
        #expect(harness.service.refreshCallCount == 1)

        gate.open()
        let renewed = try #require(await harness.recorder.waitForSnapshot(state: .monthlyActive))
        #expect(renewed.content.permitsProcessing)
    }

    @Test
    func failedRefreshBacksOffAndBecomesVerificationNeededWhileStillProcessing() async throws {
        let fixture = try EntitlementFixture()
        let start = fixture.refreshAfter - 10
        let harness = ControllerHarness(
            fixture: fixture,
            activation: try fixture.monthlyActivationState(highestTrustedTime: start),
            wallTime: start
        )
        harness.serveRefreshFailure(.transport(.offline))
        _ = await harness.subscribe()

        await harness.clock.fireNextDeadline()
        let needed = try #require(await harness.recorder.waitForSnapshot(state: .verificationNeeded))
        #expect(needed.content.permitsProcessing)
        #expect(needed.content.lastRefreshFailure == .offline)
        #expect(harness.service.refreshCallCount == 1)

        var deadline = try #require(await harness.clock.waitForSleeper())
        #expect(deadline == .seconds(10 + 60))
        harness.advance(seconds: 60)
        #expect(await waitUntil { harness.service.refreshCallCount == 2 })

        deadline = try #require(await harness.clock.waitForSleeper())
        #expect(deadline == .seconds(10 + 60 + 300))
        harness.advance(seconds: 300)
        #expect(await waitUntil { harness.service.refreshCallCount == 3 })

        deadline = try #require(await harness.clock.waitForSleeper())
        #expect(deadline == .seconds(10 + 60 + 300 + 900))
        harness.advance(seconds: 900)
        #expect(await waitUntil { harness.service.refreshCallCount == 4 })
        deadline = try #require(await harness.clock.waitForSleeper())
        // The hourly trusted-time checkpoint comes before the capped retry.
        #expect(deadline == .seconds(TrustedTimeState.persistenceIntervalSeconds))

        harness.serveMonthlyRefresh(revision: 8)
        harness.advance(seconds: 3_600)
        let recovered = try #require(await harness.recorder.waitForSnapshot { $0.content.state == .monthlyActive && $0.content.lastRefreshFailure == nil })
        #expect(recovered.content.permitsProcessing)
    }

    @Test
    func rateLimitingHonoursALongerRetryAfter() async throws {
        let fixture = try EntitlementFixture()
        let start = fixture.refreshAfter
        let harness = ControllerHarness(
            fixture: fixture,
            activation: try fixture.monthlyActivationState(highestTrustedTime: start),
            wallTime: start
        )
        harness.serveRefreshFailure(.service(code: .rateLimited, retryAfterSeconds: 500))
        _ = await harness.subscribe()

        _ = try #require(await harness.recorder.waitForSnapshot(state: .verificationNeeded))

        let deadline = try #require(await harness.clock.waitForSleeper())
        #expect(deadline == .seconds(500))
    }

    @Test
    func graceWithAFailedRefreshStaysGrace() async throws {
        let fixture = try EntitlementFixture()
        let start = fixture.recoveryUntil + 5
        let harness = ControllerHarness(
            fixture: fixture,
            activation: try fixture.monthlyActivationState(highestTrustedTime: start),
            wallTime: start
        )
        harness.serveRefreshFailure(.transport(.offline))

        let snapshot = await harness.subscribe()
        #expect(snapshot.content.state == .monthlyGrace)

        await harness.clock.fireNextDeadline()
        #expect(await waitUntil { harness.service.refreshCallCount == 1 })
        let afterFailure = try #require(await harness.recorder.waitForSnapshot { $0.content.lastRefreshFailure == .offline })
        #expect(afterFailure.content.state == .monthlyGrace)
        #expect(afterFailure.content.permitsProcessing)
    }

    @Test(arguments: [
        (LicenseState.monthlyRecovery, Int64(0)),
        (.monthlyGrace, 0),
        (.monthlyExpired, 0)
    ])
    func schedulerWakesAtEachSignedBoundary(expected: LicenseState, _: Int64) async throws {
        let fixture = try EntitlementFixture()
        let boundary: Int64 = switch expected {
        case .monthlyRecovery: fixture.billingPeriodEnd
        case .monthlyGrace: fixture.recoveryUntil
        default: fixture.expiresAt
        }
        let start = boundary - 10
        // A recently refreshed entitlement, so no refresh is due before the boundary.
        let harness = ControllerHarness(
            fixture: fixture,
            activation: try fixture.monthlyActivationState(
                issuedAt: start - 100,
                refreshAfter: min(boundary + 1_000, fixture.expiresAt),
                highestTrustedTime: start
            ),
            wallTime: start
        )
        let before = await harness.subscribe()
        #expect(before.content.state != expected)

        let deadline = try #require(await harness.clock.waitForSleeper())
        #expect(deadline == .seconds(10))
        harness.advance(seconds: 10)

        let after = try #require(await harness.recorder.waitForSnapshot(state: expected))
        #expect(after.content.permitsProcessing == expected.permitsProcessing)
        // Crossing `exp` also crosses `refresh_after`, so only expiry triggers a renewal check.
        #expect(harness.service.calls.isEmpty || expected == .monthlyExpired)
    }

    @Test
    func noPastBoundaryIsScheduledAndTheHourlyCheckpointPersistsTheFloor() async throws {
        let fixture = try EntitlementFixture()
        let harness = ControllerHarness(
            fixture: fixture,
            activation: try fixture.monthlyActivationState()
        )
        _ = await harness.subscribe()

        let deadline = try #require(await harness.clock.waitForSleeper())
        #expect(deadline == .seconds(TrustedTimeState.persistenceIntervalSeconds))
        harness.advance(seconds: TrustedTimeState.persistenceIntervalSeconds)

        #expect(await waitUntil { harness.store.saveActivationCount == 1 })
        #expect(harness.store.activation?.highestTrustedTime == fixture.issuedAt + TrustedTimeState.persistenceIntervalSeconds)
        #expect(harness.service.calls.isEmpty)
        let next = try #require(await harness.clock.waitForSleeper())
        #expect(next == .seconds(2 * TrustedTimeState.persistenceIntervalSeconds))
    }

    // MARK: Refresh outcomes

    @Test
    func staleRevisionFromTheServerIsRejected() async throws {
        let fixture = try EntitlementFixture()
        let harness = ControllerHarness(fixture: fixture, activation: try fixture.monthlyActivationState())
        harness.serveMonthlyRefresh(revision: 6)
        _ = await harness.subscribe()

        await harness.controller.refreshNow()

        let snapshot = await harness.controller.currentSnapshot()
        #expect(snapshot.content.lastRefreshFailure == .invalidEntitlementReceived(.staleRevision))
        #expect(harness.store.activation?.highestAcceptedRevision == 7)
        #expect(harness.store.saveActivationCount == 0)
    }

    @Test
    func temporaryServiceFailureIsReportedAsUnavailable() async throws {
        let fixture = try EntitlementFixture()
        let harness = ControllerHarness(fixture: fixture, activation: try fixture.monthlyActivationState())
        harness.serveRefreshFailure(.service(
            code: .temporarilyUnavailable,
            retryAfterSeconds: 120
        ))

        await harness.controller.refreshNow()

        let snapshot = await harness.controller.currentSnapshot()
        #expect(snapshot.content.lastRefreshFailure == .serviceUnavailable)
        #expect(await harness.clock.waitForSleeper() == .seconds(120))
    }

    @Test
    func refreshBeforeSubscriptionLoadsAndUpdatesTheStoredActivation() async throws {
        let fixture = try EntitlementFixture()
        let harness = ControllerHarness(fixture: fixture, activation: try fixture.monthlyActivationState())
        harness.serveMonthlyRefresh(revision: 8)

        await harness.controller.refreshNow()

        #expect(harness.service.refreshCallCount == 1)
        #expect(harness.store.activation?.highestAcceptedRevision == 8)
    }

    @Test
    func authenticatedRefreshRebasesAPoisonedForwardClockFloor() async throws {
        let fixture = try EntitlementFixture()
        let correctedWall = fixture.issuedAt + 100
        let harness = ControllerHarness(
            fixture: fixture,
            activation: try fixture.monthlyActivationState(
                highestTrustedTime: fixture.expiresAt + 1_000
            ),
            wallTime: correctedWall
        )
        harness.serveMonthlyRefresh(revision: 8, startingAt: correctedWall)

        await harness.controller.refreshNow()

        let stored = try #require(harness.store.activation)
        #expect(stored.highestTrustedTime == correctedWall)
        #expect(stored.wallClockAtLastVerification == correctedWall)
        #expect(await harness.controller.currentSnapshot().content.state == .monthlyActive)
    }

    @Test
    func authenticatedRollbackBaselineSurvivesRelaunch() async throws {
        let fixture = try EntitlementFixture()
        let serverTime = fixture.issuedAt + 10 * 60 * 60
        let harness = ControllerHarness(
            fixture: fixture,
            activation: try fixture.monthlyActivationState(highestTrustedTime: serverTime),
            wallTime: fixture.issuedAt
        )
        harness.serveMonthlyRefresh(revision: 8, startingAt: serverTime)
        await harness.controller.refreshNow()
        let stored = try #require(harness.store.activation)

        let relaunch = ControllerHarness(
            fixture: fixture,
            activation: stored,
            wallTime: fixture.issuedAt
        )
        _ = await relaunch.controller.currentSnapshot()

        #expect(relaunch.store.activation?.clockAnomalyDetectedAt == nil)
        #expect(relaunch.service.calls.isEmpty)
    }

    @Test
    func licenseNotEligiblePersistsTheDenialAcrossAnOfflineRelaunch() async throws {
        let fixture = try EntitlementFixture()
        let harness = ControllerHarness(fixture: fixture, activation: try fixture.monthlyActivationState())
        harness.serveRefreshFailure(notEligible())
        _ = await harness.subscribe()

        await harness.controller.refreshNow()

        let denied = try #require(await harness.recorder.waitForSnapshot(state: .monthlyExpired))
        #expect(!denied.content.permitsProcessing)
        guard let terms = denied.content.terms else {
            Issue.record("expected monthly terms")
            return
        }
        #expect(terms.expiresAt == fixture.expiresAt)
        #expect(harness.store.activation?.serverDeniedAt == fixture.issuedAt)
        let retry = try #require(await harness.clock.waitForSleeper())
        #expect(retry == .seconds(3_600))

        let relaunch = ControllerHarness(
            fixture: fixture,
            activation: harness.store.activation,
            wallTime: fixture.issuedAt + 100
        )
        relaunch.serveRefreshFailure(.transport(.offline))
        #expect(await relaunch.subscribe().content.state == .monthlyExpired)

        relaunch.serveMonthlyRefresh(revision: 8)
        await relaunch.controller.refreshNow()
        #expect(await relaunch.controller.currentSnapshot().content.state == .monthlyActive)
        #expect(relaunch.store.activation?.serverDeniedAt == nil)
    }

    @Test(arguments: [LicenseServiceErrorCode.activationRevoked, .invalidCredentials])
    func revokedCredentialsKeepOfflineAuthorityUntilTheSignedExpiry(code: LicenseServiceErrorCode) async throws {
        let fixture = try EntitlementFixture()
        let harness = ControllerHarness(fixture: fixture, activation: try fixture.monthlyActivationState())
        harness.serveRefreshFailure(.service(code: code, retryAfterSeconds: nil))
        _ = await harness.subscribe()

        await harness.controller.refreshNow()

        let revoked = await harness.controller.currentSnapshot()
        #expect(revoked.content.state == .monthlyActive)
        #expect(revoked.content.permitsProcessing)
        #expect(revoked.content.lastRefreshFailure == .rejected(.activationRevoked))
        #expect(harness.store.activation?.serviceRevokedAt == fixture.issuedAt)
        #expect(harness.store.clearCount == 0)

        // No credential is left to refresh with, so the schedule follows the signed boundaries only.
        harness.advance(seconds: fixture.recoveryUntil - fixture.issuedAt - 1)
        let grace = await harness.controller.currentSnapshot()
        #expect(grace.content.state == .monthlyRecovery || grace.content.state == .verificationNeeded)
        for _ in 0 ..< 20 { await Task.yield() }
        #expect(harness.service.refreshCallCount == 1)
        let deadline = try #require(await harness.clock.waitForSleeper())
        #expect(deadline == harness.clock.now() + .seconds(1))

        let relaunch = ControllerHarness(
            fixture: fixture,
            activation: harness.store.activation,
            wallTime: fixture.expiresAt
        )
        #expect(await relaunch.subscribe().content.state == .monthlyExpired)
        #expect(relaunch.service.calls.isEmpty)
    }

    @Test
    func aRevokedPerpetualLicenseKeepsProcessing() async throws {
        let fixture = try EntitlementFixture()
        let harness = ControllerHarness(fixture: fixture, activation: try fixture.perpetualActivationState())
        harness.serveRefreshFailure(.service(code: .activationRevoked, retryAfterSeconds: nil))
        _ = await harness.subscribe()

        await harness.controller.refreshNow()

        #expect(harness.service.calls.isEmpty)
        #expect(await harness.controller.currentSnapshot().content.state == .perpetual)
    }

    @Test
    func aFailedExclusiveOperationDoesNotStrandTheScheduler() async throws {
        let fixture = try EntitlementFixture()
        let start = fixture.refreshAfter - 10
        let harness = ControllerHarness(
            fixture: fixture,
            activation: try fixture.monthlyActivationState(highestTrustedTime: start),
            wallTime: start
        )
        harness.serveMonthlyRefresh(revision: 8)
        _ = await harness.subscribe()

        await #expect(throws: LicensingError.activationAlreadyExists) {
            try await harness.controller.activate(licenseKey: "GEQ1-KEY")
        }

        await harness.clock.fireNextDeadline()
        #expect(await waitUntil { harness.store.activation?.highestAcceptedRevision == 8 })
        #expect(harness.service.refreshCallCount == 1)
        #expect(await harness.clock.waitForSleeper() != nil)
    }

    @Test
    func anOverdueCheckpointRunsImmediatelyAfterRelaunch() async throws {
        let fixture = try EntitlementFixture()
        let twoDays: Int64 = 2 * 24 * 60 * 60
        let harness = ControllerHarness(
            fixture: fixture,
            activation: try fixture.monthlyActivationState(highestTrustedTime: fixture.issuedAt),
            wallTime: fixture.issuedAt + twoDays
        )

        _ = await harness.subscribe()

        #expect(await waitUntil { harness.store.saveActivationCount == 1 })
        #expect(harness.clock.requestedDeadlines.first == .zero)
        #expect(harness.store.activation?.highestTrustedTime == fixture.issuedAt + twoDays)
    }

    @Test
    func activationCannotOverwriteAnExistingLicense() async throws {
        let fixture = try EntitlementFixture()
        let harness = ControllerHarness(
            fixture: fixture,
            activation: try fixture.monthlyActivationState(highestTrustedTime: fixture.expiresAt + 1_000),
            wallTime: fixture.issuedAt
        )
        #expect(await harness.subscribe().content.state == .monthlyExpired)

        await #expect(throws: LicensingError.activationAlreadyExists) {
            try await harness.controller.activate(licenseKey: "GEQ1-NEW")
        }

        #expect(harness.service.calls.isEmpty)
        #expect(harness.store.activation?.activationToken == "gea_test")
    }

    @Test
    func activationCannotOverwriteATombstonedLicense() async throws {
        let fixture = try EntitlementFixture()
        var tombstoned = try fixture.monthlyActivationState()
        tombstoned.deactivationRequestedAt = fixture.issuedAt
        let harness = ControllerHarness(fixture: fixture, activation: tombstoned)

        await #expect(throws: LicensingError.activationAlreadyExists) {
            try await harness.controller.activate(licenseKey: "GEQ1-NEW")
        }

        #expect(harness.service.calls.isEmpty)
        #expect(harness.store.activation?.activationToken == "gea_test")
    }

    @Test
    func activationReplacesACorruptRecord() async throws {
        let fixture = try EntitlementFixture()
        let harness = ControllerHarness(fixture: fixture)
        harness.store.activationLoadFailure = .corruptRecord
        harness.service.onActivate { _, installationID, _ in
            ActivationResponse(
                activationToken: "gea_recovered",
                entitlement: try fixture.sign(payload: fixture.monthlyPayload(
                    installationID: installationID
                ))
            )
        }

        #expect(await harness.subscribe().content.state == .invalidEntitlement)

        try await harness.controller.activate(licenseKey: "GEQ1-NEW")

        #expect(harness.store.clearCount == 1)
        #expect(harness.store.activation?.activationToken == "gea_recovered")
        #expect(await harness.controller.currentSnapshot().content.state == .monthlyActive)
    }

    @Test
    func activationDoesNotReplaceAFutureActivationSchema() async throws {
        let harness = ControllerHarness(fixture: try EntitlementFixture())
        harness.store.activationLoadFailure = .unsupportedSchemaVersion(2)

        #expect(await harness.subscribe().content.state == .invalidEntitlement)
        await #expect(throws: LicensingError.storage(.unsupportedSchemaVersion(2))) {
            try await harness.controller.activate(licenseKey: "GEQ1-NEW")
        }

        #expect(harness.store.clearCount == 0)
        #expect(harness.service.calls.isEmpty)
    }

    @Test
    func deactivationClearsACorruptRecordWithoutCallingTheService() async throws {
        let harness = ControllerHarness(fixture: try EntitlementFixture())
        harness.store.activationLoadFailure = .corruptRecord

        try await harness.controller.deactivateCurrent()

        #expect(harness.store.clearCount == 1)
        #expect(harness.service.calls.isEmpty)
        #expect(await harness.controller.currentSnapshot().content.state == .unlicensed)
    }

    @Test
    func mutationsFailWhenTheStoreCannotBeRead() async throws {
        let fixture = try EntitlementFixture()
        let harness = ControllerHarness(fixture: fixture, activation: try fixture.monthlyActivationState())
        harness.store.loadFailure = .keychain(-25_300)
        harness.service.onActivate { _, _, _ in
            ActivationResponse(activationToken: "gea_new", entitlement: try fixture.sign(payload: fixture.monthlyPayload()))
        }
        harness.service.onDeactivate { _ in }

        await #expect(throws: LicensingError.storage(.keychain(-25_300))) {
            try await harness.controller.activate(licenseKey: "GEQ1-KEY")
        }
        await #expect(throws: LicensingError.storage(.keychain(-25_300))) {
            try await harness.controller.deactivateCurrent()
        }

        #expect(harness.service.calls.isEmpty)
        #expect(harness.store.activation != nil)
    }

    @Test
    func storageAndRefreshRetriesKeepSeparateSchedules() async throws {
        let fixture = try EntitlementFixture()
        let start = fixture.refreshAfter - 10
        let harness = ControllerHarness(
            fixture: fixture,
            activation: try fixture.monthlyActivationState(highestTrustedTime: start),
            wallTime: start
        )
        harness.store.loadFailure = .keychain(-25_300)
        harness.serveRefreshFailure(.transport(.offline))
        _ = await harness.subscribe()

        // Two storage failures escalate the storage schedule only.
        await harness.clock.fireNextDeadline()
        #expect(await waitUntil { harness.clock.pendingDeadlines.first == .seconds(60 + 300) })
        harness.store.loadFailure = nil
        harness.advance(seconds: 300)

        // The load succeeds and the overdue refresh runs at once and fails. Its first failure
        // waits the first interval, not the third.
        _ = try #require(await harness.recorder.waitForSnapshot(state: .verificationNeeded))
        let deadline = try #require(await harness.clock.waitForSleeper())
        #expect(deadline == harness.clock.now() + .seconds(60))
    }

    @Test
    func aRefreshFinishingAfterDeactivationCannotRestoreTheOldState() async throws {
        let fixture = try EntitlementFixture()
        let harness = ControllerHarness(fixture: fixture, activation: try fixture.monthlyActivationState())
        let gate = AsyncGate()
        harness.service.onRefresh { _, installationID in
            await gate.wait()
            return try fixture.sign(payload: fixture.monthlyPayload(revision: 8, installationID: installationID))
        }
        harness.service.onDeactivate { _ in }
        _ = await harness.subscribe()

        let refresh = Task { await harness.controller.refreshNow() }
        #expect(await waitUntil { harness.service.refreshCallCount == 1 })
        try await harness.controller.deactivateCurrent()
        gate.open()
        await refresh.value

        #expect(harness.store.activation == nil)
        #expect(await harness.controller.currentSnapshot().content.state == .unlicensed)
        #expect(harness.recorder.snapshots.allSatisfy { $0.content.highestRevisionIsNotEight })
    }

    @Test
    func concurrentRefreshRequestsMakeOneRequest() async throws {
        let fixture = try EntitlementFixture()
        let harness = ControllerHarness(fixture: fixture, activation: try fixture.monthlyActivationState())
        let gate = AsyncGate()
        harness.service.onRefresh { _, installationID in
            await gate.wait()
            return try fixture.sign(payload: fixture.monthlyPayload(revision: 8, installationID: installationID))
        }
        _ = await harness.subscribe()

        let first = Task { await harness.controller.refreshNow() }
        #expect(await waitUntil { harness.service.refreshCallCount == 1 })
        let second = Task { await harness.controller.refreshNow() }
        for _ in 0 ..< 20 { await Task.yield() }
        gate.open()
        await first.value
        await second.value

        #expect(harness.service.refreshCallCount == 1)
        #expect(harness.store.activation?.highestAcceptedRevision == 8)
    }

    // MARK: Deactivation

    @Test
    func deactivationReleasesTheServerRegistrationAndClearsLocalState() async throws {
        let fixture = try EntitlementFixture()
        let harness = ControllerHarness(fixture: fixture, activation: try fixture.monthlyActivationState())
        harness.service.onDeactivate { _ in }
        _ = await harness.subscribe()

        let returned = try await harness.controller.deactivateCurrent()

        #expect(harness.service.calls == [.deactivate(activationToken: "gea_test")])
        #expect(harness.store.activation == nil)
        // The tombstone is published before the request and refuses activation; the cleared
        // record is published after it and accepts one.
        let published = harness.recorder.snapshots.filter { $0.content.state == .unlicensed }
        #expect(published.map(\.sequence) == [2, 3])
        #expect(published.map(\.content.activation) == [.releasingPreviousActivation, .available])
        #expect(returned == published.last)
    }

    @Test
    func deactivationFailsClosedBeforeTheRequestAndRetriesIt() async throws {
        let fixture = try EntitlementFixture()
        let harness = ControllerHarness(fixture: fixture, activation: try fixture.monthlyActivationState())
        harness.service.onDeactivate { _ in throw LicenseServiceError.transport(.offline) }
        _ = await harness.subscribe()

        await #expect(throws: LicensingError.service(.transport(.offline))) {
            try await harness.controller.deactivateCurrent()
        }

        #expect(harness.store.activation?.deactivationRequestedAt == fixture.issuedAt)
        #expect(await harness.controller.currentSnapshot().content.state == .unlicensed)
        let retry = try #require(await harness.clock.waitForSleeper())
        #expect(retry == .seconds(60))

        harness.service.onDeactivate { _ in }
        harness.advance(seconds: 60)
        #expect(await waitUntil { harness.store.activation == nil })
        #expect(harness.service.calls.filter { if case .deactivate = $0 { true } else { false } }.count == 2)
    }

    @Test(arguments: [LicenseServiceErrorCode.rateLimited, .temporarilyUnavailable])
    func deactivationHonorsRetryAfter(code: LicenseServiceErrorCode) async throws {
        let fixture = try EntitlementFixture()
        let harness = ControllerHarness(fixture: fixture, activation: try fixture.monthlyActivationState())
        let failure = LicenseServiceError.service(code: code, retryAfterSeconds: 3_600)
        harness.service.onDeactivate { _ in throw failure }
        _ = await harness.subscribe()

        await #expect(throws: LicensingError.service(failure)) {
            try await harness.controller.deactivateCurrent()
        }

        #expect(try #require(await harness.clock.waitForSleeper()) == .seconds(3_600))
    }

    @Test
    func tombstoneDoesNotScheduleAnImmediateRetryWhileDeactivationIsInFlight() async throws {
        let fixture = try EntitlementFixture()
        let harness = ControllerHarness(fixture: fixture, activation: try fixture.monthlyActivationState())
        let gate = AsyncGate()
        harness.service.onDeactivate { _ in await gate.wait() }
        _ = await harness.subscribe()

        let deactivation = Task { try await harness.controller.deactivateCurrent() }
        #expect(await waitUntil {
            harness.service.calls.contains(.deactivate(activationToken: "gea_test"))
        })
        #expect(harness.clock.pendingDeadlines.isEmpty)

        gate.open()
        try await deactivation.value
        #expect(harness.store.activation == nil)
    }

    @Test
    func aTombstonedRecordCompletesItsDeactivationOnRelaunch() async throws {
        let fixture = try EntitlementFixture()
        var tombstoned = try fixture.monthlyActivationState()
        tombstoned.deactivationRequestedAt = fixture.issuedAt
        let harness = ControllerHarness(fixture: fixture, activation: tombstoned)
        harness.service.onDeactivate { _ in }

        let snapshot = await harness.subscribe()

        #expect(snapshot.content.state == .unlicensed)
        #expect(!snapshot.content.permitsProcessing)
        #expect(await waitUntil { harness.store.activation == nil })
        #expect(harness.service.calls == [.deactivate(activationToken: "gea_test")])
    }

    @Test
    func aFailedDeletionAfterServerSuccessStaysUnlicensedAndRetries() async throws {
        let fixture = try EntitlementFixture()
        let harness = ControllerHarness(fixture: fixture, activation: try fixture.monthlyActivationState())
        harness.service.onDeactivate { _ in }
        _ = await harness.subscribe()
        harness.store.clearFailure = .keychain(-25_291)

        await #expect(throws: LicensingError.storage(.keychain(-25_291))) {
            try await harness.controller.deactivateCurrent()
        }

        let snapshot = await harness.controller.currentSnapshot()
        #expect(snapshot.content.state == .unlicensed)
        #expect(snapshot.content.storageFailure == .keychain(-25_291))
        #expect(harness.store.activation?.deactivationRequestedAt != nil)
        harness.store.clearFailure = nil
        harness.advance(seconds: 60)
        #expect(await waitUntil { harness.store.activation == nil })
        #expect(await harness.controller.currentSnapshot().content.storageFailure == nil)
    }

    @Test
    func aSavedReplacementCancelsTheStaleDeletionRetry() async throws {
        let fixture = try EntitlementFixture()
        let harness = ControllerHarness(fixture: fixture, activation: try fixture.monthlyActivationState())
        harness.service.onDeactivate { token in
            if token == "gea_new" {
                throw LicenseServiceError.transport(.offline)
            }
        }
        _ = await harness.subscribe()
        harness.store.clearFailure = .keychain(-25_291)

        await #expect(throws: LicensingError.storage(.keychain(-25_291))) {
            try await harness.controller.deactivateCurrent()
        }

        harness.store.clearFailure = nil
        harness.store.failNextActivationSave(with: .keychain(-25_291))
        harness.service.onActivate { _, installationID, _ in
            ActivationResponse(
                activationToken: "gea_new",
                entitlement: try fixture.sign(payload: fixture.monthlyPayload(installationID: installationID))
            )
        }
        await #expect(throws: LicensingError.storage(.keychain(-25_291))) {
            try await harness.controller.activate(licenseKey: "GEQ1-NEW")
        }

        #expect(harness.store.activation?.activationToken == "gea_new")
        #expect(try #require(await harness.clock.waitForSleeper()) == .seconds(60))

        harness.service.onDeactivate { _ in }
        harness.advance(seconds: 60)
        #expect(await waitUntil { harness.store.activation == nil })
        #expect(harness.service.calls.filter {
            $0 == .deactivate(activationToken: "gea_new")
        }.count == 2)
    }

    @Test
    func aPendingTombstoneSaveCancelsTheStaleDeletionRetry() async throws {
        let fixture = try EntitlementFixture()
        let harness = ControllerHarness(fixture: fixture, activation: try fixture.monthlyActivationState())
        harness.service.onDeactivate { token in
            if token == "gea_new" {
                throw LicenseServiceError.transport(.offline)
            }
        }
        _ = await harness.subscribe()
        harness.store.clearFailure = .keychain(-25_291)

        await #expect(throws: LicensingError.storage(.keychain(-25_291))) {
            try await harness.controller.deactivateCurrent()
        }

        harness.store.clearFailure = nil
        harness.store.failNextActivationSave(with: .keychain(-25_291))
        harness.store.failNextActivationSave(with: .keychain(-25_291))
        harness.service.onActivate { _, installationID, _ in
            ActivationResponse(
                activationToken: "gea_new",
                entitlement: try fixture.sign(payload: fixture.monthlyPayload(installationID: installationID))
            )
        }
        await #expect(throws: LicensingError.storage(.keychain(-25_291))) {
            try await harness.controller.activate(licenseKey: "GEQ1-NEW")
        }

        #expect(harness.store.activation?.activationToken == "gea_test")
        #expect(try #require(await harness.clock.waitForSleeper()) == .seconds(60))
        harness.advance(seconds: 60)
        #expect(try #require(await harness.clock.waitForSleeper()) == .seconds(300))
        harness.advance(seconds: 240)

        #expect(await waitUntil { harness.store.activation?.activationToken == "gea_new" })
        #expect(harness.store.clearCount == 1)

        harness.service.onDeactivate { _ in }
        harness.advance(seconds: 60)
        #expect(await waitUntil { harness.store.activation == nil })
        #expect(harness.service.calls.filter {
            $0 == .deactivate(activationToken: "gea_new")
        }.count == 3)
    }

    // MARK: Trusted time

    @Test
    func rollbackBeyondToleranceRequestsAnImmediateRefreshAndKeepsProcessingOffline() async throws {
        let fixture = try EntitlementFixture()
        let harness = ControllerHarness(fixture: fixture, activation: try fixture.monthlyActivationState())
        harness.serveRefreshFailure(.transport(.offline))
        _ = await harness.subscribe()
        let tolerance = TrustedTimeState.rollbackToleranceSeconds

        harness.wall.time = fixture.issuedAt - tolerance
        #expect(await harness.controller.currentSnapshot().content.state == .monthlyActive)

        harness.wall.time = fixture.issuedAt - tolerance - 1
        let anomalous = await harness.controller.currentSnapshot()
        #expect(anomalous.content.state == .verificationNeeded)
        #expect(anomalous.content.permitsProcessing)
        #expect(harness.store.activation?.clockAnomalyDetectedAt == fixture.issuedAt)
        let offline = try #require(await harness.recorder.waitForSnapshot { $0.content.lastRefreshFailure == .offline })
        #expect(harness.service.refreshCallCount == 1)
        #expect(harness.clock.requestedDeadlines.contains(.zero))
        #expect(offline.content.state == .verificationNeeded)
        #expect(offline.content.permitsProcessing)

        harness.serveMonthlyRefresh(revision: 8, startingAt: fixture.issuedAt)
        await harness.controller.refreshNow()
        #expect(await harness.controller.currentSnapshot().content.state == .monthlyActive)
        #expect(harness.store.activation?.clockAnomalyDetectedAt == nil)
        #expect(harness.service.refreshCallCount == 2)

        // The clock is still behind, but that distance was verified. Only a further rollback counts.
        harness.wall.time -= tolerance
        #expect(await harness.controller.currentSnapshot().content.state == .monthlyActive)
        harness.wall.time -= 1
        #expect(await harness.controller.currentSnapshot().content.state == .verificationNeeded)
    }

    @Test
    func rollbackMarkerPersistsTheAdvancedTrustedTimeFloor() async throws {
        let fixture = try EntitlementFixture()
        let harness = ControllerHarness(fixture: fixture, activation: try fixture.monthlyActivationState())
        harness.serveRefreshFailure(.transport(.offline))
        _ = await harness.subscribe()

        harness.advance(seconds: 100)
        #expect(harness.store.activation?.highestTrustedTime == fixture.issuedAt)

        harness.wall.time = fixture.issuedAt - TrustedTimeState.rollbackToleranceSeconds - 1
        _ = await harness.controller.currentSnapshot()

        #expect(harness.store.activation?.highestTrustedTime == fixture.issuedAt + 100)
        #expect(harness.store.activation?.clockAnomalyDetectedAt == fixture.issuedAt + 100)
    }

    @Test
    func checkpointPersistsTheAdvancedFloorAndALaterLaunchKeepsIt() async throws {
        let fixture = try EntitlementFixture()
        let harness = ControllerHarness(fixture: fixture, activation: try fixture.monthlyActivationState())
        _ = await harness.subscribe()

        await harness.controller.checkpoint()
        #expect(harness.store.saveActivationCount == 0)

        harness.advance(seconds: 100)
        await harness.controller.checkpoint()
        #expect(harness.store.saveActivationCount == 1)
        #expect(harness.store.activation?.highestTrustedTime == fixture.issuedAt + 100)

        let relaunch = ControllerHarness(
            fixture: fixture,
            activation: harness.store.activation,
            wallTime: fixture.issuedAt - 50
        )
        _ = await relaunch.subscribe()
        relaunch.advance(seconds: 1)
        await relaunch.controller.checkpoint()
        #expect(relaunch.store.activation?.highestTrustedTime == fixture.issuedAt + 101)
    }

    @Test
    func failedCheckpointWriteKeepsProcessingAndRetries() async throws {
        let fixture = try EntitlementFixture()
        let harness = ControllerHarness(fixture: fixture, activation: try fixture.monthlyActivationState())
        _ = await harness.subscribe()
        harness.store.saveFailure = .keychain(-25_291)
        harness.advance(seconds: 100)

        await harness.controller.checkpoint()

        let snapshot = await harness.controller.currentSnapshot()
        #expect(snapshot.content.state == .monthlyActive)
        #expect(snapshot.content.storageFailure == .keychain(-25_291))
        let deadline = try #require(await harness.clock.waitForSleeper())
        #expect(deadline == .seconds(100 + 60))
        harness.store.saveFailure = nil
        harness.advance(seconds: 60)
        #expect(await waitUntil { harness.store.activation?.highestTrustedTime == fixture.issuedAt + 160 })
        #expect(await harness.controller.currentSnapshot().content.storageFailure == nil)
    }

    // MARK: Publishing and ownership

    @Test
    func snapshotsAreDeduplicatedAndSequencesIncrease() async throws {
        let fixture = try EntitlementFixture()
        let harness = ControllerHarness(fixture: fixture, activation: try fixture.monthlyActivationState())

        let first = await harness.subscribe()
        let again = await harness.controller.currentSnapshot()
        harness.serveRefreshFailure(notEligible())
        await harness.controller.refreshNow()
        harness.serveMonthlyRefresh(revision: 8)
        await harness.controller.refreshNow()

        #expect(again == first)
        let sequences = harness.recorder.snapshots.map(\.sequence)
        #expect(sequences == [2, 3])
        #expect(harness.recorder.snapshots.map(\.content.state) == [.monthlyExpired, .monthlyActive])
    }

    @Test
    func shutdownReleasesTheSchedulerSoTheControllerDeinitializes() async throws {
        let fixture = try EntitlementFixture()
        var harness: ControllerHarness? = ControllerHarness(fixture: fixture, activation: try fixture.monthlyActivationState())
        let weakController = WeakControllerBox(harness?.controller)
        _ = await harness?.subscribe()
        _ = try #require(await harness?.clock.waitForSleeper())

        await harness?.controller.shutdown()
        harness = nil

        #expect(await waitUntil { weakController.value == nil })
    }
}

private final class WeakControllerBox: @unchecked Sendable {
    private let lock = NSLock()
    private weak var controller: LicensingController?

    init(_ controller: LicensingController?) {
        self.controller = controller
    }

    var value: LicensingController? { lock.withLock { controller } }
}

private final class AttemptCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func next() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }
}

private extension LicenseSnapshotContent {
    /// The refreshed entitlement in these tests shifts no dates, so its only visible trace would be
    /// a change of state after deactivation; an unlicensed tail is the expected outcome.
    var highestRevisionIsNotEight: Bool {
        state == .unlicensed || state == .monthlyActive
    }
}
