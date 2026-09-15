import GlassEQCore
import SwiftUI

struct ApplyBar: View {
    var controller: SettingsController

    var body: some View {
        let hasUnsavedDraft = controller.hasUnsavedDraft
        let isReadOnly = controller.isProfileStoreProtected
        let isPreviewing = controller.snapshot.isPreviewing
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
            .disabled(isReadOnly || !hasUnsavedDraft || isComparing)
            .buttonStyle(.borderedProminent)

            Button(isPreviewing ? localized("Stop Preview") : localized("Preview")) {
                isPreviewing ? controller.stopPreview() : controller.previewDraft()
            }
            .disabled((isReadOnly && !isPreviewing) || isComparing)
            .accessibilityValue(Text(isPreviewing ? localized("Previewing") : localized("Not previewing")))

            Button(localized("Use for This Output")) {
                controller.useDraftForCurrentOutput()
            }
            .disabled(isReadOnly || !controller.hasCurrentOutput || isComparing)
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
                    Picker(localized("A/B branch"), selection: $controller.programmeComparisonSelection) {
                        Text(localized("A · EQ"))
                            .tag(EQProgrammeComparisonSelection.equalized)
                        Text(localized("B · Filters off"))
                            .tag(EQProgrammeComparisonSelection.reference)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 210)

                    Button(localized("Stop A/B")) {
                        controller.stopProgrammeComparison()
                    }
                } else {
                    Button(localized("Start A/B")) {
                        controller.startProgrammeComparison()
                    }
                    .disabled(controller.isProfileStoreProtected || controller.snapshot.isPreviewing || !controller.snapshot.isRunning)
                    .help(localized("Compares the draft EQ with its filters disabled while preserving the same preamp."))
                }
            } label: {
                Text(localized("Programme-loudness A/B"))
                Text(comparisonDescription(programmeComparison))
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
        if programmeComparison.referenceAttenuationDB < -0.05 {
            return localized(
                "Matched · Filters off \(localizedDecibels(programmeComparison.referenceAttenuationDB))"
            )
        }
        return localized("Matched · no level adjustment needed")
    }
}
