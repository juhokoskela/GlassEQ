import GlassEQCore
import SwiftUI

private let sidebarCardInset: CGFloat = 6
private let sidebarCardCornerRadius: CGFloat = 14

struct ProfileSidebar: View {
    var controller: SettingsController

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var selectionNamespace

    var body: some View {
        let selectedProfileID = controller.selectedProfileID
        let isReadOnly = controller.isEditingLocked
        let canDeleteSelectedProfile = controller.canDeleteProfile(selectedProfileID)
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(controller.snapshot.profiles) { profile in
                        row(for: profile)
                    }
                }
                .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: selectedProfileID)
                // Align the row text (which sits 10pt inside the selection capsule) with the
                // sidebar's content leading.
                .padding(.horizontal, sidebarContentLeading - sidebarCardInset - 10)
                // No header now: inset the first row below the window controls, aligning it with
                // the content header on the right.
                .padding(.top, settingsTitlebarInset - sidebarCardInset)
                .padding(.bottom, 10)
            }

            Divider()

            HStack(spacing: 4) {
                Button {
                    controller.isNewProfileSheetPresented = true
                } label: {
                    ActionButtonLabel(title: localized("New Profile"), systemImage: "plus")
                }
                .controlSize(.large)
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
                .help(canDeleteSelectedProfile ? localized("Delete profile") : localized("Switch away from the active profile before deleting it"))
                .disabled(!canDeleteSelectedProfile)
                .opacity(canDeleteSelectedProfile ? 1 : 0.35)
                .accessibilityLabel(Text(localized("Delete profile")))
                .accessibilityValue(Text(canDeleteSelectedProfile ? localized("Available") : localized("Unavailable for active profile")))
                .accessibilityHint(Text(canDeleteSelectedProfile ? localized("Deletes the selected profile") : localized("Switch away from the active profile before deleting it")))
            }
            .padding(.horizontal, sidebarContentLeading - sidebarCardInset)
            .padding(.vertical, 14)
        }
        .card(fill: .regularMaterial, cornerRadius: sidebarCardCornerRadius)
        .clipShape(RoundedRectangle(cornerRadius: sidebarCardCornerRadius, style: .continuous))
        .shadow(color: .black.opacity(0.16), radius: 4, x: 0, y: 1)
        // Small, even buffer on all sides. Kept small so the window controls still land on the
        // card (with .hiddenTitleBar, macOS parks them near the top) rather than in the margin.
        .padding(sidebarCardInset)
    }

    private func row(for profile: EQProfile) -> some View {
        let isSelected = profile.id == controller.selectedProfileID
        let isActive = profile.id == controller.snapshot.activeProfileID
        let secondary = isSelected ? Color.white.opacity(0.78) : Color.secondary
        return Button {
            controller.selectProfile(profile.id)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: profile.mode.symbol)
                    .font(.body)
                    .frame(width: 20)
                    .foregroundStyle(secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(profile.name)
                        .lineLimit(1)
                    Text(profileSubtitle(profile))
                        .font(.caption)
                        .foregroundStyle(secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                if isActive {
                    Image(systemName: profile.isBypassed ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.caption)
                        .foregroundStyle(secondary)
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.accentColor)
                        .matchedGeometryEffect(id: "selection", in: selectionNamespace)
                }
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            Button(localized("Duplicate")) {
                controller.duplicateProfile(profile.id)
            }
            .disabled(controller.isEditingLocked)
            Button(localized("Use for This Output")) {
                controller.assignProfileToCurrentOutput(profile.id)
            }
            .disabled(controller.isEditingLocked || !controller.hasCurrentOutput)
            Divider()
            Button(localized("Delete…"), role: .destructive) {
                controller.requestProfileDeletion(profile.id)
            }
            .disabled(!controller.canDeleteProfile(profile.id))
        }
        .accessibilityLabel(Text(profile.name))
        .accessibilityValue(Text(profileAccessibilityValue(profile, isSelected: isSelected, isActive: isActive)))
        .accessibilityHint(Text(localized("Selects this profile for editing")))
    }

    private func profileSubtitle(_ profile: EQProfile) -> String {
        var parts = [profile.mode.title]
        switch profile.mode {
        case .parametric:
            let count = profile.channelMode == .stereo
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

    private func profileAccessibilityValue(_ profile: EQProfile, isSelected: Bool, isActive: Bool) -> String {
        var values = [profileSubtitle(profile)]
        if isSelected {
            values.append(localized("Selected"))
        }
        if isActive {
            values.append(profile.isBypassed ? localized("Active, bypassed") : localized("Active"))
        }
        return values.joined(separator: ", ")
    }
}
