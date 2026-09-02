import Foundation

public enum LicenseState: Equatable, Sendable {
    case unlicensed
    case perpetual
    case monthlyActive
    case monthlyRecovery
    case monthlyGrace
    case monthlyExpired
    case verificationNeeded
    case invalidEntitlement
    /// The credential store could not be read, so the cached entitlement is unknown. This is a
    /// storage problem rather than a bad entitlement. It fails closed and is retried.
    case storageUnavailable

    public var permitsProcessing: Bool {
        switch self {
        case .perpetual, .monthlyActive, .monthlyRecovery, .monthlyGrace, .verificationNeeded:
            true
        case .unlicensed, .monthlyExpired, .invalidEntitlement, .storageUnavailable:
            false
        }
    }
}

public enum LicenseRefreshFailure: Equatable, Sendable {
    case offline
    case timedOut
    case serviceUnavailable
    case rateLimited
    case rejected(LicenseServiceErrorCode)
    case invalidEntitlementReceived(EntitlementVerificationError)
}

public struct LicenseSnapshotContent: Equatable, Sendable {
    public let state: LicenseState
    public let plan: EntitlementPlan?
    public let billingState: MonthlyBillingState?
    public let billingPeriodEnd: Int64?
    public let recoveryUntil: Int64?
    public let expiresAt: Int64?
    public let updateAccess: EntitlementUpdateAccess
    public let lastRefreshFailure: LicenseRefreshFailure?
    public let storageFailure: LicenseCredentialStoreError?

    public var permitsProcessing: Bool { state.permitsProcessing }

    public init(
        state: LicenseState,
        plan: EntitlementPlan? = nil,
        billingState: MonthlyBillingState? = nil,
        billingPeriodEnd: Int64? = nil,
        recoveryUntil: Int64? = nil,
        expiresAt: Int64? = nil,
        updateAccess: EntitlementUpdateAccess = .none,
        lastRefreshFailure: LicenseRefreshFailure? = nil,
        storageFailure: LicenseCredentialStoreError? = nil
    ) {
        self.state = state
        self.plan = plan
        self.billingState = billingState
        self.billingPeriodEnd = billingPeriodEnd
        self.recoveryUntil = recoveryUntil
        self.expiresAt = expiresAt
        self.updateAccess = updateAccess
        self.lastRefreshFailure = lastRefreshFailure
        self.storageFailure = storageFailure
    }
}

/// An immutable license snapshot. `sequence` increases with every published change so a consumer
/// that receives snapshots through unordered hops can discard the ones that arrive late.
public struct LicenseSnapshot: Equatable, Sendable {
    public let sequence: UInt64
    public let content: LicenseSnapshotContent

    public init(sequence: UInt64, content: LicenseSnapshotContent) {
        self.sequence = sequence
        self.content = content
    }
}
