public struct EQTransitionRenderResult: Sendable {
    public var saturatedSamples: UInt64
    public var completedTransition: Bool
    public var retiredProcessor: EQProcessor?
    public var secondRetiredProcessor: EQProcessor?
    public var blendStartFrame: Int?
    public var blendFrameCount: Int
    public var programmeComparison: EQProgrammeComparisonSnapshot
    public var workTiming: EQRenderWorkTiming

    public init(
        saturatedSamples: UInt64 = 0,
        completedTransition: Bool = false,
        retiredProcessor: EQProcessor? = nil,
        secondRetiredProcessor: EQProcessor? = nil,
        blendStartFrame: Int? = nil,
        blendFrameCount: Int = 0,
        programmeComparison: EQProgrammeComparisonSnapshot = EQProgrammeComparisonSnapshot(),
        workTiming: EQRenderWorkTiming = EQRenderWorkTiming()
    ) {
        self.saturatedSamples = saturatedSamples
        self.completedTransition = completedTransition
        self.retiredProcessor = retiredProcessor
        self.secondRetiredProcessor = secondRetiredProcessor
        self.blendStartFrame = blendStartFrame
        self.blendFrameCount = blendFrameCount
        self.programmeComparison = programmeComparison
        self.workTiming = workTiming
    }

    @inline(__always)
    public func incomingBlendWeight(frameOffset: Int) -> Float {
        guard let blendStartFrame,
              blendFrameCount > 0 else {
            return 0
        }
        if blendFrameCount == 1 {
            return 1
        }
        let transitionFrame = min(
            max(blendStartFrame + max(frameOffset, 0), 0),
            blendFrameCount - 1
        )
        return Self.smoothstep(
            Float(transitionFrame) / Float(blendFrameCount - 1)
        )
    }

    @inline(__always)
    static func smoothstep(_ progress: Float) -> Float {
        progress * progress * (3 - 2 * progress)
    }
}

public struct RealtimeEQTransition: Sendable {
    public static let defaultWarmupSeconds = 0.020
    public static let defaultBlendSeconds = 0.010

    private var activeProcessor: EQProcessor
    private var incomingProcessor: EQProcessor?
    private var pendingComparisonReferenceProcessor: EQProcessor?
    private var comparisonReferenceProcessor: EQProcessor?
    private var retiredComparisonProcessor: EQProcessor?
    private var alternateSamples: [Float]
    private let channelCount: Int
    private let warmupFrameCount: Int
    private let blendFrameCount: Int
    private var warmupFramesRemaining = 0
    private var blendedFrames = 0
    private var comparisonWarmupFramesRemaining = 0
    private var comparisonSelection = EQProgrammeComparisonSelection.equalized
    private var comparisonSelectionStartWeight: Float = 0
    private var comparisonSelectionWeight: Float = 0
    private var comparisonSelectionBlendedFrames = 0
    private var comparisonExitRequested = false
    private var comparisonExitGainStart: Float?
    private var comparisonExitGainBlendedFrames = 0
    private var programmeLoudnessMatcher: RealtimeProgrammeLoudnessMatcher

    public init(
        activeProcessor: EQProcessor,
        maximumFrameCount: Int,
        channelCount: Int,
        sampleRate: Double,
        warmupSeconds: Double = Self.defaultWarmupSeconds,
        blendSeconds: Double = Self.defaultBlendSeconds
    ) {
        let validSampleRate = sampleRate.isFinite && sampleRate > 0 ? sampleRate : 48_000
        let validWarmup = warmupSeconds.isFinite && warmupSeconds >= 0
            ? warmupSeconds
            : Self.defaultWarmupSeconds
        let validBlend = blendSeconds.isFinite && blendSeconds > 0
            ? blendSeconds
            : Self.defaultBlendSeconds
        self.activeProcessor = activeProcessor
        self.channelCount = max(channelCount, 1)
        self.alternateSamples = Array(
            repeating: 0,
            count: max(maximumFrameCount, 1) * max(channelCount, 1)
        )
        self.warmupFrameCount = max(Int((validSampleRate * validWarmup).rounded()), 0)
        self.blendFrameCount = max(Int((validSampleRate * validBlend).rounded()), 1)
        self.programmeLoudnessMatcher = RealtimeProgrammeLoudnessMatcher(
            sampleRate: validSampleRate,
            channelCount: self.channelCount
        )
    }

    public var isTransitioning: Bool {
        incomingProcessor != nil || pendingComparisonReferenceProcessor != nil
    }

    public var isProgrammeComparisonActive: Bool {
        pendingComparisonReferenceProcessor != nil || comparisonReferenceProcessor != nil
    }

    @discardableResult
    public mutating func beginTransition(to processor: EQProcessor) -> Bool {
        guard incomingProcessor == nil,
              processor.configuration.sampleRate == activeProcessor.configuration.sampleRate,
              processor.configuration.channelCount == activeProcessor.configuration.channelCount else {
            return false
        }
        incomingProcessor = processor
        if comparisonReferenceProcessor != nil {
            comparisonExitRequested = true
            setProgrammeComparisonSelection(.equalized)
        } else {
            beginStandardTransition()
        }
        return true
    }

    @discardableResult
    public mutating func beginProgrammeComparison(
        equalizedProcessor: EQProcessor,
        filtersOffProcessor: EQProcessor
    ) -> Bool {
        guard incomingProcessor == nil,
              comparisonReferenceProcessor == nil,
              pendingComparisonReferenceProcessor == nil,
              equalizedProcessor.configuration.sampleRate == activeProcessor.configuration.sampleRate,
              filtersOffProcessor.configuration.sampleRate == activeProcessor.configuration.sampleRate,
              equalizedProcessor.configuration.channelCount == activeProcessor.configuration.channelCount,
              filtersOffProcessor.configuration.channelCount == activeProcessor.configuration.channelCount else {
            return false
        }
        incomingProcessor = equalizedProcessor
        pendingComparisonReferenceProcessor = filtersOffProcessor
        beginStandardTransition()
        return true
    }

    public mutating func setProgrammeComparisonSelection(
        _ selection: EQProgrammeComparisonSelection
    ) {
        guard selection != comparisonSelection else {
            return
        }
        comparisonSelection = selection
        comparisonSelectionStartWeight = comparisonSelectionWeight
        comparisonSelectionBlendedFrames = 0
    }

    public var programmeComparisonSnapshot: EQProgrammeComparisonSnapshot {
        guard isProgrammeComparisonActive else {
            return EQProgrammeComparisonSnapshot()
        }
        let match = programmeLoudnessMatcher.snapshot
        return EQProgrammeComparisonSnapshot(
            isActive: isProgrammeComparisonActive,
            isReady: comparisonReferenceProcessor != nil
                && comparisonWarmupFramesRemaining == 0
                && match.isReady,
            selection: comparisonSelection,
            equalizedAttenuationDB: match.equalizedAttenuationDB,
            filtersOffAttenuationDB: match.filtersOffAttenuationDB
        )
    }

    public mutating func processInterleavedWithDiagnostics(
        _ samples: UnsafeMutableBufferPointer<Float>,
        frameCount: Int,
        channelCount: Int
    ) -> EQTransitionRenderResult {
        let channels = max(channelCount, 1)
        let availableFrames = min(max(frameCount, 0), samples.count / channels)
        guard availableFrames > 0 else {
            return EQTransitionRenderResult(programmeComparison: programmeComparisonSnapshot)
        }
        guard channels == self.channelCount,
              availableFrames * channels <= alternateSamples.count else {
            return processActiveProcessor(
                samples,
                frameCount: availableFrames,
                channelCount: channels
            )
        }

        if comparisonReferenceProcessor != nil {
            return processProgrammeComparison(
                samples,
                frameCount: availableFrames,
                channelCount: channels
            )
        }
        if incomingProcessor != nil {
            return processStandardTransition(
                samples,
                frameCount: availableFrames,
                channelCount: channels
            )
        }

        return processActiveProcessor(
            samples,
            frameCount: availableFrames,
            channelCount: channels
        )
    }

    private mutating func processActiveProcessor(
        _ samples: UnsafeMutableBufferPointer<Float>,
        frameCount: Int,
        channelCount: Int
    ) -> EQTransitionRenderResult {
        guard !activeProcessor.configuration.isBypassed else {
            return EQTransitionRenderResult(
                programmeComparison: programmeComparisonSnapshot
            )
        }
        guard activeProcessor.configuration.usesConvolution else {
            let saturated = activeProcessor.processInterleavedWithDiagnostics(
                samples,
                frameCount: frameCount,
                channelCount: channelCount
            )
            return EQTransitionRenderResult(
                saturatedSamples: saturated,
                programmeComparison: programmeComparisonSnapshot
            )
        }

        let diagnostics = activeProcessor.processInterleavedLinearlyWithDiagnostics(
            samples,
            frameCount: frameCount,
            channelCount: channelCount
        )
        return EQTransitionRenderResult(
            saturatedSamples: diagnostics.nonFiniteSamples
                &+ Self.protect(samples, frameCount: frameCount, channelCount: channelCount),
            programmeComparison: programmeComparisonSnapshot,
            workTiming: diagnostics.workTiming
        )
    }

    private mutating func processStandardTransition(
        _ samples: UnsafeMutableBufferPointer<Float>,
        frameCount: Int,
        channelCount: Int
    ) -> EQTransitionRenderResult {
        let sampleCount = frameCount * channelCount
        var result = alternateSamples.withUnsafeMutableBufferPointer { alternateStorage in
            let alternate = UnsafeMutableBufferPointer(
                start: alternateStorage.baseAddress,
                count: sampleCount
            )
            Self.copy(samples, into: alternate, sampleCount: sampleCount)

            let activeDiagnostics = activeProcessor.processInterleavedLinearlyWithDiagnostics(
                samples,
                frameCount: frameCount,
                channelCount: channelCount
            )
            let incomingDiagnostics = incomingProcessor!.processInterleavedLinearlyWithDiagnostics(
                alternate,
                frameCount: frameCount,
                channelCount: channelCount
            )
            var workTiming = activeDiagnostics.workTiming
            workTiming.merge(incomingDiagnostics.workTiming)

            if warmupFramesRemaining > 0 {
                warmupFramesRemaining = max(warmupFramesRemaining - frameCount, 0)
                return EQTransitionRenderResult(
                    saturatedSamples: activeDiagnostics.nonFiniteSamples
                        &+ incomingDiagnostics.nonFiniteSamples
                        &+ Self.protect(samples, frameCount: frameCount, channelCount: channelCount),
                    workTiming: workTiming
                )
            }

            let renderedBlendStartFrame = blendedFrames
            let blendWindow = EQTransitionRenderResult(
                blendStartFrame: renderedBlendStartFrame,
                blendFrameCount: blendFrameCount
            )
            var sampleIndex = 0
            for frame in 0..<frameCount {
                let incomingWeight = blendWindow.incomingBlendWeight(frameOffset: frame)
                for channel in 0..<channelCount {
                    let oldSample = samples[sampleIndex + channel]
                    samples[sampleIndex + channel] = oldSample
                        + (alternate[sampleIndex + channel] - oldSample) * incomingWeight
                }
                sampleIndex += channelCount
            }
            blendedFrames += frameCount
            let saturated = activeDiagnostics.nonFiniteSamples
                &+ incomingDiagnostics.nonFiniteSamples
                &+ Self.protect(samples, frameCount: frameCount, channelCount: channelCount)

            guard blendedFrames >= blendFrameCount,
                  let completedProcessor = incomingProcessor else {
                return EQTransitionRenderResult(
                    saturatedSamples: saturated,
                    blendStartFrame: renderedBlendStartFrame,
                    blendFrameCount: blendFrameCount,
                    workTiming: workTiming
                )
            }

            let retiredProcessor = activeProcessor
            activeProcessor = completedProcessor
            incomingProcessor = nil
            blendedFrames = 0
            if let referenceProcessor = pendingComparisonReferenceProcessor {
                pendingComparisonReferenceProcessor = nil
                comparisonReferenceProcessor = referenceProcessor
                comparisonWarmupFramesRemaining = warmupFrameCount
                comparisonSelection = .equalized
                comparisonSelectionStartWeight = 0
                comparisonSelectionWeight = 0
                comparisonSelectionBlendedFrames = blendFrameCount
                comparisonExitRequested = false
                comparisonExitGainStart = nil
                comparisonExitGainBlendedFrames = 0
                programmeLoudnessMatcher.reset()
            }
            let secondRetiredProcessor = retiredComparisonProcessor
            retiredComparisonProcessor = nil
            return EQTransitionRenderResult(
                saturatedSamples: saturated,
                completedTransition: true,
                retiredProcessor: retiredProcessor,
                secondRetiredProcessor: secondRetiredProcessor,
                blendStartFrame: renderedBlendStartFrame,
                blendFrameCount: blendFrameCount,
                workTiming: workTiming
            )
        }
        result.programmeComparison = programmeComparisonSnapshot
        return result
    }

    private mutating func processProgrammeComparison(
        _ samples: UnsafeMutableBufferPointer<Float>,
        frameCount: Int,
        channelCount: Int
    ) -> EQTransitionRenderResult {
        if let gainStart = comparisonExitGainStart {
            return processComparisonGainRestore(
                samples,
                frameCount: frameCount,
                channelCount: channelCount,
                gainStart: gainStart
            )
        }

        let sampleCount = frameCount * channelCount
        var shouldFinishComparison = false
        var result = alternateSamples.withUnsafeMutableBufferPointer { alternateStorage in
            let alternate = UnsafeMutableBufferPointer(
                start: alternateStorage.baseAddress,
                count: sampleCount
            )
            Self.copy(samples, into: alternate, sampleCount: sampleCount)
            let equalizedDiagnostics = activeProcessor.processInterleavedLinearlyWithDiagnostics(
                samples,
                frameCount: frameCount,
                channelCount: channelCount
            )
            let filtersOffDiagnostics = comparisonReferenceProcessor!
                .processInterleavedLinearlyWithDiagnostics(
                    alternate,
                    frameCount: frameCount,
                    channelCount: channelCount
                )
            var workTiming = equalizedDiagnostics.workTiming
            workTiming.merge(filtersOffDiagnostics.workTiming)

            if comparisonWarmupFramesRemaining > 0 {
                comparisonWarmupFramesRemaining = max(
                    comparisonWarmupFramesRemaining - frameCount,
                    0
                )
                if comparisonExitRequested {
                    shouldFinishComparison = true
                }
                return EQTransitionRenderResult(
                    saturatedSamples: equalizedDiagnostics.nonFiniteSamples
                        &+ filtersOffDiagnostics.nonFiniteSamples
                        &+ Self.protect(samples, frameCount: frameCount, channelCount: channelCount),
                    workTiming: workTiming
                )
            }

            let equalized = UnsafeBufferPointer(samples)
            let filtersOff = UnsafeBufferPointer(alternate)
            var sampleIndex = 0
            for _ in 0..<frameCount {
                let match = programmeLoudnessMatcher.observeFrame(
                    equalized: equalized,
                    filtersOff: filtersOff,
                    sampleOffset: sampleIndex,
                    channelCount: channelCount
                )
                let selectionTarget: Float = comparisonSelection == .filtersOff ? 1 : 0
                let filtersOffWeight: Float
                if comparisonSelectionBlendedFrames >= blendFrameCount {
                    comparisonSelectionWeight = selectionTarget
                    filtersOffWeight = selectionTarget
                } else {
                    let progress = blendFrameCount == 1
                        ? 1
                        : EQTransitionRenderResult.smoothstep(
                            Float(comparisonSelectionBlendedFrames)
                                / Float(blendFrameCount - 1)
                        )
                    comparisonSelectionWeight = comparisonSelectionStartWeight
                        + (selectionTarget - comparisonSelectionStartWeight) * progress
                    comparisonSelectionBlendedFrames += 1
                    if comparisonSelectionBlendedFrames >= blendFrameCount {
                        comparisonSelectionWeight = selectionTarget
                    }
                    filtersOffWeight = comparisonSelectionWeight
                }
                for channel in 0..<channelCount {
                    let equalizedSample = samples[sampleIndex + channel] * match.equalized
                    let filtersOffSample = alternate[sampleIndex + channel] * match.filtersOff
                    samples[sampleIndex + channel] = equalizedSample
                        + (filtersOffSample - equalizedSample) * filtersOffWeight
                }
                sampleIndex += channelCount
            }

            if comparisonExitRequested,
               comparisonSelection == .equalized,
               comparisonSelectionBlendedFrames >= blendFrameCount {
                let gain = programmeLoudnessMatcher.snapshot.equalizedGain
                if abs(gain - 1) < 0.000_001 {
                    shouldFinishComparison = true
                } else {
                    comparisonExitGainStart = gain
                    comparisonExitGainBlendedFrames = 0
                }
            }
            return EQTransitionRenderResult(
                saturatedSamples: equalizedDiagnostics.nonFiniteSamples
                    &+ filtersOffDiagnostics.nonFiniteSamples
                    &+ Self.protect(samples, frameCount: frameCount, channelCount: channelCount),
                workTiming: workTiming
            )
        }
        if shouldFinishComparison {
            finishProgrammeComparison()
        }
        result.programmeComparison = programmeComparisonSnapshot
        return result
    }

    private mutating func processComparisonGainRestore(
        _ samples: UnsafeMutableBufferPointer<Float>,
        frameCount: Int,
        channelCount: Int,
        gainStart: Float
    ) -> EQTransitionRenderResult {
        let diagnostics = activeProcessor.processInterleavedLinearlyWithDiagnostics(
            samples,
            frameCount: frameCount,
            channelCount: channelCount
        )
        var sampleIndex = 0
        for frame in 0..<frameCount {
            let transitionFrame = min(
                comparisonExitGainBlendedFrames + frame,
                blendFrameCount - 1
            )
            let progress = blendFrameCount == 1
                ? 1
                : EQTransitionRenderResult.smoothstep(
                    Float(transitionFrame) / Float(blendFrameCount - 1)
                )
            let gain = gainStart + (1 - gainStart) * progress
            for channel in 0..<channelCount {
                samples[sampleIndex + channel] *= gain
            }
            sampleIndex += channelCount
        }
        comparisonExitGainBlendedFrames += frameCount
        if comparisonExitGainBlendedFrames >= blendFrameCount {
            finishProgrammeComparison()
        }
        return EQTransitionRenderResult(
            saturatedSamples: diagnostics.nonFiniteSamples
                &+ Self.protect(samples, frameCount: frameCount, channelCount: channelCount),
            programmeComparison: programmeComparisonSnapshot,
            workTiming: diagnostics.workTiming
        )
    }

    private mutating func finishProgrammeComparison() {
        retiredComparisonProcessor = comparisonReferenceProcessor
        comparisonReferenceProcessor = nil
        comparisonWarmupFramesRemaining = 0
        comparisonExitRequested = false
        comparisonExitGainStart = nil
        comparisonExitGainBlendedFrames = 0
        comparisonSelection = .equalized
        comparisonSelectionStartWeight = 0
        comparisonSelectionWeight = 0
        comparisonSelectionBlendedFrames = blendFrameCount
        beginStandardTransition()
    }

    private mutating func beginStandardTransition() {
        warmupFramesRemaining = max(
            warmupFrameCount,
            incomingProcessor?.requiredWarmupFrames ?? 0
        )
        blendedFrames = 0
    }

    private static func copy(
        _ source: UnsafeMutableBufferPointer<Float>,
        into destination: UnsafeMutableBufferPointer<Float>,
        sampleCount: Int
    ) {
        for index in 0..<sampleCount {
            destination[index] = source[index]
        }
    }

    private static func protect(
        _ samples: UnsafeMutableBufferPointer<Float>,
        frameCount: Int,
        channelCount: Int
    ) -> UInt64 {
        EQProcessor.protectInterleavedWithDiagnostics(
            samples,
            frameCount: frameCount,
            channelCount: channelCount
        )
    }
}
