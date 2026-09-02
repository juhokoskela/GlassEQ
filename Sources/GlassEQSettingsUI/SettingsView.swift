import AppKit
@_spi(GlassEQSettingsUI) import GlassEQCore
import GlassEQSettingsIPC
import SwiftUI

typealias SettingsSnapshot = SettingsSnapshotDTO
typealias ImportFormat = SettingsImportFormat

private extension SettingsImportFormat {
    var title: String {
        switch self {
        case .autoEQ:
            localized("AutoEQ / EqualizerAPO")
        case .rew:
            localized("REW")
        }
    }
}

private let settingsResourcesBundle: Bundle = {
    let resourceBundleName = "GlassEQ_GlassEQSettingsUI.bundle"
    let candidates = [
        Bundle.main.resourceURL?.appendingPathComponent(resourceBundleName),
        Bundle.main.bundleURL.appendingPathComponent(resourceBundleName),
        Bundle.main.bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent(resourceBundleName)
    ].compactMap { $0 }

    for candidate in candidates {
        if let bundle = Bundle(url: candidate) {
            return bundle
        }
    }

    return Bundle.main
}()

func localized(_ value: String.LocalizationValue) -> String {
    String(localized: value, bundle: settingsResourcesBundle)
}

func localizedDecimal(
    _ value: Double,
    minimumFractionDigits: Int,
    maximumFractionDigits: Int,
    signed: Bool = false
) -> String {
    let formatter = NumberFormatter()
    formatter.locale = .autoupdatingCurrent
    formatter.numberStyle = .decimal
    formatter.minimumFractionDigits = minimumFractionDigits
    formatter.maximumFractionDigits = maximumFractionDigits
    if signed {
        formatter.positivePrefix = formatter.plusSign
    }
    return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
}

func editableNumberText(_ value: Double, locale: Locale = .autoupdatingCurrent) -> String {
    let formatter = NumberFormatter()
    formatter.locale = locale
    formatter.numberStyle = .decimal
    formatter.usesGroupingSeparator = false
    formatter.usesSignificantDigits = true
    formatter.minimumSignificantDigits = 1
    formatter.maximumSignificantDigits = 17
    return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
}

func parseEditableNumber(_ text: String, locale: Locale = .autoupdatingCurrent) -> Double? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        return nil
    }

    let formatter = NumberFormatter()
    formatter.locale = locale
    formatter.numberStyle = .decimal
    if let groupingSeparator = formatter.groupingSeparator,
       !groupingSeparator.isEmpty,
       groupingSeparator != formatter.decimalSeparator,
       trimmed.contains(groupingSeparator) {
        return nil
    }

    var normalized = trimmed
    if let decimalSeparator = formatter.decimalSeparator,
       decimalSeparator != "." {
        normalized = normalized.replacingOccurrences(of: decimalSeparator, with: ".")
    }
    if let minusSign = formatter.minusSign,
       minusSign != "-" {
        normalized = normalized.replacingOccurrences(of: minusSign, with: "-")
    }
    if let plusSign = formatter.plusSign,
       plusSign != "+" {
        normalized = normalized.replacingOccurrences(of: plusSign, with: "+")
    }
    var asciiNormalized = ""
    for scalar in normalized.unicodeScalars {
        if scalar.properties.numericType == .decimal,
           let numericValue = scalar.properties.numericValue,
           let asciiDigit = UnicodeScalar(Int(numericValue) + 48) {
            asciiNormalized.unicodeScalars.append(asciiDigit)
        } else {
            asciiNormalized.unicodeScalars.append(scalar)
        }
    }
    let parsed = Double(asciiNormalized)
    guard let parsed, parsed.isFinite else {
        return nil
    }
    return parsed
}

func clampedEditableNumber(
    _ text: String,
    range: ClosedRange<Double>,
    locale: Locale = .autoupdatingCurrent
) -> Double? {
    guard let parsed = parseEditableNumber(text, locale: locale) else {
        return nil
    }
    return min(max(parsed, range.lowerBound), range.upperBound)
}

func playbackFramesToMilliseconds(
    _ frames: Double,
    bufferSampleRate: Double,
    fallbackSampleRate: Double
) -> Double {
    let sampleRate = bufferSampleRate > 0 ? bufferSampleRate : fallbackSampleRate
    guard sampleRate > 0 else {
        return 0
    }
    return frames / sampleRate * 1_000
}

func localizedInteger(_ value: Int) -> String {
    value.formatted(.number.locale(.autoupdatingCurrent))
}

func localizedInteger(_ value: UInt32) -> String {
    UInt64(value).formatted(.number.locale(.autoupdatingCurrent))
}

func localizedInteger(_ value: UInt64) -> String {
    value.formatted(.number.locale(.autoupdatingCurrent))
}

func localizedDecibels(_ value: Double, fractionDigits: Int = 1) -> String {
    let number = localizedDecimal(
        value,
        minimumFractionDigits: fractionDigits,
        maximumFractionDigits: fractionDigits,
        signed: true
    )
    return localized("\(number) dB")
}

func localizedFrequency(_ value: Double) -> String {
    if value >= 1_000 {
        let number = localizedDecimal(value / 1_000, minimumFractionDigits: 1, maximumFractionDigits: 1)
        return localized("\(number) kHz")
    }
    let number = localizedDecimal(value, minimumFractionDigits: 0, maximumFractionDigits: 0)
    return localized("\(number) Hz")
}

func localizedFrameCount(_ value: Int) -> String {
    let number = localizedInteger(value)
    return value == 1 ? localized("\(number) frame") : localized("\(number) frames")
}

func localizedFrameCount(_ value: UInt32) -> String {
    let number = localizedInteger(value)
    return value == 1 ? localized("\(number) frame") : localized("\(number) frames")
}

func settingsCanDeleteSelectedProfile(_ snapshot: SettingsSnapshot) -> Bool {
    settingsCanDeleteProfile(snapshot, id: snapshot.selectedProfileID)
}

func settingsCanDeleteProfile(_ snapshot: SettingsSnapshot, id: UUID) -> Bool {
    !snapshot.profileStoreProtection.isProtected
        && snapshot.profiles.count > 1
        && !snapshot.isPreviewing
        && !snapshot.programmeComparison.isActive
        && id != snapshot.activeProfileID
}

func settingsSnapshotPreservingLocalDraft(
    current: SettingsSnapshot,
    latest: SettingsSnapshot
) -> SettingsSnapshot {
    guard latest.profiles.contains(where: { $0.id == current.selectedProfileID }) else {
        return latest
    }

    let selectedProfile = current.profiles.first(where: { $0.id == current.selectedProfileID })
        ?? current.draftProfile
    let hasUnsavedDraft = current.draftProfile != selectedProfile
    var merged = latest
    merged.selectedProfileID = current.selectedProfileID
    merged.draftProfile = hasUnsavedDraft
        ? current.draftProfile
        : latest.profiles.first(where: { $0.id == current.selectedProfileID }) ?? current.draftProfile
    return merged
}

func settingsSnapshotAfterCommand(
    current: SettingsSnapshot,
    dispatched: SettingsSnapshot,
    latest: SettingsSnapshot
) -> SettingsSnapshot {
    guard current.selectedProfileID == dispatched.selectedProfileID,
          current.draftProfile == dispatched.draftProfile else {
        return settingsSnapshotPreservingLocalDraft(current: current, latest: latest)
    }
    return latest
}

func localizedLatency(milliseconds: Double) -> String {
    let number = localizedDecimal(milliseconds, minimumFractionDigits: 2, maximumFractionDigits: 2)
    return localized("\(number) ms")
}

private extension Notification.Name {
    static let glassEQBringSettingsToFront = Notification.Name("com.glasseq.bringSettingsToFront")
}

@MainActor
public enum SettingsWindowFocus {
    private static var pendingSection: SettingsSection?

    public static func request(section: SettingsSection? = nil) {
        if let section {
            pendingSection = section
        }
        NotificationCenter.default.post(
            name: .glassEQBringSettingsToFront,
            object: section
        )
    }

    static func consumePendingSection() -> SettingsSection? {
        defer {
            pendingSection = nil
        }
        return pendingSection
    }
}

public struct SettingsView: View {
    @Bindable var model: GlassEQSettingsViewModel
    @State private var snapshot: SettingsSnapshot
    @State private var tab = EditorSection.editor
    @State private var draftEditGeneration = 0
    @State private var isImportSheetPresented = false
    @State private var isNewProfileSheetPresented = false
    @State private var importRequestedFromNewProfileSheet = false
    @State private var profilePendingDeletion: EQProfile?

    public init(model: GlassEQSettingsViewModel) {
        self._model = Bindable(wrappedValue: model)
        _snapshot = State(initialValue: model.snapshot)
    }

    public var body: some View {
        HStack(spacing: 0) {
            ProfileSidebar(
                profiles: snapshot.profiles,
                activeProfileID: snapshot.activeProfileID,
                selectedProfileID: snapshot.selectedProfileID,
                hasCurrentOutput: !snapshot.currentOutputUID.isEmpty,
                onSelect: selectProfile,
                onCreate: { isNewProfileSheetPresented = true },
                onDuplicate: duplicateProfile,
                onDelete: requestProfileDeletion,
                onAssignToCurrentOutput: assignProfileToCurrentOutput,
                canDeleteProfile: { settingsCanDeleteProfile(snapshot, id: $0) },
                isReadOnly: isProfileStoreProtected || snapshot.programmeComparison.isActive
            )
                .frame(width: 260)
                .sheet(isPresented: $isNewProfileSheetPresented, onDismiss: presentImportIfRequested) {
                    NewProfileSheet(
                        onCreate: createProfile,
                        onImport: { importRequestedFromNewProfileSheet = true }
                    )
                }
                .confirmationDialog(
                    profilePendingDeletion.map { localized("Delete \"\($0.name)\"?") } ?? "",
                    isPresented: Binding(
                        get: { profilePendingDeletion != nil },
                        set: { isPresented in
                            if !isPresented {
                                profilePendingDeletion = nil
                            }
                        }
                    ),
                    titleVisibility: .visible,
                    presenting: profilePendingDeletion
                ) { profile in
                    Button(localized("Delete"), role: .destructive) {
                        perform(.deleteProfile(profile.id))
                    }
                } message: { _ in
                    Text(localized("This also removes any output assignment that uses the profile. It can't be undone."))
                }

            ProfileDetail(
                snapshot: snapshot,
                draftProfile: $snapshot.draftProfile,
                tab: $tab,
                draftEditGeneration: draftEditGeneration,
                hasUnsavedDraft: hasUnsavedDraft,
                onApply: applyDraft,
                onRevert: revertDraft,
                onUseForCurrentOutput: useDraftForCurrentOutput,
                onSetFallback: setFallbackToDraft,
                onShowImporter: { isImportSheetPresented = true },
                onPreview: previewDraft,
                onStopPreview: stopPreview,
                onStartProgrammeComparison: startProgrammeComparison,
                onSelectProgrammeComparison: selectProgrammeComparison,
                onStopProgrammeComparison: stopProgrammeComparison,
                onResetDiagnostics: resetDiagnostics,
                onSetAggregateBufferMode: setAggregateBufferMode,
                onRetryAutomaticAggregateBuffer: retryAutomaticAggregateBuffer,
                onRetryAudioEngine: retryAudioEngine,
                onOpenPrivacySettings: openPrivacySettings,
                onResetUnsupportedProfileStore: resetUnsupportedProfileStore
            )
                .frame(minWidth: 640, maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .background(FinderStyleWindowConfigurator())
        .sheet(isPresented: $isImportSheetPresented) {
            ProfileImportSheet(
                currentProfile: snapshot.draftProfile,
                isReadOnly: isProfileStoreProtected,
                onImport: importProfile,
                onImportParsedProfile: importParsedProfile,
                onChooseImportFiles: chooseImportFiles
            )
        }
        // Run the content up under the (transparent, separator-less) titlebar so there's no bar
        // or hairline between the window controls and the content, and the sidebar card sits
        // beneath the traffic lights — matching System Settings.
        .ignoresSafeArea(.container, edges: .top)
        .overlay(alignment: .bottom) {
            if let message = model.commandErrorMessage {
                Text(message)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.macOSSystemRed)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 8))
                    .padding()
            }
        }
        .onChange(of: model.snapshotVersion) { _, _ in
            refreshSnapshotFromModel()
        }
        .onChange(of: model.isConnected) { _, _ in
            refreshSnapshotFromModel()
        }
        .onAppear {
            if let requestedSection = SettingsWindowFocus.consumePendingSection() {
                show(requestedSection)
            }
            refreshSnapshotFromModel()
            updateMetricsPolling()
        }
        .onDisappear {
            stopMetricsPolling()
        }
        .onChange(of: tab) { _, _ in
            updateMetricsPolling()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .glassEQBringSettingsToFront)
        ) { notification in
            if let requestedSection = notification.object as? SettingsSection {
                show(requestedSection)
                _ = SettingsWindowFocus.consumePendingSection()
            }
        }
    }

    private var selectedProfile: EQProfile {
        snapshot.profiles.first(where: { $0.id == snapshot.selectedProfileID }) ?? snapshot.draftProfile
    }

    private var hasUnsavedDraft: Bool {
        snapshot.draftProfile != selectedProfile
    }

    private var canDeleteSelectedProfile: Bool {
        settingsCanDeleteSelectedProfile(snapshot)
    }

    private var isProfileStoreProtected: Bool {
        snapshot.profileStoreProtection.isProtected
    }

    private func selectProfile(_ id: UUID) {
        guard let profile = snapshot.profiles.first(where: { $0.id == id }) else {
            return
        }
        snapshot.selectedProfileID = id
        snapshot.draftProfile = profile
    }

    private func applyDraft() {
        perform(.applyProfile(snapshot.draftProfile))
    }

    private func revertDraft() {
        snapshot.draftProfile = selectedProfile
        draftEditGeneration &+= 1
    }

    private func useDraftForCurrentOutput() {
        perform(.useProfileForCurrentOutput(snapshot.draftProfile))
    }

    private func setFallbackToDraft() {
        perform(.setFallback(snapshot.draftProfile))
    }

    private func importProfile(format: ImportFormat, name: String, text: String) async -> String? {
        let dispatchedSnapshot = snapshot
        let response = await model.perform(.importProfile(format: format, name: name, text: text))
        refreshSnapshotFromModel(afterCommandDispatchedFrom: dispatchedSnapshot)
        guard response?.importSucceeded == true else {
            return model.commandErrorMessage ?? localized("GlassEQ could not import this profile.")
        }
        return nil
    }

    private func importParsedProfile(_ profile: EQProfile) async -> String? {
        let dispatchedSnapshot = snapshot
        let response = await model.perform(.importParsedProfile(profile))
        refreshSnapshotFromModel(afterCommandDispatchedFrom: dispatchedSnapshot)
        guard response?.importSucceeded == true else {
            return model.commandErrorMessage ?? localized("GlassEQ could not import this profile.")
        }
        return nil
    }

    private func chooseImportFiles(_ mode: SettingsFileImportMode) async -> SettingsFileImportChoice {
        let response = await model.perform(.chooseImportFiles(mode: mode))
        return SettingsFileImportChoice(
            selection: response?.fileImportSelection,
            errorMessage: response == nil ? model.commandErrorMessage : nil
        )
    }

    private func show(_ section: SettingsSection) {
        switch section {
        case .output:
            tab = .output
        }
    }

    private func previewDraft() {
        perform(.preview(snapshot.draftProfile))
    }

    private func stopPreview() {
        perform(.stopPreview)
    }

    private func startProgrammeComparison() {
        perform(.startProgrammeComparison(snapshot.draftProfile))
    }

    private func selectProgrammeComparison(
        _ selection: EQProgrammeComparisonSelection
    ) {
        perform(.selectProgrammeComparison(selection))
    }

    private func stopProgrammeComparison() {
        perform(.stopProgrammeComparison)
    }

    private func resetDiagnostics() {
        perform(.resetDiagnostics)
    }

    private func setAggregateBufferMode(_ mode: SettingsAggregateBufferMode) {
        perform(.setAggregateBufferMode(mode))
    }

    private func retryAutomaticAggregateBuffer() {
        perform(.retryAutomaticAggregateBuffer)
    }

    private func retryAudioEngine() {
        perform(.retryAudioEngine)
    }

    private func openPrivacySettings() {
        perform(.openPrivacySettings)
    }

    private func resetUnsupportedProfileStore() {
        perform(.resetUnsupportedProfileStore)
    }

    private func createProfile(_ kind: SettingsProfileKind) {
        perform(.createProfile(kind))
    }

    private func presentImportIfRequested() {
        guard importRequestedFromNewProfileSheet else {
            return
        }
        importRequestedFromNewProfileSheet = false
        isImportSheetPresented = true
    }

    private func duplicateProfile(_ id: UUID) {
        perform(.duplicateProfile(id))
    }

    private func requestProfileDeletion(_ id: UUID) {
        profilePendingDeletion = snapshot.profiles.first(where: { $0.id == id })
    }

    private func assignProfileToCurrentOutput(_ id: UUID) {
        guard let profile = snapshot.profiles.first(where: { $0.id == id }) else {
            return
        }
        perform(.useProfileForCurrentOutput(profile))
    }

    private func refreshMetricsFromModel() {
        snapshot.metrics = model.snapshot.metrics
    }

    private func refreshSnapshotFromModel() {
        snapshot = settingsSnapshotPreservingLocalDraft(current: snapshot, latest: model.snapshot)
    }

    private func refreshSnapshotFromModel(afterCommandDispatchedFrom dispatchedSnapshot: SettingsSnapshot) {
        snapshot = settingsSnapshotAfterCommand(
            current: snapshot,
            dispatched: dispatchedSnapshot,
            latest: model.snapshot
        )
    }

    private func updateMetricsPolling() {
        if tab == .output {
            perform(.startMetricsPolling)
            refreshMetricsFromModel()
        } else {
            stopMetricsPolling()
        }
    }

    private func stopMetricsPolling() {
        perform(.stopMetricsPolling)
    }

    private func perform(_ command: SettingsCommand) {
        let dispatchedSnapshot = snapshot
        Task { @MainActor in
            await model.perform(command)
            refreshSnapshotFromModel(afterCommandDispatchedFrom: dispatchedSnapshot)
        }
    }
}

private struct FinderStyleWindowConfigurator: NSViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> FirstResponderSinkView {
        let view = FirstResponderSinkView()
        context.coordinator.view = view
        context.coordinator.installObserver()
        return view
    }

    func updateNSView(_ view: FirstResponderSinkView, context: Context) {
        context.coordinator.view = view
        DispatchQueue.main.async {
            context.coordinator.configureWindowIfAvailable()
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        weak var view: FirstResponderSinkView?
        private var didInitialFront = false
        private var observingWindow = false

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        func installObserver() {
            NotificationCenter.default.removeObserver(self, name: .glassEQBringSettingsToFront, object: nil)
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(bringSettingsToFrontNotification),
                name: .glassEQBringSettingsToFront,
                object: nil
            )
        }

        func configureWindowIfAvailable() {
            guard let view, let window = view.window else {
                return
            }
            // Solid base layer that the sidebar card and content cards float on. The hidden title
            // bar (.windowStyle(.hiddenTitleBar) on the scene) handles the window chrome; the
            // content is pulled up under the controls by .ignoresSafeArea(.top) in the body.
            window.isOpaque = true
            window.backgroundColor = .windowBackgroundColor
            window.initialFirstResponder = view
            startObservingGeometry(of: window)
            positionSettingsWindowControls(in: window)

            guard !didInitialFront else {
                return
            }
            didInitialFront = true
            bringToFront()
        }

        private func startObservingGeometry(of window: NSWindow) {
            guard !observingWindow else {
                return
            }
            observingWindow = true
            let center = NotificationCenter.default
            for name in [NSWindow.didResizeNotification, NSWindow.didBecomeKeyNotification, NSWindow.didExitFullScreenNotification] {
                center.addObserver(self, selector: #selector(windowGeometryDidChange(_:)), name: name, object: window)
            }
        }

        @objc private func windowGeometryDidChange(_ note: Notification) {
            guard let window = note.object as? NSWindow else {
                return
            }
            positionSettingsWindowControls(in: window)
        }


        @objc private func bringSettingsToFrontNotification() {
            bringToFront()
        }

        private func bringToFront() {
            guard let view, let window = view.window else {
                return
            }
            NSApplication.shared.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            window.makeFirstResponder(view)
        }
    }

    final class FirstResponderSinkView: NSView {
        override var acceptsFirstResponder: Bool {
            true
        }

        // Position the controls as soon as we're in the window — before it's shown — so they don't
        // visibly jump from the default position when the settings window opens.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                positionSettingsWindowControls(in: window)
            }
        }
    }
}

// Top inset for the sidebar header and content pane so they clear the window controls (which are
// nudged downward by `windowControlTopMargin`).
private let settingsTitlebarInset: CGFloat = 38

// Distance from the window's top edge to the top of the traffic lights. `.hiddenTitleBar` parks
// them ~9pt from the top (centered in the 32pt titlebar); System Settings sits them lower.
private let windowControlTopMargin: CGFloat = 16

// Distance from the window's left edge to the leftmost traffic light (default is ~9pt).
private let windowControlLeadingMargin: CGFloat = 13

// Leading inset for the sidebar's content text. Kept independent of the traffic lights so the
// selection capsule keeps its inset; the lights sit slightly to its left, like System Settings.
private let sidebarContentLeading: CGFloat = 19

// Moves the traffic lights to (windowControlLeadingMargin, windowControlTopMargin), preserving
// their spacing. Idempotent — safe to re-apply on geometry changes and to call early (before the
// window is shown) so the controls don't visibly jump into place on open.
@MainActor
private func positionSettingsWindowControls(in window: NSWindow) {
    let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
        .compactMap { window.standardWindowButton($0) }
    guard let titlebar = buttons.first?.superview,
          let leftmost = buttons.map(\.frame.minX).min() else {
        return
    }
    let dx = windowControlLeadingMargin - leftmost
    for button in buttons {
        let targetX = button.frame.minX + dx
        let targetY = max(0, titlebar.bounds.height - windowControlTopMargin - button.frame.height)
        if abs(button.frame.origin.x - targetX) > 0.5 || abs(button.frame.origin.y - targetY) > 0.5 {
            button.setFrameOrigin(NSPoint(x: targetX, y: targetY))
        }
    }
}

private let sidebarCardInset: CGFloat = 6
private let sidebarCardCornerRadius: CGFloat = 14

private struct CardPanelModifier: ViewModifier {
    var padding: CGFloat = 16
    var cornerRadius: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
    }
}

private extension View {
    func cardPanel(padding: CGFloat = 16, cornerRadius: CGFloat = 16) -> some View {
        modifier(CardPanelModifier(padding: padding, cornerRadius: cornerRadius))
    }
}

private extension Color {
    static let macOSSystemRed = Color(nsColor: .systemRed)
}

private struct SettingRow<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 88, alignment: .leading)
            content
        }
    }
}

private struct GraphLegendItem: View {
    var color: Color
    var title: String

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct EQAnalysisSignature: Equatable, Sendable {
    static let defaultSampleRate = 48_000.0

    var sampleRate: Double
    var mode: EQMode
    var channelMode: EQChannelMode
    var preampDB: Double
    var filters: [EQFilter]
    var leftPreampDB: Double
    var leftFilters: [EQFilter]
    var rightPreampDB: Double
    var rightFilters: [EQFilter]
    var convolution: EQConvolutionSource?
    var leftConvolution: EQConvolutionSource?
    var rightConvolution: EQConvolutionSource?

    init(profile: EQProfile, sampleRate: Double) {
        self.sampleRate = Self.effectiveSampleRate(sampleRate)
        self.mode = profile.mode
        self.channelMode = profile.channelMode
        self.preampDB = profile.preampDB
        self.filters = profile.filters
        self.leftPreampDB = profile.leftPreampDB
        self.leftFilters = profile.leftFilters
        self.rightPreampDB = profile.rightPreampDB
        self.rightFilters = profile.rightFilters
        self.convolution = profile.convolution
        self.leftConvolution = profile.leftConvolution
        self.rightConvolution = profile.rightConvolution
    }

    static func effectiveSampleRate(_ sampleRate: Double) -> Double {
        guard sampleRate.isFinite, sampleRate > 0 else {
            return defaultSampleRate
        }
        return sampleRate
    }

    func hasSameResponseContent(as other: Self) -> Bool {
        sampleRate == other.sampleRate
            && mode == other.mode
            && channelMode == other.channelMode
            && filters == other.filters
            && leftFilters == other.leftFilters
            && rightFilters == other.rightFilters
            && convolution == other.convolution
            && leftConvolution == other.leftConvolution
            && rightConvolution == other.rightConvolution
    }
}

struct EQAnalysisSnapshot: Equatable, Sendable {
    var signature: EQAnalysisSignature
    var channelMode: EQChannelMode
    var recommendedPreampDB: Double
    var maximumUsableFrequency: Double
    var inactiveEnabledFilterCount: Int
    var linkedPoints: [FrequencyResponsePoint]
    var leftPoints: [FrequencyResponsePoint]
    var rightPoints: [FrequencyResponsePoint]
    private var linkedSourcePeakDB: Double?
    private var leftSourcePeakDB: Double?
    private var rightSourcePeakDB: Double?
    private var linkedSourcePoints: [FrequencyResponsePoint]
    private var leftSourcePoints: [FrequencyResponsePoint]
    private var rightSourcePoints: [FrequencyResponsePoint]

    @concurrent
    static func analyze(
        profile: EQProfile,
        sampleRate: Double,
        cancellationCheck: @Sendable () throws -> Void = { try Task.checkCancellation() }
    ) async throws -> Self {
        try Self(
            profile: profile,
            sampleRate: sampleRate,
            cancellationCheck: cancellationCheck
        )
    }

    private init(
        profile: EQProfile,
        sampleRate: Double,
        cancellationCheck: @Sendable () throws -> Void
    ) throws {
        try cancellationCheck()
        let sampleRate = EQAnalysisSignature.effectiveSampleRate(sampleRate)
        self.signature = EQAnalysisSignature(profile: profile, sampleRate: sampleRate)
        self.channelMode = profile.channelMode
        self.maximumUsableFrequency = EQRouteFrequencyPolicy.maximumUsableFrequency(
            sampleRate: sampleRate
        )
        self.inactiveEnabledFilterCount = EQRouteFrequencyPolicy.inactiveEnabledFilterCount(
            profile: profile,
            sampleRate: sampleRate
        )

        switch profile.channelMode {
        case .linked:
            let sourcePeakDB = try Self.sourcePeakMagnitudeDB(
                mode: profile.mode,
                filters: profile.filters,
                source: profile.convolution,
                sampleRate: sampleRate,
                cancellationCheck: cancellationCheck
            )
            let sourcePoints = try Self.responsePoints(
                mode: profile.mode,
                filters: profile.filters,
                source: profile.convolution,
                preampDB: 0,
                sampleRate: sampleRate,
                cancellationCheck: cancellationCheck
            )
            self.linkedSourcePeakDB = sourcePeakDB
            self.leftSourcePeakDB = nil
            self.rightSourcePeakDB = nil
            self.linkedSourcePoints = sourcePoints
            self.leftSourcePoints = []
            self.rightSourcePoints = []
            self.linkedPoints = Self.applyingPreamp(profile.preampDB, to: sourcePoints)
            self.leftPoints = []
            self.rightPoints = []
        case .stereo:
            let leftSourcePeakDB = try Self.sourcePeakMagnitudeDB(
                mode: profile.mode,
                filters: profile.leftFilters,
                source: profile.leftConvolution,
                sampleRate: sampleRate,
                cancellationCheck: cancellationCheck
            )
            let rightSourcePeakDB = try Self.sourcePeakMagnitudeDB(
                mode: profile.mode,
                filters: profile.rightFilters,
                source: profile.rightConvolution,
                sampleRate: sampleRate,
                cancellationCheck: cancellationCheck
            )
            let leftSourcePoints = try Self.responsePoints(
                mode: profile.mode,
                filters: profile.leftFilters,
                source: profile.leftConvolution,
                preampDB: 0,
                sampleRate: sampleRate,
                cancellationCheck: cancellationCheck
            )
            let rightSourcePoints = try Self.responsePoints(
                mode: profile.mode,
                filters: profile.rightFilters,
                source: profile.rightConvolution,
                preampDB: 0,
                sampleRate: sampleRate,
                cancellationCheck: cancellationCheck
            )
            self.linkedSourcePeakDB = nil
            self.leftSourcePeakDB = leftSourcePeakDB
            self.rightSourcePeakDB = rightSourcePeakDB
            self.linkedSourcePoints = []
            self.leftSourcePoints = leftSourcePoints
            self.rightSourcePoints = rightSourcePoints
            self.linkedPoints = []
            self.leftPoints = Self.applyingPreamp(profile.leftPreampDB, to: leftSourcePoints)
            self.rightPoints = Self.applyingPreamp(profile.rightPreampDB, to: rightSourcePoints)
        }
        self.recommendedPreampDB = Self.recommendedPreampDB(
            profile: profile,
            linkedSourcePeakDB: linkedSourcePeakDB,
            leftSourcePeakDB: leftSourcePeakDB,
            rightSourcePeakDB: rightSourcePeakDB
        )
        try cancellationCheck()
    }

    func updatingPreamp(profile: EQProfile, sampleRate: Double) -> Self? {
        let nextSignature = EQAnalysisSignature(profile: profile, sampleRate: sampleRate)
        guard signature.hasSameResponseContent(as: nextSignature) else {
            return nil
        }

        var updated = self
        updated.signature = nextSignature
        switch profile.channelMode {
        case .linked:
            updated.linkedPoints = Self.applyingPreamp(
                profile.preampDB,
                to: linkedSourcePoints
            )
        case .stereo:
            updated.leftPoints = Self.applyingPreamp(
                profile.leftPreampDB,
                to: leftSourcePoints
            )
            updated.rightPoints = Self.applyingPreamp(
                profile.rightPreampDB,
                to: rightSourcePoints
            )
        }
        updated.recommendedPreampDB = Self.recommendedPreampDB(
            profile: profile,
            linkedSourcePeakDB: linkedSourcePeakDB,
            leftSourcePeakDB: leftSourcePeakDB,
            rightSourcePeakDB: rightSourcePeakDB
        )
        return updated
    }

    private static func sourcePeakMagnitudeDB(
        mode: EQMode,
        filters: [EQFilter],
        source: EQConvolutionSource?,
        sampleRate: Double,
        cancellationCheck: @Sendable () throws -> Void
    ) throws -> Double {
        if mode == .convolution {
            return try FrequencyResponse.peakMagnitudeDB(
                for: source,
                preampDB: 0,
                sampleRate: sampleRate,
                cancellationCheck: cancellationCheck
            )
        }
        return try FrequencyResponse.peakMagnitudeDB(
            for: filters,
            preampDB: 0,
            sampleRate: sampleRate,
            cancellationCheck: cancellationCheck
        )
    }

    private static func applyingPreamp(
        _ preampDB: Double,
        to points: [FrequencyResponsePoint]
    ) -> [FrequencyResponsePoint] {
        points.map {
            FrequencyResponsePoint(
                frequency: $0.frequency,
                magnitudeDB: preampDB + $0.magnitudeDB
            )
        }
    }

    private static func recommendedPreampDB(
        profile: EQProfile,
        linkedSourcePeakDB: Double?,
        leftSourcePeakDB: Double?,
        rightSourcePeakDB: Double?
    ) -> Double {
        let activePreampDB: Double
        let renderedPeakDB: Double
        switch profile.channelMode {
        case .linked:
            activePreampDB = profile.preampDB
            renderedPeakDB = profile.preampDB + (linkedSourcePeakDB ?? 0)
        case .stereo:
            activePreampDB = max(profile.leftPreampDB, profile.rightPreampDB)
            renderedPeakDB = max(
                profile.leftPreampDB + (leftSourcePeakDB ?? 0),
                profile.rightPreampDB + (rightSourcePeakDB ?? 0)
            )
        }
        return activePreampDB - max(renderedPeakDB + 0.5, 0)
    }

    private static func responsePoints(
        mode: EQMode,
        filters: [EQFilter],
        source: EQConvolutionSource?,
        preampDB: Double,
        sampleRate: Double,
        cancellationCheck: @Sendable () throws -> Void
    ) rethrows -> [FrequencyResponsePoint] {
        if mode == .convolution {
            return try FrequencyResponse.points(
                for: source,
                preampDB: preampDB,
                sampleRate: sampleRate,
                cancellationCheck: cancellationCheck
            )
        }
        try cancellationCheck()
        let points = FrequencyResponse.points(
            for: filters,
            preampDB: preampDB,
            sampleRate: sampleRate
        )
        try cancellationCheck()
        return points
    }

    var accessibilitySummary: String {
        let curveSummary: String
        switch channelMode {
        case .linked:
            curveSummary = localized(
                "Linked curve from \(localizedDecibels(minMagnitude(in: linkedPoints))) to \(localizedDecibels(maxMagnitude(in: linkedPoints))); recommended preamp \(localizedDecibels(recommendedPreampDB))"
            )
        case .stereo:
            curveSummary = localized(
                "Left curve from \(localizedDecibels(minMagnitude(in: leftPoints))) to \(localizedDecibels(maxMagnitude(in: leftPoints))); right curve from \(localizedDecibels(minMagnitude(in: rightPoints))) to \(localizedDecibels(maxMagnitude(in: rightPoints))); recommended preamp \(localizedDecibels(recommendedPreampDB))"
            )
        }
        guard let inactiveFilterSummary else {
            return curveSummary
        }
        return localized("\(curveSummary). \(inactiveFilterSummary)")
    }

    var inactiveFilterSummary: String? {
        guard inactiveEnabledFilterCount > 0 else {
            return nil
        }
        let count = localizedInteger(inactiveEnabledFilterCount)
        let ceiling = localizedFrequency(maximumUsableFrequency)
        if inactiveEnabledFilterCount == 1 {
            return localized("\(count) enabled filter above \(ceiling) is inactive on this route")
        }
        return localized("\(count) enabled filters above \(ceiling) are inactive on this route")
    }

    private func minMagnitude(in points: [FrequencyResponsePoint]) -> Double {
        points.map(\.magnitudeDB).min() ?? 0
    }

    private func maxMagnitude(in points: [FrequencyResponsePoint]) -> Double {
        points.map(\.magnitudeDB).max() ?? 0
    }
}

private struct ProfileSidebar: View {
    var profiles: [EQProfile]
    var activeProfileID: UUID
    var selectedProfileID: UUID
    var hasCurrentOutput: Bool
    var onSelect: (UUID) -> Void
    var onCreate: () -> Void
    var onDuplicate: (UUID) -> Void
    var onDelete: (UUID) -> Void
    var onAssignToCurrentOutput: (UUID) -> Void
    var canDeleteProfile: (UUID) -> Bool
    var isReadOnly: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var selectionNamespace

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(profiles) { profile in
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
                    onCreate()
                } label: {
                    Label(localized("New Profile"), systemImage: "plus")
                        .frame(minHeight: 28)
                        .contentShape(.rect)
                }
                .controlSize(.large)
                .disabled(isReadOnly)
                .accessibilityHint(Text(localized("Chooses a profile type or import source")))

                Spacer()

                Button {
                    onDuplicate(selectedProfileID)
                } label: {
                    Image(systemName: "plus.square.on.square")
                        .frame(width: 28, height: 28)
                        .contentShape(.rect)
                }
                .buttonStyle(.borderless)
                .help(localized("Duplicate profile"))
                .disabled(isReadOnly)
                .accessibilityLabel(Text(localized("Duplicate profile")))
                .accessibilityHint(Text(localized("Copies the selected profile")))

                Button(role: .destructive) {
                    onDelete(selectedProfileID)
                } label: {
                    Image(systemName: "trash")
                        .frame(width: 28, height: 28)
                        .contentShape(.rect)
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
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: sidebarCardCornerRadius, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: sidebarCardCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: sidebarCardCornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.16), radius: 4, x: 0, y: 1)
        // Small, even buffer on all sides. Kept small so the window controls still land on the
        // card (with .hiddenTitleBar, macOS parks them near the top) rather than in the margin.
        .padding(sidebarCardInset)
    }

    private var canDeleteSelectedProfile: Bool {
        canDeleteProfile(selectedProfileID)
    }

    private func row(for profile: EQProfile) -> some View {
        let isSelected = profile.id == selectedProfileID
        let isActive = profile.id == activeProfileID
        let secondary = isSelected ? Color.white.opacity(0.78) : Color.secondary
        return Button {
            onSelect(profile.id)
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
                onDuplicate(profile.id)
            }
            .disabled(isReadOnly)
            Button(localized("Use for This Output")) {
                onAssignToCurrentOutput(profile.id)
            }
            .disabled(isReadOnly || !hasCurrentOutput)
            Divider()
            Button(localized("Delete…"), role: .destructive) {
                onDelete(profile.id)
            }
            .disabled(!canDeleteProfile(profile.id))
        }
        .accessibilityLabel(Text(profile.name))
        .accessibilityValue(Text(profileAccessibilityValue(profile)))
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

    private func profileAccessibilityValue(_ profile: EQProfile) -> String {
        var values = [profileSubtitle(profile)]
        if profile.id == selectedProfileID {
            values.append(localized("Selected"))
        }
        if profile.id == activeProfileID {
            values.append(profile.isBypassed ? localized("Active, bypassed") : localized("Active"))
        }
        return values.joined(separator: ", ")
    }
}

private struct ProfileDetail: View {
    var snapshot: SettingsSnapshot
    @Binding var draftProfile: EQProfile
    @Binding var tab: EditorSection
    var draftEditGeneration: Int
    var hasUnsavedDraft: Bool
    var onApply: () -> Void
    var onRevert: () -> Void
    var onUseForCurrentOutput: () -> Void
    var onSetFallback: () -> Void
    var onShowImporter: () -> Void
    var onPreview: () -> Void
    var onStopPreview: () -> Void
    var onStartProgrammeComparison: () -> Void
    var onSelectProgrammeComparison: (EQProgrammeComparisonSelection) -> Void
    var onStopProgrammeComparison: () -> Void
    var onResetDiagnostics: () -> Void
    var onSetAggregateBufferMode: (SettingsAggregateBufferMode) -> Void
    var onRetryAutomaticAggregateBuffer: () -> Void
    var onRetryAudioEngine: () -> Void
    var onOpenPrivacySettings: () -> Void
    var onResetUnsupportedProfileStore: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            constrainedContent {
                ProfileHeader(
                    snapshot: snapshot,
                    draftProfile: $draftProfile,
                    tab: $tab,
                    isReadOnly: isProfileStoreProtected
                        || snapshot.programmeComparison.isActive,
                    onShowImporter: onShowImporter
                )
            }

            if isProfileStoreProtected {
                constrainedContent {
                    ProfileStoreProtectionBanner(
                        protection: snapshot.profileStoreProtection,
                        onReset: onResetUnsupportedProfileStore
                    )
                }
                .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView {
                constrainedContent {
                    Group {
                        switch tab {
                        case .editor:
                            EditorTab(
                                draftProfile: $draftProfile,
                                sampleRate: snapshot.currentProcessingSampleRate > 0
                                    ? snapshot.currentProcessingSampleRate
                                    : snapshot.currentOutputSampleRate,
                                draftEditGeneration: draftEditGeneration
                            )
                            .disabled(
                                isProfileStoreProtected
                                    || snapshot.programmeComparison.isActive
                            )
                        case .output:
                            OutputTab(
                                snapshot: snapshot,
                                isProfileStoreProtected: isProfileStoreProtected,
                                onUseForCurrentOutput: onUseForCurrentOutput,
                                onSetFallback: onSetFallback,
                                onResetDiagnostics: onResetDiagnostics,
                                onSetAggregateBufferMode: onSetAggregateBufferMode,
                                onRetryAutomaticAggregateBuffer: onRetryAutomaticAggregateBuffer,
                                onRetryAudioEngine: onRetryAudioEngine,
                                onOpenPrivacySettings: onOpenPrivacySettings
                            )
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

            if tab == .editor {
                constrainedContent {
                    ApplyBar(
                        hasUnsavedDraft: hasUnsavedDraft,
                        currentOutputUID: snapshot.currentOutputUID,
                        isPreviewing: snapshot.isPreviewing,
                        isRunning: snapshot.isRunning,
                        programmeComparison: snapshot.programmeComparison,
                        isReadOnly: isProfileStoreProtected,
                        onApply: onApply,
                        onRevert: onRevert,
                        onPreview: onPreview,
                        onStopPreview: onStopPreview,
                        onStartProgrammeComparison: onStartProgrammeComparison,
                        onSelectProgrammeComparison: onSelectProgrammeComparison,
                        onStopProgrammeComparison: onStopProgrammeComparison,
                        onUseForCurrentOutput: onUseForCurrentOutput
                    )
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

    private var isProfileStoreProtected: Bool {
        snapshot.profileStoreProtection.isProtected
    }
}

private struct ProfileHeader: View {
    var snapshot: SettingsSnapshot
    @Binding var draftProfile: EQProfile
    @Binding var tab: EditorSection
    var isReadOnly: Bool
    var onShowImporter: () -> Void
    @State private var isRenaming = false

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                if isRenaming {
                    HStack(spacing: 8) {
                        TextField(localized("Profile name"), text: $draftProfile.name)
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
                        Text(draftProfile.name)
                            .font(.title2.weight(.semibold))
                            .lineLimit(1)
                        Button {
                            isRenaming = true
                        } label: {
                            Image(systemName: "pencil")
                                .frame(width: 28, height: 28)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.borderless)
                        .disabled(isReadOnly)
                        .help(localized("Rename profile"))
                        .accessibilityLabel(Text(localized("Rename profile")))
                        .accessibilityHint(Text(localized("Edits the selected profile name")))
                    }
                }

                HStack(spacing: 8) {
                    Label(draftProfile.mode.title, systemImage: draftProfile.mode.symbol)
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
                .accessibilityValue(Text(([draftProfile.mode.title] + statusChips.map(\.title)).joined(separator: ", ")))
            }

            Spacer()

            Button {
                onShowImporter()
            } label: {
                Label(localized("Import"), systemImage: "square.and.arrow.down")
            }
            .controlSize(.large)
            .disabled(isReadOnly)
            .accessibilityHint(Text(localized("Opens guided profile import")))

            Picker(localized("Section"), selection: $tab) {
                ForEach(EditorSection.allCases) { section in
                    Text(section.title).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 230)
            .accessibilityLabel(Text(localized("Section")))
            .accessibilityValue(Text(tab.title))
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
        var chips: [StatusChip] = []
        let id = draftProfile.id
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

private struct ProfileStoreProtectionBanner: View {
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
                Label(protection.resetButtonTitle, systemImage: "arrow.counterclockwise")
                    .frame(minHeight: 28)
                    .contentShape(.rect)
            }
            .controlSize(.large)
            .accessibilityLabel(Text(protection.resetButtonTitle))
        }
        .cardPanel(padding: 14)
    }
}

private enum EditorSection: String, CaseIterable, Identifiable {
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

enum EQEditChannel: String, CaseIterable, Identifiable {
    case left
    case right

    var id: String { rawValue }

    var title: String {
        switch self {
        case .left:
            localized("Left")
        case .right:
            localized("Right")
        }
    }
}

private extension EQChannelMode {
    var accessibilityTitle: String {
        switch self {
        case .linked:
            localized("Linked")
        case .stereo:
            localized("Separate left and right")
        }
    }
}

private struct EditorTab: View {
    @Binding var draftProfile: EQProfile
    var sampleRate: Double
    var draftEditGeneration: Int
    @State private var editChannel = EQEditChannel.left
    @State private var analysis: EQAnalysisSnapshot?
    @State private var lastRequestedAnalysisSignature: EQAnalysisSignature?

    var body: some View {
        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                SettingRow(title: localized("Channels")) {
                    Picker(localized("Channels"), selection: Binding(
                        get: { draftProfile.channelMode },
                        set: { setChannelMode($0) }
                    )) {
                        Text(localized("Linked")).tag(EQChannelMode.linked)
                        Text(localized("Separate L/R")).tag(EQChannelMode.stereo)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 230)
                    .accessibilityLabel(Text(localized("Channels")))
                    .accessibilityValue(Text(draftProfile.channelMode.accessibilityTitle))
                    .accessibilityHint(Text(localized("Chooses whether channels share one EQ or use separate left and right settings")))
                }

                if draftProfile.channelMode == .stereo {
                    SettingRow(title: localized("Editing")) {
                        Picker(localized("Editing"), selection: $editChannel) {
                            ForEach(EQEditChannel.allCases) { channel in
                                Text(channel.title).tag(channel)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(maxWidth: 160)
                        .accessibilityLabel(Text(localized("Editing channel")))
                        .accessibilityValue(Text(editChannel.title))
                        .accessibilityHint(Text(localized("Chooses which stereo channel is being edited")))
                    }
                }

                SliderRow(
                    title: localized("Preamp"),
                    value: activePreampBinding,
                    range: -24...12,
                    validationRange: ProfilePersistence.preampRange,
                    step: 0.1,
                    suffix: "dB"
                )
                .id("preamp:\(activeEditContextID)")

                SettingRow(title: localized("Bypass")) {
                    Toggle(localized("Bypass"), isOn: $draftProfile.isBypassed)
                        .labelsHidden()
                        .accessibilityLabel(Text(localized("Bypass")))
                        .accessibilityValue(Text(draftProfile.isBypassed ? localized("On") : localized("Off")))
                        .accessibilityHint(Text(localized("Turns equalizer processing off without changing settings")))
                }

                if let analysis = currentAnalysis {
                    HeadroomRow(
                        profile: $draftProfile,
                        recommendedPreampDB: analysis.recommendedPreampDB
                    )
                } else {
                    PendingHeadroomRow()
                }
            }
            .cardPanel(padding: 16)

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(localized("Frequency Response"))
                        .font(.headline)
                    Spacer()
                    if draftProfile.channelMode == .stereo {
                        GraphLegendItem(color: .blue, title: localized("Left"))
                        GraphLegendItem(color: .orange, title: localized("Right"))
                    }
                }
                if let analysis = currentAnalysis {
                    FrequencyResponseGraph(analysis: analysis)
                        .frame(height: 165)
                        .accessibilityLabel(Text(localized("Frequency response graph")))
                        .accessibilityValue(Text(analysis.accessibilitySummary))
                        .accessibilityHint(Text(localized("Shows the estimated gain curve from 20 Hz to \(localizedFrequency(analysis.maximumUsableFrequency))")))
                    if let inactiveFilterSummary = analysis.inactiveFilterSummary {
                        Label(inactiveFilterSummary, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                } else {
                    VStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(localized("Analyzing frequency response…"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 165)
                    .accessibilityElement(children: .combine)
                }
            }
            .cardPanel(padding: 16)

            switch draftProfile.mode {
            case .parametric:
                ParametricFilterEditor(filters: activeFiltersBinding)
                    .id("parametric:\(activeEditContextID)")
            case .graphic10, .graphic31:
                GraphicFilterEditor(filters: activeFiltersBinding)
                    .id("graphic:\(activeEditContextID)")
                    .cardPanel(padding: 16)
            case .convolution:
                if case .impulseResponse(let source) = activeConvolutionSource {
                    ImportedImpulseResponseEditor(source: source)
                        .id("impulse:\(activeEditContextID)")
                        .cardPanel(padding: 16)
                } else {
                    MagnitudeCurveEditor(points: activeMagnitudePointsBinding)
                        .id("curve:\(activeEditContextID)")
                        .cardPanel(padding: 16)
                }
            }

        }
        .task(id: analysisSignature) {
            await refreshAnalysis()
        }
    }

    private var analysisSignature: EQAnalysisSignature {
        EQAnalysisSignature(profile: draftProfile, sampleRate: sampleRate)
    }

    // The most recent analysis, even while a newer one is still computing. Swapping in a
    // placeholder on every slider tick would flicker and break the curve animation.
    private var currentAnalysis: EQAnalysisSnapshot? {
        analysis
    }

    private func refreshAnalysis() async {
        let profile = draftProfile
        let sampleRate = sampleRate
        let signature = EQAnalysisSignature(profile: profile, sampleRate: sampleRate)
        guard analysis?.signature != signature else {
            return
        }
        if let updatedAnalysis = analysis?.updatingPreamp(
            profile: profile,
            sampleRate: sampleRate
        ) {
            lastRequestedAnalysisSignature = signature
            analysis = updatedAnalysis
            return
        }

        let previousSignature = lastRequestedAnalysisSignature ?? analysis?.signature
        lastRequestedAnalysisSignature = signature
        let shouldDebounce = previousSignature?.mode == signature.mode
            && previousSignature?.channelMode == signature.channelMode

        do {
            if shouldDebounce {
                try await Task.sleep(for: .milliseconds(50))
            }
            let nextAnalysis = try await EQAnalysisSnapshot.analyze(
                profile: profile,
                sampleRate: sampleRate
            )
            try Task.checkCancellation()

            guard analysisSignature == nextAnalysis.signature else {
                return
            }
            analysis = nextAnalysis
        } catch {
            return
        }
    }

    private var activePreampBinding: Binding<Double> {
        switch (draftProfile.channelMode, editChannel) {
        case (.stereo, .left):
            $draftProfile.leftPreampDB
        case (.stereo, .right):
            $draftProfile.rightPreampDB
        default:
            $draftProfile.preampDB
        }
    }

    private var activeFiltersBinding: Binding<[EQFilter]> {
        switch (draftProfile.channelMode, editChannel) {
        case (.stereo, .left):
            $draftProfile.leftFilters
        case (.stereo, .right):
            $draftProfile.rightFilters
        default:
            $draftProfile.filters
        }
    }

    private var activeMagnitudePointsBinding: Binding<[EQMagnitudePoint]> {
        let source: Binding<EQConvolutionSource?>
        switch (draftProfile.channelMode, editChannel) {
        case (.stereo, .left):
            source = $draftProfile.leftConvolution
        case (.stereo, .right):
            source = $draftProfile.rightConvolution
        default:
            source = $draftProfile.convolution
        }
        return Binding(
            get: {
                guard case .magnitudeCurve(let curve) = source.wrappedValue else {
                    return []
                }
                return curve.points
            },
            set: { points in
                let version: UInt16
                if case .magnitudeCurve(let curve) = source.wrappedValue {
                    version = curve.synthesisVersion
                } else {
                    version = MinimumPhaseFIRCompiler.synthesisVersion
                }
                source.wrappedValue = .magnitudeCurve(MagnitudeCurveSource(
                    synthesisVersion: version,
                    points: points
                ))
            }
        )
    }

    private var activeConvolutionSource: EQConvolutionSource? {
        switch (draftProfile.channelMode, editChannel) {
        case (.stereo, .left):
            draftProfile.leftConvolution
        case (.stereo, .right):
            draftProfile.rightConvolution
        default:
            draftProfile.convolution
        }
    }

    private var activeEditContextID: String {
        let channel = draftProfile.channelMode == .stereo ? editChannel.rawValue : "linked"
        return "\(draftProfile.id.uuidString):\(channel):\(draftEditGeneration)"
    }

    private func setChannelMode(_ mode: EQChannelMode) {
        guard mode != draftProfile.channelMode else {
            return
        }
        draftProfile = draftProfile.convertedToChannelMode(mode, editedChannel: editChannel)
        if mode == .stereo {
            editChannel = .left
        }
    }
}

// Whole-profile conversion used by the editor's channel switch.
extension EQProfile {
    func convertedToChannelMode(
        _ mode: EQChannelMode,
        editedChannel: EQEditChannel
    ) -> EQProfile {
        var converted = self
        switch mode {
        case .linked:
            let useRight = editedChannel == .right
            converted.filters = useRight ? rightFilters : leftFilters
            converted.preampDB = useRight ? rightPreampDB : leftPreampDB
            converted.convolution = useRight ? rightConvolution : leftConvolution
        case .stereo:
            converted.leftFilters = filters
            converted.rightFilters = filters
            converted.leftPreampDB = preampDB
            converted.rightPreampDB = preampDB
            converted.leftConvolution = convolution
            converted.rightConvolution = convolution
        }
        converted.channelMode = mode
        return converted
    }
}

// Footer action button. A custom style is the only way to make the disabled state less faint than
// the system default (which can't be lightened on a native `.disabled()` button), and the flatter
// look reads more like a precise tool than a consumer app.
private struct ToolbarButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        ToolbarButtonLabel(configuration: configuration, prominent: prominent)
    }

    private struct ToolbarButtonLabel: View {
        let configuration: ButtonStyleConfiguration
        let prominent: Bool
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
            return configuration.label
                .font(.body)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(minHeight: 30)
                .foregroundStyle(prominent ? Color.white : Color.primary)
                .background(fillColor(pressed: configuration.isPressed), in: shape)
                .overlay { shape.stroke(Color.primary.opacity(prominent ? 0 : 0.14), lineWidth: 1) }
                .opacity(isEnabled ? 1 : 0.5)
                .contentShape(shape)
        }

        private func fillColor(pressed: Bool) -> Color {
            if prominent {
                return Color.accentColor.opacity(pressed ? 0.82 : 1)
            }
            return Color.primary.opacity(pressed ? 0.14 : 0.07)
        }
    }
}

private struct ApplyBar: View {
    var hasUnsavedDraft: Bool
    var currentOutputUID: String
    var isPreviewing: Bool
    var isRunning: Bool
    var programmeComparison: EQProgrammeComparisonSnapshot
    var isReadOnly: Bool
    var onApply: () -> Void
    var onRevert: () -> Void
    var onPreview: () -> Void
    var onStopPreview: () -> Void
    var onStartProgrammeComparison: () -> Void
    var onSelectProgrammeComparison: (EQProgrammeComparisonSelection) -> Void
    var onStopProgrammeComparison: () -> Void
    var onUseForCurrentOutput: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsAppliedConfirmation = false
    @State private var appliedConfirmationTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(localized("Programme-loudness A/B"))
                        .font(.caption.weight(.semibold))
                    Text(comparisonDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if programmeComparison.isActive {
                    Picker(
                        localized("A/B branch"),
                        selection: Binding(
                            get: { programmeComparison.selection },
                            set: { selection in
                                onSelectProgrammeComparison(selection)
                            }
                        )
                    ) {
                        Text(localized("A · EQ"))
                            .tag(EQProgrammeComparisonSelection.equalized)
                        Text(localized("B · Filters off"))
                            .tag(EQProgrammeComparisonSelection.filtersOff)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 210)

                    Button(localized("Stop A/B")) {
                        onStopProgrammeComparison()
                    }
                    .buttonStyle(ToolbarButtonStyle())
                } else {
                    Button(localized("Start A/B")) {
                        onStartProgrammeComparison()
                    }
                    .disabled(isReadOnly || isPreviewing || !isRunning)
                    .buttonStyle(ToolbarButtonStyle())
                    .help(localized("Compares the draft EQ with its filters disabled while preserving the same preamp."))
                }
            }

            Divider()

            HStack {
                Group {
                    if hasUnsavedDraft {
                        Text(localized("Unsaved changes"))
                            .foregroundStyle(.secondary)
                    } else if showsAppliedConfirmation {
                        Label(localized("Applied"), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Color(nsColor: .systemGreen))
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    } else {
                        Text(localized("All changes saved"))
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption.weight(.medium))
                .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: showsAppliedConfirmation)
                .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: hasUnsavedDraft)
                .accessibilityLabel(Text(localized("Profile edit state")))
                .accessibilityValue(Text(hasUnsavedDraft ? localized("Unsaved changes") : localized("All changes saved")))
                Spacer()
                Button(localized("Revert")) {
                    onRevert()
                }
                .disabled(!hasUnsavedDraft || programmeComparison.isActive)
                .buttonStyle(ToolbarButtonStyle())

                Button(localized("Apply")) {
                    onApply()
                    flashAppliedConfirmation()
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(isReadOnly || !hasUnsavedDraft || programmeComparison.isActive)
                .buttonStyle(ToolbarButtonStyle(prominent: true))

                Button(isPreviewing ? localized("Stop Preview") : localized("Preview")) {
                    isPreviewing ? onStopPreview() : onPreview()
                }
                .disabled((isReadOnly && !isPreviewing) || programmeComparison.isActive)
                .buttonStyle(ToolbarButtonStyle())
                .accessibilityValue(Text(isPreviewing ? localized("Previewing") : localized("Not previewing")))

                Button(localized("Use for This Output")) {
                    onUseForCurrentOutput()
                }
                .disabled(
                    isReadOnly
                        || currentOutputUID.isEmpty
                        || programmeComparison.isActive
                )
                .buttonStyle(ToolbarButtonStyle())
                .accessibilityHint(Text(currentOutputUID.isEmpty ? localized("No current output is available") : localized("Maps the selected profile to the current output device")))
            }
        }
    }

    private func flashAppliedConfirmation() {
        appliedConfirmationTask?.cancel()
        showsAppliedConfirmation = true
        appliedConfirmationTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else {
                return
            }
            showsAppliedConfirmation = false
        }
    }

    private var comparisonDescription: String {
        guard programmeComparison.isActive else {
            return localized("Compare the draft EQ with filters off. Preamp stays enabled in both.")
        }
        guard programmeComparison.isReady else {
            return localized("Measuring the current programme…")
        }
        if programmeComparison.equalizedAttenuationDB < -0.05 {
            return localized(
                "Matched · EQ \(localizedDecibels(programmeComparison.equalizedAttenuationDB))"
            )
        }
        if programmeComparison.filtersOffAttenuationDB < -0.05 {
            return localized(
                "Matched · Filters off \(localizedDecibels(programmeComparison.filtersOffAttenuationDB))"
            )
        }
        return localized("Matched · no level adjustment needed")
    }
}

private struct HeadroomRow: View {
    @Binding var profile: EQProfile
    var recommendedPreampDB: Double

    var body: some View {
        let needsHeadroom = recommendedPreampDB < activePreamp - 0.1
        let adjustedProfile = profileApplyingRecommendedHeadroom(
            profile,
            recommendedPreampDB: recommendedPreampDB
        )
        let status = if !needsHeadroom {
            localized("OK")
        } else if adjustedProfile == nil {
            localized("Required headroom exceeds the profile limit")
        } else {
            localized("Recommend \(localizedDecibels(recommendedPreampDB))")
        }
        HStack {
            Text(localized("Headroom"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 88, alignment: .leading)
            Text(status)
                .font(.caption.monospacedDigit())
                .foregroundStyle(needsHeadroom ? Color.orange : Color.secondary)
                .accessibilityLabel(Text(localized("Headroom")))
                .accessibilityValue(Text(status))
            Spacer()
            Button(localized("Use Recommended")) {
                if let adjustedProfile {
                    profile = adjustedProfile
                }
            }
            .disabled(!needsHeadroom || adjustedProfile == nil)
            .controlSize(.large)
            .accessibilityHint(Text(localized("Applies the recommended preamp to avoid clipping")))
        }
    }

    private var activePreamp: Double {
        switch profile.channelMode {
        case .linked:
            profile.preampDB
        case .stereo:
            max(profile.leftPreampDB, profile.rightPreampDB)
        }
    }

}

func profileApplyingRecommendedHeadroom(
    _ profile: EQProfile,
    recommendedPreampDB: Double
) -> EQProfile? {
    let activePreamp = switch profile.channelMode {
    case .linked:
        profile.preampDB
    case .stereo:
        max(profile.leftPreampDB, profile.rightPreampDB)
    }
    let attenuation = max(activePreamp - recommendedPreampDB, 0)
    var adjusted = profile

    switch adjusted.channelMode {
    case .linked:
        adjusted.preampDB -= attenuation
        guard ProfilePersistence.preampRange.contains(adjusted.preampDB) else {
            return nil
        }
    case .stereo:
        adjusted.leftPreampDB -= attenuation
        adjusted.rightPreampDB -= attenuation
        guard ProfilePersistence.preampRange.contains(adjusted.leftPreampDB),
              ProfilePersistence.preampRange.contains(adjusted.rightPreampDB) else {
            return nil
        }
    }
    return adjusted
}

private struct PendingHeadroomRow: View {
    var body: some View {
        HStack {
            Text(localized("Headroom"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 88, alignment: .leading)
            ProgressView()
                .controlSize(.small)
            Text(localized("Analyzing…"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }
}

private struct FrequencyResponseGraph: View {
    var analysis: EQAnalysisSnapshot

    var body: some View {
        Canvas { context, size in
            let bounds = CGRect(origin: .zero, size: size)
            let plotRect = bounds.insetBy(dx: 38, dy: 18).offsetBy(dx: 4, dy: -3)
            context.fill(Path(bounds), with: .color(Color(nsColor: .controlBackgroundColor).opacity(0.55)))
            drawGrid(context: context, rect: plotRect)
            drawAxisLabels(context: context, rect: plotRect, bounds: bounds)

        }
        .overlay {
            ZStack {
                switch analysis.channelMode {
                case .linked:
                    curve(analysis.linkedPoints, color: .accentColor)
                case .stereo:
                    curve(analysis.leftPoints, color: .blue)
                    curve(analysis.rightPoints, color: .orange)
                }
            }
            .padding(Self.plotInsets)
            .animation(reduceMotion ? nil : .smooth(duration: 0.28), value: analysis)
        }
        .clipShape(.rect(cornerRadius: 14))
        .accessibilityElement(children: .ignore)
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Mirrors the Canvas plot rect (insetBy 38/18, offsetBy 4/-3) so the shapes line up with the grid.
    private static let plotInsets = EdgeInsets(top: 15, leading: 42, bottom: 21, trailing: 34)

    private func curve(_ points: [FrequencyResponsePoint], color: Color) -> some View {
        ResponseCurveShape(
            frequencies: points.map(\.frequency),
            magnitudes: AnimatableMagnitudes(values: points.map(\.magnitudeDB)),
            maximumFrequency: analysis.maximumUsableFrequency
        )
        .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineJoin: .round))
    }

    private func drawGrid(context: GraphicsContext, rect: CGRect) {
        var path = Path()
        for db in [-24.0, -12.0, -6.0, 0.0, 6.0, 12.0] {
            let y = yPosition(for: db, in: rect)
            path.move(to: CGPoint(x: rect.minX, y: y))
            path.addLine(to: CGPoint(x: rect.maxX, y: y))
        }
        for frequency in axisFrequencies {
            let x = xPosition(for: frequency, in: rect)
            path.move(to: CGPoint(x: x, y: rect.minY))
            path.addLine(to: CGPoint(x: x, y: rect.maxY))
        }
        context.stroke(path, with: .color(.secondary.opacity(0.35)), lineWidth: 1)

        var zero = Path()
        let zeroY = yPosition(for: 0, in: rect)
        zero.move(to: CGPoint(x: rect.minX, y: zeroY))
        zero.addLine(to: CGPoint(x: rect.maxX, y: zeroY))
        context.stroke(zero, with: .color(.secondary.opacity(0.7)), lineWidth: 1.5)
    }

    private func drawAxisLabels(context: GraphicsContext, rect: CGRect, bounds: CGRect) {
        for db in [12.0, 6.0, 0.0, -6.0, -12.0, -24.0] {
            context.draw(
                Text(db.dbAxisLabel)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary),
                at: CGPoint(x: bounds.minX + 17, y: yPosition(for: db, in: rect)),
                anchor: .center
            )
        }

        for frequency in axisFrequencies {
            context.draw(
                Text(axisLabel(for: frequency))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary),
                at: CGPoint(x: xPosition(for: frequency, in: rect), y: bounds.maxY - 10),
                anchor: .center
            )
        }
    }

    private func xPosition(for frequency: Double, in rect: CGRect) -> CGFloat {
        let lower = log10(20.0)
        let upper = log10(max(analysis.maximumUsableFrequency, 20.000_1))
        let fraction = (log10(frequency) - lower) / (upper - lower)
        return rect.minX + rect.width * fraction
    }

    private var axisFrequencies: [Double] {
        let maximum = analysis.maximumUsableFrequency
        var frequencies = [20.0, 100.0, 1_000.0, 10_000.0, 20_000.0]
            .filter { $0 <= maximum }
        if frequencies.last != maximum {
            frequencies.append(maximum)
        }
        return frequencies
    }

    private func axisLabel(for frequency: Double) -> String {
        if frequency == analysis.maximumUsableFrequency,
           frequency != EQRouteFrequencyPolicy.maximumProfileFrequency {
            return frequency.frequencyLabel
        }
        return frequency.axisFrequencyLabel
    }

    private func yPosition(for magnitudeDB: Double, in rect: CGRect) -> CGFloat {
        let minDB = -24.0
        let maxDB = 12.0
        let fraction = 1 - ((magnitudeDB - minDB) / (maxDB - minDB))
        return rect.minY + rect.height * fraction
    }
}

// Interpolates a magnitude array so the response curve morphs between analyses.
struct AnimatableMagnitudes: VectorArithmetic {
    var values: [Double]

    static var zero: AnimatableMagnitudes { AnimatableMagnitudes(values: []) }

    var magnitudeSquared: Double {
        values.reduce(0) { $0 + $1 * $1 }
    }

    mutating func scale(by rhs: Double) {
        values = values.map { $0 * rhs }
    }

    static func + (lhs: Self, rhs: Self) -> Self {
        combine(lhs, rhs, +)
    }

    static func - (lhs: Self, rhs: Self) -> Self {
        combine(lhs, rhs, -)
    }

    // Point counts only differ when the usable bandwidth changes; pad the shorter side with the
    // other's values so the transition stays a valid curve instead of collapsing.
    private static func combine(_ lhs: Self, _ rhs: Self, _ operation: (Double, Double) -> Double) -> Self {
        let count = max(lhs.values.count, rhs.values.count)
        var values = [Double](repeating: 0, count: count)
        for index in 0..<count {
            let left = index < lhs.values.count ? lhs.values[index] : (rhs.values.indices.contains(index) ? rhs.values[index] : 0)
            let right = index < rhs.values.count ? rhs.values[index] : (lhs.values.indices.contains(index) ? lhs.values[index] : 0)
            values[index] = operation(left, right)
        }
        return AnimatableMagnitudes(values: values)
    }
}

private struct ResponseCurveShape: Shape {
    var frequencies: [Double]
    var magnitudes: AnimatableMagnitudes
    var maximumFrequency: Double

    var animatableData: AnimatableMagnitudes {
        get { magnitudes }
        set { magnitudes = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let count = min(frequencies.count, magnitudes.values.count)
        guard count > 1 else {
            return Path()
        }
        let minDB = -24.0
        let maxDB = 12.0
        let lower = log10(20.0)
        let upper = log10(max(maximumFrequency, 20.000_1))
        var path = Path()
        for index in 0..<count {
            let fraction = (log10(frequencies[index]) - lower) / (upper - lower)
            let magnitude = min(max(magnitudes.values[index], minDB), maxDB)
            let position = CGPoint(
                x: rect.minX + rect.width * fraction,
                y: rect.minY + rect.height * (1 - ((magnitude - minDB) / (maxDB - minDB)))
            )
            index == 0 ? path.move(to: position) : path.addLine(to: position)
        }
        return path
    }
}

private struct MagnitudeCurveEditor: View {
    @Binding var points: [EQMagnitudePoint]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(localized("Target Response"))
                    .font(.headline)
                Spacer()
                Button {
                    addPoint()
                } label: {
                    Label(localized("Add Point"), systemImage: "plus")
                        .frame(minHeight: 28)
                        .contentShape(.rect)
                }
                .controlSize(.large)
                .accessibilityHint(Text(localized("Adds a magnitude point in the largest frequency gap")))
            }

            Text(localized("GlassEQ interpolates these points in log-frequency space and compiles a 16,384-tap minimum-phase filter when you apply the profile."))
                .font(.caption)
                .foregroundStyle(.secondary)

            LazyVStack(spacing: 6) {
                ForEach($points) { $point in
                    HStack(spacing: 10) {
                        EditableValueText(
                            title: localized("Frequency"),
                            value: $point.frequency,
                            range: ProfilePersistence.frequencyRange,
                            display: point.frequency.frequencyLabel,
                            width: 72
                        )
                        Slider(
                            value: Binding(
                                get: { point.gainDB },
                                set: { point.gainDB = quantized($0, step: 0.1) }
                            ),
                            in: -24...12
                        )
                        .frame(maxWidth: 640)
                        .accessibilityLabel(Text(localized("Gain at \(point.frequency.frequencyLabel)")))
                        .accessibilityValue(Text(point.gainDB.dbLabel))
                        EditableValueText(
                            title: localized("Gain"),
                            value: $point.gainDB,
                            range: ProfilePersistence.gainRange,
                            display: point.gainDB.dbLabel,
                            width: 60
                        )
                        Button(role: .destructive) {
                            points.removeAll { $0.id == point.id }
                        } label: {
                            Image(systemName: "trash")
                                .frame(width: 24, height: 24)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.borderless)
                        .disabled(points.count <= 2)
                        .accessibilityLabel(Text(localized("Delete response point")))
                        .accessibilityHint(Text(localized("Removes this magnitude point")))
                    }
                    .accessibilityElement(children: .contain)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func addPoint() {
        let sorted = points.sorted { $0.frequency < $1.frequency }
        let candidates = Set([20.0, 20_000.0] + sorted.map(\.frequency))
            .filter { ProfilePersistence.frequencyRange.contains($0) }
            .sorted()
        let widestGap = zip(candidates, candidates.dropFirst()).max { lhs, rhs in
            log(lhs.1 / lhs.0) < log(rhs.1 / rhs.0)
        }
        let frequency = widestGap.map { sqrt($0.0 * $0.1) } ?? 1_000
        let gain = MinimumPhaseFIRCompiler.interpolatedGainDB(
            frequency: frequency,
            points: sorted
        )
        points = (sorted + [EQMagnitudePoint(frequency: frequency, gainDB: gain)])
            .sorted { $0.frequency < $1.frequency }
    }
}

private struct ImportedImpulseResponseEditor: View {
    var source: ImpulseResponseSource

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(localized("Imported Impulse Response"), systemImage: "waveform")
                .font(.headline)
            LabeledContent(
                localized("Length"),
                value: localized("\(source.samples.count) taps")
            )
            LabeledContent(
                localized("Sample rate"),
                value: source.sampleRate.frequencyLabel
            )
            Text(localized("GlassEQ preserves the file's phase and samples. To replace it, import another WAV file."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct GraphicFilterEditor: View {
    @Binding var filters: [EQFilter]

    var body: some View {
        VStack(spacing: 10) {
            ForEach($filters) { $filter in
                HStack {
                    Text(filter.frequency.frequencyLabel)
                        .font(.caption.monospacedDigit())
                        .frame(width: 64, alignment: .trailing)
                    Slider(
                        value: Binding(
                            get: { filter.gainDB },
                            set: { filter.gainDB = quantized($0, step: 0.1) }
                        ),
                        in: -12...12
                    )
                        .frame(maxWidth: 640)
                        .accessibilityLabel(Text(localized("Gain at \(filter.frequency.frequencyLabel)")))
                        .accessibilityValue(Text(filter.gainDB.dbLabel))
                        .accessibilityHint(Text(localized("Adjusts this graphic EQ band")))
                    EditableValueText(
                        title: localized("Gain"),
                        value: $filter.gainDB,
                        range: ProfilePersistence.gainRange,
                        display: filter.gainDB.dbLabel,
                        width: 56
                    )
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text(localized("Graphic filter row")))
                .accessibilityValue(Text(localized("\(filter.frequency.frequencyLabel), \(filter.gainDB.dbLabel)")))
            }
        }
        .padding(.vertical, 4)
    }
}

private struct ParametricFilterEditor: View {
    @Binding var filters: [EQFilter]
    @State private var selectedFilterID: UUID?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(localized("Filters"))
                        .font(.headline)
                    Button {
                        let filter = EQFilter(kind: .peak, frequency: 1_000, gainDB: 0, q: 1)
                        filters.append(filter)
                        selectedFilterID = filter.id
                    } label: {
                        Label(localized("Add Filter"), systemImage: "plus")
                            .frame(minHeight: 28)
                            .contentShape(.rect)
                    }
                    .controlSize(.large)
                    .accessibilityHint(Text(localized("Adds a new parametric filter and selects it")))
                    Spacer()
                }

                FilterListHeader()

                LazyVStack(spacing: 4) {
                    ForEach(filters) { filter in
                        CompactFilterRow(
                            filter: filter,
                            isSelected: filter.id == effectiveSelectedFilterID
                        ) {
                            selectedFilterID = filter.id
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(minWidth: 260, idealWidth: 320, maxWidth: 420)
            .cardPanel(padding: 16)

            if let binding = selectedFilterBinding {
                ParametricFilterInspector(
                    filter: binding,
                    onDelete: {
                        let id = binding.wrappedValue.id
                        filters.removeAll { $0.id == id }
                        selectedFilterID = filters.first?.id
                    }
                )
                .id(binding.wrappedValue.id)
                .frame(minWidth: 260, maxWidth: .infinity, alignment: .topLeading)
            } else {
                ContentUnavailableView(localized("No Filter Selected"), systemImage: "slider.horizontal.3")
                    .cardPanel(padding: 16)
                    .frame(maxWidth: .infinity, minHeight: 150)
            }
        }
        .onChange(of: filters.map(\.id)) { _, _ in
            selectedFilterID = effectiveSelectedFilterID
        }
    }

    private var effectiveSelectedFilterID: UUID? {
        if let selectedFilterID,
           filters.contains(where: { $0.id == selectedFilterID }) {
            return selectedFilterID
        }
        return filters.first?.id
    }

    private var selectedFilterBinding: Binding<EQFilter>? {
        guard let id = effectiveSelectedFilterID,
              let index = filters.firstIndex(where: { $0.id == id }) else {
            return nil
        }

        return Binding(
            get: { filters[index] },
            set: { filters[index] = $0 }
        )
    }
}

private struct FilterListHeader: View {
    var body: some View {
        HStack {
            Text("")
                .frame(width: 20)
            Text(localized("Type"))
                .frame(width: 54, alignment: .leading)
            Text(localized("Freq"))
                .frame(width: 64, alignment: .trailing)
            Text(localized("Gain"))
                .frame(width: 64, alignment: .trailing)
            Text(localized("Q"))
                .frame(width: 46, alignment: .trailing)
            Spacer()
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
    }
}

private struct CompactFilterRow: View {
    var filter: EQFilter
    var isSelected: Bool
    var onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack {
                Image(systemName: filter.isEnabled ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(filter.isEnabled ? Color.accentColor : Color.secondary)
                    .frame(width: 20)
                Text(filter.kind.shortTitle)
                    .frame(width: 54, alignment: .leading)
                Text(filter.frequency.frequencyLabel)
                    .font(.caption.monospacedDigit())
                    .frame(width: 64, alignment: .trailing)
                Text(filter.gainDB.dbLabel)
                    .font(.caption.monospacedDigit())
                    .frame(width: 64, alignment: .trailing)
                Text(qLabel)
                    .font(.caption.monospacedDigit())
                    .frame(width: 46, alignment: .trailing)
                Spacer()
            }
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .background(
                isSelected
                    ? Color.accentColor.opacity(0.22)
                    : Color.primary.opacity(0.035),
                in: .rect(cornerRadius: 8)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.accentColor.opacity(0.55) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel(Text(localized("Filter \(filter.kind.title)")))
        .accessibilityValue(Text(accessibilityValue))
        .accessibilityHint(Text(localized("Selects this filter for editing")))
    }

    private var qLabel: String {
        localizedDecimal(filter.q, minimumFractionDigits: 2, maximumFractionDigits: 2)
    }

    private var accessibilityValue: String {
        let state = filter.isEnabled ? localized("Enabled") : localized("Disabled")
        let selection = isSelected ? localized("Selected") : localized("Not selected")
        return localized("\(state), \(selection), \(filter.frequency.frequencyLabel), \(filter.gainDB.dbLabel), Q \(qLabel)")
    }
}

private struct ParametricFilterInspector: View {
    @Binding var filter: EQFilter
    var onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Text(localized("Selected Filter"))
                    .font(.headline)
                Toggle(localized("Enabled"), isOn: $filter.isEnabled)
                    .toggleStyle(.switch)
                    .accessibilityLabel(Text(localized("Filter enabled")))
                    .accessibilityValue(Text(filter.isEnabled ? localized("On") : localized("Off")))
                    .accessibilityHint(Text(localized("Includes or bypasses this filter")))
                Spacer()
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                        .frame(width: 28, height: 28)
                        .contentShape(.rect)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text(localized("Delete filter")))
                .accessibilityHint(Text(localized("Removes the selected filter")))
            }

            HStack {
                Text(localized("Type"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 88, alignment: .leading)
                Picker(localized("Type"), selection: $filter.kind) {
                    ForEach(FilterKind.allCases, id: \.self) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 260)
                .accessibilityLabel(Text(localized("Filter type")))
                .accessibilityValue(Text(filter.kind.title))
                .accessibilityHint(Text(localized("Changes the selected filter type")))
            }

            SliderRow(
                title: localized("Frequency"),
                value: $filter.frequency,
                range: 20...20_000,
                validationRange: ProfilePersistence.frequencyRange,
                step: 1,
                suffix: "Hz",
                scale: .logarithmic
            )
            SliderRow(
                title: localized("Gain"),
                value: $filter.gainDB,
                range: -24...24,
                validationRange: ProfilePersistence.gainRange,
                step: 0.1,
                suffix: "dB"
            )
            SliderRow(
                title: localized("Q"),
                value: $filter.q,
                range: 0.1...10,
                validationRange: ProfilePersistence.qRange,
                step: 0.01,
                suffix: ""
            )
        }
        .cardPanel(padding: 16)
    }
}

// Quantizes slider output in the binding instead of passing `step:` to Slider — stepped macOS
// sliders render a tick mark per step, which draws a dense line of dots under the track.
func quantized(_ value: Double, step: Double) -> Double {
    guard step > 0 else {
        return value
    }
    let scale = 1 / step
    return (value * scale).rounded() / scale
}

private enum SliderScale {
    case linear
    case logarithmic
}

private struct SliderRow: View {
    var title: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var validationRange: ClosedRange<Double>? = nil
    var step: Double
    var suffix: String
    var scale = SliderScale.linear

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 88, alignment: .leading)
            Slider(value: sliderValue, in: sliderRange)
                .frame(minWidth: 80)
                .frame(maxWidth: 640)
                .accessibilityLabel(Text(title))
                .accessibilityValue(Text(label))
                .accessibilityHint(Text(localized("Adjusts \(title.lowercased())")))
            EditableValueText(
                title: title,
                value: $value,
                range: validationRange ?? range,
                display: label
            )
        }
    }

    private var sliderValue: Binding<Double> {
        switch scale {
        case .linear:
            Binding(
                get: { value },
                set: { value = quantized($0, step: step) }
            )
        case .logarithmic:
            Binding(
                get: { log10(min(max(value, range.lowerBound), range.upperBound)) },
                set: {
                    let restored = min(max(pow(10, $0), range.lowerBound), range.upperBound)
                    value = quantized(restored, step: step)
                }
            )
        }
    }

    private var sliderRange: ClosedRange<Double> {
        switch scale {
        case .linear:
            range
        case .logarithmic:
            log10(range.lowerBound)...log10(range.upperBound)
        }
    }

    private var label: String {
        if suffix == "Hz" {
            return value.frequencyLabel
        }
        if suffix == "dB" {
            return value.dbLabel
        }
        return localizedDecimal(value, minimumFractionDigits: 2, maximumFractionDigits: 2)
    }
}

// Value readout that becomes a text field on click, so exact values can be typed instead of
// approximated by dragging the slider.
private struct EditableValueText: View {
    var title: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var display: String
    var width: CGFloat = 64

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isEditing = false
    @State private var editText = ""
    @State private var editSession = EditableValueEditSession()
    @FocusState private var isFocused: Bool

    var body: some View {
        Group {
            if isEditing {
                TextField(title, text: $editText)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption.monospacedDigit())
                    .multilineTextAlignment(.trailing)
                    .focused($isFocused)
                    .onAppear {
                        isFocused = true
                    }
                    .onSubmit(commit)
                    .onExitCommand(perform: cancel)
                    .onChange(of: editText) { _, text in
                        updateValue(from: text)
                    }
                    .onChange(of: value) { _, newValue in
                        guard isEditing,
                              editSession.valueChanged(newValue) else {
                            return
                        }
                        editText = editableNumberText(newValue)
                        isEditing = false
                    }
                    .onChange(of: isFocused) { _, focused in
                        if !focused {
                            commit()
                        }
                    }
            } else {
                Button {
                    editText = editableText
                    editSession.begin(value: value)
                    isEditing = true
                } label: {
                    Text(display)
                        .font(.caption.monospacedDigit())
                        .contentTransition(.numericText(value: value))
                        .animation(reduceMotion ? nil : .snappy(duration: 0.15), value: value)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(localized("Click to type a value"))
            }
        }
        .frame(width: width)
        .accessibilityLabel(Text(localized("\(title) value")))
        .accessibilityValue(Text(display))
        .accessibilityHint(Text(localized("Edits \(title.lowercased()) as text")))
    }

    private var editableText: String {
        editableNumberText(value)
    }

    private func commit() {
        guard isEditing else {
            return
        }
        guard updateValue(from: editText) else {
            cancel()
            return
        }
        editSession.finish()
        isEditing = false
    }

    private func cancel() {
        if let originalValue = editSession.cancel() {
            value = originalValue
        }
        isEditing = false
    }

    @discardableResult
    private func updateValue(from text: String) -> Bool {
        guard isEditing,
              let parsed = clampedEditableNumber(text, range: range) else {
            return false
        }
        editSession.recordTextDrivenValue(parsed)
        value = parsed
        return true
    }
}

struct EditableValueEditSession: Equatable {
    private var originalValue: Double?
    private var textDrivenValue: Double?

    mutating func begin(value: Double) {
        originalValue = value
        textDrivenValue = nil
    }

    mutating func recordTextDrivenValue(_ value: Double) {
        textDrivenValue = value
    }

    mutating func valueChanged(_ value: Double) -> Bool {
        if textDrivenValue == value {
            textDrivenValue = nil
            return false
        }
        finish()
        return true
    }

    mutating func cancel() -> Double? {
        let value = originalValue
        finish()
        return value
    }

    mutating func finish() {
        originalValue = nil
        textDrivenValue = nil
    }
}

private struct OutputTab: View {
    var snapshot: SettingsSnapshot
    var isProfileStoreProtected: Bool
    var onUseForCurrentOutput: () -> Void
    var onSetFallback: () -> Void
    var onResetDiagnostics: () -> Void
    var onSetAggregateBufferMode: (SettingsAggregateBufferMode) -> Void
    var onRetryAutomaticAggregateBuffer: () -> Void
    var onRetryAudioEngine: () -> Void
    var onOpenPrivacySettings: () -> Void
    @State private var isShowingDiagnostics = false

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(localized("Current Output"))
                        .font(.headline)
                    Text(snapshot.currentOutputName)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .cardPanel(padding: 16)

                VStack(alignment: .leading, spacing: 10) {
                    Text(localized("Audio Buffer"))
                        .font(.headline)
                    Picker(
                        localized("Audio Buffer"),
                        selection: Binding(
                            get: { snapshot.aggregateBuffer.mode },
                            set: { onSetAggregateBufferMode($0) }
                        )
                    ) {
                        Text(localized("Automatic")).tag(SettingsAggregateBufferMode.automatic)
                        Text(localized("16 frames")).tag(SettingsAggregateBufferMode.frames16)
                        Text(localized("32 frames")).tag(SettingsAggregateBufferMode.frames32)
                        Text(localized("64 frames")).tag(SettingsAggregateBufferMode.frames64)
                    }
                    .labelsHidden()
                    .disabled(!snapshot.aggregateBuffer.isAvailable)

                    Text(aggregateBufferExplanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if snapshot.aggregateBuffer.mode == .automatic,
                       snapshot.aggregateBuffer.automaticFrameSize > 16 {
                        Button(localized("Retry 16 Frames")) {
                            onRetryAutomaticAggregateBuffer()
                        }
                        .controlSize(.large)
                    } else if let fixedFrameSize,
                              snapshot.currentOutputBufferFrameSize > fixedFrameSize {
                        Button(localized("Retry \(fixedFrameSize) Frames")) {
                            onSetAggregateBufferMode(snapshot.aggregateBuffer.mode)
                        }
                        .controlSize(.large)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .cardPanel(padding: 16)

                VStack(alignment: .leading, spacing: 10) {
                    Text(localized("Profile Mapping"))
                        .font(.headline)
                    LabeledContent(localized("Mapped Profile"), value: mappedProfileName)
                    HStack {
                        Button(localized("Use for This Output")) {
                            onUseForCurrentOutput()
                        }
                        .disabled(isProfileStoreProtected || snapshot.currentOutputUID.isEmpty)
                        .controlSize(.large)

                        Button(localized("Set as Fallback")) {
                            onSetFallback()
                        }
                        .disabled(isProfileStoreProtected)
                        .controlSize(.large)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .cardPanel(padding: 16)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)

            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(localized("Engine Status"))
                        .font(.headline)
                    LabeledContent(localized("Status"), value: statusSummary)
                    LabeledContent(localized("Mode"), value: routeModeSummary)
                    LabeledContent(localized("Current Output"), value: snapshot.currentOutputName)
                    LabeledContent(localized("Active Profile"), value: snapshot.activeProfileName)
                    LabeledContent(localized("Buffer"), value: bufferSummary)
                    LabeledContent(localized("Added Latency"), value: report.addedLatencyLabel)
                    LabeledContent(
                        localized("Underrun Events"),
                        value: snapshot.metrics.playbackUnderrunEvents == 0
                            ? localized("None")
                            : localizedInteger(snapshot.metrics.playbackUnderrunEvents)
                    )
                    Text(snapshot.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button(localized("Retry Audio Engine")) {
                            onRetryAudioEngine()
                        }
                        .controlSize(.large)

                        Button(localized("Open Privacy Settings")) {
                            onOpenPrivacySettings()
                        }
                        .controlSize(.large)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .cardPanel(padding: 16)

                VStack(alignment: .leading, spacing: 10) {
                    Text(localized("Stats for Nerds"))
                        .font(.headline)
                    Text(localized("Render timing percentiles, reliability counters, recovery history, and the Core Audio route behind this output."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        isShowingDiagnostics = true
                    } label: {
                        Label(localized("Show Stats"), systemImage: "waveform.path.ecg.rectangle")
                    }
                    .controlSize(.large)
                    .accessibilityHint(Text(localized("Opens detailed audio engine diagnostics")))
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .cardPanel(padding: 16)
                .sheet(isPresented: $isShowingDiagnostics) {
                    OutputDiagnosticsSheet(
                        report: report,
                        onReset: onResetDiagnostics
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var mappedProfileName: String {
        guard let profileID = snapshot.currentOutputMappedProfileID,
              let profile = snapshot.profiles.first(where: { $0.id == profileID }) else {
            return localized("Fallback")
        }
        return profile.name
    }

    private var aggregateBufferExplanation: String {
        guard snapshot.aggregateBuffer.isAvailable else {
            return localized("This route uses GlassEQ's compatibility audio path.")
        }
        if snapshot.aggregateBuffer.mode == .automatic {
            return localized(
                "Automatic uses the smallest buffer proven reliable for this device stream and sample rate. It is currently \(snapshot.aggregateBuffer.automaticFrameSize) frames."
            )
        }
        if let fixedFrameSize,
           snapshot.currentOutputBufferFrameSize > fixedFrameSize {
            return localized(
                "The fixed \(fixedFrameSize)-frame setting became unstable. GlassEQ is temporarily using \(snapshot.currentOutputBufferFrameSize) frames for this session."
            )
        }
        return localized(
            "A fixed buffer keeps this preference. GlassEQ may temporarily use a safer buffer if repeated deadline misses continue after a rebuild."
        )
    }

    private var fixedFrameSize: UInt32? {
        switch snapshot.aggregateBuffer.mode {
        case .automatic:
            nil
        case .frames16:
            16
        case .frames32:
            32
        case .frames64:
            64
        }
    }

    private var diagnostics: SettingsAudioDiagnosticsDTO {
        snapshot.metrics.diagnostics
    }

    private var statusSummary: String {
        switch diagnostics.status.health {
        case .stopped:
            return localized("Stopped")
        case .stable:
            return diagnostics.status.isUsingSaferBuffer
                ? localized("Stable, using safer buffer")
                : localized("Stable")
        case .recovering:
            return localized("Recovering")
        case .needsAttention:
            return localized("Needs attention")
        }
    }

    private var routeModeSummary: String {
        switch diagnostics.status.routeMode {
        case .unavailable:
            return localized("Unavailable")
        case .lowLatency:
            return localized("Low-latency path")
        case .compatibility:
            return localized("Compatibility path")
        case .headsetCompatibility:
            return localized("Headset compatibility path")
        }
    }

    private var bufferSummary: String {
        outputBufferSummary(
            aggregateBuffer: snapshot.aggregateBuffer,
            currentFrameSize: snapshot.currentOutputBufferFrameSize
        )
    }

    private var report: OutputDiagnosticsReport {
        OutputDiagnosticsReport(snapshot: snapshot)
    }

}

func outputBufferSummary(
    aggregateBuffer: SettingsAggregateBufferDTO,
    currentFrameSize: UInt32
) -> String {
    guard aggregateBuffer.isAvailable else {
        guard currentFrameSize > 0 else {
            return localized("Unavailable")
        }
        return localized("\(currentFrameSize) frames, compatibility path")
    }
    switch aggregateBuffer.mode {
    case .automatic:
        return localized(
            "Automatic, \(aggregateBuffer.automaticFrameSize) frames active"
        )
    case .frames16, .frames32, .frames64:
        let selected: UInt32 = switch aggregateBuffer.mode {
        case .automatic:
            aggregateBuffer.automaticFrameSize
        case .frames16:
            16
        case .frames32:
            32
        case .frames64:
            64
        }
        if currentFrameSize != selected {
            return localized(
                "\(selected) selected, \(currentFrameSize) frames active"
            )
        }
        return localized("\(selected) frames")
    }
}

private extension FilterKind {
    var title: String {
        switch self {
        case .peak:
            localized("Peak")
        case .lowShelf:
            localized("Low Shelf")
        case .highShelf:
            localized("High Shelf")
        case .highPass:
            localized("High Pass")
        case .lowPass:
            localized("Low Pass")
        }
    }

    var shortTitle: String {
        switch self {
        case .peak:
            localized("Peak")
        case .lowShelf:
            localized("Low")
        case .highShelf:
            localized("High")
        case .highPass:
            "HP"
        case .lowPass:
            "LP"
        }
    }
}

private extension Double {
    var dbLabel: String {
        localizedDecibels(self)
    }

    var frequencyLabel: String {
        localizedFrequency(self)
    }

    var axisFrequencyLabel: String {
        if self >= 1_000 {
            return localized("\(localizedDecimal(self / 1_000, minimumFractionDigits: 0, maximumFractionDigits: 0)) kHz")
        }
        return localized("\(localizedDecimal(self, minimumFractionDigits: 0, maximumFractionDigits: 0)) Hz")
    }

    var dbAxisLabel: String {
        localizedDecimal(self, minimumFractionDigits: 0, maximumFractionDigits: 0, signed: self > 0)
    }
}
