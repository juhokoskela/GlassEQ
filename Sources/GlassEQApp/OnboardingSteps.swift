import AppKit
import SwiftUI

@MainActor
private enum OnboardingAppIcon {
    static let image: NSImage = Bundle.main.url(forResource: "GlassEQ", withExtension: "icns")
        .flatMap { NSImage(contentsOf: $0) } ?? NSApplication.shared.applicationIconImage
}

struct OnboardingWelcomeStep: View {
    let isCurrent: Bool

    var body: some View {
        VStack(spacing: 20) {
            Image(nsImage: OnboardingAppIcon.image)
                .resizable()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)
            Text(OnboardingStep.welcome.title)
                .font(.largeTitle.weight(.bold))
                .accessibilityAddTraits(.isHeader)
            Text(localized("GlassEQ is a system-wide equalizer. It follows whatever output macOS is using and shapes the sound on the way there."))
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            OnboardingMenuBarHint(isCurrent: isCurrent)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct OnboardingMenuBarHint: View {
    let isCurrent: Bool

    var body: some View {
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
                    .symbolEffect(.bounce, options: .repeat(2), value: isCurrent)
                Text(verbatim: "9:41")
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
}

struct OnboardingAudioCaptureStep: View {
    let state: OnboardingAudioCaptureState
    let isCurrent: Bool
    let requestAudio: () -> Void
    let openPrivacySettings: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 18) {
            OnboardingStepIcon(systemName: "speaker.wave.3", tint: .accentColor)
            Text(OnboardingStep.audioCapture.title)
                .font(.title.weight(.bold))
                .accessibilityAddTraits(.isHeader)
            Text(localized("To equalize your Mac's sound, GlassEQ captures the audio other apps play and writes the corrected version to the same output. macOS asks you to allow that once."))
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                OnboardingPromiseRow(systemName: "mic.slash", text: localized("The microphone is never read."))
                OnboardingPromiseRow(systemName: "lock", text: localized("Audio stays on this Mac. Nothing is recorded or sent anywhere."))
                OnboardingPromiseRow(systemName: "arrow.uturn.backward", text: localized("If GlassEQ stops or quits, playback returns to normal by itself."))
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.macOSControlBackground, in: .rect(cornerRadius: 12))

            OnboardingAudioCaptureStatus(
                state: state,
                isCurrent: isCurrent,
                requestAudio: requestAudio,
                openPrivacySettings: openPrivacySettings
            )
            .frame(maxWidth: .infinity)
            .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: state)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct OnboardingAudioCaptureStatus: View {
    let state: OnboardingAudioCaptureState
    let isCurrent: Bool
    let requestAudio: () -> Void
    let openPrivacySettings: () -> Void

    var body: some View {
        switch state {
        case .idle:
            Button(action: requestAudio) {
                Label(localized("Allow System Audio Capture"), systemImage: "checkmark.shield")
                    .frame(minWidth: 240, minHeight: 28)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            // Only the visible step may own Return; the strip keeps the other steps mounted.
            .keyboardShortcut(isCurrent ? .defaultAction : nil)
            .accessibilityHint(Text(localized("Starts GlassEQ and shows the macOS permission prompt")))
        case .pending:
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text(localized("Waiting for macOS…"))
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        case .running(let outputName):
            Label(localized("GlassEQ is processing audio on \(outputName)."), systemImage: "checkmark.circle.fill")
                .foregroundStyle(Color.macOSSystemGreen)
                .font(.body.weight(.medium))
                .symbolEffect(.bounce, options: .nonRepeating, value: state)
                .transition(.scale(scale: 0.9).combined(with: .opacity))
        case .permissionDenied(let settingsError):
            VStack(spacing: 10) {
                Label(localized("GlassEQ was not allowed to capture system audio."), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.macOSSystemOrange)
                    .font(.body.weight(.medium))
                Text(localized("Turn on GlassEQ under System Audio Recording in Privacy & Security, then try again."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if let settingsError {
                    Text(settingsError)
                        .font(.callout)
                        .foregroundStyle(Color.macOSSystemOrange)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 10) {
                    Button(localized("Open Privacy Settings"), action: openPrivacySettings)
                    Button(localized("Try Again"), action: requestAudio)
                        .buttonStyle(.borderedProminent)
                }
                .controlSize(.large)
            }
        case .failed(let message):
            VStack(spacing: 10) {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(Color.macOSSystemOrange)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button(localized("Try Again"), action: requestAudio)
                    .controlSize(.large)
            }
        case .bypassed:
            VStack(spacing: 10) {
                Label(localized("Audio processing is off for the active profile."), systemImage: "pause.circle.fill")
                    .foregroundStyle(.secondary)
                    .font(.body.weight(.medium))
                Text(localized("Continue setup, then turn processing on from the menu bar or Settings."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct OnboardingPreferencesStep: View {
    let outputName: String
    let profileName: String
    let openSettings: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            OnboardingStepIcon(systemName: "gearshape", tint: .secondary)
            Text(OnboardingStep.preferences.title)
                .font(.title.weight(.bold))
                .accessibilityAddTraits(.isHeader)

            VStack(spacing: 0) {
                LaunchAtLoginRow()
                Divider()
                OnboardingSummaryRow(title: localized("Output"), value: outputName)
                Divider()
                OnboardingSummaryRow(title: localized("Profile"), value: profileName)
            }
            .background(Color.macOSControlBackground, in: .rect(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            }

            Text(localized("GlassEQ starts with flat profiles. Settings has an AutoEq search that imports a correction for your headphone model."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button(localized("Open Settings"), action: openSettings)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct LaunchAtLoginRow: View {
    @State private var launchAtLogin = LaunchAtLoginModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var launchAtLogin = launchAtLogin
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: $launchAtLogin.isEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(localized("Open GlassEQ at login"))
                    Text(localized("So your headphones sound right from the first song."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            if launchAtLogin.requiresApproval {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(localized("macOS needs your approval before GlassEQ can open at login."))
                        .font(.caption)
                        .foregroundStyle(Color.macOSSystemOrange)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(localized("Open Login Items")) {
                        launchAtLogin.openApprovalSettings()
                    }
                    .controlSize(.small)
                }
            }
            if let errorMessage = launchAtLogin.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(Color.macOSSystemOrange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .onAppear {
            launchAtLogin.refresh()
        }
        .onChange(of: scenePhase) {
            if scenePhase == .active {
                launchAtLogin.refresh()
            }
        }
    }
}

struct OnboardingDoneStep: View {
    let isRunning: Bool
    let outputName: String
    let profileName: String
    let isCurrent: Bool

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(Color.macOSSystemGreen)
                .symbolEffect(.bounce, options: .nonRepeating, value: isCurrent)
                .accessibilityHidden(true)
            Text(OnboardingStep.done.title)
                .font(.largeTitle.weight(.bold))
                .accessibilityAddTraits(.isHeader)
            Text(isRunning
                ? localized("GlassEQ is processing \(outputName) with \(profileName). It lives in the menu bar from here on.")
                : localized("GlassEQ is in the menu bar. It will start processing as soon as it can capture system audio."))
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text(localized("You can reopen this guide from the Output tab in Settings."))
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }
}

struct OnboardingFooter: View {
    let step: OnboardingStep
    let canSkipAudioCapture: Bool
    let back: () -> Void
    let advance: () -> Void
    let finish: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            OnboardingStepIndicator(step: step)
            HStack {
                if step != .welcome {
                    Button(localized("Back"), action: back)
                }
                Spacer()
                switch step {
                case .done:
                    Button(localized("Finish"), action: finish)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                case .audioCapture where canSkipAudioCapture:
                    Button(localized("Skip for Now"), action: advance)
                default:
                    Button(localized("Continue"), action: advance)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .controlSize(.large)
        }
        .padding(20)
    }
}

struct OnboardingStepIndicator: View {
    let step: OnboardingStep
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            ForEach(OnboardingStep.allCases, id: \.rawValue) { candidate in
                Capsule()
                    .fill(candidate == step ? Color.accentColor : Color.primary.opacity(0.15))
                    .frame(width: candidate == step ? 18 : 6, height: 6)
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: step)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(localized("Step \(step.rawValue + 1) of \(OnboardingStep.allCases.count)")))
    }
}

private struct OnboardingStepIcon: View {
    let systemName: String
    let tint: Color

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 30, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: 72, height: 72)
            .background(tint.opacity(0.12), in: .circle)
            .accessibilityHidden(true)
    }
}

private struct OnboardingPromiseRow: View {
    let systemName: String
    let text: String

    var body: some View {
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
}

private struct OnboardingSummaryRow: View {
    let title: String
    let value: String

    var body: some View {
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
}
