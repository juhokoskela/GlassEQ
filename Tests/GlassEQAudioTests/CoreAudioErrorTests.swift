import CoreAudio
import Darwin
import GlassEQAudio
import Testing

@Suite
struct CoreAudioErrorTests {
    @Test
    func formatsOSStatusAsDecimalAndFourCC() {
        let unsupportedDataStatus = fourCC("!dat")

        #expect(formatOSStatusDecimal(OSStatus(-50)) == "-50")
        #expect(formatOSStatusFourCC(unsupportedDataStatus) == "!dat")
        #expect(formatOSStatus(unsupportedDataStatus) == "\(unsupportedDataStatus) ('!dat')")
        #expect(formatOSStatusFourCC(OSStatus(EPERM)) == nil)
    }

    @Test
    func classifiesCapturePermissionFailuresForProductionOperations() {
        let operations = [
            "AudioHardwareCreateProcessTap",
            "AudioHardwareCreateProcessTap(main)",
            "AudioHardwareCreateProcessTap(system sounds)",
            "AudioDeviceStart(capture tap)",
            "AudioDeviceStart(combined aggregate)",
            "AudioDeviceStart(profile rebuild mute tap)"
        ]
        let statuses = [
            kAudioDevicePermissionsError,
            kAudioHardwareIllegalOperationError,
            OSStatus(EPERM)
        ]

        for operation in operations {
            for status in statuses {
                let failure = classifyCoreAudioError(operation: operation, status: status)

                #expect(failure.category == .systemAudioCapturePermission)
                #expect(failure.operation == operation)
                #expect(failure.status == status)
                #expect(failure.statusFourCC == formatOSStatusFourCC(status))
            }
        }
    }

    @Test
    func doesNotClassifyNonCaptureOperationsAsPermissionFailures() {
        let cases: [(String, OSStatus, AudioEngineFailure.Category)] = [
            ("AudioDeviceStart(physical-first aggregate)", kAudioDevicePermissionsError, .coreAudioOperationFailed),
            ("AudioDeviceStart(default output)", OSStatus(EPERM), .coreAudioOperationFailed),
            (
                "AudioDeviceSetPropertyData(output device format)",
                kAudioHardwareIllegalOperationError,
                .coreAudioOperationFailed
            ),
            ("AudioHardwareCreateProcessTapMetadata", kAudioHardwareIllegalOperationError, .coreAudioOperationFailed),
            ("AudioHardwareCreateProcessTap(main)", kAudioDeviceUnsupportedFormatError, .deviceFormatUnsupported)
        ]

        for (operation, status, expectedCategory) in cases {
            let failure = classifyCoreAudioError(operation: operation, status: status)

            #expect(failure.category == expectedCategory)
        }
    }

    @Test
    func classifiesDeviceFormatAndOutputFailures() {
        let formatFailure = classifyCoreAudioError(
            operation: "AudioDeviceCreateIOProcIDWithBlock(output)",
            status: kAudioDeviceUnsupportedFormatError
        )
        let outputFailure = classifyCoreAudioError(
            operation: "AudioDeviceStart(default output)",
            status: kAudioHardwareBadDeviceError
        )

        #expect(formatFailure.category == .deviceFormatUnsupported)
        #expect(formatFailure.statusFourCC == "!dat")
        #expect(outputFailure.category == .outputDeviceUnavailable)
        #expect(outputFailure.statusFourCC == "!dev")
    }
}

private func fourCC(_ value: String) -> OSStatus {
    var status = UInt32(0)
    for byte in value.utf8 {
        status = (status << 8) | UInt32(byte)
    }
    return OSStatus(bitPattern: status)
}
