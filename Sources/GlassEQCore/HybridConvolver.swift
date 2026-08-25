import Accelerate
import Darwin
import Foundation

enum HybridConvolverError: Error, Equatable, Sendable {
    case invalidImpulseResponse
    case transformSetupFailed
}

struct PreparedConvolutionKernel: @unchecked Sendable {
    static let tapCount = 16_384
    static let directTapCount = 512
    static let tailPartitionFrames = 256
    static let transformFrames = tailPartitionFrames * 2
    static let packedBinCount = transformFrames / 2
    static let tailPartitionCount = (tapCount - directTapCount) / tailPartitionFrames

    let directCoefficientsReversed: [Float]
    let tailSpectrumReal: [Float]
    let tailSpectrumImaginary: [Float]

    init(impulseResponse: [Float]) throws {
        guard !impulseResponse.isEmpty,
              impulseResponse.count <= Self.tapCount,
              impulseResponse.allSatisfy(\.isFinite) else {
            throw HybridConvolverError.invalidImpulseResponse
        }

        var padded = [Float](repeating: 0, count: Self.tapCount)
        padded.replaceSubrange(0..<impulseResponse.count, with: impulseResponse)
        self.directCoefficientsReversed = Array(
            padded[0..<Self.directTapCount].reversed()
        )

        let setup = try RealFloatDFTSetup()
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
            clear(&inputEven)
            clear(&inputOdd)
            let sourceStart = Self.directTapCount + partition * Self.tailPartitionFrames
            for pair in 0..<(Self.tailPartitionFrames / 2) {
                inputEven[pair] = padded[sourceStart + pair * 2]
                inputOdd[pair] = padded[sourceStart + pair * 2 + 1]
            }
            setup.forward(
                even: &inputEven,
                odd: &inputOdd,
                outputReal: &outputReal,
                outputImaginary: &outputImaginary
            )
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

struct RealtimeHybridConvolver: @unchecked Sendable {
    private static let outputRingFrames = 1_024
    private static let outputRingMask = outputRingFrames - 1
    private static let inverseGuardFrames = 16
    private static let partitionWorkFrames = PreparedConvolutionKernel.tailPartitionFrames
        - inverseGuardFrames

    private let kernel: PreparedConvolutionKernel
    private let transform: RealFloatDFTSetup
    private var directHistory = [Float](
        repeating: 0,
        count: PreparedConvolutionKernel.directTapCount * 2
    )
    private var directWriteIndex = 0
    private var tailInputBlock = [Float](
        repeating: 0,
        count: PreparedConvolutionKernel.tailPartitionFrames
    )
    private var tailInputCount = 0
    private var fftInputEven = [Float](
        repeating: 0,
        count: PreparedConvolutionKernel.packedBinCount
    )
    private var fftInputOdd = [Float](
        repeating: 0,
        count: PreparedConvolutionKernel.packedBinCount
    )
    private var fftOutputReal = [Float](
        repeating: 0,
        count: PreparedConvolutionKernel.packedBinCount
    )
    private var fftOutputImaginary = [Float](
        repeating: 0,
        count: PreparedConvolutionKernel.packedBinCount
    )
    private var inputSpectrumReal = [Float](
        repeating: 0,
        count: PreparedConvolutionKernel.tailPartitionCount
            * PreparedConvolutionKernel.packedBinCount
    )
    private var inputSpectrumImaginary = [Float](
        repeating: 0,
        count: PreparedConvolutionKernel.tailPartitionCount
            * PreparedConvolutionKernel.packedBinCount
    )
    private var inputSpectrumWriteIndex = -1
    private var accumulatorReal = [Float](
        repeating: 0,
        count: PreparedConvolutionKernel.packedBinCount
    )
    private var accumulatorImaginary = [Float](
        repeating: 0,
        count: PreparedConvolutionKernel.packedBinCount
    )
    private var inverseOutputEven = [Float](
        repeating: 0,
        count: PreparedConvolutionKernel.packedBinCount
    )
    private var inverseOutputOdd = [Float](
        repeating: 0,
        count: PreparedConvolutionKernel.packedBinCount
    )
    private var tailOverlap = [Float](
        repeating: 0,
        count: PreparedConvolutionKernel.tailPartitionFrames
    )
    private var tailOutputRing = [Float](
        repeating: 0,
        count: Self.outputRingFrames
    )
    private var jobActive = false
    private var jobInputSpectrumIndex = 0
    private var jobNextPartition = 0
    private var jobWorkNumerator = 0
    private var jobDueFrame: Int64 = 0
    private var absoluteFrame: Int64 = 0

    init(kernel: PreparedConvolutionKernel, prewarm: Bool = true) throws {
        self.kernel = kernel
        self.transform = try RealFloatDFTSetup()
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
            directHistory.withUnsafeBufferPointer { history in
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
        directWriteIndex = (directWriteIndex + 1)
            & (PreparedConvolutionKernel.directTapCount - 1)

        tailInputBlock[tailInputCount] = input
        tailInputCount += 1
        let completedInputBlock = tailInputCount
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
              frameCount > 0 else {
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
                    directHistory.withUnsafeBufferPointer { history in
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
                directWriteIndex = (directWriteIndex + 1)
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
        clear(&directHistory)
        directWriteIndex = 0
        clear(&tailInputBlock)
        tailInputCount = 0
        clear(&fftInputEven)
        clear(&fftInputOdd)
        clear(&fftOutputReal)
        clear(&fftOutputImaginary)
        clear(&inputSpectrumReal)
        clear(&inputSpectrumImaginary)
        inputSpectrumWriteIndex = -1
        clear(&accumulatorReal)
        clear(&accumulatorImaginary)
        clear(&inverseOutputEven)
        clear(&inverseOutputOdd)
        clear(&tailOverlap)
        clear(&tailOutputRing)
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
              jobNextPartition < PreparedConvolutionKernel.tailPartitionCount {
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
            fftInputEven[pair] = tailInputBlock[pair * 2]
            fftInputOdd[pair] = tailInputBlock[pair * 2 + 1]
        }
        let zeroPairStart = PreparedConvolutionKernel.tailPartitionFrames / 2
        for pair in zeroPairStart..<PreparedConvolutionKernel.packedBinCount {
            fftInputEven[pair] = 0
            fftInputOdd[pair] = 0
        }
        tailInputCount = 0

        transform.forward(
            even: &fftInputEven,
            odd: &fftInputOdd,
            outputReal: &fftOutputReal,
            outputImaginary: &fftOutputImaginary
        )
        inputSpectrumWriteIndex = (inputSpectrumWriteIndex + 1)
            % PreparedConvolutionKernel.tailPartitionCount
        let destinationStart = inputSpectrumWriteIndex
            * PreparedConvolutionKernel.packedBinCount
        for bin in 0..<PreparedConvolutionKernel.packedBinCount {
            inputSpectrumReal[destinationStart + bin] = fftOutputReal[bin] * 0.5
            inputSpectrumImaginary[destinationStart + bin] = fftOutputImaginary[bin] * 0.5
        }

        clear(&accumulatorReal)
        clear(&accumulatorImaginary)
        jobActive = true
        jobInputSpectrumIndex = inputSpectrumWriteIndex
        jobNextPartition = 0
        jobWorkNumerator = 0
        jobDueFrame = absoluteFrame + Int64(PreparedConvolutionKernel.tailPartitionFrames)
    }

    private mutating func accumulateTailPartition(_ partition: Int) {
        let spectrumIndex = (
            jobInputSpectrumIndex
                - partition
                + PreparedConvolutionKernel.tailPartitionCount
        ) % PreparedConvolutionKernel.tailPartitionCount
        let inputStart = spectrumIndex * PreparedConvolutionKernel.packedBinCount
        let kernelStart = partition * PreparedConvolutionKernel.packedBinCount

        accumulatorReal[0] += inputSpectrumReal[inputStart]
            * kernel.tailSpectrumReal[kernelStart]
        accumulatorImaginary[0] += inputSpectrumImaginary[inputStart]
            * kernel.tailSpectrumImaginary[kernelStart]
        inputSpectrumReal.withUnsafeMutableBufferPointer { inputReal in
            inputSpectrumImaginary.withUnsafeMutableBufferPointer { inputImaginary in
                kernel.tailSpectrumReal.withUnsafeBufferPointer { kernelReal in
                    kernel.tailSpectrumImaginary.withUnsafeBufferPointer { kernelImaginary in
                        accumulatorReal.withUnsafeMutableBufferPointer { accumulatorReal in
                            accumulatorImaginary.withUnsafeMutableBufferPointer { accumulatorImaginary in
                                var input = DSPSplitComplex(
                                    realp: inputReal.baseAddress! + inputStart + 1,
                                    imagp: inputImaginary.baseAddress! + inputStart + 1
                                )
                                var coefficients = DSPSplitComplex(
                                    realp: .init(mutating: kernelReal.baseAddress! + kernelStart + 1),
                                    imagp: .init(mutating: kernelImaginary.baseAddress! + kernelStart + 1)
                                )
                                var accumulator = DSPSplitComplex(
                                    realp: accumulatorReal.baseAddress! + 1,
                                    imagp: accumulatorImaginary.baseAddress! + 1
                                )
                                vDSP_zvma(
                                    &input,
                                    1,
                                    &coefficients,
                                    1,
                                    &accumulator,
                                    1,
                                    &accumulator,
                                    1,
                                    vDSP_Length(PreparedConvolutionKernel.packedBinCount - 1)
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    private mutating func finishTailJob() {
        transform.inverse(
            real: &accumulatorReal,
            imaginary: &accumulatorImaginary,
            outputEven: &inverseOutputEven,
            outputOdd: &inverseOutputOdd
        )
        let scale = 1 / Float(PreparedConvolutionKernel.transformFrames)
        for frame in 0..<PreparedConvolutionKernel.tailPartitionFrames {
            let firstHalfSample = unpackedInverseSample(frame) * scale
            let secondHalfSample = unpackedInverseSample(
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
            ? inverseOutputEven[pair]
            : inverseOutputOdd[pair]
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

private final class RealFloatDFTSetup: @unchecked Sendable {
    private let forwardSetup: vDSP_DFT_Setup
    private let inverseSetup: vDSP_DFT_Setup

    init() throws {
        let length = vDSP_Length(PreparedConvolutionKernel.transformFrames)
        guard let forwardSetup = vDSP_DFT_zrop_CreateSetup(nil, length, .FORWARD) else {
            throw HybridConvolverError.transformSetupFailed
        }
        guard let inverseSetup = vDSP_DFT_zrop_CreateSetup(
            forwardSetup,
            length,
            .INVERSE
        ) else {
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
        even: inout [Float],
        odd: inout [Float],
        outputReal: inout [Float],
        outputImaginary: inout [Float]
    ) {
        execute(
            setup: forwardSetup,
            inputReal: &even,
            inputImaginary: &odd,
            outputReal: &outputReal,
            outputImaginary: &outputImaginary
        )
    }

    func inverse(
        real: inout [Float],
        imaginary: inout [Float],
        outputEven: inout [Float],
        outputOdd: inout [Float]
    ) {
        execute(
            setup: inverseSetup,
            inputReal: &real,
            inputImaginary: &imaginary,
            outputReal: &outputEven,
            outputImaginary: &outputOdd
        )
    }

    private func execute(
        setup: vDSP_DFT_Setup,
        inputReal: inout [Float],
        inputImaginary: inout [Float],
        outputReal: inout [Float],
        outputImaginary: inout [Float]
    ) {
        inputReal.withUnsafeBufferPointer { inputRealBuffer in
            inputImaginary.withUnsafeBufferPointer { inputImaginaryBuffer in
                outputReal.withUnsafeMutableBufferPointer { outputRealBuffer in
                    outputImaginary.withUnsafeMutableBufferPointer { outputImaginaryBuffer in
                        vDSP_DFT_Execute(
                            setup,
                            inputRealBuffer.baseAddress!,
                            inputImaginaryBuffer.baseAddress!,
                            outputRealBuffer.baseAddress!,
                            outputImaginaryBuffer.baseAddress!
                        )
                    }
                }
            }
        }
    }
}

private func clear(_ values: inout [Float]) {
    for index in values.indices {
        values[index] = 0
    }
}
