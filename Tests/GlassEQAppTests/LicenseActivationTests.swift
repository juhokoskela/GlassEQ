import Foundation
import GlassEQLicensing
import Testing
@testable import GlassEQApp

@Suite
struct LicenseOperationFailureMessageTests {
    private static let everyError: [LicensingError] = [
        .operationInProgress,
        .activationAlreadyExists,
        .shutDown,
        .storage(.corruptRecord),
        .entitlement(.issuedInFuture),
        .entitlement(.invalidSignature),
        .service(.invalidLicenseKey),
        .service(.service(code: .invalidCredentials, retryAfterSeconds: nil)),
        .service(.service(code: .activationLimit, retryAfterSeconds: nil)),
        .service(.service(code: .licenseNotEligible, retryAfterSeconds: nil)),
        .service(.service(code: .rateLimited, retryAfterSeconds: 30)),
        .service(.service(code: .temporarilyUnavailable, retryAfterSeconds: nil)),
        .service(.service(code: .invalidRequest, retryAfterSeconds: nil)),
        .service(.service(code: .unknown("mystery"), retryAfterSeconds: nil)),
        .service(.transport(.offline)),
        .service(.transport(.timedOut)),
        .service(.transport(.other)),
        .service(.malformedResponse),
        .service(.unexpectedStatus(500)),
        .service(.redirected),
        .service(.cancelled)
    ]

    @Test(arguments: everyError)
    func everyKnownErrorHasCopyThatNeverEchoesTheRawCode(error: LicensingError) {
        let text = LicenseOperationFailureMessage.text(for: error)

        #expect(!text.isEmpty)
        #expect(!text.contains("mystery"))
        #expect(!text.contains("_"))
    }

    @Test
    func theStatesOnboardingNamesGetSpecificGuidance() {
        #expect(LicenseOperationFailureMessage.text(
            for: LicensingError.service(.service(code: .activationLimit, retryAfterSeconds: nil))
        ).contains("two Macs"))
        #expect(LicenseOperationFailureMessage.text(
            for: LicensingError.service(.transport(.offline))
        ).contains("offline"))
        #expect(LicenseOperationFailureMessage.text(
            for: LicensingError.service(.service(code: .invalidCredentials, retryAfterSeconds: nil))
        ).contains("not recognized"))
        #expect(LicenseOperationFailureMessage.text(
            for: LicensingError.service(.invalidLicenseKey)
        ).contains("GEQ1-"))
        #expect(LicenseOperationFailureMessage.text(
            for: LicensingError.entitlement(.issuedInFuture)
        ).contains("date and time"))
    }

    @Test
    func retryAfterBecomesAConcreteWait() {
        let seconds = LicenseOperationFailureMessage.text(
            for: LicensingError.service(.service(code: .rateLimited, retryAfterSeconds: 30))
        )
        let minutes = LicenseOperationFailureMessage.text(
            for: LicensingError.service(.service(code: .temporarilyUnavailable, retryAfterSeconds: 300))
        )
        let unknown = LicenseOperationFailureMessage.text(
            for: LicensingError.service(.service(code: .temporarilyUnavailable, retryAfterSeconds: nil))
        )

        #expect(seconds.contains("30 seconds"))
        #expect(minutes.contains("5 minutes"))
        #expect(unknown.contains("in a moment"))
    }
}
