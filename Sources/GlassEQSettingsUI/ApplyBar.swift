import GlassEQCore
import SwiftUI

struct ApplyBar: View {
    @Bindable var controller: SettingsController

    var body: some View {
        let hasUnsavedDraft = controller.hasUnsavedDraft
        let isReadOnly = controller.isProfileStoreProtected
        let programmeComparison = controller.snapshot.programmeComparison
        HStack(spacing: 8) {
            if programmeComparison.isActive {
                Text(comparisonStatus(programmeComparison))
                    .foregroundStyle(.secondary)
                    .font(.caption.weight(.medium))
            } else {
                Text(hasUnsavedDraft ? localized("Unsaved changes") : localized("All changes saved"))
                    .foregroundStyle(.secondary)
                    .font(.caption.weight(.medium))
                    .accessibilityLabel(Text(localized("Profile edit state")))
                    .accessibilityValue(Text(hasUnsavedDraft ? localized("Unsaved changes") : localized("All changes saved")))
            }
            Spacer()

            if programmeComparison.isActive {
                Picker(localized("Listening to"), selection: $controller.programmeComparisonSelection) {
                    Text(localized("Draft"))
                        .tag(EQProgrammeComparisonSelection.equalized)
                    Text(programmeComparison.reference.title)
                        .tag(EQProgrammeComparisonSelection.reference)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 200)

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
                .fixedSize()

                Button(localized("Compare")) {
                    controller.startProgrammeComparison()
                }
                .disabled(isReadOnly || !controller.snapshot.isRunning)
                .help(localized("Switches between the draft and a loudness-matched reference: the profile playing now, or the draft with its filters off."))
            }

            Divider()
                .frame(height: 20)
                .padding(.horizontal, 4)

            Button(localized("Revert")) {
                controller.revertDraft()
            }
            .disabled(!hasUnsavedDraft || programmeComparison.isActive)

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
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private func comparisonStatus(_ programmeComparison: EQProgrammeComparisonSnapshot) -> String {
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
