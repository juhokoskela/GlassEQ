import CryptoKit
import Foundation

public enum EntitlementVerificationError: Error, Equatable, Sendable {
    case tokenTooLarge
    case malformedCompactSerialization
    case invalidBase64URL
    case malformedHeader
    case unsupportedHeader
    case unknownKeyID
    case invalidSignature
    case malformedClaims
    case unsupportedClaims
    case installationMismatch
    case staleRevision
    case issuedInFuture
    case invalidTimeline
}

public struct EntitlementVerifier: Sendable {
    public static let maximumTokenBytes = 8 * 1_024
    public static let maximumFutureSkewSeconds: Int64 = 5 * 60

    private static let issuer = "https://license.glasseq.app"
    private static let audience = "com.glasseq.app"
    private static let type = "glasseq-entitlement+jwt"
    private static let monthlyGraceSeconds: Int64 = 7 * 24 * 60 * 60

    private let publicKeys: [String: Curve25519.Signing.PublicKey]

    public init(publicKeys: [String: Data]) throws {
        var parsedKeys: [String: Curve25519.Signing.PublicKey] = [:]
        parsedKeys.reserveCapacity(publicKeys.count)
        for (keyID, rawRepresentation) in publicKeys {
            guard !keyID.isEmpty else {
                throw EntitlementVerificationError.unknownKeyID
            }
            do {
                parsedKeys[keyID] = try Curve25519.Signing.PublicKey(
                    rawRepresentation: rawRepresentation
                )
            } catch {
                throw EntitlementVerificationError.unknownKeyID
            }
        }
        self.publicKeys = parsedKeys
    }

    public func verify(
        _ compactJWS: String,
        installationID: UUID,
        highestAcceptedRevision: Int64?,
        effectiveTime: Int64
    ) throws -> VerifiedEntitlement {
        guard compactJWS.utf8.count <= Self.maximumTokenBytes else {
            throw EntitlementVerificationError.tokenTooLarge
        }

        let parts = compactJWS.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts.allSatisfy({ !$0.isEmpty }) else {
            throw EntitlementVerificationError.malformedCompactSerialization
        }

        let headerData = try decodeBase64URL(parts[0])
        let keyID = try parseHeader(headerData)
        guard let publicKey = publicKeys[keyID] else {
            throw EntitlementVerificationError.unknownKeyID
        }

        let signature = try decodeBase64URL(parts[2])
        guard signature.count == 64 else {
            throw EntitlementVerificationError.invalidSignature
        }
        let signingInput = Data("\(parts[0]).\(parts[1])".utf8)
        guard publicKey.isValidSignature(signature, for: signingInput) else {
            throw EntitlementVerificationError.invalidSignature
        }

        let payloadData = try decodeBase64URL(parts[1])
        let claims = try parseClaims(
            payloadData,
            installationID: installationID,
            highestAcceptedRevision: highestAcceptedRevision,
            effectiveTime: effectiveTime
        )
        return VerifiedEntitlement(compactJWS: compactJWS, keyID: keyID, claims: claims)
    }

    private func parseHeader(_ data: Data) throws -> String {
        let header: EntitlementHeader
        do {
            header = try decodeExactJSONObject(
                EntitlementHeader.self,
                from: data,
                expectedKeys: ["alg", "kid", "typ"]
            )
        } catch EntitlementJSONError.unsupportedFields {
            throw EntitlementVerificationError.unsupportedHeader
        } catch {
            throw EntitlementVerificationError.malformedHeader
        }

        guard header.algorithm == "EdDSA",
              header.type == Self.type,
              !header.keyID.isEmpty else {
            throw EntitlementVerificationError.unsupportedHeader
        }
        return header.keyID
    }

    private func parseClaims(
        _ data: Data,
        installationID: UUID,
        highestAcceptedRevision: Int64?,
        effectiveTime: Int64
    ) throws -> EntitlementClaims {
        let payload: EntitlementPayload
        do {
            let fields = try jsonObjectFields(data)
            guard let rawPlan = fields["plan"] as? String,
                  let plan = EntitlementPlan(rawValue: rawPlan) else {
                throw EntitlementJSONError.unsupportedFields
            }
            let commonKeys: Set<String> = [
                "iss", "aud", "sub", "jti", "iat", "schema", "plan", "activation_id",
                "installation_id", "revision", "release_scope", "security_updates_after_expiry"
            ]
            let monthlyKeys: Set<String> = [
                "billing_state", "billing_period_end", "recovery_until", "refresh_after", "exp"
            ]
            payload = try decodeExactJSONObject(
                EntitlementPayload.self,
                from: data,
                fields: fields,
                expectedKeys: plan == .monthly ? commonKeys.union(monthlyKeys) : commonKeys
            )
        } catch EntitlementJSONError.unsupportedFields {
            throw EntitlementVerificationError.unsupportedClaims
        } catch {
            throw EntitlementVerificationError.malformedClaims
        }

        guard let plan = EntitlementPlan(rawValue: payload.plan) else {
            throw EntitlementVerificationError.unsupportedClaims
        }
        guard let claimedInstallationID = UUID(uuidString: payload.installationID),
              let releaseScope = EntitlementReleaseScope(rawValue: payload.releaseScope),
              payload.issuer == Self.issuer,
              payload.audience == Self.audience,
              payload.schema == 1,
              payload.revision > 0,
              !payload.licenseID.isEmpty,
              !payload.entitlementID.isEmpty,
              !payload.activationID.isEmpty,
              payload.issuedAt >= 0 else {
            throw EntitlementVerificationError.unsupportedClaims
        }

        guard claimedInstallationID == installationID else {
            throw EntitlementVerificationError.installationMismatch
        }
        if let highestAcceptedRevision, payload.revision < highestAcceptedRevision {
            throw EntitlementVerificationError.staleRevision
        }
        let (latestAcceptedIssueTime, overflow) = effectiveTime.addingReportingOverflow(
            Self.maximumFutureSkewSeconds
        )
        guard !overflow, payload.issuedAt <= latestAcceptedIssueTime else {
            throw EntitlementVerificationError.issuedInFuture
        }

        switch plan {
        case .perpetualV1:
            guard releaseScope == .v1, !payload.securityUpdatesAfterExpiry else {
                throw EntitlementVerificationError.unsupportedClaims
            }
            return EntitlementClaims(
                issuer: payload.issuer,
                audience: payload.audience,
                licenseID: payload.licenseID,
                entitlementID: payload.entitlementID,
                issuedAt: payload.issuedAt,
                schema: payload.schema,
                activationID: payload.activationID,
                installationID: claimedInstallationID,
                revision: payload.revision,
                releaseScope: releaseScope,
                securityUpdatesAfterExpiry: payload.securityUpdatesAfterExpiry,
                terms: .perpetualV1
            )
        case .monthly:
            return try parseMonthlyClaims(
                payload,
                installationID: claimedInstallationID,
                releaseScope: releaseScope,
                securityUpdatesAfterExpiry: payload.securityUpdatesAfterExpiry
            )
        }
    }

    private func parseMonthlyClaims(
        _ payload: EntitlementPayload,
        installationID: UUID,
        releaseScope: EntitlementReleaseScope,
        securityUpdatesAfterExpiry: Bool
    ) throws -> EntitlementClaims {
        guard releaseScope == .current,
              let billingStateValue = payload.billingState,
              let billingState = MonthlyBillingState(rawValue: billingStateValue),
              let billingPeriodEnd = payload.billingPeriodEnd,
              let recoveryUntil = payload.recoveryUntil,
              let refreshAfter = payload.refreshAfter,
              let expiresAt = payload.expiresAt,
              billingPeriodEnd >= 0,
              payload.issuedAt <= refreshAfter,
              refreshAfter <= expiresAt,
              recoveryUntil < expiresAt else {
            throw EntitlementVerificationError.invalidTimeline
        }

        let (expectedExpiry, overflow) = recoveryUntil.addingReportingOverflow(Self.monthlyGraceSeconds)
        guard !overflow, expiresAt == expectedExpiry else {
            throw EntitlementVerificationError.invalidTimeline
        }

        switch billingState {
        case .active, .recovering, .ending, .lapsed:
            guard billingPeriodEnd <= recoveryUntil else {
                throw EntitlementVerificationError.invalidTimeline
            }
        case .refunded, .chargedBack:
            break
        }

        return EntitlementClaims(
            issuer: payload.issuer,
            audience: payload.audience,
            licenseID: payload.licenseID,
            entitlementID: payload.entitlementID,
            issuedAt: payload.issuedAt,
            schema: payload.schema,
            activationID: payload.activationID,
            installationID: installationID,
            revision: payload.revision,
            releaseScope: releaseScope,
            securityUpdatesAfterExpiry: securityUpdatesAfterExpiry,
            terms: .monthly(MonthlyTerms(
                billingState: billingState,
                billingPeriodEnd: billingPeriodEnd,
                recoveryUntil: recoveryUntil,
                refreshAfter: refreshAfter,
                expiresAt: expiresAt
            ))
        )
    }

    private func decodeBase64URL(_ value: Substring) throws -> Data {
        guard !value.contains("="),
              value.utf8.allSatisfy({ byte in
                  (0x41 ... 0x5A).contains(byte)
                      || (0x61 ... 0x7A).contains(byte)
                      || (0x30 ... 0x39).contains(byte)
                      || byte == 0x2D
                      || byte == 0x5F
              }),
              value.utf8.count % 4 != 1 else {
            throw EntitlementVerificationError.invalidBase64URL
        }

        var encoded = String(value)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        encoded.append(String(repeating: "=", count: (4 - encoded.count % 4) % 4))
        guard let data = Data(base64Encoded: encoded) else {
            throw EntitlementVerificationError.invalidBase64URL
        }
        return data
    }
}

private enum EntitlementJSONError: Error {
    case malformed
    case unsupportedFields
}

private struct EntitlementHeader: Decodable {
    let algorithm: String
    let keyID: String
    let type: String

    private enum CodingKeys: String, CodingKey {
        case algorithm = "alg"
        case keyID = "kid"
        case type = "typ"
    }
}

private struct EntitlementPayload: Decodable {
    let issuer: String
    let audience: String
    let licenseID: String
    let entitlementID: String
    let issuedAt: Int64
    let schema: Int64
    let plan: String
    let activationID: String
    let installationID: String
    let revision: Int64
    let releaseScope: String
    let securityUpdatesAfterExpiry: Bool
    let billingState: String?
    let billingPeriodEnd: Int64?
    let recoveryUntil: Int64?
    let refreshAfter: Int64?
    let expiresAt: Int64?

    private enum CodingKeys: String, CodingKey {
        case issuer = "iss"
        case audience = "aud"
        case licenseID = "sub"
        case entitlementID = "jti"
        case issuedAt = "iat"
        case schema
        case plan
        case activationID = "activation_id"
        case installationID = "installation_id"
        case revision
        case releaseScope = "release_scope"
        case securityUpdatesAfterExpiry = "security_updates_after_expiry"
        case billingState = "billing_state"
        case billingPeriodEnd = "billing_period_end"
        case recoveryUntil = "recovery_until"
        case refreshAfter = "refresh_after"
        case expiresAt = "exp"
    }
}

private func jsonObjectFields(_ data: Data) throws -> [String: Any] {
    guard let fields = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw EntitlementJSONError.malformed
    }
    return fields
}

private func decodeExactJSONObject<Value: Decodable>(
    _ type: Value.Type,
    from data: Data,
    fields: [String: Any]? = nil,
    expectedKeys: Set<String>
) throws -> Value {
    let fields = try fields ?? jsonObjectFields(data)
    guard Set(fields.keys) == expectedKeys else {
        throw EntitlementJSONError.unsupportedFields
    }
    return try JSONDecoder().decode(type, from: data)
}
