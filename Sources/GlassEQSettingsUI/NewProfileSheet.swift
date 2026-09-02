import GlassEQCore
import GlassEQSettingsIPC
import SwiftUI

private enum NewProfileStep {
    case startingPoint
    case profileType

    var title: String {
        switch self {
        case .startingPoint:
            localized("New Profile")
        case .profileType:
            localized("Build Your Own")
        }
    }

    var summary: String {
        switch self {
        case .startingPoint:
            localized("Choose how you want to get started.")
        case .profileType:
            localized("Choose a profile type. You can rename it afterwards.")
        }
    }
}

private enum NewProfileStartingPoint: String, CaseIterable, Identifiable {
    case build
    case importFile
    case searchAutoEQ

    var id: String { rawValue }

    var title: String {
        switch self {
        case .build:
            localized("Build Your Own")
        case .importFile:
            localized("Import a File")
        case .searchAutoEQ:
            localized("Search AutoEq")
        }
    }

    var symbol: String {
        switch self {
        case .build:
            "slider.horizontal.3"
        case .importFile:
            "square.and.arrow.down"
        case .searchAutoEQ:
            "magnifyingglass"
        }
    }

    var summary: String {
        switch self {
        case .build:
            localized("Start with a blank Parametric, Graphic, or Convolution profile.")
        case .importFile:
            localized("Open an EqualizerAPO or REW file, or a WAV impulse response.")
        case .searchAutoEQ:
            localized("Find a headphone profile in the AutoEq catalogue.")
        }
    }

    var accessibilityHint: String {
        switch self {
        case .build:
            localized("Shows the available profile types")
        case .importFile:
            localized("Opens the file importer")
        case .searchAutoEQ:
            localized("Opens the AutoEq catalogue search")
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

    var summary: String {
        switch self {
        case .parametric:
            localized("Place peaks, shelves, and cuts at any frequency.")
        case .graphic10:
            localized("Ten fixed bands, one octave apart.")
        case .graphic31:
            localized("Thirty-one fixed bands, a third of an octave apart.")
        case .convolution:
            localized("Use a target response curve or impulse response.")
        }
    }
}

struct NewProfileSheet: View {
    let onCreate: (SettingsProfileKind) -> Void
    let onImport: (ProfileImportRoute) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var step = NewProfileStep.startingPoint

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            NewProfileSheetHeader(step: step)

            switch step {
            case .startingPoint:
                NewProfileStartingPointChoices(onSelect: selectStartingPoint)
            case .profileType:
                NewProfileKindChoices(onSelect: createProfile)
            }

            Spacer(minLength: 0)

            NewProfileSheetFooter(
                canGoBack: step == .profileType,
                onBack: { step = .startingPoint },
                onCancel: { dismiss() }
            )
        }
        .padding(24)
        .frame(width: 560)
        .frame(minHeight: 400)
    }

    private func selectStartingPoint(_ startingPoint: NewProfileStartingPoint) {
        switch startingPoint {
        case .build:
            step = .profileType
        case .importFile:
            openImporter(at: .text)
        case .searchAutoEQ:
            openImporter(at: .autoEQ)
        }
    }

    private func createProfile(_ kind: SettingsProfileKind) {
        dismiss()
        onCreate(kind)
    }

    private func openImporter(at route: ProfileImportRoute) {
        dismiss()
        onImport(route)
    }
}

private struct NewProfileSheetHeader: View {
    let step: NewProfileStep

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(step.title)
                .font(.title2.weight(.semibold))
            Text(step.summary)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

private struct NewProfileStartingPointChoices: View {
    let onSelect: (NewProfileStartingPoint) -> Void

    var body: some View {
        VStack(spacing: 12) {
            ForEach(NewProfileStartingPoint.allCases) { startingPoint in
                NewProfileChoiceCard(
                    title: startingPoint.title,
                    summary: startingPoint.summary,
                    symbol: startingPoint.symbol,
                    accessibilityHint: startingPoint.accessibilityHint,
                    action: { onSelect(startingPoint) }
                )
            }
        }
    }
}

private struct NewProfileKindChoices: View {
    let onSelect: (SettingsProfileKind) -> Void

    private let kinds: [SettingsProfileKind] = [
        .parametric,
        .convolution,
        .graphic10,
        .graphic31
    ]
    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(kinds, id: \.rawValue) { kind in
                NewProfileChoiceCard(
                    title: kind.mode.title,
                    summary: kind.summary,
                    symbol: kind.mode.symbol,
                    accessibilityHint: localized("Creates this profile type"),
                    action: { onSelect(kind) }
                )
            }
        }
    }
}

private struct NewProfileSheetFooter: View {
    let canGoBack: Bool
    let onBack: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack {
            if canGoBack {
                Button(localized("Back"), action: onBack)
            }
            Spacer()
            Button(localized("Cancel"), action: onCancel)
                .keyboardShortcut(.cancelAction)
        }
        .controlSize(.large)
    }
}

private struct NewProfileChoiceCard: View {
    let title: String
    let summary: String
    let symbol: String
    let accessibilityHint: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: symbol)
                    .font(.title3.weight(.medium))
                    .frame(width: 40, height: 40)
                    .foregroundStyle(Color.accentColor)
                    .background(Color.accentColor.opacity(0.12), in: .rect(cornerRadius: 10))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.body.weight(.semibold))
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 84, alignment: .leading)
            .contentShape(.rect(cornerRadius: 12))
            .background(
                Color.primary.opacity(isHovering ? 0.06 : 0.035),
                in: .rect(cornerRadius: 12)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.primary.opacity(0.08))
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(summary))
        .accessibilityHint(Text(accessibilityHint))
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
