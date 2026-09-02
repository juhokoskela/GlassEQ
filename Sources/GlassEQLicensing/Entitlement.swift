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

public struct EntitlementClaims: Equatable, Sendable {
    public let issuer: String
    public let audience: String
    public let licenseID: String
    public let entitlementID: String
    public let issuedAt: Int64
    public let schema: Int64
    public let plan: EntitlementPlan
    public let activationID: String
    public let installationID: UUID
    public let revision: Int64
    public let releaseScope: EntitlementReleaseScope
    public let securityUpdatesAfterExpiry: Bool
    public let billingState: MonthlyBillingState?
    public let billingPeriodEnd: Int64?
    public let recoveryUntil: Int64?
    public let refreshAfter: Int64?
    public let expiresAt: Int64?

    init(
        issuer: String,
        audience: String,
        licenseID: String,
        entitlementID: String,
        issuedAt: Int64,
        schema: Int64,
        plan: EntitlementPlan,
        activationID: String,
        installationID: UUID,
        revision: Int64,
        releaseScope: EntitlementReleaseScope,
        securityUpdatesAfterExpiry: Bool,
        billingState: MonthlyBillingState? = nil,
        billingPeriodEnd: Int64? = nil,
        recoveryUntil: Int64? = nil,
        refreshAfter: Int64? = nil,
        expiresAt: Int64? = nil
    ) {
        self.issuer = issuer
        self.audience = audience
        self.licenseID = licenseID
        self.entitlementID = entitlementID
        self.issuedAt = issuedAt
        self.schema = schema
        self.plan = plan
        self.activationID = activationID
        self.installationID = installationID
        self.revision = revision
        self.releaseScope = releaseScope
        self.securityUpdatesAfterExpiry = securityUpdatesAfterExpiry
        self.billingState = billingState
        self.billingPeriodEnd = billingPeriodEnd
        self.recoveryUntil = recoveryUntil
        self.refreshAfter = refreshAfter
        self.expiresAt = expiresAt
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
        switch claims.plan {
        case .perpetualV1:
            return EntitlementEvaluation(
                processingState: .perpetual,
                permitsProcessing: true,
                shouldRefresh: false,
                updateAccess: .v1
            )
        case .monthly:
            return evaluateMonthly(atUnixTime: time)
        }
    }

    private func evaluateMonthly(atUnixTime time: Int64) -> EntitlementEvaluation {
        guard let billingPeriodEnd = claims.billingPeriodEnd,
              let recoveryUntil = claims.recoveryUntil,
              let refreshAfter = claims.refreshAfter,
              let expiresAt = claims.expiresAt else {
            preconditionFailure("A verified monthly entitlement must contain its time claims")
        }

        if time >= expiresAt {
            return EntitlementEvaluation(
                processingState: .expired,
                permitsProcessing: false,
                shouldRefresh: false,
                updateAccess: claims.securityUpdatesAfterExpiry ? .securityOnly : .none
            )
        }

        let processingState: EntitlementProcessingState
        if time >= recoveryUntil {
            processingState = .grace
        } else if time >= billingPeriodEnd {
            processingState = .paymentRecovery
        } else {
            processingState = .active
        }

        return EntitlementEvaluation(
            processingState: processingState,
            permitsProcessing: true,
            shouldRefresh: time >= refreshAfter,
            updateAccess: .current
        )
    }
}
