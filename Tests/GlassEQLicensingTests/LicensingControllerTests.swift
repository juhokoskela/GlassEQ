import Foundation
import Testing
@testable import GlassEQLicensing

@Suite
struct LicensingControllerTests {
    private func notEligible() -> LicenseServiceError {
        .service(code: .licenseNotEligible, retryable: false, requestID: "req", retryAfterSeconds: nil)
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
            #expect(snapshot.content.expiresAt == fixture.expiresAt)
            #expect(snapshot.content.billingState == .active)
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
        #expect(snapshot.content.updateAccess == .v1)
        for _ in 0 ..< 20 { await Task.yield() }
        #expect(harness.clock.requestedDeadlines.isEmpty)
        #expect(harness.service.calls.isEmpty)
    }

    @Test
    func corruptRecordAndForeignInstallationAreInvalidEntitlements() async throws {
        let fixture = try EntitlementFixture()
        let corrupt = ControllerHarness(fixture: fixture)
        corrupt.store.corruptActivation = true
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
        #expect(snapshot.content.plan == .monthly)
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
            code: .activationLimit, retryable: false, requestID: "req", retryAfterSeconds: nil
        )
        harness.service.onActivate { _, _, _ in throw limit }

        await #expect(throws: LicensingError.service(limit)) {
            try await harness.controller.activate(licenseKey: "GEQ1-KEY")
        }
        #expect(harness.store.activation == nil)

        harness.service.onActivate { _, _, _ in
            ActivationResponse(activationToken: "gea_new", entitlement: try fixture.sign(payload: fixture.monthlyPayload()))
        }
        harness.store.saveFailure = .keychain(-25_291)
        await #expect(throws: LicensingError.storage(.keychain(-25_291))) {
            try await harness.controller.activate(licenseKey: "GEQ1-KEY")
        }
        #expect(await harness.controller.currentSnapshot().content.state == .unlicensed)
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
        let snapshot = try #require(await harness.recorder.waitForSnapshot { $0.content.billingPeriodEnd != fixture.billingPeriodEnd })
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
        #expect(deadline == .seconds(900))
        #expect(harness.service.refreshCallCount == 1)
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
        #expect(deadline == .seconds(10 + 60 + 300 + 900 + 900))

        harness.serveMonthlyRefresh(revision: 8)
        harness.advance(seconds: 900)
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
        harness.serveRefreshFailure(.service(code: .rateLimited, retryable: true, requestID: nil, retryAfterSeconds: 500))
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
    func licenseNotEligiblePersistsTheDenialAcrossAnOfflineRelaunch() async throws {
        let fixture = try EntitlementFixture()
        let harness = ControllerHarness(fixture: fixture, activation: try fixture.monthlyActivationState())
        harness.serveRefreshFailure(notEligible())
        _ = await harness.subscribe()

        await harness.controller.refreshNow()

        let denied = try #require(await harness.recorder.waitForSnapshot(state: .monthlyExpired))
        #expect(!denied.content.permitsProcessing)
        #expect(denied.content.expiresAt == fixture.expiresAt)
        #expect(denied.content.updateAccess == .securityOnly)
        #expect(harness.store.activation?.serverDeniedAt == fixture.issuedAt)
        let retry = try #require(await harness.clock.waitForSleeper())
        #expect(retry == .seconds(900))

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
    func revokedCredentialsClearTheActivation(code: LicenseServiceErrorCode) async throws {
        let fixture = try EntitlementFixture()
        let harness = ControllerHarness(fixture: fixture, activation: try fixture.monthlyActivationState())
        harness.serveRefreshFailure(.service(code: code, retryable: false, requestID: nil, retryAfterSeconds: nil))
        _ = await harness.subscribe()

        await harness.controller.refreshNow()

        #expect(await harness.controller.currentSnapshot().content.state == .unlicensed)
        #expect(harness.store.activation == nil)
        #expect(harness.store.clearCount == 1)
        #expect(harness.store.identity != nil)
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

        try await harness.controller.deactivateCurrent()

        #expect(harness.service.calls == [.deactivate(activationToken: "gea_test")])
        #expect(harness.store.activation == nil)
        let snapshot = try #require(await harness.recorder.waitForSnapshot(state: .unlicensed))
        #expect(snapshot.sequence == 2)
    }

    @Test
    func deactivationTransportFailureKeepsTheActivation() async throws {
        let fixture = try EntitlementFixture()
        let harness = ControllerHarness(fixture: fixture, activation: try fixture.monthlyActivationState())
        harness.service.onDeactivate { _ in throw LicenseServiceError.transport(.offline) }
        _ = await harness.subscribe()

        await #expect(throws: LicensingError.service(.transport(.offline))) {
            try await harness.controller.deactivateCurrent()
        }

        #expect(harness.store.activation != nil)
        #expect(await harness.controller.currentSnapshot().content.state == .monthlyActive)
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
