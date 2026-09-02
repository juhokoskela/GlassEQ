import AppKit
import SwiftUI

extension Color {
    static let macOSSystemRed = Color(nsColor: .systemRed)
    static let cardBorder = Color.primary.opacity(0.08)
}

private struct CardModifier<Fill: ShapeStyle>: ViewModifier {
    var fill: Fill
    var border: Color
    var cornerRadius: CGFloat
    var padding: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .padding(padding)
            .background(fill, in: shape)
            .overlay {
                shape.strokeBorder(border, lineWidth: 1)
            }
    }
}

extension View {
    func card<Fill: ShapeStyle>(
        fill: Fill,
        border: Color = .cardBorder,
        cornerRadius: CGFloat,
        padding: CGFloat = 0
    ) -> some View {
        modifier(CardModifier(fill: fill, border: border, cornerRadius: cornerRadius, padding: padding))
    }

    func cardPanel(padding: CGFloat = 16, cornerRadius: CGFloat = 16) -> some View {
        card(fill: Color(nsColor: .controlBackgroundColor), cornerRadius: cornerRadius, padding: padding)
    }
}

struct SettingRow<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 88, alignment: .leading)
            content
        }
    }
}

struct GraphLegendItem: View {
    var color: Color
    var title: String

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// Square icon-only button label with a comfortable hit target.
struct IconButtonLabel: View {
    var systemImage: String
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: systemImage)
            .frame(width: size, height: size)
            .contentShape(.rect)
    }
}

// Text-and-icon button label sized to match the icon buttons beside it.
struct ActionButtonLabel: View {
    var title: String
    var systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .frame(minHeight: 28)
            .contentShape(.rect)
    }
}

// Footer action button. A custom style is the only way to make the disabled state less faint than
// the system default (which can't be lightened on a native `.disabled()` button), and the flatter
// look reads more like a precise tool than a consumer app.
struct ToolbarButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        ToolbarButtonLabel(configuration: configuration, prominent: prominent)
    }

    private struct ToolbarButtonLabel: View {
        let configuration: ButtonStyleConfiguration
        let prominent: Bool
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
            return configuration.label
                .font(.body)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(minHeight: 30)
                .foregroundStyle(prominent ? Color.white : Color.primary)
                .background(fillColor(pressed: configuration.isPressed), in: shape)
                .overlay { shape.stroke(Color.primary.opacity(prominent ? 0 : 0.14), lineWidth: 1) }
                .opacity(isEnabled ? 1 : 0.5)
                .contentShape(shape)
        }

        private func fillColor(pressed: Bool) -> Color {
            if prominent {
                return Color.accentColor.opacity(pressed ? 0.82 : 1)
            }
            return Color.primary.opacity(pressed ? 0.14 : 0.07)
        }
    }
}
