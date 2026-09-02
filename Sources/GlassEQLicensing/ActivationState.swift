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

    public var activationToken: String
    public var entitlement: String
    public var highestAcceptedRevision: Int64
    public var highestTrustedTime: Int64
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
        clockAnomalyDetectedAt: Int64? = nil,
        serverDeniedAt: Int64? = nil,
        serviceRevokedAt: Int64? = nil,
        deactivationRequestedAt: Int64? = nil
    ) {
        self.activationToken = activationToken
        self.entitlement = entitlement
        self.highestAcceptedRevision = highestAcceptedRevision
        self.highestTrustedTime = highestTrustedTime
        self.clockAnomalyDetectedAt = clockAnomalyDetectedAt
        self.serverDeniedAt = serverDeniedAt
        self.serviceRevokedAt = serviceRevokedAt
        self.deactivationRequestedAt = deactivationRequestedAt
    }
}

enum LicenseRecordCodec {
    static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        guard data.count <= ActivationState.maximumEncodedBytes else {
            throw LicenseCredentialStoreError.corruptRecord
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw LicenseCredentialStoreError.corruptRecord
        }
    }
}
