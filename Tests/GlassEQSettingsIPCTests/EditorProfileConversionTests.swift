import GlassEQCore
import Testing
@testable import GlassEQSettingsUI

@Suite
struct EditorProfileConversionTests {
    @Test
    func splittingChannelsCopiesTheLinkedSettingsToBothSides() {
        var linked = EQProfile.flatParametric
        linked.filters = [EQFilter(kind: .peak, frequency: 200, gainDB: -3, q: 1)]
        linked.preampDB = -2.5

        let stereo = linked.convertedToChannelMode(.stereo, editedChannel: .left)
        #expect(stereo.channelMode == .stereo)
        #expect(stereo.leftFilters == linked.filters)
        #expect(stereo.rightFilters == linked.filters)
        #expect(stereo.leftPreampDB == -2.5)
        #expect(stereo.rightPreampDB == -2.5)
    }

    @Test
    func linkingChannelsKeepsTheChannelBeingEdited() {
        var stereo = EQProfile.flatParametric
        stereo.channelMode = .stereo
        stereo.leftFilters = [EQFilter(kind: .peak, frequency: 100, gainDB: 1, q: 1)]
        stereo.rightFilters = [EQFilter(kind: .peak, frequency: 5_000, gainDB: -4, q: 2)]
        stereo.leftPreampDB = -1
        stereo.rightPreampDB = -6

        let fromRight = stereo.convertedToChannelMode(.linked, editedChannel: .right)
        #expect(fromRight.channelMode == .linked)
        #expect(fromRight.filters == stereo.rightFilters)
        #expect(fromRight.preampDB == -6)

        let fromLeft = stereo.convertedToChannelMode(.linked, editedChannel: .left)
        #expect(fromLeft.filters == stereo.leftFilters)
        #expect(fromLeft.preampDB == -1)
    }

    @Test(arguments: [FilterKind.highPass, .lowPass])
    func enabledCutoffFiltersAreNotNeutral(_ kind: FilterKind) {
        var profile = EQProfile.flatParametric
        profile.filters = [EQFilter(kind: kind, frequency: 100)]

        #expect(!profile.isNeutral)

        profile.filters[0].isEnabled = false
        #expect(profile.isNeutral)
    }

    @Test
    func neutralCheckIgnoresInactiveChannelStorage() {
        var profile = EQProfile.flatParametric
        profile.leftPreampDB = -3
        profile.rightFilters = [EQFilter(kind: .highPass, frequency: 100)]

        #expect(profile.channelMode == .linked)
        #expect(profile.isNeutral)
    }

    @Test
    func neutralCheckUsesOnlyTheActiveProfileMode() {
        let profile = EQProfile(
            name: "Flat response curve",
            mode: .convolution,
            filters: [EQFilter(kind: .highPass, frequency: 100)],
            convolution: .magnitudeCurve(MagnitudeCurveSource(points: [
                EQMagnitudePoint(frequency: 20, gainDB: 0),
                EQMagnitudePoint(frequency: 20_000, gainDB: 0)
            ]))
        )

        #expect(profile.isNeutral)
    }
}
