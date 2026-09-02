import Foundation

public enum StereoTextPairImportError: Error, Equatable, Sendable, LocalizedError {
    case filesMustUseSameFormat
    case filesMustDescribeLinkedChannels
    case profileTypesDoNotMatch(left: EQMode, right: EQMode)
    case missingConvolutionSource

    public var errorDescription: String? {
        switch self {
        case .filesMustUseSameFormat:
            "Choose either two text files or two mono WAV files for separate left and right import."
        case .filesMustDescribeLinkedChannels:
            "Each text file must describe one linked channel. Files that already contain separate left and right settings cannot be paired again."
        case let .profileTypesDoNotMatch(left, right):
            "The files contain different profile types: \(left.importPairDescription) and \(right.importPairDescription)."
        case .missingConvolutionSource:
            "One of the text files does not contain a response curve."
        }
    }
}

public struct ImportedStereoTextPair: Equatable, Sendable {
    public var profile: EQProfile
    public var leftFilename: String
    public var rightFilename: String

    public init(profile: EQProfile, leftFilename: String, rightFilename: String) {
        self.profile = profile
        self.leftFilename = leftFilename
        self.rightFilename = rightFilename
    }

    public mutating func swapChannels() {
        profile.swapStereoChannels()
        swap(&leftFilename, &rightFilename)
    }
}

public enum StereoTextPairImporter {
    public static func load(leftURL: URL, rightURL: URL) throws -> ImportedStereoTextPair {
        let left = try importProfile(from: leftURL)
        let right = try importProfile(from: rightURL)
        guard left.channelMode == .linked,
              right.channelMode == .linked else {
            throw StereoTextPairImportError.filesMustDescribeLinkedChannels
        }
        guard left.mode == right.mode else {
            throw StereoTextPairImportError.profileTypesDoNotMatch(
                left: left.mode,
                right: right.mode
            )
        }

        let name = EQProfile.inferredStereoImportName(
            leftURL: leftURL,
            rightURL: rightURL,
            fallback: "Imported Stereo EQ"
        )
        let profile: EQProfile
        if left.mode == .convolution {
            guard let leftSource = left.convolution,
                  let rightSource = right.convolution else {
                throw StereoTextPairImportError.missingConvolutionSource
            }
            profile = EQProfile(
                name: name,
                mode: .convolution,
                channelMode: .stereo,
                preampDB: min(left.preampDB, right.preampDB),
                filters: [],
                leftPreampDB: left.preampDB,
                leftFilters: [],
                rightPreampDB: right.preampDB,
                rightFilters: [],
                convolution: nil,
                leftConvolution: leftSource,
                rightConvolution: rightSource
            )
        } else {
            profile = EQProfile(
                name: name,
                mode: left.mode,
                channelMode: .stereo,
                preampDB: min(left.preampDB, right.preampDB),
                filters: [],
                leftPreampDB: left.preampDB,
                leftFilters: left.filters,
                rightPreampDB: right.preampDB,
                rightFilters: right.filters
            )
        }

        return ImportedStereoTextPair(
            profile: profile,
            leftFilename: leftURL.lastPathComponent,
            rightFilename: rightURL.lastPathComponent
        )
    }

    private static func importProfile(from url: URL) throws -> EQProfile {
        let text = try ProfileTextFileReader.read(url)
        let name = url.deletingPathExtension().lastPathComponent
        switch ImportedEQTextDetector.format(for: text) {
        case .autoEQ:
            return try EQProfileTextImporter.importAutoEQ(text, profileName: name)
        case .rew:
            return try EQProfileTextImporter.importREW(text, profileName: name)
        }
    }
}

extension EQProfile {
    public mutating func swapStereoChannels() {
        swap(&leftPreampDB, &rightPreampDB)
        swap(&leftFilters, &rightFilters)
        swap(&leftConvolution, &rightConvolution)
    }

    public static func inferredStereoImportName(
        leftURL: URL,
        rightURL: URL,
        fallback: String
    ) -> String {
        let left = removingChannelSuffix(leftURL.deletingPathExtension().lastPathComponent)
        let right = removingChannelSuffix(rightURL.deletingPathExtension().lastPathComponent)
        if !left.isEmpty,
           left.caseInsensitiveCompare(right) == .orderedSame {
            return left
        }
        return fallback
    }

    private static func removingChannelSuffix(_ name: String) -> String {
        let suffixes = [
            " left", "-left", "_left", " l", "-l", "_l",
            " right", "-right", "_right", " r", "-r", "_r"
        ]
        let lowercased = name.lowercased()
        for suffix in suffixes where lowercased.hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return name
    }
}

private extension EQMode {
    var importPairDescription: String {
        switch self {
        case .parametric:
            "Parametric"
        case .graphic10:
            "10-band"
        case .graphic31:
            "31-band"
        case .convolution:
            "Convolution"
        }
    }
}
