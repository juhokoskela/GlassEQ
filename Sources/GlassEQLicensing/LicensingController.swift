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
    private var persistencePending = false
    private var lastRefreshFailure: LicenseRefreshFailure?
    private var consecutiveFailures = 0
    private var retryDeadline: Duration?
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
        loadIfNeeded()
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

        let now = clock.now()
        let effectiveTime = observeTime()
        let verified: VerifiedEntitlement
        do {
            verified = try verifier.verify(
                response.entitlement,
                installationID: identity.installationID,
                highestAcceptedRevision: nil,
                effectiveTime: effectiveTime
            )
        } catch let error as EntitlementVerificationError {
            throw LicensingError.entitlement(error)
        }
        trustedTime.anchor(issuedAt: verified.claims.issuedAt, at: now)
        wallClockAtLastVerification = wallClock()

        let state = ActivationState(
            activationToken: response.activationToken,
            entitlement: response.entitlement,
            highestAcceptedRevision: verified.claims.revision,
            highestTrustedTime: trustedTime.highestTrustedTime
        )
        do {
            try store.saveActivationState(state)
        } catch let error as LicenseCredentialStoreError {
            throw LicensingError.storage(error)
        }
        trustedTime.markPersisted()
        activation = .state(state)
        storageFailure = nil
        persistencePending = false
        resetRefreshFailures()
        publishAndReschedule()
    }

    public func deactivateCurrent() async throws {
        try beginExclusiveOperation()
        defer { endExclusiveOperation() }
        loadIfNeeded()
        guard case let .state(state) = activation else {
            return
        }
        do {
            try await service.deactivateCurrent(activationToken: state.activationToken)
        } catch let error as LicenseServiceError {
            switch error {
            case .service(.invalidCredentials, _, _, _), .service(.activationRevoked, _, _, _):
                break
            default:
                throw LicensingError.service(error)
            }
        } catch is CancellationError {
            throw LicensingError.service(.cancelled)
        } catch {
            throw LicensingError.service(.transport(.other))
        }
        inFlightRefresh?.cancel()
        do {
            try store.clearActivationState()
        } catch let error as LicenseCredentialStoreError {
            throw LicensingError.storage(error)
        }
        activation = .none
        trustedTime = TrustedTimeState(persistedTrustedTime: nil, wallClock: wallClock(), now: clock.now())
        wallClockAtLastVerification = nil
        storageFailure = nil
        persistencePending = false
        resetRefreshFailures()
        publishAndReschedule()
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
        if inFlightRefresh == task {
            inFlightRefresh = nil
        }
    }

    /// Persists the trusted-time floor if it advanced since the last write.
    public func checkpoint() {
        guard case var .state(state) = activation else {
            return
        }
        _ = observeTime()
        guard trustedTime.hasUnpersistedAdvance || persistencePending else {
            return
        }
        state.highestTrustedTime = trustedTime.highestTrustedTime
        persist(state)
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
        } catch LicenseCredentialStoreError.corruptRecord {
            activation = .corrupt
            storageFailure = nil
        } catch let error as LicenseCredentialStoreError {
            storageFailure = error
            scheduleRetry()
        } catch {
            storageFailure = .keychain(errSecInternalError)
            scheduleRetry()
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
    /// the failure, and retries on the schedule; it does not revoke processing.
    private func persist(_ state: ActivationState) {
        activation = .state(state)
        do {
            try store.saveActivationState(state)
            trustedTime.markPersisted()
            storageFailure = nil
            persistencePending = false
        } catch let error as LicenseCredentialStoreError {
            storageFailure = error
            persistencePending = true
            scheduleRetry()
        } catch {
            storageFailure = .keychain(errSecInternalError)
            persistencePending = true
            scheduleRetry()
        }
    }

    // MARK: Time

    /// Advances the floor from the wall clock and the monotonic anchor, detecting a rollback
    /// larger than the tolerance. A rollback requests a refresh; it never expires anything.
    private func observeTime() -> Int64 {
        let wall = wallClock()
        if detectsRollback(wallClock: wall),
           case var .state(state) = activation,
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
        switch activation {
        case .notLoaded:
            return Evaluation(
                content: LicenseSnapshotContent(state: .storageUnavailable, storageFailure: storageFailure),
                claims: nil,
                effectiveTime: effectiveTime
            )
        case .none:
            return Evaluation(
                content: LicenseSnapshotContent(state: .unlicensed, storageFailure: storageFailure),
                claims: nil,
                effectiveTime: effectiveTime
            )
        case .corrupt:
            return Evaluation(
                content: LicenseSnapshotContent(state: .invalidEntitlement, storageFailure: storageFailure),
                claims: nil,
                effectiveTime: effectiveTime
            )
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

        let licenseState: LicenseState
        switch (claims.plan, evaluation.processingState) {
        case (.perpetualV1, _), (_, .perpetual):
            licenseState = .perpetual
        case (.monthly, _) where state.serverDeniedAt != nil:
            licenseState = .monthlyExpired
        case (.monthly, .active):
            licenseState = needsVerification(claims, effectiveTime: effectiveTime, state: state)
                ? .verificationNeeded : .monthlyActive
        case (.monthly, .paymentRecovery):
            licenseState = needsVerification(claims, effectiveTime: effectiveTime, state: state)
                ? .verificationNeeded : .monthlyRecovery
        case (.monthly, .grace):
            licenseState = .monthlyGrace
        case (.monthly, .expired):
            licenseState = .monthlyExpired
        }

        let updateAccess: EntitlementUpdateAccess
        if licenseState == .monthlyExpired {
            updateAccess = claims.securityUpdatesAfterExpiry ? .securityOnly : .none
        } else {
            updateAccess = evaluation.updateAccess
        }

        return Evaluation(
            content: LicenseSnapshotContent(
                state: licenseState,
                plan: claims.plan,
                billingState: claims.billingState,
                billingPeriodEnd: claims.billingPeriodEnd,
                recoveryUntil: claims.recoveryUntil,
                expiresAt: claims.expiresAt,
                updateAccess: updateAccess,
                lastRefreshFailure: lastRefreshFailure,
                storageFailure: storageFailure
            ),
            claims: claims,
            effectiveTime: effectiveTime
        )
    }

    private func needsVerification(
        _ claims: EntitlementClaims,
        effectiveTime: Int64,
        state: ActivationState
    ) -> Bool {
        if state.clockAnomalyDetectedAt != nil {
            return true
        }
        guard let refreshAfter = claims.refreshAfter else {
            return false
        }
        return lastRefreshFailure != nil && effectiveTime >= refreshAfter
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

    private func publishAndReschedule() {
        let evaluation = evaluate()
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

    private func performRefresh() async {
        guard case let .state(state) = activation, let identity else {
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
        // Anything that changed the activation while the request was in flight wins.
        guard generation == operationGeneration,
              case .state = activation else {
            return
        }
        let now = clock.now()
        let effectiveTime = observeTime()
        guard case var .state(current) = activation, current.activationToken == token else {
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
                if let refreshAfter = verified.claims.refreshAfter, refreshAfter <= effectiveTime {
                    // The server handed back a schedule that is already due. Retry at the cap
                    // rather than immediately.
                    retryDeadline = now + retryBackoff[retryBackoff.count - 1]
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
            consecutiveFailures = retryBackoff.count
            retryDeadline = now + retryBackoff[retryBackoff.count - 1]
            persist(current)
        case .failure(.service(.activationRevoked, _, _, _)),
             .failure(.service(.invalidCredentials, _, _, _)):
            do {
                try store.clearActivationState()
                storageFailure = nil
            } catch let error as LicenseCredentialStoreError {
                storageFailure = error
            } catch {
                storageFailure = .keychain(errSecInternalError)
            }
            activation = .none
            trustedTime = TrustedTimeState(persistedTrustedTime: nil, wallClock: wallClock(), now: now)
            wallClockAtLastVerification = nil
            resetRefreshFailures()
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
        consecutiveFailures += 1
        var delay = retryBackoff[min(consecutiveFailures, retryBackoff.count) - 1]
        if let retryAfterSeconds {
            delay = max(delay, .seconds(retryAfterSeconds))
        }
        retryDeadline = clock.now() + delay
    }

    private func resetRefreshFailures() {
        lastRefreshFailure = nil
        consecutiveFailures = 0
        retryDeadline = nil
        immediateRefreshRequested = false
    }

    private func scheduleRetry() {
        consecutiveFailures += 1
        retryDeadline = clock.now() + retryBackoff[min(consecutiveFailures, retryBackoff.count) - 1]
    }

    private func beginExclusiveOperation() throws {
        guard !exclusiveOperationInProgress else {
            throw LicensingError.operationInProgress
        }
        exclusiveOperationInProgress = true
        operationGeneration &+= 1
    }

    private func endExclusiveOperation() {
        exclusiveOperationInProgress = false
    }

    // MARK: Scheduling

    private func refreshIsDue(_ evaluation: Evaluation, now: Duration) -> Bool {
        guard case .state = activation, let claims = evaluation.claims, claims.plan == .monthly else {
            return false
        }
        if immediateRefreshRequested {
            return true
        }
        guard let refreshAfter = claims.refreshAfter, evaluation.effectiveTime >= refreshAfter else {
            return false
        }
        if let retryDeadline {
            return now >= retryDeadline
        }
        return true
    }

    /// The earliest strictly future deadline. Past boundaries are never candidates, so an expired
    /// boundary or a rejected refresh cannot produce an immediate retry loop.
    private func nextDeadline(_ evaluation: Evaluation) -> Duration? {
        let now = clock.now()
        var candidates: [Duration] = []

        func addProtocolTime(_ time: Int64?) {
            guard let time, time > evaluation.effectiveTime else { return }
            candidates.append(now + .seconds(time - evaluation.effectiveTime))
        }

        if let retryDeadline, retryDeadline > now {
            candidates.append(retryDeadline)
        }
        if case .state = activation, let claims = evaluation.claims, claims.plan == .monthly {
            if refreshIsDue(evaluation, now: now) {
                return now
            }
            if retryDeadline == nil {
                addProtocolTime(claims.refreshAfter)
            }
            addProtocolTime(claims.billingPeriodEnd)
            addProtocolTime(claims.recoveryUntil)
            addProtocolTime(claims.expiresAt)
            addProtocolTime(
                trustedTime.lastPersistedTrustedTime + TrustedTimeState.persistenceIntervalSeconds
            )
        }
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
        _ = observeTime()
        checkpointIfDue()
        let evaluation = evaluate()
        if refreshIsDue(evaluation, now: clock.now()) {
            await refreshNow()
        } else {
            publishAndReschedule()
        }
    }

    private func checkpointIfDue() {
        guard case var .state(state) = activation,
              trustedTime.needsPersistence || persistencePending else {
            return
        }
        state.highestTrustedTime = trustedTime.highestTrustedTime
        persist(state)
    }
}
