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
            guard !keyID.isEmpty, keyID.utf8.count <= 128 else {
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
        let object: [String: StrictJSONValue]
        do {
            var parser = StrictJSONObjectParser(data: data)
            object = try parser.parse()
        } catch {
            throw EntitlementVerificationError.malformedHeader
        }

        guard Set(object.keys) == ["alg", "kid", "typ"],
              object["alg"] == .string("EdDSA"),
              object["typ"] == .string(Self.type),
              case let .string(keyID)? = object["kid"],
              !keyID.isEmpty,
              keyID.utf8.count <= 128 else {
            throw EntitlementVerificationError.unsupportedHeader
        }
        return keyID
    }

    private func parseClaims(
        _ data: Data,
        installationID: UUID,
        highestAcceptedRevision: Int64?,
        effectiveTime: Int64
    ) throws -> EntitlementClaims {
        let object: [String: StrictJSONValue]
        do {
            var parser = StrictJSONObjectParser(data: data)
            object = try parser.parse()
        } catch {
            throw EntitlementVerificationError.malformedClaims
        }

        let commonKeys: Set<String> = [
            "iss", "aud", "sub", "jti", "iat", "schema", "plan", "activation_id",
            "installation_id", "revision", "release_scope", "security_updates_after_expiry"
        ]
        guard case let .string(planValue)? = object["plan"],
              let plan = EntitlementPlan(rawValue: planValue) else {
            throw EntitlementVerificationError.unsupportedClaims
        }

        let requiredKeys: Set<String>
        switch plan {
        case .perpetualV1:
            requiredKeys = commonKeys
        case .monthly:
            requiredKeys = commonKeys.union([
                "billing_state", "billing_period_end", "recovery_until", "refresh_after", "exp"
            ])
        }
        guard Set(object.keys) == requiredKeys else {
            throw EntitlementVerificationError.unsupportedClaims
        }

        guard case let .string(issuer)? = object["iss"],
              case let .string(audience)? = object["aud"],
              case let .string(licenseID)? = object["sub"],
              case let .string(entitlementID)? = object["jti"],
              case let .integer(issuedAt)? = object["iat"],
              case let .integer(schema)? = object["schema"],
              case let .string(activationID)? = object["activation_id"],
              case let .string(installationIDValue)? = object["installation_id"],
              let claimedInstallationID = UUID(uuidString: installationIDValue),
              case let .integer(revision)? = object["revision"],
              case let .string(releaseScopeValue)? = object["release_scope"],
              let releaseScope = EntitlementReleaseScope(rawValue: releaseScopeValue),
              case let .boolean(securityUpdatesAfterExpiry)? = object["security_updates_after_expiry"],
              issuer == Self.issuer,
              audience == Self.audience,
              schema == 1,
              revision > 0,
              isValidOpaqueID(licenseID),
              isValidOpaqueID(entitlementID),
              isValidOpaqueID(activationID),
              issuedAt >= 0 else {
            throw EntitlementVerificationError.unsupportedClaims
        }

        guard claimedInstallationID == installationID else {
            throw EntitlementVerificationError.installationMismatch
        }
        if let highestAcceptedRevision, revision < highestAcceptedRevision {
            throw EntitlementVerificationError.staleRevision
        }
        let (latestAcceptedIssueTime, overflow) = effectiveTime.addingReportingOverflow(
            Self.maximumFutureSkewSeconds
        )
        guard !overflow, issuedAt <= latestAcceptedIssueTime else {
            throw EntitlementVerificationError.issuedInFuture
        }

        switch plan {
        case .perpetualV1:
            guard releaseScope == .v1, !securityUpdatesAfterExpiry else {
                throw EntitlementVerificationError.unsupportedClaims
            }
            return EntitlementClaims(
                issuer: issuer,
                audience: audience,
                licenseID: licenseID,
                entitlementID: entitlementID,
                issuedAt: issuedAt,
                schema: schema,
                plan: plan,
                activationID: activationID,
                installationID: claimedInstallationID,
                revision: revision,
                releaseScope: releaseScope,
                securityUpdatesAfterExpiry: securityUpdatesAfterExpiry
            )
        case .monthly:
            return try parseMonthlyClaims(
                object,
                issuer: issuer,
                audience: audience,
                licenseID: licenseID,
                entitlementID: entitlementID,
                issuedAt: issuedAt,
                schema: schema,
                activationID: activationID,
                installationID: claimedInstallationID,
                revision: revision,
                releaseScope: releaseScope,
                securityUpdatesAfterExpiry: securityUpdatesAfterExpiry
            )
        }
    }

    private func parseMonthlyClaims(
        _ object: [String: StrictJSONValue],
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
        securityUpdatesAfterExpiry: Bool
    ) throws -> EntitlementClaims {
        guard releaseScope == .current,
              case let .string(billingStateValue)? = object["billing_state"],
              let billingState = MonthlyBillingState(rawValue: billingStateValue),
              case let .integer(billingPeriodEnd)? = object["billing_period_end"],
              case let .integer(recoveryUntil)? = object["recovery_until"],
              case let .integer(refreshAfter)? = object["refresh_after"],
              case let .integer(expiresAt)? = object["exp"],
              billingPeriodEnd >= 0,
              issuedAt <= refreshAfter,
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
            issuer: issuer,
            audience: audience,
            licenseID: licenseID,
            entitlementID: entitlementID,
            issuedAt: issuedAt,
            schema: schema,
            plan: .monthly,
            activationID: activationID,
            installationID: installationID,
            revision: revision,
            releaseScope: releaseScope,
            securityUpdatesAfterExpiry: securityUpdatesAfterExpiry,
            billingState: billingState,
            billingPeriodEnd: billingPeriodEnd,
            recoveryUntil: recoveryUntil,
            refreshAfter: refreshAfter,
            expiresAt: expiresAt
        )
    }

    private func isValidOpaqueID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256
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
        guard let data = Data(base64Encoded: encoded),
              encodeBase64URL(data) == value else {
            throw EntitlementVerificationError.invalidBase64URL
        }
        return data
    }

    private func encodeBase64URL(_ data: Data) -> Substring {
        Substring(
            data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        )
    }
}
