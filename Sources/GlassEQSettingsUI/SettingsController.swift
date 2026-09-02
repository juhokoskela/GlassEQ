import Foundation
@_spi(GlassEQSettingsUI) import GlassEQCore
import GlassEQSettingsIPC
import Observation

typealias SettingsSnapshot = SettingsSnapshotDTO
typealias ImportFormat = SettingsImportFormat

enum EditorSection: String, CaseIterable, Identifiable {
    case editor
    case output

    var id: String { rawValue }

    var title: String {
        switch self {
        case .editor:
            localized("Editor")
        case .output:
            localized("Output")
        }
    }
}

struct EditorContextID: Hashable {
    var profileID: UUID
    var channel: EQProfileChannel
    var generation: Int
}

// Owns the editable draft on the Settings side. Everything else the views show is read from the
// model's snapshot; the controller only reconciles the local selection and draft when a new
// snapshot arrives.
@MainActor
@Observable
final class SettingsController {
    let model: GlassEQSettingsViewModel
    var draftProfile: EQProfile
    var selectedProfileID: UUID
    var tab = EditorSection.editor
    var editChannel = EQEditChannel.left
    var isImportSheetPresented = false
    var isNewProfileSheetPresented = false
    var profilePendingDeletion: EQProfile?
    private(set) var draftEditGeneration = 0

    // The stored copy of the selected profile as of the last reconciled snapshot. Comparing the
    // draft against it separates local edits from stored changes that arrived from the app.
    private var storedProfile: EQProfile
    private var importRequestedFromNewProfileSheet = false

    init(model: GlassEQSettingsViewModel) {
        self.model = model
        let snapshot = model.snapshot
        draftProfile = snapshot.draftProfile
        selectedProfileID = snapshot.selectedProfileID
        storedProfile = snapshot.profiles.first(where: { $0.id == snapshot.selectedProfileID })
            ?? snapshot.draftProfile
    }

    var snapshot: SettingsSnapshot {
        model.snapshot
    }

    var hasUnsavedDraft: Bool {
        draftProfile != storedProfile
    }

    var isProfileStoreProtected: Bool {
        snapshot.profileStoreProtection.isProtected
    }

    var isEditingLocked: Bool {
        isProfileStoreProtected || snapshot.programmeComparison.isActive
    }

    var hasCurrentOutput: Bool {
        !snapshot.currentOutputUID.isEmpty
    }

    var analysisSampleRate: Double {
        snapshot.currentProcessingSampleRate > 0
            ? snapshot.currentProcessingSampleRate
            : snapshot.currentOutputSampleRate
    }

    var editedChannel: EQProfileChannel {
        guard draftProfile.channelMode == .stereo else {
            return .linked
        }
        return switch editChannel {
        case .left:
            .left
        case .right:
            .right
        }
    }

    var editorContextID: EditorContextID {
        EditorContextID(
            profileID: draftProfile.id,
            channel: editedChannel,
            generation: draftEditGeneration
        )
    }

    var draftChannelMode: EQChannelMode {
        get {
            draftProfile.channelMode
        }
        set {
            guard newValue != draftProfile.channelMode else {
                return
            }
            draftProfile = draftProfile.convertedToChannelMode(newValue, editedChannel: editChannel)
            if newValue == .stereo {
                editChannel = .left
            }
        }
    }

    var isDeletionConfirmationPresented: Bool {
        get {
            profilePendingDeletion != nil
        }
        set {
            if !newValue {
                profilePendingDeletion = nil
            }
        }
    }

    var programmeComparisonSelection: EQProgrammeComparisonSelection {
        get {
            snapshot.programmeComparison.selection
        }
        set {
            perform(.selectProgrammeComparison(newValue))
        }
    }

    var aggregateBufferMode: SettingsAggregateBufferMode {
        get {
            snapshot.aggregateBuffer.mode
        }
        set {
            setAggregateBufferMode(newValue)
        }
    }

    func canDeleteProfile(_ id: UUID) -> Bool {
        settingsCanDeleteProfile(snapshot, id: id)
    }

    func selectProfile(_ id: UUID) {
        guard let profile = snapshot.profiles.first(where: { $0.id == id }) else {
            return
        }
        selectedProfileID = id
        draftProfile = profile
        storedProfile = profile
    }

    func show(_ section: SettingsSection) {
        switch section {
        case .output:
            tab = .output
        }
    }

    func applyDraft() {
        perform(.applyProfile(draftProfile))
    }

    func revertDraft() {
        draftProfile = storedProfile
        draftEditGeneration &+= 1
    }

    func useDraftForCurrentOutput() {
        perform(.useProfileForCurrentOutput(draftProfile))
    }

    func setFallbackToDraft() {
        perform(.setFallback(draftProfile))
    }

    func previewDraft() {
        perform(.preview(draftProfile))
    }

    func stopPreview() {
        perform(.stopPreview)
    }

    func startProgrammeComparison() {
        perform(.startProgrammeComparison(draftProfile))
    }

    func stopProgrammeComparison() {
        perform(.stopProgrammeComparison)
    }

    func resetDiagnostics() {
        perform(.resetDiagnostics)
    }

    func setAggregateBufferMode(_ mode: SettingsAggregateBufferMode) {
        perform(.setAggregateBufferMode(mode))
    }

    func retryAutomaticAggregateBuffer() {
        perform(.retryAutomaticAggregateBuffer)
    }

    func retryAudioEngine() {
        perform(.retryAudioEngine)
    }

    func openPrivacySettings() {
        perform(.openPrivacySettings)
    }

    func showSetupGuide() {
        perform(.showSetupGuide)
    }

    func resetUnsupportedProfileStore() {
        perform(.resetUnsupportedProfileStore)
    }

    func createProfile(_ kind: SettingsProfileKind) {
        perform(.createProfile(kind))
    }

    func duplicateProfile(_ id: UUID) {
        perform(.duplicateProfile(id))
    }

    func requestProfileDeletion(_ id: UUID) {
        profilePendingDeletion = snapshot.profiles.first(where: { $0.id == id })
    }

    func deleteProfile(_ id: UUID) {
        perform(.deleteProfile(id))
    }

    func assignProfileToCurrentOutput(_ id: UUID) {
        guard let profile = snapshot.profiles.first(where: { $0.id == id }) else {
            return
        }
        perform(.useProfileForCurrentOutput(profile))
    }

    func requestImportFromNewProfileSheet() {
        importRequestedFromNewProfileSheet = true
    }

    func newProfileSheetDidDismiss() {
        guard importRequestedFromNewProfileSheet else {
            return
        }
        importRequestedFromNewProfileSheet = false
        isImportSheetPresented = true
    }

    func importProfile(format: ImportFormat, name: String, text: String) async -> String? {
        let response = await dispatch(.importProfile(format: format, name: name, text: text))
        guard response?.importSucceeded == true else {
            return model.commandErrorMessage ?? localized("GlassEQ could not import this profile.")
        }
        return nil
    }

    func importParsedProfile(_ profile: EQProfile) async -> String? {
        let response = await dispatch(.importParsedProfile(profile))
        guard response?.importSucceeded == true else {
            return model.commandErrorMessage ?? localized("GlassEQ could not import this profile.")
        }
        return nil
    }

    func chooseImportFiles(_ mode: SettingsFileImportMode) async -> SettingsFileImportChoice {
        let response = await model.chooseImportFiles(mode: mode)
        return SettingsFileImportChoice(
            selection: response?.fileImportSelection,
            errorMessage: response == nil ? model.commandErrorMessage : nil
        )
    }

    func updateMetricsPolling() {
        if tab == .output {
            perform(.startMetricsPolling)
        } else {
            stopMetricsPolling()
        }
    }

    func stopMetricsPolling() {
        perform(.stopMetricsPolling)
    }

    // Called whenever the model publishes a new snapshot. The local selection survives as long as
    // the profile still exists; the draft is refreshed from the store only when it has no local
    // edits, so a delayed snapshot cannot discard work the user did in the meantime.
    func reconcileWithSnapshot() {
        let latest = snapshot
        guard let latestStored = latest.profiles.first(where: { $0.id == selectedProfileID }) else {
            adoptSnapshotSelection()
            return
        }
        if !hasUnsavedDraft {
            draftProfile = latestStored
        }
        storedProfile = latestStored
    }

    private func adoptSnapshotSelection() {
        let latest = snapshot
        selectedProfileID = latest.selectedProfileID
        draftProfile = latest.draftProfile
        storedProfile = latest.profiles.first(where: { $0.id == latest.selectedProfileID })
            ?? latest.draftProfile
    }

    // A command the user dispatched may intentionally move the selection (create, duplicate,
    // delete). That is adopted unless the user changed the selection or draft while the command
    // was in flight, in which case the local state wins as with any other snapshot.
    private func reconcileAfterCommand(dispatchedSelection: UUID, dispatchedDraft: EQProfile) {
        guard selectedProfileID == dispatchedSelection, draftProfile == dispatchedDraft else {
            reconcileWithSnapshot()
            return
        }
        adoptSnapshotSelection()
    }

    private func perform(_ command: SettingsCommand) {
        Task { @MainActor in
            await dispatch(command)
        }
    }

    @discardableResult
    func dispatch(_ command: SettingsCommand) async -> SettingsCommandResponse? {
        let dispatchedSelection = selectedProfileID
        let dispatchedDraft = draftProfile
        let response = await model.perform(command)
        guard response?.snapshot != nil else {
            return response
        }
        reconcileAfterCommand(
            dispatchedSelection: dispatchedSelection,
            dispatchedDraft: dispatchedDraft
        )
        return response
    }
}

func settingsCanDeleteProfile(_ snapshot: SettingsSnapshot, id: UUID) -> Bool {
    !snapshot.profileStoreProtection.isProtected
        && snapshot.profiles.count > 1
        && !snapshot.isPreviewing
        && !snapshot.programmeComparison.isActive
        && id != snapshot.activeProfileID
}
