import GlassEQCore
import SwiftUI

struct ApplyBar: View {
    var controller: SettingsController

    var body: some View {
        let hasUnsavedDraft = controller.hasUnsavedDraft
        let isReadOnly = controller.isProfileStoreProtected
        let isComparing = controller.snapshot.programmeComparison.isActive
        HStack {
            Text(hasUnsavedDraft ? localized("Unsaved changes") : localized("All changes saved"))
                .foregroundStyle(.secondary)
                .font(.caption.weight(.medium))
                .accessibilityLabel(Text(localized("Profile edit state")))
                .accessibilityValue(Text(hasUnsavedDraft ? localized("Unsaved changes") : localized("All changes saved")))
            Spacer()
            Button(localized("Revert")) {
                controller.revertDraft()
            }
            .disabled(!hasUnsavedDraft || isComparing)

            Button(localized("Apply")) {
                controller.applyDraft()
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(isReadOnly || !hasUnsavedDraft)
            .buttonStyle(.borderedProminent)

            Button(localized("Use for This Output")) {
                controller.useDraftForCurrentOutput()
            }
            .disabled(isReadOnly || !controller.hasCurrentOutput)
            .accessibilityHint(Text(controller.hasCurrentOutput ? localized("Maps the selected profile to the current output device") : localized("No current output is available")))
        }
        .controlSize(.large)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .top) {
            Divider()
        }
    }
}

struct ProgrammeComparisonSection: View {
    @Bindable var controller: SettingsController

    var body: some View {
        let programmeComparison = controller.snapshot.programmeComparison
        Section {
            LabeledContent {
                if programmeComparison.isActive {
                    Picker(localized("Listening to"), selection: $controller.programmeComparisonSelection) {
                        Text(localized("Draft"))
                            .tag(EQProgrammeComparisonSelection.equalized)
                        Text(programmeComparison.reference.title)
                            .tag(EQProgrammeComparisonSelection.reference)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 220)

                    Button(localized("Stop")) {
                        controller.stopProgrammeComparison()
                    }
                } else {
                    Picker(localized("Compare with"), selection: $controller.comparisonReference) {
                        ForEach(EQProgrammeComparisonReference.allCases, id: \.self) { reference in
                            Text(reference.title).tag(reference)
                        }
                    }
                    .labelsHidden()

                    Button(localized("Start")) {
                        controller.startProgrammeComparison()
                    }
                    .disabled(controller.isProfileStoreProtected || !controller.snapshot.isRunning)
                }
            } label: {
                Text(localized("Compare"))
                Text(description(programmeComparison))
            }
        }
    }

    private func description(_ programmeComparison: EQProgrammeComparisonSnapshot) -> String {
        guard programmeComparison.isActive else {
            return localized("Switch between the draft and a loudness-matched reference: the profile playing now, or the draft with its filters off.")
        }
        guard programmeComparison.isReady else {
            return localized("Measuring the current programme…")
        }
        if programmeComparison.equalizedAttenuationDB < -0.05 {
            return localized(
                "Matched · Draft \(localizedDecibels(programmeComparison.equalizedAttenuationDB))"
            )
        }
        if programmeComparison.referenceAttenuationDB < -0.05 {
            return localized(
                "Matched · \(programmeComparison.reference.title) \(localizedDecibels(programmeComparison.referenceAttenuationDB))"
            )
        }
        return localized("Matched · no level adjustment needed")
    }
}

private extension EQProgrammeComparisonReference {
    var title: String {
        switch self {
        case .playingNow:
            localized("Playing now")
        case .filtersOff:
            localized("Filters off")
        }
    }
}
