import Foundation
import Synchronization
@testable import GlassEQLicensing

final class InMemoryCredentialStore: LicenseCredentialStore {
    private struct State: Sendable {
        var identity: InstallationIdentity?
        var activation: ActivationState?
        var loadFailure: LicenseCredentialStoreError?
        var saveFailure: LicenseCredentialStoreError?
        var clearFailure: LicenseCredentialStoreError?
        var corruptActivation = false
        var saveActivationCount = 0
        var clearCount = 0
    }

    private let state: Mutex<State>

    init(identity: InstallationIdentity? = nil, activation: ActivationState? = nil) {
        state = Mutex(State(identity: identity, activation: activation))
    }

    var identity: InstallationIdentity? {
        get { state.withLock { $0.identity } }
        set { state.withLock { $0.identity = newValue } }
    }

    var activation: ActivationState? {
        get { state.withLock { $0.activation } }
        set { state.withLock { $0.activation = newValue } }
    }

    var loadFailure: LicenseCredentialStoreError? {
        get { state.withLock { $0.loadFailure } }
        set { state.withLock { $0.loadFailure = newValue } }
    }

    var saveFailure: LicenseCredentialStoreError? {
        get { state.withLock { $0.saveFailure } }
        set { state.withLock { $0.saveFailure = newValue } }
    }

    var clearFailure: LicenseCredentialStoreError? {
        get { state.withLock { $0.clearFailure } }
        set { state.withLock { $0.clearFailure = newValue } }
    }

    var corruptActivation: Bool {
        get { state.withLock { $0.corruptActivation } }
        set { state.withLock { $0.corruptActivation = newValue } }
    }

    var saveActivationCount: Int { state.withLock { $0.saveActivationCount } }
    var clearCount: Int { state.withLock { $0.clearCount } }

    func loadInstallationIdentity() throws(LicenseCredentialStoreError) -> InstallationIdentity? {
        let result = state.withLock { ($0.loadFailure, $0.identity) }
        if let failure = result.0 { throw failure }
        return result.1
    }

    func saveInstallationIdentity(_ identity: InstallationIdentity) throws(LicenseCredentialStoreError) {
        let failure = state.withLock { state -> LicenseCredentialStoreError? in
            guard state.saveFailure == nil else { return state.saveFailure }
            state.identity = identity
            return nil
        }
        if let failure { throw failure }
    }

    func loadActivationState() throws(LicenseCredentialStoreError) -> ActivationState? {
        let result = state.withLock { ($0.loadFailure, $0.corruptActivation, $0.activation) }
        if let failure = result.0 { throw failure }
        if result.1 { throw .corruptRecord }
        return result.2
    }

    func saveActivationState(_ activation: ActivationState) throws(LicenseCredentialStoreError) {
        let failure = state.withLock { state -> LicenseCredentialStoreError? in
            state.saveActivationCount += 1
            guard state.saveFailure == nil else { return state.saveFailure }
            state.activation = activation
            return nil
        }
        if let failure { throw failure }
    }

    func clearActivationState() throws(LicenseCredentialStoreError) {
        let failure = state.withLock { state -> LicenseCredentialStoreError? in
            state.clearCount += 1
            guard state.clearFailure == nil else { return state.clearFailure }
            state.activation = nil
            return nil
        }
        if let failure { throw failure }
    }
}

final class ScriptedLicenseService: LicenseServicing {
    enum Call: Equatable, Sendable {
        case activate(licenseKey: String, installationID: UUID, idempotencyKey: UUID)
        case refresh(activationToken: String, installationID: UUID)
        case deactivate(activationToken: String)
    }

    typealias ActivateHandler = @Sendable (String, UUID, UUID) async throws -> ActivationResponse
    typealias RefreshHandler = @Sendable (String, UUID) async throws -> String
    typealias DeactivateHandler = @Sendable (String) async throws -> Void

    private struct State: Sendable {
        var calls: [Call] = []
        var activate: ActivateHandler = { _, _, _ in throw LicenseServiceError.transport(.other) }
        var refresh: RefreshHandler = { _, _ in throw LicenseServiceError.transport(.other) }
        var deactivate: DeactivateHandler = { _ in throw LicenseServiceError.transport(.other) }
    }

    private let state = Mutex(State())

    var calls: [Call] { state.withLock { $0.calls } }
    var refreshCallCount: Int {
        calls.filter { if case .refresh = $0 { true } else { false } }.count
    }

    func onActivate(_ handler: @escaping ActivateHandler) {
        state.withLock { $0.activate = handler }
    }

    func onRefresh(_ handler: @escaping RefreshHandler) {
        state.withLock { $0.refresh = handler }
    }

    func onDeactivate(_ handler: @escaping DeactivateHandler) {
        state.withLock { $0.deactivate = handler }
    }

    func activate(licenseKey: String, installationID: UUID, idempotencyKey: UUID) async throws(LicenseServiceError) -> ActivationResponse {
        let handler = state.withLock {
            $0.calls.append(.activate(licenseKey: licenseKey, installationID: installationID, idempotencyKey: idempotencyKey))
            return $0.activate
        }
        do {
            return try await handler(licenseKey, installationID, idempotencyKey)
        } catch let error as LicenseServiceError {
            throw error
        } catch {
            throw .transport(.other)
        }
    }

    func refresh(activationToken: String, installationID: UUID) async throws(LicenseServiceError) -> String {
        let handler = state.withLock {
            $0.calls.append(.refresh(activationToken: activationToken, installationID: installationID))
            return $0.refresh
        }
        do {
            return try await handler(activationToken, installationID)
        } catch let error as LicenseServiceError {
            throw error
        } catch {
            throw .transport(.other)
        }
    }

    func deactivateCurrent(activationToken: String) async throws(LicenseServiceError) {
        let handler = state.withLock {
            $0.calls.append(.deactivate(activationToken: activationToken))
            return $0.deactivate
        }
        do {
            try await handler(activationToken)
        } catch let error as LicenseServiceError {
            throw error
        } catch {
            throw .transport(.other)
        }
    }
}

/// Suspends callers until opened. Used to hold a scripted request in flight.
final class AsyncGate: Sendable {
    private struct State: Sendable {
        var isOpen = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeNow = state.withLock {
                if $0.isOpen { return true }
                $0.waiters.append(continuation)
                return false
            }
            if resumeNow {
                continuation.resume()
            }
        }
    }

    func open() {
        let waiters = state.withLock { state in
            state.isOpen = true
            defer { state.waiters.removeAll() }
            return state.waiters
        }
        for waiter in waiters {
            waiter.resume()
        }
    }
}

final class TestWallClock: Sendable {
    private let value: Mutex<Int64>

    init(_ time: Int64) {
        value = Mutex(time)
    }

    var time: Int64 {
        get { value.withLock { $0 } }
        set { value.withLock { $0 = newValue } }
    }

    var read: @Sendable () -> Int64 {
        { [self] in time }
    }
}

/// A manually advanced monotonic clock whose sleepers resume when their deadline is reached.
final class TestLicensingClock: LicensingClock {
    private enum Registration {
        case waiting
        case due
        case cancelled
    }

    private struct Sleeper: Sendable {
        let deadline: Duration
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State: Sendable {
        var current: Duration = .zero
        var sleepers: [UUID: Sleeper] = [:]
        var cancelledBeforeRegistration: Set<UUID> = []
        var requestedDeadlines: [Duration] = []
    }

    private let state = Mutex(State())

    var requestedDeadlines: [Duration] { state.withLock { $0.requestedDeadlines } }
    var pendingDeadlines: [Duration] { state.withLock { $0.sleepers.values.map(\.deadline).sorted() } }

    func now() -> Duration {
        state.withLock { $0.current }
    }

    func sleep(until deadline: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let registration = state.withLock { state in
                    state.requestedDeadlines.append(deadline)
                    if state.cancelledBeforeRegistration.remove(id) != nil {
                        return Registration.cancelled
                    }
                    if state.current >= deadline {
                        return Registration.due
                    }
                    state.sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                    return Registration.waiting
                }
                switch registration {
                case .waiting:
                    break
                case .due:
                    continuation.resume()
                case .cancelled:
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            let sleeper = state.withLock { state -> Sleeper? in
                if let sleeper = state.sleepers.removeValue(forKey: id) {
                    return sleeper
                }
                state.cancelledBeforeRegistration.insert(id)
                return nil
            }
            if let sleeper {
                sleeper.continuation.resume(throwing: CancellationError())
            }
        }
    }

    func advance(by duration: Duration) {
        advance(to: now() + duration)
    }

    func advance(to deadline: Duration) {
        let due = state.withLock { state -> [Sleeper] in
            state.current = max(state.current, deadline)
            let due = state.sleepers.filter { $0.value.deadline <= state.current }
            for key in due.keys {
                state.sleepers.removeValue(forKey: key)
            }
            return due.values.sorted(by: { $0.deadline < $1.deadline })
        }
        for sleeper in due {
            sleeper.continuation.resume()
        }
    }

    /// Waits until at least one sleeper is registered. Returns its earliest deadline.
    func waitForSleeper() async -> Duration? {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if let earliest = pendingDeadlines.first {
                return earliest
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return nil
    }

    /// Advances to the next registered deadline and returns it.
    @discardableResult
    func fireNextDeadline() async -> Duration? {
        guard let deadline = await waitForSleeper() else {
            return nil
        }
        advance(to: deadline)
        return deadline
    }
}

final class SnapshotRecorder: Sendable {
    private let storage = Mutex<[LicenseSnapshot]>([])

    var snapshots: [LicenseSnapshot] { storage.withLock { $0 } }

    var handler: @Sendable (LicenseSnapshot) -> Void {
        { [self] snapshot in storage.withLock { $0.append(snapshot) } }
    }

    func waitForSnapshot(
        where predicate: @escaping (LicenseSnapshot) -> Bool
    ) async -> LicenseSnapshot? {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if let match = snapshots.last(where: predicate) {
                return match
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return nil
    }

    func waitForSnapshot(state: LicenseState) async -> LicenseSnapshot? {
        await waitForSnapshot { $0.content.state == state }
    }
}

func waitUntil(_ condition: @escaping @Sendable () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
        if condition() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return condition()
}

/// Everything a controller test needs, wired together with manual clocks.
struct ControllerHarness {
    let fixture: EntitlementFixture
    let store: InMemoryCredentialStore
    let service = ScriptedLicenseService()
    let clock = TestLicensingClock()
    let wall: TestWallClock
    let recorder = SnapshotRecorder()
    let controller: LicensingController

    init(
        fixture: EntitlementFixture,
        activation: ActivationState? = nil,
        identity: Bool = true,
        wallTime: Int64? = nil
    ) {
        self.fixture = fixture
        store = InMemoryCredentialStore(
            identity: identity ? InstallationIdentity(installationID: fixture.installationID) : nil,
            activation: activation
        )
        wall = TestWallClock(wallTime ?? fixture.issuedAt)
        controller = LicensingController(
            store: store,
            service: service,
            verifier: fixture.verifier,
            wallClock: wall.read,
            clock: clock,
            retryJitterMultiplier: 1
        )
    }

    func subscribe() async -> LicenseSnapshot {
        await controller.subscribe(recorder.handler)
    }

    /// Advances the wall clock and the monotonic clock together.
    func advance(seconds: Int64) {
        wall.time += seconds
        clock.advance(by: .seconds(seconds))
    }

    func serveMonthlyRefresh(revision: Int64, startingAt issuedAt: Int64? = nil) {
        let fixture = fixture
        let issuedAt = issuedAt ?? wall.time
        service.onRefresh { _, installationID in
            try fixture.sign(payload: fixture.monthlyPayload(
                startingAt: issuedAt,
                revision: revision,
                installationID: installationID
            ))
        }
    }

    func serveRefreshFailure(_ error: LicenseServiceError) {
        service.onRefresh { _, _ in throw error }
    }
}
