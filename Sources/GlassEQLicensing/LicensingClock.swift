import Foundation

/// Monotonic time for scheduling and for advancing trusted time within a process. Values are
/// durations since an arbitrary per-clock origin, so they never move backwards with the wall clock.
public protocol LicensingClock: Sendable {
    func now() -> Duration
    func sleep(until deadline: Duration) async throws
}

public struct ContinuousLicensingClock: LicensingClock {
    private let origin = ContinuousClock.now

    public init() {}

    public func now() -> Duration {
        ContinuousClock.now - origin
    }

    public func sleep(until deadline: Duration) async throws {
        try await ContinuousClock().sleep(until: origin.advanced(by: deadline))
    }
}
