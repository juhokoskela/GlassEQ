import Foundation

public enum LicensingError: Error, Equatable, LocalizedError, Sendable {
    case operationInProgress
    case activationAlreadyExists
    case storage(LicenseCredentialStoreError)
    case service(LicenseServiceError)
    case entitlement(EntitlementVerificationError)

    public var errorDescription: String? {
        switch self {
        case .operationInProgress:
            "Another licensing operation is already in progress."
        case .activationAlreadyExists:
            "Deactivate the current license before activating another one."
        case .storage:
            "The license could not be read from or saved to Keychain."
        case .service:
            "The licensing service could not complete the request."
        case .entitlement(.issuedInFuture):
            "Check this Mac's date and time, then try activating again."
        case .entitlement:
            "The licensing service returned an invalid entitlement."
        }
    }
}

/// The single owner of licensing state in the main app. It loads and persists the Keychain
/// records, verifies the cached entitlement, tracks trusted time, refreshes on the signed
/// schedule, and publishes immutable snapshots. It never touches audio.
public actor LicensingController {
    private static let retryBackoff: [Duration] = [
        .seconds(60), .seconds(5 * 60), .seconds(15 * 60), .seconds(60 * 60)
    ]

    private enum LoadedActivation: Equatable {
        case notLoaded
        case none
        case corrupt
        case state(ActivationState)
    }

    private struct Evaluation {
        let content: LicenseSnapshotContent
        let claims: EntitlementClaims?
        let effectiveTime: Int64
    }

    /// Bounded exponential backoff for one failure domain. Storage and network failures keep
    /// separate instances so one cannot escalate or suppress the other's schedule.
    private struct RetryState: Equatable {
        var failures = 0
        var deadline: Duration?

        mutating func recordFailure(
            now: Duration,
            jitterMultiplier: Double,
            atLeast minimum: Duration? = nil
        ) {
            failures += 1
            let base = LicensingController.retryBackoff[
                min(failures, LicensingController.retryBackoff.count) - 1
            ]
            var delay = Duration.seconds(max(
                Int64((Double(base.components.seconds) * jitterMultiplier).rounded()),
                1
            ))
            if let minimum {
                delay = max(delay, minimum)
            }
            deadline = now + delay
        }

        mutating func holdAtCap(now: Duration, jitterMultiplier: Double) {
            failures = LicensingController.retryBackoff.count
            let seconds = Double(
                LicensingController.retryBackoff[LicensingController.retryBackoff.count - 1]
                    .components.seconds
            )
            deadline = now + .seconds(max(Int64((seconds * jitterMultiplier).rounded()), 1))
        }

        mutating func reset() {
            failures = 0
            deadline = nil
        }

        func isDue(now: Duration) -> Bool {
            guard let deadline else { return true }
            return now >= deadline
        }
    }

    private let store: any LicenseCredentialStore
    private let service: any LicenseServicing
    private let verifier: EntitlementVerifier
    private let wallClock: @Sendable () -> Int64
    private let clock: any LicensingClock
    private let retryJitterMultiplier: Double

    private var identity: InstallationIdentity?
    private var activation = LoadedActivation.notLoaded
    private var trustedTime: TrustedTimeState
    private var storageFailure: LicenseCredentialStoreError?
    /// The in-memory record is ahead of the Keychain and the write is retried.
    private var persistencePending = false
    /// The Keychain still holds a record the controller has already retired.
    private var clearPending = false
    private var storageRetry = RetryState()
    private var lastRefreshFailure: LicenseRefreshFailure?
    private var refreshRetry = RetryState()
    private var verifiedEntitlement: VerifiedEntitlement?

    private var operationGeneration: UInt64 = 0
    private var exclusiveOperationInProgress = false
    private var inFlightRefresh: Task<Void, Never>?
    private var scheduler: Task<Void, Never>?
    private var schedulerGeneration: UInt64 = 0
    private var isShutdown = false
    private var handler: (@Sendable (LicenseSnapshot) -> Void)?
    private var lastPublished: LicenseSnapshot?

    public init(
        store: any LicenseCredentialStore,
        service: any LicenseServicing,
        verifier: EntitlementVerifier,
        wallClock: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) },
        clock: any LicensingClock = ContinuousLicensingClock()
    ) {
        self.init(
            store: store,
            service: service,
            verifier: verifier,
            wallClock: wallClock,
            clock: clock,
            retryJitterMultiplier: Double.random(in: 0.8 ... 1.2)
        )
    }

    init(
        store: any LicenseCredentialStore,
        service: any LicenseServicing,
        verifier: EntitlementVerifier,
        wallClock: @escaping @Sendable () -> Int64,
        clock: any LicensingClock,
        retryJitterMultiplier: Double
    ) {
        precondition((0.8 ... 1.2).contains(retryJitterMultiplier))
        self.store = store
        self.service = service
        self.verifier = verifier
        self.wallClock = wallClock
        self.clock = clock
        self.retryJitterMultiplier = retryJitterMultiplier
        trustedTime = TrustedTimeState(persistedTrustedTime: nil, wallClock: wallClock(), now: clock.now())
    }

    deinit {
        scheduler?.cancel()
    }

    // MARK: Public surface

    /// Returns the current snapshot and delivers every later change through `handler`. The
    /// handler runs on the actor; callers hop to their own isolation.
    public func subscribe(
        _ handler: @escaping @Sendable (LicenseSnapshot) -> Void
    ) -> LicenseSnapshot {
        let snapshot = currentSnapshot()
        self.handler = handler
        return snapshot
    }

    public func currentSnapshot() -> LicenseSnapshot {
        loadIfNeeded()
        let evaluation = evaluate()
        let snapshot = publish(evaluation.content)
        reschedule(evaluation)
        return snapshot
    }

    public func activate(licenseKey: String) async throws {
        try beginExclusiveOperation()
        defer { endExclusiveOperation() }
        try loadForMutation()
        guard case .state = activation else {
            return try await activateNewLicense(licenseKey: licenseKey)
        }
        throw LicensingError.activationAlreadyExists
    }

    private func activateNewLicense(licenseKey: String) async throws {
        let identity = try ensureIdentity()
        let idempotencyKey = UUID()

        let response: ActivationResponse
        do {
            response = try await activateWithRetry(
                licenseKey: licenseKey,
                installationID: identity.installationID,
                idempotencyKey: idempotencyKey
            )
        } catch let error {
            throw LicensingError.service(error)
        }

        // A replacement license starts its own trusted-time floor. The server's authenticated
        // issuance time anchors it; a previous activation's floor must not expire the new one.
        let now = clock.now()
        var fresh = TrustedTimeState(persistedTrustedTime: nil, wallClock: wallClock(), now: now)
        let verified: VerifiedEntitlement
        do {
            verified = try verifier.verify(
                response.entitlement,
                installationID: identity.installationID,
                highestAcceptedRevision: nil,
                effectiveTime: fresh.effectiveTime(wallClock: wallClock(), now: now)
            )
        } catch let error as EntitlementVerificationError {
            await retireUnusableActivation(response.activationToken)
            throw LicensingError.entitlement(error)
        }
        fresh.anchor(issuedAt: verified.claims.issuedAt, at: now)

        let state = ActivationState(
            activationToken: response.activationToken,
            entitlement: response.entitlement,
            highestAcceptedRevision: verified.claims.revision,
            highestTrustedTime: fresh.highestTrustedTime,
            wallClockAtLastVerification: wallClock()
        )
        do {
            try store.saveActivationState(state)
        } catch let error {
            await retireUnusableActivation(response.activationToken)
            throw LicensingError.storage(error)
        }
        fresh.markPersisted()
        trustedTime = fresh
        activation = .state(state)
        verifiedEntitlement = verified
        storageFailure = nil
        persistencePending = false
        clearPending = false
        storageRetry.reset()
        resetRefreshFailures()
    }

    private func retireUnusableActivation(_ token: String) async {
        let requestedAt = max(wallClock(), 0)
        let state = ActivationState.pendingDeactivation(
            activationToken: token,
            requestedAt: requestedAt
        )
        persist(state)
        try? await completeDeactivation(state)
    }

    /// Releases this installation's server registration and its local authority. The record is
    /// tombstoned before the request, so the installation is unlicensed from here on even if the
    /// request or the Keychain deletion fails; both are retried.
    public func deactivateCurrent() async throws {
        try beginExclusiveOperation()
        defer { endExclusiveOperation() }
        try loadForMutation()
        guard case var .state(state) = activation else {
            return
        }
        if state.deactivationRequestedAt == nil {
            state.deactivationRequestedAt = wallClock()
            do {
                try store.saveActivationState(state)
            } catch let error {
                throw LicensingError.storage(error)
            }
            activation = .state(state)
            inFlightRefresh?.cancel()
            resetRefreshFailures()
            publishAndReschedule()
        }
        try await completeDeactivation(state)
    }

    /// Performs one refresh, coalescing onto an in-flight one.
    public func refreshNow() async {
        loadIfNeeded()
        if let inFlightRefresh {
            await inFlightRefresh.value
            return
        }
        let task = Task { await self.performRefresh() }
        inFlightRefresh = task
        publishAndReschedule()
        await task.value
    }

    /// Persists the trusted-time floor if it advanced since the last write.
    public func checkpoint() {
        _ = observeTime()
        persistTrustedTime(force: true)
    }

    public func shutdown() {
        isShutdown = true
        schedulerGeneration &+= 1
        scheduler?.cancel()
        scheduler = nil
        inFlightRefresh?.cancel()
    }

    // MARK: Loading and persistence

    @discardableResult
    private func loadIfNeeded() -> LicenseCredentialStoreError? {
        guard activation == .notLoaded else {
            return nil
        }
        do {
            identity = try store.loadInstallationIdentity()
            if let state = try store.loadActivationState() {
                activation = .state(state)
                verifiedEntitlement = nil
                trustedTime = TrustedTimeState(
                    persistedTrustedTime: state.highestTrustedTime,
                    wallClock: wallClock(),
                    now: clock.now()
                )
            } else {
                activation = .none
                verifiedEntitlement = nil
            }
            storageFailure = nil
            storageRetry.reset()
            return nil
        } catch LicenseCredentialStoreError.corruptRecord {
            activation = .corrupt
            verifiedEntitlement = nil
            storageFailure = nil
            storageRetry.reset()
            return nil
        } catch let error {
            recordStorageFailure(error)
            return error
        }
    }

    /// Mutating operations must know the stored state before they change it.
    private func loadForMutation() throws {
        if let error = loadIfNeeded() {
            throw LicensingError.storage(error)
        }
        if activation == .corrupt {
            throw LicensingError.storage(.corruptRecord)
        }
    }

    private func ensureIdentity() throws -> InstallationIdentity {
        if let identity {
            return identity
        }
        let identity = InstallationIdentity(installationID: UUID())
        do {
            try store.saveInstallationIdentity(identity)
        } catch let error {
            throw LicensingError.storage(error)
        }
        self.identity = identity
        return identity
    }

    /// Applies `state` in memory and writes it. A failed write keeps the in-memory state, reports
    /// the failure, and retries on the storage schedule; it does not change processing authority.
    private func persist(_ state: ActivationState) {
        activation = .state(state)
        do {
            try store.saveActivationState(state)
            trustedTime.markPersisted()
            storageFailure = nil
            persistencePending = false
            clearPending = false
            storageRetry.reset()
        } catch let error {
            persistencePending = true
            recordStorageFailure(error)
        }
    }

    /// Retires the activation in memory and removes the record. A failed deletion is retried and
    /// never brings the authority back.
    private func clearActivation() {
        activation = .none
        verifiedEntitlement = nil
        trustedTime = TrustedTimeState(persistedTrustedTime: nil, wallClock: wallClock(), now: clock.now())
        persistencePending = false
        resetRefreshFailures()
        do {
            try store.clearActivationState()
            storageFailure = nil
            clearPending = false
            storageRetry.reset()
        } catch let error {
            clearPending = true
            recordStorageFailure(error)
        }
    }

    private func recordStorageFailure(_ error: LicenseCredentialStoreError) {
        storageFailure = error
        storageRetry.recordFailure(
            now: clock.now(),
            jitterMultiplier: retryJitterMultiplier
        )
    }

    private func persistTrustedTime(force: Bool) {
        guard case var .state(state) = activation,
              state.deactivationRequestedAt == nil else {
            return
        }
        let due = force ? trustedTime.hasUnpersistedAdvance : trustedTime.needsPersistence
        guard due || persistencePending else {
            return
        }
        state.highestTrustedTime = trustedTime.highestTrustedTime
        persist(state)
    }

    // MARK: Time

    /// Advances the floor from the wall clock and the monotonic anchor, detecting a rollback
    /// larger than the tolerance. A rollback requests a refresh; it never expires anything.
    private func observeTime() -> Int64 {
        let wall = wallClock()
        if detectsRollback(wallClock: wall),
           case var .state(state) = activation,
           state.deactivationRequestedAt == nil,
           state.clockAnomalyDetectedAt == nil {
            state.clockAnomalyDetectedAt = trustedTime.highestTrustedTime
            refreshRetry.reset()
            persist(state)
        }
        let effective = trustedTime.effectiveTime(wallClock: wall, now: clock.now())
        trustedTime.advance(to: effective)
        return effective
    }

    private func detectsRollback(wallClock wall: Int64) -> Bool {
        if case let .state(state) = activation,
           let baseline = state.wallClockAtLastVerification {
            let threshold = baseline.subtractingReportingOverflow(
                TrustedTimeState.rollbackToleranceSeconds
            )
            return wall < (threshold.overflow ? .min : threshold.partialValue)
        }
        return trustedTime.detectsRollback(wallClock: wall)
    }

    // MARK: Evaluation

    private func evaluate() -> Evaluation {
        let effectiveTime = observeTime()
        func simple(_ state: LicenseState) -> Evaluation {
            Evaluation(
                content: LicenseSnapshotContent(state: state, storageFailure: storageFailure),
                claims: nil,
                effectiveTime: effectiveTime
            )
        }
        switch activation {
        case .notLoaded:
            return simple(.storageUnavailable)
        case .none:
            return simple(.unlicensed)
        case .corrupt:
            return simple(.invalidEntitlement)
        case let .state(state) where state.deactivationRequestedAt != nil:
            return simple(.unlicensed)
        case let .state(state):
            return evaluate(state, effectiveTime: effectiveTime)
        }
    }

    private func evaluate(_ state: ActivationState, effectiveTime: Int64) -> Evaluation {
        let invalid = Evaluation(
            content: LicenseSnapshotContent(state: .invalidEntitlement, storageFailure: storageFailure),
            claims: nil,
            effectiveTime: effectiveTime
        )
        guard let identity else {
            return invalid
        }
        let verified: VerifiedEntitlement
        if let cached = verifiedEntitlement,
           cached.compactJWS == state.entitlement,
           cached.claims.revision == state.highestAcceptedRevision {
            verified = cached
        } else {
            guard let fresh = try? verifier.verify(
                state.entitlement,
                installationID: identity.installationID,
                highestAcceptedRevision: state.highestAcceptedRevision,
                effectiveTime: effectiveTime
            ) else {
                return invalid
            }
            verifiedEntitlement = fresh
            verified = fresh
        }
        let claims = verified.claims
        let refreshFailure = state.serviceRevokedAt != nil
            ? LicenseRefreshFailure.rejected(.activationRevoked)
            : lastRefreshFailure

        let licenseState: LicenseState
        switch claims.terms {
        case .perpetualV1:
            licenseState = .perpetual
        case let .monthly(terms):
            if state.serverDeniedAt != nil {
                licenseState = .monthlyExpired
            } else if effectiveTime >= terms.expiresAt {
                licenseState = .monthlyExpired
            } else if effectiveTime >= terms.recoveryUntil {
                licenseState = .monthlyGrace
            } else {
                let unverified = state.clockAnomalyDetectedAt != nil
                    || (refreshFailure != nil && effectiveTime >= terms.refreshAfter)
                if effectiveTime < terms.billingPeriodEnd {
                    licenseState = unverified ? .verificationNeeded : .monthlyActive
                } else {
                    licenseState = unverified ? .verificationNeeded : .monthlyRecovery
                }
            }
        }

        return Evaluation(
            content: LicenseSnapshotContent(
                state: licenseState,
                terms: claims.monthlyTerms,
                lastRefreshFailure: refreshFailure,
                storageFailure: storageFailure
            ),
            claims: claims,
            effectiveTime: effectiveTime
        )
    }

    // MARK: Publishing

    @discardableResult
    private func publish(_ content: LicenseSnapshotContent) -> LicenseSnapshot {
        if let lastPublished, lastPublished.content == content {
            return lastPublished
        }
        let snapshot = LicenseSnapshot(
            sequence: (lastPublished?.sequence ?? 0) + 1,
            content: content
        )
        lastPublished = snapshot
        handler?(snapshot)
        return snapshot
    }

    private func publishAndReschedule(_ evaluation: Evaluation? = nil) {
        let evaluation = evaluation ?? evaluate()
        publish(evaluation.content)
        reschedule(evaluation)
    }

    // MARK: Activation and refresh requests

    /// One idempotency key per logical activation. A timed-out request is retried once with the
    /// same key so a server that completed the first attempt replays its response.
    private func activateWithRetry(
        licenseKey: String,
        installationID: UUID,
        idempotencyKey: UUID
    ) async throws(LicenseServiceError) -> ActivationResponse {
        do {
            return try await service.activate(
                licenseKey: licenseKey,
                installationID: installationID,
                idempotencyKey: idempotencyKey
            )
        } catch LicenseServiceError.transport(.timedOut) {
            return try await service.activate(
                licenseKey: licenseKey,
                installationID: installationID,
                idempotencyKey: idempotencyKey
            )
        }
    }

    /// Sends the idempotent deactivation for a tombstoned record and clears it once the server
    /// has no registration left for the token.
    private func completeDeactivation(_ state: ActivationState) async throws {
        let generation = operationGeneration
        let token = state.activationToken
        do {
            try await service.deactivateCurrent(activationToken: token)
        } catch let error {
            switch error {
            case .service(.invalidCredentials, _), .service(.activationRevoked, _):
                break
            case .cancelled:
                throw LicensingError.service(error)
            default:
                if generation == operationGeneration {
                    let retryAfterSeconds: Int? = switch error {
                    case let .service(_, retryAfterSeconds): retryAfterSeconds
                    default: nil
                    }
                    refreshRetry.recordFailure(
                        now: clock.now(),
                        jitterMultiplier: retryJitterMultiplier,
                        atLeast: retryAfterSeconds.map { .seconds($0) }
                    )
                    publishAndReschedule()
                }
                throw LicensingError.service(error)
            }
        }
        guard generation == operationGeneration,
              case let .state(current) = activation,
              current.activationToken == token else {
            return
        }
        clearActivation()
        publishAndReschedule()
        if let storageFailure {
            throw LicensingError.storage(storageFailure)
        }
    }

    private func performRefresh() async {
        // Cleared here rather than in `refreshNow` so the marker drops in the same actor turn
        // that publishes the result; a caller can never join a refresh that already finished.
        defer {
            inFlightRefresh = nil
            if !isShutdown {
                publishAndReschedule()
            }
        }
        // Perpetual entitlements never refresh; there is no schedule to keep and nothing a
        // refresh could grant that the signed entitlement does not already carry.
        guard case let .state(state) = activation,
              state.deactivationRequestedAt == nil,
              state.serviceRevokedAt == nil,
              evaluate().claims?.plan == .monthly,
              let identity else {
            return
        }
        let generation = operationGeneration
        let token = state.activationToken
        let result: Result<String, LicenseServiceError>
        do {
            result = .success(try await service.refresh(
                activationToken: token,
                installationID: identity.installationID
            ))
        } catch let error {
            result = .failure(error)
        }
        // Anything that changed the activation while the request was in flight wins. The schedule
        // is still rebuilt so a failed exclusive operation cannot leave the controller idle.
        guard generation == operationGeneration else {
            return
        }
        let now = clock.now()
        let effectiveTime = observeTime()
        guard case var .state(current) = activation,
              current.activationToken == token,
              current.deactivationRequestedAt == nil else {
            return
        }

        switch result {
        case let .success(jws):
            do {
                let verified = try verifier.verify(
                    jws,
                    installationID: identity.installationID,
                    highestAcceptedRevision: current.highestAcceptedRevision,
                    effectiveTime: effectiveTime
                )
                let verifiedWallClock = wallClock()
                trustedTime.rebase(
                    issuedAt: verified.claims.issuedAt,
                    wallClock: verifiedWallClock,
                    at: now
                )
                current.entitlement = jws
                current.highestAcceptedRevision = verified.claims.revision
                current.highestTrustedTime = trustedTime.highestTrustedTime
                current.wallClockAtLastVerification = verifiedWallClock
                current.clockAnomalyDetectedAt = nil
                current.serverDeniedAt = nil
                verifiedEntitlement = verified
                resetRefreshFailures()
                if let terms = verified.claims.monthlyTerms, terms.refreshAfter <= effectiveTime {
                    // The server handed back a schedule that is already due. Retry at the cap
                    // rather than immediately.
                    refreshRetry.holdAtCap(
                        now: now,
                        jitterMultiplier: retryJitterMultiplier
                    )
                }
                persist(current)
            } catch let error as EntitlementVerificationError {
                recordRefreshFailure(.invalidEntitlementReceived(error), retryAfterSeconds: nil)
            } catch {
                recordRefreshFailure(.serviceUnavailable, retryAfterSeconds: nil)
            }
        case .failure(.cancelled):
            return
        case .failure(.service(.licenseNotEligible, _)):
            current.serverDeniedAt = effectiveTime
            current.highestTrustedTime = trustedTime.highestTrustedTime
            lastRefreshFailure = nil
            refreshRetry.holdAtCap(
                now: now,
                jitterMultiplier: retryJitterMultiplier
            )
            persist(current)
        case .failure(.service(.activationRevoked, _)),
             .failure(.service(.invalidCredentials, _)):
            // Service access is gone, but the signed entitlement keeps its offline authority
            // until `exp`. No further refresh is possible with this token.
            current.serviceRevokedAt = effectiveTime
            current.highestTrustedTime = trustedTime.highestTrustedTime
            current.clockAnomalyDetectedAt = nil
            resetRefreshFailures()
            persist(current)
        case .failure(.service(.rateLimited, let retryAfterSeconds)):
            recordRefreshFailure(.rateLimited, retryAfterSeconds: retryAfterSeconds)
        case .failure(.service(.temporarilyUnavailable, let retryAfterSeconds)):
            recordRefreshFailure(.serviceUnavailable, retryAfterSeconds: retryAfterSeconds)
        case .failure(.service(let code, let retryAfterSeconds)):
            recordRefreshFailure(.rejected(code), retryAfterSeconds: retryAfterSeconds)
        case .failure(.transport(.offline)):
            recordRefreshFailure(.offline, retryAfterSeconds: nil)
        case .failure(.transport(.timedOut)):
            recordRefreshFailure(.timedOut, retryAfterSeconds: nil)
        case .failure(.transport(.other)), .failure(.malformedResponse),
             .failure(.unexpectedStatus), .failure(.redirected), .failure(.invalidLicenseKey):
            recordRefreshFailure(.serviceUnavailable, retryAfterSeconds: nil)
        }
    }

    private func recordRefreshFailure(_ failure: LicenseRefreshFailure, retryAfterSeconds: Int?) {
        lastRefreshFailure = failure
        refreshRetry.recordFailure(
            now: clock.now(),
            jitterMultiplier: retryJitterMultiplier,
            atLeast: retryAfterSeconds.map { .seconds($0) }
        )
    }

    private func resetRefreshFailures() {
        lastRefreshFailure = nil
        refreshRetry.reset()
    }

    private func beginExclusiveOperation() throws {
        guard !exclusiveOperationInProgress else {
            throw LicensingError.operationInProgress
        }
        exclusiveOperationInProgress = true
        operationGeneration &+= 1
    }

    /// Runs on every exit from an exclusive operation, including failures, so the schedule is
    /// rebuilt from whatever state the operation left behind.
    private func endExclusiveOperation() {
        exclusiveOperationInProgress = false
        publishAndReschedule()
    }

    // MARK: Scheduling

    private func refreshIsDue(_ evaluation: Evaluation, now: Duration) -> Bool {
        guard !exclusiveOperationInProgress,
              inFlightRefresh == nil,
              case let .state(state) = activation,
              state.deactivationRequestedAt == nil,
              state.serviceRevokedAt == nil,
              let terms = evaluation.claims?.monthlyTerms else {
            return false
        }
        if state.clockAnomalyDetectedAt != nil { return refreshRetry.isDue(now: now) }
        guard evaluation.effectiveTime >= terms.refreshAfter else {
            return false
        }
        return refreshRetry.isDue(now: now)
    }

    /// The earliest deadline that still needs work. Boundaries already in the past are never
    /// candidates, so an expired boundary or a rejected refresh cannot loop; work that is already
    /// overdue (a refresh, a checkpoint, a pending deactivation) is scheduled immediately.
    private func nextDeadline(_ evaluation: Evaluation) -> Duration? {
        let now = clock.now()
        var candidates: [Duration] = []

        func addProtocolTime(_ time: Int64) {
            guard time > evaluation.effectiveTime else { return }
            let delta = time.subtractingReportingOverflow(evaluation.effectiveTime)
            guard !delta.overflow else { return }
            candidates.append(now + .seconds(delta.partialValue))
        }

        if activation == .notLoaded || persistencePending || clearPending {
            candidates.append(storageRetry.deadline ?? now)
        }
        guard case let .state(state) = activation else {
            return candidates.min()
        }
        if state.deactivationRequestedAt != nil {
            if !exclusiveOperationInProgress {
                candidates.append(refreshRetry.deadline ?? now)
            }
            return candidates.min()
        }
        guard let terms = evaluation.claims?.monthlyTerms else {
            return candidates.min()
        }
        if refreshIsDue(evaluation, now: now) {
            return now
        }
        if state.serviceRevokedAt == nil {
            if let deadline = refreshRetry.deadline, deadline > now {
                candidates.append(deadline)
            } else {
                addProtocolTime(terms.refreshAfter)
            }
        }
        addProtocolTime(terms.billingPeriodEnd)
        addProtocolTime(terms.recoveryUntil)
        addProtocolTime(terms.expiresAt)
        if trustedTime.needsPersistence, !persistencePending {
            return now
        }
        let persistenceTime = trustedTime.lastPersistedTrustedTime.addingReportingOverflow(
            TrustedTimeState.persistenceIntervalSeconds
        )
        if !persistenceTime.overflow {
            addProtocolTime(persistenceTime.partialValue)
        }
        return candidates.min()
    }

    private func reschedule(_ evaluation: Evaluation) {
        schedulerGeneration &+= 1
        scheduler?.cancel()
        scheduler = nil
        guard !isShutdown, let deadline = nextDeadline(evaluation) else {
            return
        }
        let clock = clock
        let generation = schedulerGeneration
        scheduler = Task { [weak self] in
            do {
                try await clock.sleep(until: deadline)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else {
                return
            }
            await self.schedulerDidFire(generation: generation)
        }
    }

    private func schedulerDidFire(generation: UInt64) async {
        guard generation == schedulerGeneration else {
            return
        }
        scheduler = nil
        loadIfNeeded()
        if clearPending, storageRetry.isDue(now: clock.now()) {
            clearActivation()
        }
        if persistencePending,
           storageRetry.isDue(now: clock.now()),
           case let .state(state) = activation,
           state.deactivationRequestedAt != nil {
            persist(state)
        }
        if case let .state(state) = activation, state.deactivationRequestedAt != nil {
            if refreshRetry.isDue(now: clock.now()), !exclusiveOperationInProgress {
                try? await completeDeactivation(state)
            } else {
                publishAndReschedule()
            }
            return
        }
        let evaluation = evaluate()
        publish(evaluation.content)
        if storageRetry.isDue(now: clock.now()) {
            persistTrustedTime(force: false)
        }
        if refreshIsDue(evaluation, now: clock.now()) {
            let refresh = Task { await self.performRefresh() }
            inFlightRefresh = refresh
            reschedule(evaluation)
            await refresh.value
        } else {
            reschedule(evaluation)
        }
    }
}
