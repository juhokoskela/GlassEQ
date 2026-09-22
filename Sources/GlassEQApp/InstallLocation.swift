import Foundation
import SwiftUI

/// Places an app bundle can run from where an update cannot replace it in place.
enum InstallLocationIssue: Equatable {
    /// A read-only volume, in practice the mounted disk image.
    case readOnlyVolume
    /// macOS copied a quarantined bundle to a random read-only location before launching it.
    case translocated
    /// Still in the Downloads folder.
    case downloads

    var reportDescription: String {
        switch self {
        case .readOnlyVolume:
            "read-only volume (disk image)"
        case .translocated:
            "translocated by Gatekeeper"
        case .downloads:
            "Downloads folder"
        }
    }
}

enum InstallLocation {
    static func issue(
        bundleURL: URL = Bundle.main.bundleURL,
        downloadsDirectory: URL? = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first,
        isVolumeReadOnly: (URL) -> Bool = { url in
            (try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) == true
        }
    ) -> InstallLocationIssue? {
        guard bundleURL.pathExtension == "app" else {
            return nil
        }
        if bundleURL.pathComponents.contains("AppTranslocation") {
            return .translocated
        }
        if isVolumeReadOnly(bundleURL) {
            return .readOnlyVolume
        }
        if let downloadsDirectory,
            bundleURL.deletingLastPathComponent().standardizedFileURL.path
                == downloadsDirectory.standardizedFileURL.path
        {
            return .downloads
        }
        return nil
    }
}

/// Shown in the menu bar popover while GlassEQ runs from somewhere an update cannot install.
struct InstallLocationNotice: View {
    let issue: InstallLocationIssue
    let dismissNotice: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "arrow.down.app")
                .foregroundStyle(Color.macOSSystemOrange)
                .accessibilityHidden(true)
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: dismissNotice) {
                Image(systemName: "xmark")
                    .frame(width: 20, height: 20)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text(localized("Dismiss")))
        }
        .font(.caption)
        .padding(10)
        .background(Color.macOSSystemOrange.opacity(0.12), in: .rect(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(localized("GlassEQ is not installed in Applications")))
    }

    private var message: String {
        switch issue {
        case .readOnlyVolume:
            localized(
                "GlassEQ is running from the disk image. Drag it to Applications and open it from there, or updates cannot install."
            )
        case .translocated:
            localized(
                "GlassEQ is running from a temporary copy macOS made. Move GlassEQ.app to Applications and open it again, or updates cannot install."
            )
        case .downloads:
            localized("GlassEQ is running from Downloads. Move it to Applications, or updates cannot install.")
        }
    }
}
