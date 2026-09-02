import Foundation

public enum LicensingError: Error, Equatable, Sendable {
    case operationInProgress
    case storage(LicenseCredentialStoreError)
    case service(LicenseServiceError)
    case entitlement(EntitlementVerificationError)
}

/// The single owner of licensing state in the main app. It loads and persists the Keychain
/// records, verifies the cached entitlement, tracks trusted time, refreshes on the signed
/// schedule, and publishes immutable snapshots. It never touches audio.
public actor LicensingController {
    public static let defaultRetryBackoff: [Duration] = [
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

        mutating func recordFailure(now: Duration, backoff: [Duration], atLeast minimum: Duration? = nil) {
            failures += 1
            var delay = backoff[min(failures, backoff.count) - 1]
            if let minimum {
                delay = max(delay, minimum)
            }
            deadline = now + delay
        }

        mutating func holdAtCap(now: Duration, backoff: [Duration]) {
            failures = backoff.count
            deadline = now + backoff[backoff.count - 1]
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
    private let retryBackoff: [Duration]

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
    private var immediateRefreshRequested = false
    /// The wall clock at the last authenticated refresh. After that point a rollback is only a
    /// further move of the wall clock, not its standing distance from the trusted floor.
    private var wallClockAtLastVerification: Int64?

    private var operationGeneration: UInt64 = 0
    private var exclusiveOperationInProgress = false
    private var inFlightRefresh: Task<Void, Never>?
    private var scheduler: Task<Void, Never>?
    private var handler: (@Sendable (LicenseSnapshot) -> Void)?
    private var lastPublished: LicenseSnapshot?

    public init(
        store: any LicenseCredentialStore,
        service: any LicenseServicing,
        verifier: EntitlementVerifier,
        wallClock: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) },
        clock: any LicensingClock = ContinuousLicensingClock(),
        retryBackoff: [Duration] = LicensingController.defaultRetryBackoff
    ) {
        precondition(!retryBackoff.isEmpty, "Retry backoff needs at least one interval")
        self.store = store
        self.service = service
        self.verifier = verifier
        self.wallClock = wallClock
        self.clock = clock
        self.retryBackoff = retryBackoff
        trustedTime = TrustedTimeState(persistedTrustedTime: nil, wallClock: wallClock(), now: clock.now())
    }

    deinit {
        scheduler?.cancel()
        inFlightRefresh?.cancel()
    }

    // MARK: Public surface

    /// Returns the current snapshot and delivers every later change through `handler`. The
    /// handler runs on the actor; callers hop to their own isolation.
    public func subscribe(
        _ handler: @escaping @Sendable (LicenseSnapshot) -> Void
    ) -> LicenseSnapshot {
        self.handler = handler
        return currentSnapshot()
    }

    public func currentSnapshot() -> LicenseSnapshot {
        loadIfNeeded()
        let evaluation = evaluate()
        if lastPublished == nil {
            lastPublished = LicenseSnapshot(sequence: 1, content: evaluation.content)
        } else {
            publish(evaluation.content)
        }
        reschedule(evaluation)
        return lastPublished ?? LicenseSnapshot(sequence: 1, content: evaluation.content)
    }

    public func activate(licenseKey: String) async throws {
        try beginExclusiveOperation()
        defer { endExclusiveOperation() }
        try loadForMutation()
        let identity = try ensureIdentity()
        let idempotencyKey = UUID()

        let response: ActivationResponse
        do {
            response = try await activateWithRetry(
                licenseKey: licenseKey,
                installationID: identity.installationID,
                idempotencyKey: idempotencyKey
            )
        } catch let error as LicenseServiceError {
            throw LicensingError.service(error)
        } catch is CancellationError {
            throw LicensingError.service(.cancelled)
        } catch {
            throw LicensingError.service(.transport(.other))
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
            throw LicensingError.entitlement(error)
        }
        fresh.anchor(issuedAt: verified.claims.issuedAt, at: now)

        let state = ActivationState(
            activationToken: response.activationToken,
            entitlement: response.entitlement,
            highestAcceptedRevision: verified.claims.revision,
            highestTrustedTime: fresh.highestTrustedTime
        )
        do {
            try store.saveActivationState(state)
        } catch let error as LicenseCredentialStoreError {
            throw LicensingError.storage(error)
        }
        fresh.markPersisted()
        trustedTime = fresh
        wallClockAtLastVerification = wallClock()
        activation = .state(state)
        storageFailure = nil
        persistencePending = false
        clearPending = false
        storageRetry.reset()
        resetRefreshFailures()
        publishAndReschedule()
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
            } catch let error as LicenseCredentialStoreError {
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
        if let inFlightRefresh {
            await inFlightRefresh.value
            return
        }
        let task = Task { await self.performRefresh() }
        inFlightRefresh = task
        await task.value
    }

    /// Persists the trusted-time floor if it advanced since the last write.
    public func checkpoint() {
        _ = observeTime()
        persistTrustedTime(force: true)
    }

    public func shutdown() {
        scheduler?.cancel()
        scheduler = nil
        inFlightRefresh?.cancel()
    }

    // MARK: Loading and persistence

    private func loadIfNeeded() {
        guard activation == .notLoaded else {
            return
        }
        do {
            identity = try store.loadInstallationIdentity()
            if let state = try store.loadActivationState() {
                activation = .state(state)
                trustedTime = TrustedTimeState(
                    persistedTrustedTime: state.highestTrustedTime,
                    wallClock: wallClock(),
                    now: clock.now()
                )
            } else {
                activation = .none
            }
            storageFailure = nil
            storageRetry.reset()
        } catch LicenseCredentialStoreError.corruptRecord {
            activation = .corrupt
            storageFailure = nil
            storageRetry.reset()
        } catch {
            recordStorageFailure(error)
        }
    }

    /// Mutating operations must know the stored state before they change it.
    private func loadForMutation() throws {
        loadIfNeeded()
        if activation == .notLoaded {
            throw LicensingError.storage(storageFailure ?? .keychain(errSecInternalError))
        }
    }

    private func ensureIdentity() throws -> InstallationIdentity {
        if let identity {
            return identity
        }
        let identity = InstallationIdentity(installationID: UUID())
        do {
            try store.saveInstallationIdentity(identity)
        } catch let error as LicenseCredentialStoreError {
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
            storageRetry.reset()
        } catch {
            persistencePending = true
            recordStorageFailure(error)
        }
    }

    /// Retires the activation in memory and removes the record. A failed deletion is retried and
    /// never brings the authority back.
    private func clearActivation() {
        activation = .none
        trustedTime = TrustedTimeState(persistedTrustedTime: nil, wallClock: wallClock(), now: clock.now())
        wallClockAtLastVerification = nil
        persistencePending = false
        resetRefreshFailures()
        do {
            try store.clearActivationState()
            storageFailure = nil
            clearPending = false
            storageRetry.reset()
        } catch {
            clearPending = true
            recordStorageFailure(error)
        }
    }

    private func recordStorageFailure(_ error: any Error) {
        storageFailure = (error as? LicenseCredentialStoreError) ?? .keychain(errSecInternalError)
        storageRetry.recordFailure(now: clock.now(), backoff: retryBackoff)
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
            immediateRefreshRequested = true
            persist(state)
        }
        let effective = trustedTime.effectiveTime(wallClock: wall, now: clock.now())
        trustedTime.advance(to: effective)
        return effective
    }

    private func detectsRollback(wallClock wall: Int64) -> Bool {
        if let wallClockAtLastVerification {
            return wall < wallClockAtLastVerification - TrustedTimeState.rollbackToleranceSeconds
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
        guard let identity,
              let verified = try? verifier.verify(
                  state.entitlement,
                  installationID: identity.installationID,
                  highestAcceptedRevision: state.highestAcceptedRevision,
                  effectiveTime: effectiveTime
              ) else {
            return invalid
        }
        let claims = verified.claims
        let evaluation = verified.evaluate(atUnixTime: effectiveTime)
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
            } else {
                let unverified = state.clockAnomalyDetectedAt != nil
                    || (refreshFailure != nil && effectiveTime >= terms.refreshAfter)
                switch evaluation.processingState {
                case .active:
                    licenseState = unverified ? .verificationNeeded : .monthlyActive
                case .paymentRecovery:
                    licenseState = unverified ? .verificationNeeded : .monthlyRecovery
                case .grace:
                    licenseState = .monthlyGrace
                case .expired:
                    licenseState = .monthlyExpired
                case .perpetual:
                    licenseState = .perpetual
                }
            }
        }

        let updateAccess: EntitlementUpdateAccess
        if state.serviceRevokedAt != nil {
            updateAccess = .none
        } else if licenseState == .monthlyExpired {
            updateAccess = claims.securityUpdatesAfterExpiry ? .securityOnly : .none
        } else {
            updateAccess = evaluation.updateAccess
        }

        return Evaluation(
            content: LicenseSnapshotContent(
                state: licenseState,
                plan: claims.plan,
                billingState: claims.monthlyTerms?.billingState,
                billingPeriodEnd: claims.monthlyTerms?.billingPeriodEnd,
                recoveryUntil: claims.monthlyTerms?.recoveryUntil,
                expiresAt: claims.monthlyTerms?.expiresAt,
                updateAccess: updateAccess,
                lastRefreshFailure: refreshFailure,
                storageFailure: storageFailure
            ),
            claims: claims,
            effectiveTime: effectiveTime
        )
    }

    // MARK: Publishing

    private func publish(_ content: LicenseSnapshotContent) {
        if let lastPublished, lastPublished.content == content {
            return
        }
        let snapshot = LicenseSnapshot(
            sequence: (lastPublished?.sequence ?? 0) + 1,
            content: content
        )
        lastPublished = snapshot
        handler?(snapshot)
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
    ) async throws -> ActivationResponse {
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
        } catch let error as LicenseServiceError {
            switch error {
            case .service(.invalidCredentials, _, _, _), .service(.activationRevoked, _, _, _):
                break
            case .cancelled:
                throw LicensingError.service(error)
            default:
                if generation == operationGeneration {
                    refreshRetry.recordFailure(now: clock.now(), backoff: retryBackoff)
                    publishAndReschedule()
                }
                throw LicensingError.service(error)
            }
        } catch is CancellationError {
            throw LicensingError.service(.cancelled)
        } catch {
            if generation == operationGeneration {
                refreshRetry.recordFailure(now: clock.now(), backoff: retryBackoff)
                publishAndReschedule()
            }
            throw LicensingError.service(.transport(.other))
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
        defer { inFlightRefresh = nil }
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
        } catch let error as LicenseServiceError {
            result = .failure(error)
        } catch is CancellationError {
            result = .failure(.cancelled)
        } catch {
            result = .failure(.transport(.other))
        }
        // Anything that changed the activation while the request was in flight wins. The schedule
        // is still rebuilt so a failed exclusive operation cannot leave the controller idle.
        guard generation == operationGeneration, case .state = activation else {
            if case .state = activation {
                publishAndReschedule()
            }
            return
        }
        let now = clock.now()
        let effectiveTime = observeTime()
        guard case var .state(current) = activation,
              current.activationToken == token,
              current.deactivationRequestedAt == nil else {
            publishAndReschedule()
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
                trustedTime.anchor(issuedAt: verified.claims.issuedAt, at: now)
                wallClockAtLastVerification = wallClock()
                current.entitlement = jws
                current.highestAcceptedRevision = verified.claims.revision
                current.highestTrustedTime = trustedTime.highestTrustedTime
                current.clockAnomalyDetectedAt = nil
                current.serverDeniedAt = nil
                resetRefreshFailures()
                if let terms = verified.claims.monthlyTerms, terms.refreshAfter <= effectiveTime {
                    // The server handed back a schedule that is already due. Retry at the cap
                    // rather than immediately.
                    refreshRetry.holdAtCap(now: now, backoff: retryBackoff)
                }
                persist(current)
            } catch let error as EntitlementVerificationError {
                recordRefreshFailure(.invalidEntitlementReceived(error), retryAfterSeconds: nil)
            } catch {
                recordRefreshFailure(.serviceUnavailable, retryAfterSeconds: nil)
            }
        case .failure(.cancelled):
            return
        case .failure(.service(.licenseNotEligible, _, _, _)):
            current.serverDeniedAt = effectiveTime
            current.highestTrustedTime = trustedTime.highestTrustedTime
            lastRefreshFailure = nil
            immediateRefreshRequested = false
            refreshRetry.holdAtCap(now: now, backoff: retryBackoff)
            persist(current)
        case .failure(.service(.activationRevoked, _, _, _)),
             .failure(.service(.invalidCredentials, _, _, _)):
            // Service access is gone, but the signed entitlement keeps its offline authority
            // until `exp`. No further refresh is possible with this token.
            current.serviceRevokedAt = effectiveTime
            current.highestTrustedTime = trustedTime.highestTrustedTime
            current.clockAnomalyDetectedAt = nil
            resetRefreshFailures()
            persist(current)
        case .failure(.service(.rateLimited, _, _, let retryAfterSeconds)):
            recordRefreshFailure(.rateLimited, retryAfterSeconds: retryAfterSeconds)
        case .failure(.service(let code, _, _, let retryAfterSeconds)):
            recordRefreshFailure(.rejected(code), retryAfterSeconds: retryAfterSeconds)
        case .failure(.transport(.offline)):
            recordRefreshFailure(.offline, retryAfterSeconds: nil)
        case .failure(.transport(.timedOut)):
            recordRefreshFailure(.timedOut, retryAfterSeconds: nil)
        case .failure(.transport(.other)), .failure(.malformedResponse),
             .failure(.unexpectedStatus), .failure(.redirected), .failure(.invalidLicenseKey):
            recordRefreshFailure(.serviceUnavailable, retryAfterSeconds: nil)
        }
        publishAndReschedule()
    }

    private func recordRefreshFailure(_ failure: LicenseRefreshFailure, retryAfterSeconds: Int?) {
        lastRefreshFailure = failure
        immediateRefreshRequested = false
        refreshRetry.recordFailure(
            now: clock.now(),
            backoff: retryBackoff,
            atLeast: retryAfterSeconds.map { .seconds($0) }
        )
    }

    private func resetRefreshFailures() {
        lastRefreshFailure = nil
        immediateRefreshRequested = false
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
              case let .state(state) = activation,
              state.deactivationRequestedAt == nil,
              state.serviceRevokedAt == nil,
              let terms = evaluation.claims?.monthlyTerms else {
            return false
        }
        if immediateRefreshRequested {
            return true
        }
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
            candidates.append(now + .seconds(time - evaluation.effectiveTime))
        }

        if activation == .notLoaded || persistencePending || clearPending {
            candidates.append(storageRetry.deadline ?? now)
        }
        guard case let .state(state) = activation else {
            return candidates.min()
        }
        if state.deactivationRequestedAt != nil {
            candidates.append(refreshRetry.deadline ?? now)
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
        addProtocolTime(trustedTime.lastPersistedTrustedTime + TrustedTimeState.persistenceIntervalSeconds)
        return candidates.min()
    }

    private func reschedule(_ evaluation: Evaluation) {
        scheduler?.cancel()
        scheduler = nil
        guard let deadline = nextDeadline(evaluation) else {
            return
        }
        let clock = clock
        scheduler = Task.detached { [weak self] in
            do {
                try await clock.sleep(until: deadline)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else {
                return
            }
            await self.schedulerDidFire()
        }
    }

    private func schedulerDidFire() async {
        scheduler = nil
        loadIfNeeded()
        if clearPending, storageRetry.isDue(now: clock.now()) {
            clearActivation()
        }
        if case let .state(state) = activation, state.deactivationRequestedAt != nil {
            if refreshRetry.isDue(now: clock.now()), !exclusiveOperationInProgress {
                try? await completeDeactivation(state)
            } else {
                publishAndReschedule()
            }
            return
        }
        _ = observeTime()
        if storageRetry.isDue(now: clock.now()) {
            persistTrustedTime(force: false)
        }
        let evaluation = evaluate()
        if refreshIsDue(evaluation, now: clock.now()) {
            await refreshNow()
        } else {
            publishAndReschedule(evaluation)
        }
    }
}
