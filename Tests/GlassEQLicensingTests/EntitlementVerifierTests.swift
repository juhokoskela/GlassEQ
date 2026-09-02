import CryptoKit
import Foundation
import Testing
@testable import GlassEQLicensing

@Suite
struct EntitlementVerifierTests {
    @Test
    func verifiesAndEvaluatesMonthlyEntitlement() throws {
        let fixture = try EntitlementFixture()
        let token = try fixture.sign(payload: fixture.monthlyPayload())

        let entitlement = try fixture.verifier.verify(
            token,
            installationID: fixture.installationID,
            highestAcceptedRevision: 6,
            effectiveTime: fixture.issuedAt
        )

        #expect(entitlement.keyID == fixture.keyID)
        #expect(entitlement.claims.plan == .monthly)
        #expect(entitlement.claims.monthlyTerms?.billingState == .active)
        #expect(entitlement.claims.revision == 7)
        #expect(entitlement.evaluate(atUnixTime: fixture.billingPeriodEnd - 1) == EntitlementEvaluation(
            processingState: .active,
            permitsProcessing: true,
            shouldRefresh: true,
            updateAccess: .current
        ))
        #expect(entitlement.evaluate(atUnixTime: fixture.billingPeriodEnd) == EntitlementEvaluation(
            processingState: .paymentRecovery,
            permitsProcessing: true,
            shouldRefresh: true,
            updateAccess: .current
        ))
        #expect(entitlement.evaluate(atUnixTime: fixture.recoveryUntil) == EntitlementEvaluation(
            processingState: .grace,
            permitsProcessing: true,
            shouldRefresh: true,
            updateAccess: .current
        ))
        #expect(entitlement.evaluate(atUnixTime: fixture.expiresAt) == EntitlementEvaluation(
            processingState: .expired,
            permitsProcessing: false,
            shouldRefresh: false,
            updateAccess: .securityOnly
        ))
    }

    @Test
    func verifiesPerpetualEntitlementWithoutRefreshOrExpiry() throws {
        let fixture = try EntitlementFixture()
        let token = try fixture.sign(payload: fixture.perpetualPayload())

        let entitlement = try fixture.verifier.verify(
            token,
            installationID: fixture.installationID,
            highestAcceptedRevision: nil,
            effectiveTime: fixture.issuedAt
        )

        #expect(entitlement.claims.plan == .perpetualV1)
        #expect(entitlement.claims.monthlyTerms == nil)
        #expect(entitlement.evaluate(atUnixTime: .max) == EntitlementEvaluation(
            processingState: .perpetual,
            permitsProcessing: true,
            shouldRefresh: false,
            updateAccess: .v1
        ))
    }

    @Test
    func rejectsSignatureFromAnotherKey() throws {
        let fixture = try EntitlementFixture()
        let otherKey = Curve25519.Signing.PrivateKey()
        let token = try fixture.sign(payload: fixture.monthlyPayload(), using: otherKey)

        #expect(throws: EntitlementVerificationError.invalidSignature) {
            try fixture.verifier.verify(
                token,
                installationID: fixture.installationID,
                highestAcceptedRevision: nil,
                effectiveTime: fixture.issuedAt
            )
        }
    }

    @Test
    func rejectsUnknownAndDuplicateHeaderFields() throws {
        let fixture = try EntitlementFixture()
        let unknownHeader = """
        {"alg":"EdDSA","kid":"\(fixture.keyID)","typ":"glasseq-entitlement+jwt","extra":"value"}
        """
        let duplicateHeader = """
        {"alg":"EdDSA","alg":"EdDSA","kid":"\(fixture.keyID)","typ":"glasseq-entitlement+jwt"}
        """

        let unknownToken = try fixture.sign(header: unknownHeader, payload: fixture.monthlyPayload())
        let duplicateToken = try fixture.sign(header: duplicateHeader, payload: fixture.monthlyPayload())

        #expect(throws: EntitlementVerificationError.unsupportedHeader) {
            try fixture.verify(unknownToken)
        }
        #expect(throws: EntitlementVerificationError.malformedHeader) {
            try fixture.verify(duplicateToken)
        }
    }

    @Test
    func rejectsDuplicateAndUnknownClaims() throws {
        let fixture = try EntitlementFixture()
        let monthlyPayload = fixture.monthlyPayload()
        let duplicatePayload = "{\"iss\":\"https://license.glasseq.app\"," + monthlyPayload.dropFirst()
        let unknownPayload = monthlyPayload.dropLast() + ",\"extra\":true}"

        #expect(throws: EntitlementVerificationError.malformedClaims) {
            try fixture.verify(try fixture.sign(payload: duplicatePayload))
        }
        #expect(throws: EntitlementVerificationError.unsupportedClaims) {
            try fixture.verify(try fixture.sign(payload: String(unknownPayload)))
        }
    }

    @Test
    func rejectsMismatchedInstallationAndStaleRevision() throws {
        let fixture = try EntitlementFixture()
        let token = try fixture.sign(payload: fixture.monthlyPayload())

        #expect(throws: EntitlementVerificationError.installationMismatch) {
            try fixture.verifier.verify(
                token,
                installationID: UUID(),
                highestAcceptedRevision: nil,
                effectiveTime: fixture.issuedAt
            )
        }
        #expect(throws: EntitlementVerificationError.staleRevision) {
            try fixture.verifier.verify(
                token,
                installationID: fixture.installationID,
                highestAcceptedRevision: 8,
                effectiveTime: fixture.issuedAt
            )
        }
    }

    @Test
    func acceptsFiveMinuteFutureSkewAndRejectsTheNextSecond() throws {
        let fixture = try EntitlementFixture()
        let acceptedToken = try fixture.sign(payload: fixture.monthlyPayload(issuedAt: fixture.issuedAt + 300))
        let rejectedToken = try fixture.sign(payload: fixture.monthlyPayload(issuedAt: fixture.issuedAt + 301))

        _ = try fixture.verify(acceptedToken)
        #expect(throws: EntitlementVerificationError.issuedInFuture) {
            try fixture.verify(rejectedToken)
        }
    }

    @Test
    func rejectsInvalidMonthlyTimeline() throws {
        let fixture = try EntitlementFixture()
        let token = try fixture.sign(payload: fixture.monthlyPayload(expiresAt: fixture.expiresAt + 1))

        #expect(throws: EntitlementVerificationError.invalidTimeline) {
            try fixture.verify(token)
        }
    }

    @Test
    func rejectsPaddedBase64URLAndOversizedToken() throws {
        let fixture = try EntitlementFixture()
        let token = try fixture.sign(payload: fixture.monthlyPayload())
        var parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        parts[0] += "="

        #expect(throws: EntitlementVerificationError.invalidBase64URL) {
            try fixture.verify(parts.joined(separator: "."))
        }
        #expect(throws: EntitlementVerificationError.tokenTooLarge) {
            try fixture.verify(String(repeating: "a", count: EntitlementVerifier.maximumTokenBytes + 1))
        }
    }

    @Test
    func strictParserDecodesUnicodeAndRejectsUnsupportedValues() throws {
        var validParser = StrictJSONObjectParser(data: Data(#"{"name":"Glass\u0045Q \uD83C\uDFB5"}"#.utf8))
        var arrayParser = StrictJSONObjectParser(data: Data(#"{"value":[]}"#.utf8))
        var decimalParser = StrictJSONObjectParser(data: Data(#"{"value":1.5}"#.utf8))

        #expect(try validParser.parse() == ["name": .string("GlassEQ 🎵")])
        #expect(throws: StrictJSONObjectError.unsupportedValue) {
            try arrayParser.parse()
        }
        #expect(throws: StrictJSONObjectError.unsupportedValue) {
            try decimalParser.parse()
        }
    }
}
