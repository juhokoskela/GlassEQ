import CryptoKit
import Foundation
@testable import GlassEQLicensing

/// Signs entitlements with a fresh in-test Ed25519 key. Timeline constants follow the protocol:
/// refresh seven days after issuance, recovery two weeks after the period end, expiry one week
/// after recovery.
struct EntitlementFixture: Sendable {
    let keyID = "entitlement-2026-01"
    let installationID = UUID(uuidString: "4E70638A-3AB2-4D21-A4AB-0B2525F80D42")!
    let issuedAt: Int64 = 1_000_000
    let refreshAfter: Int64 = 1_604_800
    let billingPeriodEnd: Int64 = 1_864_000
    let recoveryUntil: Int64 = 3_073_600
    let expiresAt: Int64 = 3_678_400
    let privateKey: Curve25519.Signing.PrivateKey
    let verifier: EntitlementVerifier

    init() throws {
        privateKey = Curve25519.Signing.PrivateKey()
        verifier = try EntitlementVerifier(publicKeys: [
            keyID: privateKey.publicKey.rawRepresentation
        ])
    }

    func verify(_ token: String) throws -> VerifiedEntitlement {
        try verifier.verify(
            token,
            installationID: installationID,
            highestAcceptedRevision: nil,
            effectiveTime: issuedAt
        )
    }

    func sign(
        header: String? = nil,
        payload: String,
        using signingKey: Curve25519.Signing.PrivateKey? = nil
    ) throws -> String {
        let header = header ?? """
        {"alg":"EdDSA","kid":"\(keyID)","typ":"glasseq-entitlement+jwt"}
        """
        let encodedHeader = base64URL(Data(header.utf8))
        let encodedPayload = base64URL(Data(payload.utf8))
        let signingInput = "\(encodedHeader).\(encodedPayload)"
        let signature = try (signingKey ?? privateKey).signature(for: Data(signingInput.utf8))
        return "\(signingInput).\(base64URL(signature))"
    }

    func perpetualPayload(
        revision: Int64 = 7,
        installationID: UUID? = nil
    ) -> String {
        """
        {"iss":"https://license.glasseq.app","aud":"com.glasseq.app","sub":"lic_01","jti":"ent_01","iat":\(issuedAt),"schema":1,"plan":"perpetual_v1","activation_id":"act_01","installation_id":"\((installationID ?? self.installationID).uuidString)","revision":\(revision),"release_scope":"v1","security_updates_after_expiry":false}
        """
    }

    func monthlyPayload(
        issuedAt: Int64? = nil,
        revision: Int64 = 7,
        billingState: String = "active",
        billingPeriodEnd: Int64? = nil,
        recoveryUntil: Int64? = nil,
        refreshAfter: Int64? = nil,
        expiresAt: Int64? = nil,
        installationID: UUID? = nil
    ) -> String {
        """
        {"iss":"https://license.glasseq.app","aud":"com.glasseq.app","sub":"lic_01","jti":"ent_01","iat":\(issuedAt ?? self.issuedAt),"schema":1,"plan":"monthly","activation_id":"act_01","installation_id":"\((installationID ?? self.installationID).uuidString)","revision":\(revision),"release_scope":"current","security_updates_after_expiry":true,"billing_state":"\(billingState)","billing_period_end":\(billingPeriodEnd ?? self.billingPeriodEnd),"recovery_until":\(recoveryUntil ?? self.recoveryUntil),"refresh_after":\(refreshAfter ?? self.refreshAfter),"exp":\(expiresAt ?? self.expiresAt)}
        """
    }

    /// A monthly entitlement whose signed timeline starts at `issuedAt`, keeping the protocol's
    /// relative offsets, so tests can chain refreshes without recomputing every boundary.
    func monthlyPayload(startingAt issuedAt: Int64, revision: Int64, installationID: UUID? = nil) -> String {
        let shift = issuedAt - self.issuedAt
        return monthlyPayload(
            issuedAt: issuedAt,
            revision: revision,
            billingPeriodEnd: billingPeriodEnd + shift,
            recoveryUntil: recoveryUntil + shift,
            refreshAfter: refreshAfter + shift,
            expiresAt: expiresAt + shift,
            installationID: installationID
        )
    }

    func monthlyActivationState(
        activationToken: String = "gea_test",
        revision: Int64 = 7,
        issuedAt: Int64? = nil,
        refreshAfter: Int64? = nil,
        highestTrustedTime: Int64? = nil,
        installationID: UUID? = nil
    ) throws -> ActivationState {
        ActivationState(
            activationToken: activationToken,
            entitlement: try sign(payload: monthlyPayload(
                issuedAt: issuedAt,
                revision: revision,
                refreshAfter: refreshAfter,
                installationID: installationID
            )),
            highestAcceptedRevision: revision,
            highestTrustedTime: highestTrustedTime ?? self.issuedAt
        )
    }

    func perpetualActivationState(activationToken: String = "gea_test") throws -> ActivationState {
        ActivationState(
            activationToken: activationToken,
            entitlement: try sign(payload: perpetualPayload()),
            highestAcceptedRevision: 7,
            highestTrustedTime: issuedAt
        )
    }

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
