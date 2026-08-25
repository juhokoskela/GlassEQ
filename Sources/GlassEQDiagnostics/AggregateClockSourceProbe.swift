import CoreAudio
import Darwin
import Foundation
import GlassEQAudio

private enum AggregateClockProbeError: Error, CustomStringConvertible {
    case coreAudio(operation: String, status: OSStatus)
    case timedOut(String)
    case unavailable(String)

    var description: String {
        switch self {
        case .coreAudio(let operation, let status):
            return "\(operation) failed with OSStatus \(status)"
        case .timedOut(let operation):
            return "Timed out waiting for \(operation)"
        case .unavailable(let message):
            return message
        }
    }
}

private enum AggregateClockProbeSource: CaseIterable {
    case physicalDevice
    case deviceClock
    case tap

    var label: String {
        switch self {
        case .physicalDevice:
            return "physical device"
        case .deviceClock:
            return "physical device clock object"
        case .tap:
            return "device-scoped tap"
        }
    }
}

private struct RunningTapSelection {
    var activeSubtapIDs: [AudioObjectID]
    var activeSubtapApplied: Bool
    var activeSubtapError: String?
    var originalTapApplied: Bool
}

func runAggregateClockSourceProbe(output: AudioOutputDevice) -> Int32 {
    print("Mode: aggregate clock-source probe")
    print("The probe creates private aggregates and briefly starts silent IO for live clock-source checks.")

    var tapID = AudioObjectID(kAudioObjectUnknown)
    do {
        let tapDescription = CATapDescription(
            excludingProcesses: [],
            deviceUID: output.uid,
            stream: 0
        )
        tapDescription.name = "GlassEQ Clock Source Probe"
        tapDescription.uuid = UUID()
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .unmuted
        tapDescription.isMixdown = false

        try check(
            AudioHardwareCreateProcessTap(tapDescription, &tapID),
            operation: "AudioHardwareCreateProcessTap(clock-source probe)"
        )
        defer {
            if tapID != kAudioObjectUnknown {
                _ = AudioHardwareDestroyProcessTap(tapID)
            }
        }

        let tap = AudioHardwareTap(id: tapID)
        let physicalDevice = AudioHardwareDevice(id: output.id)
        let deviceClock = try? physicalDevice.clock

        print("Physical device object ID: \(physicalDevice.id)")
        if let deviceClock {
            print("Physical device clock object ID: \(deviceClock.id)")
        } else {
            print("Physical device clock object ID: unavailable")
        }
        print("Tap object ID: \(tap.id)")

        for source in AggregateClockProbeSource.allCases {
            do {
                try runProbe(
                    source: source,
                    output: output,
                    physicalDevice: physicalDevice,
                    deviceClock: deviceClock,
                    tap: tap
                )
            } catch {
                print("")
                print("Clock source: \(source.label)")
                print("  Result: rejected")
                print("  Error: \(error)")
            }
        }
        for probe in [
            { try runTapOnlyProbe(tap: tap) },
            {
                try runTapFirstOutputProbe(
                    physicalDevice: physicalDevice,
                    tap: tap
                )
            },
            {
                try runTapMainUIDProbe(
                    output: output,
                    physicalDevice: physicalDevice,
                    tap: tap
                )
            }
        ] {
            do {
                try probe()
            } catch {
                print("")
                print("Additional clock-source probe rejected: \(error)")
            }
        }
        return 0
    } catch {
        print("Aggregate clock-source probe failed: \(error)")
        return 1
    }
}

private func runTapMainUIDProbe(
    output: AudioOutputDevice,
    physicalDevice: AudioHardwareDevice,
    tap: AudioHardwareTap
) throws {
    let tapUID = try stringProperty(
        objectID: tap.id,
        selector: kAudioTapPropertyUID
    )
    let description: [String: Any] = [
        kAudioAggregateDeviceNameKey: "GlassEQ Clock Probe tap master UID",
        kAudioAggregateDeviceUIDKey: "com.glasseq.clock-probe.\(UUID().uuidString)",
        kAudioAggregateDeviceIsPrivateKey: true,
        kAudioAggregateDeviceMainSubDeviceKey: tapUID,
        kAudioAggregateDeviceSubDeviceListKey: [
            [
                kAudioSubDeviceUIDKey: output.uid,
                kAudioSubDeviceInputChannelsKey: 0,
                kAudioSubDeviceOutputChannelsKey: output.outputChannelCount,
                kAudioSubDeviceDriftCompensationKey: true,
                kAudioSubDeviceDriftCompensationQualityKey:
                    kAudioAggregateDriftCompensationHighQuality
            ]
        ],
        kAudioAggregateDeviceTapListKey: [
            [
                kAudioSubTapUIDKey: tapUID,
                kAudioSubTapDriftCompensationKey: false
            ]
        ]
    ]

    var aggregateID = AudioObjectID(kAudioObjectUnknown)
    try check(
        AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID),
        operation: "AudioHardwareCreateAggregateDevice(tap master UID)"
    )
    defer { _ = AudioHardwareDestroyAggregateDevice(aggregateID) }
    let aggregate = AudioHardwareAggregateDevice(id: aggregateID)
    try waitUntilAlive(aggregate)
    let composition = try aggregate.composition

    print("")
    print("Clock source: tap UID in master composition")
    print("  Aggregate object ID: \(aggregate.id)")
    print("  Published source: \(describe(try aggregate.clockSource))")
    print("  Main subdevice UID: \(composition[kAudioAggregateDeviceMainSubDeviceKey] ?? "unavailable")")
    print("  Input safety offset: \(try aggregate.inputSafetyOffset) frames")
    print("  Output safety offset: \(try aggregate.outputSafetyOffset) frames")

    let physicalInputStreamCount = try physicalDevice.inputStreamConfiguration.count
    var runningSource = "unavailable"
    var runningSelectionApplied = false
    var runningActiveSubtaps: [AudioObjectID] = []
    var runningActiveSubtapError: String?
    try withRunningSilentIO(
        on: aggregate,
        disabledInputStreamCount: physicalInputStreamCount
    ) {
        let selection = try selectRunningTapClockSource(
            aggregate: aggregate,
            tap: tap
        )
        runningActiveSubtaps = selection.activeSubtapIDs
        runningActiveSubtapError = selection.activeSubtapError
        runningSelectionApplied = selection.activeSubtapApplied
            || selection.originalTapApplied
        runningSource = describe(try aggregate.clockSource)
    }
    print("  Selection applied while running: \(runningSelectionApplied)")
    print("  Running source: \(runningSource)")
    print("  Active subtaps while running: \(runningActiveSubtaps)")
    if let runningActiveSubtapError {
        print("  Active sub-tap selection error: \(runningActiveSubtapError)")
    }
}

private func runProbe(
    source: AggregateClockProbeSource,
    output: AudioOutputDevice,
    physicalDevice: AudioHardwareDevice,
    deviceClock: AudioHardwareClock?,
    tap: AudioHardwareTap
) throws {
    let tapUID = try stringProperty(
        objectID: tap.id,
        selector: kAudioTapPropertyUID
    )
    let description: [String: Any] = [
        kAudioAggregateDeviceNameKey: "GlassEQ Clock Probe \(source.label)",
        kAudioAggregateDeviceUIDKey: "com.glasseq.clock-probe.\(UUID().uuidString)",
        kAudioAggregateDeviceIsPrivateKey: true,
        kAudioAggregateDeviceMainSubDeviceKey: output.uid,
        kAudioAggregateDeviceSubDeviceListKey: [
            [
                kAudioSubDeviceUIDKey: output.uid,
                kAudioSubDeviceInputChannelsKey: 0,
                kAudioSubDeviceOutputChannelsKey: output.outputChannelCount,
                kAudioSubDeviceDriftCompensationKey: false
            ]
        ],
        kAudioAggregateDeviceTapListKey: [
            [
                kAudioSubTapUIDKey: tapUID,
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapDriftCompensationQualityKey:
                    kAudioAggregateDriftCompensationHighQuality
            ]
        ]
    ]

    var aggregateID = AudioObjectID(kAudioObjectUnknown)
    try check(
        AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID),
        operation: "AudioHardwareCreateAggregateDevice(\(source.label))"
    )
    defer {
        if aggregateID != kAudioObjectUnknown {
            _ = AudioHardwareDestroyAggregateDevice(aggregateID)
        }
    }

    let aggregate = AudioHardwareAggregateDevice(id: aggregateID)
    try waitUntilAlive(aggregate)

    let requestedSource: AudioHardwareObject
    switch source {
    case .physicalDevice:
        requestedSource = physicalDevice
    case .deviceClock:
        guard let deviceClock else {
            throw AggregateClockProbeError.unavailable(
                "The physical device does not publish a separate AudioHardwareClock"
            )
        }
        requestedSource = deviceClock
    case .tap:
        requestedSource = tap
    }
    try aggregate.setClockSource(requestedSource)
    let sourceApplied = try waitForClockSource(requestedSource.id, aggregate: aggregate)
    var runningSelectionApplied: Bool?
    var runningSource: String?
    var runningActiveSubtaps: [AudioObjectID]?
    var runningActiveSubtapError: String?
    if source == .tap {
        let physicalInputStreamCount = try physicalDevice.inputStreamConfiguration.count
        try withRunningSilentIO(
            on: aggregate,
            disabledInputStreamCount: physicalInputStreamCount
        ) {
            let selection = try selectRunningTapClockSource(
                aggregate: aggregate,
                tap: tap
            )
            runningActiveSubtaps = selection.activeSubtapIDs
            runningActiveSubtapError = selection.activeSubtapError
            runningSelectionApplied = selection.activeSubtapApplied
                || selection.originalTapApplied
            runningSource = describe(try aggregate.clockSource)
        }
    }

    let publishedSource = try aggregate.clockSource
    let composition = try aggregate.composition

    print("")
    print("Clock source: \(source.label)")
    print("  Aggregate object ID: \(aggregate.id)")
    print("  Requested object ID: \(requestedSource.id)")
    print("  Selection applied: \(sourceApplied)")
    if let runningSelectionApplied, let runningSource, let runningActiveSubtaps {
        print("  Selection applied while running: \(runningSelectionApplied)")
        print("  Running source: \(runningSource)")
        print("  Active subtaps while running: \(runningActiveSubtaps)")
        if let runningActiveSubtapError {
            print("  Active sub-tap selection error: \(runningActiveSubtapError)")
        }
    }
    print("  Published source: \(describe(publishedSource))")
    print("  Main subdevice UID: \(composition[kAudioAggregateDeviceMainSubDeviceKey] ?? "unavailable")")
    print("  Input safety offset: \(try aggregate.inputSafetyOffset) frames")
    print("  Output safety offset: \(try aggregate.outputSafetyOffset) frames")
    print("  Input latency: \(try aggregate.inputLatency) frames")
    print("  Output latency: \(try aggregate.outputLatency) frames")
    print("  Subdevices: \(try aggregate.subdevices.map(\.id))")
    print("  Subtaps: \(try aggregate.subtaps.map(\.id))")
}

private func runTapOnlyProbe(tap: AudioHardwareTap) throws {
    let aggregate = try createEmptyAggregate(label: "tap only")
    defer { _ = AudioHardwareDestroyAggregateDevice(aggregate.id) }

    try aggregate.setSubtaps([tap])
    try waitUntilAlive(aggregate)
    let automaticSource = try aggregate.clockSource
    let explicitSelectionApplied: Bool
    if automaticSource?.id == tap.id {
        explicitSelectionApplied = true
    } else {
        try aggregate.setClockSource(tap)
        explicitSelectionApplied = try waitForClockSource(tap.id, aggregate: aggregate)
    }
    var runningSource = "unavailable"
    var runningActiveSubtaps: [AudioObjectID] = []
    var runningActiveSubtapError: String?
    try withRunningSilentIO(on: aggregate) {
        let selection = try selectRunningTapClockSource(
            aggregate: aggregate,
            tap: tap
        )
        runningActiveSubtaps = selection.activeSubtapIDs
        runningActiveSubtapError = selection.activeSubtapError
        runningSource = describe(try aggregate.clockSource)
    }

    print("")
    print("Clock source: tap-only aggregate")
    print("  Aggregate object ID: \(aggregate.id)")
    print("  Automatic source: \(describe(automaticSource))")
    print("  Tap selection applied: \(explicitSelectionApplied)")
    print("  Running source: \(runningSource)")
    print("  Active subtaps while running: \(runningActiveSubtaps)")
    if let runningActiveSubtapError {
        print("  Active sub-tap selection error: \(runningActiveSubtapError)")
    }
    print("  Published source: \(describe(try aggregate.clockSource))")
    print("  Input safety offset: \(try aggregate.inputSafetyOffset) frames")
    print("  Output safety offset: \(try aggregate.outputSafetyOffset) frames")
    print("  Subdevices: \(try aggregate.subdevices.map(\.id))")
    print("  Subtaps: \(try aggregate.subtaps.map(\.id))")
}

private func runTapFirstOutputProbe(
    physicalDevice: AudioHardwareDevice,
    tap: AudioHardwareTap
) throws {
    let aggregate = try createEmptyAggregate(label: "tap first")
    defer { _ = AudioHardwareDestroyAggregateDevice(aggregate.id) }

    try aggregate.setSubtaps([tap])
    try waitUntilAlive(aggregate)
    var runningTapSource = false
    var runningActiveSubtaps: [AudioObjectID] = []
    var runningActiveSubtapError: String?
    try withRunningSilentIO(on: aggregate) {
        let selection = try selectRunningTapClockSource(
            aggregate: aggregate,
            tap: tap
        )
        runningActiveSubtaps = selection.activeSubtapIDs
        runningActiveSubtapError = selection.activeSubtapError
        runningTapSource = selection.activeSubtapApplied
            || selection.originalTapApplied
    }
    let sourceAfterStoppingTapOnlyIO = try aggregate.clockSource?.id == tap.id
    try aggregate.setSubdevices([physicalDevice])
    try aggregate.setClockSource(tap)
    let appliedAfterOutput = try waitForClockSource(tap.id, aggregate: aggregate)

    print("")
    print("Clock source: tap first, then physical output")
    print("  Aggregate object ID: \(aggregate.id)")
    print("  Tap source while tap-only IO ran: \(runningTapSource)")
    print("  Active subtaps while tap-only IO ran: \(runningActiveSubtaps)")
    if let runningActiveSubtapError {
        print("  Active sub-tap selection error: \(runningActiveSubtapError)")
    }
    print("  Tap source after stopping tap-only IO: \(sourceAfterStoppingTapOnlyIO)")
    print("  Tap source after output: \(appliedAfterOutput)")
    print("  Published source: \(describe(try aggregate.clockSource))")
    print("  Input safety offset: \(try aggregate.inputSafetyOffset) frames")
    print("  Output safety offset: \(try aggregate.outputSafetyOffset) frames")
    print("  Input latency: \(try aggregate.inputLatency) frames")
    print("  Output latency: \(try aggregate.outputLatency) frames")
    print("  Subdevices: \(try aggregate.subdevices.map(\.id))")
    print("  Subtaps: \(try aggregate.subtaps.map(\.id))")
}

private func selectRunningTapClockSource(
    aggregate: AudioHardwareAggregateDevice,
    tap: AudioHardwareTap
) throws -> RunningTapSelection {
    let activeSubtaps = try aggregate.activeSubtaps
    var activeSubtapApplied = false
    var activeSubtapError: String?
    if let activeSubtap = activeSubtaps.first {
        do {
            try aggregate.setClockSource(activeSubtap)
            activeSubtapApplied = try waitForClockSource(
                activeSubtap.id,
                aggregate: aggregate
            )
        } catch {
            activeSubtapError = String(describing: error)
        }
    }

    try aggregate.setClockSource(tap)
    let originalTapApplied = try waitForClockSource(tap.id, aggregate: aggregate)
    return RunningTapSelection(
        activeSubtapIDs: activeSubtaps.map(\.id),
        activeSubtapApplied: activeSubtapApplied,
        activeSubtapError: activeSubtapError,
        originalTapApplied: originalTapApplied
    )
}

private func withRunningSilentIO(
    on aggregate: AudioHardwareAggregateDevice,
    disabledInputStreamCount: Int = 0,
    _ body: () throws -> Void
) throws {
    var ioProcID: AudioDeviceIOProcID?
    try check(
        AudioDeviceCreateIOProcIDWithBlock(
            &ioProcID,
            aggregate.id,
            nil
        ) { _, _, _, outputData, _ in
            for buffer in UnsafeMutableAudioBufferListPointer(outputData) {
                guard let data = buffer.mData else {
                    continue
                }
                memset(data, 0, Int(buffer.mDataByteSize))
            }
        },
        operation: "AudioDeviceCreateIOProcIDWithBlock(clock-source probe)"
    )
    guard let ioProcID else {
        throw AggregateClockProbeError.unavailable(
            "Core Audio created no IOProc for the clock-source probe"
        )
    }
    let inputStreamCount = try aggregate.inputStreamConfiguration.count
    if inputStreamCount > 0 {
        let usage = (0..<inputStreamCount).map {
            UInt32($0 < disabledInputStreamCount ? 0 : 1)
        }
        try setInputStreamUsage(
            usage,
            aggregateID: aggregate.id,
            ioProcID: ioProcID
        )
    }
    defer {
        _ = AudioDeviceStop(aggregate.id, ioProcID)
        _ = AudioDeviceDestroyIOProcID(aggregate.id, ioProcID)
    }
    try check(
        AudioDeviceStart(aggregate.id, ioProcID),
        operation: "AudioDeviceStart(clock-source probe)"
    )
    Thread.sleep(forTimeInterval: 0.25)
    try body()
}

private func setInputStreamUsage(
    _ usage: [UInt32],
    aggregateID: AudioObjectID,
    ioProcID: AudioDeviceIOProcID
) throws {
    let valuesOffset = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(
        of: \.mStreamIsOn
    )!
    let byteCount = valuesOffset + usage.count * MemoryLayout<UInt32>.stride
    let storage = UnsafeMutableRawPointer.allocate(
        byteCount: byteCount,
        alignment: MemoryLayout<AudioHardwareIOProcStreamUsage>.alignment
    )
    defer { storage.deallocate() }
    storage.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)
    let header = storage.assumingMemoryBound(to: AudioHardwareIOProcStreamUsage.self)
    header.pointee.mIOProc = unsafeBitCast(ioProcID, to: UnsafeMutableRawPointer.self)
    header.pointee.mNumberStreams = UInt32(usage.count)
    let values = storage
        .advanced(by: valuesOffset)
        .assumingMemoryBound(to: UInt32.self)
    for (index, enabled) in usage.enumerated() {
        values[index] = enabled
    }

    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyIOProcStreamUsage,
        mScope: kAudioDevicePropertyScopeInput,
        mElement: kAudioObjectPropertyElementMain
    )
    try check(
        AudioObjectSetPropertyData(
            aggregateID,
            &address,
            0,
            nil,
            UInt32(byteCount),
            storage
        ),
        operation: "AudioObjectSetPropertyData(clock-probe input stream usage)"
    )
}

private func createEmptyAggregate(label: String) throws -> AudioHardwareAggregateDevice {
    let description: [String: Any] = [
        kAudioAggregateDeviceNameKey: "GlassEQ Clock Probe \(label)",
        kAudioAggregateDeviceUIDKey: "com.glasseq.clock-probe.\(UUID().uuidString)",
        kAudioAggregateDeviceIsPrivateKey: true
    ]
    var aggregateID = AudioObjectID(kAudioObjectUnknown)
    try check(
        AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID),
        operation: "AudioHardwareCreateAggregateDevice(\(label))"
    )
    return AudioHardwareAggregateDevice(id: aggregateID)
}

private func waitUntilAlive(_ aggregate: AudioHardwareAggregateDevice) throws {
    let deadline = Date().addingTimeInterval(3)
    repeat {
        if try aggregate.isAlive {
            return
        }
        Thread.sleep(forTimeInterval: 0.05)
    } while Date() < deadline
    throw AggregateClockProbeError.timedOut("aggregate device to become alive")
}

private func waitForClockSource(
    _ expectedID: AudioObjectID,
    aggregate: AudioHardwareAggregateDevice
) throws -> Bool {
    let deadline = Date().addingTimeInterval(3)
    repeat {
        if try aggregate.clockSource?.id == expectedID {
            return true
        }
        Thread.sleep(forTimeInterval: 0.05)
    } while Date() < deadline
    return false
}

private func describe(_ object: AudioHardwareObject?) -> String {
    guard let object else {
        return "none"
    }
    let kind: String
    if object is AudioHardwareTap {
        kind = "tap"
    } else if object is AudioHardwareDevice {
        kind = "device"
    } else if object is AudioHardwareClock {
        kind = "clock"
    } else {
        kind = "object"
    }
    return "\(kind) \(object.id)"
}

private func stringProperty(
    objectID: AudioObjectID,
    selector: AudioObjectPropertySelector
) throws -> String {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var value: CFString = "" as CFString
    var size = UInt32(MemoryLayout<CFString>.size)
    let status = withUnsafeMutablePointer(to: &value) {
        AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, $0)
    }
    try check(status, operation: "AudioObjectGetPropertyData(string)")
    guard size == UInt32(MemoryLayout<CFString>.size) else {
        throw AggregateClockProbeError.unavailable(
            "Core Audio returned an invalid string property size"
        )
    }
    return value as String
}

private func check(_ status: OSStatus, operation: String) throws {
    guard status == noErr else {
        throw AggregateClockProbeError.coreAudio(operation: operation, status: status)
    }
}
