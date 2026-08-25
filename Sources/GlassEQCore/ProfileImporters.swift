import Foundation

public struct ProfileImportLimits: Equatable, Sendable {
    public var maxUTF8Bytes: Int
    public var maxLineCount: Int
    public var maxFiltersPerChannel: Int
    public var maxTotalFilters: Int
    public var maxMagnitudePoints: Int
    public var frequencyRange: ClosedRange<Double>
    public var gainRange: ClosedRange<Double>
    public var preampRange: ClosedRange<Double>
    public var qRange: ClosedRange<Double>

    public init(
        maxUTF8Bytes: Int,
        maxLineCount: Int,
        maxFiltersPerChannel: Int,
        maxTotalFilters: Int,
        frequencyRange: ClosedRange<Double>,
        gainRange: ClosedRange<Double>,
        preampRange: ClosedRange<Double>,
        qRange: ClosedRange<Double>,
        maxMagnitudePoints: Int = 2_048
    ) {
        self.maxUTF8Bytes = maxUTF8Bytes
        self.maxLineCount = maxLineCount
        self.maxFiltersPerChannel = maxFiltersPerChannel
        self.maxTotalFilters = maxTotalFilters
        self.maxMagnitudePoints = maxMagnitudePoints
        self.frequencyRange = frequencyRange
        self.gainRange = gainRange
        self.preampRange = preampRange
        self.qRange = qRange
    }

    public static let `default` = ProfileImportLimits(
        maxUTF8Bytes: 1_048_576,
        maxLineCount: 10_000,
        maxFiltersPerChannel: 128,
        maxTotalFilters: 256,
        frequencyRange: 1...24_000,
        gainRange: -120...120,
        preampRange: -120...120,
        qRange: 0.01...100
    )
}

public enum ProfileImportError: Error, Equatable, Sendable, LocalizedError {
    case noSupportedFilters
    case mixedEqualizerAPOFormats(graphicEQLine: Int, filterLine: Int)
    case unsupportedEqualizerAPOFilter(line: Int, kind: String?)
    case unsupportedEqualizerAPOChannel(line: Int, selectors: String?)
    case multipleEqualizerAPOGraphicEQ(line: Int, channel: String)
    case inputTooLarge(byteCount: Int, maximum: Int)
    case tooManyLines(lineCount: Int, maximum: Int)
    case invalidNumber(line: Int, field: String, value: String)
    case missingNumber(line: Int, field: String)
    case valueOutOfRange(line: Int, field: String, value: Double, range: ClosedRange<Double>)
    case tooManyFilters(line: Int, channel: String, count: Int, maximum: Int)
    case tooManyTotalFilters(line: Int, count: Int, maximum: Int)
    case tooManyMagnitudePoints(line: Int, count: Int, maximum: Int)
    case duplicateMagnitudeFrequency(line: Int, frequency: Double)

    public var errorDescription: String? {
        switch self {
        case .noSupportedFilters:
            return "No supported filters were found in the imported profile."
        case let .mixedEqualizerAPOFormats(graphicEQLine, filterLine):
            return "Line \(graphicEQLine) contains GraphicEQ, but line \(filterLine) contains a Filter directive. Import one EqualizerAPO format at a time."
        case let .unsupportedEqualizerAPOFilter(line, kind):
            if let kind {
                return "Line \(line) uses unsupported enabled EqualizerAPO filter kind \(kind)."
            }
            return "Line \(line) is missing a supported enabled EqualizerAPO filter kind."
        case let .unsupportedEqualizerAPOChannel(line, selectors):
            if let selectors {
                return "Line \(line) selects unsupported EqualizerAPO channels \(selectors)."
            }
            return "Line \(line) is missing an EqualizerAPO channel selector."
        case let .multipleEqualizerAPOGraphicEQ(line, channel):
            return "Line \(line) adds a second GraphicEQ stage to the \(channel) channel, which cannot be imported without changing its response."
        case let .inputTooLarge(byteCount, maximum):
            return "Imported profile is \(byteCount) UTF-8 bytes, which exceeds the \(maximum)-byte limit."
        case let .tooManyLines(lineCount, maximum):
            return "Imported profile has \(lineCount) lines, which exceeds the \(maximum)-line limit."
        case let .invalidNumber(line, field, value):
            return "Line \(line) has an invalid \(field) value: \(value)."
        case let .missingNumber(line, field):
            return "Line \(line) is missing a numeric \(field) value."
        case let .valueOutOfRange(line, field, value, range):
            return "Line \(line) has \(field) \(format(value)), outside the allowed range \(format(range.lowerBound))...\(format(range.upperBound))."
        case let .tooManyFilters(line, channel, count, maximum):
            return "Line \(line) adds filter \(count) to \(channel), which exceeds the \(maximum)-filter channel limit."
        case let .tooManyTotalFilters(line, count, maximum):
            return "Line \(line) adds filter \(count), which exceeds the \(maximum)-filter total limit."
        case let .tooManyMagnitudePoints(line, count, maximum):
            return "Line \(line) contains \(count) magnitude points, which exceeds the \(maximum)-point limit."
        case let .duplicateMagnitudeFrequency(line, frequency):
            return "Line \(line) contains duplicate frequency \(format(frequency))."
        }
    }

    private func format(_ value: Double) -> String {
        String(format: "%g", value)
    }
}

public enum EQProfileTextImporter {
    private enum ImportChannel {
        case linked
        case leftAndRight
        case left
        case right
    }

    public static func importAutoEQ(
        _ text: String,
        profileName: String = "Imported AutoEQ",
        limits: ProfileImportLimits = .default
    ) throws -> EQProfile {
        try validateInput(text, limits: limits)

        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        var graphicEQLine: Int?
        var filterLine: Int?
        for (offset, rawLine) in lines.enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else {
                continue
            }
            if line.lowercased().hasPrefix("graphiceq") {
                graphicEQLine = graphicEQLine ?? offset + 1
            }
            let firstToken = line
                .replacingOccurrences(of: ":", with: " ")
                .split(whereSeparator: \.isWhitespace)
                .first
            if firstToken?.lowercased() == "filter" {
                filterLine = filterLine ?? offset + 1
            }
        }

        if let graphicEQLine, let filterLine {
            throw ProfileImportError.mixedEqualizerAPOFormats(
                graphicEQLine: graphicEQLine,
                filterLine: filterLine
            )
        }

        if graphicEQLine != nil {
            return try importGraphicEQ(
                text,
                profileName: profileName,
                limits: limits
            )
        }

        var filters: [EQFilter] = []
        var leftFilters: [EQFilter] = []
        var rightFilters: [EQFilter] = []
        var preampDB = 0.0
        var leftPreampDB = 0.0
        var rightPreampDB = 0.0
        var importedFilterCount = 0
        var currentChannel = ImportChannel.linked

        for (offset, rawLine) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            let lineNumber = offset + 1
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else {
                continue
            }

            let tokens = line
                .replacingOccurrences(of: ":", with: " ")
                .split(whereSeparator: \.isWhitespace)
                .map(String.init)

            if tokens.first?.caseInsensitiveCompare("Channel") == .orderedSame {
                currentChannel = try importChannel(
                    from: tokens.dropFirst(),
                    line: lineNumber
                )
                continue
            }

            if tokens.first?.caseInsensitiveCompare("Preamp") == .orderedSame,
               let value = try requiredValue(after: "Preamp", in: tokens, field: "preamp", line: lineNumber) {
                try validate(value, in: limits.preampRange, field: "preamp", line: lineNumber)
                try addPreamp(
                    value,
                    to: currentChannel,
                    preampDB: &preampDB,
                    leftPreampDB: &leftPreampDB,
                    rightPreampDB: &rightPreampDB,
                    limits: limits,
                    line: lineNumber
                )
                continue
            }

            guard tokens.first?.caseInsensitiveCompare("Filter") == .orderedSame else {
                continue
            }

            let isEnabled = !tokens.contains { $0.caseInsensitiveCompare("OFF") == .orderedSame }
            guard isEnabled else {
                continue
            }
            let kindToken = value(afterAnyOf: ["ON", "OFF"], in: tokens)
            guard let kindToken,
                  let kind = parseEqualizerAPOKind(kindToken) else {
                throw ProfileImportError.unsupportedEqualizerAPOFilter(
                    line: lineNumber,
                    kind: kindToken
                )
            }

            guard let frequency = try requiredValue(afterAnyOf: ["Fc", "F"], in: tokens, field: "frequency", line: lineNumber) else {
                throw ProfileImportError.missingNumber(line: lineNumber, field: "frequency")
            }
            try validate(frequency, in: limits.frequencyRange, field: "frequency", line: lineNumber)

            let gain = try optionalValue(after: "Gain", in: tokens, field: "gain", line: lineNumber) ?? 0
            try validate(gain, in: limits.gainRange, field: "gain", line: lineNumber)

            let q = try optionalValue(after: "Q", in: tokens, field: "Q", line: lineNumber) ?? 0.707_106_781_18
            try validate(q, in: limits.qRange, field: "Q", line: lineNumber)

            try appendEqualizerAPOFilter(
                EQFilter(kind: kind, frequency: frequency, gainDB: gain, q: q),
                to: currentChannel,
                filters: &filters,
                leftFilters: &leftFilters,
                rightFilters: &rightFilters,
                importedFilterCount: &importedFilterCount,
                line: lineNumber,
                limits: limits
            )
        }

        let hasImportedEffect = !leftFilters.isEmpty
            || !rightFilters.isEmpty
            || leftPreampDB != 0
            || rightPreampDB != 0
        guard hasImportedEffect else {
            throw ProfileImportError.noSupportedFilters
        }

        if preampDB == leftPreampDB,
           preampDB == rightPreampDB,
           filters == leftFilters,
           filters == rightFilters {
            return EQProfile(
                name: profileName,
                mode: inferredMode(filters: leftFilters),
                preampDB: leftPreampDB,
                filters: leftFilters
            )
        }

        return EQProfile(
            name: profileName,
            mode: inferredMode(leftFilters: leftFilters, rightFilters: rightFilters),
            channelMode: .stereo,
            preampDB: preampDB,
            filters: filters,
            leftPreampDB: leftPreampDB,
            leftFilters: leftFilters,
            rightPreampDB: rightPreampDB,
            rightFilters: rightFilters
        )
    }

    private static func importGraphicEQ(
        _ text: String,
        profileName: String,
        limits: ProfileImportLimits
    ) throws -> EQProfile {
        var preampDB = 0.0
        var leftPreampDB = 0.0
        var rightPreampDB = 0.0
        var points: [EQMagnitudePoint]?
        var leftPoints: [EQMagnitudePoint]?
        var rightPoints: [EQMagnitudePoint]?
        var currentChannel = ImportChannel.linked

        for (offset, rawLine) in text.split(
            omittingEmptySubsequences: false,
            whereSeparator: \.isNewline
        ).enumerated() {
            let lineNumber = offset + 1
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else {
                continue
            }

            let tokens = line
                .replacingOccurrences(of: ":", with: " ")
                .split(whereSeparator: \.isWhitespace)
                .map(String.init)

            if tokens.first?.caseInsensitiveCompare("Channel") == .orderedSame {
                currentChannel = try importChannel(
                    from: tokens.dropFirst(),
                    line: lineNumber
                )
                continue
            }

            if line.lowercased().hasPrefix("preamp") {
                guard let value = try requiredValue(
                    after: "Preamp",
                    in: tokens,
                    field: "preamp",
                    line: lineNumber
                ) else {
                    throw ProfileImportError.missingNumber(
                        line: lineNumber,
                        field: "preamp"
                    )
                }
                try validate(
                    value,
                    in: limits.preampRange,
                    field: "preamp",
                    line: lineNumber
                )
                try addPreamp(
                    value,
                    to: currentChannel,
                    preampDB: &preampDB,
                    leftPreampDB: &leftPreampDB,
                    rightPreampDB: &rightPreampDB,
                    limits: limits,
                    line: lineNumber
                )
                continue
            }

            guard line.lowercased().hasPrefix("graphiceq"),
                  let colon = line.firstIndex(of: ":") else {
                continue
            }
            let declarations = line[line.index(after: colon)...].split(separator: ";")
            var parsedPoints: [EQMagnitudePoint] = []
            var parsedFrequencies = Set<Double>()
            for declaration in declarations {
                let tokens = declaration.split(whereSeparator: \.isWhitespace).map(String.init)
                guard tokens.count == 2 else {
                    throw ProfileImportError.missingNumber(
                        line: lineNumber,
                        field: "GraphicEQ frequency/gain pair"
                    )
                }
                let frequency = try parseNumber(tokens[0], field: "frequency", line: lineNumber)
                let gain = try parseNumber(tokens[1], field: "gain", line: lineNumber)
                try validate(
                    frequency,
                    in: limits.frequencyRange,
                    field: "frequency",
                    line: lineNumber
                )
                try validate(gain, in: limits.gainRange, field: "gain", line: lineNumber)
                try appendMagnitudePoint(
                    EQMagnitudePoint(frequency: frequency, gainDB: gain),
                    to: &parsedPoints,
                    frequencies: &parsedFrequencies,
                    line: lineNumber,
                    limits: limits
                )
            }
            parsedPoints.sort { $0.frequency < $1.frequency }
            try assignGraphicEQ(
                parsedPoints,
                to: currentChannel,
                points: &points,
                leftPoints: &leftPoints,
                rightPoints: &rightPoints,
                line: lineNumber
            )
        }

        guard let importedPoints = leftPoints ?? rightPoints,
              importedPoints.count >= 2 else {
            throw ProfileImportError.noSupportedFilters
        }
        let identityPoints = importedPoints.map {
            EQMagnitudePoint(frequency: $0.frequency, gainDB: 0)
        }
        let resolvedLeftPoints = leftPoints ?? identityPoints
        let resolvedRightPoints = rightPoints ?? identityPoints

        if let points,
           preampDB == leftPreampDB,
           preampDB == rightPreampDB,
           points == resolvedLeftPoints,
           points == resolvedRightPoints {
            return EQProfile(
                name: profileName,
                mode: .convolution,
                preampDB: leftPreampDB,
                filters: [],
                convolution: .magnitudeCurve(MagnitudeCurveSource(points: points))
            )
        }

        return EQProfile(
            name: profileName,
            mode: .convolution,
            channelMode: .stereo,
            preampDB: preampDB,
            filters: [],
            leftPreampDB: leftPreampDB,
            leftFilters: [],
            rightPreampDB: rightPreampDB,
            rightFilters: [],
            convolution: points.map {
                .magnitudeCurve(MagnitudeCurveSource(points: $0))
            },
            leftConvolution: .magnitudeCurve(MagnitudeCurveSource(points: resolvedLeftPoints)),
            rightConvolution: .magnitudeCurve(MagnitudeCurveSource(points: resolvedRightPoints))
        )
    }

    private static func importChannel(
        from rawSelectors: ArraySlice<String>,
        line: Int
    ) throws -> ImportChannel {
        let selectors = rawSelectors.flatMap { token in
            token.split(separator: ",").map { $0.uppercased() }
        }
        let description = rawSelectors.isEmpty
            ? nil
            : rawSelectors.joined(separator: " ")
        guard !selectors.isEmpty else {
            throw ProfileImportError.unsupportedEqualizerAPOChannel(
                line: line,
                selectors: nil
            )
        }
        if selectors == ["ALL"] {
            return .linked
        }

        var includesLeft = false
        var includesRight = false
        for selector in selectors {
            switch selector {
            case "L", "LEFT", "1":
                includesLeft = true
            case "R", "RIGHT", "2":
                includesRight = true
            default:
                throw ProfileImportError.unsupportedEqualizerAPOChannel(
                    line: line,
                    selectors: description
                )
            }
        }
        switch (includesLeft, includesRight) {
        case (true, true):
            return .leftAndRight
        case (true, false):
            return .left
        case (false, true):
            return .right
        case (false, false):
            throw ProfileImportError.unsupportedEqualizerAPOChannel(
                line: line,
                selectors: description
            )
        }
    }

    private static func addPreamp(
        _ value: Double,
        to channel: ImportChannel,
        preampDB: inout Double,
        leftPreampDB: inout Double,
        rightPreampDB: inout Double,
        limits: ProfileImportLimits,
        line: Int
    ) throws {
        switch channel {
        case .linked:
            let nextPreamp = preampDB + value
            let nextLeft = leftPreampDB + value
            let nextRight = rightPreampDB + value
            try validate(nextPreamp, in: limits.preampRange, field: "preamp", line: line)
            try validate(nextLeft, in: limits.preampRange, field: "left preamp", line: line)
            try validate(nextRight, in: limits.preampRange, field: "right preamp", line: line)
            preampDB = nextPreamp
            leftPreampDB = nextLeft
            rightPreampDB = nextRight
        case .leftAndRight:
            let nextLeft = leftPreampDB + value
            let nextRight = rightPreampDB + value
            try validate(nextLeft, in: limits.preampRange, field: "left preamp", line: line)
            try validate(nextRight, in: limits.preampRange, field: "right preamp", line: line)
            leftPreampDB = nextLeft
            rightPreampDB = nextRight
        case .left:
            let nextLeft = leftPreampDB + value
            try validate(nextLeft, in: limits.preampRange, field: "left preamp", line: line)
            leftPreampDB = nextLeft
        case .right:
            let nextRight = rightPreampDB + value
            try validate(nextRight, in: limits.preampRange, field: "right preamp", line: line)
            rightPreampDB = nextRight
        }
    }

    private static func appendEqualizerAPOFilter(
        _ filter: EQFilter,
        to channel: ImportChannel,
        filters: inout [EQFilter],
        leftFilters: inout [EQFilter],
        rightFilters: inout [EQFilter],
        importedFilterCount: inout Int,
        line: Int,
        limits: ProfileImportLimits
    ) throws {
        switch channel {
        case .linked:
            try append(
                filter,
                to: &filters,
                channelName: "linked",
                line: line,
                limits: limits,
                totalFilterCount: importedFilterCount
            )
            try append(
                filter,
                to: &leftFilters,
                channelName: "left",
                line: line,
                limits: limits,
                totalFilterCount: importedFilterCount
            )
            try append(
                filter,
                to: &rightFilters,
                channelName: "right",
                line: line,
                limits: limits,
                totalFilterCount: importedFilterCount
            )
        case .leftAndRight:
            try append(
                filter,
                to: &leftFilters,
                channelName: "left",
                line: line,
                limits: limits,
                totalFilterCount: importedFilterCount
            )
            try append(
                filter,
                to: &rightFilters,
                channelName: "right",
                line: line,
                limits: limits,
                totalFilterCount: importedFilterCount
            )
        case .left:
            try append(
                filter,
                to: &leftFilters,
                channelName: "left",
                line: line,
                limits: limits,
                totalFilterCount: importedFilterCount
            )
        case .right:
            try append(
                filter,
                to: &rightFilters,
                channelName: "right",
                line: line,
                limits: limits,
                totalFilterCount: importedFilterCount
            )
        }
        importedFilterCount += 1
    }

    private static func assignGraphicEQ(
        _ newPoints: [EQMagnitudePoint],
        to channel: ImportChannel,
        points: inout [EQMagnitudePoint]?,
        leftPoints: inout [EQMagnitudePoint]?,
        rightPoints: inout [EQMagnitudePoint]?,
        line: Int
    ) throws {
        switch channel {
        case .linked:
            if leftPoints != nil {
                throw ProfileImportError.multipleEqualizerAPOGraphicEQ(
                    line: line,
                    channel: "left"
                )
            }
            if rightPoints != nil {
                throw ProfileImportError.multipleEqualizerAPOGraphicEQ(
                    line: line,
                    channel: "right"
                )
            }
            points = newPoints
            leftPoints = newPoints
            rightPoints = newPoints
        case .leftAndRight:
            if leftPoints != nil {
                throw ProfileImportError.multipleEqualizerAPOGraphicEQ(
                    line: line,
                    channel: "left"
                )
            }
            if rightPoints != nil {
                throw ProfileImportError.multipleEqualizerAPOGraphicEQ(
                    line: line,
                    channel: "right"
                )
            }
            leftPoints = newPoints
            rightPoints = newPoints
        case .left:
            guard leftPoints == nil else {
                throw ProfileImportError.multipleEqualizerAPOGraphicEQ(
                    line: line,
                    channel: "left"
                )
            }
            leftPoints = newPoints
        case .right:
            guard rightPoints == nil else {
                throw ProfileImportError.multipleEqualizerAPOGraphicEQ(
                    line: line,
                    channel: "right"
                )
            }
            rightPoints = newPoints
        }
    }

    public static func importREW(
        _ text: String,
        profileName: String = "Imported REW",
        limits: ProfileImportLimits = .default
    ) throws -> EQProfile {
        try validateInput(text, limits: limits)

        var filters: [EQFilter] = []

        for (offset, rawLine) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            let lineNumber = offset + 1
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("*") else {
                continue
            }

            let tokens = line
                .replacingOccurrences(of: ":", with: " ")
                .split(whereSeparator: \.isWhitespace)
                .map(String.init)

            guard tokens.first?.caseInsensitiveCompare("Filter") == .orderedSame else {
                continue
            }

            guard tokens.count > 1,
                  Int(tokens[1]) != nil else {
                continue
            }

            let enabled = !tokens.contains { $0.caseInsensitiveCompare("None") == .orderedSame }
            guard enabled else {
                continue
            }

            let kind = parseREWKind(in: tokens)

            guard let frequency = try requiredValue(afterAnyOf: ["Fc", "F"], in: tokens, field: "frequency", line: lineNumber) ??
                firstNumberFollowingFrequencyUnit(in: tokens, line: lineNumber) else {
                throw ProfileImportError.missingNumber(line: lineNumber, field: "frequency")
            }
            try validate(frequency, in: limits.frequencyRange, field: "frequency", line: lineNumber)

            let gain = try value(beforeUnit: "dB", in: tokens, field: "gain", line: lineNumber) ?? 0
            try validate(gain, in: limits.gainRange, field: "gain", line: lineNumber)

            let q = try optionalValue(after: "Q", in: tokens, field: "Q", line: lineNumber) ?? 0.707_106_781_18
            try validate(q, in: limits.qRange, field: "Q", line: lineNumber)

            try append(
                EQFilter(kind: kind, frequency: frequency, gainDB: gain, q: q),
                to: &filters,
                channelName: "linked",
                line: lineNumber,
                limits: limits,
                totalFilterCount: filters.count
            )
        }

        guard !filters.isEmpty else {
            throw ProfileImportError.noSupportedFilters
        }

        return EQProfile(name: profileName, mode: inferredMode(filters: filters), filters: filters)
    }

    private static func parseEqualizerAPOKind(_ token: String) -> FilterKind? {
        switch token.uppercased() {
        case "PK", "PEQ":
            return .peak
        case "LS", "LSC":
            return .lowShelf
        case "HS", "HSC":
            return .highShelf
        case "HP", "HPQ":
            return .highPass
        case "LP", "LPQ":
            return .lowPass
        default:
            return nil
        }
    }

    private static func parseREWKind(in tokens: [String]) -> FilterKind {
        if tokens.contains(where: { $0.caseInsensitiveCompare("Modal") == .orderedSame }) {
            return .peak
        }
        for token in tokens {
            if let kind = parseEqualizerAPOKind(token) {
                return kind
            }
        }
        return .peak
    }

    private static func optionalValue(after label: String, in tokens: [String], field: String, line: Int) throws -> Double? {
        guard let index = tokens.firstIndex(where: { $0.caseInsensitiveCompare(label) == .orderedSame }) else {
            return nil
        }
        guard tokens.indices.contains(index + 1) else {
            throw ProfileImportError.missingNumber(line: line, field: field)
        }

        return try parseNumber(tokens[index + 1], field: field, line: line)
    }

    private static func requiredValue(after label: String, in tokens: [String], field: String, line: Int) throws -> Double? {
        if let value = try optionalValue(after: label, in: tokens, field: field, line: line) {
            return value
        }
        return try firstNumericToken(in: tokens.dropFirst(), field: field, line: line)
    }

    private static func requiredValue(afterAnyOf labels: [String], in tokens: [String], field: String, line: Int) throws -> Double? {
        for label in labels {
            if let value = try optionalValue(after: label, in: tokens, field: field, line: line) {
                return value
            }
        }
        return nil
    }

    private static func value(afterAnyOf labels: [String], in tokens: [String]) -> String? {
        for label in labels {
            if let index = tokens.firstIndex(where: { $0.caseInsensitiveCompare(label) == .orderedSame }),
               tokens.indices.contains(index + 1) {
                return tokens[index + 1]
            }
        }
        return nil
    }

    private static func value(beforeUnit unit: String, in tokens: [String], field: String, line: Int) throws -> Double? {
        guard let index = tokens.firstIndex(where: { $0.caseInsensitiveCompare(unit) == .orderedSame }),
              index > tokens.startIndex else {
            return nil
        }
        return try parseNumber(tokens[index - 1], field: field, line: line)
    }

    private static func firstNumberFollowingFrequencyUnit(in tokens: [String], line: Int) throws -> Double? {
        guard let unitIndex = tokens.firstIndex(where: { $0.caseInsensitiveCompare("Hz") == .orderedSame }),
              unitIndex > tokens.startIndex else {
            return nil
        }
        return try parseNumber(tokens[unitIndex - 1], field: "frequency", line: line)
    }

    private static func firstNumericToken<S: Sequence>(in tokens: S, field: String, line: Int) throws -> Double? where S.Element == String {
        for token in tokens {
            if let value = try parseNumberIfPresent(token, field: field, line: line) {
                return value
            }
        }
        return nil
    }

    private static func parseNumber(_ token: String, field: String, line: Int) throws -> Double {
        guard let value = try parseNumberIfPresent(token, field: field, line: line) else {
            throw ProfileImportError.invalidNumber(line: line, field: field, value: token)
        }
        return value
    }

    private static func parseNumberIfPresent(_ token: String, field: String, line: Int) throws -> Double? {
        guard !isHexFloatToken(token) else {
            throw ProfileImportError.invalidNumber(line: line, field: field, value: token)
        }
        guard let value = Double(normalizedDecimalToken(token)) else {
            return nil
        }
        guard value.isFinite else {
            throw ProfileImportError.invalidNumber(line: line, field: field, value: token)
        }
        return value
    }

    private static func normalizedDecimalToken(_ token: String) -> String {
        guard token.contains(","),
              !token.contains("."),
              token.filter({ $0 == "," }).count == 1 else {
            return token
        }
        return token.replacingOccurrences(of: ",", with: ".")
    }

    private static func isHexFloatToken(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let unsigned = trimmed.hasPrefix("+") || trimmed.hasPrefix("-") ? String(trimmed.dropFirst()) : trimmed
        return unsigned.lowercased().hasPrefix("0x")
    }

    private static func validate(_ value: Double, in range: ClosedRange<Double>, field: String, line: Int) throws {
        guard value.isFinite else {
            throw ProfileImportError.invalidNumber(line: line, field: field, value: String(value))
        }
        guard range.contains(value) else {
            throw ProfileImportError.valueOutOfRange(line: line, field: field, value: value, range: range)
        }
    }

    private static func validateInput(_ text: String, limits: ProfileImportLimits) throws {
        let byteCount = text.utf8.count
        guard byteCount <= limits.maxUTF8Bytes else {
            throw ProfileImportError.inputTooLarge(byteCount: byteCount, maximum: limits.maxUTF8Bytes)
        }

        let lineCount = lineCount(in: text)
        guard lineCount <= limits.maxLineCount else {
            throw ProfileImportError.tooManyLines(lineCount: lineCount, maximum: limits.maxLineCount)
        }
    }

    private static func lineCount(in text: String) -> Int {
        guard !text.isEmpty else {
            return 0
        }

        let newlineCount = text.reduce(0) { count, character in
            character.isNewline ? count + 1 : count
        }
        return text.last?.isNewline == true ? newlineCount : newlineCount + 1
    }

    private static func append(
        _ filter: EQFilter,
        to filters: inout [EQFilter],
        channelName: String,
        line: Int,
        limits: ProfileImportLimits,
        totalFilterCount: Int
    ) throws {
        let channelCount = filters.count + 1
        guard channelCount <= limits.maxFiltersPerChannel else {
            throw ProfileImportError.tooManyFilters(
                line: line,
                channel: channelName,
                count: channelCount,
                maximum: limits.maxFiltersPerChannel
            )
        }

        let totalCount = totalFilterCount + 1
        guard totalCount <= limits.maxTotalFilters else {
            throw ProfileImportError.tooManyTotalFilters(line: line, count: totalCount, maximum: limits.maxTotalFilters)
        }

        filters.append(filter)
    }

    private static func appendMagnitudePoint(
        _ point: EQMagnitudePoint,
        to points: inout [EQMagnitudePoint],
        frequencies: inout Set<Double>,
        line: Int,
        limits: ProfileImportLimits
    ) throws {
        guard frequencies.insert(point.frequency).inserted else {
            throw ProfileImportError.duplicateMagnitudeFrequency(
                line: line,
                frequency: point.frequency
            )
        }
        let pointCount = points.count + 1
        guard pointCount <= limits.maxMagnitudePoints else {
            throw ProfileImportError.tooManyMagnitudePoints(
                line: line,
                count: pointCount,
                maximum: limits.maxMagnitudePoints
            )
        }
        points.append(point)
    }

    private static func inferredMode(filters: [EQFilter]) -> EQMode {
        graphicMode(for: filters) ?? .parametric
    }

    private static func inferredMode(leftFilters: [EQFilter], rightFilters: [EQFilter]) -> EQMode {
        guard let leftMode = graphicMode(for: leftFilters),
              let rightMode = graphicMode(for: rightFilters),
              leftMode == rightMode else {
            return .parametric
        }
        return leftMode
    }

    private static func graphicMode(for filters: [EQFilter]) -> EQMode? {
        let activeFilters = filters.filter(\.isEnabled)
        guard activeFilters.allSatisfy({ $0.kind == .peak }) else {
            return nil
        }
        if matchesGraphicBands(activeFilters, bands: GraphicEQBands.tenBand) {
            return .graphic10
        }
        if matchesGraphicBands(activeFilters, bands: GraphicEQBands.thirtyOneBand) {
            return .graphic31
        }
        return nil
    }

    private static func matchesGraphicBands(_ filters: [EQFilter], bands: [Double]) -> Bool {
        guard filters.count == bands.count else {
            return false
        }
        return zip(filters, bands).allSatisfy { filter, band in
            abs(filter.frequency - band) <= 0.1 &&
                abs(filter.q - GraphicEQBands.graphicQ) <= 0.01
        }
    }
}

public enum EQProfileTextExportError: Error, Equatable, Sendable, LocalizedError {
    case impulseResponseUnsupported

    public var errorDescription: String? {
        switch self {
        case .impulseResponseUnsupported:
            "Impulse-response profiles cannot be exported as EqualizerAPO text."
        }
    }
}

public enum EQProfileTextExporter {
    public static func exportEqualizerAPO(_ profile: EQProfile) throws -> String {
        if profile.mode == .convolution {
            return try exportGraphicEQ(profile)
        }
        var lines: [String] = []

        switch profile.channelMode {
        case .linked:
            lines.append(String(format: "Preamp: %.2f dB", profile.preampDB))
            lines.append(contentsOf: filterLines(profile.filters))
        case .stereo:
            lines.append("Channel: L")
            lines.append(String(format: "Preamp: %.2f dB", profile.leftPreampDB))
            lines.append(contentsOf: filterLines(profile.leftFilters))
            lines.append("")
            lines.append("Channel: R")
            lines.append(String(format: "Preamp: %.2f dB", profile.rightPreampDB))
            lines.append(contentsOf: filterLines(profile.rightFilters))
        }

        return lines.joined(separator: "\n")
    }

    private static func exportGraphicEQ(_ profile: EQProfile) throws -> String {
        var lines: [String] = []
        switch profile.channelMode {
        case .linked:
            lines.append(String(format: "Preamp: %.2f dB", profile.preampDB))
            if let line = try graphicEQLine(profile.convolution) {
                lines.append(line)
            }
        case .stereo:
            lines.append("Channel: L")
            lines.append(String(format: "Preamp: %.2f dB", profile.leftPreampDB))
            if let line = try graphicEQLine(profile.leftConvolution) {
                lines.append(line)
            }
            lines.append("")
            lines.append("Channel: R")
            lines.append(String(format: "Preamp: %.2f dB", profile.rightPreampDB))
            if let line = try graphicEQLine(profile.rightConvolution) {
                lines.append(line)
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func graphicEQLine(_ source: EQConvolutionSource?) throws -> String? {
        guard let source else {
            return nil
        }
        guard case .magnitudeCurve(let curve) = source else {
            throw EQProfileTextExportError.impulseResponseUnsupported
        }
        let declarations = curve.points
            .sorted { $0.frequency < $1.frequency }
            .map {
                String(
                    format: "%.8g %.8g",
                    locale: Locale(identifier: "en_US_POSIX"),
                    $0.frequency,
                    $0.gainDB
                )
            }
            .joined(separator: "; ")
        return "GraphicEQ: \(declarations)"
    }

    private static func filterLines(_ filters: [EQFilter]) -> [String] {
        filters.enumerated().map { index, filter in
            String(
                format: "Filter %d: %@ %@ Fc %.1f Hz Gain %.2f dB Q %.2f",
                index + 1,
                filter.isEnabled ? "ON" : "OFF",
                equalizerAPOKind(filter.kind),
                filter.frequency,
                filter.gainDB,
                filter.q
            )
        }
    }

    private static func equalizerAPOKind(_ kind: FilterKind) -> String {
        switch kind {
        case .peak:
            "PK"
        case .lowShelf:
            "LS"
        case .highShelf:
            "HS"
        case .highPass:
            "HP"
        case .lowPass:
            "LP"
        }
    }
}
