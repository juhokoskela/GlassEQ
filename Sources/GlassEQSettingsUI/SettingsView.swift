import AppKit
import GlassEQCore
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

private func localized(_ value: String.LocalizationValue) -> String {
    String(localized: value, bundle: settingsResourcesBundle)
}

private func localizedDecimal(
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

private func localizedInteger(_ value: Int) -> String {
    value.formatted(.number.locale(.autoupdatingCurrent))
}

private func localizedInteger(_ value: UInt32) -> String {
    UInt64(value).formatted(.number.locale(.autoupdatingCurrent))
}

private func localizedInteger(_ value: UInt64) -> String {
    value.formatted(.number.locale(.autoupdatingCurrent))
}

private func localizedDecibels(_ value: Double, fractionDigits: Int = 1) -> String {
    let number = localizedDecimal(
        value,
        minimumFractionDigits: fractionDigits,
        maximumFractionDigits: fractionDigits,
        signed: true
    )
    return localized("\(number) dB")
}

private func localizedFrequency(_ value: Double) -> String {
    if value >= 1_000 {
        let number = localizedDecimal(value / 1_000, minimumFractionDigits: 1, maximumFractionDigits: 1)
        return localized("\(number) kHz")
    }
    let number = localizedDecimal(value, minimumFractionDigits: 0, maximumFractionDigits: 0)
    return localized("\(number) Hz")
}

private func localizedFrameCount(_ value: Int) -> String {
    let number = localizedInteger(value)
    return value == 1 ? localized("\(number) frame") : localized("\(number) frames")
}

private func localizedFrameCount(_ value: UInt32) -> String {
    let number = localizedInteger(value)
    return value == 1 ? localized("\(number) frame") : localized("\(number) frames")
}

func settingsCanDeleteSelectedProfile(_ snapshot: SettingsSnapshot) -> Bool {
    !snapshot.profileStoreProtection.isProtected
        && snapshot.profiles.count > 1
        && !snapshot.isPreviewing
        && snapshot.selectedProfileID != snapshot.activeProfileID
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

private func localizedLatency(milliseconds: Double) -> String {
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

    public init(model: GlassEQSettingsViewModel) {
        self._model = Bindable(wrappedValue: model)
        _snapshot = State(initialValue: model.snapshot)
    }

    public var body: some View {
        HStack(spacing: 0) {
            ProfileSidebar(
                profiles: snapshot.profiles,
                mappedProfileID: snapshot.currentOutputMappedProfileID,
                selectedProfileID: snapshot.selectedProfileID,
                onSelect: selectProfile,
                onCreateGraphic31: createGraphic31Profile,
                onCreateGraphic10: createGraphic10Profile,
                onCreateParametric: createParametricProfile,
                onDuplicate: duplicateSelectedProfile,
                onDelete: deleteSelectedProfile,
                canDeleteSelectedProfile: canDeleteSelectedProfile,
                isReadOnly: isProfileStoreProtected
            )
                .frame(width: 260)

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
                onImport: importProfile,
                onPreview: previewDraft,
                onStopPreview: stopPreview,
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
                tab = EditorSection(requestedSection)
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
                tab = EditorSection(requestedSection)
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

    private func importProfile(format: ImportFormat, name: String, text: String) async -> Bool {
        let dispatchedSnapshot = snapshot
        let response = await model.perform(.importProfile(format: format, name: name, text: text))
        refreshSnapshotFromModel(afterCommandDispatchedFrom: dispatchedSnapshot)
        return response?.importSucceeded ?? false
    }

    private func previewDraft() {
        perform(.preview(snapshot.draftProfile))
    }

    private func stopPreview() {
        perform(.stopPreview)
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

    private func createGraphic31Profile() {
        perform(.createProfile(.graphic31))
    }

    private func createGraphic10Profile() {
        perform(.createProfile(.graphic10))
    }

    private func createParametricProfile() {
        perform(.createProfile(.parametric))
    }

    private func duplicateSelectedProfile() {
        perform(.duplicateProfile(snapshot.selectedProfileID))
    }

    private func deleteSelectedProfile() {
        perform(.deleteProfile(snapshot.selectedProfileID))
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
    }

    static func effectiveSampleRate(_ sampleRate: Double) -> Double {
        guard sampleRate.isFinite, sampleRate > 0 else {
            return defaultSampleRate
        }
        return sampleRate
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

    init(profile: EQProfile, sampleRate: Double) {
        let sampleRate = EQAnalysisSignature.effectiveSampleRate(sampleRate)
        self.signature = EQAnalysisSignature(profile: profile, sampleRate: sampleRate)
        self.channelMode = profile.channelMode
        self.recommendedPreampDB = EQProfileAnalysis.recommendedPreampDB(profile: profile, sampleRate: sampleRate)
        self.maximumUsableFrequency = EQRouteFrequencyPolicy.maximumUsableFrequency(sampleRate: sampleRate)
        self.inactiveEnabledFilterCount = EQRouteFrequencyPolicy.inactiveEnabledFilterCount(
            profile: profile,
            sampleRate: sampleRate
        )

        switch profile.channelMode {
        case .linked:
            self.linkedPoints = FrequencyResponse.points(
                for: profile.filters,
                preampDB: profile.preampDB,
                sampleRate: sampleRate
            )
            self.leftPoints = []
            self.rightPoints = []
        case .stereo:
            self.linkedPoints = []
            self.leftPoints = FrequencyResponse.points(
                for: profile.leftFilters,
                preampDB: profile.leftPreampDB,
                sampleRate: sampleRate
            )
            self.rightPoints = FrequencyResponse.points(
                for: profile.rightFilters,
                preampDB: profile.rightPreampDB,
                sampleRate: sampleRate
            )
        }
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
    var mappedProfileID: UUID?
    var selectedProfileID: UUID
    var onSelect: (UUID) -> Void
    var onCreateGraphic31: () -> Void
    var onCreateGraphic10: () -> Void
    var onCreateParametric: () -> Void
    var onDuplicate: () -> Void
    var onDelete: () -> Void
    var canDeleteSelectedProfile: Bool
    var isReadOnly: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(profiles) { profile in
                        Button {
                            onSelect(profile.id)
                        } label: {
                            HStack {
                                Text(profile.name)
                                    .lineLimit(1)
                                Spacer()
                                if profile.id == mappedProfileID {
                                    Image(systemName: "speaker.wave.2.fill")
                                        .foregroundStyle(profile.id == selectedProfileID ? Color.white.opacity(0.85) : Color.secondary)
                                        .accessibilityHidden(true)
                                }
                            }
                            .foregroundStyle(profile.id == selectedProfileID ? Color.white : Color.primary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(.rect)
                            .background(
                                profile.id == selectedProfileID
                                    ? Color.accentColor
                                    : Color.clear,
                                in: .rect(cornerRadius: 8)
                            )
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel(Text(profile.name))
                        .accessibilityValue(Text(profileAccessibilityValue(profile)))
                        .accessibilityHint(Text(localized("Selects this profile for editing")))
                    }
                }
                // Align the row text (which sits 10pt inside the selection capsule) with the
                // sidebar's content leading.
                .padding(.horizontal, sidebarContentLeading - sidebarCardInset - 10)
                // No header now: inset the first row below the window controls, aligning it with
                // the content header on the right.
                .padding(.top, settingsTitlebarInset - sidebarCardInset)
                .padding(.bottom, 10)
            }

            Divider()

            VStack(spacing: 10) {
                HStack {
                    Button {
                        onCreateGraphic31()
                    } label: {
                        Image(systemName: "31.circle")
                            .frame(width: 28, height: 28)
                            .contentShape(.rect)
                    }
                    .help(localized("New 31-band profile"))
                    .disabled(isReadOnly)
                    .accessibilityLabel(Text(localized("New 31-band profile")))
                    .accessibilityHint(Text(localized("Creates a 31-band graphic equalizer profile")))

                    Button {
                        onCreateGraphic10()
                    } label: {
                        Image(systemName: "10.circle")
                            .frame(width: 28, height: 28)
                            .contentShape(.rect)
                    }
                    .help(localized("New 10-band profile"))
                    .disabled(isReadOnly)
                    .accessibilityLabel(Text(localized("New 10-band profile")))
                    .accessibilityHint(Text(localized("Creates a 10-band graphic equalizer profile")))

                    Button {
                        onCreateParametric()
                    } label: {
                        Image(systemName: "waveform.path.ecg")
                            .frame(width: 28, height: 28)
                            .contentShape(.rect)
                    }
                    .help(localized("New parametric profile"))
                    .disabled(isReadOnly)
                    .accessibilityLabel(Text(localized("New parametric profile")))
                    .accessibilityHint(Text(localized("Creates a parametric equalizer profile")))

                    Spacer()

                    Button {
                        onDuplicate()
                    } label: {
                        Image(systemName: "plus.square.on.square")
                            .frame(width: 28, height: 28)
                            .contentShape(.rect)
                    }
                    .help(localized("Duplicate profile"))
                    .disabled(isReadOnly)
                    .accessibilityLabel(Text(localized("Duplicate profile")))
                    .accessibilityHint(Text(localized("Copies the selected profile")))

                    Button(role: .destructive) {
                        onDelete()
                    } label: {
                        Image(systemName: "trash")
                            .frame(width: 28, height: 28)
                            .contentShape(.rect)
                    }
                    .help(canDeleteSelectedProfile ? localized("Delete profile") : localized("Switch away from the active profile before deleting it"))
                    .disabled(!canDeleteSelectedProfile)
                    .opacity(canDeleteSelectedProfile ? 1 : 0.35)
                    .accessibilityLabel(Text(localized("Delete profile")))
                    .accessibilityValue(Text(canDeleteSelectedProfile ? localized("Available") : localized("Unavailable for active profile")))
                    .accessibilityHint(Text(canDeleteSelectedProfile ? localized("Deletes the selected profile") : localized("Switch away from the active profile before deleting it")))
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, sidebarContentLeading - sidebarCardInset)
            .padding(.vertical, 16)
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

    private func profileAccessibilityValue(_ profile: EQProfile) -> String {
        var values: [String] = []
        if profile.id == selectedProfileID {
            values.append(localized("Selected"))
        }
        if profile.id == mappedProfileID {
            values.append(localized("Mapped to current output"))
        }
        return values.isEmpty ? localized("Not selected") : values.joined(separator: ", ")
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
    var onImport: (ImportFormat, String, String) async -> Bool
    var onPreview: () -> Void
    var onStopPreview: () -> Void
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
                                sampleRate: snapshot.currentOutputSampleRate,
                                draftEditGeneration: draftEditGeneration
                            )
                            .disabled(isProfileStoreProtected)
                        case .importer:
                            ImportTab(
                                profile: draftProfile,
                                isReadOnly: isProfileStoreProtected,
                                onImport: onImport
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
                        isReadOnly: isProfileStoreProtected,
                        onApply: onApply,
                        onRevert: onRevert,
                        onPreview: onPreview,
                        onStopPreview: onStopPreview,
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

                Text(localized("\(draftProfile.mode.title) profile, \(snapshot.currentOutputName)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityLabel(Text(localized("Profile summary")))
            }

            Spacer()

            Picker(localized("Section"), selection: $tab) {
                ForEach(EditorSection.allCases) { section in
                    Text(section.title).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 320)
            .accessibilityLabel(Text(localized("Section")))
            .accessibilityValue(Text(tab.title))
            .accessibilityHint(Text(localized("Switches between editor, import, and output details")))
        }
        .cardPanel(padding: 16)
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
    case importer
    case output

    var id: String { rawValue }

    init(_ section: SettingsSection) {
        switch section {
        case .editor:
            self = .editor
        case .importer:
            self = .importer
        case .output:
            self = .output
        }
    }

    var title: String {
        switch self {
        case .editor:
            localized("Editor")
        case .importer:
            localized("Import")
        case .output:
            localized("Output")
        }
    }
}

private enum EQEditChannel: String, CaseIterable, Identifiable {
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
    @State private var analysis: EQAnalysisSnapshot
    @State private var analysisTask: Task<Void, Never>?

    init(draftProfile: Binding<EQProfile>, sampleRate: Double, draftEditGeneration: Int) {
        self._draftProfile = draftProfile
        self.sampleRate = sampleRate
        self.draftEditGeneration = draftEditGeneration
        self._analysis = State(
            initialValue: EQAnalysisSnapshot(
                profile: draftProfile.wrappedValue,
                sampleRate: sampleRate
            )
        )
    }

    var body: some View {
        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                SettingRow(title: localized("Profile type")) {
                    Picker(localized("Profile type"), selection: Binding(
                        get: { draftProfile.mode },
                        set: { mode in
                            draftProfile.mode = mode
                            normalizeFilters(for: mode)
                        }
                    )) {
                        ForEach(EQMode.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 300)
                    .accessibilityLabel(Text(localized("Profile type")))
                    .accessibilityValue(Text(draftProfile.mode.title))
                    .accessibilityHint(Text(localized("Changes the equalizer profile type")))
                }

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

                HeadroomRow(profile: $draftProfile, recommendedPreampDB: analysis.recommendedPreampDB)
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
            }
            .cardPanel(padding: 16)

            if draftProfile.mode == .parametric {
                ParametricFilterEditor(filters: activeFiltersBinding)
                    .id("parametric:\(activeEditContextID)")
            } else {
                GraphicFilterEditor(filters: activeFiltersBinding)
                    .id("graphic:\(activeEditContextID)")
                    .cardPanel(padding: 16)
            }

        }
        .onAppear {
            refreshAnalysisIfNeeded(debounced: false)
        }
        .onChange(of: analysisSignature) { _, _ in
            refreshAnalysisIfNeeded(debounced: true)
        }
        .onDisappear {
            analysisTask?.cancel()
        }
    }

    private var analysisSignature: EQAnalysisSignature {
        EQAnalysisSignature(profile: draftProfile, sampleRate: sampleRate)
    }

    private func refreshAnalysisIfNeeded(debounced: Bool) {
        let profile = draftProfile
        let sampleRate = sampleRate
        let signature = EQAnalysisSignature(profile: profile, sampleRate: sampleRate)
        guard analysis.signature != signature else {
            return
        }

        analysisTask?.cancel()
        let shouldDebounce = debounced
            && analysis.signature.mode == signature.mode
            && analysis.signature.channelMode == signature.channelMode
        analysisTask = Task { @MainActor in
            if shouldDebounce {
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard !Task.isCancelled else {
                return
            }

            let nextAnalysis = await Task.detached(priority: .userInitiated) {
                EQAnalysisSnapshot(profile: profile, sampleRate: sampleRate)
            }.value

            guard !Task.isCancelled,
                  EQAnalysisSignature(profile: draftProfile, sampleRate: sampleRate) == nextAnalysis.signature else {
                return
            }
            analysis = nextAnalysis
        }
    }

    private func normalizeFilters(for mode: EQMode) {
        let filters: [EQFilter]
        switch mode {
        case .parametric:
            filters = [EQFilter(kind: .peak, frequency: 1_000, gainDB: 0, q: 1)]
        case .graphic10:
            filters = GraphicEQBands.tenBand.map {
                EQFilter(kind: .peak, frequency: $0, gainDB: 0, q: GraphicEQBands.graphicQ)
            }
        case .graphic31:
            filters = GraphicEQBands.thirtyOneBand.map {
                EQFilter(kind: .peak, frequency: $0, gainDB: 0, q: GraphicEQBands.graphicQ)
            }
        }
        draftProfile.filters = filters
        draftProfile.leftFilters = filters
        draftProfile.rightFilters = filters
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

    private var activeEditContextID: String {
        let channel = draftProfile.channelMode == .stereo ? editChannel.rawValue : "linked"
        return "\(draftProfile.id.uuidString):\(channel):\(draftEditGeneration)"
    }

    private func setChannelMode(_ mode: EQChannelMode) {
        guard mode != draftProfile.channelMode else {
            return
        }

        switch mode {
        case .linked:
            let sourceFilters = editChannel == .right ? draftProfile.rightFilters : draftProfile.leftFilters
            let sourcePreamp = editChannel == .right ? draftProfile.rightPreampDB : draftProfile.leftPreampDB
            draftProfile.filters = sourceFilters
            draftProfile.preampDB = sourcePreamp
        case .stereo:
            draftProfile.leftFilters = draftProfile.filters
            draftProfile.rightFilters = draftProfile.filters
            draftProfile.leftPreampDB = draftProfile.preampDB
            draftProfile.rightPreampDB = draftProfile.preampDB
            editChannel = .left
        }

        draftProfile.channelMode = mode
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
    var isReadOnly: Bool
    var onApply: () -> Void
    var onRevert: () -> Void
    var onPreview: () -> Void
    var onStopPreview: () -> Void
    var onUseForCurrentOutput: () -> Void

    var body: some View {
        HStack {
            Text(hasUnsavedDraft ? localized("Unsaved changes") : localized("All changes saved"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel(Text(localized("Profile edit state")))
                .accessibilityValue(Text(hasUnsavedDraft ? localized("Unsaved changes") : localized("All changes saved")))
            Spacer()
            Button(localized("Revert")) {
                onRevert()
            }
            .disabled(!hasUnsavedDraft)
            .buttonStyle(ToolbarButtonStyle())

            Button(localized("Apply")) {
                onApply()
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(isReadOnly || !hasUnsavedDraft)
            .buttonStyle(ToolbarButtonStyle(prominent: true))

            Button(isPreviewing ? localized("Stop Preview") : localized("Preview")) {
                isPreviewing ? onStopPreview() : onPreview()
            }
            .disabled(isReadOnly && !isPreviewing)
            .buttonStyle(ToolbarButtonStyle())
            .accessibilityValue(Text(isPreviewing ? localized("Previewing") : localized("Not previewing")))

            Button(localized("Assign to current output")) {
                onUseForCurrentOutput()
            }
            .disabled(isReadOnly || currentOutputUID.isEmpty)
            .buttonStyle(ToolbarButtonStyle())
            .accessibilityHint(Text(currentOutputUID.isEmpty ? localized("No current output is available") : localized("Maps the selected profile to the current output device")))
        }
    }
}

private struct HeadroomRow: View {
    @Binding var profile: EQProfile
    var recommendedPreampDB: Double

    var body: some View {
        let needsHeadroom = recommendedPreampDB < activePreamp - 0.1
        HStack {
            Text(localized("Headroom"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 88, alignment: .leading)
            Text(needsHeadroom ? localized("Recommend \(localizedDecibels(recommendedPreampDB))") : localized("OK"))
                .font(.caption.monospacedDigit())
                .foregroundStyle(needsHeadroom ? Color.orange : Color.secondary)
                .accessibilityLabel(Text(localized("Headroom")))
                .accessibilityValue(Text(needsHeadroom ? localized("Recommend \(localizedDecibels(recommendedPreampDB))") : localized("OK")))
            Spacer()
            Button(localized("Apply")) {
                apply(recommendedPreampDB)
            }
            .disabled(!needsHeadroom)
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

    private func apply(_ value: Double) {
        switch profile.channelMode {
        case .linked:
            profile.preampDB = value
        case .stereo:
            profile.leftPreampDB = min(profile.leftPreampDB, value)
            profile.rightPreampDB = min(profile.rightPreampDB, value)
        }
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

            switch analysis.channelMode {
            case .linked:
                draw(points: analysis.linkedPoints, color: .accentColor, context: context, rect: plotRect)
            case .stereo:
                draw(points: analysis.leftPoints, color: .blue, context: context, rect: plotRect)
                draw(points: analysis.rightPoints, color: .orange, context: context, rect: plotRect)
            }
        }
        .clipShape(.rect(cornerRadius: 14))
        .accessibilityElement(children: .ignore)
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

    private func draw(points: [FrequencyResponsePoint], color: Color, context: GraphicsContext, rect: CGRect) {
        guard points.count > 1 else {
            return
        }
        let minDB = -24.0
        let maxDB = 12.0
        var path = Path()
        for (index, point) in points.enumerated() {
            let position = CGPoint(
                x: xPosition(for: point.frequency, in: rect),
                y: yPosition(for: min(max(point.magnitudeDB, minDB), maxDB), in: rect)
            )
            index == 0 ? path.move(to: position) : path.addLine(to: position)
        }
        context.stroke(path, with: .color(color), lineWidth: 2.5)
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

private struct ImportTab: View {
    var profile: EQProfile
    var isReadOnly: Bool
    var onImport: (ImportFormat, String, String) async -> Bool
    @State private var importFormat: ImportFormat
    @State private var importName: String
    @State private var importText: String
    @State private var isEditorVisible = false
    @State private var isImporting = false

    init(profile: EQProfile, isReadOnly: Bool, onImport: @escaping (ImportFormat, String, String) async -> Bool) {
        self.profile = profile
        self.isReadOnly = isReadOnly
        self.onImport = onImport
        _importFormat = State(initialValue: .autoEQ)
        _importName = State(initialValue: localized("Imported Profile"))
        _importText = State(initialValue: "")
    }

    var body: some View {
        VStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 12) {
                Text(localized("Import / Export"))
                    .font(.headline)
                Picker(localized("Format"), selection: $importFormat) {
                    ForEach(ImportFormat.allCases) { format in
                        Text(format.rawValue).tag(format)
                    }
                }
                .pickerStyle(.segmented)

                TextField(localized("Profile Name"), text: $importName)
            }
            .cardPanel()

            if isEditorVisible {
                TextEditor(text: $importText)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .frame(minHeight: 280)
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.72), in: .rect(cornerRadius: 14))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                    )
            } else {
                HStack {
                    Button {
                        isEditorVisible = true
                    } label: {
                        Label(localized("Open Import Editor"), systemImage: "text.alignleft")
                            .frame(minHeight: 28)
                            .contentShape(.rect)
                    }
                    .controlSize(.large)
                    Spacer()
                }
                .cardPanel(padding: 12)
            }

            HStack {
                Button {
                    importText = EQProfileTextExporter.exportEqualizerAPO(profile)
                    importName = profile.name
                    importFormat = .autoEQ
                    isEditorVisible = true
                } label: {
                    Label(localized("Export Current"), systemImage: "square.and.arrow.up")
                        .frame(minHeight: 28)
                        .contentShape(.rect)
                }
                .controlSize(.large)

                Spacer()
                if isEditorVisible {
                    Button(localized("Clear")) {
                        importText = ""
                        isEditorVisible = false
                    }
                    .disabled(importText.isEmpty || isImporting)
                    .controlSize(.large)
                }
                Button {
                    let format = importFormat
                    let name = importName
                    let text = importText
                    isImporting = true
                    Task {
                        let imported = await onImport(format, name, text)
                        await MainActor.run {
                            if imported {
                                importText = ""
                                isEditorVisible = false
                            }
                            isImporting = false
                        }
                    }
                } label: {
                    Label(isImporting ? localized("Importing") : localized("Import"), systemImage: "square.and.arrow.down")
                        .frame(minHeight: 28)
                        .contentShape(.rect)
                }
                .disabled(isReadOnly || !isEditorVisible || importText.isEmpty || isImporting)
                .controlSize(.large)
            }
            .cardPanel(padding: 12)
        }
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

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(localized("Current Output"))
                        .font(.headline)
                    Text(snapshot.currentOutputName)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                    LabeledContent(localized("UID"), value: snapshot.currentOutputUID)
                    LabeledContent(localized("Sample Rate"), value: sampleRateLabel)
                    LabeledContent(localized("Channels"), value: localizedInteger(snapshot.currentOutputChannelCount))
                    LabeledContent(localized("Buffer"), value: localizedFrameCount(snapshot.currentOutputBufferFrameSize))
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
                        Button(localized("Retry 16 frames")) {
                            onRetryAutomaticAggregateBuffer()
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
                        Button(localized("Use for this output")) {
                            onUseForCurrentOutput()
                        }
                        .disabled(isProfileStoreProtected || snapshot.currentOutputUID.isEmpty)
                        .controlSize(.large)

                        Button(localized("Set as fallback profile")) {
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
                    LabeledContent(localized("Status"), value: snapshot.statusMessage)
                    LabeledContent(localized("Active Profile"), value: snapshot.activeProfileName)
                    HStack {
                        Button(localized("Retry audio engine")) {
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

                VStack(alignment: .leading, spacing: 8) {
                    Text(localized("Diagnostics"))
                        .font(.headline)
                    LabeledContent(localized("Captured"), value: localizedInteger(snapshot.metrics.capturedFrames))
                    LabeledContent(localized("Played"), value: localizedInteger(snapshot.metrics.playedFrames))
                    LabeledContent(localized("Underruns"), value: localizedInteger(snapshot.metrics.playbackUnderrunFrames))
                    LabeledContent(localized("Dropped Input"), value: localizedInteger(snapshot.metrics.droppedInputFrames))
                    LabeledContent(localized("Saturated Samples"), value: localizedInteger(snapshot.metrics.saturatedSamples))
                    LabeledContent(localized("Capture Callback Peak"), value: localizedFrameCount(snapshot.metrics.maximumCaptureCallbackFrames))
                    LabeledContent(localized("Output Callback Peak"), value: localizedFrameCount(snapshot.metrics.maximumPlaybackCallbackFrames))
                    if usesSeparateClockDiagnostics {
                        LabeledContent(localized("Dropped Buffered"), value: localizedInteger(snapshot.metrics.droppedBufferedFrames))
                        LabeledContent(localized("Ring Gate Failures"), value: localizedInteger(snapshot.metrics.ringGateContentionFailures))
                        LabeledContent(localized("Buffered"), value: localizedFrameCount(snapshot.metrics.currentBufferedFrames))
                        LabeledContent(localized("Peak Buffer"), value: localizedFrameCount(snapshot.metrics.maximumPlaybackBufferedFrames))
                        LabeledContent(localized("Output Timing Gaps"), value: localizedInteger(snapshot.metrics.playbackTimestampDiscontinuities))
                        LabeledContent(
                            localized("Sample Rate Conversion"),
                            value: snapshot.metrics.playbackSampleRateConversionActive
                                ? localized("Active")
                                : localized("Inactive")
                        )
                        LabeledContent(localized("Clock Correction"), value: playbackRateCorrectionLabel)
                        LabeledContent(localized("Servo Buffer"), value: servoBufferLabel)
                        LabeledContent(localized("Bridge Latency"), value: bridgeLatencyLabel)
                        LabeledContent(localized("Bridge Latency Range"), value: bridgeLatencyRangeLabel)
                    } else {
                        LabeledContent(localized("Input Timestamp Jumps"), value: localizedInteger(snapshot.metrics.inputTimestampDiscontinuities))
                        LabeledContent(localized("Output Timestamp Jumps"), value: localizedInteger(snapshot.metrics.outputTimestampDiscontinuities))
                        LabeledContent(localized("Tap-to-Output Latency"), value: tapToOutputLatencyLabel)
                        LabeledContent(localized("Tap-to-Output Range"), value: tapToOutputLatencyRangeLabel)
                    }
                    Button(localized("Reset metrics")) {
                        onResetDiagnostics()
                    }
                    .controlSize(.large)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .cardPanel(padding: 16)
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
        return localized(
            "A fixed buffer disables automatic reliability fallback for this route."
        )
    }

    private var sampleRateLabel: String {
        guard snapshot.currentOutputSampleRate > 0 else {
            return localized("Unknown")
        }
        return localizedFrequency(snapshot.currentOutputSampleRate)
    }

    private var tapToOutputLatencyLabel: String {
        guard snapshot.metrics.tapToOutputLatencyObservations > 0 else {
            return localized("No samples")
        }
        return localizedLatency(
            milliseconds: snapshot.metrics.averageTapToOutputLatencyNanoseconds / 1_000_000
        )
    }

    private var tapToOutputLatencyRangeLabel: String {
        guard snapshot.metrics.tapToOutputLatencyObservations > 0 else {
            return localized("No samples")
        }
        let minimum = localizedLatency(
            milliseconds: Double(snapshot.metrics.minimumTapToOutputLatencyNanoseconds) / 1_000_000
        )
        let maximum = localizedLatency(
            milliseconds: Double(snapshot.metrics.maximumTapToOutputLatencyNanoseconds) / 1_000_000
        )
        return localized("\(minimum) to \(maximum)")
    }

    private var usesSeparateClockDiagnostics: Bool {
        snapshot.metrics.playbackBufferObservations > 0
    }

    private var bridgeLatencyLabel: String {
        localizedLatency(
            milliseconds: playbackFramesToMilliseconds(
                snapshot.metrics.averagePlaybackBufferedFrames,
                bufferSampleRate: snapshot.metrics.playbackBufferSampleRate,
                fallbackSampleRate: snapshot.currentOutputSampleRate
            )
        )
    }

    private var bridgeLatencyRangeLabel: String {
        let minimum = playbackFramesToMilliseconds(
            Double(snapshot.metrics.minimumPlaybackBufferedFrames),
            bufferSampleRate: snapshot.metrics.playbackBufferSampleRate,
            fallbackSampleRate: snapshot.currentOutputSampleRate
        )
        let maximum = playbackFramesToMilliseconds(
            Double(snapshot.metrics.maximumPlaybackBufferedFrames),
            bufferSampleRate: snapshot.metrics.playbackBufferSampleRate,
            fallbackSampleRate: snapshot.currentOutputSampleRate
        )
        return localized(
            "\(localizedLatency(milliseconds: minimum)) to \(localizedLatency(milliseconds: maximum))"
        )
    }

    private var playbackRateCorrectionLabel: String {
        let correction = localizedDecimal(
            snapshot.metrics.playbackRateCorrectionPPM,
            minimumFractionDigits: 1,
            maximumFractionDigits: 1,
            signed: true
        )
        return localized("\(correction) ppm")
    }

    private var servoBufferLabel: String {
        let occupancy = localizedDecimal(
            snapshot.metrics.filteredPlaybackOccupancyFrames,
            minimumFractionDigits: 1,
            maximumFractionDigits: 1
        )
        let target = localizedInteger(snapshot.metrics.playbackOccupancyTargetFrames)
        return localized("\(occupancy) / \(target) frames")
    }

}

private extension EQMode {
    var title: String {
        switch self {
        case .parametric:
            localized("Parametric")
        case .graphic10:
            localized("10-Band")
        case .graphic31:
            localized("31-Band")
        }
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
