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
}
