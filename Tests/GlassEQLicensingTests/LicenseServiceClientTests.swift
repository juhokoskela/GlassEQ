import Foundation
import Testing
@testable import GlassEQLicensing

@Suite(.serialized)
struct LicenseServiceClientTests {
    private let installationID = UUID(uuidString: "4E70638A-3AB2-4D21-A4AB-0B2525F80D42")!
    private let idempotencyKey = UUID(uuidString: "2B1BC1BA-407A-49F2-AD2E-A260A56BCF23")!

    @Test
    func activationSendsTheDocumentedRequestAndParsesTheResponse() async throws {
        let session = LicenseTestURLProtocol.makeSession()
        defer { LicenseTestURLProtocol.reset() }
        LicenseTestURLProtocol.enqueue(.json(
            status: 201,
            body: #"{"activation_token":"gea_abc","entitlement":"e.y.j"}"#
        ))

        let response = try await LicenseServiceClient(session: session).activate(
            licenseKey: "  GEQ1-ABCD-EFGH  ",
            installationID: installationID,
            idempotencyKey: idempotencyKey
        )

        #expect(response == ActivationResponse(activationToken: "gea_abc", entitlement: "e.y.j"))
        let request = try #require(LicenseTestURLProtocol.requests.first)
        #expect(request.url == URL(string: "https://license.glasseq.app/v1/activations"))
        #expect(request.method == "POST")
        #expect(request.headers["Content-Type"] == "application/json")
        #expect(request.headers["Accept"] == "application/json")
        #expect(request.headers["Idempotency-Key"] == idempotencyKey.uuidString)
        #expect(request.headers["Authorization"] == nil)
        let body = try JSONDecoder().decode([String: String].self, from: request.body)
        #expect(body == ["license_key": "GEQ1-ABCD-EFGH", "installation_id": installationID.uuidString])
    }

    @Test
    func activationAcceptsAReplayedTwoHundred() async throws {
        let session = LicenseTestURLProtocol.makeSession()
        defer { LicenseTestURLProtocol.reset() }
        LicenseTestURLProtocol.enqueue(.json(
            status: 200,
            body: #"{"activation_token":"gea_abc","entitlement":"e.y.j"}"#
        ))

        let response = try await LicenseServiceClient(session: session).activate(
            licenseKey: "GEQ1-ABCD",
            installationID: installationID,
            idempotencyKey: idempotencyKey
        )

        #expect(response.activationToken == "gea_abc")
    }

    @Test
    func invalidLicenseKeysNeverReachTheNetwork() async throws {
        let session = LicenseTestURLProtocol.makeSession()
        defer { LicenseTestURLProtocol.reset() }
        let client = LicenseServiceClient(session: session)
        let tooLong = String(repeating: "A", count: LicenseServiceClient.maximumLicenseKeyBytes + 1)

        await #expect(throws: LicenseServiceError.invalidLicenseKey) {
            try await client.activate(licenseKey: "   ", installationID: installationID, idempotencyKey: idempotencyKey)
        }
        await #expect(throws: LicenseServiceError.invalidLicenseKey) {
            try await client.activate(licenseKey: tooLong, installationID: installationID, idempotencyKey: idempotencyKey)
        }
        #expect(LicenseTestURLProtocol.requests.isEmpty)
    }

    @Test
    func refreshSendsTheBearerTokenOnlyInTheHeader() async throws {
        let session = LicenseTestURLProtocol.makeSession()
        defer { LicenseTestURLProtocol.reset() }
        LicenseTestURLProtocol.enqueue(.json(status: 200, body: #"{"entitlement":"e.y.j"}"#))

        let entitlement = try await LicenseServiceClient(session: session).refresh(
            activationToken: "gea_secret",
            installationID: installationID
        )

        #expect(entitlement == "e.y.j")
        let request = try #require(LicenseTestURLProtocol.requests.first)
        #expect(request.url == URL(string: "https://license.glasseq.app/v1/entitlements/refresh"))
        #expect(request.method == "POST")
        #expect(request.headers["Authorization"] == "Bearer gea_secret")
        #expect(request.url?.absoluteString.contains("gea_secret") == false)
        let body = try JSONDecoder().decode([String: String].self, from: request.body)
        #expect(body == ["installation_id": installationID.uuidString])
    }

    @Test
    func deactivationExpectsNoContent() async throws {
        let session = LicenseTestURLProtocol.makeSession()
        defer { LicenseTestURLProtocol.reset() }
        LicenseTestURLProtocol.enqueue(.init(status: 204, headers: [:], body: Data()))

        try await LicenseServiceClient(session: session).deactivateCurrent(activationToken: "gea_secret")

        let request = try #require(LicenseTestURLProtocol.requests.first)
        #expect(request.url == URL(string: "https://license.glasseq.app/v1/activations/current"))
        #expect(request.method == "DELETE")
        #expect(request.headers["Authorization"] == "Bearer gea_secret")
        #expect(request.body.isEmpty)
    }

    @Test(arguments: [
        ("invalid_request", LicenseServiceErrorCode.invalidRequest, false),
        ("invalid_credentials", .invalidCredentials, false),
        ("activation_limit", .activationLimit, false),
        ("activation_revoked", .activationRevoked, false),
        ("license_not_eligible", .licenseNotEligible, false),
        ("release_not_eligible", .releaseNotEligible, false),
        ("idempotency_conflict", .idempotencyConflict, false),
        ("temporarily_unavailable", .temporarilyUnavailable, true),
        ("brand_new_code", .unknown("brand_new_code"), true)
    ])
    func errorEnvelopesMapToStableCodes(
        rawCode: String,
        expected: LicenseServiceErrorCode,
        retryable: Bool
    ) async throws {
        let session = LicenseTestURLProtocol.makeSession()
        defer { LicenseTestURLProtocol.reset() }
        LicenseTestURLProtocol.enqueue(.json(
            status: 403,
            body: #"{"error":{"code":"\#(rawCode)","message":"ignored","retryable":\#(retryable),"request_id":"req_01"}}"#
        ))

        await #expect(throws: LicenseServiceError.service(
            code: expected,
            retryAfterSeconds: nil
        )) {
            try await LicenseServiceClient(session: session).refresh(
                activationToken: "gea_secret",
                installationID: installationID
            )
        }
    }

    @Test(arguments: [("120", 120), ("0", 1), ("999999", 3_600), ("soon", nil)])
    func rateLimitingClampsRetryAfter(header: String, expected: Int?) async throws {
        let session = LicenseTestURLProtocol.makeSession()
        defer { LicenseTestURLProtocol.reset() }
        LicenseTestURLProtocol.enqueue(.init(
            status: 429,
            headers: ["Retry-After": header, "Content-Type": "application/json"],
            body: Data(#"{"error":{"code":"rate_limited","message":"","retryable":true}}"#.utf8)
        ))

        await #expect(throws: LicenseServiceError.service(
            code: .rateLimited,
            retryAfterSeconds: expected
        )) {
            try await LicenseServiceClient(session: session).refresh(
                activationToken: "gea_secret",
                installationID: installationID
            )
        }
    }

    @Test
    func retryAfterLookupIsCaseInsensitive() async throws {
        let session = LicenseTestURLProtocol.makeSession()
        defer { LicenseTestURLProtocol.reset() }
        LicenseTestURLProtocol.enqueue(.init(
            status: 503,
            headers: ["retry-after": "120", "content-type": "application/json"],
            body: Data(#"{"error":{"code":"temporarily_unavailable","message":"","retryable":true}}"#.utf8)
        ))

        await #expect(throws: LicenseServiceError.service(
            code: .temporarilyUnavailable,
            retryAfterSeconds: 120
        )) {
            try await LicenseServiceClient(session: session).refresh(
                activationToken: "gea_secret",
                installationID: installationID
            )
        }
    }

    @Test(arguments: [
        (URLError.Code.notConnectedToInternet, LicenseServiceError.transport(.offline)),
        (.cannotConnectToHost, .transport(.offline)),
        (.dnsLookupFailed, .transport(.offline)),
        (.timedOut, .transport(.timedOut)),
        (.cancelled, .transport(.other)),
        (.badServerResponse, .transport(.other))
    ])
    func transportFailuresAreClassified(code: URLError.Code, expected: LicenseServiceError) async throws {
        let session = LicenseTestURLProtocol.makeSession()
        defer { LicenseTestURLProtocol.reset() }
        LicenseTestURLProtocol.enqueueFailure(URLError(code))

        await #expect(throws: expected) {
            try await LicenseServiceClient(session: session).refresh(
                activationToken: "gea_secret",
                installationID: installationID
            )
        }
    }

    @Test
    func oversizedAndUnparseableBodiesAreMalformed() async throws {
        let session = LicenseTestURLProtocol.makeSession()
        defer { LicenseTestURLProtocol.reset() }
        let client = LicenseServiceClient(session: session)
        let oversized = Data(repeating: 0x61, count: LicenseServiceClient.maximumResponseBytes + 1)

        LicenseTestURLProtocol.enqueue(.init(status: 200, headers: [:], body: oversized))
        await #expect(throws: LicenseServiceError.malformedResponse) {
            try await client.refresh(activationToken: "gea_secret", installationID: installationID)
        }

        LicenseTestURLProtocol.enqueue(.init(status: 200, headers: [:], body: oversized, chunked: true))
        await #expect(throws: LicenseServiceError.malformedResponse) {
            try await client.refresh(activationToken: "gea_secret", installationID: installationID)
        }

        LicenseTestURLProtocol.enqueue(.json(status: 200, body: "not json"))
        await #expect(throws: LicenseServiceError.malformedResponse) {
            try await client.refresh(activationToken: "gea_secret", installationID: installationID)
        }

        LicenseTestURLProtocol.enqueue(.json(status: 200, body: #"{"entitlement":""}"#))
        await #expect(throws: LicenseServiceError.malformedResponse) {
            try await client.refresh(activationToken: "gea_secret", installationID: installationID)
        }
    }

    @Test
    func unexpectedStatusesWithoutAnEnvelopeAreReported() async throws {
        let session = LicenseTestURLProtocol.makeSession()
        defer { LicenseTestURLProtocol.reset() }
        LicenseTestURLProtocol.enqueue(.init(status: 502, headers: [:], body: Data("bad gateway".utf8)))

        await #expect(throws: LicenseServiceError.unexpectedStatus(502)) {
            try await LicenseServiceClient(session: session).refresh(
                activationToken: "gea_secret",
                installationID: installationID
            )
        }
    }

    @Test
    func redirectsAreRefusedWithoutASecondRequest() async throws {
        let session = LicenseTestURLProtocol.makeSession()
        defer { LicenseTestURLProtocol.reset() }
        LicenseTestURLProtocol.enqueue(.init(
            status: 302,
            headers: ["Location": "https://evil.example/v1/entitlements/refresh"],
            body: Data()
        ))
        LicenseTestURLProtocol.enqueue(.json(status: 200, body: #"{"entitlement":"e.y.j"}"#))

        await #expect(throws: LicenseServiceError.redirected) {
            try await LicenseServiceClient(session: session).refresh(
                activationToken: "gea_secret",
                installationID: installationID
            )
        }
        #expect(LicenseTestURLProtocol.requests.count == 1)
    }
}

// MARK: - URLProtocol stub

struct LicenseTestResponse: Sendable {
    let status: Int
    let headers: [String: String]
    let body: Data
    var chunked = false

    static func json(status: Int, body: String) -> LicenseTestResponse {
        LicenseTestResponse(
            status: status,
            headers: ["Content-Type": "application/json"],
            body: Data(body.utf8)
        )
    }
}

struct LicenseTestRecordedRequest: Sendable {
    let url: URL?
    let method: String?
    let headers: [String: String]
    let body: Data
}

final class LicenseTestURLProtocol: URLProtocol, @unchecked Sendable {
    private enum Outcome {
        case response(LicenseTestResponse)
        case failure(URLError)
    }

    private final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var queue: [Outcome] = []
        var recorded: [LicenseTestRecordedRequest] = []
    }

    private static let storage = Storage()

    static var requests: [LicenseTestRecordedRequest] { storage.lock.withLock { storage.recorded } }

    static func makeSession() -> URLSession {
        reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LicenseTestURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func enqueue(_ response: LicenseTestResponse) {
        storage.lock.withLock { storage.queue.append(.response(response)) }
    }

    static func enqueueFailure(_ error: URLError) {
        storage.lock.withLock { storage.queue.append(.failure(error)) }
    }

    static func reset() {
        storage.lock.withLock {
            storage.queue.removeAll()
            storage.recorded.removeAll()
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let storage = Self.storage
        let outcome = storage.lock.withLock { () -> Outcome? in
            storage.recorded.append(LicenseTestRecordedRequest(
                url: request.url,
                method: request.httpMethod,
                headers: request.allHTTPHeaderFields ?? [:],
                body: Self.readBody(request)
            ))
            return storage.queue.isEmpty ? nil : storage.queue.removeFirst()
        }
        guard let outcome, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        switch outcome {
        case let .failure(error):
            client?.urlProtocol(self, didFailWithError: error)
        case let .response(stub):
            var headers = stub.headers
            if !stub.chunked {
                headers["Content-Length"] = String(stub.body.count)
            }
            guard let response = HTTPURLResponse(
                url: url,
                statusCode: stub.status,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            ) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if stub.chunked {
                for start in stride(from: 0, to: stub.body.count, by: 1_024) {
                    let end = min(start + 1_024, stub.body.count)
                    client?.urlProtocol(self, didLoad: stub.body[start ..< end])
                }
            } else if !stub.body.isEmpty {
                client?.urlProtocol(self, didLoad: stub.body)
            }
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}

    /// URLSession hands protocols the body as a stream rather than as `httpBody`.
    private static func readBody(_ request: URLRequest) -> Data {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return Data()
        }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
