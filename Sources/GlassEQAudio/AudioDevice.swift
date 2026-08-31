import CoreAudio
import Foundation

public struct AudioOutputDevice: Equatable, Sendable {
    public var id: AudioObjectID
    public var uid: String
    public var name: String
    public var nominalSampleRate: Double
    public var outputChannelCount: Int
    public var bufferFrameSize: UInt32
    public var transportType: UInt32?

    public init(
        id: AudioObjectID,
        uid: String,
        name: String,
        nominalSampleRate: Double,
        outputChannelCount: Int,
        bufferFrameSize: UInt32,
        transportType: UInt32? = nil
    ) {
        self.id = id
        self.uid = uid
        self.name = name
        self.nominalSampleRate = nominalSampleRate
        self.outputChannelCount = outputChannelCount
        self.bufferFrameSize = bufferFrameSize
        self.transportType = transportType
    }

    public var isBluetoothTransport: Bool {
        transportType == kAudioDeviceTransportTypeBluetooth
            || transportType == kAudioDeviceTransportTypeBluetoothLE
    }
}

public struct AudioBufferFrameSizeRange: Equatable, Sendable {
    public var minimum: UInt32
    public var maximum: UInt32

    public init(minimum: UInt32, maximum: UInt32) {
        self.minimum = minimum
        self.maximum = maximum
    }
}

public enum AudioDeviceAvailabilityError: Error, Equatable, LocalizedError, CustomStringConvertible, Sendable {
    case noDefaultOutput
    case outputDeviceNotAlive(AudioObjectID)
    case outputDeviceHasNoOutputChannels(AudioObjectID)
    case unsupportedOutputChannelCount(AudioObjectID, Int)
    case unsupportedOutputBufferFrameSize(AudioObjectID, UInt32, maximum: UInt32)
    case unsupportedPlaybackConversionBuffer(AudioObjectID, requiredPrimeFrames: Int, maximumPrimeFrames: Int)
    case invalidDeviceMetadata(AudioObjectID, String)

    public var description: String {
        switch self {
        case .noDefaultOutput:
            "No default output device is available"
        case .outputDeviceNotAlive(let id):
            "Output device \(id) is not available"
        case .outputDeviceHasNoOutputChannels(let id):
            "Output device \(id) has no output channels"
        case .unsupportedOutputChannelCount(let id, let channelCount):
            "Output device \(id) reports channel count \(channelCount); GlassEQ supports up to \(CoreAudioDeviceQuery.maxChannelCount) output channels"
        case .unsupportedOutputBufferFrameSize(let id, let frameSize, let maximum):
            "Output device \(id) uses \(frameSize)-frame buffers; GlassEQ supports playback callbacks up to \(maximum) frames"
        case .unsupportedPlaybackConversionBuffer(let id, let requiredPrimeFrames, let maximumPrimeFrames):
            "Output device \(id) requires a \(requiredPrimeFrames)-frame converted playback prime; GlassEQ supports up to \(maximumPrimeFrames) frames with drift headroom"
        case .invalidDeviceMetadata(let id, let message):
            "Output device \(id) reported invalid Core Audio metadata: \(message)"
        }
    }

    public var errorDescription: String? {
        description
    }
}

public enum CoreAudioDeviceQuery {
    static let maxStreamConfigurationBytes: UInt32 = 1_048_576
    static let maxSampleRate = 768_000.0
    static let maxBufferFrameSize: UInt32 = 1_048_576
    static let maxChannelCount = 256

    public static func defaultOutputDevice() throws -> AudioOutputDevice {
        let deviceID = try getAudioObjectIDProperty(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDefaultOutputDevice,
            scope: kAudioObjectPropertyScopeGlobal
        )
        guard deviceID != kAudioObjectUnknown else {
            throw AudioDeviceAvailabilityError.noDefaultOutput
        }

        return try outputDevice(id: deviceID)
    }

    public static func outputDevices() throws -> [AudioOutputDevice] {
        try audioDeviceIDs().compactMap { deviceID in
            try? outputDevice(id: deviceID)
        }
    }

    public static func outputDevice(id: AudioObjectID) throws -> AudioOutputDevice {
        guard id != kAudioObjectUnknown else {
            throw AudioDeviceAvailabilityError.noDefaultOutput
        }
        guard try isDeviceAlive(id: id) else {
            throw AudioDeviceAvailabilityError.outputDeviceNotAlive(id)
        }
        let uid = try getStringProperty(
            objectID: id,
            selector: kAudioDevicePropertyDeviceUID,
            scope: kAudioObjectPropertyScopeGlobal
        )
        let name = try getStringProperty(
            objectID: id,
            selector: kAudioObjectPropertyName,
            scope: kAudioObjectPropertyScopeGlobal
        )
        let sampleRate = try validatedSampleRate(
            getFloat64Property(
                objectID: id,
                selector: kAudioDevicePropertyNominalSampleRate,
                scope: kAudioObjectPropertyScopeGlobal
            ),
            objectID: id
        )
        let outputChannelCount = try getChannelCount(
            objectID: id,
            scope: kAudioDevicePropertyScopeOutput
        )
        guard outputChannelCount > 0 else {
            throw AudioDeviceAvailabilityError.outputDeviceHasNoOutputChannels(id)
        }
        let bufferFrameSize = try validatedBufferFrameSize(
            getUInt32Property(
                objectID: id,
                selector: kAudioDevicePropertyBufferFrameSize,
                scope: kAudioObjectPropertyScopeGlobal
            ),
            objectID: id
        )
        let transportType = try? getUInt32Property(
            objectID: id,
            selector: kAudioDevicePropertyTransportType,
            scope: kAudioObjectPropertyScopeGlobal
        )

        return AudioOutputDevice(
            id: id,
            uid: uid,
            name: name,
            nominalSampleRate: sampleRate,
            outputChannelCount: outputChannelCount,
            bufferFrameSize: bufferFrameSize,
            transportType: transportType
        )
    }

    static func outputDevice(uid targetUID: String) throws -> AudioOutputDevice? {
        guard !targetUID.isEmpty else {
            return nil
        }

        for deviceID in try audioDeviceIDs() {
            guard (try? getStringProperty(
                objectID: deviceID,
                selector: kAudioDevicePropertyDeviceUID,
                scope: kAudioObjectPropertyScopeGlobal
            )) == targetUID else {
                continue
            }
            guard (try? isDeviceAlive(id: deviceID)) == true else {
                return nil
            }
            do {
                return try outputDevice(id: deviceID)
            } catch AudioDeviceAvailabilityError.outputDeviceHasNoOutputChannels {
                return nil
            }
        }

        return nil
    }

    public static func bufferFrameSizeRangeValue(objectID: AudioObjectID) throws -> AudioBufferFrameSizeRange {
        let range = try bufferFrameSizeRange(objectID: objectID)
        return try validatedBufferFrameSizeRange(range, objectID: objectID)
    }

    public static func isDeviceAlive(id: AudioObjectID) throws -> Bool {
        try getUInt32Property(
            objectID: id,
            selector: kAudioDevicePropertyDeviceIsAlive,
            scope: kAudioObjectPropertyScopeGlobal
        ) != 0
    }

    public static func bufferFrameSizeRange(objectID: AudioObjectID) throws -> AudioValueRange {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSizeRange,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = AudioValueRange()
        var size = UInt32(MemoryLayout<AudioValueRange>.size)
        try checkOSStatus(
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value),
            operation: "AudioObjectGetPropertyData(buffer frame size range)"
        )
        try validatePropertySize(
            actual: size,
            expected: UInt32(MemoryLayout<AudioValueRange>.size),
            operation: "AudioObjectGetPropertyData(buffer frame size range)",
            objectID: objectID
        )
        return value
    }

    public static func setBufferFrameSize(_ frameSize: UInt32, objectID: AudioObjectID) throws {
        _ = try validatedBufferFrameSize(frameSize, objectID: objectID)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = frameSize
        let size = UInt32(MemoryLayout<UInt32>.size)
        // Mark this as our own change so the default-output observer ignores the resulting
        // property-change notification instead of rebuilding.
        CoreAudioSelfChangeGuard.shared.beginSelfChange(deviceID: objectID)
        try checkOSStatus(
            AudioObjectSetPropertyData(objectID, &address, 0, nil, size, &value),
            operation: "AudioObjectSetPropertyData(buffer frame size)"
        )
    }

    public static func setNominalSampleRate(_ sampleRate: Double, objectID: AudioObjectID) throws {
        _ = try validatedSampleRate(sampleRate, objectID: objectID)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = sampleRate
        let size = UInt32(MemoryLayout<Float64>.size)
        // Mark this as our own change so the default-output observer ignores the resulting
        // property-change notification instead of rebuilding.
        CoreAudioSelfChangeGuard.shared.beginSelfChange(deviceID: objectID)
        try checkOSStatus(
            AudioObjectSetPropertyData(objectID, &address, 0, nil, size, &value),
            operation: "AudioObjectSetPropertyData(nominal sample rate)"
        )
    }

    static func getAudioObjectIDProperty(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )
        var value = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try checkOSStatus(
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value),
            operation: "AudioObjectGetPropertyData(\(selector))"
        )
        try validatePropertySize(
            actual: size,
            expected: UInt32(MemoryLayout<AudioObjectID>.size),
            operation: "AudioObjectGetPropertyData(\(selector))",
            objectID: objectID
        )
        return value
    }

    static func audioDeviceIDs() throws -> [AudioObjectID] {
        try audioObjectIDs(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDevices,
            scope: kAudioObjectPropertyScopeGlobal,
            description: "devices"
        )
    }

    static func hasActiveOutputProcess(
        using deviceID: AudioObjectID,
        excluding excludedProcessObjectIDs: Set<AudioObjectID>,
        processObjectIDs: () throws -> [AudioObjectID] = audioProcessObjectIDs,
        isRunningOutput: (AudioObjectID) throws -> Bool = isProcessRunningOutput,
        outputDeviceIDs: (AudioObjectID) throws -> [AudioObjectID] = processOutputDeviceIDs
    ) throws -> Bool {
        for processObjectID in try processObjectIDs()
        where !excludedProcessObjectIDs.contains(processObjectID) {
            do {
                guard try isRunningOutput(processObjectID) else {
                    continue
                }
                if try outputDeviceIDs(processObjectID).contains(deviceID) {
                    return true
                }
            } catch {
                continue
            }
        }
        return false
    }

    private static func audioProcessObjectIDs() throws -> [AudioObjectID] {
        try audioObjectIDs(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyProcessObjectList,
            scope: kAudioObjectPropertyScopeGlobal,
            description: "audio processes"
        )
    }

    private static func isProcessRunningOutput(_ processObjectID: AudioObjectID) throws -> Bool {
        try getUInt32Property(
            objectID: processObjectID,
            selector: kAudioProcessPropertyIsRunningOutput,
            scope: kAudioObjectPropertyScopeGlobal
        ) != 0
    }

    private static func processOutputDeviceIDs(
        _ processObjectID: AudioObjectID
    ) throws -> [AudioObjectID] {
        try audioObjectIDs(
            objectID: processObjectID,
            selector: kAudioProcessPropertyDevices,
            scope: kAudioObjectPropertyScopeOutput,
            description: "process output devices"
        )
    }

    private static func audioObjectIDs(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        description: String
    ) throws -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(0)
        try checkOSStatus(
            AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size),
            operation: "AudioObjectGetPropertyDataSize(\(description))"
        )
        guard size % UInt32(MemoryLayout<AudioObjectID>.size) == 0 else {
            throw AudioDeviceAvailabilityError.invalidDeviceMetadata(
                objectID,
                "\(description) returned \(size) bytes; expected a multiple of \(MemoryLayout<AudioObjectID>.size)"
            )
        }
        guard size <= maxStreamConfigurationBytes else {
            throw AudioDeviceAvailabilityError.invalidDeviceMetadata(
                objectID,
                "\(description) is too large (\(size) bytes)"
            )
        }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else {
            return []
        }

        var deviceIDs = Array(repeating: AudioObjectID(kAudioObjectUnknown), count: count)
        try deviceIDs.withUnsafeMutableBufferPointer { buffer in
            try checkOSStatus(
                AudioObjectGetPropertyData(
                    objectID,
                    &address,
                    0,
                    nil,
                    &size,
                    buffer.baseAddress!
                ),
                operation: "AudioObjectGetPropertyData(\(description))"
            )
        }
        return deviceIDs.filter { $0 != kAudioObjectUnknown }
    }

    static func getFloat64Property(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) throws -> Float64 {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )
        var value = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        try checkOSStatus(
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value),
            operation: "AudioObjectGetPropertyData(\(selector))"
        )
        try validatePropertySize(
            actual: size,
            expected: UInt32(MemoryLayout<Float64>.size),
            operation: "AudioObjectGetPropertyData(\(selector))",
            objectID: objectID
        )
        return value
    }

    static func getUInt32Property(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) throws -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        try checkOSStatus(
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value),
            operation: "AudioObjectGetPropertyData(\(selector))"
        )
        try validatePropertySize(
            actual: size,
            expected: UInt32(MemoryLayout<UInt32>.size),
            operation: "AudioObjectGetPropertyData(\(selector))",
            objectID: objectID
        )
        return value
    }

    static func getStringProperty(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )
        let pointer = UnsafeMutablePointer<CFString?>.allocate(capacity: 1)
        pointer.initialize(to: nil)
        defer {
            pointer.deinitialize(count: 1)
            pointer.deallocate()
        }
        var size = UInt32(MemoryLayout<CFString?>.size)
        try checkOSStatus(
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, UnsafeMutableRawPointer(pointer)),
            operation: "AudioObjectGetPropertyData(\(selector))"
        )
        try validatePropertySize(
            actual: size,
            expected: UInt32(MemoryLayout<CFString?>.size),
            operation: "AudioObjectGetPropertyData(\(selector))",
            objectID: objectID
        )
        let value = pointer.pointee
        guard let value else {
            throw CoreAudioError(operation: "AudioObjectGetPropertyData(\(selector)) nil", status: kAudioHardwareBadObjectError)
        }
        return value as String
    }

    static func setProcessTapMuteBehavior(
        _ muteBehavior: CATapMuteBehavior,
        tapID: AudioObjectID
    ) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyDescription,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var description: Unmanaged<CATapDescription>?
        var size = UInt32(MemoryLayout<Unmanaged<CATapDescription>?>.size)
        try checkOSStatus(
            AudioObjectGetPropertyData(
                tapID,
                &address,
                0,
                nil,
                &size,
                &description
            ),
            operation: "AudioObjectGetPropertyData(tap description)"
        )
        try validatePropertySize(
            actual: size,
            expected: UInt32(MemoryLayout<Unmanaged<CATapDescription>?>.size),
            operation: "AudioObjectGetPropertyData(tap description)",
            objectID: tapID
        )
        guard let description else {
            throw CoreAudioError(
                operation: "AudioObjectGetPropertyData(tap description) nil",
                status: kAudioHardwareBadObjectError
            )
        }

        let tapDescription = description.takeUnretainedValue()
        tapDescription.muteBehavior = muteBehavior
        var updatedDescription = Unmanaged.passUnretained(tapDescription)
        try checkOSStatus(
            AudioObjectSetPropertyData(
                tapID,
                &address,
                0,
                nil,
                UInt32(MemoryLayout<Unmanaged<CATapDescription>>.size),
                &updatedDescription
            ),
            operation: "AudioObjectSetPropertyData(tap description)"
        )
    }

    /// The device's preferred stereo pair as raw 1-based channel numbers; callers sanitize
    /// (the HAL reports zeros when the pair was never configured).
    static func preferredStereoChannels(objectID: AudioObjectID) throws -> (left: UInt32, right: UInt32) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyPreferredChannelsForStereo,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var channels: (UInt32, UInt32) = (0, 0)
        var size = UInt32(MemoryLayout<(UInt32, UInt32)>.size)
        try checkOSStatus(
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &channels),
            operation: "AudioObjectGetPropertyData(preferred stereo channels)"
        )
        try validatePropertySize(
            actual: size,
            expected: UInt32(MemoryLayout<(UInt32, UInt32)>.size),
            operation: "AudioObjectGetPropertyData(preferred stereo channels)",
            objectID: objectID
        )
        return (left: channels.0, right: channels.1)
    }

    static func getChannelCount(
        objectID: AudioObjectID,
        scope: AudioObjectPropertyScope
    ) throws -> Int {
        try streamChannelCounts(objectID: objectID, scope: scope).reduce(0, +)
    }

    static func streamChannelCounts(
        objectID: AudioObjectID,
        scope: AudioObjectPropertyScope
    ) throws -> [Int] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(0)
        try checkOSStatus(
            AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size),
            operation: "AudioObjectGetPropertyDataSize(stream configuration)"
        )
        try validateStreamConfigurationSize(size, objectID: objectID)

        let rawPointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer {
            rawPointer.deallocate()
        }

        try checkOSStatus(
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, rawPointer),
            operation: "AudioObjectGetPropertyData(stream configuration)"
        )
        try validateStreamConfigurationSize(size, objectID: objectID)

        let bufferCount = Int(rawPointer.load(as: UInt32.self))
        try validateAudioBufferListStorage(
            bufferCount: bufferCount,
            byteCount: Int(size),
            objectID: objectID
        )
        guard bufferCount > 0 else {
            return []
        }
        let bufferList = rawPointer.bindMemory(to: AudioBufferList.self, capacity: 1)
        return UnsafeMutableAudioBufferListPointer(bufferList).map { buffer in
            Int(buffer.mNumberChannels)
        }
    }

    static func validatePropertySize(
        actual: UInt32,
        expected: UInt32,
        operation: String,
        objectID: AudioObjectID
    ) throws {
        guard actual == expected else {
            throw AudioDeviceAvailabilityError.invalidDeviceMetadata(
                objectID,
                "\(operation) returned \(actual) bytes; expected \(expected)"
            )
        }
    }

    static func validateStreamConfigurationSize(_ size: UInt32, objectID: AudioObjectID) throws {
        guard let buffersOffset = MemoryLayout<AudioBufferList>.offset(of: \.mBuffers) else {
            throw AudioDeviceAvailabilityError.invalidDeviceMetadata(
                objectID,
                "cannot determine AudioBufferList layout"
            )
        }
        guard size >= UInt32(buffersOffset) else {
            throw AudioDeviceAvailabilityError.invalidDeviceMetadata(
                objectID,
                "stream configuration is too small (\(size) bytes)"
            )
        }
        guard size <= maxStreamConfigurationBytes else {
            throw AudioDeviceAvailabilityError.invalidDeviceMetadata(
                objectID,
                "stream configuration is too large (\(size) bytes)"
            )
        }
    }

    static func validatedSampleRate(_ sampleRate: Double, objectID: AudioObjectID) throws -> Double {
        guard sampleRate.isFinite, sampleRate > 0, sampleRate <= maxSampleRate else {
            throw AudioDeviceAvailabilityError.invalidDeviceMetadata(
                objectID,
                "nominal sample rate \(sampleRate) is outside the supported range"
            )
        }
        return sampleRate
    }

    static func validatedBufferFrameSize(_ frameSize: UInt32, objectID: AudioObjectID) throws -> UInt32 {
        guard frameSize > 0, frameSize <= maxBufferFrameSize else {
            throw AudioDeviceAvailabilityError.invalidDeviceMetadata(
                objectID,
                "buffer frame size \(frameSize) is outside the supported range"
            )
        }
        return frameSize
    }

    static func validatedBufferFrameSizeRange(
        _ range: AudioValueRange,
        objectID: AudioObjectID
    ) throws -> AudioBufferFrameSizeRange {
        guard range.mMinimum.isFinite,
              range.mMaximum.isFinite,
              range.mMinimum > 0,
              range.mMaximum > 0,
              range.mMinimum <= range.mMaximum else {
            throw AudioDeviceAvailabilityError.invalidDeviceMetadata(
                objectID,
                "buffer frame size range \(range.mMinimum)...\(range.mMaximum) is invalid"
            )
        }

        let roundedMinimum = range.mMinimum.rounded(.up)
        let roundedMaximum = range.mMaximum.rounded(.down)
        guard roundedMinimum >= 1,
              roundedMaximum >= roundedMinimum,
              roundedMaximum <= Double(maxBufferFrameSize),
              roundedMinimum <= Double(UInt32.max),
              roundedMaximum <= Double(UInt32.max) else {
            throw AudioDeviceAvailabilityError.invalidDeviceMetadata(
                objectID,
                "buffer frame size range \(range.mMinimum)...\(range.mMaximum) is outside supported bounds"
            )
        }

        return AudioBufferFrameSizeRange(
            minimum: UInt32(roundedMinimum),
            maximum: UInt32(roundedMaximum)
        )
    }

    static func checkedSampleCount(frames: Int, channels: Int, objectID: AudioObjectID) throws -> Int {
        guard frames >= 0, channels > 0, channels <= maxChannelCount else {
            throw AudioDeviceAvailabilityError.invalidDeviceMetadata(
                objectID,
                "invalid frame/channel count \(frames)x\(channels)"
            )
        }
        guard let count = frames.multipliedReportingOverflow(by: channels).partialValue as Int?,
              !frames.multipliedReportingOverflow(by: channels).overflow,
              count <= Int(maxBufferFrameSize) * maxChannelCount else {
            throw AudioDeviceAvailabilityError.invalidDeviceMetadata(
                objectID,
                "frame/channel count \(frames)x\(channels) is too large"
            )
        }
        return count
    }

    static func validateAudioBufferListStorage(
        bufferCount: Int,
        byteCount: Int,
        objectID: AudioObjectID
    ) throws {
        guard let buffersOffset = MemoryLayout<AudioBufferList>.offset(of: \.mBuffers) else {
            throw AudioDeviceAvailabilityError.invalidDeviceMetadata(objectID, "cannot determine AudioBufferList layout")
        }
        guard bufferCount >= 0, bufferCount <= maxChannelCount else {
            throw AudioDeviceAvailabilityError.invalidDeviceMetadata(
                objectID,
                "stream configuration has invalid buffer count \(bufferCount)"
            )
        }
        let requiredBytes = buffersOffset + bufferCount * MemoryLayout<AudioBuffer>.stride
        guard requiredBytes <= byteCount else {
            throw AudioDeviceAvailabilityError.invalidDeviceMetadata(
                objectID,
                "stream configuration buffer list exceeds returned size"
            )
        }
    }
}
