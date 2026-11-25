import GlassEQCore
import SwiftUI

struct ProfileSidebar: View {
    @Bindable var controller: SettingsController

    var body: some View {
        let isReadOnly = controller.isEditingLocked
        let selectedProfileID = controller.selectedProfileID
        let canDeleteSelectedProfile = controller.canDeleteProfile(selectedProfileID)
        List(selection: selection) {
            Section(localized("Profiles")) {
                ForEach(controller.snapshot.profiles) { profile in
                    ProfileRow(
                        profile: profile,
                        isSelected: profile.id == selectedProfileID,
                        isActive: profile.id == controller.snapshot.activeProfileID
                    )
                    .tag(profile.id)
                    .contextMenu {
                        Button(localized("Duplicate Saved Profile")) {
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
            }
        }
        .alert(
            localized("Discard unapplied changes?"),
            isPresented: $controller.isDiscardSelectionPresented, presenting: controller.pendingSelection
        ) { id in
            Button(localized("Keep Editing"), role: .cancel) {}
            Button(localized("Discard Changes"), role: .destructive) { controller.selectProfile(id) }
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
                .help(localized("Duplicate Saved Profile"))
                .disabled(isReadOnly)
                .accessibilityLabel(Text(localized("Duplicate Saved Profile")))
                .accessibilityHint(Text(localized("Copies the saved version of the selected profile")))

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
                if let id { controller.requestSelection(id) }
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
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text(localized("Active profile")))
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
        return parts.joined(separator: " · ")
    }
}
