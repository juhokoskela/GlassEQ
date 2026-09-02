import Foundation
import Testing
@testable import GlassEQProfileImport

@Suite
struct AutoEQRepositoryTests {
    @Test
    func autoEQCatalogueParserReadsRecommendedResults() throws {
        let markdown = """
        # Recommended Results
        - [Sennheiser HD 58X](./oratory1990/over-ear/Sennheiser%20HD%2058X)
        - [7Hz Salnotes Zero](./crinacle/711%20in-ear/7Hz%20Salnotes%20Zero)
        """

        let entries = try AutoEQCatalogueParser.parse(markdown)

        #expect(entries == [
            AutoEQCatalogueEntry(
                name: "Sennheiser HD 58X",
                encodedResultPath: "oratory1990/over-ear/Sennheiser%20HD%2058X",
                source: "oratory1990",
                form: "Over-ear"
            ),
            AutoEQCatalogueEntry(
                name: "7Hz Salnotes Zero",
                encodedResultPath: "crinacle/711%20in-ear/7Hz%20Salnotes%20Zero",
                source: "crinacle",
                form: "In-ear"
            )
        ])
    }

    @Test
    func autoEQCatalogueParserDeduplicatesResultPaths() throws {
        let markdown = """
        - [First](./source/over-ear/model)
        - [Duplicate](./source/over-ear/model)
        """

        let entries = try AutoEQCatalogueParser.parse(markdown)

        #expect(entries.map(\.name) == ["First"])
    }

    @Test
    func autoEQCatalogueParserRejectsEntryCountAmplification() {
        let markdown = """
        - [One](./source/over-ear/one)
        - [Two](./source/over-ear/two)
        - [Three](./source/over-ear/three)
        """

        #expect(throws: AutoEQRepositoryError.catalogueTooLarge) {
            _ = try AutoEQCatalogueParser.parse(markdown, maximumEntryCount: 2)
        }
    }

    @Test
    func autoEQCatalogueParserSkipsOversizedAndEncodedSeparatorComponents() throws {
        let longName = String(repeating: "x", count: 513)
        let markdown = """
        - [\(longName)](./source/over-ear/long-name)
        - [Encoded separator](./source%2Fother/over-ear/model)
        - [Valid](./source/over-ear/valid)
        """

        let entries = try AutoEQCatalogueParser.parse(markdown)

        #expect(entries.map(\.name) == ["Valid"])
    }

    @Test
    func autoEQProfileURLPreservesResultPathAndEncodesFilename() throws {
        let entry = AutoEQCatalogueEntry(
            name: "Sennheiser HD 58X",
            encodedResultPath: "oratory1990/over-ear/Sennheiser%20HD%2058X",
            source: "oratory1990",
            form: "Over-ear"
        )

        let responseCurveURL = try AutoEQRepositoryClient.profileURL(
            for: entry,
            kind: .responseCurve
        )
        let parametricURL = try AutoEQRepositoryClient.profileURL(
            for: entry,
            kind: .parametric
        )

        #expect(responseCurveURL.absoluteString.hasSuffix(
            "/Sennheiser%20HD%2058X/Sennheiser%20HD%2058X%20GraphicEQ.txt"
        ))
        #expect(parametricURL.absoluteString.hasSuffix(
            "/Sennheiser%20HD%2058X/Sennheiser%20HD%2058X%20ParametricEQ.txt"
        ))
    }

    @Test
    func autoEQProfileDownloadAcceptsTheExactByteLimit() async throws {
        let entry = autoEQNetworkTestEntry(named: "At Limit")
        let url = try AutoEQRepositoryClient.profileURL(for: entry, kind: .responseCurve)
        let body = Data(repeating: 0x78, count: 32)
        AutoEQTestURLProtocol.register(statusCode: 200, body: body, for: url)
        defer { AutoEQTestURLProtocol.unregister(url) }
        let session = autoEQTestSession()
        defer { session.invalidateAndCancel() }
        let client = AutoEQRepositoryClient(
            session: session,
            maximumProfileBytes: body.count
        )

        let text = try await client.profileText(for: entry, kind: .responseCurve)

        #expect(text == String(repeating: "x", count: body.count))
    }

    @Test
    func autoEQProfileDownloadRejectsTheFirstByteBeyondTheLimit() async throws {
        let entry = autoEQNetworkTestEntry(named: "Too Large")
        let url = try AutoEQRepositoryClient.profileURL(for: entry, kind: .parametric)
        AutoEQTestURLProtocol.register(
            statusCode: 200,
            body: Data(repeating: 0x78, count: 33),
            for: url
        )
        defer { AutoEQTestURLProtocol.unregister(url) }
        let session = autoEQTestSession()
        defer { session.invalidateAndCancel() }
        let client = AutoEQRepositoryClient(
            session: session,
            maximumProfileBytes: 32
        )

        await #expect(throws: AutoEQRepositoryError.profileTooLarge) {
            try await client.profileText(for: entry, kind: .parametric)
        }
    }

    @Test
    func autoEQProfileDownloadBoundsResponsesWithoutAContentLength() async throws {
        let entry = autoEQNetworkTestEntry(named: "Unknown Length")
        let url = try AutoEQRepositoryClient.profileURL(for: entry, kind: .parametric)
        AutoEQTestURLProtocol.register(
            statusCode: 200,
            body: Data(repeating: 0x78, count: 33),
            includesContentLength: false,
            chunkSize: 8,
            for: url
        )
        defer { AutoEQTestURLProtocol.unregister(url) }
        let session = autoEQTestSession()
        defer { session.invalidateAndCancel() }
        let client = AutoEQRepositoryClient(
            session: session,
            maximumProfileBytes: 32
        )

        await #expect(throws: AutoEQRepositoryError.profileTooLarge) {
            try await client.profileText(for: entry, kind: .parametric)
        }
    }

    @Test
    func autoEQCatalogueDownloadUsesItsOwnSizeError() async {
        let url = URL(
            string: "https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/results/README.md"
        )!
        AutoEQTestURLProtocol.register(
            statusCode: 200,
            body: Data(repeating: 0x78, count: 9),
            for: url
        )
        defer { AutoEQTestURLProtocol.unregister(url) }
        let session = autoEQTestSession()
        defer { session.invalidateAndCancel() }
        let client = AutoEQRepositoryClient(
            session: session,
            maximumCatalogueBytes: 8
        )

        await #expect(throws: AutoEQRepositoryError.catalogueTooLarge) {
            try await client.catalogue()
        }
    }

    @Test
    func autoEQDownloadRejectsAnUnsuccessfulHTTPResponse() async throws {
        let entry = autoEQNetworkTestEntry(named: "Unavailable")
        let url = try AutoEQRepositoryClient.profileURL(for: entry, kind: .responseCurve)
        AutoEQTestURLProtocol.register(statusCode: 503, body: Data(), for: url)
        defer { AutoEQTestURLProtocol.unregister(url) }
        let session = autoEQTestSession()
        defer { session.invalidateAndCancel() }
        let client = AutoEQRepositoryClient(session: session)

        await #expect(throws: AutoEQRepositoryError.invalidResponse) {
            try await client.profileText(for: entry, kind: .responseCurve)
        }
    }
}

private func autoEQNetworkTestEntry(named name: String) -> AutoEQCatalogueEntry {
    AutoEQCatalogueEntry(
        name: name,
        encodedResultPath: "test/\(name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!)",
        source: "test",
        form: nil
    )
}

private func autoEQTestSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [AutoEQTestURLProtocol.self]
    return URLSession(configuration: configuration)
}

private struct AutoEQTestURLResponse: Sendable {
    let statusCode: Int
    let body: Data
    let includesContentLength: Bool
    let chunkSize: Int?
}

private final class AutoEQTestURLResponseStore: @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [URL: AutoEQTestURLResponse] = [:]

    func register(_ response: AutoEQTestURLResponse, for url: URL) {
        lock.lock()
        responses[url] = response
        lock.unlock()
    }

    func unregister(_ url: URL) {
        lock.lock()
        responses[url] = nil
        lock.unlock()
    }

    func response(for url: URL) -> AutoEQTestURLResponse? {
        lock.lock()
        defer { lock.unlock() }
        return responses[url]
    }
}

private final class AutoEQTestURLProtocol: URLProtocol, @unchecked Sendable {
    private static let responseStore = AutoEQTestURLResponseStore()

    static func register(
        statusCode: Int,
        body: Data,
        includesContentLength: Bool = true,
        chunkSize: Int? = nil,
        for url: URL
    ) {
        responseStore.register(
            AutoEQTestURLResponse(
                statusCode: statusCode,
                body: body,
                includesContentLength: includesContentLength,
                chunkSize: chunkSize
            ),
            for: url
        )
    }

    static func unregister(_ url: URL) {
        responseStore.unregister(url)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
              let stub = Self.responseStore.response(for: url),
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: stub.statusCode,
                  httpVersion: "HTTP/1.1",
                  headerFields: stub.includesContentLength
                      ? ["Content-Length": String(stub.body.count)]
                      : nil
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let chunkSize = stub.chunkSize {
            for start in stride(from: 0, to: stub.body.count, by: chunkSize) {
                let end = min(start + chunkSize, stub.body.count)
                client?.urlProtocol(self, didLoad: stub.body[start..<end])
            }
        } else {
            client?.urlProtocol(self, didLoad: stub.body)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
