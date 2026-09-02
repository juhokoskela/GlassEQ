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

@MainActor
@Observable
final class LaunchAtLoginModel {
    private(set) var errorMessage: String?
    private var isRegistered = SMAppService.mainApp.status == .enabled

    var isEnabled: Bool {
        get { isRegistered }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
                errorMessage = nil
            } catch {
                errorMessage = localized("macOS did not accept the change: \(error.localizedDescription)")
            }
            isRegistered = SMAppService.mainApp.status == .enabled
        }
    }
}

enum OnboardingStep: Int, CaseIterable {
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

    var previous: OnboardingStep {
        OnboardingStep(rawValue: rawValue - 1) ?? .welcome
    }

    var next: OnboardingStep {
        OnboardingStep(rawValue: rawValue + 1) ?? .done
    }
}

enum OnboardingAudioCaptureState: Equatable {
    case notRequested
    case waiting
    case running
    case permissionDenied
    case failed

    init(isRunning: Bool, hasRequested: Bool, failureCategory: AudioEngineFailure.Category?) {
        if isRunning {
            self = .running
            return
        }
        guard hasRequested else {
            self = .notRequested
            return
        }
        switch failureCategory {
        case .systemAudioCapturePermission:
            self = .permissionDenied
        case .outputDeviceUnavailable, .deviceFormatUnsupported, .coreAudioOperationFailed:
            self = .failed
        case nil:
            self = .waiting
        }
    }
}

struct OnboardingView: View {
    let model: GlassEQAppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step = OnboardingStep.welcome
    @State private var scrolledStep: OnboardingStep? = .welcome
    @State private var hasRequestedAudio = false

    static let width: CGFloat = 560

    var body: some View {
        VStack(spacing: 0) {
            // Every step sits in one paging strip, so going back reverses the motion and the strip
            // follows the layout direction instead of a hand-computed offset.
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(OnboardingStep.allCases, id: \.rawValue) { candidate in
                        content(for: candidate)
                            .padding(.horizontal, 36)
                            .padding(.top, 36)
                            .frame(width: Self.width)
                            .frame(maxHeight: .infinity, alignment: .top)
                            .accessibilityHidden(candidate != step)
                            .id(candidate)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $scrolledStep)
            .scrollDisabled(true)
            .scrollIndicators(.hidden)
            .frame(width: Self.width)

            OnboardingFooter(
                step: step,
                canSkipAudioCapture: audioCaptureState == .notRequested,
                back: { step = step.previous },
                advance: { step = step.next },
                finish: { dismiss() }
            )
        }
        .background(Color.macOSWindowBackground)
        .onAppear {
            hasRequestedAudio = model.hasStartedAudio
        }
        .onChange(of: step) {
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.3)) {
                scrolledStep = step
            }
        }
    }

    private var audioCaptureState: OnboardingAudioCaptureState {
        OnboardingAudioCaptureState(
            isRunning: model.isRunning,
            hasRequested: hasRequestedAudio,
            failureCategory: model.lastAudioEngineFailureCategory
        )
    }

    @ViewBuilder
    private func content(for candidate: OnboardingStep) -> some View {
        switch candidate {
        case .welcome:
            OnboardingWelcomeStep(isCurrent: step == .welcome)
        case .audioCapture:
            OnboardingAudioCaptureStep(
                state: audioCaptureState,
                statusMessage: model.statusMessage,
                outputName: model.currentOutputName,
                isCurrent: step == .audioCapture,
                requestAudio: requestAudio,
                openPrivacySettings: { try? model.openPrivacySettings() }
            )
        case .preferences:
            OnboardingPreferencesStep(
                outputName: model.currentOutputName,
                profileName: model.activeProfileName,
                openSettings: { model.openSettings() }
            )
        case .done:
            OnboardingDoneStep(
                isRunning: model.isRunning,
                outputName: model.currentOutputName,
                profileName: model.activeProfileName,
                isCurrent: step == .done
            )
        }
    }

    private func requestAudio() {
        hasRequestedAudio = true
        model.startAudioForOnboarding()
    }
}
