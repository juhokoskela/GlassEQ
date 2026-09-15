import GlassEQCore
import GlassEQSettingsIPC
import SwiftUI

struct ProfileDetail: View {
    @Bindable var controller: SettingsController

    var body: some View {
        let isReadOnly = controller.isEditingLocked
        VStack(alignment: .leading, spacing: 16) {
            if controller.isProfileStoreProtected {
                constrainedContent {
                    ProfileStoreProtectionBanner(
                        protection: controller.snapshot.profileStoreProtection,
                        onReset: controller.resetUnsupportedProfileStore
                    )
                }
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
                                .disabled(isReadOnly)
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
                .layoutPriority(2)
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle($controller.draftProfile.name)
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker(localized("Section"), selection: $controller.tab) {
                    ForEach(EditorSection.allCases) { section in
                        Text(section.title).tag(section)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityHint(Text(localized("Switches between editor and output details")))
            }
            ToolbarItem {
                Button(localized("Import"), systemImage: "square.and.arrow.down") {
                    controller.presentImport(.text)
                }
                .disabled(isReadOnly)
                .accessibilityHint(Text(localized("Opens guided profile import")))
            }
        }
    }

    private func constrainedContent<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            // Cap the editor column so controls (preamp row, chart) don't stretch on wide windows.
            .frame(maxWidth: 860, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    // The profile type plus where the selected profile is used right now, as opposed to the
    // draft's contents.
    private var subtitle: String {
        let snapshot = controller.snapshot
        let id = controller.draftProfile.id
        var parts = [controller.draftProfile.mode.title]
        if id == snapshot.activeProfileID {
            parts.append(snapshot.isRunning ? localized("Playing now") : localized("Active"))
        }
        if id == snapshot.currentOutputMappedProfileID {
            parts.append(localized("Assigned to \(snapshot.currentOutputName)"))
        }
        if id == snapshot.fallbackProfileID {
            parts.append(localized("Fallback"))
        }
        return parts.joined(separator: " · ")
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
