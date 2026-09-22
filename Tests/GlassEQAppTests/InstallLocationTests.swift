import Foundation
import Testing
@testable import GlassEQApp

@Suite
struct InstallLocationTests {
    @Test
    func anAppInApplicationsHasNoIssue() {
        let issue = InstallLocation.issue(
            bundleURL: URL(filePath: "/Applications/GlassEQ.app"))

        #expect(issue == nil)
    }

    @Test
    func aBareExecutableIsNotAnInstalledApp() {
        let issue = InstallLocation.issue(
            bundleURL: URL(filePath: "/Users/someone/Downloads/GlassEQ"))

        #expect(issue == nil)
    }

    @Test
    func writableDownloadsIsAllowedAndTranslocationIsReported() {
        #expect(
            InstallLocation.issue(
                bundleURL: URL(filePath: "/Users/someone/Downloads/GlassEQ.app"))
                == nil)
        #expect(
            InstallLocation.issue(
                bundleURL: URL(
                    filePath: "/private/var/folders/xx/T/AppTranslocation/1234-5678/d/GlassEQ.app"))
                == .translocated)
    }

    @Test
    func aReadOnlyVolumeIsReported() {
        let issue = InstallLocation.issue(
            bundleURL: URL(filePath: "/Volumes/GlassEQ/GlassEQ.app"),
            isVolumeReadOnly: { $0.path.hasPrefix("/Volumes/GlassEQ") })

        #expect(issue == .readOnlyVolume)
        #expect(
            InstallLocation.issue(
                bundleURL: URL(filePath: "/Applications/GlassEQ.app"),
                isVolumeReadOnly: { _ in false })
                == nil)
    }
}
