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
    var draftProfile: EQProfile {
        didSet { refreshAnalyses() }
    }
    var selectedProfileID: UUID
    var tab = EditorSection.editor
    var editChannel = EQEditChannel.left
    var isImportSheetPresented = false
    var importRoute = ProfileImportRoute.text
    var isNewProfileSheetPresented = false
    var profilePendingDeletion: EQProfile?
    private(set) var draftEditGeneration = 0
    private(set) var comparisonStartTask: Task<Void, Never>?

    // The stored copy of the selected profile as of the last reconciled snapshot. Comparing the
    // draft against it separates local edits from stored changes that arrived from the app.
    private var storedProfile: EQProfile
    private var pendingNewProfileImportRoute: ProfileImportRoute?

    let analysisCache = EQAnalysisCache()
    @ObservationIgnored private var isAnalysisActive = false

    init(model: GlassEQSettingsViewModel) {
        self.model = model
        let snapshot = model.snapshot
        draftProfile = snapshot.draftProfile
        selectedProfileID = snapshot.selectedProfileID
        storedProfile =
            snapshot.profiles.first(where: { $0.id == snapshot.selectedProfileID })
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
        isProfileStoreProtected || isComparisonInProgress
    }

    var isStartingProgrammeComparison: Bool {
        comparisonStartTask != nil
    }

    var isComparisonInProgress: Bool {
        isStartingProgrammeComparison || snapshot.programmeComparison.isActive
    }

    var draftName: String {
        get { draftProfile.name }
        set {
            guard !isEditingLocked else { return }
            draftProfile.name = newValue
        }
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
            guard !isEditingLocked, newValue != draftProfile.channelMode else {
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
        !isStartingProgrammeComparison && settingsCanDeleteProfile(snapshot, id: id)
    }

    func selectProfile(_ id: UUID) {
        guard !isComparisonInProgress,
            let profile = snapshot.profiles.first(where: { $0.id == id })
        else {
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
        guard !isStartingProgrammeComparison else { return }
        perform(.applyProfile(draftProfile))
    }

    func revertDraft() {
        guard !isComparisonInProgress else { return }
        draftProfile = storedProfile
        draftEditGeneration &+= 1
    }

    func useDraftForCurrentOutput() {
        perform(.useProfileForCurrentOutput(draftProfile))
    }

    func setFallbackToDraft() {
        perform(.setFallback(draftProfile))
    }

    func startProgrammeComparison() {
        guard !isEditingLocked else { return }
        let draft = draftProfile
        comparisonStartTask = Task { @MainActor in
            defer { comparisonStartTask = nil }
            await dispatch(.startProgrammeComparison(draft))
        }
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

    func presentImport(_ route: ProfileImportRoute) {
        importRoute = route
        isImportSheetPresented = true
    }

    func requestImportFromNewProfileSheet(_ route: ProfileImportRoute) {
        pendingNewProfileImportRoute = route
    }

    func newProfileSheetDidDismiss() {
        guard let route = pendingNewProfileImportRoute else {
            return
        }
        pendingNewProfileImportRoute = nil
        presentImport(route)
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

    func startAnalyses() {
        isAnalysisActive = true
        refreshAnalyses()
    }

    func stopAnalyses() {
        isAnalysisActive = false
        analysisCache.stop()
    }

    func refreshAnalyses() {
        guard isAnalysisActive else { return }
        analysisCache.update(profiles: snapshot.profiles, selected: draftProfile, sampleRate: analysisSampleRate)
    }

    // Preserve local selection and edits when a delayed snapshot arrives.
    func reconcileWithSnapshot() {
        let latest = snapshot
        guard let latestStored = latest.profiles.first(where: { $0.id == selectedProfileID }) else {
            adoptSnapshotSelection()
            return
        }
        if !hasUnsavedDraft {
            draftProfile = latestStored
        } else {
            refreshAnalyses()
        }
        storedProfile = latestStored
    }

    private func adoptSnapshotSelection() {
        let latest = snapshot
        selectedProfileID = latest.selectedProfileID
        draftProfile = latest.draftProfile
        storedProfile =
            latest.profiles.first(where: { $0.id == latest.selectedProfileID })
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
        switch command {
        case .createProfile, .duplicateProfile, .deleteProfile,
            .applyProfile, .useProfileForCurrentOutput, .setFallback,
            .importProfile, .importParsedProfile, .resetUnsupportedProfileStore:
            reconcileAfterCommand(
                dispatchedSelection: dispatchedSelection,
                dispatchedDraft: dispatchedDraft
            )
        default:
            reconcileWithSnapshot()
        }
        return response
    }
}

func settingsCanDeleteProfile(_ snapshot: SettingsSnapshot, id: UUID) -> Bool {
    !snapshot.profileStoreProtection.isProtected
        && snapshot.profiles.count > 1
        && !snapshot.programmeComparison.isActive
        && id != snapshot.activeProfileID
}
