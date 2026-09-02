import AppKit
import GlassEQAudio
import ServiceManagement
import SwiftUI

enum OnboardingState {
    private static let completedVersionKey = "onboarding.completedVersion"
    private static let currentVersion = 1

    static var isComplete: Bool {
        UserDefaults.standard.integer(forKey: completedVersionKey) >= currentVersion
    }

    static func markComplete() {
        UserDefaults.standard.set(currentVersion, forKey: completedVersionKey)
    }
}

enum LaunchAtLoginSetting {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

private enum OnboardingStep: Int, CaseIterable {
    case welcome
    case audioCapture
    case preferences
    case done

    var title: String {
        switch self {
        case .welcome:
            localized("Welcome to GlassEQ")
        case .audioCapture:
            localized("Let GlassEQ hear what you hear")
        case .preferences:
            localized("A couple of choices")
        case .done:
            localized("You're set")
        }
    }
}

struct OnboardingView: View {
    @Bindable var model: GlassEQAppModel
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step = OnboardingStep.welcome
    @State private var hasRequestedAudio = false

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case .welcome:
                    welcome
                case .audioCapture:
                    audioCapture
                case .preferences:
                    preferences
                case .done:
                    done
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 36)
            .padding(.top, 36)
            .transition(reduceMotion ? .opacity : .asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)
            ))
            .id(step)

            footer
        }
        .frame(width: 560, height: 540)
        .background(Color(nsColor: .windowBackgroundColor))
        .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: step)
        .onAppear {
            hasRequestedAudio = model.hasStartedAudio
        }
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(spacing: 20) {
            appIcon
            Text(OnboardingStep.welcome.title)
                .font(.largeTitle.weight(.bold))
                .accessibilityAddTraits(.isHeader)
            Text(localized("GlassEQ is a system-wide equalizer. It follows whatever output macOS is using and shapes the sound on the way there."))
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            menuBarHint
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
    }

    private var menuBarHint: some View {
        VStack(spacing: 10) {
            HStack(spacing: 14) {
                Spacer()
                Image(systemName: "wifi")
                Image(systemName: "battery.75percent")
                Image(systemName: "slider.horizontal.3")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(6)
                    .background(Color.accentColor.opacity(0.15), in: .rect(cornerRadius: 6))
                    .symbolEffect(.bounce, options: .repeat(2), value: step)
                Text("9:41")
            }
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: .rect(cornerRadius: 10))
            .accessibilityHidden(true)

            Text(localized("There is no Dock icon once setup is done. Look for this icon in the menu bar to switch profiles, pause processing, or open Settings."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var audioCapture: some View {
        VStack(spacing: 18) {
            stepIcon("speaker.wave.3", tint: .accentColor)
            Text(OnboardingStep.audioCapture.title)
                .font(.title.weight(.bold))
                .accessibilityAddTraits(.isHeader)
            Text(localized("To equalize your Mac's sound, GlassEQ captures the audio other apps play and writes the corrected version to the same output. macOS asks you to allow that once."))
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                promiseRow("mic.slash", localized("The microphone is never read."))
                promiseRow("lock", localized("Audio stays on this Mac. Nothing is recorded or sent anywhere."))
                promiseRow("arrow.uturn.backward", localized("If GlassEQ stops or quits, playback returns to normal by itself."))
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 12))

            audioCaptureStatus
                .frame(maxWidth: .infinity)
                .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: audioCaptureState)
        }
        .frame(maxWidth: .infinity)
    }

    private enum AudioCaptureState: Equatable {
        case notRequested
        case waiting
        case running
        case permissionDenied
        case failed
    }

    private var audioCaptureState: AudioCaptureState {
        if model.isRunning {
            return .running
        }
        guard hasRequestedAudio else {
            return .notRequested
        }
        switch model.lastAudioEngineFailureCategory {
        case .systemAudioCapturePermission:
            return .permissionDenied
        case .outputDeviceUnavailable, .deviceFormatUnsupported, .coreAudioOperationFailed:
            return .failed
        case nil:
            return .waiting
        }
    }

    @ViewBuilder
    private var audioCaptureStatus: some View {
        switch audioCaptureState {
        case .notRequested:
            Button {
                requestAudio()
            } label: {
                Label(localized("Allow System Audio Capture"), systemImage: "checkmark.shield")
                    .frame(minWidth: 240, minHeight: 28)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .accessibilityHint(Text(localized("Starts GlassEQ and shows the macOS permission prompt")))
        case .waiting:
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text(localized("Waiting for macOS…"))
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        case .running:
            Label(localized("GlassEQ is processing audio on \(model.currentOutputName)."), systemImage: "checkmark.circle.fill")
                .foregroundStyle(Color(nsColor: .systemGreen))
                .font(.body.weight(.medium))
                .symbolEffect(.bounce, options: .nonRepeating, value: audioCaptureState)
                .transition(.scale(scale: 0.9).combined(with: .opacity))
        case .permissionDenied:
            VStack(spacing: 10) {
                Label(localized("GlassEQ was not allowed to capture system audio."), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color(nsColor: .systemOrange))
                    .font(.body.weight(.medium))
                Text(localized("Turn on GlassEQ under System Audio Recording in Privacy & Security, then try again."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                HStack(spacing: 10) {
                    Button(localized("Open Privacy Settings")) {
                        try? model.openPrivacySettings()
                    }
                    Button(localized("Try Again")) {
                        requestAudio()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .controlSize(.large)
            }
        case .failed:
            VStack(spacing: 10) {
                Text(model.statusMessage)
                    .font(.callout)
                    .foregroundStyle(Color(nsColor: .systemOrange))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button(localized("Try Again")) {
                    requestAudio()
                }
                .controlSize(.large)
            }
        }
    }

    private var preferences: some View {
        VStack(spacing: 18) {
            stepIcon("gearshape", tint: .secondary)
            Text(OnboardingStep.preferences.title)
                .font(.title.weight(.bold))
                .accessibilityAddTraits(.isHeader)

            VStack(spacing: 0) {
                LaunchAtLoginRow()
                Divider()
                summaryRow(localized("Output"), value: model.currentOutputName)
                Divider()
                summaryRow(localized("Profile"), value: model.activeProfile.name)
            }
            .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08), lineWidth: 1))

            Text(localized("GlassEQ starts with flat profiles. Settings has an AutoEq search that imports a correction for your headphone model."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button(localized("Open Settings")) {
                model.openSettings()
            }
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity)
    }

    private var done: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(Color(nsColor: .systemGreen))
                .symbolEffect(.bounce, options: .nonRepeating, value: step)
                .accessibilityHidden(true)
            Text(OnboardingStep.done.title)
                .font(.largeTitle.weight(.bold))
                .accessibilityAddTraits(.isHeader)
            Text(model.isRunning
                ? localized("GlassEQ is processing \(model.currentOutputName) with \(model.activeProfile.name). It lives in the menu bar from here on.")
                : localized("GlassEQ is in the menu bar. It will start processing as soon as it can capture system audio."))
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text(localized("You can reopen this guide from the Output tab in Settings."))
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Chrome

    private var footer: some View {
        HStack {
            if step != .welcome {
                Button(localized("Back")) {
                    step = OnboardingStep(rawValue: step.rawValue - 1) ?? .welcome
                }
            }
            Spacer()
            switch step {
            case .done:
                Button(localized("Finish")) {
                    dismissWindow(id: "onboarding")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            case .audioCapture where audioCaptureState == .notRequested:
                Button(localized("Skip for Now")) {
                    advance()
                }
            default:
                Button(localized("Continue")) {
                    advance()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .controlSize(.large)
        .padding(20)
        .overlay {
            stepIndicator
        }
    }

    private var stepIndicator: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingStep.allCases, id: \.rawValue) { candidate in
                Capsule()
                    .fill(candidate == step ? Color.accentColor : Color.primary.opacity(0.15))
                    .frame(width: candidate == step ? 18 : 6, height: 6)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(localized("Step \(step.rawValue + 1) of \(OnboardingStep.allCases.count)")))
    }

    private var appIcon: some View {
        let bundledIcon = Bundle.main.url(forResource: "GlassEQ", withExtension: "icns")
            .flatMap { NSImage(contentsOf: $0) }
        return Image(nsImage: bundledIcon ?? NSApplication.shared.applicationIconImage)
            .resizable()
            .frame(width: 96, height: 96)
            .accessibilityHidden(true)
    }

    private func stepIcon(_ systemName: String, tint: Color) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 30, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: 72, height: 72)
            .background(tint.opacity(0.12), in: .circle)
            .accessibilityHidden(true)
    }

    private func promiseRow(_ systemName: String, _ text: String) -> some View {
        Label {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemName)
                .foregroundStyle(Color.accentColor)
                .frame(width: 20)
        }
        .font(.callout)
    }

    private func summaryRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .accessibilityElement(children: .combine)
    }

    private func requestAudio() {
        hasRequestedAudio = true
        model.startAudioForOnboarding()
    }

    private func advance() {
        step = OnboardingStep(rawValue: step.rawValue + 1) ?? .done
    }
}

private struct LaunchAtLoginRow: View {
    @State private var isEnabled = LaunchAtLoginSetting.isEnabled
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(
                get: { isEnabled },
                set: { setEnabled($0) }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(localized("Open GlassEQ at login"))
                    Text(localized("So your headphones sound right from the first song."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(Color(nsColor: .systemOrange))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func setEnabled(_ enabled: Bool) {
        do {
            try LaunchAtLoginSetting.setEnabled(enabled)
            isEnabled = LaunchAtLoginSetting.isEnabled
            errorMessage = nil
        } catch {
            isEnabled = LaunchAtLoginSetting.isEnabled
            errorMessage = localized("macOS did not accept the change: \(error.localizedDescription)")
        }
    }
}
