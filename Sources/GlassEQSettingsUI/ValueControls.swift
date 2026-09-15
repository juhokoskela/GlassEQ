import SwiftUI

extension EnvironmentValues {
    @Entry var editorContext: EditorContextID?
}

struct EditableValueContext: Equatable {
    var editor: EditorContextID?
    var valueID: UUID?
}

enum SliderScale {
    case linear
    case logarithmic
}

struct SliderRow: View {
    var title: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var validationRange: ClosedRange<Double>? = nil
    var step: Double
    var suffix: String
    var scale = SliderScale.linear
    var valueID: UUID?

    var body: some View {
        LabeledContent(title) {
            Slider(value: sliderValue, in: sliderRange)
                .accessibilityLabel(Text(title))
                .accessibilityValue(Text(label))
                .accessibilityHint(Text(localized("Adjusts \(title.lowercased())")))
            EditableValueText(
                title: title,
                value: $value,
                range: validationRange ?? range,
                display: label,
                valueID: valueID
            )
        }
    }

    private var sliderValue: Binding<Double> {
        switch scale {
        case .linear:
            $value[quantizedTo: step]
        case .logarithmic:
            Binding(
                get: { log10(min(max(value, range.lowerBound), range.upperBound)) },
                set: {
                    let restored = min(max(pow(10, $0), range.lowerBound), range.upperBound)
                    value = quantized(restored, step: step)
                }
            )
        }
    }

    private var sliderRange: ClosedRange<Double> {
        switch scale {
        case .linear:
            range
        case .logarithmic:
            log10(range.lowerBound)...log10(range.upperBound)
        }
    }

    private var label: String {
        if suffix == "Hz" {
            return value.frequencyLabel
        }
        if suffix == "dB" {
            return value.dbLabel
        }
        return localizedDecimal(value, minimumFractionDigits: 2, maximumFractionDigits: 2)
    }
}

// Value readout that becomes a text field on click, so exact values can be typed instead of
// approximated by dragging the slider.
struct EditableValueText: View {
    var title: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var display: String
    var width: CGFloat = 64
    var valueID: UUID?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.editorContext) private var editorContext
    @State private var isEditing = false
    @State private var editText = ""
    @State private var editSession = EditableValueEditSession()
    @FocusState private var isFocused: Bool

    var body: some View {
        Group {
            if isEditing {
                TextField(title, text: $editText)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption.monospacedDigit())
                    .multilineTextAlignment(.trailing)
                    .focused($isFocused)
                    .onAppear {
                        isFocused = true
                    }
                    .onSubmit(commit)
                    .onExitCommand(perform: cancel)
                    .onChange(of: editText) { _, text in
                        updateValue(from: text)
                    }
                    .onChange(of: value) { _, newValue in
                        guard isEditing,
                              editSession.valueChanged(newValue) else {
                            return
                        }
                        editText = editableNumberText(newValue)
                        isEditing = false
                    }
                    .onChange(of: isFocused) { _, focused in
                        if !focused {
                            commit()
                        }
                    }
            } else {
                Button {
                    editText = editableNumberText(value)
                    editSession.begin(value: value, context: context)
                    isEditing = true
                } label: {
                    Text(display)
                        .font(.caption.monospacedDigit())
                        .contentTransition(.numericText(value: value))
                        .animation(reduceMotion ? nil : .snappy(duration: 0.15), value: value)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(localized("Click to type a value"))
            }
        }
        .frame(width: width)
        .accessibilityLabel(Text(localized("\(title) value")))
        .accessibilityValue(Text(display))
        .accessibilityHint(Text(localized("Edits \(title.lowercased()) as text")))
        .onChange(of: context) {
            if isEditing { finishEditing() }
        }
        .transaction(value: context) { $0.disablesAnimations = true }
    }

    private var context: EditableValueContext {
        EditableValueContext(editor: editorContext, valueID: valueID)
    }

    private func finishEditing() {
        editSession.finish()
        isEditing = false
        isFocused = false
    }

    private func commit() {
        guard isEditing else {
            return
        }
        guard updateValue(from: editText) else {
            cancel()
            return
        }
        finishEditing()
    }

    private func cancel() {
        if editSession.isActive(in: context), let originalValue = editSession.cancel() {
            value = originalValue
        }
        finishEditing()
    }

    @discardableResult
    private func updateValue(from text: String) -> Bool {
        guard isEditing, editSession.isActive(in: context),
              let parsed = clampedEditableNumber(text, range: range) else {
            return false
        }
        editSession.recordTextDrivenValue(parsed)
        value = parsed
        return true
    }
}

struct EditableValueEditSession: Equatable {
    private var originalValue: Double?
    private var textDrivenValue: Double?
    private var context: EditableValueContext?

    mutating func begin(value: Double, context: EditableValueContext = EditableValueContext()) {
        originalValue = value
        textDrivenValue = nil
        self.context = context
    }

    func isActive(in context: EditableValueContext) -> Bool {
        originalValue != nil && self.context == context
    }

    mutating func recordTextDrivenValue(_ value: Double) {
        textDrivenValue = value
    }

    mutating func valueChanged(_ value: Double) -> Bool {
        if textDrivenValue == value {
            textDrivenValue = nil
            return false
        }
        finish()
        return true
    }

    mutating func cancel() -> Double? {
        let value = originalValue
        finish()
        return value
    }

    mutating func finish() {
        originalValue = nil
        textDrivenValue = nil
        context = nil
    }
}
