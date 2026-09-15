import AppKit
import GlassEQSettingsIPC
import SwiftUI

public struct SettingsView: View {
    @State private var controller: SettingsController

    public init(model: GlassEQSettingsViewModel) {
        _controller = State(initialValue: SettingsController(model: model))
    }

    public var body: some View {
        @Bindable var controller = controller
        NavigationSplitView {
            ProfileSidebar(controller: controller)
                .sheet(isPresented: $controller.isNewProfileSheetPresented, onDismiss: controller.newProfileSheetDidDismiss) {
                    NewProfileSheet(
                        onCreate: controller.createProfile,
                        onImport: controller.requestImportFromNewProfileSheet
                    )
                }
                .confirmationDialog(
                    controller.profilePendingDeletion.map { localized("Delete \"\($0.name)\"?") } ?? "",
                    isPresented: $controller.isDeletionConfirmationPresented,
                    titleVisibility: .visible,
                    presenting: controller.profilePendingDeletion
                ) { profile in
                    Button(localized("Delete"), role: .destructive) {
                        controller.deleteProfile(profile.id)
                    }
                } message: { _ in
                    Text(localized("This also removes any output assignment that uses the profile. It can't be undone."))
                }
        } detail: {
            ProfileDetail(controller: controller)
        }
        .background {
            SettingsWindowFocusBridge()
        }
        .sheet(isPresented: $controller.isImportSheetPresented) {
            ProfileImportSheet(
                route: $controller.importRoute,
                currentProfile: controller.draftProfile,
                isReadOnly: controller.isProfileStoreProtected,
                onImport: controller.importProfile,
                onImportParsedProfile: controller.importParsedProfile,
                onChooseImportFiles: controller.chooseImportFiles
            )
        }
        .overlay(alignment: .bottom) {
            if let message = controller.model.commandErrorMessage {
                Text(message)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.macOSSystemRed)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 8))
                    .padding()
            }
        }
        .onChange(of: controller.model.profileSnapshotRevision) {
            controller.reconcileWithSnapshot()
        }
        .onAppear {
            if let requestedSection = SettingsWindowFocus.consumePendingSection() {
                controller.show(requestedSection)
            }
            controller.reconcileWithSnapshot()
            controller.updateMetricsPolling()
        }
        .onDisappear {
            controller.stopMetricsPolling()
        }
        .onChange(of: controller.tab) {
            controller.updateMetricsPolling()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .glassEQBringSettingsToFront)
        ) { notification in
            if let requestedSection = notification.object as? SettingsSection {
                controller.show(requestedSection)
                _ = SettingsWindowFocus.consumePendingSection()
            }
        }
    }
}
