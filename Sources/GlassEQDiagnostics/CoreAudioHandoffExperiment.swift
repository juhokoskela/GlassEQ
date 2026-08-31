import AudioToolbox
import CoreAudio
import Darwin
import Foundation
import Synchronization
@_spi(GlassEQDiagnostics) import GlassEQAudio
import GlassEQCore

enum CoreAudioHandoffExperiment: String {
    case productionStart = "production-start"
    case quiesceOnly = "quiesce-only"
    case combinedIncumbent = "combined-incumbent"
    case combined16 = "combined-16"
    case physicalCreateOnly = "physical-create-only"
    case combinedCreateOnly = "combined-create-only"
    case combinedOutputOnly = "combined-output-only"
    case physicalFirstLiveTaps = "physical-first-live-taps"
    case physicalFirstLiveTaps16 = "physical-first-live-taps-16"
    case completeRouteSwitch = "complete-route-switch"
    case physicalFirstRouteSwitch = "physical-first-route-switch"
}

func runCoreAudioHandoffExperiment(
    _ experiment: CoreAudioHandoffExperiment,
    engine: SystemTapAudioEngine,
    output: AudioOutputDevice,
    holdDuration: TimeInterval
) throws -> Int32 {
    let trace = CoreAudioExperimentTrace()
    engine.setDiagnosticTrace { [trace] hostTimeNanoseconds, message in
        trace.record(hostTimeNanoseconds: hostTimeNanoseconds, message: message)
    }
    defer {
        engine.stop()
        engine.setDiagnosticTrace(nil)
    }

    trace.record(
        message: "experiment begin mode=\(experiment.rawValue) physicalDevice=\(output.id) physicalUID=\(output.uid)"
    )
    printCoreAudioRouteSnapshot(label: "before setup", physicalDeviceID: output.id)

    switch experiment {
    case .productionStart:
        try runProductionStartExperiment(
            engine: engine,
            output: output,
            holdDuration: holdDuration,
            trace: trace
        )
    case .quiesceOnly:
        try runQuiesceOnlyExperiment(
            engine: engine,
            output: output,
            holdDuration: holdDuration,
            trace: trace
        )
    case .combinedIncumbent, .combined16:
        try runCombinedExperiment(
            experiment,
            engine: engine,
            output: output,
            holdDuration: holdDuration,
            trace: trace
        )
    case .physicalCreateOnly:
        try runPhysicalAggregateCreateOnlyExperiment(
            output: output,
            holdDuration: holdDuration,
            trace: trace
        )
    case .combinedCreateOnly:
        try runCombinedAggregateCreateOnlyExperiment(
            output: output,
            holdDuration: holdDuration,
            trace: trace,
            startOutputOnly: false
        )
    case .combinedOutputOnly:
        try runCombinedAggregateCreateOnlyExperiment(
            output: output,
            holdDuration: holdDuration,
            trace: trace,
            startOutputOnly: true
        )
    case .physicalFirstLiveTaps:
        try runPhysicalFirstLiveTapExperiment(
            output: output,
            holdDuration: holdDuration,
            trace: trace,
            stepDownTo16Frames: false
        )
    case .physicalFirstLiveTaps16:
        try runPhysicalFirstLiveTapExperiment(
            output: output,
            holdDuration: holdDuration,
            trace: trace,
            stepDownTo16Frames: true
        )
    case .completeRouteSwitch:
        try runRouteSwitchExperiment(
            engine: engine,
            destination: output,
            holdDuration: holdDuration,
            trace: trace,
            forceCompleteComposition: true
        )
    case .physicalFirstRouteSwitch:
        try runRouteSwitchExperiment(
            engine: engine,
            destination: output,
            holdDuration: holdDuration,
            trace: trace,
            forceCompleteComposition: false
        )
    }

    trace.record(message: "experiment end mode=\(experiment.rawValue)")
    return 0
}

private func runRouteSwitchExperiment(
    engine: SystemTapAudioEngine,
    destination: AudioOutputDevice,
    holdDuration: TimeInterval,
    trace: CoreAudioExperimentTrace,
    forceCompleteComposition: Bool
) throws {
    let initialOutput = try CoreAudioDeviceQuery.defaultOutputDevice()
    guard initialOutput.uid != destination.uid else {
        throw DiagnosticCoreAudioError(
            operation: "The route-switch destination is already the default output",
            status: kAudioHardwareIllegalOperationError
        )
    }
    defer {
        try? setDiagnosticDefaultOutputDevice(initialOutput)
    }

    let victimState = readExperimentValue(
        prompt: "Prepare the default-following victim and explicitly routed destination client, then enter their state:",
        defaultValue: "unspecified"
    )
    trace.record(message: "route-switch victims prepared state=\(victimState)")
    trace.record(message: "route-switch initial engine.start begin output=\(initialOutput.id)")
    try engine.start(output: initialOutput, profile: .flatGraphic31)
    trace.record(message: "route-switch initial engine.start return status=\(engine.status)")
    Thread.sleep(forTimeInterval: 1)

    engine.muteOutputForTransition()
    trace.record(
        message: "route-switch set default begin from=\(initialOutput.id) to=\(destination.id)"
    )
    try setDiagnosticDefaultOutputDevice(destination)
    trace.record(message: "route-switch set default return destination=\(destination.id)")
    Thread.sleep(forTimeInterval: 0.2)

    let liveDestination = try CoreAudioDeviceQuery.outputDevice(id: destination.id)
    let ordering = forceCompleteComposition ? "complete-composition" : "physical-first"
    trace.record(message: "route-switch \(ordering) start begin output=\(liveDestination.id)")
    if forceCompleteComposition {
        try engine.startDiagnosticCombinedPath(
            output: liveDestination,
            profile: .flatGraphic31,
            targetFrameSize: 16
        )
    } else {
        try engine.start(output: liveDestination, profile: .flatGraphic31)
    }
    trace.record(message: "route-switch \(ordering) start return status=\(engine.status)")
    printCoreAudioRouteSnapshot(
        label: "\(ordering) route switch running",
        physicalDeviceID: liveDestination.id
    )

    Thread.sleep(forTimeInterval: holdDuration)
    let result = readExperimentValue(
        prompt: "Enter the audible result, latency, and microphone-indicator state:",
        defaultValue: "unreported"
    )
    trace.record(message: "route-switch \(ordering) result=\(result)")
    printExperimentMeasurements(
        engine: engine,
        sampleRate: liveDestination.nominalSampleRate
    )
}

private func runProductionStartExperiment(
    engine: SystemTapAudioEngine,
    output: AudioOutputDevice,
    holdDuration: TimeInterval,
    trace: CoreAudioExperimentTrace
) throws {
    let victimState = readExperimentValue(
        prompt: "Prepare the victim, then enter its state (for example firefox-playing):",
        defaultValue: "unspecified"
    )
    trace.record(message: "victim prepared state=\(victimState)")
    trace.record(message: "production engine.start begin output=\(output.id)")
    try engine.start(output: output, profile: .flatGraphic31)
    trace.record(
        message: "production engine.start return state=\(engine.state) status=\(engine.status)"
    )
    printCoreAudioRouteSnapshot(
        label: "production engine running",
        physicalDeviceID: output.id
    )
    if let metadata = engine.snapshotLatencyMetadata() {
        printLatencyMetadata(metadata.physicalDevice, label: "Physical device")
        printLatencyMetadata(metadata.aggregateDevice, label: "Combined aggregate")
    }
    Thread.sleep(forTimeInterval: holdDuration)
    let runningResult = readExperimentValue(
        prompt: "With the production EQ runtime active, enter the Firefox result:",
        defaultValue: "unreported"
    )
    trace.record(
        message: "production engine running result=\(runningResult)"
    )
    printExperimentMeasurements(engine: engine, sampleRate: output.nominalSampleRate)
    trace.record(message: "production engine.stop begin")
    engine.stop()
    trace.record(message: "production engine.stop return")
    Thread.sleep(forTimeInterval: 1)
    let stoppedResult = readExperimentValue(
        prompt: "After stopping the production EQ runtime, enter the Firefox result:",
        defaultValue: "unreported"
    )
    trace.record(message: "production engine stopped result=\(stoppedResult)")
}

private func runCombinedAggregateCreateOnlyExperiment(
    output: AudioOutputDevice,
    holdDuration: TimeInterval,
    trace: CoreAudioExperimentTrace,
    startOutputOnly: Bool
) throws {
    let victimState = readExperimentValue(
        prompt: "Prepare the victim, then enter its state (for example firefox-playing or firefox-paused):",
        defaultValue: "unspecified"
    )
    trace.record(message: "victim prepared state=\(victimState)")
    let liveOutput = try CoreAudioDeviceQuery.outputDevice(id: output.id)
    printCoreAudioRouteSnapshot(
        label: "before combined create-only",
        physicalDeviceID: liveOutput.id
    )

    var mainTapID = AudioObjectID(kAudioObjectUnknown)
    var systemSoundTapID = AudioObjectID(kAudioObjectUnknown)
    var aggregateID = AudioObjectID(kAudioObjectUnknown)
    var ioProcID: AudioDeviceIOProcID?
    defer {
        if aggregateID != kAudioObjectUnknown, let ioProcID {
            _ = AudioDeviceStop(aggregateID, ioProcID)
            _ = AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        if aggregateID != kAudioObjectUnknown {
            _ = AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if mainTapID != kAudioObjectUnknown {
            _ = AudioHardwareDestroyProcessTap(mainTapID)
        }
        if systemSoundTapID != kAudioObjectUnknown {
            _ = AudioHardwareDestroyProcessTap(systemSoundTapID)
        }
    }

    let ownProcess = try currentDiagnosticAudioProcessObjectID()
    let mainDescription = CATapDescription(
        excludingProcesses: [ownProcess],
        deviceUID: liveOutput.uid,
        stream: 0
    )
    mainDescription.name = "GlassEQ Create-Only Main Tap"
    mainDescription.uuid = UUID()
    mainDescription.isPrivate = true
    mainDescription.muteBehavior = .mutedWhenTapped
    mainDescription.isMixdown = false
    mainDescription.isProcessRestoreEnabled = true

    let systemSoundDescription = CATapDescription(
        processes: [],
        deviceUID: liveOutput.uid,
        stream: 0
    )
    systemSoundDescription.name = "GlassEQ Create-Only System Sounds Tap"
    systemSoundDescription.uuid = UUID()
    systemSoundDescription.isPrivate = true
    systemSoundDescription.muteBehavior = .mutedWhenTapped
    systemSoundDescription.isMixdown = false
    systemSoundDescription.bundleIDs = ["systemsoundserverd"]
    systemSoundDescription.isProcessRestoreEnabled = true

    trace.record(message: "AudioHardwareCreateProcessTap(create-only main) begin")
    let mainTapStatus = AudioHardwareCreateProcessTap(mainDescription, &mainTapID)
    trace.record(
        message: "AudioHardwareCreateProcessTap(create-only main) return status=\(mainTapStatus) tap=\(mainTapID)"
    )
    try requireNoErr(
        mainTapStatus,
        operation: "AudioHardwareCreateProcessTap(create-only main)"
    )
    trace.record(message: "AudioHardwareCreateProcessTap(create-only system sounds) begin")
    let systemSoundTapStatus = AudioHardwareCreateProcessTap(
        systemSoundDescription,
        &systemSoundTapID
    )
    trace.record(
        message: "AudioHardwareCreateProcessTap(create-only system sounds) return status=\(systemSoundTapStatus) tap=\(systemSoundTapID)"
    )
    try requireNoErr(
        systemSoundTapStatus,
        operation: "AudioHardwareCreateProcessTap(create-only system sounds)"
    )

    let mainTapUID = try getAudioStringProperty(
        objectID: mainTapID,
        selector: kAudioTapPropertyUID,
        scope: kAudioObjectPropertyScopeGlobal
    )
    let systemSoundTapUID = try getAudioStringProperty(
        objectID: systemSoundTapID,
        selector: kAudioTapPropertyUID,
        scope: kAudioObjectPropertyScopeGlobal
    )
    let tapDescription: (String) -> [String: Any] = { uid in
        [
            kAudioSubTapUIDKey: uid,
            kAudioSubTapDriftCompensationKey: true,
            kAudioSubTapDriftCompensationQualityKey:
                kAudioAggregateDriftCompensationHighQuality
        ]
    }
    let aggregateDescription: [String: Any] = [
        kAudioAggregateDeviceNameKey: "GlassEQ Combined Creation Probe",
        kAudioAggregateDeviceUIDKey: "com.glasseq.combined-create-probe.\(UUID().uuidString)",
        kAudioAggregateDeviceIsPrivateKey: true,
        kAudioAggregateDeviceMainSubDeviceKey: liveOutput.uid,
        kAudioAggregateDeviceSubDeviceListKey: [
            [
                kAudioSubDeviceUIDKey: liveOutput.uid,
                kAudioSubDeviceInputChannelsKey: 0,
                kAudioSubDeviceOutputChannelsKey: liveOutput.outputChannelCount,
                kAudioSubDeviceDriftCompensationKey: false
            ]
        ],
        kAudioAggregateDeviceTapListKey: [
            tapDescription(mainTapUID),
            tapDescription(systemSoundTapUID)
        ]
    ]

    trace.record(
        message: "AudioHardwareCreateAggregateDevice(combined create-only) begin physicalDevice=\(liveOutput.id) physicalBuffer=\(liveOutput.bufferFrameSize)"
    )
    let createStatus = AudioHardwareCreateAggregateDevice(
        aggregateDescription as CFDictionary,
        &aggregateID
    )
    trace.record(
        message: "AudioHardwareCreateAggregateDevice(combined create-only) return status=\(createStatus) device=\(aggregateID)"
    )
    try requireNoErr(
        createStatus,
        operation: "AudioHardwareCreateAggregateDevice(combined create-only)"
    )
    try waitUntilDeviceIsAlive(aggregateID)
    let aggregate = try CoreAudioDeviceQuery.outputDevice(id: aggregateID)
    trace.record(
        message: "combined create-only aggregate alive device=\(aggregateID) buffer=\(aggregate.bufferFrameSize); no IOProc will be created or started"
    )
    printCoreAudioRouteSnapshot(
        label: "combined create-only aggregate alive",
        physicalDeviceID: liveOutput.id
    )

    Thread.sleep(forTimeInterval: holdDuration)
    let attachedResult = readExperimentValue(
        prompt: "While the unstarted combined aggregate exists, enter the Firefox result:",
        defaultValue: "unreported"
    )
    trace.record(message: "combined create-only attached result=\(attachedResult)")

    if startOutputOnly {
        trace.record(
            message: "AudioDeviceCreateIOProcIDWithBlock(combined output-only) begin device=\(aggregateID)"
        )
        var createdIOProcID: AudioDeviceIOProcID?
        let createIOProcStatus = AudioDeviceCreateIOProcIDWithBlock(
            &createdIOProcID,
            aggregateID,
            nil
        ) { _, _, _, outputData, _ in
            for buffer in UnsafeMutableAudioBufferListPointer(outputData) {
                guard let data = buffer.mData else {
                    continue
                }
                memset(data, 0, Int(buffer.mDataByteSize))
            }
        }
        trace.record(
            message: "AudioDeviceCreateIOProcIDWithBlock(combined output-only) return status=\(createIOProcStatus) device=\(aggregateID)"
        )
        try requireNoErr(
            createIOProcStatus,
            operation: "AudioDeviceCreateIOProcIDWithBlock(combined output-only)"
        )
        guard let createdIOProcID else {
            throw DiagnosticCoreAudioError(
                operation: "Core Audio returned no combined output-only IOProc",
                status: kAudioHardwareUnspecifiedError
            )
        }
        ioProcID = createdIOProcID

        let aggregateDevice = AudioHardwareAggregateDevice(id: aggregateID)
        let inputStreamCount = try aggregateDevice.inputStreamConfiguration.count
        let inputUsage = [UInt32](repeating: 0, count: inputStreamCount)
        trace.record(
            message: "set combined output-only input usage begin device=\(aggregateID) streams=\(inputStreamCount) usage=\(inputUsage)"
        )
        try setDiagnosticInputStreamUsage(
            inputUsage,
            aggregateID: aggregateID,
            ioProcID: createdIOProcID
        )
        trace.record(
            message: "set combined output-only input usage end device=\(aggregateID)"
        )

        trace.record(
            message: "AudioDeviceStart(combined output-only) begin device=\(aggregateID)"
        )
        let startStatus = AudioDeviceStart(aggregateID, createdIOProcID)
        trace.record(
            message: "AudioDeviceStart(combined output-only) return status=\(startStatus) device=\(aggregateID)"
        )
        try requireNoErr(
            startStatus,
            operation: "AudioDeviceStart(combined output-only)"
        )
        Thread.sleep(forTimeInterval: holdDuration)
        let runningResult = readExperimentValue(
            prompt: "With output-only IO running and all tap inputs disabled, enter the Firefox result:",
            defaultValue: "unreported"
        )
        trace.record(message: "combined output-only running result=\(runningResult)")

        trace.record(
            message: "AudioDeviceStop(combined output-only) begin device=\(aggregateID)"
        )
        let stopStatus = AudioDeviceStop(aggregateID, createdIOProcID)
        trace.record(
            message: "AudioDeviceStop(combined output-only) return status=\(stopStatus) device=\(aggregateID)"
        )
        try requireNoErr(
            stopStatus,
            operation: "AudioDeviceStop(combined output-only)"
        )
        let destroyIOProcStatus = AudioDeviceDestroyIOProcID(
            aggregateID,
            createdIOProcID
        )
        trace.record(
            message: "AudioDeviceDestroyIOProcID(combined output-only) return status=\(destroyIOProcStatus) device=\(aggregateID)"
        )
        try requireNoErr(
            destroyIOProcStatus,
            operation: "AudioDeviceDestroyIOProcID(combined output-only)"
        )
        ioProcID = nil
    }

    trace.record(
        message: "AudioHardwareDestroyAggregateDevice(combined create-only) begin device=\(aggregateID)"
    )
    let destroyAggregateStatus = AudioHardwareDestroyAggregateDevice(aggregateID)
    trace.record(
        message: "AudioHardwareDestroyAggregateDevice(combined create-only) return status=\(destroyAggregateStatus) device=\(aggregateID)"
    )
    try requireNoErr(
        destroyAggregateStatus,
        operation: "AudioHardwareDestroyAggregateDevice(combined create-only)"
    )
    aggregateID = AudioObjectID(kAudioObjectUnknown)

    let destroyMainTapStatus = AudioHardwareDestroyProcessTap(mainTapID)
    trace.record(
        message: "AudioHardwareDestroyProcessTap(create-only main) return status=\(destroyMainTapStatus) tap=\(mainTapID)"
    )
    try requireNoErr(
        destroyMainTapStatus,
        operation: "AudioHardwareDestroyProcessTap(create-only main)"
    )
    mainTapID = AudioObjectID(kAudioObjectUnknown)
    let destroySystemSoundTapStatus = AudioHardwareDestroyProcessTap(systemSoundTapID)
    trace.record(
        message: "AudioHardwareDestroyProcessTap(create-only system sounds) return status=\(destroySystemSoundTapStatus) tap=\(systemSoundTapID)"
    )
    try requireNoErr(
        destroySystemSoundTapStatus,
        operation: "AudioHardwareDestroyProcessTap(create-only system sounds)"
    )
    systemSoundTapID = AudioObjectID(kAudioObjectUnknown)

    Thread.sleep(forTimeInterval: 1)
    let detachedResult = readExperimentValue(
        prompt: "After destroying the create-only aggregate and taps, enter the Firefox result:",
        defaultValue: "unreported"
    )
    trace.record(message: "combined create-only detached result=\(detachedResult)")
}

private func runPhysicalAggregateCreateOnlyExperiment(
    output: AudioOutputDevice,
    holdDuration: TimeInterval,
    trace: CoreAudioExperimentTrace
) throws {
    let victimState = readExperimentValue(
        prompt: "Prepare the victim, then enter its state (for example firefox-playing or firefox-paused):",
        defaultValue: "unspecified"
    )
    trace.record(message: "victim prepared state=\(victimState)")
    let liveOutput = try CoreAudioDeviceQuery.outputDevice(id: output.id)
    printCoreAudioRouteSnapshot(
        label: "before physical-only aggregate creation",
        physicalDeviceID: output.id
    )

    let description: [String: Any] = [
        kAudioAggregateDeviceNameKey: "GlassEQ Physical Creation Probe",
        kAudioAggregateDeviceUIDKey: "com.glasseq.physical-create-probe.\(UUID().uuidString)",
        kAudioAggregateDeviceIsPrivateKey: true,
        kAudioAggregateDeviceMainSubDeviceKey: liveOutput.uid,
        kAudioAggregateDeviceSubDeviceListKey: [
            [
                kAudioSubDeviceUIDKey: liveOutput.uid,
                kAudioSubDeviceInputChannelsKey: 0,
                kAudioSubDeviceOutputChannelsKey: liveOutput.outputChannelCount,
                kAudioSubDeviceDriftCompensationKey: false
            ]
        ]
    ]

    var aggregateID = AudioObjectID(kAudioObjectUnknown)
    defer {
        if aggregateID != kAudioObjectUnknown {
            trace.record(
                message: "AudioHardwareDestroyAggregateDevice(physical-only) begin device=\(aggregateID)"
            )
            let status = AudioHardwareDestroyAggregateDevice(aggregateID)
            trace.record(
                message: "AudioHardwareDestroyAggregateDevice(physical-only) return status=\(status) device=\(aggregateID)"
            )
        }
    }

    trace.record(
        message: "AudioHardwareCreateAggregateDevice(physical-only) begin physicalDevice=\(liveOutput.id) physicalBuffer=\(liveOutput.bufferFrameSize)"
    )
    let createStatus = AudioHardwareCreateAggregateDevice(
        description as CFDictionary,
        &aggregateID
    )
    trace.record(
        message: "AudioHardwareCreateAggregateDevice(physical-only) return status=\(createStatus) device=\(aggregateID)"
    )
    try requireNoErr(
        createStatus,
        operation: "AudioHardwareCreateAggregateDevice(physical-only)"
    )
    try waitUntilDeviceIsAlive(aggregateID)
    let aggregate = try CoreAudioDeviceQuery.outputDevice(id: aggregateID)
    trace.record(
        message: "physical-only aggregate alive device=\(aggregateID) buffer=\(aggregate.bufferFrameSize)"
    )
    printCoreAudioRouteSnapshot(
        label: "physical-only aggregate alive",
        physicalDeviceID: output.id
    )

    Thread.sleep(forTimeInterval: holdDuration)
    let attachedResult = readExperimentValue(
        prompt: "While the physical-only aggregate exists, enter the Firefox result (clean, robotic, silent, or notes):",
        defaultValue: "unreported"
    )
    trace.record(message: "physical-only attached result=\(attachedResult)")

    trace.record(
        message: "AudioHardwareDestroyAggregateDevice(physical-only) begin device=\(aggregateID)"
    )
    let destroyStatus = AudioHardwareDestroyAggregateDevice(aggregateID)
    trace.record(
        message: "AudioHardwareDestroyAggregateDevice(physical-only) return status=\(destroyStatus) device=\(aggregateID)"
    )
    try requireNoErr(
        destroyStatus,
        operation: "AudioHardwareDestroyAggregateDevice(physical-only)"
    )
    aggregateID = AudioObjectID(kAudioObjectUnknown)
    Thread.sleep(forTimeInterval: 1)
    let detachedResult = readExperimentValue(
        prompt: "After destroying the physical-only aggregate, enter the Firefox result:",
        defaultValue: "unreported"
    )
    trace.record(message: "physical-only detached result=\(detachedResult)")
}

private func runPhysicalFirstLiveTapExperiment(
    output: AudioOutputDevice,
    holdDuration: TimeInterval,
    trace: CoreAudioExperimentTrace,
    stepDownTo16Frames: Bool
) throws {
    let victimState = readExperimentValue(
        prompt: "Prepare the victim, then enter its state (for example firefox-playing):",
        defaultValue: "unspecified"
    )
    trace.record(message: "victim prepared state=\(victimState)")
    let liveOutput = try CoreAudioDeviceQuery.outputDevice(id: output.id)
    printCoreAudioRouteSnapshot(
        label: "before physical-first live-tap experiment",
        physicalDeviceID: liveOutput.id
    )

    var aggregateID = AudioObjectID(kAudioObjectUnknown)
    var mainTapID = AudioObjectID(kAudioObjectUnknown)
    var systemSoundTapID = AudioObjectID(kAudioObjectUnknown)
    var ioProcID: AudioDeviceIOProcID?
    defer {
        if aggregateID != kAudioObjectUnknown, let ioProcID {
            _ = AudioDeviceStop(aggregateID, ioProcID)
            _ = AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        if aggregateID != kAudioObjectUnknown {
            _ = AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if mainTapID != kAudioObjectUnknown {
            _ = AudioHardwareDestroyProcessTap(mainTapID)
        }
        if systemSoundTapID != kAudioObjectUnknown {
            _ = AudioHardwareDestroyProcessTap(systemSoundTapID)
        }
    }

    let aggregateDescription: [String: Any] = [
        kAudioAggregateDeviceNameKey: "GlassEQ Physical-First Live-Tap Probe",
        kAudioAggregateDeviceUIDKey: "com.glasseq.physical-first-probe.\(UUID().uuidString)",
        kAudioAggregateDeviceIsPrivateKey: true,
        kAudioAggregateDeviceMainSubDeviceKey: liveOutput.uid,
        kAudioAggregateDeviceSubDeviceListKey: [
            [
                kAudioSubDeviceUIDKey: liveOutput.uid,
                kAudioSubDeviceInputChannelsKey: 0,
                kAudioSubDeviceOutputChannelsKey: liveOutput.outputChannelCount,
                kAudioSubDeviceDriftCompensationKey: false
            ]
        ]
    ]
    trace.record(
        message: "AudioHardwareCreateAggregateDevice(physical-first) begin physicalDevice=\(liveOutput.id) physicalBuffer=\(liveOutput.bufferFrameSize)"
    )
    let createAggregateStatus = AudioHardwareCreateAggregateDevice(
        aggregateDescription as CFDictionary,
        &aggregateID
    )
    trace.record(
        message: "AudioHardwareCreateAggregateDevice(physical-first) return status=\(createAggregateStatus) device=\(aggregateID)"
    )
    try requireNoErr(
        createAggregateStatus,
        operation: "AudioHardwareCreateAggregateDevice(physical-first)"
    )
    try waitUntilDeviceIsAlive(aggregateID)
    let aggregate = AudioHardwareAggregateDevice(id: aggregateID)
    let tapListSettable = try isAudioPropertySettable(
        objectID: aggregateID,
        selector: kAudioAggregateDevicePropertyTapList,
        scope: kAudioObjectPropertyScopeGlobal
    )
    let compositionSettable = try isAudioPropertySettable(
        objectID: aggregateID,
        selector: kAudioAggregateDevicePropertyComposition,
        scope: kAudioObjectPropertyScopeGlobal
    )
    let aggregateOutput = try CoreAudioDeviceQuery.outputDevice(id: aggregateID)
    trace.record(
        message: "physical-first aggregate alive device=\(aggregateID) buffer=\(aggregateOutput.bufferFrameSize) tapListSettable=\(tapListSettable) compositionSettable=\(compositionSettable)"
    )
    printCoreAudioRouteSnapshot(
        label: "physical-first aggregate alive",
        physicalDeviceID: liveOutput.id
    )
    Thread.sleep(forTimeInterval: holdDuration)
    let createdResult = readExperimentValue(
        prompt: "With the unstarted physical-only aggregate present, enter the Firefox result:",
        defaultValue: "unreported"
    )
    trace.record(message: "physical-first aggregate-created result=\(createdResult)")

    let passthrough = LiveTapPassthroughState()
    trace.record(
        message: "AudioDeviceCreateIOProcIDWithBlock(physical-first) begin device=\(aggregateID)"
    )
    var createdIOProcID: AudioDeviceIOProcID?
    let createIOProcStatus = AudioDeviceCreateIOProcIDWithBlock(
        &createdIOProcID,
        aggregateID,
        nil
    ) { _, inputData, inputTime, outputData, outputTime in
        passthrough.render(
            inputData: inputData,
            inputTime: inputTime.pointee,
            outputData: outputData,
            outputTime: outputTime.pointee
        )
    }
    trace.record(
        message: "AudioDeviceCreateIOProcIDWithBlock(physical-first) return status=\(createIOProcStatus) device=\(aggregateID)"
    )
    try requireNoErr(
        createIOProcStatus,
        operation: "AudioDeviceCreateIOProcIDWithBlock(physical-first)"
    )
    guard let createdIOProcID else {
        throw DiagnosticCoreAudioError(
            operation: "Core Audio returned no physical-first IOProc",
            status: kAudioHardwareUnspecifiedError
        )
    }
    ioProcID = createdIOProcID
    trace.record(message: "AudioDeviceStart(physical-first) begin device=\(aggregateID)")
    let startStatus = AudioDeviceStart(aggregateID, createdIOProcID)
    trace.record(
        message: "AudioDeviceStart(physical-first) return status=\(startStatus) device=\(aggregateID)"
    )
    try requireNoErr(startStatus, operation: "AudioDeviceStart(physical-first)")
    Thread.sleep(forTimeInterval: holdDuration)
    let physicalRunningResult = readExperimentValue(
        prompt: "With physical-only aggregate IO running, enter the Firefox result:",
        defaultValue: "unreported"
    )
    trace.record(
        message: "physical-first physical-only-running result=\(physicalRunningResult) metrics=\(passthrough.snapshot())"
    )

    let ownProcess = try currentDiagnosticAudioProcessObjectID()
    let mainDescription = CATapDescription(
        excludingProcesses: [ownProcess],
        deviceUID: liveOutput.uid,
        stream: 0
    )
    mainDescription.name = "GlassEQ Physical-First Main Tap"
    mainDescription.uuid = UUID()
    mainDescription.isPrivate = true
    mainDescription.muteBehavior = .mutedWhenTapped
    mainDescription.isMixdown = false
    mainDescription.isProcessRestoreEnabled = true

    let systemSoundDescription = CATapDescription(
        processes: [],
        deviceUID: liveOutput.uid,
        stream: 0
    )
    systemSoundDescription.name = "GlassEQ Physical-First System Sounds Tap"
    systemSoundDescription.uuid = UUID()
    systemSoundDescription.isPrivate = true
    systemSoundDescription.muteBehavior = .mutedWhenTapped
    systemSoundDescription.isMixdown = false
    systemSoundDescription.bundleIDs = ["systemsoundserverd"]
    systemSoundDescription.isProcessRestoreEnabled = true

    trace.record(message: "AudioHardwareCreateProcessTap(physical-first main) begin")
    let mainTapStatus = AudioHardwareCreateProcessTap(mainDescription, &mainTapID)
    trace.record(
        message: "AudioHardwareCreateProcessTap(physical-first main) return status=\(mainTapStatus) tap=\(mainTapID)"
    )
    try requireNoErr(
        mainTapStatus,
        operation: "AudioHardwareCreateProcessTap(physical-first main)"
    )
    trace.record(message: "AudioHardwareCreateProcessTap(physical-first system sounds) begin")
    let systemSoundTapStatus = AudioHardwareCreateProcessTap(
        systemSoundDescription,
        &systemSoundTapID
    )
    trace.record(
        message: "AudioHardwareCreateProcessTap(physical-first system sounds) return status=\(systemSoundTapStatus) tap=\(systemSoundTapID)"
    )
    try requireNoErr(
        systemSoundTapStatus,
        operation: "AudioHardwareCreateProcessTap(physical-first system sounds)"
    )
    Thread.sleep(forTimeInterval: holdDuration)
    let tapsCreatedResult = readExperimentValue(
        prompt: "With taps created but not attached, enter the Firefox result:",
        defaultValue: "unreported"
    )
    trace.record(message: "physical-first taps-created result=\(tapsCreatedResult)")

    trace.record(
        message: "AudioHardwareAggregateDevice.setSubtaps begin device=\(aggregateID) taps=[\(mainTapID), \(systemSoundTapID)]"
    )
    try aggregate.setSubtaps([
        AudioHardwareTap(id: mainTapID),
        AudioHardwareTap(id: systemSoundTapID)
    ])
    trace.record(
        message: "AudioHardwareAggregateDevice.setSubtaps return device=\(aggregateID)"
    )
    let activeSubtaps = try waitForAggregateSubtaps(2, aggregate: aggregate)
    let inputStreamCount = try aggregate.inputStreamConfiguration.count
    trace.record(
        message: "physical-first subtaps active ids=\(activeSubtaps.map(\.id)) inputStreams=\(inputStreamCount) composition=\(try aggregate.composition)"
    )
    if inputStreamCount > 0 {
        do {
            let usage = [UInt32](repeating: 1, count: inputStreamCount)
            trace.record(
                message: "set physical-first input usage begin device=\(aggregateID) usage=\(usage)"
            )
            try setDiagnosticInputStreamUsage(
                usage,
                aggregateID: aggregateID,
                ioProcID: createdIOProcID
            )
            trace.record(
                message: "set physical-first input usage end device=\(aggregateID)"
            )
        } catch {
            trace.record(
                message: "set physical-first input usage failed device=\(aggregateID) error=\(error)"
            )
        }
    }
    Thread.sleep(forTimeInterval: holdDuration)
    let attachedResult = readExperimentValue(
        prompt: "With taps attached live and passed through, enter the Firefox result:",
        defaultValue: "unreported"
    )
    trace.record(
        message: "physical-first live-taps result=\(attachedResult) metrics=\(passthrough.snapshot())"
    )

    if stepDownTo16Frames {
        trace.record(
            message: "set physical-first aggregate buffer begin device=\(aggregateID) requested=16 current=\((try CoreAudioDeviceQuery.outputDevice(id: aggregateID)).bufferFrameSize)"
        )
        try CoreAudioDeviceQuery.setBufferFrameSize(16, objectID: aggregateID)
        let resizedAggregate = try waitForAggregateBufferFrameSize(
            16,
            aggregateID: aggregateID
        )
        trace.record(
            message: "set physical-first aggregate buffer end device=\(aggregateID) actual=\(resizedAggregate.bufferFrameSize)"
        )
        Thread.sleep(forTimeInterval: holdDuration)
        let resizedResult = readExperimentValue(
            prompt: "With the live tap aggregate now at 16 frames, enter the Firefox result:",
            defaultValue: "unreported"
        )
        trace.record(
            message: "physical-first live-taps-16 result=\(resizedResult) metrics=\(passthrough.snapshot())"
        )
    }

    trace.record(message: "AudioDeviceStop(physical-first) begin device=\(aggregateID)")
    let stopStatus = AudioDeviceStop(aggregateID, createdIOProcID)
    trace.record(
        message: "AudioDeviceStop(physical-first) return status=\(stopStatus) device=\(aggregateID)"
    )
    try requireNoErr(stopStatus, operation: "AudioDeviceStop(physical-first)")
    let destroyIOProcStatus = AudioDeviceDestroyIOProcID(aggregateID, createdIOProcID)
    trace.record(
        message: "AudioDeviceDestroyIOProcID(physical-first) return status=\(destroyIOProcStatus) device=\(aggregateID)"
    )
    try requireNoErr(
        destroyIOProcStatus,
        operation: "AudioDeviceDestroyIOProcID(physical-first)"
    )
    ioProcID = nil
    trace.record(
        message: "AudioHardwareDestroyAggregateDevice(physical-first) begin device=\(aggregateID)"
    )
    let destroyAggregateStatus = AudioHardwareDestroyAggregateDevice(aggregateID)
    trace.record(
        message: "AudioHardwareDestroyAggregateDevice(physical-first) return status=\(destroyAggregateStatus) device=\(aggregateID)"
    )
    try requireNoErr(
        destroyAggregateStatus,
        operation: "AudioHardwareDestroyAggregateDevice(physical-first)"
    )
    aggregateID = AudioObjectID(kAudioObjectUnknown)
    let destroyMainTapStatus = AudioHardwareDestroyProcessTap(mainTapID)
    trace.record(
        message: "AudioHardwareDestroyProcessTap(physical-first main) return status=\(destroyMainTapStatus) tap=\(mainTapID)"
    )
    try requireNoErr(
        destroyMainTapStatus,
        operation: "AudioHardwareDestroyProcessTap(physical-first main)"
    )
    mainTapID = AudioObjectID(kAudioObjectUnknown)
    let destroySystemSoundTapStatus = AudioHardwareDestroyProcessTap(systemSoundTapID)
    trace.record(
        message: "AudioHardwareDestroyProcessTap(physical-first system sounds) return status=\(destroySystemSoundTapStatus) tap=\(systemSoundTapID)"
    )
    try requireNoErr(
        destroySystemSoundTapStatus,
        operation: "AudioHardwareDestroyProcessTap(physical-first system sounds)"
    )
    systemSoundTapID = AudioObjectID(kAudioObjectUnknown)

    Thread.sleep(forTimeInterval: 1)
    let detachedResult = readExperimentValue(
        prompt: "After destroying the physical-first probe, enter the Firefox result:",
        defaultValue: "unreported"
    )
    trace.record(message: "physical-first detached result=\(detachedResult)")
}

private final class LiveTapPassthroughState: @unchecked Sendable {
    private let callbackCount = Atomic<UInt64>(0)
    private let inputCallbackCount = Atomic<UInt64>(0)
    private let nonzeroInputCallbackCount = Atomic<UInt64>(0)
    private let copiedFrames = Atomic<UInt64>(0)
    private let maximumInputNanoAmplitude = Atomic<UInt64>(0)
    private let firstCallbackHostTimeNanoseconds = Atomic<UInt64>(0)
    private let lastInputSampleTimeBits = Atomic<UInt64>(0)
    private let lastInputHostTime = Atomic<UInt64>(0)
    private let lastInputFlags = Atomic<UInt64>(0)
    private let lastInputFrameCount = Atomic<UInt64>(0)
    private let lastOutputSampleTimeBits = Atomic<UInt64>(0)
    private let lastOutputHostTime = Atomic<UInt64>(0)
    private let lastOutputFlags = Atomic<UInt64>(0)
    private let lastOutputFrameCount = Atomic<UInt64>(0)
    private let lastTapToOutputLatencyNanoseconds = Atomic<UInt64>(0)
    private let inputTimestampSeen = Atomic<Bool>(false)
    private let previousInputSampleTimeBits = Atomic<UInt64>(0)
    private let previousInputFrameCount = Atomic<UInt64>(0)
    private let inputTimestampDiscontinuities = Atomic<UInt64>(0)
    private let outputTimestampSeen = Atomic<Bool>(false)
    private let previousOutputSampleTimeBits = Atomic<UInt64>(0)
    private let previousOutputFrameCount = Atomic<UInt64>(0)
    private let outputTimestampDiscontinuities = Atomic<UInt64>(0)

    func render(
        inputData: UnsafePointer<AudioBufferList>,
        inputTime: AudioTimeStamp,
        outputData: UnsafeMutablePointer<AudioBufferList>,
        outputTime: AudioTimeStamp
    ) {
        let inputs = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inputData)
        )
        let outputs = UnsafeMutableAudioBufferListPointer(outputData)
        for buffer in outputs where buffer.mData != nil {
            memset(buffer.mData, 0, Int(buffer.mDataByteSize))
        }
        callbackCount.wrappingAdd(1, ordering: .relaxed)
        let callbackHostTime = AudioConvertHostTimeToNanos(AudioGetCurrentHostTime())
        _ = firstCallbackHostTimeNanoseconds.compareExchange(
            expected: 0,
            desired: callbackHostTime,
            ordering: .relaxed
        )
        lastInputSampleTimeBits.store(inputTime.mSampleTime.bitPattern, ordering: .relaxed)
        lastInputHostTime.store(inputTime.mHostTime, ordering: .relaxed)
        lastInputFlags.store(UInt64(inputTime.mFlags.rawValue), ordering: .relaxed)
        lastOutputSampleTimeBits.store(outputTime.mSampleTime.bitPattern, ordering: .relaxed)
        lastOutputHostTime.store(outputTime.mHostTime, ordering: .relaxed)
        lastOutputFlags.store(UInt64(outputTime.mFlags.rawValue), ordering: .relaxed)

        guard let inputFrameCount = Self.frameCount(
            buffers: inputs,
            channelRange: 0..<2
        ),
              let outputFrameCount = Self.frameCount(
                buffers: outputs,
                channelRange: 0..<2
              ) else {
            return
        }
        let frameCount = min(inputFrameCount, outputFrameCount)
        guard frameCount > 0 else {
            return
        }
        lastInputFrameCount.store(UInt64(inputFrameCount), ordering: .relaxed)
        lastOutputFrameCount.store(UInt64(outputFrameCount), ordering: .relaxed)
        recordTimestampContinuity(
            sampleTime: inputTime.mSampleTime,
            flags: inputTime.mFlags,
            frameCount: inputFrameCount,
            seen: inputTimestampSeen,
            previousSampleTimeBits: previousInputSampleTimeBits,
            previousFrameCount: previousInputFrameCount,
            discontinuities: inputTimestampDiscontinuities
        )
        recordTimestampContinuity(
            sampleTime: outputTime.mSampleTime,
            flags: outputTime.mFlags,
            frameCount: outputFrameCount,
            seen: outputTimestampSeen,
            previousSampleTimeBits: previousOutputSampleTimeBits,
            previousFrameCount: previousOutputFrameCount,
            discontinuities: outputTimestampDiscontinuities
        )
        if inputTime.mFlags.contains(.hostTimeValid),
           outputTime.mFlags.contains(.hostTimeValid),
           outputTime.mHostTime >= inputTime.mHostTime {
            lastTapToOutputLatencyNanoseconds.store(
                AudioConvertHostTimeToNanos(outputTime.mHostTime - inputTime.mHostTime),
                ordering: .relaxed
            )
        }
        inputCallbackCount.wrappingAdd(1, ordering: .relaxed)
        var callbackPeak: Float = 0
        for frame in 0..<frameCount {
            for channel in 0..<2 {
                let sample = Self.sample(
                    from: inputs,
                    frame: frame,
                    globalChannel: channel
                )
                if sample.isFinite {
                    callbackPeak = max(callbackPeak, abs(sample))
                    Self.write(
                        sample,
                        to: outputs,
                        frame: frame,
                        globalChannel: channel
                    )
                }
            }
        }
        if callbackPeak > 1e-6 {
            nonzeroInputCallbackCount.wrappingAdd(1, ordering: .relaxed)
        }
        copiedFrames.wrappingAdd(UInt64(frameCount), ordering: .relaxed)
        let nanoAmplitude = UInt64(
            min(Double(callbackPeak), 1_000_000) * 1_000_000_000
        )
        var currentMaximum = maximumInputNanoAmplitude.load(ordering: .relaxed)
        while nanoAmplitude > currentMaximum {
            let result = maximumInputNanoAmplitude.compareExchange(
                expected: currentMaximum,
                desired: nanoAmplitude,
                ordering: .relaxed
            )
            if result.exchanged {
                break
            }
            currentMaximum = result.original
        }
    }

    func snapshot() -> String {
        let peak = Double(maximumInputNanoAmplitude.load(ordering: .relaxed))
            / 1_000_000_000
        let inputSampleTime = Double(
            bitPattern: lastInputSampleTimeBits.load(ordering: .relaxed)
        )
        let outputSampleTime = Double(
            bitPattern: lastOutputSampleTimeBits.load(ordering: .relaxed)
        )
        return "callbacks=\(callbackCount.load(ordering: .relaxed)) inputCallbacks=\(inputCallbackCount.load(ordering: .relaxed)) nonzeroInputCallbacks=\(nonzeroInputCallbackCount.load(ordering: .relaxed)) copiedFrames=\(copiedFrames.load(ordering: .relaxed)) maxInputPeak=\(peak) lastInputFrames=\(lastInputFrameCount.load(ordering: .relaxed)) lastOutputFrames=\(lastOutputFrameCount.load(ordering: .relaxed)) inputTimestampDiscontinuities=\(inputTimestampDiscontinuities.load(ordering: .relaxed)) outputTimestampDiscontinuities=\(outputTimestampDiscontinuities.load(ordering: .relaxed)) lastTapToOutputLatencyNs=\(lastTapToOutputLatencyNanoseconds.load(ordering: .relaxed)) lastSampleTimeDeltaFrames=\(outputSampleTime - inputSampleTime) firstCallbackHostNs=\(firstCallbackHostTimeNanoseconds.load(ordering: .relaxed)) lastInputSampleTime=\(inputSampleTime) lastInputHostTime=\(lastInputHostTime.load(ordering: .relaxed)) lastInputFlags=\(lastInputFlags.load(ordering: .relaxed)) lastOutputSampleTime=\(outputSampleTime) lastOutputHostTime=\(lastOutputHostTime.load(ordering: .relaxed)) lastOutputFlags=\(lastOutputFlags.load(ordering: .relaxed))"
    }

    private func recordTimestampContinuity(
        sampleTime: Float64,
        flags: AudioTimeStampFlags,
        frameCount: Int,
        seen: borrowing Atomic<Bool>,
        previousSampleTimeBits: borrowing Atomic<UInt64>,
        previousFrameCount: borrowing Atomic<UInt64>,
        discontinuities: borrowing Atomic<UInt64>
    ) {
        guard flags.contains(.sampleTimeValid) else {
            return
        }
        if seen.load(ordering: .relaxed) {
            let previous = Double(
                bitPattern: previousSampleTimeBits.load(ordering: .relaxed)
            )
            let expected = previous
                + Double(previousFrameCount.load(ordering: .relaxed))
            if abs(sampleTime - expected) > 0.5 {
                discontinuities.wrappingAdd(1, ordering: .relaxed)
            }
        }
        previousSampleTimeBits.store(sampleTime.bitPattern, ordering: .relaxed)
        previousFrameCount.store(UInt64(frameCount), ordering: .relaxed)
        seen.store(true, ordering: .relaxed)
    }

    private static func frameCount(
        buffers: UnsafeMutableAudioBufferListPointer,
        channelRange: Range<Int>
    ) -> Int? {
        var globalChannelOffset = 0
        var coveredChannels = 0
        var minimumFrameCount = Int.max
        for buffer in buffers {
            let channels = Int(buffer.mNumberChannels)
            guard channels > 0 else {
                continue
            }
            let bufferRange = globalChannelOffset..<(globalChannelOffset + channels)
            let overlap = bufferRange.clamped(to: channelRange)
            if !overlap.isEmpty {
                guard buffer.mData != nil,
                      buffer.mDataByteSize
                        % UInt32(channels * MemoryLayout<Float>.stride) == 0 else {
                    return nil
                }
                coveredChannels += overlap.count
                minimumFrameCount = min(
                    minimumFrameCount,
                    Int(buffer.mDataByteSize) / (channels * MemoryLayout<Float>.stride)
                )
            }
            globalChannelOffset = bufferRange.upperBound
        }
        guard coveredChannels == channelRange.count,
              minimumFrameCount != Int.max else {
            return nil
        }
        return minimumFrameCount
    }

    private static func sample(
        from buffers: UnsafeMutableAudioBufferListPointer,
        frame: Int,
        globalChannel: Int
    ) -> Float {
        var remainingChannel = globalChannel
        for buffer in buffers {
            let channels = Int(buffer.mNumberChannels)
            guard channels > 0 else {
                continue
            }
            guard remainingChannel < channels else {
                remainingChannel -= channels
                continue
            }
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else {
                return 0
            }
            return data[frame * channels + remainingChannel]
        }
        return 0
    }

    private static func write(
        _ sample: Float,
        to buffers: UnsafeMutableAudioBufferListPointer,
        frame: Int,
        globalChannel: Int
    ) {
        var remainingChannel = globalChannel
        for buffer in buffers {
            let channels = Int(buffer.mNumberChannels)
            guard channels > 0 else {
                continue
            }
            guard remainingChannel < channels else {
                remainingChannel -= channels
                continue
            }
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else {
                return
            }
            data[frame * channels + remainingChannel] = sample
            return
        }
    }
}

private func waitForAggregateSubtaps(
    _ expectedCount: Int,
    aggregate: AudioHardwareAggregateDevice
) throws -> [AudioHardwareTap] {
    let deadline = Date().addingTimeInterval(3)
    repeat {
        let subtaps = try aggregate.subtaps
        if subtaps.count == expectedCount {
            return subtaps
        }
        Thread.sleep(forTimeInterval: 0.05)
    } while Date() < deadline
    throw DiagnosticCoreAudioError(
        operation: "wait for aggregate \(aggregate.id) to publish \(expectedCount) subtaps",
        status: kAudioHardwareNotRunningError
    )
}

private func waitForAggregateBufferFrameSize(
    _ expectedFrameSize: UInt32,
    aggregateID: AudioObjectID
) throws -> AudioOutputDevice {
    let deadline = Date().addingTimeInterval(3)
    repeat {
        let aggregate = try CoreAudioDeviceQuery.outputDevice(id: aggregateID)
        if aggregate.bufferFrameSize == expectedFrameSize {
            return aggregate
        }
        Thread.sleep(forTimeInterval: 0.01)
    } while Date() < deadline
    throw DiagnosticCoreAudioError(
        operation: "wait for aggregate \(aggregateID) buffer size \(expectedFrameSize)",
        status: kAudioHardwareUnspecifiedError
    )
}

private func waitUntilDeviceIsAlive(_ deviceID: AudioObjectID) throws {
    let deadline = Date().addingTimeInterval(3)
    repeat {
        if try CoreAudioDeviceQuery.isDeviceAlive(id: deviceID) {
            return
        }
        Thread.sleep(forTimeInterval: 0.05)
    } while Date() < deadline
    throw DiagnosticCoreAudioError(
        operation: "wait for aggregate \(deviceID) to become alive",
        status: kAudioHardwareNotRunningError
    )
}

private func runQuiesceOnlyExperiment(
    engine: SystemTapAudioEngine,
    output: AudioOutputDevice,
    holdDuration: TimeInterval,
    trace: CoreAudioExperimentTrace
) throws {
    let profile = EQProfile.flatGraphic31
    try engine.startDiagnosticCompatibilityPath(output: output, profile: profile)
    trace.record(message: "compatibility path running")
    printCoreAudioRouteSnapshot(
        label: "compatibility running",
        physicalDeviceID: output.id
    )

    let victimState = readExperimentValue(
        prompt: "Prepare the victim, then enter its state (for example firefox-playing or firefox-paused):",
        defaultValue: "unspecified"
    )
    trace.record(message: "victim prepared state=\(victimState)")
    printCoreAudioRouteSnapshot(label: "before quiesce", physicalDeviceID: output.id)

    trace.record(message: "STOP-ONLY CONTROL begin; no combined aggregate will be created")
    try engine.quiesceDiagnosticCompatibilityOutput()
    trace.record(message: "STOP-ONLY CONTROL quiesced")
    printCoreAudioRouteSnapshot(label: "after quiesce", physicalDeviceID: output.id)

    Thread.sleep(forTimeInterval: holdDuration)
    trace.record(message: "STOP-ONLY CONTROL hold complete seconds=\(holdDuration)")
    try engine.restoreDiagnosticCompatibilityOutput(output: output, profile: profile)
    trace.record(message: "STOP-ONLY CONTROL compatibility restored")
    printCoreAudioRouteSnapshot(label: "after restore", physicalDeviceID: output.id)

    let result = readExperimentValue(
        prompt: "Resume or listen to the victim, then enter the result (clean, robotic, silent, dry-leak, or notes):",
        defaultValue: "unreported"
    )
    trace.record(message: "audible result=\(result)")
    printExperimentMeasurements(engine: engine, sampleRate: output.nominalSampleRate)
}

private func runCombinedExperiment(
    _ experiment: CoreAudioHandoffExperiment,
    engine: SystemTapAudioEngine,
    output: AudioOutputDevice,
    holdDuration: TimeInterval,
    trace: CoreAudioExperimentTrace
) throws {
    let victimState = readExperimentValue(
        prompt: "Prepare the victim, then enter its state (for example firefox-playing or firefox-paused):",
        defaultValue: "unspecified"
    )
    trace.record(message: "victim prepared state=\(victimState)")

    let liveOutput = try CoreAudioDeviceQuery.outputDevice(id: output.id)
    let targetFrameSize = experiment == .combinedIncumbent
        ? liveOutput.bufferFrameSize
        : 16
    trace.record(
        message: "DIRECT COMBINED CONTROL begin physicalBuffer=\(liveOutput.bufferFrameSize) targetAggregateBuffer=\(targetFrameSize)"
    )
    printCoreAudioRouteSnapshot(label: "before combined attach", physicalDeviceID: output.id)
    try engine.startDiagnosticCombinedPath(
        output: liveOutput,
        profile: .flatGraphic31,
        targetFrameSize: targetFrameSize
    )
    trace.record(message: "DIRECT COMBINED CONTROL running")
    printCoreAudioRouteSnapshot(label: "after combined start", physicalDeviceID: output.id)

    Thread.sleep(forTimeInterval: holdDuration)
    let result = readExperimentValue(
        prompt: "Resume or listen to the victim, then enter the result (clean, robotic, silent, dry-leak, or notes):",
        defaultValue: "unreported"
    )
    trace.record(message: "audible result=\(result)")
    printExperimentMeasurements(engine: engine, sampleRate: liveOutput.nominalSampleRate)
}

private func readExperimentValue(prompt: String, defaultValue: String) -> String {
    print(prompt)
    fflush(stdout)
    guard let value = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines),
          !value.isEmpty else {
        return defaultValue
    }
    return value.replacingOccurrences(of: "\n", with: " ")
}

private func printExperimentMeasurements(
    engine: SystemTapAudioEngine,
    sampleRate: Double
) {
    if let latencyMetadata = engine.snapshotLatencyMetadata() {
        printLatencyMetadata(latencyMetadata.physicalDevice, label: "Physical device")
        printLatencyMetadata(latencyMetadata.aggregateDevice, label: "Combined aggregate")
    }
    printMetrics(engine.snapshotMetrics(), sampleRate: sampleRate)
    printTimestampProbeRecords(engine.snapshotTimestampProbeRecords())
}

private final class CoreAudioExperimentTrace: @unchecked Sendable {
    private let originHostTimeNanoseconds = AudioConvertHostTimeToNanos(
        AudioGetCurrentHostTime()
    )

    func record(
        hostTimeNanoseconds: UInt64? = nil,
        message: String
    ) {
        let timestamp = hostTimeNanoseconds ?? AudioConvertHostTimeToNanos(
            AudioGetCurrentHostTime()
        )
        let relativeNanoseconds = timestamp >= originHostTimeNanoseconds
            ? timestamp - originHostTimeNanoseconds
            : 0
        let prefix = String(
            format: "TRACE +%9.3f ms host_ns=%llu",
            Double(relativeNanoseconds) / 1_000_000,
            timestamp
        )
        print("\(prefix) \(message)")
        fflush(stdout)
    }
}

private func printCoreAudioRouteSnapshot(
    label: String,
    physicalDeviceID: AudioObjectID
) {
    print("Core Audio route snapshot: \(label)")
    if let defaultOutput = try? CoreAudioDeviceQuery.defaultOutputDevice() {
        print(
            "  default output: id=\(defaultOutput.id) uid=\(defaultOutput.uid) buffer=\(defaultOutput.bufferFrameSize) sampleRate=\(defaultOutput.nominalSampleRate)"
        )
    } else {
        print("  default output: unavailable")
    }
    if let physicalOutput = try? CoreAudioDeviceQuery.outputDevice(id: physicalDeviceID) {
        print(
            "  physical output: id=\(physicalOutput.id) uid=\(physicalOutput.uid) buffer=\(physicalOutput.bufferFrameSize) sampleRate=\(physicalOutput.nominalSampleRate)"
        )
    } else {
        print("  physical output: unavailable id=\(physicalDeviceID)")
    }

    do {
        let processes = try audioProcessSnapshots(using: physicalDeviceID)
        if processes.isEmpty {
            print("  physical-output process objects: none")
        }
        for process in processes {
            print(
                "  process object=\(process.objectID) pid=\(process.pid) bundle=\(process.bundleID) runningOutput=\(process.isRunningOutput) outputDevices=\(process.outputDeviceIDs)"
            )
        }
    } catch {
        print("  physical-output process objects: unavailable error=\(error)")
    }
    fflush(stdout)
}

private struct AudioProcessSnapshot {
    var objectID: AudioObjectID
    var pid: pid_t
    var bundleID: String
    var isRunningOutput: Bool
    var outputDeviceIDs: [AudioObjectID]
}

private func audioProcessSnapshots(
    using physicalDeviceID: AudioObjectID
) throws -> [AudioProcessSnapshot] {
    let processObjectIDs = try getAudioObjectIDs(
        objectID: AudioObjectID(kAudioObjectSystemObject),
        selector: kAudioHardwarePropertyProcessObjectList,
        scope: kAudioObjectPropertyScopeGlobal
    )
    return processObjectIDs.compactMap { processObjectID in
        guard let outputDeviceIDs = try? getAudioObjectIDs(
            objectID: processObjectID,
            selector: kAudioProcessPropertyDevices,
            scope: kAudioObjectPropertyScopeOutput
        ), outputDeviceIDs.contains(physicalDeviceID) else {
            return nil
        }
        let pid = (try? getAudioProperty(
            objectID: processObjectID,
            selector: kAudioProcessPropertyPID,
            scope: kAudioObjectPropertyScopeGlobal,
            initialValue: pid_t(0)
        )) ?? 0
        let bundleID = (try? getAudioStringProperty(
            objectID: processObjectID,
            selector: kAudioProcessPropertyBundleID,
            scope: kAudioObjectPropertyScopeGlobal
        )) ?? "unknown"
        let isRunningOutput = ((try? getAudioProperty(
            objectID: processObjectID,
            selector: kAudioProcessPropertyIsRunningOutput,
            scope: kAudioObjectPropertyScopeGlobal,
            initialValue: UInt32(0)
        )) ?? 0) != 0
        return AudioProcessSnapshot(
            objectID: processObjectID,
            pid: pid,
            bundleID: bundleID,
            isRunningOutput: isRunningOutput,
            outputDeviceIDs: outputDeviceIDs
        )
    }.sorted { lhs, rhs in
        if lhs.bundleID == rhs.bundleID {
            return lhs.pid < rhs.pid
        }
        return lhs.bundleID < rhs.bundleID
    }
}

private func getAudioObjectIDs(
    objectID: AudioObjectID,
    selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope
) throws -> [AudioObjectID] {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
    )
    var size = UInt32(0)
    try requireNoErr(
        AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size),
        operation: "AudioObjectGetPropertyDataSize(\(selector))"
    )
    guard size % UInt32(MemoryLayout<AudioObjectID>.stride) == 0 else {
        throw DiagnosticCoreAudioError(
            operation: "AudioObjectGetPropertyDataSize(\(selector)) returned \(size) bytes",
            status: kAudioHardwareBadPropertySizeError
        )
    }
    let count = Int(size) / MemoryLayout<AudioObjectID>.stride
    guard count > 0 else {
        return []
    }
    let pointer = UnsafeMutablePointer<AudioObjectID>.allocate(capacity: count)
    defer { pointer.deallocate() }
    try requireNoErr(
        AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, pointer),
        operation: "AudioObjectGetPropertyData(\(selector))"
    )
    return Array(UnsafeBufferPointer(start: pointer, count: count))
}

private func getAudioProperty<Value: BitwiseCopyable>(
    objectID: AudioObjectID,
    selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope,
    initialValue: Value
) throws -> Value {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
    )
    var size = UInt32(MemoryLayout<Value>.size)
    let pointer = UnsafeMutablePointer<Value>.allocate(capacity: 1)
    pointer.initialize(to: initialValue)
    defer {
        pointer.deinitialize(count: 1)
        pointer.deallocate()
    }
    try requireNoErr(
        AudioObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            &size,
            UnsafeMutableRawPointer(pointer)
        ),
        operation: "AudioObjectGetPropertyData(\(selector))"
    )
    return pointer.pointee
}

private func getAudioStringProperty(
    objectID: AudioObjectID,
    selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope
) throws -> String {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
    )
    let pointer = UnsafeMutablePointer<CFString?>.allocate(capacity: 1)
    pointer.initialize(to: nil)
    defer {
        pointer.deinitialize(count: 1)
        pointer.deallocate()
    }
    var size = UInt32(MemoryLayout<CFString?>.size)
    try requireNoErr(
        AudioObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            &size,
            UnsafeMutableRawPointer(pointer)
        ),
        operation: "AudioObjectGetPropertyData(\(selector))"
    )
    guard let value = pointer.pointee else {
        return "unknown"
    }
    return value as String
}

private func isAudioPropertySettable(
    objectID: AudioObjectID,
    selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope
) throws -> Bool {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: scope,
        mElement: kAudioObjectPropertyElementMain
    )
    var settable = DarwinBoolean(false)
    try requireNoErr(
        AudioObjectIsPropertySettable(objectID, &address, &settable),
        operation: "AudioObjectIsPropertySettable(\(selector))"
    )
    return settable.boolValue
}

private struct DiagnosticCoreAudioError: Error, CustomStringConvertible {
    var operation: String
    var status: OSStatus

    var description: String {
        "\(operation) failed with OSStatus \(status)"
    }
}

private func setDiagnosticInputStreamUsage(
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
    let header = storage.assumingMemoryBound(
        to: AudioHardwareIOProcStreamUsage.self
    )
    header.pointee.mIOProc = unsafeBitCast(
        ioProcID,
        to: UnsafeMutableRawPointer.self
    )
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
    try requireNoErr(
        AudioObjectSetPropertyData(
            aggregateID,
            &address,
            0,
            nil,
            UInt32(byteCount),
            storage
        ),
        operation: "AudioObjectSetPropertyData(diagnostics input stream usage)"
    )
}

private func currentDiagnosticAudioProcessObjectID() throws -> AudioObjectID {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var pid = getpid()
    var processID = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    try requireNoErr(
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<pid_t>.size),
            &pid,
            &size,
            &processID
        ),
        operation: "AudioObjectGetPropertyData(translate diagnostics pid)"
    )
    guard processID != kAudioObjectUnknown else {
        throw DiagnosticCoreAudioError(
            operation: "Core Audio did not publish the diagnostics process object",
            status: kAudioHardwareBadObjectError
        )
    }
    return processID
}

private func requireNoErr(_ status: OSStatus, operation: String) throws {
    guard status == noErr else {
        throw DiagnosticCoreAudioError(operation: operation, status: status)
    }
}
