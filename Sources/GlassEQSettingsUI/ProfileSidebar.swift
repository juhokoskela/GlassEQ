import GlassEQCore
import SwiftUI

struct ProfileSidebar: View {
    var controller: SettingsController

    var body: some View {
        let isReadOnly = controller.isEditingLocked
        let selectedProfileID = controller.selectedProfileID
        let canDeleteSelectedProfile = controller.canDeleteProfile(selectedProfileID)
        List(controller.snapshot.profiles, selection: selection) { profile in
            ProfileRow(
                profile: profile,
                isSelected: profile.id == selectedProfileID,
                isActive: profile.id == controller.snapshot.activeProfileID
            )
            .contextMenu {
                Button(localized("Duplicate")) {
                    controller.duplicateProfile(profile.id)
                }
                .disabled(isReadOnly)
                Button(localized("Use for This Output")) {
                    controller.assignProfileToCurrentOutput(profile.id)
                }
                .disabled(isReadOnly || !controller.hasCurrentOutput)
                Divider()
                Button(localized("Delete…"), role: .destructive) {
                    controller.requestProfileDeletion(profile.id)
                }
                .disabled(!controller.canDeleteProfile(profile.id))
            }
        }
        .listStyle(.sidebar)
        .disabled(controller.isComparisonInProgress)
        // Removing the toggle after the column width modifier drops the width back to a system
        // minimum, so the order here matters.
        .toolbar(removing: .sidebarToggle)
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 4) {
                Button(localized("New Profile"), systemImage: "plus") {
                    controller.isNewProfileSheetPresented = true
                }
                .disabled(isReadOnly)
                .accessibilityHint(Text(localized("Chooses a profile type or import source")))

                Spacer()

                Button {
                    controller.duplicateProfile(selectedProfileID)
                } label: {
                    IconButtonLabel(systemImage: "plus.square.on.square")
                }
                .buttonStyle(.borderless)
                .help(localized("Duplicate profile"))
                .disabled(isReadOnly)
                .accessibilityLabel(Text(localized("Duplicate profile")))
                .accessibilityHint(Text(localized("Copies the selected profile")))

                Button(role: .destructive) {
                    controller.requestProfileDeletion(selectedProfileID)
                } label: {
                    IconButtonLabel(systemImage: "trash")
                }
                .buttonStyle(.borderless)
                .help(
                    canDeleteSelectedProfile
                        ? localized("Delete profile")
                        : localized("Switch away from the active profile before deleting it")
                )
                .disabled(!canDeleteSelectedProfile)
                .accessibilityLabel(Text(localized("Delete profile")))
                .accessibilityHint(
                    Text(
                        canDeleteSelectedProfile
                            ? localized("Deletes the selected profile")
                            : localized("Switch away from the active profile before deleting it")))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .overlay(alignment: .top) {
                Divider()
            }
        }
    }

    // The list needs an optional selection, but the controller always has a selected profile.
    private var selection: Binding<UUID?> {
        Binding(
            get: { controller.selectedProfileID },
            set: { id in
                if let id {
                    controller.selectProfile(id)
                }
            }
        )
    }
}

private struct ProfileRow: View {
    var profile: EQProfile
    var isSelected: Bool
    var isActive: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: profile.mode.symbol)
                .frame(width: 20)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(profile.name)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if isActive {
                Image(systemName: profile.isBypassed ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text(profile.isBypassed ? localized("Active, bypassed") : localized("Active")))
            }
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        var parts = [profile.mode.title]
        switch profile.mode {
        case .parametric:
            let count =
                profile.channelMode == .stereo
                ? max(profile.leftFilters.count, profile.rightFilters.count)
                : profile.filters.count
            parts.append(count == 1 ? localized("1 filter") : localized("\(count) filters"))
        case .graphic10, .graphic31:
            break
        case .convolution:
            switch profile.channelMode == .stereo ? profile.leftConvolution : profile.convolution {
            case .magnitudeCurve(let curve):
                parts.append(curve.points.count == 1 ? localized("1 point") : localized("\(curve.points.count) points"))
            case .impulseResponse:
                parts.append(localized("impulse response"))
            case nil:
                break
            }
        }
        if profile.channelMode == .stereo {
            parts.append(localized("L/R"))
        }
        if profile.isBypassed {
            parts.append(localized("bypassed"))
        }
        return parts.joined(separator: " · ")
    }
}
