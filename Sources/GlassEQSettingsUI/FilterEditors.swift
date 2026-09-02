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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(localized("Target Response"))
                    .font(.headline)
                Spacer()
                Button {
                    addPoint()
                } label: {
                    ActionButtonLabel(title: localized("Add Point"), systemImage: "plus")
                }
                .controlSize(.large)
                .accessibilityHint(Text(localized("Adds a magnitude point in the largest frequency gap")))
            }

            Text(localized("GlassEQ interpolates these points in log-frequency space and compiles a 16,384-tap minimum-phase filter when you apply the profile."))
                .font(.caption)
                .foregroundStyle(.secondary)

            LazyVStack(spacing: 6) {
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
                            .frame(maxWidth: 640)
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
            }
        }
        .padding(.vertical, 4)
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
        VStack(alignment: .leading, spacing: 10) {
            Label(localized("Imported Impulse Response"), systemImage: "waveform")
                .font(.headline)
            LabeledContent(
                localized("Length"),
                value: localized("\(source.samples.count) taps")
            )
            LabeledContent(
                localized("Sample rate"),
                value: source.sampleRate.frequencyLabel
            )
            Text(localized("GlassEQ preserves the file's phase and samples. To replace it, import another WAV file."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct GraphicFilterEditor: View {
    @Binding var filters: [EQFilter]

    var body: some View {
        VStack(spacing: 10) {
            ForEach($filters) { $filter in
                HStack {
                    Text(filter.frequency.frequencyLabel)
                        .font(.caption.monospacedDigit())
                        .frame(width: 64, alignment: .trailing)
                    Slider(value: $filter.quantizedGainDB, in: -12...12)
                        .frame(maxWidth: 640)
                        .accessibilityLabel(Text(localized("Gain at \(filter.frequency.frequencyLabel)")))
                        .accessibilityValue(Text(filter.gainDB.dbLabel))
                        .accessibilityHint(Text(localized("Adjusts this graphic EQ band")))
                    EditableValueText(
                        title: localized("Gain"),
                        value: $filter.gainDB,
                        range: ProfilePersistence.gainRange,
                        display: filter.gainDB.dbLabel,
                        width: 56
                    )
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(Text(localized("Graphic filter row")))
                .accessibilityValue(Text(localized("\(filter.frequency.frequencyLabel), \(filter.gainDB.dbLabel)")))
            }
        }
        .padding(.vertical, 4)
    }
}

struct ParametricFilterEditor: View {
    @Binding var filters: [EQFilter]
    @State private var selectedFilterID: UUID?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(localized("Filters"))
                        .font(.headline)
                    Button {
                        let filter = EQFilter(kind: .peak, frequency: 1_000, gainDB: 0, q: 1)
                        filters.append(filter)
                        selectedFilterID = filter.id
                    } label: {
                        ActionButtonLabel(title: localized("Add Filter"), systemImage: "plus")
                    }
                    .controlSize(.large)
                    .accessibilityHint(Text(localized("Adds a new parametric filter and selects it")))
                    Spacer()
                }

                FilterListHeader()

                LazyVStack(spacing: 4) {
                    ForEach(filters) { filter in
                        CompactFilterRow(
                            filter: filter,
                            isSelected: filter.id == effectiveSelectedFilterID
                        ) {
                            selectedFilterID = filter.id
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(minWidth: 260, idealWidth: 320, maxWidth: 420)
            .cardPanel(padding: 16)

            if let index = selectedFilterIndex {
                ParametricFilterInspector(
                    filter: $filters[index],
                    onDelete: {
                        let id = filters[index].id
                        filters.removeAll { $0.id == id }
                        selectedFilterID = filters.first?.id
                    }
                )
                .id(filters[index].id)
                .frame(minWidth: 260, maxWidth: .infinity, alignment: .topLeading)
            } else {
                ContentUnavailableView(localized("No Filter Selected"), systemImage: "slider.horizontal.3")
                    .cardPanel(padding: 16)
                    .frame(maxWidth: .infinity, minHeight: 150)
            }
        }
    }

    private var effectiveSelectedFilterID: UUID? {
        if let selectedFilterID,
           filters.contains(where: { $0.id == selectedFilterID }) {
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

struct FilterListHeader: View {
    var body: some View {
        HStack {
            Color.clear
                .frame(width: 20, height: 0)
            Text(localized("Type"))
                .frame(width: 54, alignment: .leading)
            Text(localized("Freq"))
                .frame(width: 64, alignment: .trailing)
            Text(localized("Gain"))
                .frame(width: 64, alignment: .trailing)
            Text(localized("Q"))
                .frame(width: 46, alignment: .trailing)
            Spacer()
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
    }
}

struct CompactFilterRow: View {
    var filter: EQFilter
    var isSelected: Bool
    var onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack {
                Image(systemName: filter.isEnabled ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(filter.isEnabled ? Color.accentColor : Color.secondary)
                    .frame(width: 20)
                Text(filter.kind.shortTitle)
                    .frame(width: 54, alignment: .leading)
                Text(filter.frequency.frequencyLabel)
                    .font(.caption.monospacedDigit())
                    .frame(width: 64, alignment: .trailing)
                Text(filter.gainDB.dbLabel)
                    .font(.caption.monospacedDigit())
                    .frame(width: 64, alignment: .trailing)
                Text(qLabel)
                    .font(.caption.monospacedDigit())
                    .frame(width: 46, alignment: .trailing)
                Spacer()
            }
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            .card(
                fill: isSelected ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.035),
                border: isSelected ? Color.accentColor.opacity(0.55) : Color.clear,
                cornerRadius: 8
            )
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel(Text(localized("Filter \(filter.kind.title)")))
        .accessibilityValue(Text(accessibilityValue))
        .accessibilityHint(Text(localized("Selects this filter for editing")))
    }

    private var qLabel: String {
        localizedDecimal(filter.q, minimumFractionDigits: 2, maximumFractionDigits: 2)
    }

    private var accessibilityValue: String {
        let state = filter.isEnabled ? localized("Enabled") : localized("Disabled")
        let selection = isSelected ? localized("Selected") : localized("Not selected")
        return localized("\(state), \(selection), \(filter.frequency.frequencyLabel), \(filter.gainDB.dbLabel), Q \(qLabel)")
    }
}

struct ParametricFilterInspector: View {
    @Binding var filter: EQFilter
    var onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Text(localized("Selected Filter"))
                    .font(.headline)
                Toggle(localized("Enabled"), isOn: $filter.isEnabled)
                    .toggleStyle(.switch)
                    .accessibilityLabel(Text(localized("Filter enabled")))
                    .accessibilityValue(Text(filter.isEnabled ? localized("On") : localized("Off")))
                    .accessibilityHint(Text(localized("Includes or bypasses this filter")))
                Spacer()
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    IconButtonLabel(systemImage: "trash")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text(localized("Delete filter")))
                .accessibilityHint(Text(localized("Removes the selected filter")))
            }

            SettingRow(title: localized("Type")) {
                Picker(localized("Type"), selection: $filter.kind) {
                    ForEach(FilterKind.allCases, id: \.self) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 260)
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
                scale: .logarithmic
            )
            SliderRow(
                title: localized("Gain"),
                value: $filter.gainDB,
                range: -24...24,
                validationRange: ProfilePersistence.gainRange,
                step: 0.1,
                suffix: "dB"
            )
            SliderRow(
                title: localized("Q"),
                value: $filter.q,
                range: 0.1...10,
                validationRange: ProfilePersistence.qRange,
                step: 0.01,
                suffix: ""
            )
        }
        .cardPanel(padding: 16)
    }
}
