import Darwin
import GlassEQCore
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
    func outputRouteCeilingDisablesFilterWithoutChangingDSPRateOrTopology() {
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
        #expect(lowRateRoute.hasRealtimeCompatibleTopology(with: fullRate))
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
    func recommendedPreampFallbackUsesQuieterStereoPreamp() {
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

        #expect(recommended == -9)
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
        #expect(transition.activeConfiguration.coefficients.count == 2)
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
        #expect(transition.activeConfiguration.isBypassed)
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
