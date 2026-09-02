import GlassEQSettingsIPC
import Testing
@testable import GlassEQSettingsUI

@Suite
struct OutputDiagnosticsReportTests {
    @Test
    func addedLatencyUsesTapTimingForLowLatencyRoutes() {
        var snapshot = SettingsSnapshotDTO.disconnected
        snapshot.metrics = SettingsAudioMetricsDTO(
            tapToOutputLatencyObservations: 1,
            averageTapToOutputLatencyNanoseconds: 1_500_000
        )

        #expect(outputAddedLatencyLabel(snapshot) == localizedLatency(milliseconds: 1.5))
    }

    @Test
    func addedLatencyUsesBufferedFramesForCompatibilityRoutes() {
        var snapshot = SettingsSnapshotDTO.disconnected
        snapshot.currentOutputSampleRate = 48_000
        snapshot.metrics = SettingsAudioMetricsDTO(
            averagePlaybackBufferedFrames: 480,
            playbackBufferObservations: 1,
            playbackBufferSampleRate: 48_000,
            diagnostics: SettingsAudioDiagnosticsDTO(
                status: SettingsAudioStatusDTO(routeMode: .compatibility)
            )
        )

        #expect(outputAddedLatencyLabel(snapshot) == localizedLatency(milliseconds: 10))
    }
}
