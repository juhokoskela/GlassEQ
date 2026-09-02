import Foundation

public struct ActivationResponse: Equatable, Sendable {
    public let activationToken: String
    public let entitlement: String

    public init(activationToken: String, entitlement: String) {
        self.activationToken = activationToken
        self.entitlement = entitlement
    }
}

/// The activation-lifecycle calls the licensing controller depends on.
public protocol LicenseServicing: Sendable {
    func activate(
        licenseKey: String,
        installationID: UUID,
        idempotencyKey: UUID
    ) async throws(LicenseServiceError) -> ActivationResponse
    func refresh(activationToken: String, installationID: UUID) async throws(LicenseServiceError) -> String
    func deactivateCurrent(activationToken: String) async throws(LicenseServiceError)
}

public enum LicenseServiceErrorCode: Equatable, Sendable {
    case invalidRequest
    case invalidCredentials
    case activationLimit
    case activationRevoked
    case licenseNotEligible
    case releaseNotEligible
    case idempotencyConflict
    case rateLimited
    case temporarilyUnavailable
    case unknown(String)

    init(rawValue: String) {
        switch rawValue {
        case "invalid_request": self = .invalidRequest
        case "invalid_credentials": self = .invalidCredentials
        case "activation_limit": self = .activationLimit
        case "activation_revoked": self = .activationRevoked
        case "license_not_eligible": self = .licenseNotEligible
        case "release_not_eligible": self = .releaseNotEligible
        case "idempotency_conflict": self = .idempotencyConflict
        case "rate_limited": self = .rateLimited
        case "temporarily_unavailable": self = .temporarilyUnavailable
        default: self = .unknown(String(rawValue.prefix(64)))
        }
    }
}

public enum LicenseTransportFailure: Equatable, Sendable {
    case offline
    case timedOut
    case other
}

public enum LicenseServiceError: Error, Equatable, Sendable {
    case invalidLicenseKey
    case service(
        code: LicenseServiceErrorCode,
        retryAfterSeconds: Int?
    )
    case transport(LicenseTransportFailure)
    case cancelled
    case malformedResponse
    case unexpectedStatus(Int)
    case redirected
}

/// Fixed-origin HTTPS client for `https://license.glasseq.app`. Credentials travel only in JSON
/// bodies or the `Authorization` header, redirects are refused, and response bodies are bounded.
public struct LicenseServiceClient: LicenseServicing {
    public static let origin = URL(string: "https://license.glasseq.app")!
    public static let maximumResponseBytes = 16 * 1_024
    public static let maximumLicenseKeyBytes = 64
    static let requestTimeout: TimeInterval = 30
    static let minimumRetryAfterSeconds = 1
    static let maximumRetryAfterSeconds = 60 * 60

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func activate(
        licenseKey: String,
        installationID: UUID,
        idempotencyKey: UUID
    ) async throws(LicenseServiceError) -> ActivationResponse {
        let key = licenseKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.utf8.count <= Self.maximumLicenseKeyBytes else {
            throw LicenseServiceError.invalidLicenseKey
        }
        var request = makeRequest(
            method: "POST",
            path: "/v1/activations",
            body: try Self.encode(
                ActivationRequestBody(licenseKey: key, installationID: installationID.uuidString)
            )
        )
        request.setValue(idempotencyKey.uuidString, forHTTPHeaderField: "Idempotency-Key")
        let data = try await perform(request, accepting: [200, 201])
        let body = try Self.decode(ActivationResponseBody.self, from: data)
        guard Self.isBoundedCredential(body.activationToken),
              Self.isBoundedEntitlement(body.entitlement) else {
            throw LicenseServiceError.malformedResponse
        }
        return ActivationResponse(activationToken: body.activationToken, entitlement: body.entitlement)
    }

    public func refresh(activationToken: String, installationID: UUID) async throws(LicenseServiceError) -> String {
        var request = makeRequest(
            method: "POST",
            path: "/v1/entitlements/refresh",
            body: try Self.encode(RefreshRequestBody(installationID: installationID.uuidString))
        )
        request.setValue("Bearer \(activationToken)", forHTTPHeaderField: "Authorization")
        let data = try await perform(request, accepting: [200])
        let body = try Self.decode(RefreshResponseBody.self, from: data)
        guard Self.isBoundedEntitlement(body.entitlement) else {
            throw LicenseServiceError.malformedResponse
        }
        return body.entitlement
    }

    public func deactivateCurrent(activationToken: String) async throws(LicenseServiceError) {
        var request = makeRequest(method: "DELETE", path: "/v1/activations/current", body: nil)
        request.setValue("Bearer \(activationToken)", forHTTPHeaderField: "Authorization")
        _ = try await perform(request, accepting: [204])
    }

    private func makeRequest(method: String, path: String, body: Data?) -> URLRequest {
        var request = URLRequest(
            url: Self.origin.appending(path: path),
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: Self.requestTimeout
        )
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        return request
    }

    private func perform(
        _ request: URLRequest,
        accepting statuses: Set<Int>
    ) async throws(LicenseServiceError) -> Data {
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(
                for: request,
                delegate: RedirectRefusingDelegate()
            )
        } catch {
            if Task.isCancelled {
                throw .cancelled
            }
            throw Self.transportError(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw .malformedResponse
        }
        if (300 ..< 400).contains(http.statusCode) {
            throw .redirected
        }
        guard http.expectedContentLength <= Int64(Self.maximumResponseBytes) else {
            throw .malformedResponse
        }
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                guard data.count <= Self.maximumResponseBytes else {
                    throw LicenseServiceError.malformedResponse
                }
            }
        } catch let error as LicenseServiceError {
            throw error
        } catch {
            if Task.isCancelled {
                throw .cancelled
            }
            throw Self.transportError(error)
        }
        guard statuses.contains(http.statusCode) else {
            throw Self.error(status: http.statusCode, data: data, response: http)
        }
        return data
    }

    private static func error(status: Int, data: Data, response: HTTPURLResponse) -> LicenseServiceError {
        guard status >= 400,
              let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data) else {
            return .unexpectedStatus(status)
        }
        var retryAfter: Int?
        if let header = response.value(forHTTPHeaderField: "Retry-After"), let seconds = Int(header) {
            retryAfter = min(max(seconds, minimumRetryAfterSeconds), maximumRetryAfterSeconds)
        }
        return .service(
            code: LicenseServiceErrorCode(rawValue: envelope.error.code),
            retryAfterSeconds: retryAfter
        )
    }

    private static func transportError(_ error: any Error) -> LicenseServiceError {
        guard let urlError = error as? URLError else {
            return .transport(.other)
        }
        switch urlError.code {
        case .cancelled:
            return .transport(.other)
        case .timedOut:
            return .transport(.timedOut)
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed,
             .internationalRoamingOff, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return .transport(.offline)
        default:
            return .transport(.other)
        }
    }

    private static func encode<Value: Encodable>(_ value: Value) throws(LicenseServiceError) -> Data {
        do {
            return try JSONEncoder().encode(value)
        } catch {
            throw .malformedResponse
        }
    }

    private static func decode<Value: Decodable>(
        _ type: Value.Type,
        from data: Data
    ) throws(LicenseServiceError) -> Value {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw LicenseServiceError.malformedResponse
        }
    }

    private static func isBoundedCredential(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256
    }

    private static func isBoundedEntitlement(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= EntitlementVerifier.maximumTokenBytes
    }
}

private struct ActivationRequestBody: Encodable {
    let licenseKey: String
    let installationID: String

    enum CodingKeys: String, CodingKey {
        case licenseKey = "license_key"
        case installationID = "installation_id"
    }
}

private struct RefreshRequestBody: Encodable {
    let installationID: String

    enum CodingKeys: String, CodingKey {
        case installationID = "installation_id"
    }
}

private struct ActivationResponseBody: Decodable {
    let activationToken: String
    let entitlement: String

    enum CodingKeys: String, CodingKey {
        case activationToken = "activation_token"
        case entitlement
    }
}

private struct RefreshResponseBody: Decodable {
    let entitlement: String
}

private struct ErrorEnvelope: Decodable {
    struct Body: Decodable {
        let code: String
    }

    let error: Body
}

private final class RedirectRefusingDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}
