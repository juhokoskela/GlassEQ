import GlassEQCore
// Re-exported so GlassEQSettingsUI clients keep seeing the import types that
// used to live in this module.
import GlassEQProfileImport
import GlassEQSettingsIPC
import SwiftUI

enum ProfileImportRoute: CaseIterable {
    case autoEQ
    case text

    var title: String {
        switch self {
        case .autoEQ:
            localized("Search AutoEq")
        case .text:
            localized("Import a File")
        }
    }

    var symbol: String {
        switch self {
        case .autoEQ:
            "headphones"
        case .text:
            "doc.text"
        }
    }
}

struct SettingsFileImportChoice {
    var selection: SettingsFileImportSelectionDTO?
    var errorMessage: String?

    var shouldClearExistingSelection: Bool {
        errorMessage != nil
    }
}

struct ProfileImportSheet: View {
    var currentProfile: EQProfile
    var isReadOnly: Bool
    var onImport: (SettingsImportFormat, String, String) async -> String?
    var onImportParsedProfile: (EQProfile) async -> String?
    var onChooseImportFiles: (SettingsFileImportMode) async -> SettingsFileImportChoice

    @State private var route = ProfileImportRoute.autoEQ
    @State private var model = ProfileImportModel()

    var body: some View {
        HStack(spacing: 0) {
            ProfileImportSidebar(route: $route, isDisabled: model.isCommitInFlight)

            Divider()

            Group {
                switch route {
                case .autoEQ:
                    AutoEQImportPane(
                        isReadOnly: isReadOnly,
                        model: model,
                        onImport: onImport
                    )
                case .text:
                    TextProfileImportPane(
                        currentProfile: currentProfile,
                        isReadOnly: isReadOnly,
                        model: model,
                        onImport: onImport,
                        onImportParsedProfile: onImportParsedProfile,
                        onChooseImportFiles: onChooseImportFiles
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 760, idealWidth: 820, minHeight: 520, idealHeight: 580)
        .interactiveDismissDisabled(model.isCommitInFlight)
    }
}

private struct ProfileImportSidebar: View {
    @Binding var route: ProfileImportRoute
    var isDisabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(localized("Import Profile"))
                .font(.headline)
                .padding(.horizontal, 14)
                .padding(.top, 16)

            List(ProfileImportRoute.allCases, id: \.self, selection: $route) { route in
                Label(route.title, systemImage: route.symbol)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .disabled(isDisabled)
        }
        .frame(width: 190)
        .background(.regularMaterial)
    }
}

struct ProfileImportFooter: View {
    var note: String
    var canImport: Bool
    var model: ProfileImportModel
    var onImport: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack {
            Text(note)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button(localized("Cancel")) {
                model.cancel()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            .disabled(model.isCommitInFlight)
            Button(action: onImport) {
                if model.isBusy {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text(localized("Add Profile"))
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!canImport || model.isBusy)
        }
        .padding(16)
    }
}

struct ProfileImportErrorLabel: View {
    var message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(Color(nsColor: .systemRed))
            .fixedSize(horizontal: false, vertical: true)
    }
}
