import Foundation

/// The trusted-time floor for one activation. Effective time is the greatest of the wall clock,
/// the highest time ever trusted, and the latest authenticated issuance time advanced by the
/// monotonic clock. The signed `exp` evaluated against this floor is the final cutoff.
struct TrustedTimeState: Equatable, Sendable {
    static let rollbackToleranceSeconds: Int64 = 6 * 60 * 60
    static let persistenceIntervalSeconds: Int64 = 60 * 60

    struct Anchor: Equatable, Sendable {
        var issuedAt: Int64
        var at: Duration
    }

    private(set) var highestTrustedTime: Int64
    private(set) var lastPersistedTrustedTime: Int64
    private(set) var anchor: Anchor

    init(persistedTrustedTime: Int64?, wallClock: Int64, now: Duration) {
        let wallClock = max(wallClock, 0)
        let floor = max(wallClock, persistedTrustedTime ?? wallClock)
        highestTrustedTime = floor
        lastPersistedTrustedTime = persistedTrustedTime ?? floor
        anchor = Anchor(issuedAt: floor, at: now)
    }

    func effectiveTime(wallClock: Int64, now: Duration) -> Int64 {
        let elapsed = max((now - anchor.at).components.seconds, 0)
        let anchored = anchor.issuedAt.addingReportingOverflow(elapsed)
        return max(wallClock, highestTrustedTime, anchored.overflow ? .max : anchored.partialValue)
    }

    func detectsRollback(wallClock: Int64) -> Bool {
        let threshold = highestTrustedTime.subtractingReportingOverflow(Self.rollbackToleranceSeconds)
        return wallClock < (threshold.overflow ? .min : threshold.partialValue)
    }

    var needsPersistence: Bool {
        guard highestTrustedTime >= lastPersistedTrustedTime else { return false }
        return highestTrustedTime - lastPersistedTrustedTime >= Self.persistenceIntervalSeconds
    }

    var hasUnpersistedAdvance: Bool {
        highestTrustedTime > lastPersistedTrustedTime
    }

    mutating func advance(to time: Int64) {
        highestTrustedTime = max(highestTrustedTime, time)
    }

    mutating func anchor(issuedAt: Int64, at now: Duration) {
        anchor = Anchor(issuedAt: issuedAt, at: now)
        advance(to: issuedAt)
    }

    mutating func rebase(issuedAt: Int64, wallClock: Int64, at now: Duration) {
        let floor = max(issuedAt, wallClock, 0)
        highestTrustedTime = floor
        anchor = Anchor(issuedAt: floor, at: now)
    }

    mutating func markPersisted() {
        lastPersistedTrustedTime = highestTrustedTime
    }
}
