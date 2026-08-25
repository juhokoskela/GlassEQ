import Foundation

public struct EQChannelConfiguration: Equatable, Sendable {
    public var preampLinearGain: Float
    public var coefficients: [BiquadCoefficients]

    public init(
        preampDB: Double,
        filters: [EQFilter],
        sampleRate: Double,
        maximumUsableFrequency: Double? = nil
    ) {
        self.preampLinearGain = Float(pow(10, preampDB / 20))
        self.coefficients = filters
            .filter(\.isEnabled)
            .map {
                BiquadCoefficients.make(
                    filter: $0,
                    sampleRate: sampleRate,
                    maximumUsableFrequency: maximumUsableFrequency
                )
            }
    }
}

public struct EQConfiguration: Equatable, Sendable {
    public var sampleRate: Double
    public var maximumUsableFrequency: Double
    public var channelCount: Int
    public var preampLinearGain: Float
    public var coefficients: [BiquadCoefficients]
    public var channelConfigurations: [EQChannelConfiguration]
    public var convolutionSources: [EQConvolutionSource?]
    public var usesConvolution: Bool
    public var isBypassed: Bool

    public init(
        profile: EQProfile,
        sampleRate: Double,
        channelCount: Int,
        maximumUsableFrequency: Double? = nil
    ) {
        self.sampleRate = sampleRate
        self.maximumUsableFrequency = min(
            EQRouteFrequencyPolicy.maximumUsableFrequency(sampleRate: sampleRate),
            maximumUsableFrequency ?? .greatestFiniteMagnitude
        )
        self.channelCount = max(channelCount, 1)
        let linkedConfiguration = EQChannelConfiguration(
            preampDB: profile.preampDB,
            filters: profile.filters,
            sampleRate: sampleRate,
            maximumUsableFrequency: self.maximumUsableFrequency
        )
        self.preampLinearGain = linkedConfiguration.preampLinearGain
        self.coefficients = linkedConfiguration.coefficients
        self.channelConfigurations = Self.makeChannelConfigurations(
            profile: profile,
            sampleRate: sampleRate,
            maximumUsableFrequency: self.maximumUsableFrequency,
            channelCount: self.channelCount,
            linkedConfiguration: linkedConfiguration
        )
        self.convolutionSources = Self.makeConvolutionSources(
            profile: profile,
            channelCount: self.channelCount
        )
        self.usesConvolution = profile.mode == .convolution
        self.isBypassed = profile.isBypassed
    }

    private static func makeChannelConfigurations(
        profile: EQProfile,
        sampleRate: Double,
        maximumUsableFrequency: Double,
        channelCount: Int,
        linkedConfiguration: EQChannelConfiguration
    ) -> [EQChannelConfiguration] {
        guard profile.channelMode == .stereo else {
            return Array(repeating: linkedConfiguration, count: channelCount)
        }

        let left = EQChannelConfiguration(
            preampDB: profile.leftPreampDB,
            filters: profile.leftFilters,
            sampleRate: sampleRate,
            maximumUsableFrequency: maximumUsableFrequency
        )
        let right = EQChannelConfiguration(
            preampDB: profile.rightPreampDB,
            filters: profile.rightFilters,
            sampleRate: sampleRate,
            maximumUsableFrequency: maximumUsableFrequency
        )

        return (0..<channelCount).map { channel in
            switch channel {
            case 0:
                left
            case 1:
                right
            default:
                linkedConfiguration
            }
        }
    }

    private static func makeConvolutionSources(
        profile: EQProfile,
        channelCount: Int
    ) -> [EQConvolutionSource?] {
        guard profile.mode == .convolution else {
            return Array(repeating: nil, count: channelCount)
        }
        guard profile.channelMode == .stereo else {
            return Array(repeating: profile.convolution, count: channelCount)
        }
        return (0..<channelCount).map { channel in
            switch channel {
            case 0:
                profile.leftConvolution
            case 1:
                profile.rightConvolution
            default:
                profile.convolution
            }
        }
    }
}

public struct EQRenderConfiguration: Sendable {
    public var configuration: EQConfiguration
    var coefficients: [RenderBiquadCoefficients]
    var channelStarts: [Int]
    var channelFilterCounts: [Int]
    var preampLinearGains: [Float]
    var convolvers: [RealtimeHybridConvolver?]
    private var preparationSucceeded: Bool

    public init(
        profile: EQProfile,
        sampleRate: Double,
        channelCount: Int,
        maximumUsableFrequency: Double? = nil
    ) {
        self.init(configuration: EQConfiguration(
            profile: profile,
            sampleRate: sampleRate,
            channelCount: channelCount,
            maximumUsableFrequency: maximumUsableFrequency
        ))
    }

    public init(configuration: EQConfiguration) {
        do {
            try self.init(preparing: configuration)
        } catch {
            self.init(unprepared: configuration)
        }
    }

    public static func prepare(
        profile: EQProfile,
        sampleRate: Double,
        channelCount: Int,
        maximumUsableFrequency: Double? = nil
    ) throws -> EQRenderConfiguration {
        try EQRenderConfiguration(preparing: EQConfiguration(
            profile: profile,
            sampleRate: sampleRate,
            channelCount: channelCount,
            maximumUsableFrequency: maximumUsableFrequency
        ))
    }

    private init(preparing configuration: EQConfiguration) throws {
        self.configuration = configuration
        let renderLayout = EQProcessor.makeRenderLayout(configuration: configuration)
        self.coefficients = renderLayout.coefficients
        self.channelStarts = renderLayout.channelStarts
        self.channelFilterCounts = renderLayout.channelFilterCounts
        self.preampLinearGains = renderLayout.preampLinearGains
        self.convolvers = try Self.makeConvolvers(configuration: configuration)
        self.preparationSucceeded = true
    }

    private init(unprepared configuration: EQConfiguration) {
        self.configuration = configuration
        let renderLayout = EQProcessor.makeRenderLayout(configuration: configuration)
        self.coefficients = renderLayout.coefficients
        self.channelStarts = renderLayout.channelStarts
        self.channelFilterCounts = renderLayout.channelFilterCounts
        self.preampLinearGains = renderLayout.preampLinearGains
        self.convolvers = Array(repeating: nil, count: configuration.channelCount)
        self.preparationSucceeded = !configuration.usesConvolution
    }

    public func hasRealtimeCompatibleTopology(with other: EQRenderConfiguration) -> Bool {
        configuration.sampleRate == other.configuration.sampleRate
            && configuration.channelCount == other.configuration.channelCount
            && configuration.usesConvolution == other.configuration.usesConvolution
            && channelFilterCounts == other.channelFilterCounts
    }

    public var isNumericallySafe: Bool {
        preparationSucceeded
            && configuration.sampleRate.isFinite
            && configuration.sampleRate > 0
            && configuration.channelCount > 0
            && preampLinearGains.allSatisfy { $0.isFinite && $0 >= 0 }
            && coefficients.allSatisfy(Self.isNumericallySafe)
            && (!configuration.usesConvolution
                || convolvers.count == configuration.channelCount
                    && convolvers.allSatisfy { $0 != nil })
    }

    private static func makeConvolvers(
        configuration: EQConfiguration
    ) throws -> [RealtimeHybridConvolver?] {
        guard configuration.usesConvolution else {
            return Array(repeating: nil, count: configuration.channelCount)
        }

        var preparedSources: [(source: EQConvolutionSource, kernel: PreparedConvolutionKernel)] = []
        return try configuration.convolutionSources.map { source in
            guard let source else {
                throw MinimumPhaseFIRCompilerError.insufficientPoints
            }
            let kernel: PreparedConvolutionKernel
            if let prepared = preparedSources.first(where: { $0.source == source }) {
                kernel = prepared.kernel
            } else {
                switch source {
                case .magnitudeCurve(let curve):
                    guard curve.synthesisVersion == MinimumPhaseFIRCompiler.synthesisVersion else {
                        throw MinimumPhaseFIRCompilerError.invalidPoint
                    }
                    kernel = try PreparedConvolutionKernel(
                        impulseResponse: MinimumPhaseFIRCompiler.compile(
                            points: curve.points,
                            sampleRate: configuration.sampleRate
                        )
                    )
                case .impulseResponse(let impulse):
                    guard abs(impulse.sampleRate - configuration.sampleRate) < 0.5 else {
                        throw HybridConvolverError.sampleRateMismatch(
                            source: impulse.sampleRate,
                            destination: configuration.sampleRate
                        )
                    }
                    kernel = try PreparedConvolutionKernel(
                        impulseResponse: impulse.samples
                    )
                }
                preparedSources.append((source, kernel))
            }
            return try RealtimeHybridConvolver(kernel: kernel)
        }
    }

    private static func isNumericallySafe(_ coefficients: RenderBiquadCoefficients) -> Bool {
        let values = [
            coefficients.b0,
            coefficients.b1,
            coefficients.b2,
            coefficients.a1,
            coefficients.a2
        ]
        guard values.allSatisfy(\.isFinite) else {
            return false
        }

        let a1 = Double(coefficients.a1)
        let a2 = Double(coefficients.a2)
        let discriminant = a1 * a1 - 4 * a2
        let maximumPoleMagnitude: Double
        if discriminant >= 0 {
            let root = sqrt(discriminant)
            maximumPoleMagnitude = max(
                abs((-a1 + root) / 2),
                abs((-a1 - root) / 2)
            )
        } else {
            maximumPoleMagnitude = sqrt(max(a2, 0))
        }
        return maximumPoleMagnitude <= 1.000_001
    }
}

public struct EQRenderWorkTiming: Equatable, Sendable {
    public var directHeadHostTicks: UInt64
    public var tailScheduledWorkHostTicks: UInt64
    public var tailCompletionObservations: UInt64
    public var minimumTailCompletionSlackFrames: Int
    public var tailDeadlineMisses: UInt64

    public init(
        directHeadHostTicks: UInt64 = 0,
        tailScheduledWorkHostTicks: UInt64 = 0,
        tailCompletionObservations: UInt64 = 0,
        minimumTailCompletionSlackFrames: Int = 0,
        tailDeadlineMisses: UInt64 = 0
    ) {
        self.directHeadHostTicks = directHeadHostTicks
        self.tailScheduledWorkHostTicks = tailScheduledWorkHostTicks
        self.tailCompletionObservations = tailCompletionObservations
        self.minimumTailCompletionSlackFrames = minimumTailCompletionSlackFrames
        self.tailDeadlineMisses = tailDeadlineMisses
    }

    mutating func merge(_ other: EQRenderWorkTiming) {
        directHeadHostTicks &+= other.directHeadHostTicks
        tailScheduledWorkHostTicks &+= other.tailScheduledWorkHostTicks
        tailDeadlineMisses &+= other.tailDeadlineMisses
        if other.tailCompletionObservations > 0 {
            if tailCompletionObservations == 0 {
                minimumTailCompletionSlackFrames = other.minimumTailCompletionSlackFrames
            } else {
                minimumTailCompletionSlackFrames = min(
                    minimumTailCompletionSlackFrames,
                    other.minimumTailCompletionSlackFrames
                )
            }
            tailCompletionObservations &+= other.tailCompletionObservations
        }
    }
}

struct EQLinearRenderDiagnostics: Equatable, Sendable {
    var nonFiniteSamples: UInt64
    var workTiming: EQRenderWorkTiming

    init(
        nonFiniteSamples: UInt64 = 0,
        workTiming: EQRenderWorkTiming = EQRenderWorkTiming()
    ) {
        self.nonFiniteSamples = nonFiniteSamples
        self.workTiming = workTiming
    }
}

public struct EQProcessor: Sendable {
    public private(set) var configuration: EQConfiguration
    private var coefficients: [RenderBiquadCoefficients]
    private var states: [BiquadState]
    private var channelStarts: [Int]
    private var channelFilterCounts: [Int]
    private var preampLinearGains: [Float]
    private var convolvers: [RealtimeHybridConvolver?]

    public var requiredWarmupFrames: Int {
        configuration.usesConvolution && !configuration.isBypassed
            ? PreparedConvolutionKernel.tapCount - 1
            : 0
    }

    public init(configuration: EQConfiguration) {
        self.init(renderConfiguration: EQRenderConfiguration(configuration: configuration))
    }

    public init(renderConfiguration: EQRenderConfiguration) {
        self.configuration = renderConfiguration.configuration
        self.coefficients = renderConfiguration.coefficients
        self.states = Array(repeating: BiquadState(), count: renderConfiguration.coefficients.count)
        self.channelStarts = renderConfiguration.channelStarts
        self.channelFilterCounts = renderConfiguration.channelFilterCounts
        self.preampLinearGains = renderConfiguration.preampLinearGains
        self.convolvers = renderConfiguration.convolvers
        resetConvolversForExclusiveRenderOwnership()
    }

    public mutating func update(configuration: EQConfiguration) {
        applyPreparedConfiguration(EQRenderConfiguration(configuration: configuration))
    }

    public mutating func applyPreparedConfiguration(_ renderConfiguration: EQRenderConfiguration) {
        let previousCoefficients = coefficients
        let needsStateReset = renderConfiguration.configuration.channelCount != self.configuration.channelCount
            || renderConfiguration.channelFilterCounts != channelFilterCounts
            || renderConfiguration.configuration.sampleRate != self.configuration.sampleRate

        self.configuration = renderConfiguration.configuration
        coefficients = renderConfiguration.coefficients
        channelStarts = renderConfiguration.channelStarts
        channelFilterCounts = renderConfiguration.channelFilterCounts
        preampLinearGains = renderConfiguration.preampLinearGains
        convolvers = renderConfiguration.convolvers
        resetConvolversForExclusiveRenderOwnership()

        if needsStateReset {
            states = Array(repeating: BiquadState(), count: renderConfiguration.coefficients.count)
        } else {
            resetChangedFilterStates(previousCoefficients: previousCoefficients, nextCoefficients: renderConfiguration.coefficients)
        }
    }

    private mutating func resetChangedFilterStates(
        previousCoefficients: [RenderBiquadCoefficients],
        nextCoefficients: [RenderBiquadCoefficients]
    ) {
        guard previousCoefficients.count == nextCoefficients.count,
              states.count == nextCoefficients.count else {
            states = Array(repeating: BiquadState(), count: nextCoefficients.count)
            return
        }

        for index in nextCoefficients.indices where previousCoefficients[index] != nextCoefficients[index] {
            states[index] = BiquadState()
        }
    }

    private mutating func resetConvolversForExclusiveRenderOwnership() {
        for index in convolvers.indices {
            convolvers[index]?.reset()
        }
    }

    public mutating func processInterleaved(_ samples: inout [Float], channelCount: Int) {
        guard !configuration.isBypassed else {
            return
        }

        let sourceChannelCount = max(channelCount, 1)
        let frameCount = samples.count / sourceChannelCount
        samples.withUnsafeMutableBufferPointer {
            _ = processInterleavedWithDiagnostics($0, frameCount: frameCount, channelCount: sourceChannelCount)
        }

        let remainingSampleStart = frameCount * sourceChannelCount
        if remainingSampleStart < samples.count {
            for channel in 0..<(samples.count - remainingSampleStart) {
                samples[remainingSampleStart + channel] = processSample(samples[remainingSampleStart + channel], channel: channel)
            }
        }
    }

    public mutating func processInterleavedWithDiagnostics(
        _ samples: UnsafeMutableBufferPointer<Float>,
        frameCount: Int,
        channelCount: Int
    ) -> UInt64 {
        guard !configuration.isBypassed else {
            return 0
        }

        let sourceChannelCount = max(channelCount, 1)
        let availableFrames = min(frameCount, samples.count / sourceChannelCount)
        guard availableFrames > 0 else {
            return 0
        }

        if configuration.usesConvolution {
            let diagnostics = processConvolutionInterleavedLinearly(
                samples,
                frameCount: availableFrames,
                channelCount: sourceChannelCount
            )
            return diagnostics.nonFiniteSamples &+ Self.protectInterleavedWithDiagnostics(
                samples,
                frameCount: availableFrames,
                channelCount: sourceChannelCount
            )
        }

        if sourceChannelCount == 2, channelStarts.count >= 2 {
            return withRenderBuffers { stateBuffer, coefficientBuffer, channelStartBuffer, channelFilterCountBuffer, preampLinearGainBuffer in
                Self.processStereoInterleaved(
                    samples,
                    frameCount: availableFrames,
                    states: stateBuffer,
                    coefficients: coefficientBuffer,
                    channelStarts: channelStartBuffer,
                    channelFilterCounts: channelFilterCountBuffer,
                    preampLinearGains: preampLinearGainBuffer
                )
            }
        }

        return withRenderBuffers { stateBuffer, coefficientBuffer, channelStartBuffer, channelFilterCountBuffer, preampLinearGainBuffer in
            var saturatedSamples: UInt64 = 0
            let channels = min(sourceChannelCount, channelStartBuffer.count)
            var sampleIndex = 0
            for _ in 0..<availableFrames {
                for channel in 0..<channels {
                    let processed = Self.processSampleWithDiagnosticsUnchecked(
                        samples[sampleIndex + channel],
                        channel: channel,
                        states: stateBuffer,
                        coefficients: coefficientBuffer,
                        channelStarts: channelStartBuffer,
                        channelFilterCounts: channelFilterCountBuffer,
                        preampLinearGains: preampLinearGainBuffer
                    )
                    samples[sampleIndex + channel] = processed.sample
                    if processed.saturated {
                        saturatedSamples += 1
                    }
                }
                sampleIndex += sourceChannelCount
            }
            return saturatedSamples
        }
    }

    mutating func processInterleavedLinearlyWithDiagnostics(
        _ samples: UnsafeMutableBufferPointer<Float>,
        frameCount: Int,
        channelCount: Int
    ) -> EQLinearRenderDiagnostics {
        let sourceChannelCount = max(channelCount, 1)
        let availableFrames = min(frameCount, samples.count / sourceChannelCount)
        guard availableFrames > 0 else {
            return EQLinearRenderDiagnostics()
        }

        if configuration.isBypassed {
            return Self.scanLinearSamples(
                UnsafeBufferPointer(samples),
                sampleCount: availableFrames * sourceChannelCount
            )
        }

        if configuration.usesConvolution {
            return processConvolutionInterleavedLinearly(
                samples,
                frameCount: availableFrames,
                channelCount: sourceChannelCount
            )
        }

        return withRenderBuffers { stateBuffer, coefficientBuffer, channelStartBuffer, channelFilterCountBuffer, preampLinearGainBuffer in
            var diagnostics = EQLinearRenderDiagnostics()
            let channels = min(sourceChannelCount, channelStartBuffer.count)
            var sampleIndex = 0
            for _ in 0..<availableFrames {
                for channel in 0..<channels {
                    let processed = Self.processLinearSampleWithDiagnosticsUnchecked(
                        samples[sampleIndex + channel],
                        channel: channel,
                        states: stateBuffer,
                        coefficients: coefficientBuffer,
                        channelStarts: channelStartBuffer,
                        channelFilterCounts: channelFilterCountBuffer,
                        preampLinearGains: preampLinearGainBuffer
                    )
                    samples[sampleIndex + channel] = processed.sample
                    if processed.encounteredNonFinite {
                        diagnostics.nonFiniteSamples += 1
                    }
                }
                sampleIndex += sourceChannelCount
            }
            return diagnostics
        }
    }

    static func protectInterleavedWithDiagnostics(
        _ samples: UnsafeMutableBufferPointer<Float>,
        frameCount: Int,
        channelCount: Int
    ) -> UInt64 {
        let channels = max(channelCount, 1)
        let sampleCount = min(max(frameCount, 0) * channels, samples.count)
        var saturatedSamples: UInt64 = 0
        for index in 0..<sampleCount {
            let protected = saturate(samples[index])
            samples[index] = protected.sample
            if protected.saturated {
                saturatedSamples += 1
            }
        }
        return saturatedSamples
    }

    public mutating func processNonInterleaved(_ channels: inout [[Float]]) {
        guard !configuration.isBypassed else {
            return
        }

        if configuration.usesConvolution {
            for channelIndex in channels.indices {
                for sampleIndex in channels[channelIndex].indices {
                    channels[channelIndex][sampleIndex] = processSample(
                        channels[channelIndex][sampleIndex],
                        channel: channelIndex
                    )
                }
            }
            return
        }

        withRenderBuffers { stateBuffer, coefficientBuffer, channelStartBuffer, channelFilterCountBuffer, preampLinearGainBuffer in
            for channelIndex in channels.indices {
                guard channelIndex < channelStartBuffer.count else {
                    continue
                }
                for sampleIndex in channels[channelIndex].indices {
                    channels[channelIndex][sampleIndex] = Self.processSampleWithDiagnosticsUnchecked(
                        channels[channelIndex][sampleIndex],
                        channel: channelIndex,
                        states: stateBuffer,
                        coefficients: coefficientBuffer,
                        channelStarts: channelStartBuffer,
                        channelFilterCounts: channelFilterCountBuffer,
                        preampLinearGains: preampLinearGainBuffer
                    ).sample
                }
            }
        }
    }

    public mutating func processSample(_ input: Float, channel: Int) -> Float {
        processSampleWithDiagnostics(input, channel: channel).sample
    }

    public mutating func processSampleWithDiagnostics(_ input: Float, channel: Int) -> (sample: Float, saturated: Bool) {
        guard !configuration.isBypassed else {
            return (input, false)
        }

        guard channel >= 0, channel < channelStarts.count else {
            return (input, false)
        }
        if configuration.usesConvolution {
            guard channel < convolvers.count,
                  convolvers[channel] != nil else {
                return (0, true)
            }
            let processed = convolvers[channel]!.processSample(
                input * preampLinearGains[channel]
            )
            let protected = Self.saturate(processed.sample)
            return (
                protected.sample,
                processed.encounteredNonFinite || protected.saturated
            )
        }
        return withRenderBuffers { stateBuffer, coefficientBuffer, channelStartBuffer, channelFilterCountBuffer, preampLinearGainBuffer in
            Self.processSampleWithDiagnosticsUnchecked(
                input,
                channel: channel,
                states: stateBuffer,
                coefficients: coefficientBuffer,
                channelStarts: channelStartBuffer,
                channelFilterCounts: channelFilterCountBuffer,
                preampLinearGains: preampLinearGainBuffer
            )
        }
    }

    private mutating func withRenderBuffers<Result>(
        _ body: (
            UnsafeMutableBufferPointer<BiquadState>,
            UnsafeBufferPointer<RenderBiquadCoefficients>,
            UnsafeBufferPointer<Int>,
            UnsafeBufferPointer<Int>,
            UnsafeBufferPointer<Float>
        ) -> Result
    ) -> Result {
        coefficients.withUnsafeBufferPointer { coefficientBuffer in
            channelStarts.withUnsafeBufferPointer { channelStartBuffer in
                channelFilterCounts.withUnsafeBufferPointer { channelFilterCountBuffer in
                    preampLinearGains.withUnsafeBufferPointer { preampLinearGainBuffer in
                        states.withUnsafeMutableBufferPointer { stateBuffer in
                            body(
                                stateBuffer,
                                coefficientBuffer,
                                channelStartBuffer,
                                channelFilterCountBuffer,
                                preampLinearGainBuffer
                            )
                        }
                    }
                }
            }
        }
    }

    private mutating func processConvolutionInterleavedLinearly(
        _ samples: UnsafeMutableBufferPointer<Float>,
        frameCount: Int,
        channelCount: Int
    ) -> EQLinearRenderDiagnostics {
        var diagnostics = EQLinearRenderDiagnostics()
        let channels = min(channelCount, convolvers.count)
        for channel in 0..<channels {
            guard convolvers[channel] != nil else {
                diagnostics.nonFiniteSamples += UInt64(frameCount)
                var sampleIndex = channel
                for _ in 0..<frameCount {
                    samples[sampleIndex] = 0
                    sampleIndex += channelCount
                }
                continue
            }
            let channelDiagnostics = convolvers[channel]!.processInterleavedChannel(
                samples,
                frameCount: frameCount,
                channel: channel,
                channelCount: channelCount,
                preampLinearGain: preampLinearGains[channel]
            )
            diagnostics.nonFiniteSamples &+= channelDiagnostics.nonFiniteSamples
            diagnostics.workTiming.merge(channelDiagnostics.workTiming)
        }
        return diagnostics
    }

    private static func processStereoInterleaved(
        _ samples: UnsafeMutableBufferPointer<Float>,
        frameCount: Int,
        states: UnsafeMutableBufferPointer<BiquadState>,
        coefficients: UnsafeBufferPointer<RenderBiquadCoefficients>,
        channelStarts: UnsafeBufferPointer<Int>,
        channelFilterCounts: UnsafeBufferPointer<Int>,
        preampLinearGains: UnsafeBufferPointer<Float>
    ) -> UInt64 {
        var saturatedSamples: UInt64 = 0
        var sampleIndex = 0
        for _ in 0..<frameCount {
            let left = processSampleWithDiagnosticsUnchecked(
                samples[sampleIndex],
                channel: 0,
                states: states,
                coefficients: coefficients,
                channelStarts: channelStarts,
                channelFilterCounts: channelFilterCounts,
                preampLinearGains: preampLinearGains
            )
            samples[sampleIndex] = left.sample
            if left.saturated {
                saturatedSamples += 1
            }

            let right = processSampleWithDiagnosticsUnchecked(
                samples[sampleIndex + 1],
                channel: 1,
                states: states,
                coefficients: coefficients,
                channelStarts: channelStarts,
                channelFilterCounts: channelFilterCounts,
                preampLinearGains: preampLinearGains
            )
            samples[sampleIndex + 1] = right.sample
            if right.saturated {
                saturatedSamples += 1
            }

            sampleIndex += 2
        }
        return saturatedSamples
    }

    private static func processSampleWithDiagnosticsUnchecked(
        _ input: Float,
        channel: Int,
        states: UnsafeMutableBufferPointer<BiquadState>,
        coefficients: UnsafeBufferPointer<RenderBiquadCoefficients>,
        channelStarts: UnsafeBufferPointer<Int>,
        channelFilterCounts: UnsafeBufferPointer<Int>,
        preampLinearGains: UnsafeBufferPointer<Float>
    ) -> (sample: Float, saturated: Bool) {
        guard channel >= 0, channel < channelStarts.count else {
            return (input, false)
        }
        let start = channelStarts[channel]
        let count = channelFilterCounts[channel]
        var value = input * preampLinearGains[channel]

        for filterOffset in 0..<count {
            let index = start + filterOffset
            value = states[index].process(value, coefficients: coefficients[index])
        }

        return Self.saturate(value)
    }

    private static func processLinearSampleWithDiagnosticsUnchecked(
        _ input: Float,
        channel: Int,
        states: UnsafeMutableBufferPointer<BiquadState>,
        coefficients: UnsafeBufferPointer<RenderBiquadCoefficients>,
        channelStarts: UnsafeBufferPointer<Int>,
        channelFilterCounts: UnsafeBufferPointer<Int>,
        preampLinearGains: UnsafeBufferPointer<Float>
    ) -> (sample: Float, encounteredNonFinite: Bool) {
        guard channel >= 0, channel < channelStarts.count else {
            return (input.isFinite ? input : 0, !input.isFinite)
        }
        let start = channelStarts[channel]
        let count = channelFilterCounts[channel]
        var value = input * preampLinearGains[channel]
        var encounteredNonFinite = !value.isFinite
        if encounteredNonFinite {
            value = 0
        }

        for filterOffset in 0..<count {
            let index = start + filterOffset
            let processed = states[index].processWithDiagnostics(
                value,
                coefficients: coefficients[index]
            )
            value = processed.sample
            encounteredNonFinite = encounteredNonFinite || processed.encounteredNonFinite
        }

        return (value, encounteredNonFinite)
    }

    private static func scanLinearSamples(
        _ samples: UnsafeBufferPointer<Float>,
        sampleCount: Int
    ) -> EQLinearRenderDiagnostics {
        var diagnostics = EQLinearRenderDiagnostics()
        for index in 0..<min(max(sampleCount, 0), samples.count) {
            let sample = samples[index]
            if !sample.isFinite {
                diagnostics.nonFiniteSamples += 1
            }
        }
        return diagnostics
    }

    private static func saturate(_ value: Float) -> (sample: Float, saturated: Bool) {
        guard value.isFinite else {
            return (0, true)
        }

        let threshold: Float = 0.98
        if value > threshold {
            return (
                threshold + (1 - threshold) * tanh((value - threshold) / (1 - threshold)),
                true
            )
        }
        if value < -threshold {
            return (
                -threshold + (1 - threshold) * tanh((value + threshold) / (1 - threshold)),
                true
            )
        }
        return (value, false)
    }

    static func makeRenderLayout(configuration: EQConfiguration) -> (
        coefficients: [RenderBiquadCoefficients],
        states: [BiquadState],
        channelStarts: [Int],
        channelFilterCounts: [Int],
        preampLinearGains: [Float]
    ) {
        var coefficients: [RenderBiquadCoefficients] = []
        var channelStarts: [Int] = []
        var channelFilterCounts: [Int] = []
        var preampLinearGains: [Float] = []

        for channelConfiguration in configuration.channelConfigurations {
            channelStarts.append(coefficients.count)
            channelFilterCounts.append(channelConfiguration.coefficients.count)
            preampLinearGains.append(channelConfiguration.preampLinearGain)
            coefficients.append(contentsOf: channelConfiguration.coefficients.map(RenderBiquadCoefficients.init))
        }

        return (
            coefficients: coefficients,
            states: Array(repeating: BiquadState(), count: coefficients.count),
            channelStarts: channelStarts,
            channelFilterCounts: channelFilterCounts,
            preampLinearGains: preampLinearGains
        )
    }
}
