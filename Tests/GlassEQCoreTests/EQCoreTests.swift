import Darwin
@testable import GlassEQCore
import Foundation
import Testing

@Suite
struct EQCoreTests {
    @Test
    func peakFilterBoostsNearCenterFrequency() {
        let filter = EQFilter(kind: .peak, frequency: 1_000, gainDB: 6, q: 1)
        let coefficients = BiquadCoefficients.make(filter: filter, sampleRate: 48_000)

        let magnitude = FrequencyResponse.magnitudeDB(
            for: coefficients,
            frequency: 1_000,
            sampleRate: 48_000
        )

        #expect(magnitude > 5.8)
        #expect(magnitude < 6.2)
    }

    @Test
    func frequencyResponsePointsMatchCoefficientMagnitudeSum() {
        let filters = [
            EQFilter(kind: .peak, frequency: 1_000, gainDB: 6, q: 1),
            EQFilter(kind: .highShelf, frequency: 8_000, gainDB: -3, q: 0.7)
        ]
        let points = FrequencyResponse.points(for: filters, preampDB: -2, sampleRate: 48_000, count: 5)
        let coefficients = filters.map { BiquadCoefficients.make(filter: $0, sampleRate: 48_000) }

        for point in points {
            let expected = coefficients.reduce(-2.0) { magnitude, coefficients in
                magnitude + FrequencyResponse.magnitudeDB(
                    for: coefficients,
                    frequency: point.frequency,
                    sampleRate: 48_000
                )
            }
            #expect(abs(point.magnitudeDB - expected) < 0.000_000_001)
        }
    }

    @Test
    func disabledFiltersDoNotAffectFrequencyResponse() {
        let disabled = EQFilter(
            kind: .peak,
            frequency: 1_000,
            gainDB: 18,
            q: 1,
            isEnabled: false
        )

        let points = FrequencyResponse.points(for: [disabled], preampDB: -3, sampleRate: 48_000, count: 8)

        #expect(points.allSatisfy { abs($0.magnitudeDB + 3) < 0.000_000_001 })
        #expect(abs(FrequencyResponse.peakMagnitudeDB(for: [disabled], preampDB: -3, sampleRate: 48_000) + 3) < 0.000_000_001)
    }

    @Test
    func routeFrequencyPolicyKeepsFiltersInsideNyquistGuardBand() {
        #expect(EQRouteFrequencyPolicy.maximumUsableFrequency(sampleRate: 48_000) == 20_000)
        #expect(EQRouteFrequencyPolicy.maximumUsableFrequency(sampleRate: 44_100) == 19_845)
        #expect(EQRouteFrequencyPolicy.maximumUsableFrequency(sampleRate: 16_000) == 7_200)
    }

    @Test
    func outOfBandFilterRendersAsIdentityWithoutChangingProfileFrequency() {
        let filter = EQFilter(kind: .peak, frequency: 20_000, gainDB: 12, q: 8)

        let lowRateCoefficients = BiquadCoefficients.make(filter: filter, sampleRate: 44_100)
        let fullRateCoefficients = BiquadCoefficients.make(filter: filter, sampleRate: 48_000)

        #expect(lowRateCoefficients == .identity)
        #expect(fullRateCoefficients != .identity)
        #expect(filter.frequency == 20_000)
    }

    @Test
    func outputRouteCeilingDisablesFilterWithoutChangingDSPRateOrFilterCount() {
        let profile = EQProfile(
            name: "Low-rate route",
            mode: .parametric,
            filters: [EQFilter(kind: .highShelf, frequency: 8_000, gainDB: 12, q: 0.7)]
        )
        let fullRate = EQRenderConfiguration(
            profile: profile,
            sampleRate: 48_000,
            channelCount: 2
        )
        let lowRateRoute = EQRenderConfiguration(
            profile: profile,
            sampleRate: 48_000,
            channelCount: 2,
            maximumUsableFrequency: 7_200
        )

        #expect(fullRate.configuration.coefficients[0] != .identity)
        #expect(lowRateRoute.configuration.sampleRate == 48_000)
        #expect(lowRateRoute.configuration.maximumUsableFrequency == 7_200)
        #expect(lowRateRoute.configuration.coefficients == [.identity])
        #expect(lowRateRoute.configuration.coefficients.count == fullRate.configuration.coefficients.count)
    }

    @Test
    func frequencyResponseStopsAtRouteCeilingAndIgnoresOutOfBandFilters() {
        let filter = EQFilter(kind: .highShelf, frequency: 8_000, gainDB: 12, q: 0.7)

        let points = FrequencyResponse.points(
            for: [filter],
            preampDB: -3,
            sampleRate: 16_000,
            count: 8
        )

        #expect(abs((points.last?.frequency ?? 0) - 7_200) < 0.000_000_001)
        #expect(points.allSatisfy { abs($0.magnitudeDB + 3) < 0.000_000_001 })
    }

    @Test
    func inactiveFilterCountUsesCurrentChannelModeAndIgnoresDisabledFilters() {
        let linkedProfile = EQProfile(
            name: "Linked",
            mode: .parametric,
            filters: [
                EQFilter(kind: .peak, frequency: 6_000, gainDB: 3),
                EQFilter(kind: .peak, frequency: 8_000, gainDB: 3),
                EQFilter(kind: .peak, frequency: 20_000, gainDB: 3, isEnabled: false)
            ]
        )
        let stereoProfile = EQProfile(
            name: "Stereo",
            mode: .parametric,
            channelMode: .stereo,
            filters: [],
            leftFilters: [EQFilter(kind: .peak, frequency: 8_000, gainDB: 3)],
            rightFilters: [EQFilter(kind: .peak, frequency: 20_000, gainDB: 3)]
        )

        #expect(EQRouteFrequencyPolicy.inactiveEnabledFilterCount(
            profile: linkedProfile,
            sampleRate: 16_000
        ) == 1)
        #expect(EQRouteFrequencyPolicy.inactiveEnabledFilterCount(
            profile: stereoProfile,
            sampleRate: 16_000
        ) == 2)
    }

    @Test
    func recommendedPreampUsesLouderStereoChannel() {
        let profile = EQProfile(
            name: "Stereo Headroom",
            mode: .parametric,
            channelMode: .stereo,
            preampDB: 0,
            filters: [],
            leftFilters: [EQFilter(kind: .peak, frequency: 1_000, gainDB: 12, q: 1)],
            rightFilters: [EQFilter(kind: .peak, frequency: 1_000, gainDB: -6, q: 1)]
        )

        let recommended = EQProfileAnalysis.recommendedPreampDB(profile: profile, sampleRate: 48_000)

        #expect(recommended < -11.5)
        #expect(recommended > -13.0)
    }

    @Test
    func recommendedPreampPreservesSafeStereoBalance() {
        let profile = EQProfile(
            name: "Stereo Cut",
            mode: .parametric,
            channelMode: .stereo,
            preampDB: 0,
            filters: [],
            leftPreampDB: -3,
            leftFilters: [EQFilter(kind: .peak, frequency: 1_000, gainDB: -6, q: 1)],
            rightPreampDB: -9,
            rightFilters: [EQFilter(kind: .peak, frequency: 1_000, gainDB: -3, q: 1)]
        )

        let recommended = EQProfileAnalysis.recommendedPreampDB(profile: profile, sampleRate: 48_000)

        #expect(recommended == -3)
    }

    @Test
    func recommendedPreampUsesUniformStereoAttenuation() {
        let profile = EQProfile(
            name: "Stereo balance",
            mode: .parametric,
            channelMode: .stereo,
            preampDB: 0,
            filters: [],
            leftPreampDB: 0,
            leftFilters: [],
            rightPreampDB: -20,
            rightFilters: [EQFilter(kind: .peak, frequency: 1_000, gainDB: 30, q: 1)]
        )

        let recommended = EQProfileAnalysis.recommendedPreampDB(
            profile: profile,
            sampleRate: 48_000
        )

        #expect(recommended < -10.49)
        #expect(recommended > -10.6)
    }

    @Test
    func recommendedPreampIsAnAbsoluteTargetAtNonzeroPreamp() {
        let profile = EQProfile(
            name: "Absolute headroom",
            mode: .parametric,
            preampDB: -6,
            filters: [EQFilter(kind: .peak, frequency: 1_000, gainDB: 12, q: 1)]
        )

        let recommended = EQProfileAnalysis.recommendedPreampDB(
            profile: profile,
            sampleRate: 48_000
        )

        #expect(recommended < -12.49)
        #expect(recommended > -12.6)
    }

    @Test
    func recommendedPreampBoundsNarrowLowFrequencyFloatPeak() {
        let filter = EQFilter(kind: .peak, frequency: 10, gainDB: 12, q: 100)
        let peak = FrequencyResponse.peakMagnitudeDB(
            for: [filter],
            preampDB: 0,
            sampleRate: 48_000
        )
        let profile = EQProfile(
            name: "Low narrow peak",
            mode: .parametric,
            filters: [filter]
        )
        let recommended = EQProfileAnalysis.recommendedPreampDB(
            profile: profile,
            sampleRate: 48_000
        )

        #expect(peak > 11.9)
        #expect(peak < 12.1)
        #expect(peak + recommended <= -0.49)
    }

    @Test
    func recommendedPreampBoundsNarrowHighFrequencyFloatPeak() {
        let filter = EQFilter(
            kind: .peak,
            frequency: 19_641.5878,
            gainDB: 12,
            q: 100
        )
        let peak = FrequencyResponse.peakMagnitudeDB(
            for: [filter],
            preampDB: 0,
            sampleRate: 48_000
        )
        let profile = EQProfile(
            name: "High narrow peak",
            mode: .parametric,
            filters: [filter]
        )
        let recommended = EQProfileAnalysis.recommendedPreampDB(
            profile: profile,
            sampleRate: 48_000
        )

        #expect(peak > 11.9)
        #expect(peak < 12.1)
        #expect(peak + recommended <= -0.49)
    }

    @Test
    func recommendedPreampIncludesHighShelfResponseAboveGraphCeiling() {
        let filter = EQFilter(
            kind: .highShelf,
            frequency: 18_000,
            gainDB: 12,
            q: 0.707
        )

        let peak = FrequencyResponse.peakMagnitudeDB(
            for: [filter],
            preampDB: 0,
            sampleRate: 48_000
        )
        let profile = EQProfile(
            name: "High shelf",
            mode: .parametric,
            filters: [filter]
        )
        let recommended = EQProfileAnalysis.recommendedPreampDB(
            profile: profile,
            sampleRate: 48_000
        )

        #expect(peak > 11.9)
        #expect(peak < 12.1)
        #expect(peak + recommended <= -0.49)
    }

    @Test
    func separatedBoostsDoNotProduceSummedHeadroomRecommendation() {
        let filters = [80.0, 180, 400, 900, 2_000, 4_500, 10_000, 18_000].map {
            EQFilter(kind: .peak, frequency: $0, gainDB: 6, q: 20)
        }

        let peak = FrequencyResponse.peakMagnitudeDB(
            for: filters,
            preampDB: 0,
            sampleRate: 48_000
        )

        #expect(peak > 5.9)
        #expect(peak < 8)
    }

    @Test
    func renderConfigurationRejectsMarginalFloatRoundedPole() {
        let filter = EQFilter(
            kind: .peak,
            frequency: 1,
            gainDB: -12,
            q: 0.707
        )
        let profile = EQProfile(
            name: "Marginal pole",
            mode: .parametric,
            filters: [filter]
        )

        let configuration = EQRenderConfiguration(
            profile: profile,
            sampleRate: 48_000,
            channelCount: 1
        )
        let peak = FrequencyResponse.peakMagnitudeDB(
            for: [filter],
            preampDB: 0,
            sampleRate: 48_000
        )

        #expect(!configuration.isNumericallySafe)
        #expect(peak.isInfinite)
        #expect(throws: EQRenderConfigurationError.numericallyUnsafe) {
            _ = try EQRenderConfiguration.prepare(
                profile: profile,
                sampleRate: 48_000,
                channelCount: 1
            )
        }
    }

    @Test
    func responseCurveAnalysisUsesCurvePeakAndLogFrequencyInterpolation() {
        var profile = EQProfile.flatConvolution
        profile.preampDB = -2
        profile.convolution = .magnitudeCurve(MagnitudeCurveSource(points: [
            EQMagnitudePoint(frequency: 20, gainDB: 0),
            EQMagnitudePoint(frequency: 200, gainDB: 8),
            EQMagnitudePoint(frequency: 20_000, gainDB: -3)
        ]))

        let recommended = EQProfileAnalysis.recommendedPreampDB(
            profile: profile,
            sampleRate: 48_000
        )
        let response = FrequencyResponse.points(
            for: profile.convolution,
            preampDB: profile.preampDB,
            sampleRate: 48_000,
            count: 3
        )

        #expect(recommended < -8.5)
        #expect(recommended > -8.8)
        #expect(abs(response[0].magnitudeDB + 2) < 0.000_001)
        #expect(response.count == 3)
    }

    @Test
    func impulseResponseRecommendationBoundsNarrowInterProbePeak() {
        let sampleRate = 48_000.0
        let frameCount = ImpulseResponseSource.maximumFrameCount
        let frequencyBin = 4_041
        let frequency = sampleRate * Double(frequencyBin) / Double(frameCount)
        let targetMagnitude = pow(10, 12.0 / 20)
        let coefficientScale = 2 * targetMagnitude / Double(frameCount)
        let samples = (0..<frameCount).map { index in
            Float(coefficientScale * cos(
                2 * Double.pi * Double(frequencyBin * index) / Double(frameCount)
            ))
        }
        let profile = EQProfile(
            name: "Narrow peak",
            mode: .convolution,
            filters: [],
            convolution: .impulseResponse(ImpulseResponseSource(
                sampleRate: sampleRate,
                samples: samples
            ))
        )

        let renderedPeak = impulseMagnitudeDB(
            samples: samples,
            frequency: frequency,
            sampleRate: sampleRate
        )
        let recommended = EQProfileAnalysis.recommendedPreampDB(
            profile: profile,
            sampleRate: sampleRate
        )

        #expect(samples.count == ImpulseResponseSource.maximumFrameCount)
        #expect(abs(renderedPeak - 12) < 0.001)
        #expect(renderedPeak + recommended <= -0.49)
        #expect(recommended > -12.8)
        #expect(recommended < -12.5)
    }

    @Test
    func importedImpulseRecommendationUsesCertifiedNonPowerOfTwoBound() {
        let sampleRate = 48_000.0
        let frameCount = 1_000
        let frequencyBin = 37
        let frequency = sampleRate * Double(frequencyBin) / Double(frameCount)
        let targetMagnitude = pow(10, 12.0 / 20)
        let coefficientScale = 2 * targetMagnitude / Double(frameCount)
        let samples = (0..<frameCount).map { index in
            Float(coefficientScale * cos(
                2 * Double.pi * Double(frequencyBin * index) / Double(frameCount)
            ))
        }
        let profile = EQProfile(
            name: "Non-power-of-two impulse",
            mode: .convolution,
            filters: [],
            convolution: .impulseResponse(ImpulseResponseSource(
                sampleRate: sampleRate,
                samples: samples
            ))
        )

        let renderedPeak = impulseMagnitudeDB(
            samples: samples,
            frequency: frequency,
            sampleRate: sampleRate
        )
        let recommended = EQProfileAnalysis.recommendedPreampDB(
            profile: profile,
            sampleRate: sampleRate
        )

        #expect(abs(renderedPeak - 12) < 0.001)
        #expect(renderedPeak + recommended <= -0.49)
        #expect(recommended > -12.8)
        #expect(recommended < -12.5)
    }

    @Test
    func responseCurveRecommendationBoundsCompiledUnsortedCurve() throws {
        let sampleRate = 16_000.0
        let routeCeiling = EQRouteFrequencyPolicy.maximumUsableFrequency(sampleRate: sampleRate)
        let frameCount = MinimumPhaseFIRCompiler.tapCount
        let frequencyBin = Int(routeCeiling * Double(frameCount) / sampleRate)
        let frequency = sampleRate * Double(frequencyBin) / Double(frameCount)
        var curve = MagnitudeCurveSource(points: [
            EQMagnitudePoint(frequency: 20, gainDB: 0),
            EQMagnitudePoint(frequency: 1_000, gainDB: 0),
            EQMagnitudePoint(frequency: 10_000, gainDB: 12)
        ])
        curve.points.swapAt(1, 2)
        let profile = EQProfile(
            name: "Unsorted curve",
            mode: .convolution,
            filters: [],
            convolution: .magnitudeCurve(curve)
        )
        let impulse = try MinimumPhaseFIRCompiler.compile(
            points: curve.points,
            sampleRate: sampleRate,
            maximumUsableFrequency: routeCeiling
        )

        let compiledPeak = impulseMagnitudeDB(
            samples: impulse,
            frequency: frequency,
            sampleRate: sampleRate
        )
        let recommended = EQProfileAnalysis.recommendedPreampDB(
            profile: profile,
            sampleRate: sampleRate
        )
        let response = FrequencyResponse.points(
            for: profile.convolution,
            preampDB: profile.preampDB,
            sampleRate: sampleRate,
            count: 8
        )
        let displayedPeak = response.last?.magnitudeDB ?? -.infinity

        #expect(compiledPeak > 10.2)
        #expect(compiledPeak < 10.4)
        #expect(displayedPeak > 10.2)
        #expect(displayedPeak < 10.4)
        #expect(compiledPeak + recommended <= -0.49)
    }

    @Test
    func responseCurveRecommendationBoundsRouteCeilingTransition() throws {
        let sampleRate = 16_000.0
        let routeCeiling = EQRouteFrequencyPolicy.maximumUsableFrequency(sampleRate: sampleRate)
        let curve = MagnitudeCurveSource(points: [
            EQMagnitudePoint(frequency: 20, gainDB: 0),
            EQMagnitudePoint(frequency: 7_000, gainDB: 12),
            EQMagnitudePoint(frequency: 7_200, gainDB: 12),
            EQMagnitudePoint(frequency: 7_300, gainDB: 0)
        ])
        let profile = EQProfile(
            name: "Route boundary",
            mode: .convolution,
            filters: [],
            convolution: .magnitudeCurve(curve)
        )
        let impulse = try MinimumPhaseFIRCompiler.compile(
            points: curve.points,
            sampleRate: sampleRate,
            maximumUsableFrequency: routeCeiling
        )

        let compiledPeak = impulseMagnitudeDB(
            samples: impulse,
            frequency: 7_197.8,
            sampleRate: sampleRate
        )
        let recommended = EQProfileAnalysis.recommendedPreampDB(
            profile: profile,
            sampleRate: sampleRate
        )

        #expect(compiledPeak > 11.9)
        #expect(compiledPeak < 12.1)
        #expect(compiledPeak + recommended <= -0.49)
    }

    @Test
    func convolutionRuntimeUsesIdentityAboveRouteCeiling() throws {
        let sampleRate = 16_000.0
        let profile = EQProfile(
            name: "Route-limited curve",
            mode: .convolution,
            filters: [],
            convolution: .magnitudeCurve(MagnitudeCurveSource(points: [
                EQMagnitudePoint(frequency: 20, gainDB: 0),
                EQMagnitudePoint(frequency: 7_200, gainDB: 0),
                EQMagnitudePoint(frequency: 7_300, gainDB: 12)
            ]))
        )
        let renderConfiguration = try EQRenderConfiguration.prepare(
            profile: profile,
            sampleRate: sampleRate,
            channelCount: 1
        )
        var processor = EQProcessor(renderConfiguration: renderConfiguration)
        var impulse = [Float](repeating: 0, count: MinimumPhaseFIRCompiler.tapCount)
        impulse[0] = 1

        processor.processInterleaved(&impulse, channelCount: 1)

        #expect(renderConfiguration.configuration.maximumUsableFrequency == 7_200)
        #expect(abs(impulseMagnitudeDB(
            samples: impulse,
            frequency: 7_300,
            sampleRate: sampleRate
        )) < 0.05)
    }

    @Test
    func routeCeilingDoesNotAlterImportedImpulseResponse() throws {
        let samples: [Float] = [0.5, -0.25, 0.125, -0.0625]
        let profile = EQProfile(
            name: "Imported impulse",
            mode: .convolution,
            filters: [],
            convolution: .impulseResponse(ImpulseResponseSource(
                sampleRate: 16_000,
                samples: samples
            ))
        )
        let renderConfiguration = try EQRenderConfiguration.prepare(
            profile: profile,
            sampleRate: 16_000,
            channelCount: 1,
            maximumUsableFrequency: 4_000
        )
        var processor = EQProcessor(renderConfiguration: renderConfiguration)
        var impulse = [Float](repeating: 0, count: 16)
        impulse[0] = 1

        processor.processInterleaved(&impulse, channelCount: 1)

        #expect(Array(impulse.prefix(samples.count)) == samples)
    }

    @Test
    func bypassLeavesSamplesUntouched() {
        var profile = EQProfile(
            name: "Bypass",
            mode: .parametric,
            filters: [EQFilter(kind: .peak, frequency: 1_000, gainDB: 12, q: 1)]
        )
        profile.isBypassed = true

        var processor = EQProcessor(configuration: EQConfiguration(profile: profile, sampleRate: 48_000, channelCount: 2))
        var samples: [Float] = [0.1, -0.2, 0.3, -0.4]

        processor.processInterleaved(&samples, channelCount: 2)

        #expect(samples == [0.1, -0.2, 0.3, -0.4])
    }

    @Test
    func processorPassesThroughOutOfRangeChannels() {
        let profile = EQProfile(
            name: "Gain",
            mode: .parametric,
            preampDB: 6,
            filters: []
        )
        var processor = EQProcessor(configuration: EQConfiguration(profile: profile, sampleRate: 48_000, channelCount: 2))
        var channels: [[Float]] = [
            [0.1, 0.2],
            [0.1, 0.2],
            [0.1, 0.2]
        ]

        processor.processNonInterleaved(&channels)
        let outOfRange = processor.processSampleWithDiagnostics(0.25, channel: 4)

        #expect(channels[0][0] > 0.1)
        #expect(channels[1][0] > 0.1)
        #expect(channels[2] == [0.1, 0.2])
        #expect(outOfRange.sample == 0.25)
        #expect(!outOfRange.saturated)
    }

    @Test
    func biquadStateFlushesDenormalsAndNonFiniteValues() {
        var denormalState = BiquadState()
        denormalState.z1 = 1.0e-30
        denormalState.z2 = -1.0e-30

        let denormalOutput = denormalState.process(0, coefficients: .identity)

        #expect(denormalOutput == 0)
        #expect(denormalState.z1 == 0)
        #expect(denormalState.z2 == 0)

        var nonFiniteState = BiquadState()
        nonFiniteState.z1 = .nan
        nonFiniteState.z2 = .infinity

        let nonFiniteOutput = nonFiniteState.process(0.25, coefficients: .identity)

        #expect(nonFiniteOutput == 0)
        #expect(nonFiniteState.z1 == 0)
        #expect(nonFiniteState.z2 == 0)
    }

    @Test
    func graphicProfilesHaveExpectedBandCounts() {
        #expect(EQProfile.flatGraphic10.filters.count == 10)
        #expect(EQProfile.flatGraphic31.filters.count == 31)
        #expect(EQProfile.flatGraphic31.leftFilters.count == 31)
        #expect(EQProfile.flatGraphic31.rightFilters.count == 31)
    }

    @Test
    func stereoProfileProcessesLeftAndRightIndependently() {
        let leftFilter = EQFilter(kind: .peak, frequency: 1_000, gainDB: 12, q: 1)
        let rightFilter = EQFilter(kind: .peak, frequency: 1_000, gainDB: -12, q: 1)
        let profile = EQProfile(
            name: "Stereo",
            mode: .parametric,
            channelMode: .stereo,
            preampDB: 0,
            filters: [],
            leftFilters: [leftFilter],
            rightFilters: [rightFilter]
        )

        var processor = EQProcessor(configuration: EQConfiguration(profile: profile, sampleRate: 48_000, channelCount: 2))
        var samples = Array(repeating: Float(0), count: 2 * 256)
        for index in stride(from: 0, to: samples.count, by: 2) {
            samples[index] = 0.2
            samples[index + 1] = 0.2
        }

        processor.processInterleaved(&samples, channelCount: 2)

        let leftPeak = stride(from: 0, to: samples.count, by: 2).map { samples[$0] }.max() ?? 0
        let rightPeak = stride(from: 1, to: samples.count, by: 2).map { samples[$0] }.max() ?? 0
        #expect(leftPeak > rightPeak)
    }

    @Test
    func floatRuntimeMatchesLegacyDoublePathForComplexStereoBlock() {
        let profile = EQProfile(
            name: "Complex Stereo",
            mode: .parametric,
            channelMode: .stereo,
            preampDB: -3,
            filters: [],
            leftPreampDB: -3,
            leftFilters: [
                EQFilter(kind: .peak, frequency: 55, gainDB: 4.5, q: 4),
                EQFilter(kind: .lowShelf, frequency: 110, gainDB: 2.5, q: 0.8),
                EQFilter(kind: .highShelf, frequency: 9_000, gainDB: -3.5, q: 0.7),
                EQFilter(kind: .highPass, frequency: 24, gainDB: 0, q: 0.707)
            ],
            rightPreampDB: -4,
            rightFilters: [
                EQFilter(kind: .peak, frequency: 1_250, gainDB: -5, q: 7),
                EQFilter(kind: .lowPass, frequency: 18_000, gainDB: 0, q: 0.707),
                EQFilter(kind: .highShelf, frequency: 12_000, gainDB: 2, q: 0.9),
                EQFilter(kind: .peak, frequency: 72, gainDB: 3, q: 5)
            ]
        )
        let sampleRate = 48_000.0
        var runtimeSamples = makeStereoTestBlock(frameCount: 1_024, sampleRate: sampleRate)
        var legacySamples = runtimeSamples
        var processor = EQProcessor(configuration: EQConfiguration(profile: profile, sampleRate: sampleRate, channelCount: 2))

        processor.processInterleaved(&runtimeSamples, channelCount: 2)
        legacyProcessInterleaved(&legacySamples, profile: profile, sampleRate: sampleRate, channelCount: 2)

        let maxDelta = zip(runtimeSamples, legacySamples)
            .map { abs($0 - $1) }
            .max() ?? 0
        #expect(maxDelta < 0.000_5)
    }

    @Test
    func floatRuntimeMatchesLegacyDoublePathForImpulse() {
        let profile = EQProfile(name: "Graphic", mode: .graphic31, preampDB: -6, filters: EQProfile.flatGraphic31.filters.enumerated().map { index, filter in
            var filter = filter
            filter.gainDB = Double((index % 7) - 3)
            return filter
        })
        let sampleRate = 48_000.0
        var runtimeSamples = [Float](repeating: 0, count: 2 * 512)
        runtimeSamples[0] = 0.8
        runtimeSamples[1] = -0.4
        var legacySamples = runtimeSamples
        var processor = EQProcessor(configuration: EQConfiguration(profile: profile, sampleRate: sampleRate, channelCount: 2))

        processor.processInterleaved(&runtimeSamples, channelCount: 2)
        legacyProcessInterleaved(&legacySamples, profile: profile, sampleRate: sampleRate, channelCount: 2)

        let maxDelta = zip(runtimeSamples, legacySamples)
            .map { abs($0 - $1) }
            .max() ?? 0
        #expect(maxDelta < 0.000_05)
    }

    @Test
    func interleavedDiagnosticsReportSaturation() {
        let profile = EQProfile(name: "Hot", mode: .parametric, preampDB: 24, filters: [])
        var processor = EQProcessor(configuration: EQConfiguration(profile: profile, sampleRate: 48_000, channelCount: 2))
        var samples: [Float] = [0.5, -0.5, 0.25, -0.25]

        let saturated = samples.withUnsafeMutableBufferPointer {
            processor.processInterleavedWithDiagnostics($0, frameCount: 2, channelCount: 2)
        }

        #expect(saturated == 4)
        #expect(samples.allSatisfy { $0.isFinite })
        #expect(samples.allSatisfy { abs($0) <= 1 })
    }

    @Test
    func dspCallbackPathStaysWithinGenerousDebugBudget() {
        guard !isThreadSanitizerRuntimeLoaded else {
            return
        }
        let profile = EQProfile.flatGraphic31
        var processor = EQProcessor(configuration: EQConfiguration(profile: profile, sampleRate: 48_000, channelCount: 2))
        var samples = makeStereoTestBlock(frameCount: 256, sampleRate: 48_000)
        let clock = ContinuousClock()
        let start = clock.now

        for _ in 0..<256 {
            _ = samples.withUnsafeMutableBufferPointer {
                processor.processInterleavedWithDiagnostics($0, frameCount: 256, channelCount: 2)
            }
        }

        #expect(start.duration(to: clock.now) < .seconds(2))
    }

    @Test
    func programmeComparisonCallbackPathStaysWithinGenerousDebugBudget() {
        guard !isThreadSanitizerRuntimeLoaded else {
            return
        }
        let profile = EQProfile.flatGraphic31
        var transition = RealtimeEQTransition(
            activeProcessor: EQProcessor(configuration: EQConfiguration(
                profile: profile,
                sampleRate: 48_000,
                channelCount: 2
            )),
            maximumFrameCount: 64,
            channelCount: 2,
            sampleRate: 48_000
        )
        let didBegin = transition.beginProgrammeComparison(
            equalizedProcessor: EQProcessor(configuration: EQConfiguration(
                profile: profile,
                sampleRate: 48_000,
                channelCount: 2
            )),
            filtersOffProcessor: EQProcessor(configuration: EQConfiguration(
                profile: profile.programmeComparisonReference,
                sampleRate: 48_000,
                channelCount: 2
            ))
        )
        #expect(didBegin)
        var samples = makeStereoTestBlock(frameCount: 64, sampleRate: 48_000)
        for _ in 0..<24 {
            _ = samples.withUnsafeMutableBufferPointer {
                transition.processInterleavedWithDiagnostics(
                    $0,
                    frameCount: 64,
                    channelCount: 2
                )
            }
        }

        let clock = ContinuousClock()
        let start = clock.now
        for _ in 0..<1_024 {
            _ = samples.withUnsafeMutableBufferPointer {
                transition.processInterleavedWithDiagnostics(
                    $0,
                    frameCount: 64,
                    channelCount: 2
                )
            }
        }

        #expect(start.duration(to: clock.now) < .seconds(4))
    }

    @Test
    func preparedRenderConfigurationMatchesConfigurationInitializer() {
        let profile = EQProfile(
            name: "Prepared",
            mode: .parametric,
            preampDB: -3,
            filters: [
                EQFilter(kind: .peak, frequency: 1_000, gainDB: 4, q: 1.2),
                EQFilter(kind: .highShelf, frequency: 8_000, gainDB: -2, q: 0.7)
            ]
        )
        let configuration = EQConfiguration(profile: profile, sampleRate: 48_000, channelCount: 2)
        var directProcessor = EQProcessor(configuration: configuration)
        var preparedProcessor = EQProcessor(renderConfiguration: EQRenderConfiguration(configuration: configuration))
        var directSamples = makeStereoTestBlock(frameCount: 128, sampleRate: 48_000)
        var preparedSamples = directSamples

        directProcessor.processInterleaved(&directSamples, channelCount: 2)
        preparedProcessor.processInterleaved(&preparedSamples, channelCount: 2)

        for index in directSamples.indices {
            #expect(abs(directSamples[index] - preparedSamples[index]) < 0.000_001)
        }
    }

    @Test
    func preparedRenderConfigurationCanBeAppliedWithoutChangingTopology() {
        let initial = EQProfile(
            name: "Initial",
            mode: .parametric,
            filters: [EQFilter(kind: .peak, frequency: 500, gainDB: 2, q: 1)]
        )
        let updated = EQProfile(
            name: "Updated",
            mode: .parametric,
            filters: [EQFilter(kind: .peak, frequency: 500, gainDB: -2, q: 1)]
        )
        var processor = EQProcessor(configuration: EQConfiguration(profile: initial, sampleRate: 48_000, channelCount: 2))
        processor.applyPreparedConfiguration(EQRenderConfiguration(profile: updated, sampleRate: 48_000, channelCount: 2))
        var samples = makeStereoTestBlock(frameCount: 64, sampleRate: 48_000)

        processor.processInterleaved(&samples, channelCount: 2)

        #expect(samples.allSatisfy { $0.isFinite })
    }

    @Test
    func coefficientChangeResetsMatchingTopologyState() {
        let initial = EQProfile(
            name: "Initial",
            mode: .parametric,
            filters: [EQFilter(kind: .peak, frequency: 500, gainDB: 8, q: 1)]
        )
        let updated = EQProfile(
            name: "Updated",
            mode: .parametric,
            filters: [EQFilter(kind: .peak, frequency: 2_000, gainDB: -8, q: 1)]
        )
        var warmed = EQProcessor(configuration: EQConfiguration(profile: initial, sampleRate: 48_000, channelCount: 2))
        var warmup = makeStereoTestBlock(frameCount: 512, sampleRate: 48_000)
        warmed.processInterleaved(&warmup, channelCount: 2)
        warmed.applyPreparedConfiguration(EQRenderConfiguration(profile: updated, sampleRate: 48_000, channelCount: 2))

        var fresh = EQProcessor(configuration: EQConfiguration(profile: updated, sampleRate: 48_000, channelCount: 2))
        var warmedNext = makeStereoTestBlock(frameCount: 128, sampleRate: 48_000)
        var freshNext = warmedNext
        warmed.processInterleaved(&warmedNext, channelCount: 2)
        fresh.processInterleaved(&freshNext, channelCount: 2)

        let maxDelta = zip(warmedNext, freshNext).map { abs($0 - $1) }.max() ?? 0
        #expect(maxDelta < 0.000_001)
    }

    @Test
    func processorCopiesKeepIndependentMutableState() {
        let profile = EQProfile(
            name: "Stateful",
            mode: .parametric,
            filters: [
                EQFilter(kind: .lowPass, frequency: 1_200, gainDB: 0, q: 0.707),
                EQFilter(kind: .peak, frequency: 220, gainDB: 6, q: 2)
            ]
        )
        var original = EQProcessor(configuration: EQConfiguration(profile: profile, sampleRate: 48_000, channelCount: 2))
        var copied = original
        var warmed = makeStereoTestBlock(frameCount: 256, sampleRate: 48_000)
        original.processInterleaved(&warmed, channelCount: 2)

        var originalNext = makeStereoTestBlock(frameCount: 64, sampleRate: 48_000)
        var copiedNext = originalNext
        var freshNext = originalNext
        var fresh = EQProcessor(configuration: EQConfiguration(profile: profile, sampleRate: 48_000, channelCount: 2))

        original.processInterleaved(&originalNext, channelCount: 2)
        copied.processInterleaved(&copiedNext, channelCount: 2)
        fresh.processInterleaved(&freshNext, channelCount: 2)

        let copiedFreshDelta = zip(copiedNext, freshNext).map { abs($0 - $1) }.max() ?? 0
        let copiedOriginalDelta = zip(copiedNext, originalNext).map { abs($0 - $1) }.max() ?? 0
        #expect(copiedFreshDelta < 0.000_001)
        #expect(copiedOriginalDelta > 0.000_001)
    }

    @Test
    func wholeBankTransitionUsesSampleAccurateSmoothstepBlend() {
        let active = EQProfile(name: "Active", mode: .parametric, filters: [])
        let incoming = EQProfile(
            name: "Incoming",
            mode: .parametric,
            preampDB: 6.020_599_913,
            filters: []
        )
        var transition = RealtimeEQTransition(
            activeProcessor: EQProcessor(configuration: EQConfiguration(
                profile: active,
                sampleRate: 1_000,
                channelCount: 1
            )),
            maximumFrameCount: 4,
            channelCount: 1,
            sampleRate: 1_000,
            warmupSeconds: 0,
            blendSeconds: 0.004
        )
        let didBegin = transition.beginTransition(to: EQProcessor(configuration: EQConfiguration(
            profile: incoming,
            sampleRate: 1_000,
            channelCount: 1
        )))
        #expect(didBegin)
        var samples = [Float](repeating: 0.25, count: 4)

        let result = samples.withUnsafeMutableBufferPointer {
            transition.processInterleavedWithDiagnostics(
                $0,
                frameCount: 4,
                channelCount: 1
            )
        }

        #expect(abs(samples[0] - 0.25) < 0.000_001)
        #expect(abs(samples[1] - 0.314_814_8) < 0.000_001)
        #expect(abs(samples[2] - 0.435_185_2) < 0.000_001)
        #expect(abs(samples[3] - 0.5) < 0.000_001)
        #expect(result.completedTransition)
        #expect(result.retiredProcessor != nil)
        #expect(!transition.isTransitioning)
    }

    @Test
    func wholeBankTransitionWarmsIncomingBankBeforeBlending() {
        let active = EQProfile(name: "Active", mode: .parametric, filters: [])
        let incoming = EQProfile(
            name: "Incoming",
            mode: .parametric,
            preampDB: 6.020_599_913,
            filters: []
        )
        var transition = RealtimeEQTransition(
            activeProcessor: EQProcessor(configuration: EQConfiguration(
                profile: active,
                sampleRate: 1_000,
                channelCount: 1
            )),
            maximumFrameCount: 4,
            channelCount: 1,
            sampleRate: 1_000,
            warmupSeconds: 0.004,
            blendSeconds: 0.004
        )
        let didBegin = transition.beginTransition(to: EQProcessor(configuration: EQConfiguration(
            profile: incoming,
            sampleRate: 1_000,
            channelCount: 1
        )))
        #expect(didBegin)
        var warmup = [Float](repeating: 0.25, count: 4)

        let warmupResult = warmup.withUnsafeMutableBufferPointer {
            transition.processInterleavedWithDiagnostics(
                $0,
                frameCount: 4,
                channelCount: 1
            )
        }

        #expect(warmup == [0.25, 0.25, 0.25, 0.25])
        #expect(!warmupResult.completedTransition)
        #expect(transition.isTransitioning)
    }

    @Test
    func convolutionTransitionWarmsEntireImpulseHistoryBeforeBlending() throws {
        let active = EQProfile(name: "Active", mode: .parametric, filters: [])
        var incoming = EQProfile.flatConvolution
        incoming.preampDB = 6.020_599_913
        let incomingConfiguration = try EQRenderConfiguration.prepare(
            profile: incoming,
            sampleRate: 48_000,
            channelCount: 1
        )
        var transition = RealtimeEQTransition(
            activeProcessor: EQProcessor(configuration: EQConfiguration(
                profile: active,
                sampleRate: 48_000,
                channelCount: 1
            )),
            maximumFrameCount: 480,
            channelCount: 1,
            sampleRate: 48_000,
            warmupSeconds: 0,
            blendSeconds: 4.0 / 48_000
        )
        let didBegin = transition.beginTransition(to: EQProcessor(
            renderConfiguration: incomingConfiguration
        ))
        #expect(didBegin)

        var renderedFrames = 0
        var observedTailCompletion = false
        while renderedFrames < PreparedConvolutionKernel.tapCount - 1 {
            let frameCount = min(
                480,
                PreparedConvolutionKernel.tapCount - 1 - renderedFrames
            )
            var samples = [Float](repeating: 0.25, count: frameCount)
            let result = samples.withUnsafeMutableBufferPointer {
                transition.processInterleavedWithDiagnostics(
                    $0,
                    frameCount: frameCount,
                    channelCount: 1
                )
            }
            #expect(samples.allSatisfy { abs($0 - 0.25) < 0.000_001 })
            #expect(!result.completedTransition)
            #expect(result.workTiming.directHeadHostTicks > 0)
            #expect(result.workTiming.tailDeadlineMisses == 0)
            observedTailCompletion = observedTailCompletion
                || result.workTiming.tailCompletionObservations > 0
            renderedFrames += frameCount
        }
        #expect(observedTailCompletion)

        var blend = [Float](repeating: 0.25, count: 4)
        let blendResult = blend.withUnsafeMutableBufferPointer {
            transition.processInterleavedWithDiagnostics(
                $0,
                frameCount: 4,
                channelCount: 1
            )
        }
        #expect(abs(blend[0] - 0.25) < 0.000_01)
        #expect(abs(blend[3] - 0.5) < 0.000_01)
        #expect(blendResult.completedTransition)
    }

    @Test
    func wholeBankTransitionAllowsFilterTopologyChanges() {
        let active = EQProfile(name: "Active", mode: .parametric, filters: [])
        let incoming = EQProfile(
            name: "Incoming",
            mode: .parametric,
            filters: [
                EQFilter(kind: .lowShelf, frequency: 120, gainDB: 3, q: 0.7),
                EQFilter(kind: .peak, frequency: 1_500, gainDB: -4, q: 2)
            ]
        )
        var transition = RealtimeEQTransition(
            activeProcessor: EQProcessor(configuration: EQConfiguration(
                profile: active,
                sampleRate: 1_000,
                channelCount: 1
            )),
            maximumFrameCount: 4,
            channelCount: 1,
            sampleRate: 1_000,
            warmupSeconds: 0,
            blendSeconds: 0.004
        )

        let didBegin = transition.beginTransition(to: EQProcessor(configuration: EQConfiguration(
            profile: incoming,
            sampleRate: 1_000,
            channelCount: 1
        )))
        #expect(didBegin)

        var samples = [Float](repeating: 0.1, count: 4)
        let result = samples.withUnsafeMutableBufferPointer {
            transition.processInterleavedWithDiagnostics(
                $0,
                frameCount: 4,
                channelCount: 1
            )
        }

        #expect(result.completedTransition)
        #expect(!transition.isTransitioning)
    }

    @Test
    func wholeBankTransitionCanBlendToBypass() {
        let active = EQProfile(
            name: "Active",
            mode: .parametric,
            preampDB: 6.020_599_913,
            filters: []
        )
        var bypassed = active
        bypassed.isBypassed = true
        var transition = RealtimeEQTransition(
            activeProcessor: EQProcessor(configuration: EQConfiguration(
                profile: active,
                sampleRate: 1_000,
                channelCount: 1
            )),
            maximumFrameCount: 4,
            channelCount: 1,
            sampleRate: 1_000,
            warmupSeconds: 0,
            blendSeconds: 0.004
        )
        let didBegin = transition.beginTransition(to: EQProcessor(configuration: EQConfiguration(
            profile: bypassed,
            sampleRate: 1_000,
            channelCount: 1
        )))
        #expect(didBegin)
        var samples = [Float](repeating: 0.25, count: 4)

        let result = samples.withUnsafeMutableBufferPointer {
            transition.processInterleavedWithDiagnostics(
                $0,
                frameCount: 4,
                channelCount: 1
            )
        }

        #expect(abs(samples[0] - 0.5) < 0.000_001)
        #expect(abs(samples[3] - 0.25) < 0.000_001)
        #expect(result.completedTransition)

        var steadyState = [Float](repeating: 0.25, count: 4)
        let steadyStateResult = steadyState.withUnsafeMutableBufferPointer {
            transition.processInterleavedWithDiagnostics(
                $0,
                frameCount: 4,
                channelCount: 1
            )
        }
        #expect(steadyState == [0.25, 0.25, 0.25, 0.25])
        #expect(!steadyStateResult.completedTransition)
    }

    @Test
    func programmeComparisonReferenceKeepsPreampAndDisablesOnlyFilters() {
        let profile = EQProfile(
            name: "Stereo",
            mode: .parametric,
            channelMode: .stereo,
            preampDB: -7,
            filters: [
                EQFilter(kind: .peak, frequency: 1_000, gainDB: 4, q: 1)
            ],
            leftPreampDB: -5,
            leftFilters: [
                EQFilter(kind: .lowShelf, frequency: 100, gainDB: 3, q: 0.7)
            ],
            rightPreampDB: -9,
            rightFilters: [
                EQFilter(kind: .highShelf, frequency: 8_000, gainDB: -2, q: 0.7)
            ]
        )
        var bypassed = profile
        bypassed.isBypassed = true

        let reference = bypassed.programmeComparisonReference

        #expect(reference.preampDB == -7)
        #expect(reference.leftPreampDB == -5)
        #expect(reference.rightPreampDB == -9)
        #expect(reference.channelMode == .stereo)
        #expect(reference.filters.isEmpty)
        #expect(reference.leftFilters.isEmpty)
        #expect(reference.rightFilters.isEmpty)
        #expect(!reference.isBypassed)
    }

    @Test
    func programmeComparisonReferenceKeepsConvolutionPreampAndDisablesCurve() {
        var profile = EQProfile.flatConvolution
        profile.preampDB = -8
        profile.isBypassed = true

        let reference = profile.programmeComparisonReference

        #expect(reference.preampDB == -8)
        #expect(reference.mode == .parametric)
        #expect(reference.convolution == nil)
        #expect(reference.leftConvolution == nil)
        #expect(reference.rightConvolution == nil)
        #expect(!reference.isBypassed)
    }

    @Test
    func programmeLoudnessMatcherAttenuatesOnlyTheLouderBranch() {
        let sampleRate = 48_000.0
        let frameCount = Int(sampleRate * 4)
        var equalized = [Float](repeating: 0, count: frameCount * 2)
        var filtersOff = [Float](repeating: 0, count: frameCount * 2)
        for frame in 0..<frameCount {
            let sample = Float(sin(2 * Double.pi * 1_000 * Double(frame) / sampleRate))
            equalized[frame * 2] = sample * 0.2
            equalized[frame * 2 + 1] = sample * 0.2
            filtersOff[frame * 2] = sample * 0.1
            filtersOff[frame * 2 + 1] = sample * 0.1
        }
        var matcher = RealtimeProgrammeLoudnessMatcher(
            sampleRate: sampleRate,
            channelCount: 2
        )

        equalized.withUnsafeBufferPointer { equalizedSamples in
            filtersOff.withUnsafeBufferPointer { filtersOffSamples in
                for frame in 0..<frameCount {
                    _ = matcher.observeFrame(
                        equalized: equalizedSamples,
                        filtersOff: filtersOffSamples,
                        sampleOffset: frame * 2,
                        channelCount: 2
                    )
                }
            }
        }

        let match = matcher.snapshot
        #expect(match.isReady)
        #expect(abs(match.equalizedAttenuationDB + 6.0206) < 0.02)
        #expect(abs(match.filtersOffAttenuationDB) < 0.000_001)
    }

    @Test
    func kWeightingCoefficientsMatchBS1770At48KHz() {
        let shelf = KWeightingCoefficients.kWeightingShelf(sampleRate: 48_000)
        #expect(abs(shelf.b0 - 1.535_124_9) < 0.000_001)
        #expect(abs(shelf.b1 + 2.691_696_2) < 0.000_001)
        #expect(abs(shelf.b2 - 1.198_392_9) < 0.000_001)
        #expect(abs(shelf.a1 + 1.690_659_3) < 0.000_001)
        #expect(abs(shelf.a2 - 0.732_480_76) < 0.000_001)

        let highPass = KWeightingCoefficients.kWeightingHighPass(sampleRate: 48_000)
        #expect(highPass.b0 == 1)
        #expect(highPass.b1 == -2)
        #expect(highPass.b2 == 1)
        #expect(abs(highPass.a1 + 1.990_047_5) < 0.000_001)
        #expect(abs(highPass.a2 - 0.990_072_25) < 0.000_001)
    }

    @Test
    func programmeComparisonTransitionsIntoBothBranchesAndBackOut() {
        let active = EQProfile(name: "Active", mode: .parametric, filters: [])
        let equalized = EQProfile(
            name: "Equalized",
            mode: .parametric,
            preampDB: 6.020_599_913,
            filters: []
        )
        let filtersOff = EQProfile(name: "Filters off", mode: .parametric, filters: [])
        var transition = RealtimeEQTransition(
            activeProcessor: EQProcessor(configuration: EQConfiguration(
                profile: active,
                sampleRate: 48_000,
                channelCount: 1
            )),
            maximumFrameCount: 4,
            channelCount: 1,
            sampleRate: 48_000,
            warmupSeconds: 0,
            blendSeconds: 4.0 / 48_000
        )

        let didBeginComparison = transition.beginProgrammeComparison(
            equalizedProcessor: EQProcessor(configuration: EQConfiguration(
                profile: equalized,
                sampleRate: 48_000,
                channelCount: 1
            )),
            filtersOffProcessor: EQProcessor(configuration: EQConfiguration(
                profile: filtersOff,
                sampleRate: 48_000,
                channelCount: 1
            ))
        )
        #expect(didBeginComparison)
        var entry = [Float](repeating: 0.25, count: 4)
        let entryResult = entry.withUnsafeMutableBufferPointer {
            transition.processInterleavedWithDiagnostics(
                $0,
                frameCount: 4,
                channelCount: 1
            )
        }
        #expect(entryResult.completedTransition)
        #expect(entryResult.programmeComparison.isActive)
        #expect(abs(entry[0] - 0.25) < 0.000_001)
        #expect(abs(entry[3] - 0.5) < 0.000_001)

        transition.setProgrammeComparisonSelection(.filtersOff)
        var comparison = [Float](repeating: 0.25, count: 4)
        let comparisonResult = comparison.withUnsafeMutableBufferPointer {
            transition.processInterleavedWithDiagnostics(
                $0,
                frameCount: 4,
                channelCount: 1
            )
        }
        #expect(comparisonResult.programmeComparison.isActive)
        #expect(abs(comparison[0] - 0.5) < 0.000_001)
        #expect(abs(comparison[3] - 0.25) < 0.000_001)

        let didBeginExit = transition.beginTransition(to: EQProcessor(configuration: EQConfiguration(
            profile: active,
            sampleRate: 48_000,
            channelCount: 1
        )))
        #expect(didBeginExit)
        var exitSelection = [Float](repeating: 0.25, count: 4)
        _ = exitSelection.withUnsafeMutableBufferPointer {
            transition.processInterleavedWithDiagnostics(
                $0,
                frameCount: 4,
                channelCount: 1
            )
        }
        var exitProfile = [Float](repeating: 0.25, count: 4)
        let exitResult = exitProfile.withUnsafeMutableBufferPointer {
            transition.processInterleavedWithDiagnostics(
                $0,
                frameCount: 4,
                channelCount: 1
            )
        }
        #expect(exitResult.completedTransition)
        #expect(exitResult.retiredProcessor != nil)
        #expect(exitResult.secondRetiredProcessor != nil)
        #expect(!exitResult.programmeComparison.isActive)
        #expect(abs(exitProfile[0] - 0.5) < 0.000_001)
        #expect(abs(exitProfile[3] - 0.25) < 0.000_001)
    }

    @Test
    func programmeComparisonPublishesReadinessDuringSteadyStateRendering() {
        let sampleRate = 48_000.0
        let blockFrames = 4_800
        let active = EQProfile(name: "Active", mode: .parametric, filters: [])
        let equalized = EQProfile(
            name: "Equalized",
            mode: .parametric,
            preampDB: 6.020_599_913,
            filters: []
        )
        let filtersOff = EQProfile(name: "Filters off", mode: .parametric, filters: [])
        var transition = RealtimeEQTransition(
            activeProcessor: EQProcessor(configuration: EQConfiguration(
                profile: active,
                sampleRate: sampleRate,
                channelCount: 1
            )),
            maximumFrameCount: blockFrames,
            channelCount: 1,
            sampleRate: sampleRate,
            warmupSeconds: 0,
            blendSeconds: Double(blockFrames) / sampleRate
        )
        let didBegin = transition.beginProgrammeComparison(
            equalizedProcessor: EQProcessor(configuration: EQConfiguration(
                profile: equalized,
                sampleRate: sampleRate,
                channelCount: 1
            )),
            filtersOffProcessor: EQProcessor(configuration: EQConfiguration(
                profile: filtersOff,
                sampleRate: sampleRate,
                channelCount: 1
            ))
        )
        #expect(didBegin)

        var lastResult = EQTransitionRenderResult()
        for block in 0..<40 {
            var samples = (0..<blockFrames).map { frame in
                Float(sin(
                    2 * Double.pi * 1_000
                        * Double(block * blockFrames + frame)
                        / sampleRate
                )) * 0.1
            }
            lastResult = samples.withUnsafeMutableBufferPointer {
                transition.processInterleavedWithDiagnostics(
                    $0,
                    frameCount: blockFrames,
                    channelCount: 1
                )
            }
        }

        #expect(lastResult.programmeComparison.isActive)
        #expect(lastResult.programmeComparison.isReady)
        #expect(lastResult.programmeComparison.equalizedAttenuationDB < -5.9)
        #expect(abs(lastResult.programmeComparison.filtersOffAttenuationDB) < 0.001)
    }

    @Test
    func renderConfigurationRejectsNonFinitePreamp() {
        let profile = EQProfile(
            name: "Invalid",
            mode: .parametric,
            preampDB: .nan,
            filters: []
        )

        let configuration = EQRenderConfiguration(
            profile: profile,
            sampleRate: 48_000,
            channelCount: 2
        )

        #expect(!configuration.isNumericallySafe)
    }

    @Test
    func profileDecoderDefaultsMissingStereoFieldsToLinked() throws {
        let json = """
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "name": "Legacy",
          "mode": "parametric",
          "preampDB": 0,
          "filters": [],
          "isBypassed": false
        }
        """

        let profile = try ProfilePersistence.decoder.decode(EQProfile.self, from: Data(json.utf8))
        #expect(profile.channelMode == EQChannelMode.linked)
        #expect(profile.leftFilters == profile.filters)
        #expect(profile.rightFilters == profile.filters)
    }

    @Test
    func profileMappingUsesOutputUID() {
        let profile = EQProfile(name: "USB DAC", mode: .graphic31, filters: EQProfile.flatGraphic31.filters)
        let store = ProfileStore(
            profiles: [.flatParametric, profile],
            outputMappings: [OutputDeviceProfileMapping(outputDeviceUID: "dac-uid", profileID: profile.id)],
            fallbackProfileID: EQProfile.flatParametric.id
        )

        #expect(store.profile(forOutputUID: "dac-uid").id == profile.id)
        #expect(store.profile(forOutputUID: "other").name == "Flat")
    }

    @Test
    func profileStoreRepairRestoresDefaultsAndFallbackWhenProfilesAreEmpty() {
        var store = ProfileStore(profiles: [], fallbackProfileID: UUID())

        let summary = store.repairReferences()

        #expect(summary.restoredDefaultProfiles)
        #expect(summary.repairedFallbackProfileID)
        #expect(summary.didRepair)
        #expect(store.profiles == ProfileStore.defaultProfiles)
        #expect(store.fallbackProfileID == ProfileStore.defaultProfiles[0].id)
    }

    @Test
    func profileStoreRepairRemovesInvalidMappingsAndKeepsLastOutputUIDMapping() {
        let first = EQProfile(name: "First", mode: .parametric, filters: [])
        let second = EQProfile(name: "Second", mode: .parametric, filters: [])
        let missingProfileID = UUID()
        var store = ProfileStore(
            profiles: [first, second],
            outputMappings: [
                OutputDeviceProfileMapping(outputDeviceUID: "", profileID: first.id),
                OutputDeviceProfileMapping(outputDeviceUID: "dac", profileID: missingProfileID),
                OutputDeviceProfileMapping(outputDeviceUID: "dac", profileID: first.id),
                OutputDeviceProfileMapping(outputDeviceUID: "speaker", profileID: second.id),
                OutputDeviceProfileMapping(outputDeviceUID: "dac", profileID: second.id)
            ],
            fallbackProfileID: missingProfileID
        )

        let summary = store.repairReferences()

        #expect(summary.repairedFallbackProfileID)
        #expect(summary.removedOutputMappings == 2)
        #expect(summary.deduplicatedOutputMappings == 1)
        #expect(store.fallbackProfileID == first.id)
        #expect(store.outputMappings == [
            OutputDeviceProfileMapping(outputDeviceUID: "speaker", profileID: second.id),
            OutputDeviceProfileMapping(outputDeviceUID: "dac", profileID: second.id)
        ])
    }

    @Test
    func profileLookupFallsBackToFirstProfileThenFlatProfile() {
        let first = EQProfile(name: "First", mode: .parametric, filters: [])
        let storeWithBrokenFallback = ProfileStore(profiles: [first], fallbackProfileID: UUID())
        let emptyStore = ProfileStore(profiles: [], fallbackProfileID: UUID())

        #expect(storeWithBrokenFallback.profile(forOutputUID: nil).id == first.id)
        #expect(emptyStore.profile(forOutputUID: nil).id == EQProfile.flatParametric.id)
    }

    @Test
    func profileStoreRoundTripsThroughJSON() throws {
        let store = ProfileStore()
        let data = try ProfilePersistence.encode(store)
        let decoded = try ProfilePersistence.decode(data)

        #expect(decoded.profiles.count == store.profiles.count)
        #expect(decoded.outputMappings == store.outputMappings)
    }

    private func makeStereoTestBlock(frameCount: Int, sampleRate: Double) -> [Float] {
        var samples = [Float](repeating: 0, count: frameCount * 2)
        for frame in 0..<frameCount {
            let time = Double(frame) / sampleRate
            samples[frame * 2] = Float(0.18 * sin(2 * Double.pi * 73 * time) + 0.07 * sin(2 * Double.pi * 1_007 * time))
            samples[frame * 2 + 1] = Float(0.16 * sin(2 * Double.pi * 211 * time) - 0.05 * sin(2 * Double.pi * 6_300 * time))
        }
        return samples
    }

    private func impulseMagnitudeDB(
        samples: [Float],
        frequency: Double,
        sampleRate: Double
    ) -> Double {
        let omega = 2 * Double.pi * frequency / sampleRate
        var real = 0.0
        var imaginary = 0.0
        for (index, sample) in samples.enumerated() {
            let phase = -omega * Double(index)
            real += Double(sample) * cos(phase)
            imaginary += Double(sample) * sin(phase)
        }
        return 20 * log10(max(hypot(real, imaginary), .leastNonzeroMagnitude))
    }

    private func legacyProcessInterleaved(
        _ samples: inout [Float],
        profile: EQProfile,
        sampleRate: Double,
        channelCount: Int
    ) {
        let configuration = EQConfiguration(profile: profile, sampleRate: sampleRate, channelCount: channelCount)
        guard !configuration.isBypassed else {
            return
        }

        var states = configuration.channelConfigurations.map {
            Array(repeating: BiquadState(), count: $0.coefficients.count)
        }
        let channelCount = max(channelCount, 1)
        var sampleIndex = 0
        while sampleIndex < samples.count {
            for channel in 0..<min(channelCount, states.count) where sampleIndex + channel < samples.count {
                let channelConfiguration = configuration.channelConfigurations[channel]
                var value = samples[sampleIndex + channel] * channelConfiguration.preampLinearGain
                for filterIndex in channelConfiguration.coefficients.indices {
                    value = states[channel][filterIndex].process(value, coefficients: channelConfiguration.coefficients[filterIndex])
                }
                samples[sampleIndex + channel] = legacySaturate(value)
            }
            sampleIndex += channelCount
        }
    }

    private func legacySaturate(_ value: Float) -> Float {
        guard value.isFinite else {
            return 0
        }

        let threshold: Float = 0.98
        if value > threshold {
            return threshold + (1 - threshold) * tanh((value - threshold) / (1 - threshold))
        }
        if value < -threshold {
            return -threshold + (1 - threshold) * tanh((value + threshold) / (1 - threshold))
        }
        return value
    }
}

private var isThreadSanitizerRuntimeLoaded: Bool {
    for index in 0..<_dyld_image_count() {
        guard let imageName = _dyld_get_image_name(index) else {
            continue
        }
        if String(cString: imageName).contains("libclang_rt.tsan") {
            return true
        }
    }
    return false
}
