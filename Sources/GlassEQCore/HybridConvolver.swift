import Accelerate
import Darwin

enum HybridConvolverError: Error, Equatable, Sendable {
    case invalidImpulseResponse
    case sampleRateMismatch(source: Double, destination: Double)
    case transformSetupFailed
}

struct PreparedConvolutionKernel: Sendable {
    static let tapCount = 16_384
    static let directTapCount = 512
    static let tailPartitionFrames = 256
    static let transformFrames = tailPartitionFrames * 2
    static let packedBinCount = transformFrames / 2
    static let tailPartitionCount = (tapCount - directTapCount) / tailPartitionFrames

    let directCoefficientsReversed: [Float]
    let tailSpectrumReal: [Float]
    let tailSpectrumImaginary: [Float]
    fileprivate let transform: RealFloatDFTSetup

    init(impulseResponse: [Float]) throws {
        guard !impulseResponse.isEmpty,
            impulseResponse.count <= Self.tapCount,
            impulseResponse.allSatisfy(\.isFinite)
        else {
            throw HybridConvolverError.invalidImpulseResponse
        }

        var padded = [Float](repeating: 0, count: Self.tapCount)
        padded.replaceSubrange(0..<impulseResponse.count, with: impulseResponse)
        self.directCoefficientsReversed = Array(
            padded[0..<Self.directTapCount].reversed()
        )

        let setup = try RealFloatDFTSetup()
        self.transform = setup
        var spectrumReal = [Float](
            repeating: 0,
            count: Self.tailPartitionCount * Self.packedBinCount
        )
        var spectrumImaginary = spectrumReal
        var inputEven = [Float](repeating: 0, count: Self.packedBinCount)
        var inputOdd = inputEven
        var outputReal = inputEven
        var outputImaginary = inputEven

        for partition in 0..<Self.tailPartitionCount {
            inputEven.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
            inputOdd.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
            let sourceStart = Self.directTapCount + partition * Self.tailPartitionFrames
            for pair in 0..<(Self.tailPartitionFrames / 2) {
                inputEven[pair] = padded[sourceStart + pair * 2]
                inputOdd[pair] = padded[sourceStart + pair * 2 + 1]
            }
            inputEven.withUnsafeBufferPointer { even in
                inputOdd.withUnsafeBufferPointer { odd in
                    outputReal.withUnsafeMutableBufferPointer { real in
                        outputImaginary.withUnsafeMutableBufferPointer { imaginary in
                            setup.forward(even: even, odd: odd, outputReal: real, outputImaginary: imaginary)
                        }
                    }
                }
            }
            let destinationStart = partition * Self.packedBinCount
            for bin in 0..<Self.packedBinCount {
                spectrumReal[destinationStart + bin] = outputReal[bin] * 0.5
                spectrumImaginary[destinationStart + bin] = outputImaginary[bin] * 0.5
            }
        }

        self.tailSpectrumReal = spectrumReal
        self.tailSpectrumImaginary = spectrumImaginary
    }
}

struct RealtimeHybridConvolver: ~Copyable, Sendable {
    private static let outputRingFrames = 1_024
    private static let outputRingMask = outputRingFrames - 1
    private static let inverseGuardFrames = 16
    private static let partitionWorkFrames =
        PreparedConvolutionKernel.tailPartitionFrames
        - inverseGuardFrames

    private let kernel: PreparedConvolutionKernel
    private var scratch = ConvolutionScratch()
    private var directHistory: InlineArray<1024, Float> = .init(repeating: 0)
    private var directWriteIndex = 0
    private var tailInputBlock: InlineArray<256, Float> = .init(repeating: 0)
    private var tailInputCount = 0
    private var inputSpectrumWriteIndex = -1
    private var tailOverlap: InlineArray<256, Float> = .init(repeating: 0)
    private var tailOutputRing: InlineArray<1024, Float> = .init(repeating: 0)
    private var jobActive = false
    private var jobInputSpectrumIndex = 0
    private var jobNextPartition = 0
    private var jobWorkNumerator = 0
    private var jobDueFrame: Int64 = 0
    private var absoluteFrame: Int64 = 0

    init(kernel: PreparedConvolutionKernel, prewarm: Bool = true) {
        self.kernel = kernel
        precondition(directHistory.count == PreparedConvolutionKernel.directTapCount * 2)
        precondition(tailInputBlock.count == PreparedConvolutionKernel.tailPartitionFrames)
        precondition(tailOverlap.count == PreparedConvolutionKernel.tailPartitionFrames)
        precondition(tailOutputRing.count == Self.outputRingFrames)
        if prewarm {
            prewarmAndReset()
        }
    }

    mutating func processSample(_ rawInput: Float) -> (
        sample: Float,
        encounteredNonFinite: Bool
    ) {
        let encounteredNonFinite = !rawInput.isFinite
        let input = encounteredNonFinite ? 0 : rawInput
        let outputRingIndex = Int(absoluteFrame) & Self.outputRingMask
        let tailOutput = tailOutputRing[outputRingIndex]
        tailOutputRing[outputRingIndex] = 0

        directHistory[directWriteIndex] = input
        directHistory[directWriteIndex + PreparedConvolutionKernel.directTapCount] = input
        let historyStart = directWriteIndex + 1
        var directOutput: Float = 0
        kernel.directCoefficientsReversed.withUnsafeBufferPointer { coefficients in
            directHistory.span.withUnsafeBufferPointer { history in
                vDSP_dotpr(
                    coefficients.baseAddress!,
                    1,
                    history.baseAddress! + historyStart,
                    1,
                    &directOutput,
                    vDSP_Length(PreparedConvolutionKernel.directTapCount)
                )
            }
        }
        directWriteIndex =
            (directWriteIndex + 1)
            & (PreparedConvolutionKernel.directTapCount - 1)

        tailInputBlock[tailInputCount] = input
        tailInputCount += 1
        let completedInputBlock =
            tailInputCount
            == PreparedConvolutionKernel.tailPartitionFrames

        advanceTailJobByOneFrame()
        absoluteFrame += 1
        if completedInputBlock {
            beginTailJob()
        }

        let output = directOutput + tailOutput
        return (output.isFinite ? output : 0, encounteredNonFinite || !output.isFinite)
    }

    mutating func processInterleavedChannel(
        _ samples: UnsafeMutableBufferPointer<Float>,
        frameCount: Int,
        channel: Int,
        channelCount: Int,
        preampLinearGain: Float
    ) -> EQLinearRenderDiagnostics {
        guard channel >= 0,
            channel < channelCount,
            frameCount > 0
        else {
            return EQLinearRenderDiagnostics()
        }

        var diagnostics = EQLinearRenderDiagnostics()
        var renderedFrames = 0
        while renderedFrames < frameCount {
            let segmentFrames = min(
                frameCount - renderedFrames,
                PreparedConvolutionKernel.tailPartitionFrames - tailInputCount
            )

            let tailAdvanceStart = mach_absolute_time()
            let tailAdvance = advanceTailJob(frameCount: segmentFrames)
            let directHeadStart = mach_absolute_time()
            if tailAdvance.didWork {
                diagnostics.workTiming.tailScheduledWorkHostTicks &+=
                    directHeadStart &- tailAdvanceStart
            }
            diagnostics.workTiming.mergeTailCompletion(tailAdvance.completion)

            var sampleIndex = channel + renderedFrames * channelCount
            for _ in 0..<segmentFrames {
                let rawInput = samples[sampleIndex] * preampLinearGain
                let encounteredNonFinite = !rawInput.isFinite
                let input = encounteredNonFinite ? 0 : rawInput
                let outputRingIndex = Int(absoluteFrame) & Self.outputRingMask
                let tailOutput = tailOutputRing[outputRingIndex]
                tailOutputRing[outputRingIndex] = 0

                directHistory[directWriteIndex] = input
                directHistory[directWriteIndex + PreparedConvolutionKernel.directTapCount] = input
                let historyStart = directWriteIndex + 1
                var directOutput: Float = 0
                kernel.directCoefficientsReversed.withUnsafeBufferPointer { coefficients in
                    directHistory.span.withUnsafeBufferPointer { history in
                        vDSP_dotpr(
                            coefficients.baseAddress!,
                            1,
                            history.baseAddress! + historyStart,
                            1,
                            &directOutput,
                            vDSP_Length(PreparedConvolutionKernel.directTapCount)
                        )
                    }
                }
                directWriteIndex =
                    (directWriteIndex + 1)
                    & (PreparedConvolutionKernel.directTapCount - 1)

                tailInputBlock[tailInputCount] = input
                tailInputCount += 1
                absoluteFrame += 1

                let output = directOutput + tailOutput
                samples[sampleIndex] = output.isFinite ? output : 0
                if encounteredNonFinite || !output.isFinite {
                    diagnostics.nonFiniteSamples += 1
                }
                sampleIndex += channelCount
            }
            let directHeadEnd = mach_absolute_time()
            diagnostics.workTiming.directHeadHostTicks &+= directHeadEnd &- directHeadStart

            if tailInputCount == PreparedConvolutionKernel.tailPartitionFrames {
                let tailBeginStart = mach_absolute_time()
                beginTailJob()
                diagnostics.workTiming.tailScheduledWorkHostTicks &+=
                    mach_absolute_time() &- tailBeginStart
            }
            renderedFrames += segmentFrames
        }
        return diagnostics
    }

    mutating func reset() {
        scratch.reset()
        directHistory = .init(repeating: 0)
        directWriteIndex = 0
        tailInputBlock = .init(repeating: 0)
        tailInputCount = 0
        inputSpectrumWriteIndex = -1
        tailOverlap = .init(repeating: 0)
        tailOutputRing = .init(repeating: 0)
        jobActive = false
        jobInputSpectrumIndex = 0
        jobNextPartition = 0
        jobWorkNumerator = 0
        jobDueFrame = 0
        absoluteFrame = 0
    }

    private mutating func prewarmAndReset() {
        for _ in 0..<(PreparedConvolutionKernel.tailPartitionFrames * 3) {
            _ = processSample(0)
        }
        reset()
    }

    private mutating func advanceTailJobByOneFrame() {
        _ = advanceTailJob(frameCount: 1)
    }

    private mutating func advanceTailJob(
        frameCount: Int
    ) -> TailAdvanceResult {
        guard jobActive else {
            return TailAdvanceResult()
        }

        jobWorkNumerator += PreparedConvolutionKernel.tailPartitionCount * frameCount
        var didWork = false
        while jobWorkNumerator >= Self.partitionWorkFrames,
            jobNextPartition < PreparedConvolutionKernel.tailPartitionCount
        {
            jobWorkNumerator -= Self.partitionWorkFrames
            accumulateTailPartition(jobNextPartition)
            jobNextPartition += 1
            didWork = true
        }

        if jobNextPartition == PreparedConvolutionKernel.tailPartitionCount {
            finishTailJob()
            let completionFrame = absoluteFrame + Int64(frameCount)
            let slackFrames = jobDueFrame - completionFrame
            return TailAdvanceResult(
                didWork: true,
                completion: TailCompletion(
                    slackFrames: max(Int(slackFrames), 0),
                    missedDeadline: slackFrames < 0
                )
            )
        }
        return TailAdvanceResult(didWork: didWork)
    }

    private mutating func beginTailJob() {
        precondition(!jobActive)
        for pair in 0..<(PreparedConvolutionKernel.tailPartitionFrames / 2) {
            scratch.fftInputEven[pair] = tailInputBlock[pair * 2]
            scratch.fftInputOdd[pair] = tailInputBlock[pair * 2 + 1]
        }
        let zeroPairStart = PreparedConvolutionKernel.tailPartitionFrames / 2
        for pair in zeroPairStart..<PreparedConvolutionKernel.packedBinCount {
            scratch.fftInputEven[pair] = 0
            scratch.fftInputOdd[pair] = 0
        }
        tailInputCount = 0

        kernel.transform.forward(
            even: UnsafeBufferPointer(scratch.fftInputEven),
            odd: UnsafeBufferPointer(scratch.fftInputOdd),
            outputReal: scratch.fftOutputReal,
            outputImaginary: scratch.fftOutputImaginary
        )
        inputSpectrumWriteIndex =
            (inputSpectrumWriteIndex + 1)
            % PreparedConvolutionKernel.tailPartitionCount
        let destinationStart =
            inputSpectrumWriteIndex
            * PreparedConvolutionKernel.packedBinCount
        for bin in 0..<PreparedConvolutionKernel.packedBinCount {
            scratch.inputSpectrumReal[destinationStart + bin] = scratch.fftOutputReal[bin] * 0.5
            scratch.inputSpectrumImaginary[destinationStart + bin] = scratch.fftOutputImaginary[bin] * 0.5
        }

        scratch.accumulatorReal.update(repeating: 0)
        scratch.accumulatorImaginary.update(repeating: 0)
        jobActive = true
        jobInputSpectrumIndex = inputSpectrumWriteIndex
        jobNextPartition = 0
        jobWorkNumerator = 0
        jobDueFrame = absoluteFrame + Int64(PreparedConvolutionKernel.tailPartitionFrames)
    }

    private mutating func accumulateTailPartition(_ partition: Int) {
        let partitionCount = PreparedConvolutionKernel.tailPartitionCount
        let spectrumIndex = (jobInputSpectrumIndex - partition + partitionCount) % partitionCount
        let inputStart = spectrumIndex * PreparedConvolutionKernel.packedBinCount
        let kernelStart = partition * PreparedConvolutionKernel.packedBinCount

        scratch.accumulatorReal[0] +=
            scratch.inputSpectrumReal[inputStart]
            * kernel.tailSpectrumReal[kernelStart]
        scratch.accumulatorImaginary[0] +=
            scratch.inputSpectrumImaginary[inputStart]
            * kernel.tailSpectrumImaginary[kernelStart]
        kernel.tailSpectrumReal.withUnsafeBufferPointer { kernelReal in
            kernel.tailSpectrumImaginary.withUnsafeBufferPointer { kernelImaginary in
                var input = DSPSplitComplex(
                    realp: scratch.inputSpectrumReal.baseAddress! + inputStart + 1,
                    imagp: scratch.inputSpectrumImaginary.baseAddress! + inputStart + 1
                )
                var coefficients = DSPSplitComplex(
                    realp: .init(mutating: kernelReal.baseAddress! + kernelStart + 1),
                    imagp: .init(mutating: kernelImaginary.baseAddress! + kernelStart + 1)
                )
                var accumulator = DSPSplitComplex(
                    realp: scratch.accumulatorReal.baseAddress! + 1,
                    imagp: scratch.accumulatorImaginary.baseAddress! + 1
                )
                vDSP_zvma(
                    &input, 1, &coefficients, 1, &accumulator, 1, &accumulator, 1,
                    vDSP_Length(PreparedConvolutionKernel.packedBinCount - 1)
                )
            }
        }
    }

    private mutating func finishTailJob() {
        kernel.transform.inverse(
            real: UnsafeBufferPointer(scratch.accumulatorReal),
            imaginary: UnsafeBufferPointer(scratch.accumulatorImaginary),
            outputEven: scratch.inverseOutputEven,
            outputOdd: scratch.inverseOutputOdd
        )
        let scale = 1 / Float(PreparedConvolutionKernel.transformFrames)
        for frame in 0..<PreparedConvolutionKernel.tailPartitionFrames {
            let firstHalfSample = unpackedInverseSample(frame) * scale
            let secondHalfSample =
                unpackedInverseSample(
                    frame + PreparedConvolutionKernel.tailPartitionFrames
                ) * scale
            let outputIndex = Int(jobDueFrame + Int64(frame)) & Self.outputRingMask
            tailOutputRing[outputIndex] = firstHalfSample + tailOverlap[frame]
            tailOverlap[frame] = secondHalfSample
        }
        jobActive = false
        jobWorkNumerator = 0
    }

    private func unpackedInverseSample(_ frame: Int) -> Float {
        let pair = frame / 2
        return frame.isMultiple(of: 2)
            ? scratch.inverseOutputEven[pair]
            : scratch.inverseOutputOdd[pair]
    }
}

private struct TailAdvanceResult {
    var didWork = false
    var completion: TailCompletion?
}

private struct TailCompletion {
    var slackFrames: Int
    var missedDeadline: Bool
}

private extension EQRenderWorkTiming {
    mutating func mergeTailCompletion(_ completion: TailCompletion?) {
        guard let completion else {
            return
        }
        if tailCompletionObservations == 0 {
            minimumTailCompletionSlackFrames = completion.slackFrames
        } else {
            minimumTailCompletionSlackFrames = min(
                minimumTailCompletionSlackFrames,
                completion.slackFrames
            )
        }
        tailCompletionObservations &+= 1
        if completion.missedDeadline {
            tailDeadlineMisses &+= 1
        }
    }
}

// Accelerate permits concurrent execution of shared setups, but not creation or destruction
// while any sharing setup executes. Both setups are created before publication and stay owned
// together through each call. Their owner must be reclaimed outside the render callback.
private final class RealFloatDFTSetup: @unchecked Sendable {
    private let forwardSetup: vDSP_DFT_Setup
    private let inverseSetup: vDSP_DFT_Setup

    init() throws {
        let length = vDSP_Length(PreparedConvolutionKernel.transformFrames)
        guard let forwardSetup = vDSP_DFT_zrop_CreateSetup(nil, length, .FORWARD) else {
            throw HybridConvolverError.transformSetupFailed
        }
        guard
            let inverseSetup = vDSP_DFT_zrop_CreateSetup(
                forwardSetup,
                length,
                .INVERSE
            )
        else {
            vDSP_DFT_DestroySetup(forwardSetup)
            throw HybridConvolverError.transformSetupFailed
        }
        self.forwardSetup = forwardSetup
        self.inverseSetup = inverseSetup
    }

    deinit {
        vDSP_DFT_DestroySetup(forwardSetup)
        vDSP_DFT_DestroySetup(inverseSetup)
    }

    func forward(
        even: UnsafeBufferPointer<Float>,
        odd: UnsafeBufferPointer<Float>,
        outputReal: UnsafeMutableBufferPointer<Float>,
        outputImaginary: UnsafeMutableBufferPointer<Float>
    ) {
        vDSP_DFT_Execute(
            forwardSetup, even.baseAddress!, odd.baseAddress!,
            outputReal.baseAddress!, outputImaginary.baseAddress!
        )
    }

    func inverse(
        real: UnsafeBufferPointer<Float>,
        imaginary: UnsafeBufferPointer<Float>,
        outputEven: UnsafeMutableBufferPointer<Float>,
        outputOdd: UnsafeMutableBufferPointer<Float>
    ) {
        vDSP_DFT_Execute(
            inverseSetup, real.baseAddress!, imaginary.baseAddress!,
            outputEven.baseAddress!, outputOdd.baseAddress!
        )
    }
}

// The noncopyable convolver exclusively owns this allocation. Region views stay within its
// mutating render methods; neither the pointers nor their storage are shared with another bank.
private struct ConvolutionScratch: ~Copyable, @unchecked Sendable {
    private let storage: UnsafeMutableBufferPointer<Float>
    let fftInputEven: UnsafeMutableBufferPointer<Float>
    let fftInputOdd: UnsafeMutableBufferPointer<Float>
    let fftOutputReal: UnsafeMutableBufferPointer<Float>
    let fftOutputImaginary: UnsafeMutableBufferPointer<Float>
    let inputSpectrumReal: UnsafeMutableBufferPointer<Float>
    let inputSpectrumImaginary: UnsafeMutableBufferPointer<Float>
    let accumulatorReal: UnsafeMutableBufferPointer<Float>
    let accumulatorImaginary: UnsafeMutableBufferPointer<Float>
    let inverseOutputEven: UnsafeMutableBufferPointer<Float>
    let inverseOutputOdd: UnsafeMutableBufferPointer<Float>

    init() {
        let bins = PreparedConvolutionKernel.packedBinCount
        let spectrumBins = PreparedConvolutionKernel.tailPartitionCount * bins
        let storage = UnsafeMutableBufferPointer<Float>.allocate(capacity: 8 * bins + 2 * spectrumBins)
        storage.initialize(repeating: 0)
        var offset = 0
        func region(count: Int) -> UnsafeMutableBufferPointer<Float> {
            defer { offset += count }
            return UnsafeMutableBufferPointer(rebasing: storage[offset..<(offset + count)])
        }
        self.storage = storage
        self.fftInputEven = region(count: bins)
        self.fftInputOdd = region(count: bins)
        self.fftOutputReal = region(count: bins)
        self.fftOutputImaginary = region(count: bins)
        self.inputSpectrumReal = region(count: spectrumBins)
        self.inputSpectrumImaginary = region(count: spectrumBins)
        self.accumulatorReal = region(count: bins)
        self.accumulatorImaginary = region(count: bins)
        self.inverseOutputEven = region(count: bins)
        self.inverseOutputOdd = region(count: bins)
        precondition(offset == storage.count)
    }

    deinit {
        storage.deinitialize()
        storage.deallocate()
    }

    mutating func reset() {
        storage.update(repeating: 0)
    }
}
