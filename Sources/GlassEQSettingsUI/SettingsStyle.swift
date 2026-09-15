import AppKit
import SwiftUI

public extension Color {
    static let macOSSystemGreen = Color(nsColor: .systemGreen)
    static let macOSSystemRed = Color(nsColor: .systemRed)
    static let macOSSystemYellow = Color(nsColor: .systemYellow)
    static let macOSSystemOrange = Color(nsColor: .systemOrange)
    static let macOSWindowBackground = Color(nsColor: .windowBackgroundColor)
    static let macOSControlBackground = Color(nsColor: .controlBackgroundColor)
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
