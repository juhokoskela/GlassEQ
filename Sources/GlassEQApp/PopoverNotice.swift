import SwiftUI

struct PopoverNotice: View {
    let symbol: String
    let title: String
    let message: String
    let dismiss: () -> Void
    var showSupportReport: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: symbol)
                    .foregroundStyle(Color.macOSSystemOrange)
                    .accessibilityHidden(true)
                Text(message)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .frame(width: 20, height: 20)
                        .contentShape(.rect)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text(localized("Dismiss")))
            }
            if let showSupportReport {
                Button(localized("Support Report…"), action: showSupportReport)
                    .controlSize(.small)
            }
        }
        .font(.caption)
        .padding(10)
        .background(Color.macOSSystemOrange.opacity(0.12), in: .rect(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(title))
    }
}
