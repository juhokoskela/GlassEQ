import Foundation

public struct InstallationIdentity: Codable, Equatable, Sendable {
    public let installationID: UUID

    public init(installationID: UUID) {
        self.installationID = installationID
    }
}

/// Every cached authority that depends on the activation lives in this one value so clearing it
/// removes the token, the entitlement, the replay floor, and the trusted-time floor together.
public struct ActivationState: Codable, Equatable, Sendable {
    public static let maximumEncodedBytes = 16 * 1_024
    /// Increment before a persisted shape or meaning changes. Older clients reject records with
    /// a version they do not understand instead of restoring partial authority.
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    public var activationToken: String
    public var entitlement: String
    public var highestAcceptedRevision: Int64
    public var highestTrustedTime: Int64
    /// The wall clock observed when the service last returned a verified entitlement. Persisting
    /// this baseline prevents the same standing clock offset from looking like a new rollback on
    /// every launch.
    public var wallClockAtLastVerification: Int64?
    public var clockAnomalyDetectedAt: Int64?
    /// Set when the service answered a refresh with `license_not_eligible`. The cached entitlement
    /// may still carry a later `exp` than the server's shortened window, so the denial has to
    /// survive an offline relaunch. Cleared only by a successful refresh or a new activation.
    public var serverDeniedAt: Int64?
    /// Set when the service no longer recognizes the activation token, for example after the slot
    /// was released from another Mac. Service access is gone, but the signed entitlement keeps its
    /// offline authority until `exp`, and forever for a perpetual license.
    public var serviceRevokedAt: Int64?
    /// Set before the deactivation request is sent. From then on the installation is unlicensed
    /// locally even if the request or the Keychain deletion fails; both are retried.
    public var deactivationRequestedAt: Int64?

    public init(
        activationToken: String,
        entitlement: String,
        highestAcceptedRevision: Int64,
        highestTrustedTime: Int64,
        wallClockAtLastVerification: Int64? = nil,
        clockAnomalyDetectedAt: Int64? = nil,
        serverDeniedAt: Int64? = nil,
        serviceRevokedAt: Int64? = nil,
        deactivationRequestedAt: Int64? = nil
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.activationToken = activationToken
        self.entitlement = entitlement
        self.highestAcceptedRevision = highestAcceptedRevision
        self.highestTrustedTime = highestTrustedTime
        self.wallClockAtLastVerification = wallClockAtLastVerification
        self.clockAnomalyDetectedAt = clockAnomalyDetectedAt
        self.serverDeniedAt = serverDeniedAt
        self.serviceRevokedAt = serviceRevokedAt
        self.deactivationRequestedAt = deactivationRequestedAt
    }

    static func pendingDeactivation(
        activationToken: String,
        requestedAt: Int64
    ) -> ActivationState {
        ActivationState(
            activationToken: activationToken,
            entitlement: "",
            highestAcceptedRevision: 0,
            highestTrustedTime: requestedAt,
            deactivationRequestedAt: requestedAt
        )
    }

    func validate() throws(LicenseCredentialStoreError) {
        guard schemaVersion == Self.currentSchemaVersion,
              !activationToken.isEmpty,
              activationToken.utf8.count <= 256,
              entitlement.utf8.count <= EntitlementVerifier.maximumTokenBytes,
              highestAcceptedRevision >= 0,
              highestTrustedTime >= 0,
              [
                  wallClockAtLastVerification,
                  clockAnomalyDetectedAt,
                  serverDeniedAt,
                  serviceRevokedAt,
                  deactivationRequestedAt
              ].allSatisfy({ $0.map { $0 >= 0 } ?? true }) else {
            throw .corruptRecord
        }

        let hasActiveAuthority = !entitlement.isEmpty && highestAcceptedRevision > 0
        let isCleanupOnly = entitlement.isEmpty
            && highestAcceptedRevision == 0
            && deactivationRequestedAt != nil
        guard hasActiveAuthority || isCleanupOnly else {
            throw .corruptRecord
        }
    }
}

enum LicenseRecordCodec {
    static func encode<Value: Encodable>(_ value: Value) throws(LicenseCredentialStoreError) -> Data {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(value)
        } catch {
            throw .corruptRecord
        }
    }

    static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws(LicenseCredentialStoreError) -> Value {
        guard data.count <= ActivationState.maximumEncodedBytes else {
            throw .corruptRecord
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw .corruptRecord
        }
    }

    static func decodeActivationState(from data: Data) throws(LicenseCredentialStoreError) -> ActivationState {
        let state = try decode(ActivationState.self, from: data)
        try state.validate()
        return state
    }
}
