import Foundation
import GlassEQLicensing

/// What a snapshot that does not permit processing asks the user to do. The menu bar status and
/// the onboarding step both read it, so they never name different actions for the same record.
/// Nil while processing is permitted.
enum LicenseRecovery: Equatable {
    /// Activation would be accepted. `notice` explains a stored record that it will replace.
    case activate(notice: String?)
    /// A stored record the controller cannot use on this Mac must be released first.
    case remove(notice: String)
    /// Nothing to do here: the controller is retrying, a release is pending, or this build is
    /// too old for the record.
    case wait(message: String)
    /// A verified subscription that has expired.
    case renew

    init?(content: LicenseSnapshotContent) {
        guard !content.permitsProcessing else {
            return nil
        }
        switch content.activation {
        case .activated:
            self = .renew
        case .revoked:
            self = .remove(notice: localized("This Mac's place on the license was released, and the subscription has ended. Remove the stored license, then activate again."))
        case .available:
            self = .activate(notice: content.state == .invalidEntitlement
                ? localized("The stored license is invalid. Activate again to continue.")
                : nil)
        case .releasingPreviousActivation:
            self = .wait(message: localized("The previous license is still being released. Activation opens as soon as that finishes."))
        case .storageUnavailable:
            self = .wait(message: localized("The license could not be read from Keychain. GlassEQ keeps trying."))
        case .needsAppUpdate:
            self = .wait(message: localized("This Mac's license needs a newer version of GlassEQ."))
        case .needsRemoval:
            self = .remove(notice: localized("The stored license can't be verified on this Mac. Remove it, then activate again."))
        }
    }

    /// The one-line reason processing is stopped.
    var statusMessage: String {
        switch self {
        case let .activate(notice):
            notice ?? localized("Activate a license to start processing")
        case let .remove(notice):
            notice
        case let .wait(message):
            message
        case .renew:
            localized("Subscription ended. GlassEQ has returned to unprocessed playback.")
        }
    }
}

/// What onboarding's activation step shows. The app model derives it from `LicenseRecovery`, the
/// build's licensing configuration, and the user-driven operation in flight.
enum OnboardingLicenseState: Equatable {
    case checking
    /// `failure` is the last operation's error, kept until the next attempt starts.
    case awaitingKey(notice: String?, failure: String?)
    case replaceable(notice: String, failure: String?)
    case unavailable(message: String, failure: String?)
    case working(String)
    case activated(detail: String)
    /// Renewal is possible through the controller's refresh; removal is offered for a license
    /// that will not come back. `failure` is a failed removal.
    case expired(detail: String, failure: String?)

    /// The step has nothing left to ask for, so the footer offers Continue instead of Skip.
    var isSettled: Bool {
        switch self {
        case .activated, .expired:
            true
        case .checking, .awaitingKey, .replaceable, .unavailable, .working:
            false
        }
    }
}

/// Copy for failed activation and removal requests. Server text is never shown directly; every
/// code has its own line, and a Retry-After becomes a concrete wait.
enum LicenseOperationFailureMessage {
    static func text(for error: LicensingError) -> String {
        switch error {
        case .operationInProgress:
            return localized("Another license operation is still running. Try again in a moment.")
        case .activationAlreadyExists:
            return localized("This Mac already has an active license.")
        case .shutDown:
            return localized("GlassEQ is quitting.")
        case .storage:
            return localized("Keychain could not be updated. Try again.")
        case .entitlement(.issuedInFuture):
            return localized("Check this Mac's date and time, then try again.")
        case .entitlement:
            return localized("The licensing service returned an invalid license. Try again in a moment.")
        case let .service(serviceError):
            return text(for: serviceError)
        }
    }

    static func text(for error: LicenseServiceError) -> String {
        switch error {
        case .invalidLicenseKey:
            return localized("Enter the license key from your purchase email. It starts with GEQ1-.")
        case .service(.invalidCredentials, _):
            return localized("That license key was not recognized. Check it and try again.")
        case .service(.activationLimit, _):
            return localized("This license is already active on two Macs. A third can't be added until one of them is released.")
        case .service(.licenseNotEligible, _):
            return localized("This license can't be activated. It may have been refunded, or its subscription may have ended.")
        case let .service(.rateLimited, retryAfterSeconds),
             let .service(.temporarilyUnavailable, retryAfterSeconds):
            guard let retryAfterSeconds else {
                return localized("The licensing service is busy. Try again in a moment.")
            }
            let wait = Duration.seconds(retryAfterSeconds)
                .formatted(.units(allowed: [.minutes, .seconds], width: .wide, maximumUnitCount: 1))
            return localized("The licensing service is busy. Try again in \(wait).")
        case .service:
            return localized("The licensing service rejected the request. Try again in a moment.")
        case .transport(.offline):
            return localized("This Mac appears to be offline. Connect to the internet and try again.")
        case .transport(.timedOut):
            return localized("The licensing service did not respond. Try again.")
        case .transport(.other), .malformedResponse, .unexpectedStatus, .redirected:
            return localized("The licensing service could not be reached. Try again in a moment.")
        case .cancelled:
            return localized("The request was interrupted. Try again.")
        }
    }
}
