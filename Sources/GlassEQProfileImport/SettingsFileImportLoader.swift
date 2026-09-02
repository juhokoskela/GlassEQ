import Foundation
import GlassEQCore
import GlassEQSettingsIPC

public enum SettingsFileImportLoader {
    public static func load(
        mode: SettingsFileImportMode,
        urls: [URL]
    ) throws -> SettingsFileImportSelectionDTO {
        switch mode {
        case .single:
            let url = urls[0]
            if isWAV(url) {
                return selection(for: try ImpulseResponseWAVImporter.load(from: url))
            }
            return .text(
                suggestedName: url.deletingPathExtension().lastPathComponent,
                filename: url.lastPathComponent,
                text: try ProfileTextFileReader.read(url)
            )

        case .stereoPair:
            let leftURL = urls[0]
            let rightURL = urls[1]
            guard isWAV(leftURL) == isWAV(rightURL) else {
                throw StereoTextPairImportError.filesMustUseSameFormat
            }
            if isWAV(leftURL) {
                return selection(for: try ImpulseResponseWAVImporter.loadStereoPair(
                    leftURL: leftURL,
                    rightURL: rightURL
                ))
            }
            let imported = try StereoTextPairImporter.load(
                leftURL: leftURL,
                rightURL: rightURL
            )
            return .stereoText(
                profile: imported.profile,
                leftFilename: imported.leftFilename,
                rightFilename: imported.rightFilename
            )
        }
    }

    private static func isWAV(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "wav"
    }

    private static func selection(
        for imported: ImportedImpulseResponse
    ) -> SettingsFileImportSelectionDTO {
        let channels: [ImportedImpulseResponse.Channel] = switch imported.channels {
        case .mono(let channel):
            [channel]
        case let .stereo(left, right):
            [left, right]
        }
        return .impulseResponse(
            profile: imported.profile,
            channels: channels.map {
                SettingsImpulseResponseChannelDTO(
                    filename: $0.filename,
                    frameCount: $0.frameCount,
                    sampleRate: $0.sampleRate
                )
            },
            sourceFileCount: imported.sourceFileCount
        )
    }
}

extension ImportedImpulseResponse.Channels {
    public init?(_ channels: [SettingsImpulseResponseChannelDTO]) {
        let converted = channels.map {
            ImportedImpulseResponse.Channel(
                filename: $0.filename,
                frameCount: $0.frameCount,
                sampleRate: $0.sampleRate
            )
        }
        switch converted.count {
        case 1:
            self = .mono(converted[0])
        case 2:
            self = .stereo(left: converted[0], right: converted[1])
        default:
            return nil
        }
    }
}
