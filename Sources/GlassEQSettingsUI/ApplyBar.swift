import GlassEQCore
import SwiftUI

struct ApplyBar: View {
    @Bindable var controller: SettingsController

    var body: some View {
        let hasUnsavedDraft = controller.hasUnsavedDraft
        let isReadOnly = controller.isProfileStoreProtected
        let isPreviewing = controller.snapshot.isPreviewing
        let programmeComparison = controller.snapshot.programmeComparison
        let hasCurrentOutput = controller.hasCurrentOutput
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(localized("Programme-loudness A/B"))
                        .font(.caption.weight(.semibold))
                    Text(comparisonDescription(programmeComparison))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if programmeComparison.isActive {
                    Picker(localized("A/B branch"), selection: $controller.programmeComparisonSelection) {
                        Text(localized("A · EQ"))
                            .tag(EQProgrammeComparisonSelection.equalized)
                        Text(localized("B · Filters off"))
                            .tag(EQProgrammeComparisonSelection.filtersOff)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 210)

                    Button(localized("Stop A/B")) {
                        controller.stopProgrammeComparison()
                    }
                    .buttonStyle(ToolbarButtonStyle())
                } else {
                    Button(localized("Start A/B")) {
                        controller.startProgrammeComparison()
                    }
                    .disabled(isReadOnly || isPreviewing || !controller.snapshot.isRunning)
                    .buttonStyle(ToolbarButtonStyle())
                    .help(localized("Compares the draft EQ with its filters disabled while preserving the same preamp."))
                }
            }

            Divider()

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
                .disabled(!hasUnsavedDraft || programmeComparison.isActive)
                .buttonStyle(ToolbarButtonStyle())

                Button(localized("Apply")) {
                    controller.applyDraft()
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(isReadOnly || !hasUnsavedDraft || programmeComparison.isActive)
                .buttonStyle(ToolbarButtonStyle(prominent: true))

                Button(isPreviewing ? localized("Stop Preview") : localized("Preview")) {
                    isPreviewing ? controller.stopPreview() : controller.previewDraft()
                }
                .disabled((isReadOnly && !isPreviewing) || programmeComparison.isActive)
                .buttonStyle(ToolbarButtonStyle())
                .accessibilityValue(Text(isPreviewing ? localized("Previewing") : localized("Not previewing")))

                Button(localized("Use for This Output")) {
                    controller.useDraftForCurrentOutput()
                }
                .disabled(isReadOnly || !hasCurrentOutput || programmeComparison.isActive)
                .buttonStyle(ToolbarButtonStyle())
                .accessibilityHint(Text(hasCurrentOutput ? localized("Maps the selected profile to the current output device") : localized("No current output is available")))
            }
        }
    }

    private func comparisonDescription(_ programmeComparison: EQProgrammeComparisonSnapshot) -> String {
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
