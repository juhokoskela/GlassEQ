import GlassEQCore
import Testing
@testable import GlassEQSettingsUI

@Suite
struct EditorProfileConversionTests {
    @Test
    func convertingToGraphicModesProducesFlatBandsAndClearsConvolution() {
        var source = EQProfile.flatConvolution
        source.channelMode = .stereo
        source.leftConvolution = source.convolution
        source.rightConvolution = source.convolution

        let graphic31 = source.convertedToMode(.graphic31)
        #expect(graphic31.mode == .graphic31)
        #expect(graphic31.filters.map(\.frequency) == GraphicEQBands.thirtyOneBand)
        #expect(graphic31.leftFilters == graphic31.filters)
        #expect(graphic31.rightFilters == graphic31.filters)
        #expect(graphic31.filters.allSatisfy { $0.gainDB == 0 })
        #expect(graphic31.convolution == nil)
        #expect(graphic31.leftConvolution == nil)
        #expect(graphic31.rightConvolution == nil)
        #expect(graphic31.channelMode == .stereo)
        #expect(graphic31.id == source.id)

        let graphic10 = source.convertedToMode(.graphic10)
        #expect(graphic10.filters.map(\.frequency) == GraphicEQBands.tenBand)
    }

    @Test
    func convertingToParametricStartsWithOneNeutralPeak() {
        let parametric = EQProfile.flatGraphic31.convertedToMode(.parametric)
        #expect(parametric.mode == .parametric)
        #expect(parametric.filters.count == 1)
        #expect(parametric.filters.first?.kind == .peak)
        #expect(parametric.filters.first?.gainDB == 0)
    }

    @Test
    func convertingToResponseCurveInstallsAFlatCurveOnEveryChannel() {
        let curve = EQProfile.flatGraphic10.convertedToMode(.convolution)
        #expect(curve.mode == .convolution)
        #expect(curve.filters.isEmpty)
        #expect(curve.leftFilters.isEmpty)
        #expect(curve.convolution == EQProfile.flatConvolution.convolution)
        #expect(curve.leftConvolution == curve.convolution)
        #expect(curve.rightConvolution == curve.convolution)
    }

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
