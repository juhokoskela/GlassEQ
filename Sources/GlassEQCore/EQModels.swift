import Foundation

public enum EQMode: String, Codable, Sendable, CaseIterable {
    case parametric
    case graphic10
    case graphic31
    case convolution
}

public enum EQChannelMode: String, Codable, Sendable, CaseIterable {
    case linked
    case stereo
}

public enum FilterKind: String, Codable, Sendable, CaseIterable {
    case peak
    case lowShelf
    case highShelf
    case highPass
    case lowPass
}

public struct EQFilter: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var kind: FilterKind
    public var frequency: Double
    public var gainDB: Double
    public var q: Double
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        kind: FilterKind,
        frequency: Double,
        gainDB: Double = 0,
        q: Double = 0.707_106_781_18,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.kind = kind
        self.frequency = frequency
        self.gainDB = gainDB
        self.q = q
        self.isEnabled = isEnabled
    }
}

public struct EQMagnitudePoint: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var frequency: Double
    public var gainDB: Double

    public init(
        id: UUID = UUID(),
        frequency: Double,
        gainDB: Double
    ) {
        self.id = id
        self.frequency = frequency
        self.gainDB = gainDB
    }
}

public struct MagnitudeCurveSource: Codable, Equatable, Sendable {
    public var synthesisVersion: UInt16
    public var points: [EQMagnitudePoint]

    public init(
        synthesisVersion: UInt16 = MinimumPhaseFIRCompiler.synthesisVersion,
        points: [EQMagnitudePoint]
    ) {
        self.synthesisVersion = synthesisVersion
        self.points = points
    }
}

public enum EQConvolutionSource: Equatable, Sendable {
    case magnitudeCurve(MagnitudeCurveSource)
}

extension EQConvolutionSource: Codable {
    private enum SourceType: String, Codable {
        case magnitudeCurve
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case magnitudeCurve
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(SourceType.self, forKey: .type) {
        case .magnitudeCurve:
            self = .magnitudeCurve(
                try container.decode(MagnitudeCurveSource.self, forKey: .magnitudeCurve)
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .magnitudeCurve(let source):
            try container.encode(SourceType.magnitudeCurve, forKey: .type)
            try container.encode(source, forKey: .magnitudeCurve)
        }
    }
}

public struct EQProfile: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var mode: EQMode
    public var channelMode: EQChannelMode
    public var preampDB: Double
    public var filters: [EQFilter]
    public var leftPreampDB: Double
    public var leftFilters: [EQFilter]
    public var rightPreampDB: Double
    public var rightFilters: [EQFilter]
    public var convolution: EQConvolutionSource?
    public var leftConvolution: EQConvolutionSource?
    public var rightConvolution: EQConvolutionSource?
    public var isBypassed: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        mode: EQMode,
        channelMode: EQChannelMode = .linked,
        preampDB: Double = 0,
        filters: [EQFilter],
        leftPreampDB: Double? = nil,
        leftFilters: [EQFilter]? = nil,
        rightPreampDB: Double? = nil,
        rightFilters: [EQFilter]? = nil,
        convolution: EQConvolutionSource? = nil,
        leftConvolution: EQConvolutionSource? = nil,
        rightConvolution: EQConvolutionSource? = nil,
        isBypassed: Bool = false
    ) {
        self.id = id
        self.name = name
        self.mode = mode
        self.channelMode = channelMode
        self.preampDB = preampDB
        self.filters = filters
        self.leftPreampDB = leftPreampDB ?? preampDB
        self.leftFilters = leftFilters ?? filters
        self.rightPreampDB = rightPreampDB ?? preampDB
        self.rightFilters = rightFilters ?? filters
        self.convolution = convolution
        self.leftConvolution = leftConvolution ?? convolution
        self.rightConvolution = rightConvolution ?? convolution
        self.isBypassed = isBypassed
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case mode
        case channelMode
        case preampDB
        case filters
        case leftPreampDB
        case leftFilters
        case rightPreampDB
        case rightFilters
        case convolution
        case leftConvolution
        case rightConvolution
        case isBypassed
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        mode = try container.decode(EQMode.self, forKey: .mode)
        channelMode = try container.decodeIfPresent(EQChannelMode.self, forKey: .channelMode) ?? .linked
        preampDB = try container.decode(Double.self, forKey: .preampDB)
        filters = try container.decode([EQFilter].self, forKey: .filters)
        leftPreampDB = try container.decodeIfPresent(Double.self, forKey: .leftPreampDB) ?? preampDB
        leftFilters = try container.decodeIfPresent([EQFilter].self, forKey: .leftFilters) ?? filters
        rightPreampDB = try container.decodeIfPresent(Double.self, forKey: .rightPreampDB) ?? preampDB
        rightFilters = try container.decodeIfPresent([EQFilter].self, forKey: .rightFilters) ?? filters
        convolution = try container.decodeIfPresent(EQConvolutionSource.self, forKey: .convolution)
        leftConvolution = try container.decodeIfPresent(EQConvolutionSource.self, forKey: .leftConvolution)
            ?? convolution
        rightConvolution = try container.decodeIfPresent(EQConvolutionSource.self, forKey: .rightConvolution)
            ?? convolution
        isBypassed = try container.decodeIfPresent(Bool.self, forKey: .isBypassed) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(mode, forKey: .mode)
        try container.encode(channelMode, forKey: .channelMode)
        try container.encode(preampDB, forKey: .preampDB)
        try container.encode(filters, forKey: .filters)
        try container.encode(leftPreampDB, forKey: .leftPreampDB)
        try container.encode(leftFilters, forKey: .leftFilters)
        try container.encode(rightPreampDB, forKey: .rightPreampDB)
        try container.encode(rightFilters, forKey: .rightFilters)
        try container.encodeIfPresent(convolution, forKey: .convolution)
        try container.encodeIfPresent(leftConvolution, forKey: .leftConvolution)
        try container.encodeIfPresent(rightConvolution, forKey: .rightConvolution)
        try container.encode(isBypassed, forKey: .isBypassed)
    }

    public static let flatParametric = EQProfile(
        name: "Flat",
        mode: .parametric,
        filters: []
    )

    public static let flatGraphic10 = EQProfile(
        name: "Flat 10-Band",
        mode: .graphic10,
        filters: GraphicEQBands.tenBand.map {
            EQFilter(kind: .peak, frequency: $0, gainDB: 0, q: GraphicEQBands.graphicQ)
        }
    )

    public static let flatGraphic31 = EQProfile(
        name: "Flat 31-Band",
        mode: .graphic31,
        filters: GraphicEQBands.thirtyOneBand.map {
            EQFilter(kind: .peak, frequency: $0, gainDB: 0, q: GraphicEQBands.graphicQ)
        }
    )

    public static let flatConvolution = EQProfile(
        name: "Flat Response Curve",
        mode: .convolution,
        filters: [],
        convolution: .magnitudeCurve(MagnitudeCurveSource(points: [
            EQMagnitudePoint(frequency: 20, gainDB: 0),
            EQMagnitudePoint(frequency: 20_000, gainDB: 0)
        ]))
    )
}

public enum GraphicEQBands {
    public static let graphicQ = 1.414_213_562_37

    public static let tenBand: [Double] = [
        31.25, 62.5, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000
    ]

    public static let thirtyOneBand: [Double] = [
        20, 25, 31.5, 40, 50, 63, 80, 100,
        125, 160, 200, 250, 315, 400, 500, 630, 800,
        1_000, 1_250, 1_600, 2_000, 2_500, 3_150, 4_000,
        5_000, 6_300, 8_000, 10_000, 12_500, 16_000, 20_000
    ]
}

public struct OutputDeviceProfileMapping: Codable, Equatable, Sendable {
    public var outputDeviceUID: String
    public var profileID: UUID

    public init(outputDeviceUID: String, profileID: UUID) {
        self.outputDeviceUID = outputDeviceUID
        self.profileID = profileID
    }
}

public struct ProfileStoreRepairSummary: Equatable, Sendable {
    public var restoredDefaultProfiles: Bool
    public var repairedFallbackProfileID: Bool
    public var removedOutputMappings: Int
    public var deduplicatedOutputMappings: Int
    public var removedInvalidProfiles: Int

    public var didRepair: Bool {
        restoredDefaultProfiles ||
            repairedFallbackProfileID ||
            removedOutputMappings > 0 ||
            deduplicatedOutputMappings > 0 ||
            removedInvalidProfiles > 0
    }

    public init(
        restoredDefaultProfiles: Bool = false,
        repairedFallbackProfileID: Bool = false,
        removedOutputMappings: Int = 0,
        deduplicatedOutputMappings: Int = 0,
        removedInvalidProfiles: Int = 0
    ) {
        self.restoredDefaultProfiles = restoredDefaultProfiles
        self.repairedFallbackProfileID = repairedFallbackProfileID
        self.removedOutputMappings = removedOutputMappings
        self.deduplicatedOutputMappings = deduplicatedOutputMappings
        self.removedInvalidProfiles = removedInvalidProfiles
    }

    mutating func merge(_ other: ProfileStoreRepairSummary) {
        restoredDefaultProfiles = restoredDefaultProfiles || other.restoredDefaultProfiles
        repairedFallbackProfileID = repairedFallbackProfileID || other.repairedFallbackProfileID
        removedOutputMappings += other.removedOutputMappings
        deduplicatedOutputMappings += other.deduplicatedOutputMappings
        removedInvalidProfiles += other.removedInvalidProfiles
    }
}

public struct ProfileStore: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let defaultProfiles: [EQProfile] = [.flatGraphic31, .flatGraphic10, .flatParametric]

    public var schemaVersion: Int
    public var profiles: [EQProfile]
    public var outputMappings: [OutputDeviceProfileMapping]
    public var fallbackProfileID: UUID

    public init(
        schemaVersion: Int = ProfileStore.currentSchemaVersion,
        profiles: [EQProfile] = ProfileStore.defaultProfiles,
        outputMappings: [OutputDeviceProfileMapping] = [],
        fallbackProfileID: UUID? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.profiles = profiles
        self.outputMappings = outputMappings
        self.fallbackProfileID = fallbackProfileID ?? profiles.first?.id ?? EQProfile.flatParametric.id
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case profiles
        case outputMappings
        case fallbackProfileID
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Self.currentSchemaVersion
        profiles = try container.decode([EQProfile].self, forKey: .profiles)
        outputMappings = try container.decode([OutputDeviceProfileMapping].self, forKey: .outputMappings)
        fallbackProfileID = try container.decode(UUID.self, forKey: .fallbackProfileID)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(profiles, forKey: .profiles)
        try container.encode(outputMappings, forKey: .outputMappings)
        try container.encode(fallbackProfileID, forKey: .fallbackProfileID)
    }

    @discardableResult
    public mutating func repairReferences() -> ProfileStoreRepairSummary {
        var summary = ProfileStoreRepairSummary()

        if profiles.isEmpty {
            profiles = Self.defaultProfiles
            summary.restoredDefaultProfiles = true
        }

        let profileIDs = Set(profiles.map(\.id))
        if !profileIDs.contains(fallbackProfileID), let firstProfileID = profiles.first?.id {
            fallbackProfileID = firstProfileID
            summary.repairedFallbackProfileID = true
        }

        let mappingCountBeforeRemoval = outputMappings.count
        outputMappings.removeAll { mapping in
            mapping.outputDeviceUID.isEmpty || !profileIDs.contains(mapping.profileID)
        }
        summary.removedOutputMappings = mappingCountBeforeRemoval - outputMappings.count

        var seenOutputUIDs = Set<String>()
        var dedupedReversed: [OutputDeviceProfileMapping] = []
        for mapping in outputMappings.reversed() {
            if seenOutputUIDs.insert(mapping.outputDeviceUID).inserted {
                dedupedReversed.append(mapping)
            } else {
                summary.deduplicatedOutputMappings += 1
            }
        }
        outputMappings = dedupedReversed.reversed()

        return summary
    }

    public func profile(forOutputUID uid: String?) -> EQProfile {
        if let uid,
           let profileID = outputMappings.first(where: { $0.outputDeviceUID == uid })?.profileID,
           let profile = profiles.first(where: { $0.id == profileID }) {
            return profile
        }

        return profiles.first(where: { $0.id == fallbackProfileID }) ?? profiles.first ?? .flatParametric
    }
}
