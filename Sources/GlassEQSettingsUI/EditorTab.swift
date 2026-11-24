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
        let adjustedPreamps =
            switch channelMode {
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

    // True when the active profile settings would leave audio unchanged.
    var isNeutral: Bool {
        switch channelMode {
        case .linked:
            channelIsNeutral(.linked)
        case .stereo:
            channelIsNeutral(.left) && channelIsNeutral(.right)
        }
    }

    private func channelIsNeutral(_ channel: EQProfileChannel) -> Bool {
        let settings = self[channel: channel]
        guard settings.preampDB == 0 else {
            return false
        }
        switch mode {
        case .parametric, .graphic10, .graphic31:
            return settings.filters.allSatisfy { filter in
                guard filter.isEnabled else {
                    return true
                }
                switch filter.kind {
                case .peak, .lowShelf, .highShelf:
                    return filter.gainDB == 0
                case .highPass, .lowPass:
                    return false
                }
            }
        case .convolution:
            switch settings.convolution {
            case nil:
                return true
            case .magnitudeCurve(let curve):
                return curve.points.allSatisfy { $0.gainDB == 0 }
            case .impulseResponse:
                return false
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
    @State private var confirmsLink = false

    var body: some View {
        let draftProfile = controller.draftProfile
        let channel = controller.editedChannel
        Form {
            // Everything except the A/B controls locks while a comparison is running, so the
            // comparison can still be stopped.
            Group {
                if controller.snapshot.profiles.allSatisfy(\.isNeutral) {
                    Section {
                        StartingPointHint(
                            onImport: { controller.presentImport(.autoEQ) },
                            onCreate: { controller.isNewProfileSheetPresented = true }
                        )
                    }
                }

                Section {
                    HStack {
                        Text(localized("Channels"))
                        Spacer()
                        channelPickers
                    }
                    .accessibilityElement(children: .contain)

                    SliderRow(
                        title: localized("Preamp"),
                        value: $controller.draftProfile[channel: channel].preampDB,
                        range: -24...12,
                        validationRange: ProfilePersistence.preampRange,
                        step: 0.1,
                        suffix: "dB"
                    )

                    Toggle(localized("Bypass"), isOn: $controller.draftProfile.isBypassed)
                        .toggleStyle(.switch)
                        .accessibilityHint(Text(localized("Turns equalizer processing off without changing settings")))

                    EditorHeadroomRow(controller: controller)
                }

                EditorResponseSection(
                    profile: draftProfile,
                    sampleRate: controller.analysisSampleRate,
                    cache: controller.analysisCache
                )

                switch draftProfile.mode {
                case .parametric:
                    ParametricFilterEditor(filters: $controller.draftProfile[channel: channel].filters)
                case .graphic10, .graphic31:
                    GraphicFilterEditor(filters: $controller.draftProfile[channel: channel].filters)
                        .id(draftProfile.mode)
                case .convolution:
                    if case .impulseResponse(let source) = draftProfile[channel: channel].convolution {
                        ImportedImpulseResponseEditor(source: source)
                    } else {
                        MagnitudeCurveEditor(points: $controller.draftProfile[channel: channel].magnitudePoints)
                            .id(draftProfile.id)
                    }
                }
            }
            .disabled(controller.isEditingLocked)
        }
        .formStyle(.grouped)
        .environment(\.editorContext, controller.editorContextID)
        .alert(localized("Link left and right channels?"), isPresented: $confirmsLink) {
            Button(localized("Cancel"), role: .cancel) {}
            Button(localized("Link Channels"), role: .destructive) { controller.draftChannelMode = .linked }
        } message: {
            Text(
                controller.editChannel == .left
                    ? localized("Both channels will use the left channel’s settings.")
                    : localized("Both channels will use the right channel’s settings."))
        }
    }

    @ViewBuilder
    private var channelPickers: some View {
        Picker(
            localized("Channels"),
            selection: Binding(
                get: { controller.draftChannelMode },
                set: { mode in
                    if mode == .linked
                        && controller.draftProfile[channel: .left] != controller.draftProfile[channel: .right]
                    {
                        confirmsLink = true
                    } else {
                        controller.draftChannelMode = mode
                    }
                }
            )
        ) {
            Text(localized("Linked")).tag(EQChannelMode.linked)
            Text(localized("Separate L/R")).tag(EQChannelMode.stereo)
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .fixedSize()
        .accessibilityValue(Text(controller.draftChannelMode.accessibilityTitle))
        if controller.draftChannelMode == .stereo {
            Text(localized("Edit"))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Picker(localized("Edit"), selection: $controller.editChannel) {
                ForEach(EQEditChannel.allCases) { channel in
                    Text(channel.title).tag(channel)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()
            .accessibilityHint(Text(localized("Chooses which stereo channel is being edited")))
        }
    }
}

private struct EditorHeadroomRow: View {
    @Bindable var controller: SettingsController

    var body: some View {
        if let preamp = controller.analysisCache.analysis(
            for: controller.draftProfile, sampleRate: controller.analysisSampleRate
        )?.recommendedPreampDB {
            HeadroomRow(profile: $controller.draftProfile, recommendedPreampDB: preamp)
        } else {
            PendingHeadroomRow()
        }
    }
}

private struct EditorResponseSection: View {
    var profile: EQProfile
    var sampleRate: Double
    var cache: EQAnalysisCache

    var body: some View {
        let analysis = cache.analysis(for: profile, sampleRate: sampleRate)
        Section {
            // The most recent analysis stays on screen while a newer one computes. Swapping
            // in a placeholder on every slider tick would flicker and break the curve animation.
            if let analysis {
                FrequencyResponseGraph(analysis: analysis)
                    .frame(height: 140)
                    .accessibilityLabel(Text(localized("Frequency response graph")))
                    .accessibilityValue(Text(analysis.accessibilitySummary))
                    .accessibilityHint(
                        Text(
                            localized(
                                "Shows the estimated gain curve from 20 Hz to \(localizedFrequency(analysis.maximumUsableFrequency))"
                            )))
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
                .frame(maxWidth: .infinity, minHeight: 140)
                .accessibilityElement(children: .combine)
            }
        } header: {
            HStack {
                Text(localized("Frequency Response (dB)"))
                Spacer()
                if profile.channelMode == .stereo {
                    GraphLegendItem(color: .blue, title: localized("Left"))
                    GraphLegendItem(color: .orange, title: localized("Right"), dashed: true)
                }
            }
        }
    }
}

struct HeadroomRow: View {
    @Binding var profile: EQProfile
    var recommendedPreampDB: Double

    var body: some View {
        let needsHeadroom = recommendedPreampDB < profile.activePreampDB - 0.1
        let attenuation = profile.headroomAttenuation(toReach: recommendedPreampDB)
        let status =
            if !needsHeadroom {
                localized("No clipping expected")
            } else if attenuation == nil {
                localized("Required headroom exceeds the profile limit")
            } else {
                localized("Recommend \(localizedDecibels(recommendedPreampDB))")
            }
        LabeledContent(localized("Headroom")) {
            Text(status)
                .monospacedDigit()
                .foregroundStyle(needsHeadroom ? Color.orange : Color.secondary)
                .accessibilityLabel(Text(localized("Headroom")))
                .accessibilityValue(Text(status))
            if needsHeadroom, attenuation != nil {
                Button(localized("Use Recommended")) {
                    if let adjusted = profileApplyingRecommendedHeadroom(
                        profile, recommendedPreampDB: recommendedPreampDB)
                    {
                        profile = adjusted
                    }
                }
                .accessibilityHint(Text(localized("Applies the recommended preamp to avoid clipping")))
            }
        }
    }
}

struct PendingHeadroomRow: View {
    var body: some View {
        LabeledContent(localized("Headroom")) {
            ProgressView()
                .controlSize(.small)
            Text(localized("Analyzing…"))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
