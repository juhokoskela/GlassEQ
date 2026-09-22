import Foundation
import Testing
@testable import GlassEQApp

/// The packaging scripts copy the repository's LICENSE into the app bundle. The repository root
/// itself is a flat bundle with that file at its top level, so the lookup can be tested without
/// packaging an app.
private func repositoryRootAsBundle() throws -> Bundle {
    let root = URL(filePath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    return try #require(Bundle(url: root))
}

@Suite
struct AppBuildInfoTests {
    @Test
    func releaseBuildShowsItsLabelAndFullVersionLine() {
        let info = AppBuildInfo(infoDictionary: [
            "CFBundleShortVersionString": "0.9.3",
            "CFBundleVersion": "15",
            "GlassEQReleaseLabel": "beta-0.9.3",
            "NSHumanReadableCopyright": "Copyright © 2026 Juho Koskela",
        ])

        #expect(info.displayVersion == "beta-0.9.3")
        #expect(info.versionLine == "Version 0.9.3 (15) · beta-0.9.3")
        #expect(info.copyright == "Copyright © 2026 Juho Koskela")
    }

    @Test
    func unlabelledBuildFallsBackToVersionAndBuild() {
        let info = AppBuildInfo(infoDictionary: [
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "20",
            "GlassEQReleaseLabel": "",
        ])

        #expect(info.displayVersion == "v1.0 (20)")
        #expect(info.versionLine == "Version 1.0 (20)")
        #expect(info.releaseLabel == nil)
    }

    @Test
    func bundlelessRunIsReportedAsASourceBuild() {
        let info = AppBuildInfo(infoDictionary: [:])

        #expect(info.displayVersion == "Source build")
        #expect(info.versionLine == "Source build without version information")
        #expect(info.copyright == nil)
    }
}

@Suite
struct LegalNoticesTests {
    @Test
    func bundledLicenseTextIsTheGPLv3() throws {
        let text = try #require(LegalNotices.gplText(from: repositoryRootAsBundle()))

        #expect(text.contains("GNU GENERAL PUBLIC LICENSE"))
        #expect(text.contains("Version 3, 29 June 2007"))
        #expect(text.contains("END OF TERMS AND CONDITIONS"))
    }

    @Test
    func autoEqNoticeCarriesTheMITPermissionAndCopyright() {
        #expect(LegalNotices.autoEqCopyright.hasPrefix("Copyright (c)"))
        #expect(LegalNotices.autoEqCopyright.contains("Jaakko Pasanen"))
        #expect(LegalNotices.mitLicenseText.hasPrefix("Permission is hereby granted, free of charge"))
        #expect(LegalNotices.mitLicenseText.contains("THE SOFTWARE IS PROVIDED \"AS IS\""))
    }
}
