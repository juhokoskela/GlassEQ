import GlassEQCore
import GlassEQSettingsIPC
import SwiftUI

enum NewProfileChoice: Hashable, Identifiable {
    case create(SettingsProfileKind)
    case importProfile

    static let createChoices: [NewProfileChoice] = [
        .create(.parametric),
        .create(.graphic10),
        .create(.graphic31),
        .create(.convolution)
    ]

    var id: Self { self }

    var title: String {
        switch self {
        case .create(let kind):
            kind.mode.title
        case .importProfile:
            localized("Import")
        }
    }

    var symbol: String {
        switch self {
        case .create(let kind):
            kind.mode.symbol
        case .importProfile:
            "square.and.arrow.down"
        }
    }

    var summary: String {
        switch self {
        case .create(.parametric):
            localized("A few filters you place by hand. Peaks, shelves, and cuts at any frequency.")
        case .create(.graphic10):
            localized("Ten fixed bands, one octave apart. Quick tone adjustments.")
        case .create(.graphic31):
            localized("Thirty-one fixed bands, a third of an octave apart. Fine control.")
        case .create(.convolution):
            localized("A target response curve or impulse response, rendered as a minimum-phase FIR filter.")
        case .importProfile:
            localized("From an AutoEq result, an EqualizerAPO or REW file, or a WAV impulse response.")
        }
    }

    var actionTitle: String {
        switch self {
        case .create:
            localized("Create")
        case .importProfile:
            localized("Import…")
        }
    }
}

extension SettingsProfileKind {
    var mode: EQMode {
        switch self {
        case .graphic10:
            .graphic10
        case .graphic31:
            .graphic31
        case .parametric:
            .parametric
        case .convolution:
            .convolution
        }
    }
}

struct NewProfileSheet: View {
    let onCreate: (SettingsProfileKind) -> Void
    let onImport: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var choice = NewProfileChoice.create(.parametric)

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(localized("New Profile"))
                    .font(.title2.weight(.semibold))
                Text(localized("Pick how you want to shape the sound. You can rename the profile afterwards."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 12) {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(NewProfileChoice.createChoices) { option in
                        NewProfileChoiceCard(option: option, choice: $choice, onConfirm: confirm)
                    }
                }
                NewProfileChoiceCard(option: .importProfile, choice: $choice, onConfirm: confirm)
            }
            .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: choice)

            HStack {
                Spacer()
                Button(localized("Cancel")) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(choice.actionTitle) {
                    confirm()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 560)
    }

    private func confirm() {
        dismiss()
        switch choice {
        case .create(let kind):
            onCreate(kind)
        case .importProfile:
            onImport()
        }
    }
}

private struct NewProfileChoiceCard: View {
    let option: NewProfileChoice
    @Binding var choice: NewProfileChoice
    let onConfirm: () -> Void

    @State private var isHovering = false

    private var isSelected: Bool {
        option == choice
    }

    var body: some View {
        Button {
            choice = option
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: option.symbol)
                    .font(.title3.weight(.medium))
                    .frame(width: 34, height: 34)
                    .foregroundStyle(isSelected ? Color(nsColor: .alternateSelectedControlTextColor) : Color.accentColor)
                    .background(
                        isSelected ? Color.accentColor : Color.accentColor.opacity(0.12),
                        in: .rect(cornerRadius: 9)
                    )
                    .symbolEffect(.bounce, options: .nonRepeating, value: isSelected)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(option.title)
                        .font(.body.weight(.semibold))
                    Text(option.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading)
            .contentShape(.rect(cornerRadius: 12))
            .background(
                isSelected ? Color.accentColor.opacity(0.1) : Color.primary.opacity(isHovering ? 0.06 : 0.035),
                in: .rect(cornerRadius: 12)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        isSelected ? Color.accentColor : Color.primary.opacity(0.08),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .simultaneousGesture(TapGesture(count: 2).onEnded { onConfirm() })
        .accessibilityLabel(Text(option.title))
        .accessibilityValue(Text(option.summary))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint(Text(localized("Selects this profile type")))
        .accessibilityAction(named: Text(option.actionTitle)) {
            choice = option
            onConfirm()
        }
    }
}

extension EQMode {
    var title: String {
        switch self {
        case .parametric:
            localized("Parametric")
        case .graphic10:
            localized("10-Band")
        case .graphic31:
            localized("31-Band")
        case .convolution:
            localized("Convolution")
        }
    }

    var symbol: String {
        switch self {
        case .parametric:
            "slider.horizontal.3"
        case .graphic10:
            "10.circle"
        case .graphic31:
            "31.circle"
        case .convolution:
            "waveform.path"
        }
    }
}
