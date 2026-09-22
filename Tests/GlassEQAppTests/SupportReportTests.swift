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
        #expect(LifecycleLog.launchOptions(arguments: ["GlassEQ", "--debug"]))
        #expect(!LifecycleLog.launchOptions(arguments: ["GlassEQ"]))
        #expect(!LifecycleLog.launchOptions(arguments: ["--debug"]))
        #expect(!LifecycleLog.launchOptions(arguments: []))
    }
}

@Suite
struct LaunchRecordStoreTests {
    private func temporaryRecordURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "GlassEQLaunchRecordTests-\(UUID().uuidString)")
            .appending(path: LaunchRecordStore.filename)
    }

    @Test
    func firstRunHasNoPreviousRecordAndWritesItsOwn() throws {
        let url = temporaryRecordURL()
        defer { LaunchRecordStore.endRun(at: url) }

        let previous = LaunchRecordStore.beginRun(at: url, version: "v1.0 (1)", processIdentifier: 100)

        #expect(previous == nil)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test
    func cleanShutdownLeavesNothingForTheNextRun() {
        let url = temporaryRecordURL()

        _ = LaunchRecordStore.beginRun(at: url, version: "v1.0 (1)", processIdentifier: 100)
        LaunchRecordStore.endRun(at: url)
        let previous = LaunchRecordStore.beginRun(at: url, version: "v1.0 (1)", processIdentifier: 101)
        LaunchRecordStore.endRun(at: url)

        #expect(previous == nil)
    }

    @Test
    func aLeftoverRecordFromADeadProcessReportsTheUncleanRun() {
        let url = temporaryRecordURL()
        defer { LaunchRecordStore.endRun(at: url) }
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

        _ = LaunchRecordStore.beginRun(at: url, startedAt: startedAt, version: "v1.0 (1)", processIdentifier: 100)
        let previous = LaunchRecordStore.beginRun(
            at: url, version: "v1.0 (2)", processIdentifier: 101, isProcessAlive: { _ in false })

        #expect(previous == LaunchRecord(startedAt: startedAt, version: "v1.0 (1)", processIdentifier: 100))
    }

    @Test
    func aRecordFromARunningProcessIsAnotherInstanceNotACrash() {
        let url = temporaryRecordURL()
        defer { LaunchRecordStore.endRun(at: url) }

        _ = LaunchRecordStore.beginRun(at: url, version: "v1.0 (1)", processIdentifier: 100)
        let previous = LaunchRecordStore.beginRun(
            at: url, version: "v1.0 (1)", processIdentifier: 101, isProcessAlive: { $0 == 100 })

        #expect(previous == nil)
    }

    @Test
    func aRecordFromThisProcessIsIgnored() {
        let url = temporaryRecordURL()
        defer { LaunchRecordStore.endRun(at: url) }

        _ = LaunchRecordStore.beginRun(at: url, version: "v1.0 (1)", processIdentifier: 100)
        let previous = LaunchRecordStore.beginRun(
            at: url, version: "v1.0 (1)", processIdentifier: 100, isProcessAlive: { _ in false })

        #expect(previous == nil)
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
            installLocation: "installed normally",
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
