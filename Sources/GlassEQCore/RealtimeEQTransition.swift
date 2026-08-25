public struct EQTransitionRenderResult: Sendable {
    public var saturatedSamples: UInt64
    public var completedTransition: Bool
    public var retiredProcessor: EQProcessor?
    public var blendStartFrame: Int?
    public var blendFrameCount: Int

    public init(
        saturatedSamples: UInt64 = 0,
        completedTransition: Bool = false,
        retiredProcessor: EQProcessor? = nil,
        blendStartFrame: Int? = nil,
        blendFrameCount: Int = 0
    ) {
        self.saturatedSamples = saturatedSamples
        self.completedTransition = completedTransition
        self.retiredProcessor = retiredProcessor
        self.blendStartFrame = blendStartFrame
        self.blendFrameCount = blendFrameCount
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
        let linearProgress = Float(transitionFrame) / Float(blendFrameCount - 1)
        return linearProgress * linearProgress * (3 - 2 * linearProgress)
    }
}

public struct RealtimeEQTransition: Sendable {
    public static let defaultWarmupSeconds = 0.020
    public static let defaultBlendSeconds = 0.010

    private var activeProcessor: EQProcessor
    private var incomingProcessor: EQProcessor?
    private var alternateSamples: [Float]
    private let channelCount: Int
    private let warmupFrameCount: Int
    private let blendFrameCount: Int
    private var warmupFramesRemaining = 0
    private var blendedFrames = 0

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
    }

    public var isTransitioning: Bool {
        incomingProcessor != nil
    }

    public var activeConfiguration: EQConfiguration {
        activeProcessor.configuration
    }

    @discardableResult
    public mutating func beginTransition(to processor: EQProcessor) -> Bool {
        guard incomingProcessor == nil,
              processor.configuration.sampleRate == activeProcessor.configuration.sampleRate,
              processor.configuration.channelCount == activeProcessor.configuration.channelCount else {
            return false
        }
        incomingProcessor = processor
        warmupFramesRemaining = warmupFrameCount
        blendedFrames = 0
        return true
    }

    public mutating func processInterleavedWithDiagnostics(
        _ samples: UnsafeMutableBufferPointer<Float>,
        frameCount: Int,
        channelCount: Int
    ) -> EQTransitionRenderResult {
        let channels = max(channelCount, 1)
        let availableFrames = min(max(frameCount, 0), samples.count / channels)
        guard availableFrames > 0 else {
            return EQTransitionRenderResult()
        }
        guard channels == self.channelCount,
              incomingProcessor != nil,
              availableFrames * channels <= alternateSamples.count else {
            let saturated = activeProcessor.processInterleavedWithDiagnostics(
                samples,
                frameCount: availableFrames,
                channelCount: channels
            )
            return EQTransitionRenderResult(saturatedSamples: saturated)
        }

        let sampleCount = availableFrames * channels
        return alternateSamples.withUnsafeMutableBufferPointer { alternateStorage in
            let alternate = UnsafeMutableBufferPointer(
                start: alternateStorage.baseAddress,
                count: sampleCount
            )
            for index in 0..<sampleCount {
                alternate[index] = samples[index]
            }

            let activeDiagnostics = activeProcessor.processInterleavedLinearlyWithDiagnostics(
                samples,
                frameCount: availableFrames,
                channelCount: channels
            )
            let incomingDiagnostics = self.incomingProcessor!.processInterleavedLinearlyWithDiagnostics(
                alternate,
                frameCount: availableFrames,
                channelCount: channels
            )

            if warmupFramesRemaining > 0 {
                warmupFramesRemaining = max(warmupFramesRemaining - availableFrames, 0)
                let saturated = activeDiagnostics.nonFiniteSamples
                    &+ incomingDiagnostics.nonFiniteSamples
                    &+ EQProcessor.protectInterleavedWithDiagnostics(
                        samples,
                        frameCount: availableFrames,
                        channelCount: channels
                    )
                return EQTransitionRenderResult(saturatedSamples: saturated)
            }

            let renderedBlendStartFrame = blendedFrames
            let blendWindow = EQTransitionRenderResult(
                blendStartFrame: renderedBlendStartFrame,
                blendFrameCount: blendFrameCount
            )
            var sampleIndex = 0
            for frame in 0..<availableFrames {
                let incomingWeight = blendWindow.incomingBlendWeight(frameOffset: frame)
                for channel in 0..<channels {
                    let oldSample = samples[sampleIndex + channel]
                    samples[sampleIndex + channel] = oldSample
                        + (alternate[sampleIndex + channel] - oldSample) * incomingWeight
                }
                sampleIndex += channels
            }
            blendedFrames += availableFrames
            let saturated = activeDiagnostics.nonFiniteSamples
                &+ incomingDiagnostics.nonFiniteSamples
                &+ EQProcessor.protectInterleavedWithDiagnostics(
                    samples,
                    frameCount: availableFrames,
                    channelCount: channels
                )

            guard blendedFrames >= blendFrameCount,
                  let completedProcessor = self.incomingProcessor else {
                return EQTransitionRenderResult(
                    saturatedSamples: saturated,
                    blendStartFrame: renderedBlendStartFrame,
                    blendFrameCount: blendFrameCount
                )
            }
            let retiredProcessor = activeProcessor
            activeProcessor = completedProcessor
            self.incomingProcessor = nil
            blendedFrames = 0
            return EQTransitionRenderResult(
                saturatedSamples: saturated,
                completedTransition: true,
                retiredProcessor: retiredProcessor,
                blendStartFrame: renderedBlendStartFrame,
                blendFrameCount: blendFrameCount
            )
        }
    }
}
