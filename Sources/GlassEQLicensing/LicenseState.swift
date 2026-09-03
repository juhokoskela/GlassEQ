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

/// What the controller would do with the stored record, decided where the record is loaded and
/// verified so a UI never has to guess which recovery a non-permitting state needs.
public enum ActivationAvailability: Equatable, Sendable {
    /// Nothing is stored, or the stored record is malformed and `activate` will clear it.
    case available
    /// A verified record is stored. `activate` throws `activationAlreadyExists`.
    case activated
    /// A verified record whose service access is gone: the slot was released elsewhere or the
    /// token stopped being recognized. It keeps its signed offline authority until `exp`, but no
    /// refresh can ever renew it, so once it stops permitting processing only removal helps.
    case revoked
    /// A deactivation is still releasing its server slot. Its cleanup is retried, and activation
    /// waits so the old slot cannot become unreachable.
    case releasingPreviousActivation
    /// The Keychain could not be read. Nothing can be decided until the retried read succeeds.
    case storageUnavailable
    /// The stored record uses a schema, signing key, header, or claim set this build does not
    /// know. A newer GlassEQ can use it; deactivating it would throw away a valid license.
    case needsAppUpdate
    /// The stored record cannot be used on this Mac: its identity is gone or foreign, its
    /// signature or timeline is bad, or it was rolled back. Deactivating it releases the slot.
    case needsRemoval
}

public struct LicenseSnapshotContent: Equatable, Sendable {
    public let state: LicenseState
    public let terms: MonthlyTerms?
    public let lastRefreshFailure: LicenseRefreshFailure?
    public let storageFailure: LicenseCredentialStoreError?
    public let activation: ActivationAvailability

    public var permitsProcessing: Bool { state.permitsProcessing }

    public init(
        state: LicenseState,
        terms: MonthlyTerms? = nil,
        lastRefreshFailure: LicenseRefreshFailure? = nil,
        storageFailure: LicenseCredentialStoreError? = nil,
        activation: ActivationAvailability
    ) {
        self.state = state
        self.terms = terms
        self.lastRefreshFailure = lastRefreshFailure
        self.storageFailure = storageFailure
        self.activation = activation
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
