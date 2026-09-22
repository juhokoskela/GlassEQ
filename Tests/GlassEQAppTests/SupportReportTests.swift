import Foundation
import Testing
@testable import GlassEQApp

@MainActor
@Suite
struct LifecycleLogTests {
    @Test
    func keepsOnlyTheMostRecentEntriesInOrder() {
        let log = LifecycleLog(now: { Date(timeIntervalSince1970: 0) })

        for index in 0..<(LifecycleLog.capacity + 5) {
            log.record("event \(index)")
        }

        #expect(log.entries.count == LifecycleLog.capacity)
        #expect(log.entries.first?.message == "event 5")
        #expect(log.entries.last?.message == "event \(LifecycleLog.capacity + 4)")
    }

    @Test
    func textCarriesTimestampsAndMessages() {
        let log = LifecycleLog(now: { Date(timeIntervalSince1970: 1_700_000_000) })

        log.record("first")
        log.record("second")

        let lines = log.text.split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines[0].hasSuffix(" first"))
        #expect(lines[0].hasPrefix("2023-11-14T22:13:20"))
        #expect(lines[1].hasSuffix(" second"))
    }

    @Test
    func debugFlagIsReadFromArgumentsAfterTheExecutable() {
        #expect(LifecycleLog.isDebugLaunch(arguments: ["GlassEQ", "--debug"]))
        #expect(!LifecycleLog.isDebugLaunch(arguments: ["GlassEQ"]))
        #expect(!LifecycleLog.isDebugLaunch(arguments: ["--debug"]))
        #expect(!LifecycleLog.isDebugLaunch(arguments: []))
    }
}

@Suite
struct LaunchRecordStoreTests {
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "GlassEQLaunchRecordTests-\(UUID().uuidString)")
    }

    private let dead: (LaunchRecord) -> Bool = { _ in false }

    @Test
    func firstRunHasNoPreviousRecordAndWritesItsOwn() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let previous = LaunchRecordStore.beginRun(
            in: directory, version: "v1.0 (1)", processIdentifier: 100, isProcessAlive: dead)

        #expect(previous == nil)
        #expect(
            FileManager.default.fileExists(
                atPath: LaunchRecordStore.recordURL(in: directory, processIdentifier: 100).path))
    }

    @Test
    func cleanShutdownLeavesNothingForTheNextRun() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        _ = LaunchRecordStore.beginRun(in: directory, version: "v1.0 (1)", processIdentifier: 100, isProcessAlive: dead)
        LaunchRecordStore.endRun(in: directory, processIdentifier: 100)
        let previous = LaunchRecordStore.beginRun(
            in: directory, version: "v1.0 (1)", processIdentifier: 101, isProcessAlive: dead)

        #expect(previous == nil)
    }

    @Test
    func aLeftoverRecordFromADeadProcessReportsTheUncleanRunOnce() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        _ = LaunchRecordStore.beginRun(
            in: directory, startedAt: startedAt, version: "v1.0 (1)", processIdentifier: 100, isProcessAlive: dead)
        let previous = LaunchRecordStore.beginRun(
            in: directory, version: "v1.0 (2)", processIdentifier: 101, isProcessAlive: dead)
        let again = LaunchRecordStore.beginRun(
            in: directory, version: "v1.0 (2)", processIdentifier: 102, isProcessAlive: { $0.processIdentifier == 101 })

        #expect(previous == LaunchRecord(startedAt: startedAt, version: "v1.0 (1)", processIdentifier: 100))
        #expect(again == nil)
    }

    @Test
    func aRecordFromARunningProcessIsAnotherInstanceNotACrash() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        _ = LaunchRecordStore.beginRun(in: directory, version: "v1.0 (1)", processIdentifier: 100, isProcessAlive: dead)
        let previous = LaunchRecordStore.beginRun(
            in: directory, version: "v1.0 (1)", processIdentifier: 101, isProcessAlive: { $0.processIdentifier == 100 })

        #expect(previous == nil)
        #expect(
            FileManager.default.fileExists(
                atPath: LaunchRecordStore.recordURL(in: directory, processIdentifier: 100).path))
    }

    @Test
    func overlappingCopiesKeepTheirOwnMarkers() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bStartedAt = Date(timeIntervalSince1970: 1_700_000_500)

        _ = LaunchRecordStore.beginRun(in: directory, version: "A", processIdentifier: 100, isProcessAlive: dead)
        _ = LaunchRecordStore.beginRun(
            in: directory, startedAt: bStartedAt, version: "B", processIdentifier: 101,
            isProcessAlive: { $0.processIdentifier == 100 })
        LaunchRecordStore.endRun(in: directory, processIdentifier: 100)
        // B crashes; nothing removes its record.
        let previous = LaunchRecordStore.beginRun(
            in: directory, version: "C", processIdentifier: 102, isProcessAlive: dead)

        #expect(previous == LaunchRecord(startedAt: bStartedAt, version: "B", processIdentifier: 101))
    }

    @Test(arguments: [4_095, 4_096, 4_097, 65_536])
    func oversizedMarkersAreIgnoredWithoutHidingValidRecords(byteCount: Int) throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = LaunchRecordStore.beginRun(
            in: directory, startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            version: "Older", processIdentifier: 100, isProcessAlive: dead)
        _ = LaunchRecordStore.beginRun(
            in: directory, startedAt: Date(timeIntervalSince1970: 1_700_000_900),
            version: "Newer", processIdentifier: 101, isProcessAlive: { _ in true })
        let url = LaunchRecordStore.recordURL(in: directory, processIdentifier: 101)
        var data = try Data(contentsOf: url)
        data.append(Data(repeating: 0x20, count: byteCount - data.count))
        try data.write(to: url)

        let previous = LaunchRecordStore.beginRun(
            in: directory, version: "Current", processIdentifier: 102, isProcessAlive: dead)

        #expect(previous?.version == (byteCount <= 4_096 ? "Newer" : "Older"))
        #expect(
            FileManager.default.fileExists(
                atPath: LaunchRecordStore.recordURL(in: directory, processIdentifier: 102).path))
    }

    @Test
    func theNewestDeadRecordWinsWhenSeveralAreLeftBehind() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let older = Date(timeIntervalSince1970: 1_700_000_000)
        let newer = Date(timeIntervalSince1970: 1_700_000_900)

        _ = LaunchRecordStore.beginRun(
            in: directory, startedAt: newer, version: "N", processIdentifier: 100, isProcessAlive: dead)
        _ = LaunchRecordStore.beginRun(
            in: directory, startedAt: older, version: "O", processIdentifier: 101,
            isProcessAlive: { $0.processIdentifier == 100 })
        let previous = LaunchRecordStore.beginRun(
            in: directory, version: "C", processIdentifier: 102, isProcessAlive: dead)

        #expect(previous?.version == "N")
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["102.json"])
    }
}

@Suite
struct SupportReportTextTests {
    private func makeInputs() -> SupportReportInputs {
        SupportReportInputs(
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            build: AppBuildInfo(infoDictionary: [
                "CFBundleShortVersionString": "1.0", "CFBundleVersion": "20", "GlassEQReleaseLabel": "production-1.0",
            ]),
            operatingSystemVersion: "Version 26.1 (Build 25B99)",
            architecture: "arm64",
            modelIdentifier: "Mac15,6",
            launchedWithDebugFlag: true,
            installLocation: nil,
            lifecycleState: "running",
            statusMessage: "Processing on Studio Monitors",
            isRunning: true,
            onboardingIsComplete: true,
            audioCaptureState: "running on Studio Monitors",
            launchAtLoginStatus: "enabled",
            licenseSummary: "Perpetual license. Every v1 update is included.",
            previousRun: LaunchRecord(
                startedAt: Date(timeIntervalSince1970: 1_699_990_000), version: "v1.0 (19)", processIdentifier: 4),
            profileCount: 3,
            activeProfileName: "HD 58X",
            activeProfileMode: "convolution",
            activeProfileIsBypassed: false,
            currentOutputIsMapped: true,
            fallbackProfileName: "Flat",
            audioDiagnostics: "GlassEQ audio diagnostics\nOutput: Studio Monitors",
            recentEvents: "2023-11-14T22:13:20.000Z Launch"
        )
    }

    @Test
    func reportListsEverySectionWithTheProvidedValues() {
        let text = SupportReport.text(makeInputs())

        #expect(text.hasPrefix("# GlassEQ support report\nGenerated: 2023-11-14T22:13:20Z\n"))
        #expect(text.contains("Version: Version 1.0 (20) · production-1.0"))
        #expect(text.contains("Launched with --debug: yes"))
        #expect(text.contains("Install location: installed normally"))
        #expect(text.contains("macOS: Version 26.1 (Build 25B99)"))
        #expect(text.contains("Model identifier: Mac15,6"))
        #expect(text.contains("License: Perpetual license."))
        #expect(text.contains("Previous run: did not quit cleanly (started 2023-11-14T19:26:40Z, v1.0 (19))"))
        #expect(text.contains("Active profile: HD 58X (convolution)"))
        #expect(text.contains("## Audio diagnostics\nGlassEQ audio diagnostics\nOutput: Studio Monitors"))
        #expect(text.hasSuffix("## Recent events\n2023-11-14T22:13:20.000Z Launch"))
    }

    @Test
    func optionalLinesFallBackWhenAbsent() {
        var inputs = makeInputs()
        inputs.modelIdentifier = nil
        inputs.licenseSummary = nil
        inputs.previousRun = nil
        inputs.recentEvents = ""
        inputs.activeProfileIsBypassed = true

        let text = SupportReport.text(inputs)

        #expect(!text.contains("Model identifier"))
        #expect(!text.contains("License:"))
        #expect(text.contains("Previous run: quit cleanly"))
        #expect(text.contains("Active profile: HD 58X (convolution, disabled)"))
        #expect(text.hasSuffix("## Recent events\nNone recorded"))
    }

    @Test
    func suggestedFilenameIsDatedAndPlainText() {
        let name = SupportReport.suggestedFilename(generatedAt: Date(timeIntervalSince1970: 1_700_000_000))

        #expect(name.hasPrefix("GlassEQ Support Report 2023-11-1"))
        #expect(name.hasSuffix(".txt"))
        #expect(!name.contains(":"))
    }
}
