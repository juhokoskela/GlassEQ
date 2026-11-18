import Foundation

public struct AggregateAudioRouteFingerprint: Codable, Equatable, Hashable, Sendable {
    package static let maximumSampleRate = 768_000.0
    package static let maximumChannelCount = 256

    public var outputDeviceUID: String
    public var nativeOutputStreamIndex: Int
    public var nominalSampleRate: Int64

    public init(
        outputDeviceUID: String,
        nativeOutputStreamIndex: Int,
        nominalSampleRate: Double
    ) {
        self.outputDeviceUID = outputDeviceUID
        self.nativeOutputStreamIndex = nativeOutputStreamIndex
        if nominalSampleRate.isFinite,
            nominalSampleRate > 0,
            nominalSampleRate <= Self.maximumSampleRate
        {
            self.nominalSampleRate = Int64(nominalSampleRate.rounded())
        } else {
            self.nominalSampleRate = 0
        }
    }

    public var isValid: Bool {
        !outputDeviceUID.isEmpty
            && outputDeviceUID.utf8.count <= 512
            && nativeOutputStreamIndex >= 0
            && nativeOutputStreamIndex < Self.maximumChannelCount
            && nominalSampleRate > 0
            && nominalSampleRate <= Int64(Self.maximumSampleRate)
    }
}

public enum AggregateBufferMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case automatic
    case frames16
    case frames32
    case frames64
    case frames128

    public var id: String { rawValue }
}

public struct OutputBufferPreference: Codable, Equatable, Sendable {
    public let route: AggregateAudioRouteFingerprint
    public let mode: AggregateBufferMode

    public init(route: AggregateAudioRouteFingerprint, mode: AggregateBufferMode) {
        self.route = route
        self.mode = mode
    }
}
