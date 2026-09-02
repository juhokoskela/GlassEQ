import GlassEQCore
import GlassEQProfileImport
import SwiftUI

struct ImportedImpulseResponseSummary: View {
    @Binding var imported: ImportedImpulseResponse

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(localized("Impulse response"), systemImage: "waveform")
                    .font(.headline)
                Spacer()
                if case .stereo = imported.channels {
                    Button(localized("Swap L/R")) {
                        imported.swapStereoChannels()
                    }
                }
            }
            switch imported.channels {
            case .mono(let channel):
                LabeledContent(localized("Length"), value: localized("\(channel.frameCount) taps"))
                LabeledContent(localized("Channels"), value: localized("Mono"))
            case let .stereo(left, right):
                LabeledContent(localized("Left"), value: description(of: left))
                LabeledContent(localized("Right"), value: description(of: right))
            }
            LabeledContent(
                localized("Sample rate"),
                value: ImportedImpulseResponse.sampleRateLabel(imported.sampleRate)
            )
            Text(localized("GlassEQ will convolve audio with these samples directly; it will not reconstruct or normalize the file."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .importedSourceCard()
    }

    private func description(of channel: ImportedImpulseResponse.Channel) -> String {
        localized("\(channel.filename) · \(channel.frameCount) taps")
    }
}

struct ImportedStereoTextPairSummary: View {
    @Binding var imported: ImportedStereoTextPair

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(localized("Separate left and right settings"), systemImage: "slider.horizontal.3")
                    .font(.headline)
                Spacer()
                Button(localized("Swap L/R")) {
                    imported.swapChannels()
                }
            }
            LabeledContent(localized("Left"), value: imported.leftFilename)
            LabeledContent(localized("Right"), value: imported.rightFilename)
            LabeledContent(localized("Profile type"), value: imported.profile.mode.importPairTitle)
            Text(localized("GlassEQ parsed each file independently and will keep its filters and preamp on the assigned channel."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .importedSourceCard()
    }
}

private extension View {
    func importedSourceCard() -> some View {
        padding(16)
            .frame(maxWidth: .infinity, minHeight: 230, alignment: .topLeading)
            .background(
                Color(nsColor: .controlBackgroundColor).opacity(0.7),
                in: .rect(cornerRadius: 10)
            )
    }
}

private extension EQMode {
    var importPairTitle: String {
        switch self {
        case .parametric:
            localized("Parametric")
        case .graphic10:
            localized("10-band")
        case .graphic31:
            localized("31-band")
        case .convolution:
            localized("Convolution")
        }
    }
}
