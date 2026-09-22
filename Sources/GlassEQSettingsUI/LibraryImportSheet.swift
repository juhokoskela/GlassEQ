import GlassEQSettingsIPC
import SwiftUI

/// Shows what a chosen library contains and what adding it or replacing the current library
/// would do, then lets the user pick one or back out.
struct LibraryImportSheet: View {
    let preview: SettingsLibraryImportPreviewDTO
    let onMerge: () -> Void
    let onReplace: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(localized("Import Library"))
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(preview.filename)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(savedLine)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 12) {
                choice(
                    title: localized("Add to your library"),
                    detail: mergeDetail,
                    warning: preview.mergeExceedsProfileLimit
                        ? localized(
                            "Adding these would exceed the limit of 64 profiles. Delete some first, or replace the library."
                        )
                        : nil
                )
                choice(
                    title: localized("Replace your library"),
                    detail: localized(
                        "Removes your current profiles and output assignments and restores these \(preview.profileCount) profiles instead. GlassEQ saves a copy of your current library first."
                    ),
                    warning: nil
                )
            }

            HStack {
                Button(localized("Cancel"), role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(localized("Replace…"), role: .destructive, action: onReplace)
                Button(localized("Add"), action: onMerge)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(preview.mergeExceedsProfileLimit)
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 520)
    }

    private var savedLine: String {
        let date = preview.createdAt.formatted(date: .abbreviated, time: .shortened)
        var line = localized("Saved \(date)")
        if let appVersion = preview.appVersion {
            line += localized(" by GlassEQ \(appVersion)")
        }
        line += localized(". \(preview.profileCount) profiles, \(preview.outputMappingCount) output assignments")
        if preview.hasBufferPreferences {
            line += localized(", buffer preferences")
        }
        return line + "."
    }

    private var mergeDetail: String {
        var parts: [String] = []
        if preview.mergeAddedProfiles > 0 {
            parts.append(localized("adds \(preview.mergeAddedProfiles) new profiles"))
        }
        if preview.mergeCopiedProfiles > 0 {
            parts.append(
                localized(
                    "adds \(preview.mergeCopiedProfiles) as copies because a profile with the same identity here differs"
                ))
        }
        if preview.mergeUnchangedProfiles > 0 {
            parts.append(localized("skips \(preview.mergeUnchangedProfiles) already here"))
        }
        if preview.mergeAddedMappings > 0 {
            parts.append(localized("assigns \(preview.mergeAddedMappings) outputs that have no profile yet"))
        }
        guard !parts.isEmpty else {
            return localized("Every profile in this file is already in your library. Nothing would change.")
        }
        var detail = parts.joined(separator: ", ")
        detail = detail.prefix(1).uppercased() + detail.dropFirst()
        return detail + localized(". Nothing you have is changed.")
    }

    private func choice(title: String, detail: String, warning: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
            Text(detail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let warning {
                Text(warning)
                    .foregroundStyle(Color.macOSSystemOrange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.callout)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.macOSControlBackground, in: .rect(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}
