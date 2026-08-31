import AVFoundation
import Foundation
import GlassEQCore
import GlassEQSettingsIPC
import Testing
@testable import GlassEQSettingsUI

@Suite
struct ImpulseResponseWAVImporterTests {
    @Test
    func mainProcessFileLoaderPackagesTextAndImpulseResponseSelections() throws {
        let textURL = try writeText("Preamp: -3 dB")
        let wavURL = try writeWAV(channels: [[1, 0.25]])
        defer {
            try? FileManager.default.removeItem(at: textURL)
            try? FileManager.default.removeItem(at: wavURL)
        }

        let textSelection = try SettingsFileImportPicker.loadSelection(
            mode: .single,
            urls: [textURL],
            expectedSampleRate: 48_000
        )
        guard case let .text(suggestedName, filename, text) = textSelection else {
            Issue.record("Expected a text-file selection")
            return
        }
        #expect(suggestedName == textURL.deletingPathExtension().lastPathComponent)
        #expect(filename == textURL.lastPathComponent)
        #expect(text == "Preamp: -3 dB")

        let wavSelection = try SettingsFileImportPicker.loadSelection(
            mode: .single,
            urls: [wavURL],
            expectedSampleRate: 48_000
        )
        guard case let .impulseResponse(profile, channels, sourceFileCount) = wavSelection else {
            Issue.record("Expected an impulse-response selection")
            return
        }
        #expect(profile.mode == .convolution)
        #expect(channels.map(\.frameCount) == [2])
        #expect(sourceFileCount == 1)
    }

    @Test
    func importsMonoWAVAsLinkedImpulseResponse() throws {
        let url = try writeWAV(channels: [[1, 0.25, -0.125]])
        defer { try? FileManager.default.removeItem(at: url) }

        let imported = try ImpulseResponseWAVImporter.load(
            from: url,
            expectedSampleRate: 48_000
        )

        #expect(imported.frameCount == 3)
        #expect(imported.channelCount == 1)
        #expect(imported.sourceFileCount == 1)
        #expect(imported.profile.channelMode == .linked)
        guard case .impulseResponse(let source) = imported.profile.convolution else {
            Issue.record("Expected linked impulse response")
            return
        }
        #expect(source.sampleRate == 48_000)
        #expect(source.samples == [1, 0.25, -0.125])
    }

    @Test
    func importsStereoWAVWithoutCombiningChannels() throws {
        let url = try writeWAV(channels: [
            [1, 0.5, 0.25],
            [-1, -0.5, -0.25]
        ])
        defer { try? FileManager.default.removeItem(at: url) }

        let imported = try ImpulseResponseWAVImporter.load(from: url)

        #expect(imported.channelCount == 2)
        #expect(imported.sourceFileCount == 1)
        #expect(imported.profile.channelMode == .stereo)
        guard case .impulseResponse(let left) = imported.profile.leftConvolution,
              case .impulseResponse(let right) = imported.profile.rightConvolution else {
            Issue.record("Expected independent stereo impulse responses")
            return
        }
        #expect(left.samples == [1, 0.5, 0.25])
        #expect(right.samples == [-1, -0.5, -0.25])
    }

    @Test
    func importsSeparateMonoWAVsAsLeftAndRightSources() throws {
        let leftURL = try writeWAV(channels: [[1, 0.5, 0.25]])
        let rightURL = try writeWAV(channels: [[-1, -0.25]])
        defer {
            try? FileManager.default.removeItem(at: leftURL)
            try? FileManager.default.removeItem(at: rightURL)
        }

        var imported = try ImpulseResponseWAVImporter.loadStereoPair(
            leftURL: leftURL,
            rightURL: rightURL,
            expectedSampleRate: 48_000
        )

        #expect(imported.channelCount == 2)
        #expect(imported.sourceFileCount == 2)
        #expect(imported.channels[0].filename == leftURL.lastPathComponent)
        #expect(imported.channels[0].frameCount == 3)
        #expect(imported.channels[1].filename == rightURL.lastPathComponent)
        #expect(imported.channels[1].frameCount == 2)
        guard case .impulseResponse(let left) = imported.profile.leftConvolution,
              case .impulseResponse(let right) = imported.profile.rightConvolution else {
            Issue.record("Expected separate left and right impulse responses")
            return
        }
        #expect(left.samples == [1, 0.5, 0.25])
        #expect(right.samples == [-1, -0.25])

        imported.swapStereoChannels()

        #expect(imported.channels[0].filename == rightURL.lastPathComponent)
        #expect(imported.channels[1].filename == leftURL.lastPathComponent)
        guard case .impulseResponse(let swappedLeft) = imported.profile.leftConvolution,
              case .impulseResponse(let swappedRight) = imported.profile.rightConvolution else {
            Issue.record("Expected swapped left and right impulse responses")
            return
        }
        #expect(swappedLeft.samples == right.samples)
        #expect(swappedRight.samples == left.samples)
    }

    @Test
    func rejectsStereoFileAsOneSideOfSeparatePair() throws {
        let leftURL = try writeWAV(channels: [[1], [0.5]])
        let rightURL = try writeWAV(channels: [[1]])
        defer {
            try? FileManager.default.removeItem(at: leftURL)
            try? FileManager.default.removeItem(at: rightURL)
        }

        #expect(throws: ImpulseResponseWAVImportError.separateFilesMustBeMono(
            leftChannels: 2,
            rightChannels: 1
        )) {
            _ = try ImpulseResponseWAVImporter.loadStereoPair(
                leftURL: leftURL,
                rightURL: rightURL
            )
        }
    }

    @Test
    func rejectsSeparateFilesWithDifferentSampleRates() throws {
        let leftURL = try writeWAV(channels: [[1]], sampleRate: 48_000)
        let rightURL = try writeWAV(channels: [[1]], sampleRate: 96_000)
        defer {
            try? FileManager.default.removeItem(at: leftURL)
            try? FileManager.default.removeItem(at: rightURL)
        }

        #expect(throws: ImpulseResponseWAVImportError.channelSampleRateMismatch(
            left: 48_000,
            right: 96_000
        )) {
            _ = try ImpulseResponseWAVImporter.loadStereoPair(
                leftURL: leftURL,
                rightURL: rightURL
            )
        }
    }

    @Test
    func importsSeparateTextFilesAsLeftAndRightFilters() throws {
        let leftURL = try writeText("""
        Preamp: -2 dB
        Filter 1: ON PK Fc 100 Hz Gain 3 dB Q 1
        """)
        let rightURL = try writeText("""
        Preamp: -4 dB
        Filter 1: ON PK Fc 200 Hz Gain -2 dB Q 2
        """)
        defer {
            try? FileManager.default.removeItem(at: leftURL)
            try? FileManager.default.removeItem(at: rightURL)
        }

        var imported = try StereoTextPairImporter.load(
            leftURL: leftURL,
            rightURL: rightURL
        )

        #expect(imported.profile.mode == .parametric)
        #expect(imported.profile.channelMode == .stereo)
        #expect(imported.profile.leftPreampDB == -2)
        #expect(imported.profile.rightPreampDB == -4)
        #expect(imported.profile.leftFilters.map(\.frequency) == [100])
        #expect(imported.profile.rightFilters.map(\.frequency) == [200])
        #expect(imported.leftFilename == leftURL.lastPathComponent)
        #expect(imported.rightFilename == rightURL.lastPathComponent)

        imported.swapChannels()

        #expect(imported.profile.leftPreampDB == -4)
        #expect(imported.profile.rightPreampDB == -2)
        #expect(imported.profile.leftFilters.map(\.frequency) == [200])
        #expect(imported.profile.rightFilters.map(\.frequency) == [100])
        #expect(imported.leftFilename == rightURL.lastPathComponent)
        #expect(imported.rightFilename == leftURL.lastPathComponent)
    }

    @Test
    func importsSeparateGraphicEQFilesAsStereoResponseCurves() throws {
        let leftURL = try writeText("GraphicEQ: 20 1; 20000 -1")
        let rightURL = try writeText("GraphicEQ: 20 -2; 20000 2")
        defer {
            try? FileManager.default.removeItem(at: leftURL)
            try? FileManager.default.removeItem(at: rightURL)
        }

        let imported = try StereoTextPairImporter.load(
            leftURL: leftURL,
            rightURL: rightURL
        )

        #expect(imported.profile.mode == .convolution)
        #expect(imported.profile.channelMode == .stereo)
        guard case .magnitudeCurve(let left) = imported.profile.leftConvolution,
              case .magnitudeCurve(let right) = imported.profile.rightConvolution else {
            Issue.record("Expected separate response curves")
            return
        }
        #expect(left.points.map(\.gainDB) == [1, -1])
        #expect(right.points.map(\.gainDB) == [-2, 2])
    }

    @Test
    func importsSeparateREWFilesAsLeftAndRightFilters() throws {
        let leftURL = try writeText("""
        Filter Settings file
        Room EQ V5.31.3
        Equaliser: Generic
        Filter 1: ON PK Fc 45 Hz Gain -4.5 dB Q 3.2
        """)
        let rightURL = try writeText("""
        Filter Settings file
        Room EQ V5.31.3
        Equaliser: Generic
        Filter 1: ON PK Fc 63 Hz Gain -2.5 dB Q 2.1
        """)
        defer {
            try? FileManager.default.removeItem(at: leftURL)
            try? FileManager.default.removeItem(at: rightURL)
        }

        let imported = try StereoTextPairImporter.load(
            leftURL: leftURL,
            rightURL: rightURL
        )

        #expect(imported.profile.mode == .parametric)
        #expect(imported.profile.channelMode == .stereo)
        #expect(imported.profile.leftFilters.map(\.frequency) == [45])
        #expect(imported.profile.rightFilters.map(\.frequency) == [63])
        #expect(imported.profile.leftFilters.map(\.gainDB) == [-4.5])
        #expect(imported.profile.rightFilters.map(\.gainDB) == [-2.5])
    }

    @Test
    func rejectsWAVForDifferentOutputSampleRate() throws {
        let url = try writeWAV(channels: [[1]])
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: ImpulseResponseWAVImportError.sampleRateMismatch(
            file: 48_000,
            output: 96_000
        )) {
            _ = try ImpulseResponseWAVImporter.load(
                from: url,
                expectedSampleRate: 96_000
            )
        }
    }

    @Test
    func rejectsWAVWhenProcessingSampleRateIsUnknown() throws {
        let url = try writeWAV(channels: [[1]])
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: ImpulseResponseWAVImportError.processingSampleRateUnavailable) {
            _ = try ImpulseResponseWAVImporter.load(
                from: url,
                expectedSampleRate: 0
            )
        }
    }

    private func writeWAV(
        channels: [[Float]],
        sampleRate: Double = 48_000
    ) throws -> URL {
        let frameCount = try #require(channels.first?.count)
        #expect(channels.allSatisfy { $0.count == frameCount })
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channels.count),
            interleaved: false
        ))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlassEQ-IR-\(UUID().uuidString).wav")
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let buffer = try #require(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount)
        ))
        buffer.frameLength = AVAudioFrameCount(frameCount)
        let storage = try #require(buffer.floatChannelData)
        for channel in channels.indices {
            for frame in channels[channel].indices {
                storage[channel][frame] = channels[channel][frame]
            }
        }
        try file.write(from: buffer)
        return url
    }

    private func writeText(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlassEQ-EQ-\(UUID().uuidString).txt")
        try Data(text.utf8).write(to: url)
        return url
    }
}
