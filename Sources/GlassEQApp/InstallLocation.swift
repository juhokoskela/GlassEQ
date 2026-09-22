import Foundation

/// Places an app bundle can run from where an update cannot replace it in place.
enum InstallLocationIssue: Equatable {
    /// A read-only volume, in practice the mounted disk image.
    case readOnlyVolume
    /// macOS copied a quarantined bundle to a random read-only location before launching it.
    case translocated

    var message: String {
        switch self {
        case .readOnlyVolume:
            localized(
                "GlassEQ is running from the disk image. Drag it to Applications and open it from there, or updates cannot install."
            )
        case .translocated:
            localized(
                "GlassEQ is running from a temporary copy macOS made. Move GlassEQ.app to Applications and open it again, or updates cannot install."
            )
        }
    }

    var reportDescription: String {
        switch self {
        case .readOnlyVolume:
            "read-only volume (disk image)"
        case .translocated:
            "translocated by Gatekeeper"
        }
    }
}

enum InstallLocation {
    static func issue(
        bundleURL: URL = Bundle.main.bundleURL,
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
        return nil
    }
}
