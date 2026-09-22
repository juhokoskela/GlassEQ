import AppKit
import SwiftUI

/// The identity of the running build, read once from Info.plist. A source build run without a
/// bundle has none of these keys and says so instead of inventing a version.
struct AppBuildInfo: Equatable {
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
    static let gnuLicenses = URL(string: "https://www.gnu.org/licenses/")!
    static let autoEq = URL(string: "https://github.com/jaakkopasanen/AutoEq")!
    static let contact = URL(string: "mailto:contact@juhokoskela.fi")!
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

enum AboutSection: String, CaseIterable, Identifiable {
    case overview
    case license
    case privacy
    case credits

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .overview:
            localized("Overview")
        case .license:
            localized("License")
        case .privacy:
            localized("Privacy")
        case .credits:
            localized("Credits")
        }
    }
}

struct AboutView: View {
    let model: GlassEQAppModel
    @State private var section: AboutSection
    @State private var isShowingLicenseText = false

    static let width: CGFloat = 520
    static let contentHeight: CGFloat = 340

    init(model: GlassEQAppModel, section: AboutSection = .overview) {
        self.model = model
        _section = State(initialValue: section)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 28)
                .padding(.top, 24)
                .padding(.bottom, 16)

            Picker(localized("Section"), selection: $section) {
                ForEach(AboutSection.allCases) { section in
                    Text(section.title).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 28)
            .accessibilityLabel(Text(localized("About section")))

            ScrollView {
                content
                    .padding(.horizontal, 28)
                    .padding(.vertical, 20)
                    .frame(width: Self.width, alignment: .topLeading)
            }
            .frame(height: Self.contentHeight)
        }
        .frame(width: Self.width)
        .background(Color.macOSWindowBackground)
        .sheet(isPresented: $isShowingLicenseText) {
            LicenseTextSheet()
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 18) {
            Image(nsImage: AppIcon.image)
                .resizable()
                .frame(width: 80, height: 80)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(localized("GlassEQ"))
                    .font(.title.weight(.bold))
                    .accessibilityAddTraits(.isHeader)
                Text(AppBuildInfo.current.versionLine)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if let copyright = AppBuildInfo.current.copyright {
                    Text(copyright)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 14) {
                    Link(localized("Website"), destination: GlassEQLinks.website)
                    Link(localized("Source Code"), destination: GlassEQLinks.sourceCode)
                }
                .font(.callout)
                .padding(.top, 6)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch section {
        case .overview:
            overview
        case .license:
            license
        case .privacy:
            privacy
        case .credits:
            credits
        }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 16) {
            AboutParagraph(
                localized(
                    "GlassEQ is a system-wide equalizer for macOS. It follows the output macOS is using, applies your profile to the system mix with Core Audio process taps, and plays the result on the same device. No virtual audio device, driver, or system extension is installed."
                ))
            if let licenseSummary = model.licenseSummaryMessage {
                AboutGroup(title: localized("License")) {
                    Text(licenseSummary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(localized("Manage License…")) {
                        model.requestOnboardingPresentation(step: .license)
                    }
                    .accessibilityHint(Text(localized("Opens the setup guide at the activation step")))
                }
            }
            AboutGroup(title: localized("Help")) {
                Button(localized("Open Setup Guide")) {
                    model.requestOnboardingPresentation()
                }
                .accessibilityHint(Text(localized("Reopens the first-launch walkthrough")))
            }
        }
    }

    private var license: some View {
        VStack(alignment: .leading, spacing: 16) {
            AboutParagraph(
                localized(
                    "GlassEQ is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version."
                ))
            AboutParagraph(
                localized(
                    "GlassEQ is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details."
                ))
            HStack(spacing: 14) {
                Button(localized("Show License Text")) {
                    isShowingLicenseText = true
                }
                Link(localized("gnu.org/licenses"), destination: GlassEQLinks.gnuLicenses)
                    .font(.callout)
            }
            AboutGroup(title: localized("Trademarks")) {
                Text(
                    localized(
                        "“GlassEQ” and the GlassEQ logo are trademarks of Juho Koskela. A build that Juho Koskela did not publish and sign must use a different name and logo, and must not claim to be an official release."
                    )
                )
                .fixedSize(horizontal: false, vertical: true)
                Link(localized("Trademark Policy"), destination: GlassEQLinks.trademarkPolicy)
                    .font(.callout)
            }
        }
    }

    private var privacy: some View {
        VStack(alignment: .leading, spacing: 16) {
            AboutParagraph(
                localized(
                    "Audio, profiles, output devices, and diagnostics stay on this Mac. GlassEQ has no analytics, telemetry, crash reporting, or cloud sync. Diagnostics leave this Mac only when you copy or export them yourself."
                ))
            AboutGroup(title: localized("License service")) {
                Text(
                    localized(
                        "Activating the official build sends your license key and a random installation identifier to license.glasseq.app. Later checks send that identifier and the activation token the service issued. The service never receives audio, profiles, device names, or hardware identifiers, and the app stores only the signed entitlement in Keychain."
                    )
                )
                .fixedSize(horizontal: false, vertical: true)
                Text(
                    localized(
                        "The service keeps the activation records needed to operate your license. To ask about or delete them, write to contact@juhokoskela.fi."
                    )
                )
                .fixedSize(horizontal: false, vertical: true)
            }
            AboutGroup(title: localized("AutoEq search")) {
                Text(
                    localized(
                        "Searching AutoEq downloads the public result list and the result you choose from GitHub. Like any download, the request shows GitHub your IP address. Nothing else is sent."
                    )
                )
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var credits: some View {
        VStack(alignment: .leading, spacing: 16) {
            AboutParagraph(localized("GlassEQ is made by Juho Koskela."))
            AboutGroup(title: localized("AutoEq")) {
                Text(
                    localized(
                        "Headphone measurements and recommended corrections come from AutoEq by Jaakko Pasanen, used under the MIT License."
                    )
                )
                .fixedSize(horizontal: false, vertical: true)
                Link(localized("AutoEq on GitHub"), destination: GlassEQLinks.autoEq)
                    .font(.callout)
                Text(verbatim: LegalNotices.autoEqCopyright)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(verbatim: LegalNotices.mitLicenseText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }
}

private struct AboutParagraph: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct AboutGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.macOSControlBackground, in: .rect(cornerRadius: 12))
    }
}

struct LicenseTextSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                Text(verbatim: LegalNotices.gplText() ?? localized("The license text is missing from this build."))
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
