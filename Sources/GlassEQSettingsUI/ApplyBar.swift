import GlassEQCore
import SwiftUI

struct ApplyBar: View {
    @Bindable var controller: SettingsController

    var body: some View {
        let hasUnsavedDraft = controller.hasUnsavedDraft
        let isReadOnly = controller.isProfileStoreProtected
        let programmeComparison = controller.snapshot.programmeComparison
        VStack(alignment: .leading, spacing: 8) {
            if programmeComparison.isActive {
                Text(programmeComparison.isReady ? localized("Volume matched") : localized("Matching volume…"))
                    .foregroundStyle(.secondary)
                    .font(.caption.weight(.medium))
            } else if hasUnsavedDraft {
                Text(localized("Unapplied changes"))
                    .foregroundStyle(.secondary)
                    .font(.caption.weight(.medium))

            }
            HStack(spacing: 8) {
                if programmeComparison.isActive {
                    Picker(localized("Listening to"), selection: $controller.programmeComparisonSelection) {
                        Text(localized("Filters off"))
                            .tag(EQProgrammeComparisonSelection.reference)
                        Text(localized("Filters on"))
                            .tag(EQProgrammeComparisonSelection.equalized)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()

                    Button(localized("Done")) {
                        controller.stopProgrammeComparison()
                    }
                    .keyboardShortcut(.cancelAction)
                    .help(localized("End comparison and return to normal playback."))
                } else {
                    Button(localized("Compare")) {
                        controller.startProgrammeComparison()
                    }
                    .disabled(isReadOnly || !controller.snapshot.isRunning || controller.draftProfile.isBypassed)
                    .help(localized("Compare the current filters with filters off at a matched volume."))

                    if hasUnsavedDraft {
                        Button(localized("Revert")) { controller.revertDraft() }
                    }

                    if controller.canAssignDraftToOutput {
                        Button(
                            hasUnsavedDraft ? localized("Save and Assign to Output") : localized("Use for This Output")
                        ) {
                            controller.useDraftForCurrentOutput()
                        }
                        .disabled(isReadOnly)
                        .help(localized("Maps the selected profile to the current output device"))
                    }
                }

                Spacer(minLength: 0)

                Button(
                    !hasUnsavedDraft && controller.draftProfile.id != controller.snapshot.activeProfileID
                        ? localized("Activate Profile") : localized("Apply")
                ) {
                    controller.applyDraft()
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!controller.canApplyDraft)
                .buttonStyle(.borderedProminent)
            }
            .disabled(controller.isStartingProgrammeComparison)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .top) {
            Divider()
        }
    }
}
