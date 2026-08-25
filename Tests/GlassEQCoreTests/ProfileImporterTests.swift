import GlassEQCore
import Testing

@Suite
struct ProfileImporterTests {
    @Test
    func importsEqualizerAPOText() throws {
        let text = """
        Preamp: -5.4 dB
        Filter 1: ON PK Fc 105 Hz Gain -2.1 dB Q 1.41
        Filter 2: ON LS Fc 80 Hz Gain 3.0 dB Q 0.70
        """

        let profile = try EQProfileTextImporter.importAutoEQ(text)

        #expect(profile.preampDB == -5.4)
        #expect(profile.filters.count == 2)
        #expect(profile.filters[0].kind == .peak)
        #expect(profile.filters[0].frequency == 105)
        #expect(profile.filters[0].gainDB == -2.1)
        #expect(profile.filters[1].kind == .lowShelf)
    }

    @Test
    func importsEqualizerAPOGraphicEQAsMagnitudeCurve() throws {
        let text = """
        Preamp: -6.2 dB
        GraphicEQ: 20 -0.2; 100 3.5; 1000 -2.1; 20000 0.4
        """

        let profile = try EQProfileTextImporter.importAutoEQ(text)

        #expect(profile.mode == .convolution)
        #expect(profile.preampDB == -6.2)
        #expect(profile.filters.isEmpty)
        guard case .magnitudeCurve(let curve) = profile.convolution else {
            Issue.record("Expected a magnitude-curve convolution source")
            return
        }
        #expect(curve.synthesisVersion == MinimumPhaseFIRCompiler.synthesisVersion)
        #expect(curve.points.map(\.frequency) == [20, 100, 1_000, 20_000])
        #expect(curve.points.map(\.gainDB) == [-0.2, 3.5, -2.1, 0.4])
    }

    @Test
    func importsUnsortedGraphicEQPointsInFrequencyOrder() throws {
        let profile = try EQProfileTextImporter.importAutoEQ(
            "GraphicEQ: 1000 -2; 20 1; 20000 0"
        )

        guard case .magnitudeCurve(let curve) = profile.convolution else {
            Issue.record("Expected a magnitude-curve convolution source")
            return
        }
        #expect(curve.points.map(\.frequency) == [20, 1_000, 20_000])
    }

    @Test
    func rejectsDuplicateGraphicEQFrequencies() throws {
        #expect(throws: ProfileImportError.duplicateMagnitudeFrequency(
            line: 1,
            frequency: 100
        )) {
            _ = try EQProfileTextImporter.importAutoEQ(
                "GraphicEQ: 20 0; 100 1; 100 -1"
            )
        }
    }

    @Test
    func rejectsMixedGraphicEQAndFilterDirectives() throws {
        let text = """
        Preamp: -4 dB
        GraphicEQ: 20 0; 1000 3; 20000 0
        Filter 1: ON PK Fc 1000 Hz Gain -2 dB Q 1
        """

        #expect(throws: ProfileImportError.mixedEqualizerAPOFormats(
            graphicEQLine: 2,
            filterLine: 3
        )) {
            _ = try EQProfileTextImporter.importAutoEQ(text)
        }
    }

    @Test
    func importsChannelGraphicEQWithCommentsAndPreamps() throws {
        let text = """
        # Filter 1: this comment is not an active filter
        Preamp: -4 dB
        Channel: L
        Preamp: -5 dB
        GraphicEQ: 20 0; 20000 -1
        Channel: R
        GraphicEQ: 20 -2; 20000 1
        """

        let profile = try EQProfileTextImporter.importAutoEQ(text)

        #expect(profile.channelMode == .stereo)
        #expect(profile.preampDB == -4)
        #expect(profile.leftPreampDB == -5)
        #expect(profile.rightPreampDB == -4)
        guard case .magnitudeCurve = profile.leftConvolution,
              case .magnitudeCurve = profile.rightConvolution else {
            Issue.record("Expected separate magnitude curves")
            return
        }
    }

    @Test
    func graphicEQExportRoundTripsStereoCurvesAndPreamps() throws {
        let left = EQConvolutionSource.magnitudeCurve(MagnitudeCurveSource(points: [
            EQMagnitudePoint(frequency: 20, gainDB: 2),
            EQMagnitudePoint(frequency: 20_000, gainDB: -1)
        ]))
        let right = EQConvolutionSource.magnitudeCurve(MagnitudeCurveSource(points: [
            EQMagnitudePoint(frequency: 20, gainDB: -3),
            EQMagnitudePoint(frequency: 20_000, gainDB: 1.5)
        ]))
        let profile = EQProfile(
            name: "Stereo Curve",
            mode: .convolution,
            channelMode: .stereo,
            preampDB: -4,
            filters: [],
            leftPreampDB: -5,
            leftFilters: [],
            rightPreampDB: -6,
            rightFilters: [],
            leftConvolution: left,
            rightConvolution: right
        )

        let exported = try EQProfileTextExporter.exportEqualizerAPO(profile)
        let imported = try EQProfileTextImporter.importAutoEQ(exported)

        #expect(imported.mode == .convolution)
        #expect(imported.channelMode == .stereo)
        #expect(imported.preampDB == -4)
        #expect(imported.leftPreampDB == -5)
        #expect(imported.rightPreampDB == -6)
        guard case .magnitudeCurve(let importedLeft) = imported.leftConvolution,
              case .magnitudeCurve(let importedRight) = imported.rightConvolution,
              case .magnitudeCurve(let expectedLeft) = left,
              case .magnitudeCurve(let expectedRight) = right else {
            Issue.record("Expected stereo magnitude curves")
            return
        }
        #expect(importedLeft.points.map(\.frequency) == expectedLeft.points.map(\.frequency))
        #expect(importedLeft.points.map(\.gainDB) == expectedLeft.points.map(\.gainDB))
        #expect(importedRight.points.map(\.frequency) == expectedRight.points.map(\.frequency))
        #expect(importedRight.points.map(\.gainDB) == expectedRight.points.map(\.gainDB))
    }

    @Test
    func ignoresDisabledEqualizerAPOFilters() throws {
        let text = """
        Filter 1: OFF BP Fc 1000 Hz Gain 6 dB Q 1
        Filter 2: OFF
        Filter 3: ON PK Fc 2000 Hz Gain 3 dB Q 1
        """

        let profile = try EQProfileTextImporter.importAutoEQ(text)

        #expect(profile.filters.count == 1)
        #expect(profile.filters[0].frequency == 2_000)
    }

    @Test
    func rejectsUnsupportedEnabledEqualizerAPOFiltersWithoutPartialImport() throws {
        let text = """
        Filter 1: ON PK Fc 2000 Hz Gain 3 dB Q 1
        Filter 2: ON BP Fc 1000 Hz Gain 6 dB Q 1
        """

        #expect(throws: ProfileImportError.unsupportedEqualizerAPOFilter(
            line: 2,
            kind: "BP"
        )) {
            _ = try EQProfileTextImporter.importAutoEQ(text)
        }
    }

    @Test
    func rejectsEnabledEqualizerAPOFilterWithoutKind() throws {
        let text = """
        Filter 1: ON PK Fc 2000 Hz Gain 3 dB Q 1
        Filter 2: ON
        """

        #expect(throws: ProfileImportError.unsupportedEqualizerAPOFilter(
            line: 2,
            kind: nil
        )) {
            _ = try EQProfileTextImporter.importAutoEQ(text)
        }
    }

    @Test
    func rejectsImpulseResponseEqualizerAPOExport() throws {
        let profile = EQProfile(
            name: "Imported IR",
            mode: .convolution,
            filters: [],
            convolution: .impulseResponse(ImpulseResponseSource(
                sampleRate: 48_000,
                samples: [1, 0]
            ))
        )

        #expect(throws: EQProfileTextExportError.impulseResponseUnsupported) {
            _ = try EQProfileTextExporter.exportEqualizerAPO(profile)
        }
    }

    @Test
    func importsEqualizerAPOChannelSectionsAsStereoProfile() throws {
        let text = """
        Preamp: -5.96 dB

        Channel: L
        Filter 1:  ON  PK  Fc 37 Hz  Gain 6 dB  Q 1
        Filter 2:  ON  PK  Fc 47 Hz  Gain -16.7 dB  Q 5

        Channel: R
        Filter 1:  ON  PK  Fc 61 Hz  Gain 2.7 dB  Q 7.5
        Filter 2:  ON  PK  Fc 67 Hz  Gain -6.8 dB  Q 5
        """

        let profile = try EQProfileTextImporter.importAutoEQ(text)

        #expect(profile.channelMode == EQChannelMode.stereo)
        #expect(profile.preampDB == -5.96)
        #expect(profile.leftPreampDB == -5.96)
        #expect(profile.rightPreampDB == -5.96)
        #expect(profile.filters.isEmpty)
        #expect(profile.leftFilters.count == 2)
        #expect(profile.rightFilters.count == 2)
        #expect(profile.leftFilters[0].frequency == 37)
        #expect(profile.leftFilters[1].gainDB == -16.7)
        #expect(profile.rightFilters[0].frequency == 61)
        #expect(profile.rightFilters[1].q == 5)
    }

    @Test
    func importsEqualizerAPOChannelPreampsWithoutFiltersAsStereoProfile() throws {
        let text = """
        Preamp: -1 dB

        Channel: L
        Preamp: -3 dB

        Channel: R
        Preamp: -4 dB
        """

        let profile = try EQProfileTextImporter.importAutoEQ(text)

        #expect(profile.channelMode == .stereo)
        #expect(profile.preampDB == -1)
        #expect(profile.leftPreampDB == -3)
        #expect(profile.rightPreampDB == -4)
        #expect(profile.filters.isEmpty)
        #expect(profile.leftFilters.isEmpty)
        #expect(profile.rightFilters.isEmpty)
    }

    @Test
    func importsEqualizerAPOChannelPreampsWithLinkedFiltersAsStereoFallback() throws {
        let text = """
        Preamp: -1 dB
        Filter 1: ON PK Fc 1000 Hz Gain 2 dB Q 1

        Channel: L
        Preamp: -3 dB

        Channel: R
        Preamp: -4 dB
        """

        let profile = try EQProfileTextImporter.importAutoEQ(text)

        #expect(profile.channelMode == .stereo)
        #expect(profile.preampDB == -1)
        #expect(profile.leftPreampDB == -3)
        #expect(profile.rightPreampDB == -4)
        #expect(profile.filters.count == 1)
        #expect(profile.leftFilters == profile.filters)
        #expect(profile.rightFilters == profile.filters)
    }

    @Test
    func importsREWText() throws {
        let text = """
        Filter 1: ON PK Fc 45.0 Hz Gain -4.5 dB Q 3.20
        Filter 2: ON PK Fc 120.0 Hz Gain 2.0 dB Q 1.10
        """

        let profile = try EQProfileTextImporter.importREW(text)

        #expect(profile.filters.count == 2)
        #expect(profile.filters[0].frequency == 45)
        #expect(profile.filters[0].gainDB == -4.5)
        #expect(profile.filters[0].q == 3.2)
    }

    @Test
    func importsREWTextWithUncommentedFilterSettingsHeader() throws {
        let text = """
        Filter Settings file

        Room EQ V5.31.3
        Equaliser: Generic
        Filter 1: ON PK Fc 45.0 Hz Gain -4.5 dB Q 3.20
        """

        let profile = try EQProfileTextImporter.importREW(text)

        #expect(profile.filters.count == 1)
        #expect(profile.filters[0].frequency == 45)
    }

    @Test
    func importsREWFilterKindsAndDecimalCommas() throws {
        let text = """
        Filter 1: ON LS Fc 80,5 Hz Gain 3,5 dB Q 0,70
        Filter 2: ON HS Fc 12000 Hz Gain -2 dB Q 0.80
        Filter 3: ON HP Fc 30 Hz Gain 0 dB Q 0.707
        Filter 4: ON LP Fc 18000 Hz Gain 0 dB Q 0.707
        """

        let profile = try EQProfileTextImporter.importREW(text)

        #expect(profile.filters.map(\.kind) == [.lowShelf, .highShelf, .highPass, .lowPass])
        #expect(profile.filters[0].frequency == 80.5)
        #expect(profile.filters[0].gainDB == 3.5)
        #expect(profile.filters[0].q == 0.7)
    }

    @Test
    func importsREWMissingQAsDefaultInsteadOfLastNumericToken() throws {
        let profile = try EQProfileTextImporter.importREW("Filter 1: ON PK Fc 45.0 Hz Gain -4.5 dB")

        #expect(profile.filters.count == 1)
        #expect(profile.filters[0].q == 0.707_106_781_18)
    }

    @Test
    func rejectsHexFloatNumericTokens() throws {
        do {
            _ = try EQProfileTextImporter.importREW("Filter 1: ON PK Fc 0x1p10 Hz Gain 0 dB Q 1")
            Issue.record("Expected hex float to fail")
        } catch let error as ProfileImportError {
            #expect(error == .invalidNumber(line: 1, field: "frequency", value: "0x1p10"))
        }
    }

    @Test
    func importsGraphicProfileRoundTripAsGraphicMode() throws {
        let exported = try EQProfileTextExporter.exportEqualizerAPO(.flatGraphic10)

        let profile = try EQProfileTextImporter.importAutoEQ(exported)

        #expect(profile.mode == .graphic10)
        #expect(profile.filters.count == GraphicEQBands.tenBand.count)
    }

    @Test
    func importsGraphicBandFrequenciesWithNonGraphicQAsParametric() throws {
        let text = GraphicEQBands.tenBand.enumerated().map { index, frequency in
            "Filter \(index + 1): ON PK Fc \(frequency) Hz Gain 0 dB Q 1.00"
        }.joined(separator: "\n")

        let profile = try EQProfileTextImporter.importAutoEQ(text)

        #expect(profile.mode == .parametric)
        #expect(profile.filters.map(\.frequency) == GraphicEQBands.tenBand)
    }

    @Test
    func importsStereoGraphicProfileAndPersistsWithEmptyLinkedFilters() throws {
        let stereoGraphic = EQProfile(
            name: "Stereo Graphic",
            mode: .graphic10,
            channelMode: .stereo,
            filters: [],
            leftFilters: EQProfile.flatGraphic10.filters,
            rightFilters: EQProfile.flatGraphic10.filters
        )
        let exported = try EQProfileTextExporter.exportEqualizerAPO(stereoGraphic)

        let profile = try EQProfileTextImporter.importAutoEQ(exported)
        let store = ProfileStore(profiles: [profile], fallbackProfileID: profile.id)
        let decoded = try ProfilePersistence.decode(ProfilePersistence.encode(store))

        #expect(profile.mode == .graphic10)
        #expect(profile.channelMode == .stereo)
        #expect(profile.filters.isEmpty)
        #expect(profile.leftFilters.count == GraphicEQBands.tenBand.count)
        #expect(profile.rightFilters.count == GraphicEQBands.tenBand.count)
        #expect(decoded.profiles == [profile])
    }

    @Test
    func importsREWFrequencyImmediatelyBeforeHz() throws {
        let profile = try EQProfileTextImporter.importREW("Filter 1: ON PK 45.0 Hz Gain -4.5 dB Q 3.20")

        #expect(profile.filters.count == 1)
        #expect(profile.filters[0].frequency == 45)
    }

    @Test
    func importsREWFrequencyAfterFLabel() throws {
        let profile = try EQProfileTextImporter.importREW("Filter 1: ON PK F 45.0 Hz Gain -4.5 dB Q 3.20")

        #expect(profile.filters.count == 1)
        #expect(profile.filters[0].frequency == 45)
    }

    @Test
    func rejectsREWBareNumericFilterLineAsMissingFrequency() throws {
        let text = "Filter 1: ON PK 45.0 Gain -4.5 dB Q 3.20"

        do {
            _ = try EQProfileTextImporter.importREW(text)
            Issue.record("Expected missing REW frequency to fail")
        } catch let error as ProfileImportError {
            #expect(error == .missingNumber(line: 1, field: "frequency"))
        }
    }

    @Test
    func rejectsAutoEQBareFrequencyWithoutFcOrF() throws {
        let text = "Filter 1: ON PK 45.0 Hz Gain -4.5 dB Q 3.20"

        do {
            _ = try EQProfileTextImporter.importAutoEQ(text)
            Issue.record("Expected missing AutoEQ frequency to fail")
        } catch let error as ProfileImportError {
            #expect(error == .missingNumber(line: 1, field: "frequency"))
        }
    }

    @Test
    func rejectsInputOverUTF8ByteLimit() throws {
        var limits = ProfileImportLimits.default
        limits.maxUTF8Bytes = 8

        do {
            _ = try EQProfileTextImporter.importAutoEQ("Filter 1: ON PK Fc 100 Hz Gain 0 dB Q 1", limits: limits)
            Issue.record("Expected oversized input to fail")
        } catch let error as ProfileImportError {
            #expect(error == .inputTooLarge(byteCount: 39, maximum: 8))
            #expect(error.errorDescription?.contains("UTF-8 bytes") == true)
        }
    }

    @Test
    func rejectsInputOverLineLimit() throws {
        var limits = ProfileImportLimits.default
        limits.maxLineCount = 2

        do {
            _ = try EQProfileTextImporter.importAutoEQ("one\ntwo\nthree", limits: limits)
            Issue.record("Expected line limit to fail")
        } catch let error as ProfileImportError {
            #expect(error == .tooManyLines(lineCount: 3, maximum: 2))
        }
    }

    @Test
    func rejectsAutoEQNumericFieldsOutsideLimitsWithLineNumber() throws {
        let text = """
        Preamp: -3 dB
        Filter 1: ON PK Fc 25000 Hz Gain 0 dB Q 1
        """

        do {
            _ = try EQProfileTextImporter.importAutoEQ(text)
            Issue.record("Expected frequency limit to fail")
        } catch let error as ProfileImportError {
            #expect(error == .valueOutOfRange(line: 2, field: "frequency", value: 25_000, range: 1...24_000))
            #expect(error.errorDescription?.contains("Line 2") == true)
        }
    }

    @Test
    func rejectsREWInvalidNumericFieldWithLineNumber() throws {
        let text = "Filter 1: ON PK Fc nope Hz Gain 0 dB Q 1"

        do {
            _ = try EQProfileTextImporter.importREW(text)
            Issue.record("Expected invalid frequency to fail")
        } catch let error as ProfileImportError {
            #expect(error == .invalidNumber(line: 1, field: "frequency", value: "nope"))
        }
    }

    @Test
    func enforcesPerChannelFilterLimit() throws {
        var limits = ProfileImportLimits.default
        limits.maxFiltersPerChannel = 1
        let text = """
        Filter 1: ON PK Fc 100 Hz Gain 0 dB Q 1
        Filter 2: ON PK Fc 200 Hz Gain 0 dB Q 1
        """

        do {
            _ = try EQProfileTextImporter.importAutoEQ(text, limits: limits)
            Issue.record("Expected per-channel filter limit to fail")
        } catch let error as ProfileImportError {
            #expect(error == .tooManyFilters(line: 2, channel: "linked", count: 2, maximum: 1))
        }
    }

    @Test
    func enforcesTotalFilterLimitAcrossStereoChannels() throws {
        var limits = ProfileImportLimits.default
        limits.maxFiltersPerChannel = 4
        limits.maxTotalFilters = 2
        let text = """
        Channel: L
        Filter 1: ON PK Fc 100 Hz Gain 0 dB Q 1
        Filter 2: ON PK Fc 200 Hz Gain 0 dB Q 1
        Channel: R
        Filter 1: ON PK Fc 300 Hz Gain 0 dB Q 1
        """

        do {
            _ = try EQProfileTextImporter.importAutoEQ(text, limits: limits)
            Issue.record("Expected total filter limit to fail")
        } catch let error as ProfileImportError {
            #expect(error == .tooManyTotalFilters(line: 5, count: 3, maximum: 2))
        }
    }
}
