import Foundation
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
    typealias StatusProvider = @MainActor () -> SMAppService.Status
    typealias ServiceAction = @MainActor () throws -> Void
    typealias SettingsAction = @MainActor () -> Void

    private(set) var errorMessage: String?
    private(set) var status: SMAppService.Status
    @ObservationIgnored private let statusProvider: StatusProvider
    @ObservationIgnored private let register: ServiceAction
    @ObservationIgnored private let unregister: ServiceAction
    @ObservationIgnored private let openLoginItemsSettings: SettingsAction

    init(
        status: @escaping StatusProvider = { SMAppService.mainApp.status },
        register: @escaping ServiceAction = { try SMAppService.mainApp.register() },
        unregister: @escaping ServiceAction = { try SMAppService.mainApp.unregister() },
        openLoginItemsSettings: @escaping SettingsAction = {
            SMAppService.openSystemSettingsLoginItems()
        }
    ) {
        self.statusProvider = status
        self.register = register
        self.unregister = unregister
        self.openLoginItemsSettings = openLoginItemsSettings
        self.status = status()
    }

    var isEnabled: Bool {
        get {
            switch status {
            case .enabled, .requiresApproval:
                true
            case .notRegistered, .notFound:
                false
            @unknown default:
                false
            }
        }
        set {
            guard newValue != isEnabled else {
                return
            }
            do {
                if newValue {
                    try register()
                } else {
                    try unregister()
                }
                errorMessage = nil
            } catch {
                errorMessage = localized("macOS did not accept the change: \(error.localizedDescription)")
            }
            refresh()
        }
    }

    var requiresApproval: Bool {
        status == .requiresApproval
    }

    func refresh() {
        status = statusProvider()
    }

    func openApprovalSettings() {
        openLoginItemsSettings()
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
    case idle
    case pending
    case running(outputName: String)
    case permissionDenied(settingsError: String?)
    case failed(message: String)
    case bypassed
}

struct OnboardingView: View {
    let model: GlassEQAppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step = OnboardingStep.welcome
    @State private var scrolledStep: OnboardingStep? = .welcome

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
                canSkipAudioCapture: model.onboardingAudioCaptureState == .idle,
                back: { step = step.previous },
                advance: { step = step.next },
                finish: { dismiss() }
            )
        }
        .background(Color.macOSWindowBackground)
        .onChange(of: step) {
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.3)) {
                scrolledStep = step
            }
        }
    }

    @ViewBuilder
    private func content(for candidate: OnboardingStep) -> some View {
        switch candidate {
        case .welcome:
            OnboardingWelcomeStep(isCurrent: step == .welcome)
        case .audioCapture:
            OnboardingAudioCaptureStep(
                state: model.onboardingAudioCaptureState,
                isCurrent: step == .audioCapture,
                requestAudio: { model.startAudioForOnboarding() },
                openPrivacySettings: { model.openPrivacySettingsForOnboarding() }
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
}
