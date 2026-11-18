import SwiftUI

/// The identity of the running build, read once from Info.plist. A source build run without a
/// bundle has none of these keys and says so instead of inventing a version.
struct AppBuildInfo {
    let version: String?
    let build: String?
    let releaseLabel: String?
    let copyright: String?

    init(infoDictionary: [String: Any]) {
        func string(_ key: String) -> String? {
            guard let value = infoDictionary[key] as? String, !value.isEmpty else {
                return nil
            }
            return value
        }
        version = string("CFBundleShortVersionString")
        build = string("CFBundleVersion")
        releaseLabel = string("GlassEQReleaseLabel")
        copyright = string("NSHumanReadableCopyright")
    }

    static let current = AppBuildInfo(infoDictionary: Bundle.main.infoDictionary ?? [:])

    /// The compact form in the menu bar popover.
    var displayVersion: String {
        if let releaseLabel {
            return releaseLabel
        }
        guard let version else {
            return localized("Source build")
        }
        return "v\(version)\(build.map { " (\($0))" } ?? "")"
    }

    /// The long form in the About window: marketing version, build number, and release label.
    var versionLine: String {
        guard let version else {
            return localized("Source build without version information")
        }
        var line = localized("Version \(version)")
        if let build {
            line += " (\(build))"
        }
        if let releaseLabel {
            line += " · \(releaseLabel)"
        }
        return line
    }
}

enum GlassEQLinks {
    static let website = URL(string: "https://glasseq.app")!
    static let sourceCode = URL(string: "https://github.com/juhokoskela/GlassEQ")!
    static let trademarkPolicy = URL(string: "https://github.com/juhokoskela/GlassEQ/blob/main/TRADEMARKS.md")!
}

enum LegalNotices {
    /// The full GPL text that the packaging scripts place at `Contents/Resources/LICENSE`, so the
    /// license is readable offline. A bare `swift run` has no bundle and shows the fallback.
    static func gplText(from bundle: Bundle = .main) -> String? {
        guard let url = bundle.url(forResource: "LICENSE", withExtension: nil),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else {
            return nil
        }
        return text
    }

    /// Read once; the sheet's body must not touch the file on every render.
    static let bundledGPLText = gplText()

    static let autoEqCopyright = "Copyright (c) 2018-2022 Jaakko Pasanen"

    static let mitLicenseText = """
        Permission is hereby granted, free of charge, to any person obtaining a copy of this software \
        and associated documentation files (the "Software"), to deal in the Software without \
        restriction, including without limitation the rights to use, copy, modify, merge, publish, \
        distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the \
        Software is furnished to do so, subject to the following conditions:

        The above copyright notice and this permission notice shall be included in all copies or \
        substantial portions of the Software.

        THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING \
        BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND \
        NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, \
        DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, \
        OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
        """
}

struct AboutView: View {
    let model: GlassEQAppModel
    @State private var showsReport = false
    @State private var showsLicense = false

    var body: some View {
        Form {
            Section {
                Text(AppBuildInfo.current.versionLine)
                if let copyright = AppBuildInfo.current.copyright { Text(copyright) }
                Link(localized("GlassEQ website"), destination: GlassEQLinks.website)
                Link(localized("Source code"), destination: GlassEQLinks.sourceCode)
                Button(localized("Support Report…")) { showsReport = true }
                Button(localized("Open Setup Guide")) { model.requestOnboardingPresentation() }
            }
            Section(localized("Privacy")) {
                Text(
                    localized(
                        "Audio, profiles and diagnostics stay on your Mac. You choose whether to share a support report."
                    ))
                Text(
                    localized(
                        "Official builds send your license key and a random installation identifier to activate. License refresh and deactivation send the activation token and installation identifier. Keychain stores that identifier, the activation token, the signed entitlement and its verification state."
                    ))
                Text(localized("AutoEq downloads its catalogue and the result you select from GitHub."))
            }
            Section(localized("Licenses and credits")) {
                Button(localized("GNU General Public License v3 or later")) { showsLicense = true }
                Link(localized("GlassEQ trademark policy"), destination: GlassEQLinks.trademarkPolicy)
                DisclosureGroup(localized("AutoEq · MIT License")) {
                    Text(verbatim: LegalNotices.autoEqCopyright + "\n\n" + LegalNotices.mitLicenseText)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 460, idealWidth: 520, minHeight: 410, idealHeight: 510)
        .sheet(isPresented: $showsReport) { SupportReportView(model: model) }
        .sheet(isPresented: $showsLicense) { LicenseTextSheet() }
    }
}

struct LicenseTextSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                Text(verbatim: LegalNotices.bundledGPLText ?? localized("The license text is missing from this build."))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
            Divider()
            HStack {
                Spacer()
                Button(localized("Done")) {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 620, height: 520)
        .navigationTitle(localized("GNU General Public License"))
    }
}
