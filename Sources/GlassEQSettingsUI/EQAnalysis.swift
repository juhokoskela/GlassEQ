import Foundation
@_spi(GlassEQSettingsUI) import GlassEQCore
import SwiftUI

struct EQAnalysisSignature: Equatable, Sendable {
    static let defaultSampleRate = 48_000.0

    var sampleRate: Double
    var mode: EQMode
    var channelMode: EQChannelMode
    var preampDB: Double
    var filters: [EQFilter]
    var leftPreampDB: Double
    var leftFilters: [EQFilter]
    var rightPreampDB: Double
    var rightFilters: [EQFilter]
    var convolution: EQConvolutionSource?
    var leftConvolution: EQConvolutionSource?
    var rightConvolution: EQConvolutionSource?

    init(profile: EQProfile, sampleRate: Double) {
        self.sampleRate = Self.effectiveSampleRate(sampleRate)
        self.mode = profile.mode
        self.channelMode = profile.channelMode
        self.preampDB = profile.preampDB
        self.filters = profile.filters
        self.leftPreampDB = profile.leftPreampDB
        self.leftFilters = profile.leftFilters
        self.rightPreampDB = profile.rightPreampDB
        self.rightFilters = profile.rightFilters
        self.convolution = profile.convolution
        self.leftConvolution = profile.leftConvolution
        self.rightConvolution = profile.rightConvolution
    }

    static func effectiveSampleRate(_ sampleRate: Double) -> Double {
        guard sampleRate.isFinite, sampleRate > 0 else {
            return defaultSampleRate
        }
        return sampleRate
    }

    func hasSameResponseContent(as other: Self) -> Bool {
        sampleRate == other.sampleRate
            && mode == other.mode
            && channelMode == other.channelMode
            && filters == other.filters
            && leftFilters == other.leftFilters
            && rightFilters == other.rightFilters
            && convolution == other.convolution
            && leftConvolution == other.leftConvolution
            && rightConvolution == other.rightConvolution
    }
}

struct EQAnalysisSnapshot: Equatable, Sendable {
    var signature: EQAnalysisSignature
    var channelMode: EQChannelMode
    var recommendedPreampDB: Double
    var maximumUsableFrequency: Double
    var inactiveEnabledFilterCount: Int
    var linkedPoints: [FrequencyResponsePoint]
    var leftPoints: [FrequencyResponsePoint]
    var rightPoints: [FrequencyResponsePoint]
    private var linkedSourcePeakDB: Double?
    private var leftSourcePeakDB: Double?
    private var rightSourcePeakDB: Double?
    private var linkedSourcePoints: [FrequencyResponsePoint]
    private var leftSourcePoints: [FrequencyResponsePoint]
    private var rightSourcePoints: [FrequencyResponsePoint]

    @concurrent
    static func analyze(
        profile: EQProfile,
        sampleRate: Double,
        cancellationCheck: @Sendable () throws -> Void = { try Task.checkCancellation() }
    ) async throws -> Self {
        try Self(
            profile: profile,
            sampleRate: sampleRate,
            cancellationCheck: cancellationCheck
        )
    }

    private init(
        profile: EQProfile,
        sampleRate: Double,
        cancellationCheck: @Sendable () throws -> Void
    ) throws {
        try cancellationCheck()
        let sampleRate = EQAnalysisSignature.effectiveSampleRate(sampleRate)
        self.signature = EQAnalysisSignature(profile: profile, sampleRate: sampleRate)
        self.channelMode = profile.channelMode
        self.maximumUsableFrequency = EQRouteFrequencyPolicy.maximumUsableFrequency(
            sampleRate: sampleRate
        )
        self.inactiveEnabledFilterCount = EQRouteFrequencyPolicy.inactiveEnabledFilterCount(
            profile: profile,
            sampleRate: sampleRate
        )

        switch profile.channelMode {
        case .linked:
            let sourcePeakDB = try Self.sourcePeakMagnitudeDB(
                mode: profile.mode,
                filters: profile.filters,
                source: profile.convolution,
                sampleRate: sampleRate,
                cancellationCheck: cancellationCheck
            )
            let sourcePoints = try Self.responsePoints(
                mode: profile.mode,
                filters: profile.filters,
                source: profile.convolution,
                preampDB: 0,
                sampleRate: sampleRate,
                cancellationCheck: cancellationCheck
            )
            self.linkedSourcePeakDB = sourcePeakDB
            self.leftSourcePeakDB = nil
            self.rightSourcePeakDB = nil
            self.linkedSourcePoints = sourcePoints
            self.leftSourcePoints = []
            self.rightSourcePoints = []
            self.linkedPoints = Self.applyingPreamp(profile.preampDB, to: sourcePoints)
            self.leftPoints = []
            self.rightPoints = []
        case .stereo:
            let leftSourcePeakDB = try Self.sourcePeakMagnitudeDB(
                mode: profile.mode,
                filters: profile.leftFilters,
                source: profile.leftConvolution,
                sampleRate: sampleRate,
                cancellationCheck: cancellationCheck
            )
            let rightSourcePeakDB = try Self.sourcePeakMagnitudeDB(
                mode: profile.mode,
                filters: profile.rightFilters,
                source: profile.rightConvolution,
                sampleRate: sampleRate,
                cancellationCheck: cancellationCheck
            )
            let leftSourcePoints = try Self.responsePoints(
                mode: profile.mode,
                filters: profile.leftFilters,
                source: profile.leftConvolution,
                preampDB: 0,
                sampleRate: sampleRate,
                cancellationCheck: cancellationCheck
            )
            let rightSourcePoints = try Self.responsePoints(
                mode: profile.mode,
                filters: profile.rightFilters,
                source: profile.rightConvolution,
                preampDB: 0,
                sampleRate: sampleRate,
                cancellationCheck: cancellationCheck
            )
            self.linkedSourcePeakDB = nil
            self.leftSourcePeakDB = leftSourcePeakDB
            self.rightSourcePeakDB = rightSourcePeakDB
            self.linkedSourcePoints = []
            self.leftSourcePoints = leftSourcePoints
            self.rightSourcePoints = rightSourcePoints
            self.linkedPoints = []
            self.leftPoints = Self.applyingPreamp(profile.leftPreampDB, to: leftSourcePoints)
            self.rightPoints = Self.applyingPreamp(profile.rightPreampDB, to: rightSourcePoints)
        }
        self.recommendedPreampDB = Self.recommendedPreampDB(
            profile: profile,
            linkedSourcePeakDB: linkedSourcePeakDB,
            leftSourcePeakDB: leftSourcePeakDB,
            rightSourcePeakDB: rightSourcePeakDB
        )
        try cancellationCheck()
    }

    func updatingPreamp(profile: EQProfile, sampleRate: Double) -> Self? {
        let nextSignature = EQAnalysisSignature(profile: profile, sampleRate: sampleRate)
        guard signature.hasSameResponseContent(as: nextSignature) else {
            return nil
        }

        var updated = self
        updated.signature = nextSignature
        switch profile.channelMode {
        case .linked:
            updated.linkedPoints = Self.applyingPreamp(
                profile.preampDB,
                to: linkedSourcePoints
            )
        case .stereo:
            updated.leftPoints = Self.applyingPreamp(
                profile.leftPreampDB,
                to: leftSourcePoints
            )
            updated.rightPoints = Self.applyingPreamp(
                profile.rightPreampDB,
                to: rightSourcePoints
            )
        }
        updated.recommendedPreampDB = Self.recommendedPreampDB(
            profile: profile,
            linkedSourcePeakDB: linkedSourcePeakDB,
            leftSourcePeakDB: leftSourcePeakDB,
            rightSourcePeakDB: rightSourcePeakDB
        )
        return updated
    }

    private static func sourcePeakMagnitudeDB(
        mode: EQMode,
        filters: [EQFilter],
        source: EQConvolutionSource?,
        sampleRate: Double,
        cancellationCheck: @Sendable () throws -> Void
    ) throws -> Double {
        if mode == .convolution {
            return try FrequencyResponse.peakMagnitudeDB(
                for: source,
                preampDB: 0,
                sampleRate: sampleRate,
                cancellationCheck: cancellationCheck
            )
        }
        return try FrequencyResponse.peakMagnitudeDB(
            for: filters,
            preampDB: 0,
            sampleRate: sampleRate,
            cancellationCheck: cancellationCheck
        )
    }

    private static func applyingPreamp(
        _ preampDB: Double,
        to points: [FrequencyResponsePoint]
    ) -> [FrequencyResponsePoint] {
        points.map {
            FrequencyResponsePoint(
                frequency: $0.frequency,
                magnitudeDB: preampDB + $0.magnitudeDB
            )
        }
    }

    private static func recommendedPreampDB(
        profile: EQProfile,
        linkedSourcePeakDB: Double?,
        leftSourcePeakDB: Double?,
        rightSourcePeakDB: Double?
    ) -> Double {
        let renderedPeakDB = switch profile.channelMode {
        case .linked:
            profile.preampDB + (linkedSourcePeakDB ?? 0)
        case .stereo:
            max(
                profile.leftPreampDB + (leftSourcePeakDB ?? 0),
                profile.rightPreampDB + (rightSourcePeakDB ?? 0)
            )
        }
        return profile.activePreampDB - max(renderedPeakDB + 0.5, 0)
    }

    private static func responsePoints(
        mode: EQMode,
        filters: [EQFilter],
        source: EQConvolutionSource?,
        preampDB: Double,
        sampleRate: Double,
        cancellationCheck: @Sendable () throws -> Void
    ) rethrows -> [FrequencyResponsePoint] {
        if mode == .convolution {
            return try FrequencyResponse.points(
                for: source,
                preampDB: preampDB,
                sampleRate: sampleRate,
                cancellationCheck: cancellationCheck
            )
        }
        try cancellationCheck()
        let points = FrequencyResponse.points(
            for: filters,
            preampDB: preampDB,
            sampleRate: sampleRate
        )
        try cancellationCheck()
        return points
    }

    var accessibilitySummary: String {
        let curveSummary: String
        switch channelMode {
        case .linked:
            curveSummary = localized(
                "Linked curve from \(localizedDecibels(minMagnitude(in: linkedPoints))) to \(localizedDecibels(maxMagnitude(in: linkedPoints))); recommended preamp \(localizedDecibels(recommendedPreampDB))"
            )
        case .stereo:
            curveSummary = localized(
                "Left curve from \(localizedDecibels(minMagnitude(in: leftPoints))) to \(localizedDecibels(maxMagnitude(in: leftPoints))); right curve from \(localizedDecibels(minMagnitude(in: rightPoints))) to \(localizedDecibels(maxMagnitude(in: rightPoints))); recommended preamp \(localizedDecibels(recommendedPreampDB))"
            )
        }
        guard let inactiveFilterSummary else {
            return curveSummary
        }
        return localized("\(curveSummary). \(inactiveFilterSummary)")
    }

    var inactiveFilterSummary: String? {
        guard inactiveEnabledFilterCount > 0 else {
            return nil
        }
        let count = localizedInteger(inactiveEnabledFilterCount)
        let ceiling = localizedFrequency(maximumUsableFrequency)
        if inactiveEnabledFilterCount == 1 {
            return localized("\(count) enabled filter above \(ceiling) is inactive on this route")
        }
        return localized("\(count) enabled filters above \(ceiling) are inactive on this route")
    }

    private func minMagnitude(in points: [FrequencyResponsePoint]) -> Double {
        points.map(\.magnitudeDB).min() ?? 0
    }

    private func maxMagnitude(in points: [FrequencyResponsePoint]) -> Double {
        points.map(\.magnitudeDB).max() ?? 0
    }
}
