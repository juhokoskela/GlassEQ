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
        didSet {
            updateDirtyState()
            refreshAnalyses()
        }
    }
    var selectedProfileID: UUID
    var pendingSelection: UUID?
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
    private var storedProfile: EQProfile { didSet { updateDirtyState() } }
    private(set) var hasUnsavedDraft = false
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
        updateDirtyState()
    }

    var snapshot: SettingsSnapshot {
        model.snapshot
    }

    private func updateDirtyState() {
        let dirty = draftProfile != storedProfile
        if hasUnsavedDraft != dirty { hasUnsavedDraft = dirty }
    }

    var canAssignDraftToOutput: Bool {
        hasCurrentOutput && draftProfile.id != snapshot.currentOutputMappedProfileID
    }

    var canApplyDraft: Bool {
        !isProfileStoreProtected && !isStartingProgrammeComparison
            && (hasUnsavedDraft || draftProfile.id != snapshot.activeProfileID || !snapshot.activeProfileMatchesLibrary)
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

    var isDiscardSelectionPresented: Bool {
        get { pendingSelection != nil && !isImportSheetPresented && !isNewProfileSheetPresented }
        set { if !newValue { pendingSelection = nil } }
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

    func requestSelection(_ id: UUID) {
        guard !isComparisonInProgress else { return }
        tab = .editor
        guard selectedProfileID != id else { return }
        if hasUnsavedDraft {
            pendingSelection = id
        } else {
            selectProfile(id)
        }
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
        guard canApplyDraft else { return }
        perform(.applyProfile(draftProfile))
    }

    func revertDraft() {
        guard !isComparisonInProgress else { return }
        draftProfile = storedProfile
        draftEditGeneration &+= 1
    }

    func setEqualizerEnabled(_ enabled: Bool) {
        perform(.setEqualizerEnabled(enabled))
    }

    func useDraftForCurrentOutput() {
        if hasUnsavedDraft {
            perform(.useProfileForCurrentOutput(draftProfile, outputUID: snapshot.currentOutputUID))
        } else {
            assignProfileToCurrentOutput(draftProfile.id)
        }
    }

    func setOutputAssignment(outputUID: String, profileID: UUID?) {
        perform(.setOutputAssignment(outputUID: outputUID, profileID: profileID))
    }

    func setFallbackProfile(_ id: UUID) {
        guard id != snapshot.fallbackProfileID, !isEditingLocked else { return }
        perform(.setFallbackProfile(id))
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

    func playWithoutEQ() { perform(.playWithoutEQ) }

    func retryAudioEngine() {
        perform(.retryAudioEngine)
    }

    func openPrivacySettings() {
        perform(.openPrivacySettings)
    }

    func showAbout() { perform(.showAbout) }

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
        setOutputAssignment(outputUID: snapshot.currentOutputUID, profileID: id)
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

    private func takeCommandError() -> String? {
        defer { model.commandErrorMessage = nil }
        return model.commandErrorMessage
    }

    func importProfile(format: ImportFormat, name: String, text: String) async -> String? {
        let response = await dispatch(.importProfile(format: format, name: name, text: text))
        guard response?.importSucceeded == true else {
            return takeCommandError() ?? localized("GlassEQ could not import this profile.")
        }
        return nil
    }

    func importParsedProfile(_ profile: EQProfile) async -> String? {
        let response = await dispatch(.importParsedProfile(profile))
        guard response?.importSucceeded == true else {
            return takeCommandError() ?? localized("GlassEQ could not import this profile.")
        }
        return nil
    }

    // MARK: Library backup

    var libraryImportPreview: SettingsLibraryImportPreviewDTO?
    var libraryMessage: String?
    private(set) var isLibraryTransferInProgress = false

    func exportLibrary() {
        runLibraryTransfer { [self] in
            let response = await model.perform(.exportLibrary)
            libraryMessage = response?.libraryMessage
        }
    }

    func chooseLibraryBackup() {
        runLibraryTransfer { [self] in
            libraryMessage = nil
            let response = await model.perform(.chooseLibraryBackup)
            libraryImportPreview = response?.libraryImportPreview
        }
    }

    func applyLibraryImport(_ mode: SettingsLibraryImportMode) {
        libraryImportPreview = nil
        runLibraryTransfer { [self] in
            let response = await dispatch(.applyLibraryImport(mode))
            libraryMessage = response?.libraryMessage
        }
    }

    func cancelLibraryImport() {
        guard libraryImportPreview != nil else {
            return
        }
        libraryImportPreview = nil
        perform(.cancelLibraryImport)
    }

    private func runLibraryTransfer(_ operation: @escaping @MainActor () async -> Void) {
        guard !isLibraryTransferInProgress else {
            return
        }
        isLibraryTransferInProgress = true
        Task { @MainActor in
            defer {
                isLibraryTransferInProgress = false
            }
            await operation()
        }
    }

    func showLibraryBackups() { perform(.showLibraryBackups) }

    func chooseImportFiles(_ mode: SettingsFileImportMode) async -> SettingsFileImportChoice {
        let response = await model.chooseImportFiles(mode: mode)
        return SettingsFileImportChoice(
            selection: response?.fileImportSelection,
            errorMessage: response == nil ? takeCommandError() : nil
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
        guard let response else {
            return nil
        }
        guard selectedProfileID == dispatchedSelection, draftProfile == dispatchedDraft else {
            reconcileWithSnapshot()
            return response
        }
        switch command {
        case .createProfile, .duplicateProfile, .importProfile, .importParsedProfile:
            reconcileWithSnapshot()
            if pendingSelection == nil { requestSelection(snapshot.selectedProfileID) }
        case .deleteProfile(let id) where id != dispatchedSelection:
            reconcileWithSnapshot()
        case .deleteProfile, .applyProfile, .useProfileForCurrentOutput,
            .resetUnsupportedProfileStore, .applyLibraryImport(.replace):
            adoptSnapshotSelection()
        default:
            break
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
