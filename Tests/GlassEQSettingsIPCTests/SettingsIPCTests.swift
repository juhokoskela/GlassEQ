import Foundation
import GlassEQCore
import GlassEQSettingsIPC
import Testing
@testable import GlassEQSettings
@testable import GlassEQSettingsUI

@Suite
struct SettingsIPCTests {
    @Test
    func autoEQCatalogueParserReadsRecommendedResults() throws {
        let markdown = """
        # Recommended Results
        - [Sennheiser HD 58X](./oratory1990/over-ear/Sennheiser%20HD%2058X)
        - [7Hz Salnotes Zero](./crinacle/711%20in-ear/7Hz%20Salnotes%20Zero)
        """

        let entries = try AutoEQCatalogueParser.parse(markdown)

        #expect(entries == [
            AutoEQCatalogueEntry(
                name: "Sennheiser HD 58X",
                encodedResultPath: "oratory1990/over-ear/Sennheiser%20HD%2058X",
                source: "oratory1990",
                form: "Over-ear"
            ),
            AutoEQCatalogueEntry(
                name: "7Hz Salnotes Zero",
                encodedResultPath: "crinacle/711%20in-ear/7Hz%20Salnotes%20Zero",
                source: "crinacle",
                form: "In-ear"
            )
        ])
    }

    @Test
    func autoEQProfileURLPreservesResultPathAndEncodesFilename() throws {
        let entry = AutoEQCatalogueEntry(
            name: "Sennheiser HD 58X",
            encodedResultPath: "oratory1990/over-ear/Sennheiser%20HD%2058X",
            source: "oratory1990",
            form: "Over-ear"
        )

        let responseCurveURL = try AutoEQRepositoryClient.profileURL(
            for: entry,
            kind: .responseCurve
        )
        let parametricURL = try AutoEQRepositoryClient.profileURL(
            for: entry,
            kind: .parametric
        )

        #expect(responseCurveURL.absoluteString.hasSuffix(
            "/Sennheiser%20HD%2058X/Sennheiser%20HD%2058X%20GraphicEQ.txt"
        ))
        #expect(parametricURL.absoluteString.hasSuffix(
            "/Sennheiser%20HD%2058X/Sennheiser%20HD%2058X%20ParametricEQ.txt"
        ))
    }

    @Test
    func autoEQProfileDownloadAcceptsTheExactByteLimit() async throws {
        let entry = autoEQNetworkTestEntry(named: "At Limit")
        let url = try AutoEQRepositoryClient.profileURL(for: entry, kind: .responseCurve)
        let body = Data(repeating: 0x78, count: 32)
        AutoEQTestURLProtocol.register(statusCode: 200, body: body, for: url)
        defer { AutoEQTestURLProtocol.unregister(url) }
        let session = autoEQTestSession()
        defer { session.invalidateAndCancel() }
        let client = AutoEQRepositoryClient(
            session: session,
            maximumProfileBytes: body.count
        )

        let text = try await client.profileText(for: entry, kind: .responseCurve)

        #expect(text == String(repeating: "x", count: body.count))
    }

    @Test
    func autoEQProfileDownloadRejectsTheFirstByteBeyondTheLimit() async throws {
        let entry = autoEQNetworkTestEntry(named: "Too Large")
        let url = try AutoEQRepositoryClient.profileURL(for: entry, kind: .parametric)
        AutoEQTestURLProtocol.register(
            statusCode: 200,
            body: Data(repeating: 0x78, count: 33),
            for: url
        )
        defer { AutoEQTestURLProtocol.unregister(url) }
        let session = autoEQTestSession()
        defer { session.invalidateAndCancel() }
        let client = AutoEQRepositoryClient(
            session: session,
            maximumProfileBytes: 32
        )

        await #expect(throws: AutoEQRepositoryError.profileTooLarge) {
            try await client.profileText(for: entry, kind: .parametric)
        }
    }

    @Test
    func autoEQCatalogueDownloadUsesItsOwnSizeError() async {
        let url = URL(
            string: "https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/results/README.md"
        )!
        AutoEQTestURLProtocol.register(
            statusCode: 200,
            body: Data(repeating: 0x78, count: 9),
            for: url
        )
        defer { AutoEQTestURLProtocol.unregister(url) }
        let session = autoEQTestSession()
        defer { session.invalidateAndCancel() }
        let client = AutoEQRepositoryClient(
            session: session,
            maximumCatalogueBytes: 8
        )

        await #expect(throws: AutoEQRepositoryError.catalogueTooLarge) {
            try await client.catalogue()
        }
    }

    @Test
    func autoEQDownloadRejectsAnUnsuccessfulHTTPResponse() async throws {
        let entry = autoEQNetworkTestEntry(named: "Unavailable")
        let url = try AutoEQRepositoryClient.profileURL(for: entry, kind: .responseCurve)
        AutoEQTestURLProtocol.register(statusCode: 503, body: Data(), for: url)
        defer { AutoEQTestURLProtocol.unregister(url) }
        let session = autoEQTestSession()
        defer { session.invalidateAndCancel() }
        let client = AutoEQRepositoryClient(session: session)

        await #expect(throws: AutoEQRepositoryError.invalidResponse) {
            try await client.profileText(for: entry, kind: .responseCurve)
        }
    }

    @Test
    func importedEQTextDetectorRecognizesREWHeaders() {
        #expect(ImportedEQTextDetector.format(for: "* Filter Settings file") == .rew)
        #expect(ImportedEQTextDetector.format(for: "Filter Settings file") == .rew)
        #expect(ImportedEQTextDetector.format(for: "Room EQ Wizard V5.40") == .rew)
        #expect(ImportedEQTextDetector.format(
            for: "Filter 1: ON Modal Fc 44 Hz Gain -5 dB Q 3"
        ) == .rew)
        #expect(ImportedEQTextDetector.format(for: "GraphicEQ: 20 0; 20000 -1") == .autoEQ)
        #expect(ImportedEQTextDetector.format(
            for: "Filter 1: ON PK Fc 1000 Hz Gain -2 dB Q 1"
        ) == .autoEQ)
    }

    @Test(arguments: [0.707, 0.12345678901234567, 20_000.125])
    func editableNumberTextRoundTripsTypedPrecision(_ value: Double) {
        let locale = Locale(identifier: "en_US_POSIX")

        let text = editableNumberText(value, locale: locale)

        #expect(parseEditableNumber(text, locale: locale) == value)
    }

    @Test
    func editableNumberParsingSupportsLocaleDecimalSeparator() {
        #expect(parseEditableNumber("0,707", locale: Locale(identifier: "fi_FI")) == 0.707)
    }

    @Test
    func editableNumberParsingSupportsLocalizedDecimalDigits() {
        let locale = Locale(identifier: "ar_EG")
        let text = editableNumberText(-6.5, locale: locale)

        #expect(parseEditableNumber(text, locale: locale) == -6.5)
        #expect(parseEditableNumber("١٢٫٥", locale: locale) == 12.5)
    }

    @Test
    func profileDeletionIsDisabledWhilePreviewProtectsTheReturnProfile() {
        let returnProfile = EQProfile(name: "Return", mode: .parametric, filters: [])
        let previewProfile = EQProfile(name: "Preview", mode: .parametric, filters: [])
        var snapshot = SettingsSnapshotDTO.disconnected
        snapshot.profiles = [returnProfile, previewProfile]
        snapshot.selectedProfileID = returnProfile.id
        snapshot.draftProfile = returnProfile
        snapshot.activeProfileID = previewProfile.id
        snapshot.isPreviewing = true

        #expect(!settingsCanDeleteSelectedProfile(snapshot))

        snapshot.isPreviewing = false
        #expect(settingsCanDeleteSelectedProfile(snapshot))

        snapshot.programmeComparison.isActive = true
        #expect(!settingsCanDeleteSelectedProfile(snapshot))
    }

    @Test
    func editableNumberParsingRejectsLocaleGroupingSeparators() {
        #expect(parseEditableNumber("1.234", locale: Locale(identifier: "de_DE")) == nil)
        #expect(parseEditableNumber("1,234", locale: Locale(identifier: "de_DE")) == 1.234)
    }

    @Test
    func editableNumberUpdatesClampValidDraftText() {
        let range = -24.0...24.0

        #expect(clampedEditableNumber("-12.345", range: range, locale: Locale(identifier: "en_US_POSIX")) == -12.345)
        #expect(clampedEditableNumber("30", range: range, locale: Locale(identifier: "en_US_POSIX")) == 24)
        #expect(clampedEditableNumber("-", range: range, locale: Locale(identifier: "en_US_POSIX")) == nil)
    }

    @Test
    func editableNumberPreservesPersistableValuesOutsideSliderRanges() {
        let locale = Locale(identifier: "en_US_POSIX")

        #expect(clampedEditableNumber("24000", range: ProfilePersistence.frequencyRange, locale: locale) == 24_000)
        #expect(clampedEditableNumber("120", range: ProfilePersistence.gainRange, locale: locale) == 120)
        #expect(clampedEditableNumber("-30", range: ProfilePersistence.preampRange, locale: locale) == -30)
        #expect(clampedEditableNumber("20", range: ProfilePersistence.qRange, locale: locale) == 20)
    }

    @Test
    func editableValueCancellationRestoresTheValueFromTheStartOfEditing() {
        var session = EditableValueEditSession()
        session.begin(value: -3)
        session.recordTextDrivenValue(-6)

        let textChangeWasExternal = session.valueChanged(-6)
        let restoredValue = session.cancel()

        #expect(!textChangeWasExternal)
        #expect(restoredValue == -3)
    }

    @Test
    func editableValueInvalidCommitRestoresTheValueFromTheStartOfEditing() {
        var session = EditableValueEditSession()
        session.begin(value: 10)
        session.recordTextDrivenValue(2)
        _ = session.valueChanged(2)

        let finalValue: Double?
        if let parsed = clampedEditableNumber("", range: 0...20) {
            finalValue = parsed
        } else {
            finalValue = session.cancel()
        }

        #expect(finalValue == 10)
    }

    @Test
    func editableValueExternalChangesResetTheActiveSession() {
        var session = EditableValueEditSession()
        session.begin(value: -3)
        session.recordTextDrivenValue(-6)

        let textChangeWasExternal = session.valueChanged(-6)
        let headroomChangeWasExternal = session.valueChanged(-12)
        let restoredValue = session.cancel()

        #expect(!textChangeWasExternal)
        #expect(headroomChangeWasExternal)
        #expect(restoredValue == nil)
    }

    @Test
    func delayedSnapshotPreservesNewerLocalDraftAndSelection() {
        let first = EQProfile(name: "First", mode: .parametric, filters: [])
        let second = EQProfile(name: "Second", mode: .parametric, filters: [])
        var editedSecond = second
        editedSecond.preampDB = -3.25
        var current = SettingsSnapshotDTO.disconnected
        current.profiles = [first, second]
        current.selectedProfileID = second.id
        current.draftProfile = editedSecond
        var latest = current
        latest.selectedProfileID = first.id
        latest.draftProfile = first
        latest.statusMessage = "Command completed"

        let merged = settingsSnapshotPreservingLocalDraft(current: current, latest: latest)

        #expect(merged.selectedProfileID == second.id)
        #expect(merged.draftProfile == editedSecond)
        #expect(merged.statusMessage == "Command completed")
    }

    @Test
    func commandSnapshotAdoptsIntentionalSelectionChangeWhenLocalDraftIsUnchanged() {
        let original = EQProfile(name: "Original", mode: .parametric, filters: [])
        let duplicate = EQProfile(name: "Duplicate", mode: .parametric, filters: [])
        var dispatched = SettingsSnapshotDTO.disconnected
        dispatched.profiles = [original]
        dispatched.selectedProfileID = original.id
        dispatched.draftProfile = original
        var latest = dispatched
        latest.profiles = [original, duplicate]
        latest.selectedProfileID = duplicate.id
        latest.draftProfile = duplicate

        let merged = settingsSnapshotAfterCommand(
            current: dispatched,
            dispatched: dispatched,
            latest: latest
        )

        #expect(merged.selectedProfileID == duplicate.id)
        #expect(merged.draftProfile == duplicate)
    }

    @Test
    func commandSnapshotPreservesEditsMadeWhileCommandWasPending() {
        let first = EQProfile(name: "First", mode: .parametric, filters: [])
        let second = EQProfile(name: "Second", mode: .parametric, filters: [])
        var dispatched = SettingsSnapshotDTO.disconnected
        dispatched.profiles = [first, second]
        dispatched.selectedProfileID = first.id
        dispatched.draftProfile = first
        var current = dispatched
        current.selectedProfileID = second.id
        current.draftProfile = second
        var latest = dispatched
        latest.statusMessage = "Command completed"

        let merged = settingsSnapshotAfterCommand(
            current: current,
            dispatched: dispatched,
            latest: latest
        )

        #expect(merged.selectedProfileID == second.id)
        #expect(merged.draftProfile == second)
        #expect(merged.statusMessage == "Command completed")
    }

    @Test
    func sliderQuantizationDoesNotIntroduceDisplayNoise() {
        let locale = Locale(identifier: "en_US_POSIX")

        for tenth in -240...240 {
            let expected = Double(tenth) / 10
            let value = quantized(expected, step: 0.1)
            #expect(editableNumberText(value, locale: locale) == editableNumberText(expected, locale: locale))
        }
    }

    @Test(arguments: ["nan", "inf", "-inf", "infinity", "-infinity"])
    func editableNumberParsingRejectsNonFiniteValues(_ text: String) {
        #expect(parseEditableNumber(text, locale: Locale(identifier: "en_US_POSIX")) == nil)
    }

    @Test
    func pipeMessageRoundTripsConnectRequest() throws {
        let message = SettingsPipeMessage.request(sessionToken: "token", id: "request-1", kind: .connect, command: nil)

        let encoded = try SettingsPipeCodec.encodeLine(message)
        let decoded = try SettingsPipeCodec.decodeLine(Data(encoded.dropLast()))

        #expect(decoded == message)
        try decoded.validateSessionToken("token")
    }

    @Test
    func pipeMessageRoundTripsReadyRequest() throws {
        let message = SettingsPipeMessage.request(sessionToken: "token", id: "request-2", kind: .ready, command: nil)

        let encoded = try SettingsPipeCodec.encodeLine(message)
        let decoded = try SettingsPipeCodec.decodeLine(Data(encoded.dropLast()))

        #expect(decoded == message)
    }

    @Test
    func pipeMessageRoundTripsBootstrapToken() throws {
        let message = SettingsPipeMessage.bootstrap(sessionToken: "bootstrap-token")

        let encoded = try SettingsPipeCodec.encodeLine(message)
        let decoded = try SettingsPipeCodec.decodeLine(Data(encoded.dropLast()))

        #expect(decoded == message)
        try decoded.validateSessionToken("bootstrap-token")
    }

    @Test
    func pipeMessageRoundTripsCommandResponseAndEvent() throws {
        let response = SettingsPipeMessage.response(
            sessionToken: "token",
            id: "request-2",
            response: SettingsCommandResponse(snapshot: .disconnected),
            error: nil
        )
        let event = SettingsPipeMessage.event(
            sessionToken: "token",
            event: .metricsChanged(SettingsAudioMetricsDTO(capturedFrames: 42))
        )

        let decodedResponse = try SettingsPipeCodec.decodeLine(Data(try SettingsPipeCodec.encodeLine(response).dropLast()))
        let decodedEvent = try SettingsPipeCodec.decodeLine(Data(try SettingsPipeCodec.encodeLine(event).dropLast()))

        #expect(decodedResponse == response)
        #expect(decodedEvent == event)
    }

    @Test
    func aggregateBufferCommandsAndOutputDeepLinkRoundTrip() throws {
        let messages = [
            SettingsPipeMessage.request(
                sessionToken: "token",
                id: "buffer-mode",
                kind: .command,
                command: .setAggregateBufferMode(.frames64)
            ),
            SettingsPipeMessage.request(
                sessionToken: "token",
                id: "buffer-retry",
                kind: .command,
                command: .retryAutomaticAggregateBuffer
            ),
            SettingsPipeMessage.event(
                sessionToken: "token",
                event: .sectionRequested(.output)
            )
        ]

        for message in messages {
            let encoded = try SettingsPipeCodec.encodeLine(message)
            let decoded = try SettingsPipeCodec.decodeLine(Data(encoded.dropLast()))
            #expect(decoded == message)
        }
    }

    @Test
    func programmeComparisonCommandsRoundTrip() throws {
        let profile = EQProfile(name: "Draft", mode: .parametric, filters: [])
        let commands: [SettingsCommand] = [
            .startProgrammeComparison(profile),
            .selectProgrammeComparison(.filtersOff),
            .stopProgrammeComparison
        ]

        for (index, command) in commands.enumerated() {
            let message = SettingsPipeMessage.request(
                sessionToken: "token",
                id: "comparison-\(index)",
                kind: .command,
                command: command
            )
            let encoded = try SettingsPipeCodec.encodeLine(message)
            let decoded = try SettingsPipeCodec.decodeLine(Data(encoded.dropLast()))
            #expect(decoded == message)
        }
    }

    @Test
    func impulseResponseImportCommandRoundTrips() throws {
        let profile = EQProfile(
            name: "Room IR",
            mode: .convolution,
            filters: [],
            convolution: .impulseResponse(ImpulseResponseSource(
                sampleRate: 48_000,
                samples: [1, 0.25, -0.125]
            ))
        )
        let command = SettingsCommand.importParsedProfile(profile)
        let message = SettingsPipeMessage.request(
            sessionToken: "token",
            id: "impulse-response",
            kind: .command,
            command: command
        )

        let encoded = try SettingsPipeCodec.encodeLine(message)
        let decoded = try SettingsPipeCodec.decodeLine(Data(encoded.dropLast()))

        #expect(decoded == message)
    }

    @Test
    func fileImportSelectionCommandsAndResponsesRoundTrip() throws {
        let profile = EQProfile(
            name: "Imported",
            mode: .convolution,
            filters: [],
            convolution: .impulseResponse(ImpulseResponseSource(
                sampleRate: 48_000,
                samples: [1, 0.25]
            ))
        )
        let commands: [SettingsCommand] = [
            .chooseImportFiles(mode: .single, expectedSampleRate: 48_000),
            .chooseImportFiles(mode: .stereoPair, expectedSampleRate: 96_000)
        ]
        let selections: [SettingsFileImportSelectionDTO] = [
            .text(
                suggestedName: "Headphones",
                filename: "Headphones.txt",
                text: "Preamp: -6 dB"
            ),
            .impulseResponse(
                profile: profile,
                channels: [SettingsImpulseResponseChannelDTO(
                    filename: "room.wav",
                    frameCount: 2,
                    sampleRate: 48_000
                )],
                sourceFileCount: 1
            ),
            .stereoText(
                profile: profile,
                leftFilename: "left.txt",
                rightFilename: "right.txt"
            )
        ]

        for (index, command) in commands.enumerated() {
            let message = SettingsPipeMessage.request(
                sessionToken: "token",
                id: "file-command-\(index)",
                kind: .command,
                command: command
            )
            let encoded = try SettingsPipeCodec.encodeLine(message)
            #expect(try SettingsPipeCodec.decodeLine(Data(encoded.dropLast())) == message)
        }

        for (index, selection) in selections.enumerated() {
            let message = SettingsPipeMessage.response(
                sessionToken: "token",
                id: "file-response-\(index)",
                response: SettingsCommandResponse(fileImportSelection: selection),
                error: nil
            )
            let encoded = try SettingsPipeCodec.encodeLine(message)
            #expect(try SettingsPipeCodec.decodeLine(Data(encoded.dropLast())) == message)
        }
    }

    @Test
    func aggregateBufferSnapshotDefaultsLegacyPayloadToAutomaticSixteen() throws {
        let decoded = try JSONDecoder().decode(
            SettingsAggregateBufferDTO.self,
            from: Data("{}".utf8)
        )

        #expect(decoded == SettingsAggregateBufferDTO())
    }

    @Test
    func audioMetricsDecodeOldPayloadsWithDefaultedNewFields() throws {
        let data = Data("""
        {
          "capturedFrames": 42,
          "playedFrames": 24,
          "playbackUnderrunFrames": 1,
          "saturatedSamples": 2,
          "currentBufferedFrames": 512,
          "maxBufferedFrames": 1024
        }
        """.utf8)

        let metrics = try JSONDecoder().decode(SettingsAudioMetricsDTO.self, from: data)

        #expect(metrics.capturedFrames == 42)
        #expect(metrics.playedFrames == 24)
        #expect(metrics.playbackUnderrunFrames == 1)
        #expect(metrics.saturatedSamples == 2)
        #expect(metrics.maximumCaptureCallbackFrames == 0)
        #expect(metrics.maximumPlaybackCallbackFrames == 0)
        #expect(metrics.renderDeadlineMisses == 0)
        #expect(metrics.callbackStartStarvations == 0)
        #expect(metrics.renderOverruns == 0)
        #expect(metrics.pairedTimestampDiscontinuities == 0)
        #expect(metrics.droppedInputFrames == 0)
        #expect(metrics.tapToOutputLatencyObservations == 0)
        #expect(metrics.minimumTapToOutputLatencyNanoseconds == 0)
        #expect(metrics.maximumTapToOutputLatencyNanoseconds == 0)
        #expect(metrics.averageTapToOutputLatencyNanoseconds == 0)
        #expect(metrics.renderTiming == SettingsAudioRenderTimingDTO())
    }

    @Test
    func audioMetricsRoundTripTapToOutputLatency() throws {
        let metrics = SettingsAudioMetricsDTO(
            pairedTimestampDiscontinuities: 4,
            renderDeadlineMisses: 7,
            callbackStartStarvations: 5,
            renderOverruns: 2,
            tapToOutputLatencyObservations: 500,
            minimumTapToOutputLatencyNanoseconds: 1_250_000,
            maximumTapToOutputLatencyNanoseconds: 2_750_000,
            averageTapToOutputLatencyNanoseconds: 1_500_000,
            renderTiming: SettingsAudioRenderTimingDTO(
                callbackStartLatenessObservations: 10_000,
                callbackStartLatenessP9999Nanoseconds: 125_000,
                maximumCallbackStartLatenessNanoseconds: 330_000,
                directHeadObservations: 10_000,
                directHeadP9999Nanoseconds: 4_000,
                maximumDirectHeadNanoseconds: 12_000,
                tailWorkObservations: 10_000,
                tailWorkP9999Nanoseconds: 3_000,
                maximumTailWorkNanoseconds: 9_000,
                totalRenderObservations: 10_000,
                totalRenderP9999Nanoseconds: 15_000,
                maximumTotalRenderNanoseconds: 42_000,
                completionLatenessObservations: 10_000,
                completionLatenessP9999Nanoseconds: 0,
                maximumCompletionLatenessNanoseconds: 8_000,
                tailCompletionObservations: 625,
                minimumTailCompletionSlackFrames: 16,
                tailDeadlineMisses: 0
            )
        )

        let data = try JSONEncoder().encode(metrics)
        let decoded = try JSONDecoder().decode(SettingsAudioMetricsDTO.self, from: data)

        #expect(decoded == metrics)
    }

    @Test
    func settingsAnalysisUsesCurrentOutputSampleRateWithFallback() {
        let profile = EQProfile(
            name: "Analysis",
            mode: .parametric,
            filters: [
                EQFilter(kind: .peak, frequency: 20_000, gainDB: 8, q: 8)
            ]
        )

        let routeAnalysis = EQAnalysisSnapshot(profile: profile, sampleRate: 44_100)
        let fallbackAnalysis = EQAnalysisSnapshot(profile: profile, sampleRate: 0)

        #expect(routeAnalysis.signature.sampleRate == 44_100)
        #expect(fallbackAnalysis.signature.sampleRate == EQAnalysisSignature.defaultSampleRate)
        #expect(routeAnalysis.signature != fallbackAnalysis.signature)
        #expect(routeAnalysis.maximumUsableFrequency == 19_845)
        #expect(routeAnalysis.inactiveEnabledFilterCount == 1)
        #expect(fallbackAnalysis.maximumUsableFrequency == 20_000)
        #expect(fallbackAnalysis.inactiveEnabledFilterCount == 0)
        #expect(routeAnalysis.linkedPoints == FrequencyResponse.points(
            for: profile.filters,
            preampDB: profile.preampDB,
            sampleRate: 44_100
        ))
        #expect(routeAnalysis.recommendedPreampDB == EQProfileAnalysis.recommendedPreampDB(
            profile: profile,
            sampleRate: 44_100
        ))
    }

    @Test
    func settingsAnalysisTracksResponseCurveChanges() {
        var profile = EQProfile.flatConvolution
        let flat = EQAnalysisSnapshot(profile: profile, sampleRate: 48_000)
        profile.convolution = .magnitudeCurve(MagnitudeCurveSource(points: [
            EQMagnitudePoint(frequency: 20, gainDB: 6),
            EQMagnitudePoint(frequency: 20_000, gainDB: -2)
        ]))
        let shaped = EQAnalysisSnapshot(profile: profile, sampleRate: 48_000)

        #expect(flat.signature != shaped.signature)
        #expect(abs((shaped.linkedPoints.first?.magnitudeDB ?? 0) - 6) < 0.000_001)
        #expect(shaped.recommendedPreampDB == -6.5)
    }

    @Test
    func pipeMessageRejectsMismatchedSessionToken() throws {
        let message = SettingsPipeMessage.event(sessionToken: "actual", event: .shutdown)

        #expect(throws: SettingsPipeError.sessionTokenMismatch) {
            try message.validateSessionToken("expected")
        }
    }

    @Test
    func pipeMessageValidatesUTF8TokenBytes() throws {
        let message = SettingsPipeMessage.event(sessionToken: "å-token", event: .shutdown)

        try message.validateSessionToken("å-token")
        #expect(throws: SettingsPipeError.sessionTokenMismatch) {
            try message.validateSessionToken("å-tokem")
        }
        #expect(throws: SettingsPipeError.sessionTokenMismatch) {
            try message.validateSessionToken("å-token-extra")
        }
    }

    @Test
    func pipeCodecRejectsOversizedEncodedLine() throws {
        let message = SettingsPipeMessage.event(sessionToken: "token", event: .shutdown)

        #expect(throws: SettingsPipeError.self) {
            _ = try SettingsPipeCodec.encodeLine(message, maximumLineBytes: 1)
        }
    }

    @Test
    func pipeLineBufferDecodesChunkedAndMultipleLines() throws {
        let first = SettingsPipeMessage.event(sessionToken: "token", event: .focusRequested)
        let second = SettingsPipeMessage.event(sessionToken: "token", event: .shutdown)
        let firstLine = try SettingsPipeCodec.encodeLine(first)
        let secondLine = try SettingsPipeCodec.encodeLine(second)
        let splitIndex = firstLine.index(firstLine.startIndex, offsetBy: firstLine.count / 2)
        var buffer = SettingsPipeLineBuffer()

        let noLines = try buffer.append(firstLine[..<splitIndex])
        let completedLines = try buffer.append(firstLine[splitIndex...] + secondLine)

        #expect(noLines.isEmpty)
        #expect(completedLines.count == 2)
        #expect(try completedLines.map(SettingsPipeCodec.decodeLine) == [first, second])
        #expect(buffer.bufferedByteCount == 0)
    }

    @Test
    func pipeReadPumpPreservesChunkOrder() throws {
        let first = SettingsPipeMessage.bootstrap(sessionToken: "token")
        let second = SettingsPipeMessage.request(sessionToken: "token", id: "request-1", kind: .connect, command: nil)
        let third = SettingsPipeMessage.event(sessionToken: "token", event: .shutdown)
        let firstLine = try SettingsPipeCodec.encodeLine(first)
        let secondLine = try SettingsPipeCodec.encodeLine(second)
        let thirdLine = try SettingsPipeCodec.encodeLine(third)
        let splitIndex = firstLine.index(firstLine.startIndex, offsetBy: firstLine.count / 2)
        let recorder = SettingsPipePumpRecorder(expectedMessageCount: 3)
        let pipe = Pipe()
        let pump = SettingsPipeReadPump(
            label: "com.glasseq.tests.settings-pipe-read-pump",
            onMessages: { recorder.record($0) },
            onEndOfFile: { recorder.recordEndOfFile() }
        )

        pump.install(on: pipe.fileHandleForReading)
        defer {
            pump.invalidate(handle: pipe.fileHandleForReading)
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }

        try pipe.fileHandleForWriting.write(contentsOf: Data(firstLine[..<splitIndex]))
        try pipe.fileHandleForWriting.write(contentsOf: Data(firstLine[splitIndex...]) + secondLine + thirdLine)

        #expect(recorder.waitForMessages(timeout: .now() + 2))
        let snapshot = recorder.snapshot()
        #expect(snapshot.messages == [first, second, third])
        #expect(snapshot.errorCount == 0)
    }

    @Test
    func pipeWritePumpEnqueueDoesNotBlockOnSlowSink() {
        let sink = BlockingSettingsPipeWriteSink()
        let completion = DispatchSemaphore(value: 0)
        let pump = SettingsPipeWritePump(
            label: "com.glasseq.tests.settings-pipe-write-pump.blocking",
            sink: SettingsPipeWriteSink { data in
                sink.write(data)
            }
        )
        let message = SettingsPipeMessage.event(sessionToken: "token", event: .shutdown)

        let start = Date()
        pump.enqueue(message) { _ in
            completion.signal()
        }
        let elapsed = Date().timeIntervalSince(start)

        #expect(elapsed < 0.05)
        #expect(sink.waitUntilWriteStarted(timeout: .now() + 1))
        sink.unblock()
        #expect(completion.wait(timeout: .now() + 1) == .success)
    }

    @Test
    func pipeWritePumpPreservesFIFOOrder() {
        let recorder = SettingsPipeWriteRecorder(expectedWriteCount: 3)
        let pump = SettingsPipeWritePump(
            label: "com.glasseq.tests.settings-pipe-write-pump.order",
            sink: SettingsPipeWriteSink { data in
                try recorder.write(data)
            }
        )
        let messages: [SettingsPipeMessage] = [
            .bootstrap(sessionToken: "token"),
            .request(sessionToken: "token", id: "request-1", kind: .connect, command: nil),
            .event(sessionToken: "token", event: .shutdown)
        ]

        for message in messages {
            pump.enqueue(message) { result in
                recorder.recordCompletion(result)
            }
        }

        #expect(recorder.waitForCompletions(timeout: .now() + 2))
        let snapshot = recorder.snapshot()
        #expect(snapshot.messages == messages)
        #expect(snapshot.successCount == 3)
        #expect(snapshot.errorCount == 0)
    }

    @Test
    func pipeWritePumpReportsWriteFailure() {
        let recorder = SettingsPipeWriteRecorder(expectedWriteCount: 1)
        let pump = SettingsPipeWritePump(
            label: "com.glasseq.tests.settings-pipe-write-pump.failure",
            sink: SettingsPipeWriteSink { _ in
                throw SettingsPipeWriteTestError.failed
            }
        )

        let start = Date()
        pump.enqueue(.event(sessionToken: "token", event: .shutdown)) { result in
            recorder.recordCompletion(result)
        }
        let elapsed = Date().timeIntervalSince(start)

        #expect(elapsed < 0.05)
        #expect(recorder.waitForCompletions(timeout: .now() + 1))
        let snapshot = recorder.snapshot()
        #expect(snapshot.messages.isEmpty)
        #expect(snapshot.successCount == 0)
        #expect(snapshot.errorCount == 1)
    }

    @Test
    func pipeWritePumpReportsBrokenPipeWithoutSIGPIPETermination() throws {
        let pipe = Pipe()
        try pipe.fileHandleForReading.close()
        defer {
            try? pipe.fileHandleForWriting.close()
        }
        let completion = SettingsPipeResultRecorder()
        let pump = SettingsPipeWritePump(
            label: "com.glasseq.tests.settings-pipe-write-pump.closed-pipe",
            fileHandle: pipe.fileHandleForWriting
        )

        pump.enqueue(.event(sessionToken: "token", event: .shutdown)) { result in
            completion.record(result)
        }

        #expect(completion.wait(timeout: .now() + 2))
        guard case .failure = completion.result else {
            Issue.record("Expected broken pipe write to fail")
            return
        }
    }

    @Test
    func pipeWritePumpDrainClosesAfterQueuedWritesFinish() {
        let sink = BlockingSettingsPipeWriteSink()
        let writeCompletion = SettingsPipeResultRecorder()
        let drainCompletion = SettingsPipeResultRecorder()
        let pump = SettingsPipeWritePump(
            label: "com.glasseq.tests.settings-pipe-write-pump.drain",
            sink: SettingsPipeWriteSink(
                { data in
                    sink.write(data)
                },
                close: {
                    sink.close()
                }
            )
        )

        pump.enqueue(.event(sessionToken: "token", event: .shutdown)) { result in
            writeCompletion.record(result)
        }
        #expect(sink.waitUntilWriteStarted(timeout: .now() + 1))

        pump.drainAndClose { result in
            drainCompletion.record(result)
        }

        #expect(!sink.waitUntilClosed(timeout: .now() + 0.05))
        sink.unblock()

        #expect(writeCompletion.wait(timeout: .now() + 1))
        #expect(drainCompletion.wait(timeout: .now() + 1))
        #expect(sink.closeCount == 1)
        #expect(writeCompletion.result?.isSuccess == true)
        #expect(drainCompletion.result?.isSuccess == true)
    }

    @Test
    func pipeWritePumpRejectsEnqueueAfterDrain() {
        let sink = BlockingSettingsPipeWriteSink()
        let drainCompletion = SettingsPipeResultRecorder()
        let enqueueCompletion = SettingsPipeResultRecorder()
        let pump = SettingsPipeWritePump(
            label: "com.glasseq.tests.settings-pipe-write-pump.closed",
            sink: SettingsPipeWriteSink(
                { _ in },
                close: {
                    sink.close()
                }
            )
        )

        pump.drainAndClose { result in
            drainCompletion.record(result)
        }
        #expect(drainCompletion.wait(timeout: .now() + 1))

        pump.enqueue(.event(sessionToken: "token", event: .shutdown)) { result in
            enqueueCompletion.record(result)
        }

        #expect(enqueueCompletion.wait(timeout: .now() + 1))
        #expect(sink.closeCount == 1)
        #expect(enqueueCompletion.result?.isClosedPipePumpFailure == true)
    }

    @Test
    func orderedMainActorDeliveryPreservesCallbackOrder() {
        let delivery = SettingsPipeOrderedMainActorDelivery(
            label: "com.glasseq.tests.settings-pipe-delivery.order"
        )
        let recorder = OrderedDeliveryRecorder(expectedCount: 4)

        delivery.enqueue {
            recorder.record("messages-1")
        }
        delivery.enqueue {
            recorder.record("failure")
        }
        delivery.enqueue {
            recorder.record("messages-2")
        }
        delivery.enqueue {
            recorder.record("eof")
        }

        #expect(recorder.wait(timeout: .now() + 2))
        #expect(recorder.events == ["messages-1", "failure", "messages-2", "eof"])
    }

    @Test
    func pipeLineBufferRejectsOversizedUnterminatedFrame() throws {
        var buffer = SettingsPipeLineBuffer(maximumLineBytes: 4)

        #expect(throws: SettingsPipeError.frameTooLarge(byteCount: 5, maximum: 4)) {
            _ = try buffer.append(Data(repeating: 0x61, count: 5))
        }
    }

    @Test
    func snapshotPatchRoundTripsOptionalMapping() throws {
        let profileID = UUID()
        let patch = SettingsSnapshotPatchDTO(
            statusMessage: "Running",
            isRunning: true,
            programmeComparison: EQProgrammeComparisonSnapshot(
                isActive: true,
                isReady: true,
                selection: .filtersOff,
                equalizedAttenuationDB: -2.5
            ),
            activeProfileID: profileID,
            activeProfileName: "Flat",
            currentOutput: SettingsOutputDTO(
                name: "DAC",
                uid: "dac",
                sampleRate: 48_000,
                channelCount: 2,
                bufferFrameSize: 256
            ),
            currentOutputMappedProfileID: .set(profileID),
            profileStoreProtection: SettingsProfileStoreProtectionDTO(
                isProtected: true,
                message: "Newer store",
                resetButtonTitle: "Reset profiles for this version"
            )
        )
        let message = SettingsPipeMessage.event(sessionToken: "token", event: .snapshotPatched(patch))

        let decoded = try SettingsPipeCodec.decodeLine(Data(try SettingsPipeCodec.encodeLine(message).dropLast()))

        #expect(decoded == message)
    }

    @Test
    func snapshotDecodeDefaultsMissingRunningStateToStopped() throws {
        var snapshot = SettingsSnapshotDTO.disconnected
        snapshot.isRunning = true
        let encoded = try JSONEncoder().encode(snapshot)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "isRunning")
        object.removeValue(forKey: "programmeComparison")

        let decoded = try JSONDecoder().decode(
            SettingsSnapshotDTO.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        #expect(!decoded.isRunning)
        #expect(decoded.programmeComparison == EQProgrammeComparisonSnapshot())
    }

    @Test
    @MainActor
    func snapshotPatchUpdatesRunningState() {
        let model = GlassEQSettingsViewModel()

        model.accept(patch: SettingsSnapshotPatchDTO(isRunning: true))
        #expect(model.snapshot.isRunning)

        model.accept(patch: SettingsSnapshotPatchDTO(isRunning: false))
        #expect(!model.snapshot.isRunning)
    }

    @Test
    func settingsHostValidationChecksProcessParentAndBundleID() throws {
        let launchInfo = try #require(SettingsLaunchInfo(commandLineArguments: [
            "GlassEQSettings",
            "--glasseq-main-pid", "123"
        ]))

        try SettingsHostValidator.validate(
            launchInfo: launchInfo,
            resolver: FakeHostProcessResolver(snapshot: SettingsHostProcessSnapshot(
                exists: true,
                bundleIdentifier: "com.glasseq.app",
                parentProcessIdentifier: 123
            ))
        )
        #expect(throws: SettingsCommandFailure.self) {
            try SettingsHostValidator.validate(
                launchInfo: launchInfo,
                resolver: FakeHostProcessResolver(snapshot: SettingsHostProcessSnapshot(
                    exists: false,
                    bundleIdentifier: nil,
                    parentProcessIdentifier: nil
                ))
            )
        }
        #expect(throws: SettingsCommandFailure.self) {
            try SettingsHostValidator.validate(
                launchInfo: launchInfo,
                resolver: FakeHostProcessResolver(snapshot: SettingsHostProcessSnapshot(
                    exists: true,
                    bundleIdentifier: "com.glasseq.app",
                    parentProcessIdentifier: 456
                ))
            )
        }
        #expect(throws: SettingsCommandFailure.self) {
            try SettingsHostValidator.validate(
                launchInfo: launchInfo,
                resolver: FakeHostProcessResolver(snapshot: SettingsHostProcessSnapshot(
                    exists: true,
                    bundleIdentifier: "com.example.other",
                    parentProcessIdentifier: 123
                ))
            )
        }
    }

    @Test
    @MainActor
    func settingsLaunchConnectsWhenModelAttachesBeforeArgumentsAreParsed() async {
        let factory = FakeSettingsPipeClientFactory()
        let coordinator = SettingsLaunchCoordinator(clientFactory: factory)
        let model = GlassEQSettingsViewModel()

        coordinator.attach(model: model)
        #expect(model.commandErrorMessage == nil)
        coordinator.finishLaunching(arguments: launchArguments())
        await coordinator.waitForConnectionTask()

        #expect(model.isConnected)
        #expect(model.commandErrorMessage == nil)
        #expect(factory.launchInfos.map(\.mainProcessIdentifier) == [123])
    }

    @Test
    @MainActor
    func settingsLaunchConnectsWhenArgumentsAreParsedBeforeModelAttaches() async {
        let factory = FakeSettingsPipeClientFactory()
        let coordinator = SettingsLaunchCoordinator(clientFactory: factory)
        let model = GlassEQSettingsViewModel()

        coordinator.finishLaunching(arguments: launchArguments())
        coordinator.attach(model: model)
        await coordinator.waitForConnectionTask()

        #expect(model.isConnected)
        #expect(model.commandErrorMessage == nil)
        #expect(factory.launchInfos.map(\.mainProcessIdentifier) == [123])
    }

    @Test
    @MainActor
    func settingsLaunchWithoutGlassEQArgumentsShowsDirectLaunchWarning() {
        let factory = FakeSettingsPipeClientFactory()
        let coordinator = SettingsLaunchCoordinator(clientFactory: factory)
        let model = GlassEQSettingsViewModel()

        coordinator.attach(model: model)
        coordinator.finishLaunching(arguments: ["GlassEQSettings"])

        #expect(!model.isConnected)
        #expect(model.commandErrorMessage == "Settings was not launched by GlassEQ.")
        #expect(factory.launchInfos.isEmpty)
    }

    @Test
    @MainActor
    func settingsLaunchValidationFailureSurfacesConnectionError() async {
        let factory = FakeSettingsPipeClientFactory(
            makeError: SettingsCommandFailure(message: "Settings was launched by an unexpected host application.")
        )
        let coordinator = SettingsLaunchCoordinator(clientFactory: factory)
        let model = GlassEQSettingsViewModel()

        coordinator.finishLaunching(arguments: launchArguments())
        coordinator.attach(model: model)
        await coordinator.waitForConnectionTask()

        #expect(!model.isConnected)
        #expect(model.commandErrorMessage == "Settings was launched by an unexpected host application.")
    }
}

private func autoEQNetworkTestEntry(named name: String) -> AutoEQCatalogueEntry {
    AutoEQCatalogueEntry(
        name: name,
        encodedResultPath: "test/\(name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!)",
        source: "test",
        form: nil
    )
}

private func autoEQTestSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [AutoEQTestURLProtocol.self]
    return URLSession(configuration: configuration)
}

private struct AutoEQTestURLResponse: Sendable {
    let statusCode: Int
    let body: Data
}

private final class AutoEQTestURLResponseStore: @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [URL: AutoEQTestURLResponse] = [:]

    func register(_ response: AutoEQTestURLResponse, for url: URL) {
        lock.lock()
        responses[url] = response
        lock.unlock()
    }

    func unregister(_ url: URL) {
        lock.lock()
        responses[url] = nil
        lock.unlock()
    }

    func response(for url: URL) -> AutoEQTestURLResponse? {
        lock.lock()
        defer { lock.unlock() }
        return responses[url]
    }
}

private final class AutoEQTestURLProtocol: URLProtocol, @unchecked Sendable {
    private static let responseStore = AutoEQTestURLResponseStore()

    static func register(statusCode: Int, body: Data, for url: URL) {
        responseStore.register(
            AutoEQTestURLResponse(statusCode: statusCode, body: body),
            for: url
        )
    }

    static func unregister(_ url: URL) {
        responseStore.unregister(url)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
              let stub = Self.responseStore.response(for: url),
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: stub.statusCode,
                  httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Length": String(stub.body.count)]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private struct FakeHostProcessResolver: SettingsHostProcessResolving {
    var snapshot: SettingsHostProcessSnapshot

    func snapshot(for processIdentifier: pid_t) -> SettingsHostProcessSnapshot {
        snapshot
    }
}

@MainActor
private final class FakeSettingsPipeClientFactory: SettingsPipeClientMaking {
    private let makeError: (any Error)?
    private let connectError: (any Error)?
    private let snapshot: SettingsSnapshotDTO
    private(set) var launchInfos: [SettingsLaunchInfo] = []

    init(
        snapshot: SettingsSnapshotDTO = .disconnected,
        makeError: (any Error)? = nil,
        connectError: (any Error)? = nil
    ) {
        self.snapshot = snapshot
        self.makeError = makeError
        self.connectError = connectError
    }

    func makeClient(
        launchInfo: SettingsLaunchInfo,
        model: GlassEQSettingsViewModel
    ) throws -> any SettingsPipeClientConnection {
        if let makeError {
            throw makeError
        }
        launchInfos.append(launchInfo)
        return FakeSettingsPipeClient(
            snapshot: snapshot,
            connectError: connectError
        )
    }
}

@MainActor
private final class FakeSettingsPipeClient: SettingsPipeClientConnection, @unchecked Sendable {
    let token: String? = "fake-token"
    private let snapshot: SettingsSnapshotDTO
    private let connectError: (any Error)?
    private(set) var didDisconnect = false

    init(snapshot: SettingsSnapshotDTO, connectError: (any Error)?) {
        self.snapshot = snapshot
        self.connectError = connectError
    }

    func connect() async throws -> SettingsSnapshotDTO {
        if let connectError {
            throw connectError
        }
        return snapshot
    }

    func perform(_ command: SettingsCommand) async throws -> SettingsCommandResponse {
        SettingsCommandResponse()
    }

    func acknowledgeReady() async throws {}

    func disconnect() {
        didDisconnect = true
    }
}

private func launchArguments() -> [String] {
    [
        "GlassEQSettings",
        "--glasseq-main-pid", "123"
    ]
}

private final class SettingsPipePumpRecorder: @unchecked Sendable {
    private let expectedMessageCount: Int
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var messages: [SettingsPipeMessage] = []
    private var errorCount = 0
    private var endOfFileCount = 0

    init(expectedMessageCount: Int) {
        self.expectedMessageCount = expectedMessageCount
    }

    func record(_ result: Result<[SettingsPipeMessage], any Error>) {
        lock.lock()
        defer {
            lock.unlock()
        }

        switch result {
        case .success(let messages):
            self.messages.append(contentsOf: messages)
        case .failure:
            errorCount += 1
        }

        if self.messages.count >= expectedMessageCount {
            semaphore.signal()
        }
    }

    func recordEndOfFile() {
        lock.lock()
        endOfFileCount += 1
        lock.unlock()
    }

    func waitForMessages(timeout: DispatchTime) -> Bool {
        semaphore.wait(timeout: timeout) == .success
    }

    func snapshot() -> (messages: [SettingsPipeMessage], errorCount: Int, endOfFileCount: Int) {
        lock.lock()
        defer {
            lock.unlock()
        }
        return (messages, errorCount, endOfFileCount)
    }
}

private enum SettingsPipeWriteTestError: Error {
    case failed
}

private extension Result where Success == Void, Failure == any Error {
    var isSuccess: Bool {
        if case .success = self {
            return true
        }
        return false
    }

    var isClosedPipePumpFailure: Bool {
        if case .failure(let error as SettingsPipeWritePumpError) = self,
           error == .closed {
            return true
        }
        return false
    }
}

private final class SettingsPipeResultRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var _result: Result<Void, any Error>?

    var result: Result<Void, any Error>? {
        lock.lock()
        defer {
            lock.unlock()
        }
        return _result
    }

    func record(_ result: Result<Void, any Error>) {
        lock.lock()
        _result = result
        lock.unlock()
        semaphore.signal()
    }

    func wait(timeout: DispatchTime) -> Bool {
        semaphore.wait(timeout: timeout) == .success
    }
}

private final class OrderedDeliveryRecorder: @unchecked Sendable {
    private let expectedCount: Int
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var _events: [String] = []

    init(expectedCount: Int) {
        self.expectedCount = expectedCount
    }

    var events: [String] {
        lock.lock()
        defer {
            lock.unlock()
        }
        return _events
    }

    func record(_ event: String) {
        lock.lock()
        _events.append(event)
        let shouldSignal = _events.count >= expectedCount
        lock.unlock()

        if shouldSignal {
            semaphore.signal()
        }
    }

    func wait(timeout: DispatchTime) -> Bool {
        semaphore.wait(timeout: timeout) == .success
    }
}

private final class BlockingSettingsPipeWriteSink: @unchecked Sendable {
    private let started = DispatchSemaphore(value: 0)
    private let unblocker = DispatchSemaphore(value: 0)
    private let closed = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var _closeCount = 0

    var closeCount: Int {
        lock.lock()
        defer {
            lock.unlock()
        }
        return _closeCount
    }

    func write(_ data: Data) {
        started.signal()
        _ = unblocker.wait(timeout: .now() + 2)
    }

    func waitUntilWriteStarted(timeout: DispatchTime) -> Bool {
        started.wait(timeout: timeout) == .success
    }

    func unblock() {
        unblocker.signal()
    }

    func close() {
        lock.lock()
        _closeCount += 1
        lock.unlock()
        closed.signal()
    }

    func waitUntilClosed(timeout: DispatchTime) -> Bool {
        closed.wait(timeout: timeout) == .success
    }
}

private final class SettingsPipeWriteRecorder: @unchecked Sendable {
    private let expectedWriteCount: Int
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var messages: [SettingsPipeMessage] = []
    private var successCount = 0
    private var errorCount = 0

    init(expectedWriteCount: Int) {
        self.expectedWriteCount = expectedWriteCount
    }

    func write(_ data: Data) throws {
        let message = try SettingsPipeCodec.decodeLine(Data(data.dropLast()))
        lock.lock()
        messages.append(message)
        lock.unlock()
    }

    func recordCompletion(_ result: Result<Void, any Error>) {
        lock.lock()
        defer {
            lock.unlock()
        }
        switch result {
        case .success:
            successCount += 1
        case .failure:
            errorCount += 1
        }
        if successCount + errorCount >= expectedWriteCount {
            semaphore.signal()
        }
    }

    func waitForCompletions(timeout: DispatchTime) -> Bool {
        semaphore.wait(timeout: timeout) == .success
    }

    func snapshot() -> (messages: [SettingsPipeMessage], successCount: Int, errorCount: Int) {
        lock.lock()
        defer {
            lock.unlock()
        }
        return (messages, successCount, errorCount)
    }
}
