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
                Text(programmeComparison.isReady ? localized("Volume matched") : localized("Matching volume…"))
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
                    Text(localized("Filters off"))
                        .tag(EQProgrammeComparisonSelection.reference)
                    Text(localized("Current filters applied"))
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
                .disabled(isReadOnly || !controller.snapshot.isRunning)
                .help(localized("Compare the current filters with filters off at a matched volume."))

                Divider()
                    .frame(height: 20)
                    .padding(.horizontal, 4)

                Button(localized("Revert")) {
                    controller.revertDraft()
                }
                .disabled(!hasUnsavedDraft)

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
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .top) {
            Divider()
        }
    }
}
