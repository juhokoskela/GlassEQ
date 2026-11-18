import GlassEQSettingsIPC
import SwiftUI

/// Shows what a chosen library contains and what adding it or replacing the current library
/// would do, then lets the user pick one or back out.
struct LibraryImportSheet: View {
    let preview: SettingsLibraryImportPreviewDTO
    let hasUnsavedDraft: Bool
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
                    warning: preview.mergeFailure
                )
                choice(
                    title: localized("Replace your library"),
                    detail: localized(
                        "Removes your current profiles and output assignments and restores these \(preview.profileCount) profiles instead. GlassEQ saves a copy of your current library first."
                    ),
                    warning: preview.replaceFailure
                        ?? (hasUnsavedDraft ? localized("Replace also discards your unapplied profile edits.") : nil)
                )
            }

            HStack {
                Button(localized("Cancel"), role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(localized("Replace"), role: .destructive, action: onReplace)
                    .disabled(preview.replaceFailure != nil)
                Button(localized("Add"), action: onMerge)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(preview.merge == nil)
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
        guard let merge = preview.merge else { return localized("Your current library will be kept.") }
        return [
            localized("New profiles: \(merge.addedProfiles)."),
            localized("Conflicting profiles added as copies: \(merge.copiedProfiles)."),
            localized("Existing profiles kept: \(merge.unchangedProfiles)."),
            localized("New output assignments: \(merge.addedMappings)."),
            localized("New fixed buffer choices: \(merge.addedBufferPreferences)."),
        ].joined(separator: " ")
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
