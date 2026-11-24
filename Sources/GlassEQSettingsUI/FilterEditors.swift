@_spi(GlassEQSettingsUI) import GlassEQCore
import SwiftUI

extension EQFilter {
    var quantizedGainDB: Double {
        get { gainDB }
        set { gainDB = quantized(newValue, step: 0.1) }
    }
}

extension EQMagnitudePoint {
    var quantizedGainDB: Double {
        get { gainDB }
        set { gainDB = quantized(newValue, step: 0.1) }
    }
}

struct MagnitudeCurveEditor: View {
    @Binding var points: [EQMagnitudePoint]
    @State private var isExpanded = false

    var body: some View {
        Section {
            DisclosureGroup(isExpanded: $isExpanded) {
                if isExpanded {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach($points) { $point in
                            HStack(spacing: 10) {
                                EditableValueText(
                                    title: localized("Frequency"),
                                    value: $point.frequency,
                                    range: ProfilePersistence.frequencyRange,
                                    display: point.frequency.frequencyLabel,
                                    width: 72
                                )
                                Slider(value: $point.quantizedGainDB, in: -24...12)
                                    .accessibilityLabel(Text(localized("Gain at \(point.frequency.frequencyLabel)")))
                                    .accessibilityValue(Text(point.gainDB.dbLabel))
                                EditableValueText(
                                    title: localized("Gain"),
                                    value: $point.gainDB,
                                    range: ProfilePersistence.gainRange,
                                    display: point.gainDB.dbLabel,
                                    width: 60
                                )
                                Button(role: .destructive) {
                                    points.removeAll { $0.id == point.id }
                                } label: {
                                    IconButtonLabel(systemImage: "trash", size: 24)
                                }
                                .buttonStyle(.borderless)
                                .disabled(points.count <= 2)
                                .accessibilityLabel(Text(localized("Delete response point")))
                                .accessibilityHint(Text(localized("Removes this magnitude point")))
                            }
                            .accessibilityElement(children: .contain)
                        }
                        Button(localized("Add Point"), systemImage: "plus") {
                            addPoint()
                        }
                        .accessibilityHint(Text(localized("Adds a magnitude point in the largest frequency gap")))
                    }
                }
            } label: {
                Text(localized("Response points (\(points.count))"))
            }
        } header: {
            Text(localized("Target Response"))
        } footer: {
            Text(
                localized(
                    "GlassEQ interpolates these points in log-frequency space and compiles a 16,384-tap minimum-phase filter when you apply the profile."
                ))
        }
    }

    private func addPoint() {
        let sorted = points.sorted { $0.frequency < $1.frequency }
        let candidates = Set([20.0, 20_000.0] + sorted.map(\.frequency))
            .filter { ProfilePersistence.frequencyRange.contains($0) }
            .sorted()
        let widestGap = zip(candidates, candidates.dropFirst()).max { lhs, rhs in
            log(lhs.1 / lhs.0) < log(rhs.1 / rhs.0)
        }
        let frequency = widestGap.map { sqrt($0.0 * $0.1) } ?? 1_000
        let gain = MinimumPhaseFIRCompiler.interpolatedGainDB(
            frequency: frequency,
            points: sorted
        )
        points = (sorted + [EQMagnitudePoint(frequency: frequency, gainDB: gain)])
            .sorted { $0.frequency < $1.frequency }
    }
}

struct ImportedImpulseResponseEditor: View {
    var source: ImpulseResponseSource

    var body: some View {
        Section {
            LabeledContent(
                localized("Length"),
                value: localized("\(source.samples.count) taps")
            )
            LabeledContent(
                localized("Sample rate"),
                value: source.sampleRate.frequencyLabel
            )
        } header: {
            Text(localized("Imported Impulse Response"))
        } footer: {
            Text(localized("GlassEQ preserves the file's phase and samples. To replace it, import another WAV file."))
        }
    }
}

struct GraphicFilterEditor: View {
    @Binding var filters: [EQFilter]

    var body: some View {
        Section(localized("Bands")) {
            // Graphic bands are fixed slots; switching profiles only replaces their values.
            LazyVStack(spacing: 12) {
                ForEach(filters.indices, id: \.self) { index in
                    GraphicFilterRow(filter: $filters[index])
                }
            }
        }
    }
}

private struct GraphicFilterRow: View {
    @Binding var filter: EQFilter

    var body: some View {
        HStack {
            Text(filter.frequency.frequencyLabel)
                .font(.caption.monospacedDigit())
                .frame(width: 64, alignment: .trailing)
            Slider(value: $filter.quantizedGainDB, in: -12...12)
                .accessibilityLabel(Text(localized("Gain at \(filter.frequency.frequencyLabel)")))
                .accessibilityValue(Text(filter.gainDB.dbLabel))
                .accessibilityHint(Text(localized("Adjusts this graphic EQ band")))
            EditableValueText(
                title: localized("Gain"),
                value: $filter.gainDB,
                range: ProfilePersistence.gainRange,
                display: filter.gainDB.dbLabel,
                width: 56,
                valueID: filter.id
            )
        }
        .accessibilityElement(children: .contain)
    }
}

struct ParametricFilterEditor: View {
    @Binding var filters: [EQFilter]
    @State private var selectedFilterID: UUID?
    @State private var showsColumns = false

    var body: some View {
        let layout =
            showsColumns
            ? AnyLayout(HStackLayout(alignment: .top, spacing: 24))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: 16))
        Section(localized("Filters")) {
            layout {
                VStack(alignment: .leading, spacing: 8) {
                    Table(
                        filters, selection: Binding(get: { effectiveSelectedFilterID }, set: { selectedFilterID = $0 })
                    ) {
                        TableColumn(localized("Type")) { filter in
                            Text(filter.kind.title)
                                .foregroundStyle(filter.isEnabled ? .primary : .secondary)
                                .strikethrough(!filter.isEnabled)
                                .accessibilityValue(
                                    Text(filter.isEnabled ? localized("Enabled") : localized("Disabled")))
                        }
                        .width(min: 63, ideal: 77)
                        TableColumn(localized("Freq")) { Text($0.frequency.frequencyLabel) }
                            .width(min: 48, ideal: 58)
                        TableColumn(localized("Gain")) { filter in
                            Text(filter.kind.usesGain ? filter.gainDB.dbLabel : "—")
                        }
                        .width(min: 48, ideal: 58)
                        TableColumn(localized("Q")) { filter in
                            Text(localizedDecimal(filter.q, minimumFractionDigits: 2, maximumFractionDigits: 2))
                        }
                        .width(min: 30, ideal: 36)
                    }
                    .monospacedDigit()
                    .accessibilityLabel(Text(localized("Filters")))
                    .frame(height: min(210, CGFloat(filters.count) * 26 + 34))
                    Button(localized("Add Filter"), systemImage: "plus") {
                        let filter = EQFilter(kind: .peak, frequency: 1_000, gainDB: 0, q: 1)
                        filters.append(filter)
                        selectedFilterID = filter.id
                    }
                    .accessibilityHint(Text(localized("Adds a new parametric filter and selects it")))
                }
                .frame(minWidth: 260, idealWidth: 320, maxWidth: 420)

                if let index = selectedFilterIndex {
                    ParametricFilterInspector(
                        filter: $filters[index],
                        onDelete: {
                            let id = filters[index].id
                            filters.removeAll { $0.id == id }
                            selectedFilterID = filters.first?.id
                        }
                    )
                    .frame(minWidth: 260, maxWidth: .infinity, alignment: .topLeading)
                } else {
                    ContentUnavailableView(localized("No Filter Selected"), systemImage: "slider.horizontal.3")
                        .frame(maxWidth: .infinity, minHeight: 150)
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: Bool.self) { geometry in
                geometry.size.width >= 640
            } action: {
                showsColumns = $0
            }
            .padding(.vertical, 4)
        }
    }

    private var effectiveSelectedFilterID: UUID? {
        if let selectedFilterID,
            filters.contains(where: { $0.id == selectedFilterID })
        {
            return selectedFilterID
        }
        return filters.first?.id
    }

    private var selectedFilterIndex: Int? {
        guard let id = effectiveSelectedFilterID else {
            return nil
        }
        return filters.firstIndex(where: { $0.id == id })
    }
}

private extension FilterKind {
    var usesGain: Bool { self != .highPass && self != .lowPass }
}

struct ParametricFilterInspector: View {
    @Binding var filter: EQFilter
    var onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(localized("Selected Filter"))
                    .font(.headline)
                Spacer()
                Text(localized("Enabled"))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Toggle(localized("Enabled"), isOn: $filter.isEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .accessibilityLabel(Text(localized("Filter enabled")))
                    .accessibilityValue(Text(filter.isEnabled ? localized("On") : localized("Off")))
                    .accessibilityHint(Text(localized("Includes or bypasses this filter")))
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    IconButtonLabel(systemImage: "trash")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text(localized("Delete filter")))
                .accessibilityHint(Text(localized("Removes the selected filter")))
            }
            .frame(height: 28)

            LabeledContent(localized("Type")) {
                Picker(localized("Type"), selection: $filter.kind) {
                    ForEach(FilterKind.allCases, id: \.self) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .labelsHidden()
                .accessibilityLabel(Text(localized("Filter type")))
                .accessibilityValue(Text(filter.kind.title))
                .accessibilityHint(Text(localized("Changes the selected filter type")))
            }

            SliderRow(
                title: localized("Frequency"),
                value: $filter.frequency,
                range: 20...20_000,
                validationRange: ProfilePersistence.frequencyRange,
                step: 1,
                suffix: "Hz",
                scale: .logarithmic,
                valueID: filter.id
            )
            SliderRow(
                title: localized("Gain"),
                value: $filter.gainDB,
                range: -24...24,
                validationRange: ProfilePersistence.gainRange,
                step: 0.1,
                suffix: "dB",
                valueID: filter.id
            )
            .disabled(!filter.kind.usesGain)
            SliderRow(
                title: localized("Q"),
                value: $filter.q,
                range: 0.1...10,
                validationRange: ProfilePersistence.qRange,
                step: 0.01,
                suffix: "",
                valueID: filter.id
            )
        }
    }
}
