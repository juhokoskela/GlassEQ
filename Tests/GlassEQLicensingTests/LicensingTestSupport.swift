import Foundation
@testable import GlassEQLicensing

final class InMemoryCredentialStore: LicenseCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var _identity: InstallationIdentity?
    private var _activation: ActivationState?
    private var _loadFailure: LicenseCredentialStoreError?
    private var _saveFailure: LicenseCredentialStoreError?
    private var _clearFailure: LicenseCredentialStoreError?
    private var _corruptActivation = false
    private var _saveActivationCount = 0
    private var _clearCount = 0

    init(identity: InstallationIdentity? = nil, activation: ActivationState? = nil) {
        _identity = identity
        _activation = activation
    }

    var identity: InstallationIdentity? {
        get { lock.withLock { _identity } }
        set { lock.withLock { _identity = newValue } }
    }

    var activation: ActivationState? {
        get { lock.withLock { _activation } }
        set { lock.withLock { _activation = newValue } }
    }

    var loadFailure: LicenseCredentialStoreError? {
        get { lock.withLock { _loadFailure } }
        set { lock.withLock { _loadFailure = newValue } }
    }

    var saveFailure: LicenseCredentialStoreError? {
        get { lock.withLock { _saveFailure } }
        set { lock.withLock { _saveFailure = newValue } }
    }

    var clearFailure: LicenseCredentialStoreError? {
        get { lock.withLock { _clearFailure } }
        set { lock.withLock { _clearFailure = newValue } }
    }

    var corruptActivation: Bool {
        get { lock.withLock { _corruptActivation } }
        set { lock.withLock { _corruptActivation = newValue } }
    }

    var saveActivationCount: Int { lock.withLock { _saveActivationCount } }
    var clearCount: Int { lock.withLock { _clearCount } }

    func loadInstallationIdentity() throws -> InstallationIdentity? {
        try lock.withLock {
            if let failure = _loadFailure { throw failure }
            return _identity
        }
    }

    func saveInstallationIdentity(_ identity: InstallationIdentity) throws {
        try lock.withLock {
            if let failure = _saveFailure { throw failure }
            _identity = identity
        }
    }

    func loadActivationState() throws -> ActivationState? {
        try lock.withLock {
            if let failure = _loadFailure { throw failure }
            if _corruptActivation { throw LicenseCredentialStoreError.corruptRecord }
            return _activation
        }
    }

    func saveActivationState(_ state: ActivationState) throws {
        try lock.withLock {
            _saveActivationCount += 1
            if let failure = _saveFailure { throw failure }
            _activation = state
        }
    }

    func clearActivationState() throws {
        try lock.withLock {
            _clearCount += 1
            if let failure = _clearFailure { throw failure }
            _activation = nil
        }
    }
}

final class ScriptedLicenseService: LicenseServicing, @unchecked Sendable {
    enum Call: Equatable, Sendable {
        case activate(licenseKey: String, installationID: UUID, idempotencyKey: UUID)
        case refresh(activationToken: String, installationID: UUID)
        case deactivate(activationToken: String)
    }

    typealias ActivateHandler = @Sendable (String, UUID, UUID) async throws -> ActivationResponse
    typealias RefreshHandler = @Sendable (String, UUID) async throws -> String
    typealias DeactivateHandler = @Sendable (String) async throws -> Void

    private let lock = NSLock()
    private var _calls: [Call] = []
    private var _activate: ActivateHandler = { _, _, _ in throw LicenseServiceError.transport(.other) }
    private var _refresh: RefreshHandler = { _, _ in throw LicenseServiceError.transport(.other) }
    private var _deactivate: DeactivateHandler = { _ in throw LicenseServiceError.transport(.other) }

    var calls: [Call] { lock.withLock { _calls } }
    var refreshCallCount: Int {
        calls.filter { if case .refresh = $0 { true } else { false } }.count
    }

    func onActivate(_ handler: @escaping ActivateHandler) {
        lock.withLock { _activate = handler }
    }

    func onRefresh(_ handler: @escaping RefreshHandler) {
        lock.withLock { _refresh = handler }
    }

    func onDeactivate(_ handler: @escaping DeactivateHandler) {
        lock.withLock { _deactivate = handler }
    }

    func activate(licenseKey: String, installationID: UUID, idempotencyKey: UUID) async throws -> ActivationResponse {
        let handler = lock.withLock {
            _calls.append(.activate(licenseKey: licenseKey, installationID: installationID, idempotencyKey: idempotencyKey))
            return _activate
        }
        return try await handler(licenseKey, installationID, idempotencyKey)
    }

    func refresh(activationToken: String, installationID: UUID) async throws -> String {
        let handler = lock.withLock {
            _calls.append(.refresh(activationToken: activationToken, installationID: installationID))
            return _refresh
        }
        return try await handler(activationToken, installationID)
    }

    func deactivateCurrent(activationToken: String) async throws {
        let handler = lock.withLock {
            _calls.append(.deactivate(activationToken: activationToken))
            return _deactivate
        }
        try await handler(activationToken)
    }
}

/// Suspends callers until opened. Used to hold a scripted request in flight.
final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock {
                if isOpen { return true }
                waiters.append(continuation)
                return false
            }
            if resumeNow {
                continuation.resume()
            }
        }
    }

    func open() {
        let waiters = lock.withLock {
            isOpen = true
            defer { self.waiters.removeAll() }
            return self.waiters
        }
        for waiter in waiters {
            waiter.resume()
        }
    }
}

final class TestWallClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _time: Int64

    init(_ time: Int64) {
        _time = time
    }

    var time: Int64 {
        get { lock.withLock { _time } }
        set { lock.withLock { _time = newValue } }
    }

    var read: @Sendable () -> Int64 {
        { [self] in time }
    }
}

/// A manually advanced monotonic clock whose sleepers resume when their deadline is reached.
final class TestLicensingClock: LicensingClock, @unchecked Sendable {
    private struct Sleeper {
        let deadline: Duration
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let lock = NSLock()
    private var current: Duration = .zero
    private var sleepers: [UUID: Sleeper] = [:]
    private var cancelledBeforeRegistration: Set<UUID> = []
    private var _requestedDeadlines: [Duration] = []

    var requestedDeadlines: [Duration] { lock.withLock { _requestedDeadlines } }
    var pendingDeadlines: [Duration] { lock.withLock { sleepers.values.map(\.deadline).sorted() } }

    func now() -> Duration {
        lock.withLock { current }
    }

    func sleep(until deadline: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                lock.lock()
                _requestedDeadlines.append(deadline)
                if cancelledBeforeRegistration.remove(id) != nil {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if current >= deadline {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            if let sleeper = sleepers.removeValue(forKey: id) {
                lock.unlock()
                sleeper.continuation.resume(throwing: CancellationError())
            } else {
                cancelledBeforeRegistration.insert(id)
                lock.unlock()
            }
        }
    }

    func advance(by duration: Duration) {
        advance(to: now() + duration)
    }

    func advance(to deadline: Duration) {
        lock.lock()
        current = max(current, deadline)
        let due = sleepers.filter { $0.value.deadline <= current }
        for key in due.keys {
            sleepers.removeValue(forKey: key)
        }
        lock.unlock()
        for sleeper in due.values.sorted(by: { $0.deadline < $1.deadline }) {
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

final class SnapshotRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _snapshots: [LicenseSnapshot] = []

    var snapshots: [LicenseSnapshot] { lock.withLock { _snapshots } }

    var handler: @Sendable (LicenseSnapshot) -> Void {
        { [self] snapshot in lock.withLock { _snapshots.append(snapshot) } }
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
        wallTime: Int64? = nil,
        retryBackoff: [Duration] = [.seconds(60), .seconds(300), .seconds(900)]
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
            retryBackoff: retryBackoff
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
