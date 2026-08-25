import Foundation

struct PlaybackSampleRatePlan: Equatable, Sendable {
    let inputSampleRate: Double
    let outputSampleRate: Double

    init(inputSampleRate: Double, outputSampleRate: Double) {
        self.inputSampleRate = max(inputSampleRate, 1)
        self.outputSampleRate = max(outputSampleRate, 1)
    }

    var requiresConversion: Bool {
        abs(inputSampleRate - outputSampleRate) >= 1
    }

    func inputFrames(forOutputFrames outputFrames: Int) -> Int {
        Int(ceil(Double(max(outputFrames, 1)) * inputSampleRate / outputSampleRate))
    }
}

struct PlaybackOccupancyRecoveryPolicy {
    private static let toleratedCallbackCount = 4

    static func shouldReprime(
        occupancyFrames: Int,
        targetFrames: Int,
        outputFrames: Int
    ) -> Bool {
        let targetFrames = max(targetFrames, 1)
        let toleratedExcessFrames = max(
            max(outputFrames, 1) * toleratedCallbackCount,
            targetFrames
        )
        return occupancyFrames > targetFrames + toleratedExcessFrames
    }
}

struct PlaybackRateServo: Sendable {
    private static let filterTimeSeconds = 1.0
    private static let proportionalTimeSeconds = 20.0
    private static let integralTimeSeconds = 25.0
    private static let maximumCorrection = 500e-6
    private static let maximumSlewPerSecond = 100e-6

    let sampleRate: Double
    private(set) var targetFrames: Double
    private(set) var filteredOccupancyFrames: Double
    private(set) var correction: Double = 0
    private(set) var correctionIsSaturated = false
    private var correctionBias = 0.0
    private var isPriming = true

    init(sampleRate: Double, targetFrames: Int) {
        self.sampleRate = max(sampleRate, 1)
        self.targetFrames = Double(max(targetFrames, 1))
        self.filteredOccupancyFrames = Double(max(targetFrames, 1))
    }

    var ratio: Double {
        1 + correction
    }

    var correctionPartsPerMillion: Double {
        correction * 1_000_000
    }

    var learnedCorrectionPartsPerMillion: Double {
        correctionBias * 1_000_000
    }

    mutating func reset(targetFrames: Int) {
        self.targetFrames = Double(max(targetFrames, 1))
        filteredOccupancyFrames = self.targetFrames
        correction = 0
        correctionIsSaturated = false
        correctionBias = 0
        isPriming = true
    }

    mutating func beginPriming() {
        // Keep the integral's clock-rate estimate. The current correction may also contain a
        // transient proportional response, which must not become learned bias during a reprime.
        filteredOccupancyFrames = targetFrames
        isPriming = true
    }

    mutating func retarget(_ targetFrames: Int) {
        self.targetFrames = Double(max(targetFrames, 1))
        filteredOccupancyFrames = self.targetFrames
        isPriming = true
    }

    mutating func didPrime(occupancyFrames: Int) {
        filteredOccupancyFrames = Double(max(occupancyFrames, 0))
        isPriming = false
    }

    mutating func update(occupancyFrames: Int, outputFrames: Int) -> Double {
        let duration = Double(max(outputFrames, 1)) / sampleRate
        if isPriming {
            didPrime(occupancyFrames: occupancyFrames)
        }

        let filterAlpha = min(duration / Self.filterTimeSeconds, 1)
        filteredOccupancyFrames += filterAlpha * (Double(max(occupancyFrames, 0)) - filteredOccupancyFrames)

        let errorFrames = filteredOccupancyFrames - targetFrames
        // A positive occupancy error means capture is running faster, so consume input faster.
        correctionBias = clamp(
            correctionBias + errorFrames * duration
                / (sampleRate * Self.integralTimeSeconds * Self.integralTimeSeconds),
            minimum: -Self.maximumCorrection,
            maximum: Self.maximumCorrection
        )
        let unconstrainedCorrection = correctionBias + errorFrames / (sampleRate * Self.proportionalTimeSeconds)
        correctionIsSaturated = abs(unconstrainedCorrection) >= Self.maximumCorrection
        let desiredCorrection = clamp(
            unconstrainedCorrection,
            minimum: -Self.maximumCorrection,
            maximum: Self.maximumCorrection
        )
        let maximumStep = Self.maximumSlewPerSecond * duration
        correction += clamp(
            desiredCorrection - correction,
            minimum: -maximumStep,
            maximum: maximumStep
        )

        return ratio
    }

    private func clamp(_ value: Double, minimum: Double, maximum: Double) -> Double {
        min(max(value, minimum), maximum)
    }
}

struct HermitePlaybackResampler {
    struct InputPlan: Equatable, Sendable {
        var prefixFrames: Int
        var newFrames: Int
        var combinedFrames: Int
    }

    let channelCount: Int
    private var retainedSamples: [Float]
    private var retainedFrames = 0
    private var phase = 1.0

    init(channelCount: Int) {
        self.channelCount = max(channelCount, 1)
        self.retainedSamples = Array(repeating: 0, count: max(channelCount, 1) * 4)
    }

    mutating func reset() {
        retainedFrames = 0
        phase = 1
    }

    func inputPlan(outputFrames: Int, ratio: Double) -> InputPlan {
        let outputFrames = max(outputFrames, 1)
        let ratio = min(max(ratio, 0.9995), 1.0005)
        let activePhase = retainedFrames == 0 ? 1.0 : phase
        let prefixFrames = retainedFrames == 0 ? 1 : retainedFrames
        // Plan the exact integer pull up front. The extra edge frames satisfy the cubic kernel;
        // after the first block they come from the three- or four-frame private history below.
        let lastPosition = activePhase + Double(outputFrames - 1) * ratio
        let nextPosition = activePhase + Double(outputFrames) * ratio
        let lastInterpolationFrame = Int(lastPosition.rounded(.down)) + 2
        let nextRetainedFrame = Int(nextPosition.rounded(.down)) + 1
        let combinedFrames = max(lastInterpolationFrame, nextRetainedFrame) + 1
        return InputPlan(
            prefixFrames: prefixFrames,
            newFrames: max(combinedFrames - prefixFrames, 0),
            combinedFrames: combinedFrames
        )
    }

    func copyRetainedSamples(
        into samples: UnsafeMutableBufferPointer<Float>,
        plan: InputPlan
    ) -> Bool {
        guard samples.count >= plan.combinedFrames * channelCount else {
            return false
        }
        guard retainedFrames > 0 else {
            return true
        }
        let sampleCount = retainedFrames * channelCount
        for index in 0..<sampleCount {
            samples[index] = retainedSamples[index]
        }
        return true
    }

    mutating func render(
        input: UnsafeMutableBufferPointer<Float>,
        plan: InputPlan,
        output: UnsafeMutableBufferPointer<Float>,
        outputFrames: Int,
        ratio: Double
    ) -> Bool {
        let outputFrames = max(outputFrames, 0)
        guard outputFrames > 0,
              input.count >= plan.combinedFrames * channelCount,
              output.count >= outputFrames * channelCount else {
            return false
        }

        let ratio = min(max(ratio, 0.9995), 1.0005)
        let activePhase = retainedFrames == 0 ? 1.0 : phase
        if retainedFrames == 0 {
            guard plan.newFrames > 0 else {
                return false
            }
            for channel in 0..<channelCount {
                input[channel] = input[plan.prefixFrames * channelCount + channel]
            }
        }

        for outputFrame in 0..<outputFrames {
            let position = activePhase + Double(outputFrame) * ratio
            let frame = Int(position.rounded(.down))
            let fraction = Float(position - Double(frame))
            guard frame > 0, frame + 2 < plan.combinedFrames else {
                return false
            }
            for channel in 0..<channelCount {
                let y0 = input[(frame - 1) * channelCount + channel]
                let y1 = input[frame * channelCount + channel]
                let y2 = input[(frame + 1) * channelCount + channel]
                let y3 = input[(frame + 2) * channelCount + channel]
                output[outputFrame * channelCount + channel] = Self.interpolate(
                    y0: y0,
                    y1: y1,
                    y2: y2,
                    y3: y3,
                    fraction: fraction
                )
            }
        }

        let nextPosition = activePhase + Double(outputFrames) * ratio
        let retainStart = Int(nextPosition.rounded(.down)) - 1
        // A sub-unity ratio can leave four frames here when the phase does not cross an integer.
        let nextRetainedFrames = plan.combinedFrames - retainStart
        guard retainStart >= 0, (3...4).contains(nextRetainedFrames) else {
            return false
        }
        for frame in 0..<nextRetainedFrames {
            for channel in 0..<channelCount {
                retainedSamples[frame * channelCount + channel] = input[
                    (retainStart + frame) * channelCount + channel
                ]
            }
        }
        retainedFrames = nextRetainedFrames
        phase = nextPosition - Double(retainStart)
        return true
    }

    static func interpolate(
        y0: Float,
        y1: Float,
        y2: Float,
        y3: Float,
        fraction: Float
    ) -> Float {
        let c0 = y1
        let c1 = 0.5 * (y2 - y0)
        let c2 = y0 - 2.5 * y1 + 2 * y2 - 0.5 * y3
        let c3 = 0.5 * (y3 - y0) + 1.5 * (y1 - y2)
        return ((c3 * fraction + c2) * fraction + c1) * fraction + c0
    }
}
