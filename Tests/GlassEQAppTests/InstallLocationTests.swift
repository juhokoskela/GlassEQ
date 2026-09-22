import Foundation
import Testing
@testable import GlassEQApp

@Suite
struct InstallLocationTests {
    private let downloads = URL(filePath: "/Users/someone/Downloads", directoryHint: .isDirectory)

    @Test
    func anAppInApplicationsHasNoIssue() {
        let issue = InstallLocation.issue(
            bundleURL: URL(filePath: "/Applications/GlassEQ.app"), downloadsDirectory: downloads)

        #expect(issue == nil)
    }

    @Test
    func aBareExecutableIsNotAnInstalledApp() {
        let issue = InstallLocation.issue(
            bundleURL: URL(filePath: "/Users/someone/Downloads/GlassEQ"), downloadsDirectory: downloads)

        #expect(issue == nil)
    }

    @Test
    func downloadsAndTranslocationAreReported() {
        #expect(
            InstallLocation.issue(
                bundleURL: URL(filePath: "/Users/someone/Downloads/GlassEQ.app"), downloadsDirectory: downloads)
                == .downloads)
        #expect(
            InstallLocation.issue(
                bundleURL: URL(
                    filePath: "/private/var/folders/xx/T/AppTranslocation/1234-5678/d/GlassEQ.app"),
                downloadsDirectory: downloads)
                == .translocated)
    }

    @Test
    func aReadOnlyVolumeIsReportedBeforeTheDownloadsCheck() {
        let issue = InstallLocation.issue(
            bundleURL: URL(filePath: "/Volumes/GlassEQ/GlassEQ.app"),
            downloadsDirectory: downloads,
            isVolumeReadOnly: { $0.path.hasPrefix("/Volumes/GlassEQ") })

        #expect(issue == .readOnlyVolume)
        #expect(
            InstallLocation.issue(
                bundleURL: URL(filePath: "/Applications/GlassEQ.app"), downloadsDirectory: downloads,
                isVolumeReadOnly: { _ in false })
                == nil)
    }
}
