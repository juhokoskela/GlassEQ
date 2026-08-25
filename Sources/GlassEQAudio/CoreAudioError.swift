import CoreAudio
import Darwin
import Foundation

public struct CoreAudioError: Error, Equatable, CustomStringConvertible, Sendable {
    public var operation: String
    public var status: OSStatus

    public init(operation: String, status: OSStatus) {
        self.operation = operation
        self.status = status
    }

    public var description: String {
        "\(operation) failed with OSStatus \(formatOSStatus(status))"
    }
}

public struct AudioEngineFailure: Error, Equatable, Sendable, CustomStringConvertible {
    public enum Category: Equatable, Sendable {
        case systemAudioCapturePermission
        case outputDeviceUnavailable
        case deviceFormatUnsupported
        case coreAudioOperationFailed
    }

    public var category: Category
    public var userMessage: String
    public var operation: String
    public var status: OSStatus?
    public var statusFourCC: String?

    public init(
        category: Category,
        userMessage: String,
        operation: String,
        status: OSStatus? = nil
    ) {
        self.category = category
        self.userMessage = userMessage
        self.operation = operation
        self.status = status
        self.statusFourCC = status.flatMap(formatOSStatusFourCC)
    }

    public var description: String {
        guard let status else {
            return "\(userMessage) Operation: \(operation)."
        }

        return "\(userMessage) Operation: \(operation). OSStatus: \(formatOSStatus(status))."
    }
}

public enum AudioEngineStatus: Equatable, Sendable {
    case stopped
    case starting
    case running(output: AudioOutputDevice)
    case permissionRequired(AudioEngineFailure)
    case failed(AudioEngineFailure)
}

public func formatOSStatusDecimal(_ status: OSStatus) -> String {
    "\(status)"
}

public func formatOSStatusFourCC(_ status: OSStatus) -> String? {
    let value = UInt32(bitPattern: status)
    let bytes = [
        UInt8((value >> 24) & 0xff),
        UInt8((value >> 16) & 0xff),
        UInt8((value >> 8) & 0xff),
        UInt8(value & 0xff)
    ]
    guard bytes.allSatisfy({ byte in byte >= 0x20 && byte <= 0x7e }) else {
        return nil
    }
    return String(bytes: bytes, encoding: .ascii)
}

public func formatOSStatus(_ status: OSStatus) -> String {
    guard let fourCC = formatOSStatusFourCC(status) else {
        return formatOSStatusDecimal(status)
    }
    return "\(formatOSStatusDecimal(status)) ('\(fourCC)')"
}

public func classifyCoreAudioError(_ error: CoreAudioError) -> AudioEngineFailure {
    classifyCoreAudioError(operation: error.operation, status: error.status)
}

public func classifyCoreAudioError(operation: String, status: OSStatus) -> AudioEngineFailure {
    if isSystemAudioCapturePermissionFailure(operation: operation, status: status) {
        return AudioEngineFailure(
            category: .systemAudioCapturePermission,
            userMessage: "System audio capture permission is required before GlassEQ can start capturing system audio.",
            operation: operation,
            status: status
        )
    }

    if status == kAudioDeviceUnsupportedFormatError {
        return AudioEngineFailure(
            category: .deviceFormatUnsupported,
            userMessage: "The selected output device format is not supported by the GlassEQ audio engine.",
            operation: operation,
            status: status
        )
    }

    if isOutputDeviceUnavailableFailure(operation: operation, status: status) {
        return AudioEngineFailure(
            category: .outputDeviceUnavailable,
            userMessage: "No usable output device is available for the GlassEQ audio engine.",
            operation: operation,
            status: status
        )
    }

    return AudioEngineFailure(
        category: .coreAudioOperationFailed,
        userMessage: "A Core Audio operation failed while starting or running the GlassEQ audio engine.",
        operation: operation,
        status: status
    )
}

private func isSystemAudioCapturePermissionFailure(operation: String, status: OSStatus) -> Bool {
    let isPermissionStatus = status == kAudioDevicePermissionsError
        || status == kAudioHardwareIllegalOperationError
        || status == OSStatus(EPERM)
    return isPermissionStatus && isSystemAudioCaptureOperation(operation)
}

private func isSystemAudioCaptureOperation(_ operation: String) -> Bool {
    let createsProcessTap = operation == "AudioHardwareCreateProcessTap"
        || operation.hasPrefix("AudioHardwareCreateProcessTap(")
    if createsProcessTap {
        return true
    }

    switch operation {
    case "AudioDeviceStart(capture tap)",
         "AudioDeviceStart(combined aggregate)",
         "AudioDeviceStart(profile rebuild mute tap)":
        return true
    default:
        return false
    }
}

private func isOutputDeviceUnavailableFailure(operation: String, status: OSStatus) -> Bool {
    if status == kAudioHardwareBadDeviceError || status == kAudioHardwareBadObjectError {
        return true
    }

    return operation.localizedCaseInsensitiveContains("output")
        && status == kAudioHardwareNotRunningError
}

@inline(__always)
func checkOSStatus(_ status: OSStatus, operation: String) throws {
    guard status == noErr else {
        throw CoreAudioError(operation: operation, status: status)
    }
}
