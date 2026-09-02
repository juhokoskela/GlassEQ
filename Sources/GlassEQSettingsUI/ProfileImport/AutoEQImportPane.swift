import GlassEQProfileImport
import GlassEQSettingsIPC
import SwiftUI

struct AutoEQImportPane: View {
    var isReadOnly: Bool
    var model: ProfileImportModel
    var onImport: (SettingsImportFormat, String, String) async -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var entries: [AutoEQCatalogueEntry] = []
    @State private var filteredEntries: [AutoEQCatalogueEntry] = []
    @State private var searchText = ""
    @State private var selectionID: String?
    @State private var profileKind = AutoEQProfileKind.responseCurve
    @State private var isLoading = true
    @State private var reloadToken = 0

    private let client = AutoEQRepositoryClient()

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(localized("Find your headphones"))
                        .font(.title2.weight(.semibold))
                    Text(localized("Search AutoEq's recommended results and add one directly to GlassEQ."))
                        .foregroundStyle(.secondary)
                }

                TextField(localized("Headphone model"), text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .accessibilityHint(Text(localized("Searches the AutoEq headphone catalogue")))

                if isLoading {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text(localized("Loading AutoEq catalogue…"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 170)
                } else if entries.isEmpty {
                    ContentUnavailableView {
                        Label(localized("AutoEq is unavailable"), systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(model.errorMessage ?? localized("GlassEQ could not load the headphone catalogue."))
                    } actions: {
                        Button(localized("Try Again")) {
                            reloadToken += 1
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 170)
                } else if query.isEmpty {
                    ContentUnavailableView {
                        Label(localized("Search AutoEq"), systemImage: "magnifyingglass")
                    } description: {
                        Text(localized("Type a manufacturer or model name to search \(entries.count) recommended profiles."))
                    }
                    .frame(maxWidth: .infinity, minHeight: 170)
                } else if filteredEntries.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                        .frame(maxWidth: .infinity, minHeight: 170)
                } else {
                    AutoEQResultsList(entries: filteredEntries, selection: $selectionID)
                }

                if let selection {
                    AutoEQImportOptions(entry: selection, profileKind: $profileKind)
                }

                if let errorMessage = model.errorMessage {
                    ProfileImportErrorLabel(message: errorMessage)
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Divider()

            ProfileImportFooter(
                note: localized("Profiles are downloaded from the official AutoEq repository."),
                canImport: selection != nil && !isReadOnly,
                model: model,
                onImport: importSelection
            )
        }
        .task(id: reloadToken) {
            await loadCatalogue()
        }
        .onDisappear {
            model.cancel()
        }
        .onChange(of: searchText) {
            selectionID = nil
            updateFilteredEntries()
        }
    }

    private var query: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var selection: AutoEQCatalogueEntry? {
        guard let selectionID else {
            return nil
        }
        return filteredEntries.first { $0.id == selectionID }
    }

    private func updateFilteredEntries() {
        let query = query
        guard !query.isEmpty else {
            filteredEntries = []
            return
        }
        filteredEntries = entries.filter {
            $0.name.localizedStandardContains(query)
                || $0.source.localizedStandardContains(query)
        }
    }

    private func loadCatalogue() async {
        isLoading = true
        model.errorMessage = nil
        do {
            entries = try await client.catalogue()
        } catch where Task.isCancelled {
            return
        } catch {
            entries = []
            model.errorMessage = error.localizedDescription
        }
        isLoading = false
        updateFilteredEntries()
    }

    private func importSelection() {
        guard let selection else {
            return
        }
        let kind = profileKind
        model.commit(
            preparing: { try await client.profileText(for: selection, kind: kind) },
            { text in await onImport(.autoEQ, selection.name, text) },
            onSuccess: { dismiss() }
        )
    }
}

private struct AutoEQResultsList: View {
    var entries: [AutoEQCatalogueEntry]
    @Binding var selection: String?

    var body: some View {
        List(entries, selection: $selection) { entry in
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name)
                    .lineLimit(1)
                Text(entry.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.vertical, 3)
        }
        .listStyle(.inset)
        .frame(minHeight: 170)
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                .allowsHitTesting(false)
        }
    }
}

private struct AutoEQImportOptions: View {
    var entry: AutoEQCatalogueEntry
    @Binding var profileKind: AutoEQProfileKind

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(localized("How should GlassEQ import this result?"))
                .font(.headline)

            Picker(localized("Profile type"), selection: $profileKind) {
                VStack(alignment: .leading) {
                    Text(localized("Convolution"))
                    Text(localized("Full minimum-phase correction"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag(AutoEQProfileKind.responseCurve)

                VStack(alignment: .leading) {
                    Text(localized("Parametric filters"))
                    Text(localized("Ten editable filters"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag(AutoEQProfileKind.parametric)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            Text(localized("Selected: \(entry.name) · \(entry.detail)"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(14)
        .background(
            Color(nsColor: .controlBackgroundColor).opacity(0.7),
            in: .rect(cornerRadius: 12)
        )
    }
}
