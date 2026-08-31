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
    static func parse(_ markdown: String) throws -> [AutoEQCatalogueEntry] {
        var entries: [AutoEQCatalogueEntry] = []
        entries.reserveCapacity(6_500)

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

            guard !name.isEmpty, isSafeResultPath(path) else {
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
                && component != "."
                && component != ".."
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
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let response = response as? HTTPURLResponse,
              response.statusCode == 200 else {
            throw AutoEQRepositoryError.invalidResponse
        }

        var data = Data()
        if response.expectedContentLength > 0 {
            data.reserveCapacity(min(
                maximumBytes,
                Int(clamping: response.expectedContentLength)
            ))
        }
        for try await byte in bytes {
            guard data.count < maximumBytes else {
                throw tooLargeError
            }
            data.append(byte)
        }
        return data
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
