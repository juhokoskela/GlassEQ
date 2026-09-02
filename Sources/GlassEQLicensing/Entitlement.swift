import Foundation

public enum EntitlementPlan: String, Sendable {
    case perpetualV1 = "perpetual_v1"
    case monthly
}

public enum EntitlementReleaseScope: String, Sendable {
    case v1
    case current
}

public enum MonthlyBillingState: String, Sendable {
    case active
    case recovering
    case ending
    case lapsed
    case refunded
    case chargedBack = "charged_back"
}

/// The signed monthly timeline. `billingState` controls messaging; the times control processing.
public struct MonthlyTerms: Equatable, Sendable {
    public let billingState: MonthlyBillingState
    public let billingPeriodEnd: Int64
    public let recoveryUntil: Int64
    public let refreshAfter: Int64
    public let expiresAt: Int64

    public init(
        billingState: MonthlyBillingState,
        billingPeriodEnd: Int64,
        recoveryUntil: Int64,
        refreshAfter: Int64,
        expiresAt: Int64
    ) {
        self.billingState = billingState
        self.billingPeriodEnd = billingPeriodEnd
        self.recoveryUntil = recoveryUntil
        self.refreshAfter = refreshAfter
        self.expiresAt = expiresAt
    }
}

public enum EntitlementTerms: Equatable, Sendable {
    case perpetualV1
    case monthly(MonthlyTerms)
}

public struct EntitlementClaims: Equatable, Sendable {
    public let issuer: String
    public let audience: String
    public let licenseID: String
    public let entitlementID: String
    public let issuedAt: Int64
    public let schema: Int64
    public let activationID: String
    public let installationID: UUID
    public let revision: Int64
    public let releaseScope: EntitlementReleaseScope
    public let securityUpdatesAfterExpiry: Bool
    public let terms: EntitlementTerms

    public var plan: EntitlementPlan {
        switch terms {
        case .perpetualV1: .perpetualV1
        case .monthly: .monthly
        }
    }

    public var monthlyTerms: MonthlyTerms? {
        if case let .monthly(terms) = terms {
            return terms
        }
        return nil
    }
}

public struct VerifiedEntitlement: Equatable, Sendable {
    public let compactJWS: String
    public let keyID: String
    public let claims: EntitlementClaims
}
