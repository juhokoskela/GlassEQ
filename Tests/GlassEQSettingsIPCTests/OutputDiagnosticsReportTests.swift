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

@Suite
struct OutputDiagnosticsReportTextTests {
    @Test
    func supportTextCanLeaveOutTheOutputUIDRow() {
        var snapshot = SettingsSnapshotDTO.disconnected
        snapshot.currentOutputName = "USB DAC"
        snapshot.currentOutputUID = "usb-serial-1234"
        let report = OutputDiagnosticsReport(snapshot: snapshot)

        #expect(report.text.contains("usb-serial-1234"))
        #expect(!report.supportText.contains("usb-serial-1234"))
        #expect(!report.supportText.contains("Output: USB DAC"))
        #expect(!report.supportText.contains("Active profile:"))
        #expect(!report.supportText.contains("Status:"))
        #expect(report.supportText.contains("## Observation"))
    }
}
