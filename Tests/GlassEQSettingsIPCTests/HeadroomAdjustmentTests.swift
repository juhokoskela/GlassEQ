import GlassEQCore
import Testing
@testable import GlassEQSettingsUI

@Suite
struct HeadroomAdjustmentTests {
    @Test
    func stereoRecommendationPreservesChannelBalance() throws {
        let profile = EQProfile(
            name: "Stereo",
            mode: .parametric,
            channelMode: .stereo,
            filters: [],
            leftPreampDB: 0,
            leftFilters: [],
            rightPreampDB: -20,
            rightFilters: []
        )

        let adjusted = try #require(profileApplyingRecommendedHeadroom(
            profile,
            recommendedPreampDB: -10.5
        ))

        #expect(adjusted.leftPreampDB == -10.5)
        #expect(adjusted.rightPreampDB == -30.5)
    }

    @Test
    func recommendationCannotExceedThePersistedPreampRange() {
        let profile = EQProfile(
            name: "Limited Stereo",
            mode: .parametric,
            channelMode: .stereo,
            filters: [],
            leftPreampDB: 0,
            leftFilters: [],
            rightPreampDB: -119,
            rightFilters: []
        )

        #expect(profileApplyingRecommendedHeadroom(
            profile,
            recommendedPreampDB: -2
        ) == nil)
    }
}
