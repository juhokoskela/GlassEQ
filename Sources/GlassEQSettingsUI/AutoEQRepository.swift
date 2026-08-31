import Foundation
import GlassEQSettingsIPC

struct AutoEQCatalogueEntry: Equatable, Hashable, Identifiable, Sendable {
    let name: String
    let encodedResultPath: String
    let source: String
    let form: String?

    var id: String { encodedResultPath }

    var detail: String {
        if let form {
            return "\(source) · \(form)"
        }
        return source
    }
}

enum AutoEQProfileKind: String, CaseIterable, Identifiable, Sendable {
    case responseCurve
    case parametric

    var id: String { rawValue }

    var fileSuffix: String {
        switch self {
        case .responseCurve:
            "GraphicEQ.txt"
        case .parametric:
            "ParametricEQ.txt"
        }
    }
}

enum AutoEQRepositoryError: Error, LocalizedError, Equatable {
    case invalidResponse
    case catalogueTooLarge
    case profileTooLarge
    case emptyCatalogue
    case invalidResultPath(String)
    case unreadableText

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "AutoEq returned an unexpected response. Try again in a moment."
        case .catalogueTooLarge:
            "The AutoEq catalogue was larger than GlassEQ can safely load."
        case .profileTooLarge:
            "The selected AutoEq profile was larger than GlassEQ can safely load."
        case .emptyCatalogue:
            "No headphone profiles were found in the AutoEq catalogue."
        case .invalidResultPath:
            "The selected AutoEq result has an invalid download path."
        case .unreadableText:
            "AutoEq returned text that GlassEQ could not read."
        }
    }
}

enum AutoEQCatalogueParser {
    static let maximumEntryCount = 10_000
    private static let maximumNameUTF8Bytes = 512
    private static let maximumPathUTF8Bytes = 2_048
    private static let maximumPathComponentUTF8Bytes = 512

    static func parse(
        _ markdown: String,
        maximumEntryCount: Int = Self.maximumEntryCount
    ) throws -> [AutoEQCatalogueEntry] {
        var entries: [AutoEQCatalogueEntry] = []
        entries.reserveCapacity(min(6_500, maximumEntryCount))
        var seenPaths: Set<String> = []
        seenPaths.reserveCapacity(min(6_500, maximumEntryCount))

        for rawLine in markdown.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("- ["),
                  let nameEnd = line.range(of: "]("),
                  line.hasSuffix(")") else {
                continue
            }

            let nameStart = line.index(line.startIndex, offsetBy: 3)
            let name = String(line[nameStart..<nameEnd.lowerBound])
            let pathStart = nameEnd.upperBound
            let pathEnd = line.index(before: line.endIndex)
            var path = String(line[pathStart..<pathEnd])
            guard path.hasPrefix("./") else {
                continue
            }
            path.removeFirst(2)

            guard !name.isEmpty,
                  name.utf8.count <= maximumNameUTF8Bytes,
                  path.utf8.count <= maximumPathUTF8Bytes,
                  isSafeResultPath(path),
                  seenPaths.insert(path).inserted else {
                continue
            }

            let decodedComponents = path
                .split(separator: "/")
                .map { String($0).removingPercentEncoding ?? String($0) }
            guard let source = decodedComponents.first, !source.isEmpty else {
                continue
            }

            let form = decodedComponents.lazy.compactMap { component -> String? in
                let lowercased = component.lowercased()
                if lowercased.contains("over-ear") {
                    return "Over-ear"
                }
                if lowercased.contains("in-ear") {
                    return "In-ear"
                }
                return nil
            }.first

            guard entries.count < maximumEntryCount else {
                throw AutoEQRepositoryError.catalogueTooLarge
            }
            entries.append(AutoEQCatalogueEntry(
                name: name,
                encodedResultPath: path,
                source: source,
                form: form
            ))
        }

        guard !entries.isEmpty else {
            throw AutoEQRepositoryError.emptyCatalogue
        }
        return entries
    }

    static func isSafeResultPath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/") else {
            return false
        }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            let component = String($0).removingPercentEncoding ?? String($0)
            return !component.isEmpty
                && component.utf8.count <= maximumPathComponentUTF8Bytes
                && component != "."
                && component != ".."
                && !component.contains("/")
                && !component.contains("\\")
        }
    }
}

struct AutoEQRepositoryClient: Sendable {
    private static let catalogueURL = URL(
        string: "https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/results/README.md"
    )!
    private static let resultRoot =
        "https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/results/"
    private static let defaultMaximumCatalogueBytes = 2_000_000
    private static let defaultMaximumProfileBytes = 1_048_576

    private let session: URLSession
    private let maximumCatalogueBytes: Int
    private let maximumProfileBytes: Int

    init(
        session: URLSession = .shared,
        maximumCatalogueBytes: Int = Self.defaultMaximumCatalogueBytes,
        maximumProfileBytes: Int = Self.defaultMaximumProfileBytes
    ) {
        self.session = session
        self.maximumCatalogueBytes = maximumCatalogueBytes
        self.maximumProfileBytes = maximumProfileBytes
    }

    func catalogue() async throws -> [AutoEQCatalogueEntry] {
        let data = try await download(
            Self.catalogueURL,
            maximumBytes: maximumCatalogueBytes,
            tooLargeError: .catalogueTooLarge
        )
        guard let markdown = String(data: data, encoding: .utf8) else {
            throw AutoEQRepositoryError.unreadableText
        }
        return try AutoEQCatalogueParser.parse(markdown)
    }

    func profileText(
        for entry: AutoEQCatalogueEntry,
        kind: AutoEQProfileKind
    ) async throws -> String {
        let url = try Self.profileURL(for: entry, kind: kind)
        let data = try await download(
            url,
            maximumBytes: maximumProfileBytes,
            tooLargeError: .profileTooLarge
        )
        guard let text = String(data: data, encoding: .utf8) else {
            throw AutoEQRepositoryError.unreadableText
        }
        return text
    }

    static func profileURL(
        for entry: AutoEQCatalogueEntry,
        kind: AutoEQProfileKind
    ) throws -> URL {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/%?#")
        guard AutoEQCatalogueParser.isSafeResultPath(entry.encodedResultPath),
              let encodedDirectoryName = entry.encodedResultPath.split(separator: "/").last,
              let directoryName = String(encodedDirectoryName).removingPercentEncoding,
              !directoryName.isEmpty else {
            throw AutoEQRepositoryError.invalidResultPath(entry.encodedResultPath)
        }
        let filename = "\(directoryName) \(kind.fileSuffix)"
        guard
              let encodedFilename = filename.addingPercentEncoding(
                  withAllowedCharacters: allowed
              ),
              let url = URL(string:
                  Self.resultRoot
                      + entry.encodedResultPath
                      + "/"
                      + encodedFilename
              ) else {
            throw AutoEQRepositoryError.invalidResultPath(entry.encodedResultPath)
        }
        return url
    }

    private func download(
        _ url: URL,
        maximumBytes: Int,
        tooLargeError: AutoEQRepositoryError
    ) async throws -> Data {
        var request = URLRequest(
            url: url,
            cachePolicy: .useProtocolCachePolicy,
            timeoutInterval: 20
        )
        request.setValue("text/plain, text/markdown", forHTTPHeaderField: "Accept")
        let delegate = AutoEQBoundedDownloadDelegate(
            maximumBytes: maximumBytes,
            tooLargeError: tooLargeError
        )
        let boundedSession = URLSession(
            configuration: session.configuration,
            delegate: delegate,
            delegateQueue: nil
        )
        defer { boundedSession.finishTasksAndInvalidate() }
        return try await delegate.download(request, using: boundedSession)
    }
}

private final class AutoEQBoundedDownloadDelegate: NSObject,
    URLSessionDataDelegate,
    @unchecked Sendable {
    private struct State {
        var data = Data()
        var continuation: CheckedContinuation<Data, Error>?
        var task: URLSessionDataTask?
        var terminalError: Error?
        var acceptedResponse = false
        var cancelled = false
    }

    private let maximumBytes: Int
    private let tooLargeError: AutoEQRepositoryError
    private let lock = NSLock()
    private var state = State()

    init(maximumBytes: Int, tooLargeError: AutoEQRepositoryError) {
        self.maximumBytes = maximumBytes
        self.tooLargeError = tooLargeError
    }

    func download(_ request: URLRequest, using session: URLSession) async throws -> Data {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                guard !state.cancelled else {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let task = session.dataTask(with: request)
                state.continuation = continuation
                state.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        lock.lock()
        let disposition: URLSession.ResponseDisposition
        if let response = response as? HTTPURLResponse,
           response.statusCode == 200 {
            if response.expectedContentLength > Int64(maximumBytes) {
                state.terminalError = tooLargeError
                disposition = .cancel
            } else {
                state.acceptedResponse = true
                if response.expectedContentLength > 0 {
                    state.data.reserveCapacity(Int(response.expectedContentLength))
                }
                disposition = .allow
            }
        } else {
            state.terminalError = AutoEQRepositoryError.invalidResponse
            disposition = .cancel
        }
        lock.unlock()
        completionHandler(disposition)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        lock.lock()
        let shouldCancel: Bool
        if state.terminalError == nil,
           data.count <= maximumBytes - state.data.count {
            state.data.append(data)
            shouldCancel = false
        } else {
            if state.terminalError == nil {
                state.terminalError = tooLargeError
            }
            shouldCancel = true
        }
        lock.unlock()
        if shouldCancel {
            dataTask.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        lock.lock()
        guard let continuation = state.continuation else {
            lock.unlock()
            return
        }
        state.continuation = nil
        let result: Result<Data, Error>
        if let terminalError = state.terminalError {
            result = .failure(terminalError)
        } else if state.cancelled {
            result = .failure(CancellationError())
        } else if let error {
            result = .failure(error)
        } else if !state.acceptedResponse {
            result = .failure(AutoEQRepositoryError.invalidResponse)
        } else {
            result = .success(state.data)
        }
        lock.unlock()
        continuation.resume(with: result)
    }

    private func cancel() {
        lock.lock()
        state.cancelled = true
        let task = state.task
        lock.unlock()
        task?.cancel()
    }
}

enum ImportedEQTextDetector {
    static func format(for text: String) -> SettingsImportFormat {
        let lowercased = text.lowercased()
        if lowercased.contains("room eq wizard")
            || lowercased.contains("equaliser: generic")
            || lowercased.contains("filter settings file")
            || lowercased.contains(" on modal ") {
            return .rew
        }
        return .autoEQ
    }
}
