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

    init(
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

    init(
        issuer: String,
        audience: String,
        licenseID: String,
        entitlementID: String,
        issuedAt: Int64,
        schema: Int64,
        activationID: String,
        installationID: UUID,
        revision: Int64,
        releaseScope: EntitlementReleaseScope,
        securityUpdatesAfterExpiry: Bool,
        terms: EntitlementTerms
    ) {
        self.issuer = issuer
        self.audience = audience
        self.licenseID = licenseID
        self.entitlementID = entitlementID
        self.issuedAt = issuedAt
        self.schema = schema
        self.activationID = activationID
        self.installationID = installationID
        self.revision = revision
        self.releaseScope = releaseScope
        self.securityUpdatesAfterExpiry = securityUpdatesAfterExpiry
        self.terms = terms
    }
}

public struct VerifiedEntitlement: Equatable, Sendable {
    public let compactJWS: String
    public let keyID: String
    public let claims: EntitlementClaims

    init(compactJWS: String, keyID: String, claims: EntitlementClaims) {
        self.compactJWS = compactJWS
        self.keyID = keyID
        self.claims = claims
    }
}

public enum EntitlementProcessingState: Equatable, Sendable {
    case perpetual
    case active
    case paymentRecovery
    case grace
    case expired
}

public enum EntitlementUpdateAccess: Equatable, Sendable {
    case v1
    case current
    case securityOnly
    case none
}

public struct EntitlementEvaluation: Equatable, Sendable {
    public let processingState: EntitlementProcessingState
    public let permitsProcessing: Bool
    public let shouldRefresh: Bool
    public let updateAccess: EntitlementUpdateAccess
}

public extension VerifiedEntitlement {
    func evaluate(atUnixTime time: Int64) -> EntitlementEvaluation {
        switch claims.terms {
        case .perpetualV1:
            return EntitlementEvaluation(
                processingState: .perpetual,
                permitsProcessing: true,
                shouldRefresh: false,
                updateAccess: .v1
            )
        case let .monthly(terms):
            return evaluateMonthly(terms, atUnixTime: time)
        }
    }

    private func evaluateMonthly(_ terms: MonthlyTerms, atUnixTime time: Int64) -> EntitlementEvaluation {
        if time >= terms.expiresAt {
            return EntitlementEvaluation(
                processingState: .expired,
                permitsProcessing: false,
                shouldRefresh: false,
                updateAccess: claims.securityUpdatesAfterExpiry ? .securityOnly : .none
            )
        }

        let processingState: EntitlementProcessingState
        if time >= terms.recoveryUntil {
            processingState = .grace
        } else if time >= terms.billingPeriodEnd {
            processingState = .paymentRecovery
        } else {
            processingState = .active
        }

        return EntitlementEvaluation(
            processingState: processingState,
            permitsProcessing: true,
            shouldRefresh: time >= terms.refreshAfter,
            updateAccess: .current
        )
    }
}
