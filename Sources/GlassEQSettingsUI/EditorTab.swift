@_spi(GlassEQSettingsUI) import GlassEQCore
import SwiftUI

enum EQEditChannel: String, CaseIterable, Identifiable {
    case left
    case right

    var id: String { rawValue }

    var title: String {
        switch self {
        case .left:
            localized("Left")
        case .right:
            localized("Right")
        }
    }
}

// Which stored channel the editor is operating on. Linked profiles keep one set of settings;
// stereo profiles keep a left and a right set.
enum EQProfileChannel: Hashable {
    case linked
    case left
    case right
}

struct EQChannelSettings: Equatable {
    var preampDB: Double
    var filters: [EQFilter]
    var convolution: EQConvolutionSource?

    var magnitudePoints: [EQMagnitudePoint] {
        get {
            guard case .magnitudeCurve(let curve) = convolution else {
                return []
            }
            return curve.points
        }
        set {
            let version: UInt16
            if case .magnitudeCurve(let curve) = convolution {
                version = curve.synthesisVersion
            } else {
                version = MinimumPhaseFIRCompiler.synthesisVersion
            }
            convolution = .magnitudeCurve(MagnitudeCurveSource(synthesisVersion: version, points: newValue))
        }
    }
}

extension EQProfile {
    subscript(channel channel: EQProfileChannel) -> EQChannelSettings {
        get {
            switch channel {
            case .linked:
                EQChannelSettings(preampDB: preampDB, filters: filters, convolution: convolution)
            case .left:
                EQChannelSettings(preampDB: leftPreampDB, filters: leftFilters, convolution: leftConvolution)
            case .right:
                EQChannelSettings(preampDB: rightPreampDB, filters: rightFilters, convolution: rightConvolution)
            }
        }
        set {
            switch channel {
            case .linked:
                preampDB = newValue.preampDB
                filters = newValue.filters
                convolution = newValue.convolution
            case .left:
                leftPreampDB = newValue.preampDB
                leftFilters = newValue.filters
                leftConvolution = newValue.convolution
            case .right:
                rightPreampDB = newValue.preampDB
                rightFilters = newValue.filters
                rightConvolution = newValue.convolution
            }
        }
    }

    var activePreampDB: Double {
        switch channelMode {
        case .linked:
            preampDB
        case .stereo:
            max(leftPreampDB, rightPreampDB)
        }
    }

    // The attenuation needed to reach the recommended preamp, or nil when applying it would push
    // a channel past the persistable preamp range.
    func headroomAttenuation(toReach recommendedPreampDB: Double) -> Double? {
        let attenuation = max(activePreampDB - recommendedPreampDB, 0)
        let adjustedPreamps = switch channelMode {
        case .linked:
            [preampDB - attenuation]
        case .stereo:
            [leftPreampDB - attenuation, rightPreampDB - attenuation]
        }
        guard adjustedPreamps.allSatisfy(ProfilePersistence.preampRange.contains) else {
            return nil
        }
        return attenuation
    }

    // True when the profile would leave audio unchanged: unity preamp, zero-gain filters, and no
    // impulse response or non-flat target curve.
    var isNeutral: Bool {
        let preamps = [preampDB, leftPreampDB, rightPreampDB]
        guard preamps.allSatisfy({ $0 == 0 }) else {
            return false
        }
        guard (filters + leftFilters + rightFilters).allSatisfy({ !$0.isEnabled || $0.gainDB == 0 }) else {
            return false
        }
        return [convolution, leftConvolution, rightConvolution].allSatisfy { source in
            switch source {
            case nil:
                true
            case .magnitudeCurve(let curve):
                curve.points.allSatisfy { $0.gainDB == 0 }
            case .impulseResponse:
                false
            }
        }
    }

    // Whole-profile conversion used by the editor's channel switch.
    func convertedToChannelMode(
        _ mode: EQChannelMode,
        editedChannel: EQEditChannel
    ) -> EQProfile {
        var converted = self
        switch mode {
        case .linked:
            let useRight = editedChannel == .right
            converted.filters = useRight ? rightFilters : leftFilters
            converted.preampDB = useRight ? rightPreampDB : leftPreampDB
            converted.convolution = useRight ? rightConvolution : leftConvolution
        case .stereo:
            converted.leftFilters = filters
            converted.rightFilters = filters
            converted.leftPreampDB = preampDB
            converted.rightPreampDB = preampDB
            converted.leftConvolution = convolution
            converted.rightConvolution = convolution
        }
        converted.channelMode = mode
        return converted
    }
}

func profileApplyingRecommendedHeadroom(
    _ profile: EQProfile,
    recommendedPreampDB: Double
) -> EQProfile? {
    guard let attenuation = profile.headroomAttenuation(toReach: recommendedPreampDB) else {
        return nil
    }
    var adjusted = profile
    switch adjusted.channelMode {
    case .linked:
        adjusted.preampDB -= attenuation
    case .stereo:
        adjusted.leftPreampDB -= attenuation
        adjusted.rightPreampDB -= attenuation
    }
    return adjusted
}

private extension EQChannelMode {
    var accessibilityTitle: String {
        switch self {
        case .linked:
            localized("Linked")
        case .stereo:
            localized("Separate left and right")
        }
    }
}

struct EditorTab: View {
    @Bindable var controller: SettingsController
    @State private var analysis: EQAnalysisSnapshot?
    @State private var lastRequestedAnalysisSignature: EQAnalysisSignature?

    var body: some View {
        let draftProfile = controller.draftProfile
        let channel = controller.editedChannel
        let contextID = controller.editorContextID
        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                SettingRow(title: localized("Channels")) {
                    Picker(localized("Channels"), selection: $controller.draftChannelMode) {
                        Text(localized("Linked")).tag(EQChannelMode.linked)
                        Text(localized("Separate L/R")).tag(EQChannelMode.stereo)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 230)
                    .accessibilityLabel(Text(localized("Channels")))
                    .accessibilityValue(Text(draftProfile.channelMode.accessibilityTitle))
                    .accessibilityHint(Text(localized("Chooses whether channels share one EQ or use separate left and right settings")))
                }

                if draftProfile.channelMode == .stereo {
                    SettingRow(title: localized("Editing")) {
                        Picker(localized("Editing"), selection: $controller.editChannel) {
                            ForEach(EQEditChannel.allCases) { editChannel in
                                Text(editChannel.title).tag(editChannel)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(maxWidth: 160)
                        .accessibilityLabel(Text(localized("Editing channel")))
                        .accessibilityValue(Text(controller.editChannel.title))
                        .accessibilityHint(Text(localized("Chooses which stereo channel is being edited")))
                    }
                }

                SliderRow(
                    title: localized("Preamp"),
                    value: $controller.draftProfile[channel: channel].preampDB,
                    range: -24...12,
                    validationRange: ProfilePersistence.preampRange,
                    step: 0.1,
                    suffix: "dB"
                )
                .id(contextID)

                SettingRow(title: localized("Bypass")) {
                    Toggle(localized("Bypass"), isOn: $controller.draftProfile.isBypassed)
                        .labelsHidden()
                        .accessibilityLabel(Text(localized("Bypass")))
                        .accessibilityValue(Text(draftProfile.isBypassed ? localized("On") : localized("Off")))
                        .accessibilityHint(Text(localized("Turns equalizer processing off without changing settings")))
                }

                if let analysis {
                    HeadroomRow(
                        profile: $controller.draftProfile,
                        recommendedPreampDB: analysis.recommendedPreampDB
                    )
                } else {
                    PendingHeadroomRow()
                }
            }
            .cardPanel(padding: 16)

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(localized("Frequency Response"))
                        .font(.headline)
                    Spacer()
                    if draftProfile.channelMode == .stereo {
                        GraphLegendItem(color: .blue, title: localized("Left"))
                        GraphLegendItem(color: .orange, title: localized("Right"))
                    }
                }
                // The most recent analysis stays on screen while a newer one computes. Swapping
                // in a placeholder on every slider tick would flicker and break the curve animation.
                if let analysis {
                    FrequencyResponseGraph(analysis: analysis)
                        .frame(height: 165)
                        .accessibilityLabel(Text(localized("Frequency response graph")))
                        .accessibilityValue(Text(analysis.accessibilitySummary))
                        .accessibilityHint(Text(localized("Shows the estimated gain curve from 20 Hz to \(localizedFrequency(analysis.maximumUsableFrequency))")))
                    if let inactiveFilterSummary = analysis.inactiveFilterSummary {
                        Label(inactiveFilterSummary, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                } else {
                    VStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(localized("Analyzing frequency response…"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 165)
                    .accessibilityElement(children: .combine)
                }
            }
            .cardPanel(padding: 16)

            switch draftProfile.mode {
            case .parametric:
                ParametricFilterEditor(filters: $controller.draftProfile[channel: channel].filters)
                    .id(contextID)
            case .graphic10, .graphic31:
                GraphicFilterEditor(filters: $controller.draftProfile[channel: channel].filters)
                    .id(contextID)
                    .cardPanel(padding: 16)
            case .convolution:
                if case .impulseResponse(let source) = draftProfile[channel: channel].convolution {
                    ImportedImpulseResponseEditor(source: source)
                        .id(contextID)
                        .cardPanel(padding: 16)
                } else {
                    MagnitudeCurveEditor(points: $controller.draftProfile[channel: channel].magnitudePoints)
                        .id(contextID)
                        .cardPanel(padding: 16)
                }
            }
        }
        .task(id: analysisSignature) {
            await refreshAnalysis()
        }
    }

    private var analysisSignature: EQAnalysisSignature {
        EQAnalysisSignature(profile: controller.draftProfile, sampleRate: controller.analysisSampleRate)
    }

    private func refreshAnalysis() async {
        let profile = controller.draftProfile
        let sampleRate = controller.analysisSampleRate
        let signature = EQAnalysisSignature(profile: profile, sampleRate: sampleRate)
        guard analysis?.signature != signature else {
            return
        }
        if let updatedAnalysis = analysis?.updatingPreamp(
            profile: profile,
            sampleRate: sampleRate
        ) {
            lastRequestedAnalysisSignature = signature
            analysis = updatedAnalysis
            return
        }

        let previousSignature = lastRequestedAnalysisSignature ?? analysis?.signature
        lastRequestedAnalysisSignature = signature
        let shouldDebounce = previousSignature?.mode == signature.mode
            && previousSignature?.channelMode == signature.channelMode

        do {
            if shouldDebounce {
                try await Task.sleep(for: .milliseconds(50))
            }
            let nextAnalysis = try await EQAnalysisSnapshot.analyze(
                profile: profile,
                sampleRate: sampleRate
            )
            try Task.checkCancellation()

            guard analysisSignature == nextAnalysis.signature else {
                return
            }
            analysis = nextAnalysis
        } catch {
            return
        }
    }
}

struct HeadroomRow: View {
    @Binding var profile: EQProfile
    var recommendedPreampDB: Double

    var body: some View {
        let needsHeadroom = recommendedPreampDB < profile.activePreampDB - 0.1
        let attenuation = profile.headroomAttenuation(toReach: recommendedPreampDB)
        let status = if !needsHeadroom {
            localized("OK")
        } else if attenuation == nil {
            localized("Required headroom exceeds the profile limit")
        } else {
            localized("Recommend \(localizedDecibels(recommendedPreampDB))")
        }
        SettingRow(title: localized("Headroom")) {
            Text(status)
                .font(.caption.monospacedDigit())
                .foregroundStyle(needsHeadroom ? Color.orange : Color.secondary)
                .accessibilityLabel(Text(localized("Headroom")))
                .accessibilityValue(Text(status))
            Spacer()
            Button(localized("Use Recommended")) {
                if let adjusted = profileApplyingRecommendedHeadroom(profile, recommendedPreampDB: recommendedPreampDB) {
                    profile = adjusted
                }
            }
            .disabled(!needsHeadroom || attenuation == nil)
            .controlSize(.large)
            .accessibilityHint(Text(localized("Applies the recommended preamp to avoid clipping")))
        }
    }
}

struct PendingHeadroomRow: View {
    var body: some View {
        SettingRow(title: localized("Headroom")) {
            ProgressView()
                .controlSize(.small)
            Text(localized("Analyzing…"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }
}
