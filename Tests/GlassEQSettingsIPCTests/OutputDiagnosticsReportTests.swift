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

}
