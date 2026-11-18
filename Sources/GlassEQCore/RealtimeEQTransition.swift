/// Move the retired processor into off-thread reclamation before leaving the callback.
public struct EQTransitionRenderResult: ~Copyable, Sendable {
    public var saturatedSamples: UInt64
    public var completedTransition: Bool
    public var retiredProcessor: EQProcessor?
    public var blendStartFrame: Int?
    public var blendFrameCount: Int
    public var programmeComparison: EQProgrammeComparisonSnapshot
    public var workTiming: EQRenderWorkTiming

    public init(
        saturatedSamples: UInt64 = 0,
        completedTransition: Bool = false,
        retiredProcessor: consuming EQProcessor? = nil,
        blendStartFrame: Int? = nil,
        blendFrameCount: Int = 0,
        programmeComparison: EQProgrammeComparisonSnapshot = EQProgrammeComparisonSnapshot(),
        workTiming: EQRenderWorkTiming = EQRenderWorkTiming()
    ) {
        self.saturatedSamples = saturatedSamples
        self.completedTransition = completedTransition
        self.retiredProcessor = retiredProcessor
        self.blendStartFrame = blendStartFrame
        self.blendFrameCount = blendFrameCount
        self.programmeComparison = programmeComparison
        self.workTiming = workTiming
    }

    @inline(__always)
    public func incomingBlendWeight(frameOffset: Int) -> Float {
        guard let blendStartFrame,
            blendFrameCount > 0
        else {
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

public struct RealtimeEQTransition: ~Copyable, Sendable {
    public static let defaultWarmupSeconds = 0.020
    public static let defaultBlendSeconds = 0.010

    private var activeProcessor: EQProcessor
    private var incomingProcessor: EQProcessor?
    private enum ComparisonPhase {
        case inactive, entering, active
    }

    private var comparisonPhase = ComparisonPhase.inactive
    private var alternateSamples: [Float]
    private let channelCount: Int
    private let warmupFrameCount: Int
    private let blendFrameCount: Int
    private var warmupFramesRemaining = 0
    private var blendedFrames = 0
    private var comparisonSelection = EQProgrammeComparisonSelection.equalized
    private var comparisonSelectionStartWeight: Float = 0
    private var comparisonSelectionWeight: Float = 0
    private var comparisonSelectionBlendedFrames = 0
    private var comparisonExitRequested = false
    private var comparisonExitGainStart: Float?
    private var comparisonExitGainBlendedFrames = 0
    private var programmeLoudnessMatcher: RealtimeProgrammeLoudnessMatcher

    public init(
        activeProcessor: consuming EQProcessor,
        maximumFrameCount: Int,
        channelCount: Int,
        sampleRate: Double,
        warmupSeconds: Double = Self.defaultWarmupSeconds,
        blendSeconds: Double = Self.defaultBlendSeconds
    ) {
        let validSampleRate = sampleRate.isFinite && sampleRate > 0 ? sampleRate : 48_000
        let validWarmup =
            warmupSeconds.isFinite && warmupSeconds >= 0
            ? warmupSeconds
            : Self.defaultWarmupSeconds
        let validBlend =
            blendSeconds.isFinite && blendSeconds > 0
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
        incomingProcessor != nil
    }

    public var isProgrammeComparisonActive: Bool {
        comparisonPhase != .inactive
    }

    /// Takes the prepared processor only on success. A rejected candidate remains with the
    /// caller for retirement outside the render callback.
    @discardableResult
    public mutating func beginTransition(to processor: inout EQProcessor?) -> Bool {
        guard incomingProcessor == nil,
            processor?.configuration.sampleRate == activeProcessor.configuration.sampleRate,
            processor?.configuration.channelCount == activeProcessor.configuration.channelCount
        else {
            return false
        }
        swap(&incomingProcessor, &processor)
        if comparisonPhase == .active {
            comparisonExitRequested = true
            setProgrammeComparisonSelection(.equalized)
        } else {
            beginStandardTransition()
        }
        return true
    }

    /// Compares the draft with filters off at the same per-channel preamp.
    @discardableResult
    public mutating func beginProgrammeComparison(equalizedProcessor: inout EQProcessor?) -> Bool {
        guard comparisonPhase == .inactive,
            equalizedProcessor?.configuration.isBypassed == false,
            beginTransition(to: &equalizedProcessor)
        else {
            return false
        }
        comparisonPhase = .entering
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
        return EQProgrammeComparisonSnapshot(
            isActive: isProgrammeComparisonActive,
            isReady: comparisonPhase == .active
                && programmeLoudnessMatcher.isReady,
            selection: comparisonSelection
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
            availableFrames * channels <= alternateSamples.count
        else {
            return processActiveProcessor(
                samples,
                frameCount: availableFrames,
                channelCount: channels
            )
        }

        if comparisonPhase == .active {
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
        var result = EQTransitionRenderResult()
        alternateSamples.withUnsafeMutableBufferPointer { alternateStorage in
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

            let activeIsDry = activeProcessor.configuration.isBypassed
            let incomingIsDry = incomingProcessor?.configuration.isBypassed == true
            var saturated = activeDiagnostics.nonFiniteSamples &+ incomingDiagnostics.nonFiniteSamples
            if warmupFramesRemaining > 0 {
                warmupFramesRemaining = max(warmupFramesRemaining - frameCount, 0)
                if !activeIsDry {
                    saturated &+= Self.protect(samples, frameCount: frameCount, channelCount: channelCount)
                }
                result = EQTransitionRenderResult(
                    saturatedSamples: saturated,
                    workTiming: workTiming
                )
                return
            }

            // A bypass fade mixes transparent dry samples with the protected wet output.
            if incomingIsDry && !activeIsDry {
                saturated &+= Self.protect(samples, frameCount: frameCount, channelCount: channelCount)
            } else if activeIsDry && !incomingIsDry {
                saturated &+= Self.protect(alternate, frameCount: frameCount, channelCount: channelCount)
            }

            let renderedBlendStartFrame = blendedFrames
            let blendWindow = EQTransitionRenderResult(
                blendStartFrame: renderedBlendStartFrame,
                blendFrameCount: blendFrameCount
            )
            var sampleIndex = 0
            for frame in 0..<frameCount {
                let incomingWeight = blendWindow.incomingBlendWeight(frameOffset: frame)
                if incomingWeight == 1 {
                    for channel in 0..<channelCount {
                        samples[sampleIndex + channel] = alternate[sampleIndex + channel]
                    }
                } else if incomingWeight > 0 {
                    for channel in 0..<channelCount {
                        let oldSample = samples[sampleIndex + channel]
                        samples[sampleIndex + channel] =
                            oldSample + (alternate[sampleIndex + channel] - oldSample) * incomingWeight
                    }
                }
                sampleIndex += channelCount
            }
            blendedFrames += frameCount
            if !activeIsDry && !incomingIsDry {
                saturated &+= Self.protect(samples, frameCount: frameCount, channelCount: channelCount)
            }

            guard blendedFrames >= blendFrameCount,
                incomingProcessor != nil
            else {
                result = EQTransitionRenderResult(
                    saturatedSamples: saturated,
                    blendStartFrame: renderedBlendStartFrame,
                    blendFrameCount: blendFrameCount,
                    workTiming: workTiming
                )
                return
            }

            var retiredProcessor = incomingProcessor.take()!
            swap(&activeProcessor, &retiredProcessor)
            blendedFrames = 0
            if comparisonPhase == .entering {
                comparisonPhase = .active
                comparisonSelection = .equalized
                comparisonSelectionStartWeight = 0
                comparisonSelectionWeight = 0
                comparisonSelectionBlendedFrames = blendFrameCount
                comparisonExitRequested = false
                comparisonExitGainStart = nil
                comparisonExitGainBlendedFrames = 0
                programmeLoudnessMatcher.reset()
            }
            result = EQTransitionRenderResult(
                saturatedSamples: saturated,
                completedTransition: true,
                retiredProcessor: retiredProcessor,
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
        var result = EQTransitionRenderResult()
        alternateSamples.withUnsafeMutableBufferPointer { alternateStorage in
            let alternate = UnsafeMutableBufferPointer(
                start: alternateStorage.baseAddress,
                count: sampleCount
            )
            let referenceNonFinite = activeProcessor.writeFiltersOffReference(
                from: UnsafeBufferPointer(samples), into: alternate, frameCount: frameCount, channelCount: channelCount
            )
            let equalizedDiagnostics = activeProcessor.processInterleavedLinearlyWithDiagnostics(
                samples,
                frameCount: frameCount,
                channelCount: channelCount
            )
            let equalized = UnsafeBufferPointer(samples)
            let reference = UnsafeBufferPointer(alternate)
            var sampleIndex = 0
            for _ in 0..<frameCount {
                let match = programmeLoudnessMatcher.observeFrame(
                    equalized: equalized,
                    reference: reference,
                    sampleOffset: sampleIndex,
                    channelCount: channelCount
                )
                let selectionTarget: Float = comparisonSelection == .reference ? 1 : 0
                let referenceWeight: Float
                if comparisonSelectionBlendedFrames >= blendFrameCount {
                    comparisonSelectionWeight = selectionTarget
                    referenceWeight = selectionTarget
                } else {
                    let progress =
                        blendFrameCount == 1
                        ? 1
                        : EQTransitionRenderResult.smoothstep(
                            Float(comparisonSelectionBlendedFrames)
                                / Float(blendFrameCount - 1)
                        )
                    comparisonSelectionWeight =
                        comparisonSelectionStartWeight
                        + (selectionTarget - comparisonSelectionStartWeight) * progress
                    comparisonSelectionBlendedFrames += 1
                    if comparisonSelectionBlendedFrames >= blendFrameCount {
                        comparisonSelectionWeight = selectionTarget
                    }
                    referenceWeight = comparisonSelectionWeight
                }
                for channel in 0..<channelCount {
                    let equalizedSample = samples[sampleIndex + channel] * match.equalized
                    let referenceSample = alternate[sampleIndex + channel] * match.reference
                    samples[sampleIndex + channel] =
                        equalizedSample
                        + (referenceSample - equalizedSample) * referenceWeight
                }
                sampleIndex += channelCount
            }

            if comparisonExitRequested,
                comparisonSelection == .equalized,
                comparisonSelectionBlendedFrames >= blendFrameCount
            {
                let gain = programmeLoudnessMatcher.gains.equalized
                if abs(gain - 1) < 0.000_001 {
                    shouldFinishComparison = true
                } else {
                    comparisonExitGainStart = gain
                    comparisonExitGainBlendedFrames = 0
                }
            }
            result = EQTransitionRenderResult(
                saturatedSamples: equalizedDiagnostics.nonFiniteSamples
                    &+ referenceNonFinite
                    &+ Self.protect(samples, frameCount: frameCount, channelCount: channelCount),
                workTiming: equalizedDiagnostics.workTiming
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
            let progress =
                blendFrameCount == 1
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
        comparisonPhase = .inactive
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
