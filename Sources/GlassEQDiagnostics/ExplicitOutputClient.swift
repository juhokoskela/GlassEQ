import CoreAudio
import Darwin
import Foundation
import GlassEQAudio

private final class ExplicitOutputClientState: @unchecked Sendable {
    struct Snapshot: CustomStringConvertible {
        var callbacks: UInt64
        var renderedFrames: UInt64
        var timestampDiscontinuities: UInt64
        var lastTimestampGapFrames: Double
        var minimumCallbackFrames: Int
        var maximumCallbackFrames: Int
        var unsupportedBufferCallbacks: UInt64

        var description: String {
            "callbacks=\(callbacks) renderedFrames=\(renderedFrames) timestampDiscontinuities=\(timestampDiscontinuities) lastTimestampGapFrames=\(lastTimestampGapFrames) callbackFrames=\(minimumCallbackFrames)...\(maximumCallbackFrames) unsupportedBufferCallbacks=\(unsupportedBufferCallbacks)"
        }
    }

    private let sampleRate: Double
    private let phaseIncrement: Double
    private var phase = 0.0
    private var callbacks: UInt64 = 0
    private var renderedFrames: UInt64 = 0
    private var timestampDiscontinuities: UInt64 = 0
    private var lastTimestampGapFrames = 0.0
    private var minimumCallbackFrames = Int.max
    private var maximumCallbackFrames = 0
    private var unsupportedBufferCallbacks: UInt64 = 0
    private var previousSampleTime: Double?
    private var previousFrameCount = 0

    init(sampleRate: Double, frequency: Double = 440) {
        self.sampleRate = sampleRate
        phaseIncrement = 2 * Double.pi * frequency / sampleRate
    }

    func render(
        outputData: UnsafeMutablePointer<AudioBufferList>,
        outputTime: AudioTimeStamp
    ) {
        let buffers = UnsafeMutableAudioBufferListPointer(outputData)
        var callbackFrames = 0
        var supportsFloat32 = true

        for buffer in buffers {
            let channelCount = max(Int(buffer.mNumberChannels), 1)
            let bytesPerFrame = channelCount * MemoryLayout<Float>.size
            guard bytesPerFrame > 0,
                  Int(buffer.mDataByteSize) % bytesPerFrame == 0 else {
                supportsFloat32 = false
                if let data = buffer.mData {
                    memset(data, 0, Int(buffer.mDataByteSize))
                }
                continue
            }
            callbackFrames = max(
                callbackFrames,
                Int(buffer.mDataByteSize) / bytesPerFrame
            )
        }

        let startingPhase = phase
        if supportsFloat32, callbackFrames > 0 {
            for buffer in buffers {
                guard let data = buffer.mData else {
                    continue
                }
                let channelCount = max(Int(buffer.mNumberChannels), 1)
                let frames = Int(buffer.mDataByteSize)
                    / (channelCount * MemoryLayout<Float>.size)
                let samples = data.assumingMemoryBound(to: Float.self)
                for frame in 0..<frames {
                    let value = Float(sin(startingPhase + Double(frame) * phaseIncrement) * 0.002)
                    for channel in 0..<channelCount {
                        samples[frame * channelCount + channel] = value
                    }
                }
            }
            phase = (startingPhase + Double(callbackFrames) * phaseIncrement)
                .truncatingRemainder(dividingBy: 2 * Double.pi)
        } else {
            unsupportedBufferCallbacks &+= 1
        }

        callbacks &+= 1
        renderedFrames &+= UInt64(max(callbackFrames, 0))
        minimumCallbackFrames = min(minimumCallbackFrames, callbackFrames)
        maximumCallbackFrames = max(maximumCallbackFrames, callbackFrames)

        if outputTime.mFlags.contains(.sampleTimeValid) {
            if let previousSampleTime {
                let gap = outputTime.mSampleTime
                    - previousSampleTime
                    - Double(previousFrameCount)
                if abs(gap) > 0.5 {
                    timestampDiscontinuities &+= 1
                    lastTimestampGapFrames = gap
                }
            }
            previousSampleTime = outputTime.mSampleTime
            previousFrameCount = callbackFrames
        } else {
            previousSampleTime = nil
            previousFrameCount = 0
        }
    }

    func snapshot() -> Snapshot {
        Snapshot(
            callbacks: callbacks,
            renderedFrames: renderedFrames,
            timestampDiscontinuities: timestampDiscontinuities,
            lastTimestampGapFrames: lastTimestampGapFrames,
            minimumCallbackFrames: minimumCallbackFrames == Int.max ? 0 : minimumCallbackFrames,
            maximumCallbackFrames: maximumCallbackFrames,
            unsupportedBufferCallbacks: unsupportedBufferCallbacks
        )
    }
}

func runExplicitOutputClient(output: AudioOutputDevice) throws -> Int32 {
    let state = ExplicitOutputClientState(sampleRate: output.nominalSampleRate)
    var ioProcID: AudioDeviceIOProcID?
    let createStatus = AudioDeviceCreateIOProcIDWithBlock(
        &ioProcID,
        output.id,
        nil
    ) { _, _, _, outputData, outputTime in
        state.render(
            outputData: outputData,
            outputTime: outputTime.pointee
        )
    }
    try requireExplicitClientNoErr(
        createStatus,
        operation: "AudioDeviceCreateIOProcIDWithBlock(explicit output client)"
    )
    guard let ioProcID else {
        throw ExplicitOutputClientError(
            operation: "Core Audio returned no explicit output IOProc",
            status: kAudioHardwareUnspecifiedError
        )
    }
    try disableExplicitClientInput(
        deviceID: output.id,
        ioProcID: ioProcID
    )
    defer {
        _ = AudioDeviceStop(output.id, ioProcID)
        _ = AudioDeviceDestroyIOProcID(output.id, ioProcID)
    }

    try requireExplicitClientNoErr(
        AudioDeviceStart(output.id, ioProcID),
        operation: "AudioDeviceStart(explicit output client)"
    )
    print("Explicit output client running on \(output.id) \(output.name).")
    print("It renders a 440 Hz tone at -54 dBFS, disables every input stream, and does not follow the default output.")
    print("Press Return to stop it.")
    fflush(stdout)
    _ = readLine()

    try requireExplicitClientNoErr(
        AudioDeviceStop(output.id, ioProcID),
        operation: "AudioDeviceStop(explicit output client)"
    )
    print("Explicit output client metrics: \(state.snapshot())")
    return 0
}

private func disableExplicitClientInput(
    deviceID: AudioObjectID,
    ioProcID: AudioDeviceIOProcID
) throws {
    let inputStreamCount = try explicitClientInputStreamCount(deviceID: deviceID)
    guard inputStreamCount > 0 else {
        return
    }

    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyIOProcStreamUsage,
        mScope: kAudioDevicePropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain
    )
    let expectedUsage = Array(repeating: UInt32(0), count: inputStreamCount)
    let storage = explicitClientStreamUsageStorage(
        expectedUsage,
        ioProcID: ioProcID
    )
    defer { storage.deallocate() }
    var size = UInt32(explicitClientStreamUsageByteCount(streamCount: inputStreamCount))
    try requireExplicitClientNoErr(
        AudioObjectSetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            size,
            storage
        ),
        operation: "AudioObjectSetPropertyData(explicit client input stream usage)"
    )

    storage.initializeMemory(as: UInt8.self, repeating: 0, count: Int(size))
    let readbackHeader = storage.assumingMemoryBound(
        to: AudioHardwareIOProcStreamUsage.self
    )
    readbackHeader.pointee.mIOProc = unsafeBitCast(
        ioProcID,
        to: UnsafeMutableRawPointer.self
    )
    readbackHeader.pointee.mNumberStreams = UInt32(inputStreamCount)
    try requireExplicitClientNoErr(
        AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            storage
        ),
        operation: "AudioObjectGetPropertyData(explicit client input stream usage)"
    )
    let header = storage.assumingMemoryBound(to: AudioHardwareIOProcStreamUsage.self)
    guard Int(header.pointee.mNumberStreams) == inputStreamCount else {
        throw ExplicitOutputClientError(
            operation: "Core Audio returned the wrong explicit client input stream count",
            status: kAudioHardwareUnspecifiedError
        )
    }
    let values = storage
        .advanced(by: explicitClientStreamUsageValuesOffset)
        .assumingMemoryBound(to: UInt32.self)
    let appliedUsage = (0..<inputStreamCount).map { values[$0] }
    guard appliedUsage == expectedUsage else {
        throw ExplicitOutputClientError(
            operation: "Core Audio did not disable the explicit client's input streams",
            status: kAudioHardwareUnspecifiedError
        )
    }
}

private func explicitClientInputStreamCount(deviceID: AudioObjectID) throws -> Int {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyStreams,
        mScope: kAudioDevicePropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain
    )
    var size = UInt32(0)
    try requireExplicitClientNoErr(
        AudioObjectGetPropertyDataSize(
            deviceID,
            &address,
            0,
            nil,
            &size
        ),
        operation: "AudioObjectGetPropertyDataSize(explicit client input streams)"
    )
    let stride = UInt32(MemoryLayout<AudioStreamID>.stride)
    guard size.isMultiple(of: stride) else {
        throw ExplicitOutputClientError(
            operation: "Core Audio returned invalid explicit client input stream metadata",
            status: kAudioHardwareUnspecifiedError
        )
    }
    return Int(size / stride)
}

private let explicitClientStreamUsageValuesOffset =
    MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn)!

private func explicitClientStreamUsageByteCount(streamCount: Int) -> Int {
    explicitClientStreamUsageValuesOffset + streamCount * MemoryLayout<UInt32>.stride
}

private func explicitClientStreamUsageStorage(
    _ usage: [UInt32],
    ioProcID: AudioDeviceIOProcID
) -> UnsafeMutableRawPointer {
    let byteCount = explicitClientStreamUsageByteCount(streamCount: usage.count)
    let storage = UnsafeMutableRawPointer.allocate(
        byteCount: byteCount,
        alignment: MemoryLayout<AudioHardwareIOProcStreamUsage>.alignment
    )
    storage.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
    let header = storage.assumingMemoryBound(to: AudioHardwareIOProcStreamUsage.self)
    header.pointee.mIOProc = unsafeBitCast(ioProcID, to: UnsafeMutableRawPointer.self)
    header.pointee.mNumberStreams = UInt32(usage.count)
    let values = storage
        .advanced(by: explicitClientStreamUsageValuesOffset)
        .assumingMemoryBound(to: UInt32.self)
    for (index, enabled) in usage.enumerated() {
        values[index] = enabled
    }
    return storage
}

func setDiagnosticDefaultOutputDevice(_ output: AudioOutputDevice) throws {
    let systemObject = AudioObjectID(kAudioObjectSystemObject)
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var settable = DarwinBoolean(false)
    try requireExplicitClientNoErr(
        AudioObjectIsPropertySettable(systemObject, &address, &settable),
        operation: "AudioObjectIsPropertySettable(default output)"
    )
    guard settable.boolValue else {
        throw ExplicitOutputClientError(
            operation: "The default output property is not settable",
            status: kAudioHardwareUnsupportedOperationError
        )
    }

    var deviceID = output.id
    let size = UInt32(MemoryLayout<AudioObjectID>.size)
    try requireExplicitClientNoErr(
        AudioObjectSetPropertyData(
            systemObject,
            &address,
            0,
            nil,
            size,
            &deviceID
        ),
        operation: "AudioObjectSetPropertyData(default output)"
    )

    let deadline = Date().addingTimeInterval(3)
    repeat {
        if try CoreAudioDeviceQuery.defaultOutputDevice().id == output.id {
            return
        }
        Thread.sleep(forTimeInterval: 0.01)
    } while Date() < deadline

    throw ExplicitOutputClientError(
        operation: "The default output change did not settle",
        status: kAudioHardwareNotRunningError
    )
}

private struct ExplicitOutputClientError: Error, CustomStringConvertible {
    var operation: String
    var status: OSStatus

    var description: String {
        "\(operation) failed with OSStatus \(status)"
    }
}

private func requireExplicitClientNoErr(
    _ status: OSStatus,
    operation: String
) throws {
    guard status == noErr else {
        throw ExplicitOutputClientError(operation: operation, status: status)
    }
}
