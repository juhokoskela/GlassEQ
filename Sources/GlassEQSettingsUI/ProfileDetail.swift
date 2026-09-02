import GlassEQCore
import GlassEQSettingsIPC
import SwiftUI

struct ProfileDetail: View {
    @Bindable var controller: SettingsController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            constrainedContent {
                ProfileHeader(controller: controller)
            }

            if controller.isProfileStoreProtected {
                constrainedContent {
                    ProfileStoreProtectionBanner(
                        protection: controller.snapshot.profileStoreProtection,
                        onReset: controller.resetUnsupportedProfileStore
                    )
                }
                .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView {
                constrainedContent {
                    Group {
                        switch controller.tab {
                        case .editor:
                            if controller.snapshot.profiles.allSatisfy(\.isNeutral) {
                                StartingPointHint(
                                    onImport: { controller.presentImport(.text) },
                                    onCreate: { controller.isNewProfileSheetPresented = true }
                                )
                                .padding(.bottom, 12)
                            }
                            EditorTab(controller: controller)
                                .disabled(controller.isEditingLocked)
                        case .output:
                            OutputTab(controller: controller)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    // Breathing room so the last editor panel scrolls clear of the footer
                    // instead of being cut against it.
                    .padding(.bottom, 24)
                }
            }
            .scrollIndicators(.visible)
            .frame(minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
            .layoutPriority(1)

            if controller.tab == .editor {
                constrainedContent {
                    ApplyBar(controller: controller)
                        .cardPanel(padding: 16)
                }
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(2)
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 18)
        .padding(.top, settingsTitlebarInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func constrainedContent<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            // Cap the editor column so controls (preamp row, chart) don't stretch on wide windows.
            .frame(maxWidth: 860, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

struct ProfileHeader: View {
    @Bindable var controller: SettingsController
    @State private var isRenaming = false

    var body: some View {
        let isReadOnly = controller.isEditingLocked
        let mode = controller.draftProfile.mode
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                if isRenaming {
                    HStack(spacing: 8) {
                        TextField(localized("Profile name"), text: $controller.draftProfile.name)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 280)
                            .disabled(isReadOnly)
                            .accessibilityLabel(Text(localized("Profile name")))
                        Button(localized("Done")) {
                            isRenaming = false
                        }
                        .controlSize(.large)
                    }
                } else {
                    HStack(spacing: 6) {
                        Text(controller.draftProfile.name)
                            .font(.title2.weight(.semibold))
                            .lineLimit(1)
                        Button {
                            isRenaming = true
                        } label: {
                            IconButtonLabel(systemImage: "pencil")
                        }
                        .buttonStyle(.borderless)
                        .disabled(isReadOnly)
                        .help(localized("Rename profile"))
                        .accessibilityLabel(Text(localized("Rename profile")))
                        .accessibilityHint(Text(localized("Edits the selected profile name")))
                    }
                }

                HStack(spacing: 8) {
                    Label(mode.title, systemImage: mode.symbol)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(statusChips, id: \.title) { chip in
                        Text(chip.title)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(chip.color)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(chip.color.opacity(0.12), in: .capsule)
                    }
                }
                .lineLimit(1)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text(localized("Profile summary")))
                .accessibilityValue(Text(([mode.title] + statusChips.map(\.title)).joined(separator: ", ")))
            }

            Spacer()

            Button {
                controller.presentImport(.text)
            } label: {
                Label(localized("Import"), systemImage: "square.and.arrow.down")
            }
            .controlSize(.large)
            .disabled(isReadOnly)
            .accessibilityHint(Text(localized("Opens guided profile import")))

            Picker(localized("Section"), selection: $controller.tab) {
                ForEach(EditorSection.allCases) { section in
                    Text(section.title).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 230)
            .accessibilityLabel(Text(localized("Section")))
            .accessibilityValue(Text(controller.tab.title))
            .accessibilityHint(Text(localized("Switches between editor and output details")))
        }
        .cardPanel(padding: 16)
    }

    private struct StatusChip {
        var title: String
        var color: Color
    }

    // Describes where the selected profile is used right now, as opposed to the draft's contents.
    private var statusChips: [StatusChip] {
        let snapshot = controller.snapshot
        var chips: [StatusChip] = []
        let id = controller.draftProfile.id
        if id == snapshot.activeProfileID {
            chips.append(StatusChip(
                title: snapshot.isRunning ? localized("Playing now") : localized("Active"),
                color: snapshot.isRunning ? Color(nsColor: .systemGreen) : .secondary
            ))
        }
        if id == snapshot.currentOutputMappedProfileID {
            chips.append(StatusChip(
                title: localized("Assigned to \(snapshot.currentOutputName)"),
                color: .accentColor
            ))
        }
        if id == snapshot.fallbackProfileID {
            chips.append(StatusChip(title: localized("Fallback"), color: .secondary))
        }
        return chips
    }
}

// Shown while every profile in the library is still flat, so a new install has a next step.
struct StartingPointHint: View {
    var onImport: () -> Void
    var onCreate: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "headphones")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .frame(width: 36, height: 36)
                .background(Color.accentColor.opacity(0.12), in: .rect(cornerRadius: 10))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(localized("Start with a profile for your headphones"))
                    .font(.headline)
                Text(localized("Every profile here is still flat, so GlassEQ is not changing the sound yet. Search AutoEq for your headphone model and import a ready correction, or build one by hand."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button {
                        onImport()
                    } label: {
                        Label(localized("Search AutoEq"), systemImage: "magnifyingglass")
                    }
                    .buttonStyle(.borderedProminent)
                    Button(localized("New Profile")) {
                        onCreate()
                    }
                }
                .controlSize(.large)
                .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .cardPanel(padding: 16)
    }
}

struct ProfileStoreProtectionBanner: View {
    var protection: SettingsProfileStoreProtectionDTO
    var onReset: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "lock.fill")
                .foregroundStyle(Color.orange)
                .accessibilityHidden(true)
            Text(protection.message)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(role: .destructive) {
                onReset()
            } label: {
                ActionButtonLabel(title: protection.resetButtonTitle, systemImage: "arrow.counterclockwise")
            }
            .controlSize(.large)
            .accessibilityLabel(Text(protection.resetButtonTitle))
        }
        .cardPanel(padding: 14)
    }
}
