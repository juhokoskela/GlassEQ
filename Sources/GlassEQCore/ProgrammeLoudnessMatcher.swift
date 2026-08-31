import Foundation

public extension EQProfile {
    var programmeComparisonReference: EQProfile {
        var reference = self
        reference.filters = []
        reference.leftFilters = []
        reference.rightFilters = []
        reference.isBypassed = false
        return reference
    }
}

public enum EQProgrammeComparisonSelection: UInt8, Codable, Equatable, Sendable {
    case equalized
    case filtersOff
}

public struct EQProgrammeComparisonSnapshot: Codable, Equatable, Sendable {
    public var isActive: Bool
    public var isReady: Bool
    public var selection: EQProgrammeComparisonSelection
    public var equalizedAttenuationDB: Double
    public var filtersOffAttenuationDB: Double

    public init(
        isActive: Bool = false,
        isReady: Bool = false,
        selection: EQProgrammeComparisonSelection = .equalized,
        equalizedAttenuationDB: Double = 0,
        filtersOffAttenuationDB: Double = 0
    ) {
        self.isActive = isActive
        self.isReady = isReady
        self.selection = selection
        self.equalizedAttenuationDB = equalizedAttenuationDB
        self.filtersOffAttenuationDB = filtersOffAttenuationDB
    }
}

struct ProgrammeLoudnessMatch: Equatable, Sendable {
    var isReady = false
    var equalizedGain: Float = 1
    var filtersOffGain: Float = 1
    var equalizedAttenuationDB = 0.0
    var filtersOffAttenuationDB = 0.0
}

struct ProgrammeLoudnessGains: Equatable, Sendable {
    var equalized: Float = 1
    var filtersOff: Float = 1
}

struct RealtimeProgrammeLoudnessMatcher: Sendable {
    private static let windowSegmentCount = 30
    private static let gatingBlockSegmentCount = 4
    private static let minimumGatedBlockCount = 4
    private static let absoluteGateEnergy = pow(10, (-70.0 + 0.691) / 10)
    private static let maximumAttenuationDB = -60.0

    private var equalizedWeighting: [KWeightingChannel]
    private var filtersOffWeighting: [KWeightingChannel]
    private var equalizedSegmentEnergy = Array(
        repeating: 0.0,
        count: Self.windowSegmentCount
    )
    private var filtersOffSegmentEnergy = Array(
        repeating: 0.0,
        count: Self.windowSegmentCount
    )
    private let segmentFrameCount: Int
    private let gainSmoothingCoefficient: Double
    private var segmentFrames = 0
    private var equalizedEnergyAccumulator = 0.0
    private var filtersOffEnergyAccumulator = 0.0
    private var segmentWriteIndex = 0
    private var storedSegmentCount = 0
    private var targetEqualizedGain = 1.0
    private var targetFiltersOffGain = 1.0
    private var currentEqualizedGain = 1.0
    private var currentFiltersOffGain = 1.0
    private(set) var isReady = false

    init(
        sampleRate: Double,
        channelCount: Int,
        gainSmoothingSeconds: Double = 0.5
    ) {
        let validSampleRate = sampleRate.isFinite && sampleRate > 0
            ? sampleRate
            : 48_000
        let channels = max(channelCount, 1)
        self.equalizedWeighting = (0..<channels).map { _ in
            KWeightingChannel(sampleRate: validSampleRate)
        }
        self.filtersOffWeighting = (0..<channels).map { _ in
            KWeightingChannel(sampleRate: validSampleRate)
        }
        self.segmentFrameCount = max(Int((validSampleRate * 0.1).rounded()), 1)
        let smoothingSeconds = gainSmoothingSeconds.isFinite && gainSmoothingSeconds > 0
            ? gainSmoothingSeconds
            : 0.5
        self.gainSmoothingCoefficient = 1 - exp(-1 / (validSampleRate * smoothingSeconds))
    }

    mutating func reset() {
        for index in equalizedWeighting.indices {
            equalizedWeighting[index].reset()
            filtersOffWeighting[index].reset()
        }
        for index in equalizedSegmentEnergy.indices {
            equalizedSegmentEnergy[index] = 0
            filtersOffSegmentEnergy[index] = 0
        }
        segmentFrames = 0
        equalizedEnergyAccumulator = 0
        filtersOffEnergyAccumulator = 0
        segmentWriteIndex = 0
        storedSegmentCount = 0
        targetEqualizedGain = 1
        targetFiltersOffGain = 1
        currentEqualizedGain = 1
        currentFiltersOffGain = 1
        isReady = false
    }

    mutating func observeFrame(
        equalized: UnsafeBufferPointer<Float>,
        filtersOff: UnsafeBufferPointer<Float>,
        sampleOffset: Int,
        channelCount: Int
    ) -> ProgrammeLoudnessGains {
        let availableSamples = min(
            max(equalized.count - sampleOffset, 0),
            max(filtersOff.count - sampleOffset, 0)
        )
        let weightingChannels = min(
            equalizedWeighting.count,
            filtersOffWeighting.count
        )
        let channels = min(
            max(channelCount, 1),
            min(weightingChannels, availableSamples)
        )
        if channels > 0 {
            for channel in 0..<channels {
                let equalizedSample = equalizedWeighting[channel].process(
                    equalized[sampleOffset + channel]
                )
                let filtersOffSample = filtersOffWeighting[channel].process(
                    filtersOff[sampleOffset + channel]
                )
                equalizedEnergyAccumulator += Double(equalizedSample * equalizedSample)
                filtersOffEnergyAccumulator += Double(filtersOffSample * filtersOffSample)
            }
        }

        segmentFrames += 1
        if segmentFrames >= segmentFrameCount {
            finishSegment()
        }
        advanceSmoothedGains()
        return ProgrammeLoudnessGains(
            equalized: Float(currentEqualizedGain),
            filtersOff: Float(currentFiltersOffGain)
        )
    }

    var snapshot: ProgrammeLoudnessMatch {
        currentMatch()
    }

    private mutating func finishSegment() {
        let divisor = Double(max(segmentFrames, 1))
        equalizedSegmentEnergy[segmentWriteIndex] = equalizedEnergyAccumulator / divisor
        filtersOffSegmentEnergy[segmentWriteIndex] = filtersOffEnergyAccumulator / divisor
        segmentWriteIndex = (segmentWriteIndex + 1) % Self.windowSegmentCount
        storedSegmentCount = min(storedSegmentCount + 1, Self.windowSegmentCount)
        segmentFrames = 0
        equalizedEnergyAccumulator = 0
        filtersOffEnergyAccumulator = 0
        updateTargetGains()
    }

    private mutating func updateTargetGains() {
        guard storedSegmentCount >= Self.gatingBlockSegmentCount else {
            return
        }

        // Gate both branches with the same programme windows. Independent gates could compare
        // different passages and turn the matcher itself into an A/B bias.
        var absoluteGatedJointEnergy = 0.0
        var absoluteGatedBlockCount = 0
        for blockEnd in (Self.gatingBlockSegmentCount - 1)..<storedSegmentCount {
            let block = blockEnergy(endingAt: blockEnd)
            let jointEnergy = max(block.equalized, block.filtersOff)
            if jointEnergy >= Self.absoluteGateEnergy {
                absoluteGatedJointEnergy += jointEnergy
                absoluteGatedBlockCount += 1
            }
        }
        guard absoluteGatedBlockCount > 0 else {
            return
        }

        let relativeGate = absoluteGatedJointEnergy
            / Double(absoluteGatedBlockCount)
            * 0.1
        let gate = max(Self.absoluteGateEnergy, relativeGate)
        var equalizedEnergy = 0.0
        var filtersOffEnergy = 0.0
        var gatedBlockCount = 0
        for blockEnd in (Self.gatingBlockSegmentCount - 1)..<storedSegmentCount {
            let block = blockEnergy(endingAt: blockEnd)
            guard max(block.equalized, block.filtersOff) >= gate else {
                continue
            }
            equalizedEnergy += block.equalized
            filtersOffEnergy += block.filtersOff
            gatedBlockCount += 1
        }
        guard gatedBlockCount >= Self.minimumGatedBlockCount,
              equalizedEnergy.isFinite,
              filtersOffEnergy.isFinite,
              equalizedEnergy > 0,
              filtersOffEnergy > 0 else {
            return
        }

        isReady = true
        let differenceDB = 10 * log10(equalizedEnergy / filtersOffEnergy)
        // Never boost the quieter branch: matching by attenuation preserves the profile's
        // available headroom and cannot manufacture a new clipping path.
        if differenceDB > 0 {
            targetEqualizedGain = pow(
                10,
                max(-differenceDB, Self.maximumAttenuationDB) / 20
            )
            targetFiltersOffGain = 1
        } else {
            targetEqualizedGain = 1
            targetFiltersOffGain = pow(
                10,
                max(differenceDB, Self.maximumAttenuationDB) / 20
            )
        }
    }

    private func blockEnergy(endingAt orderedEndIndex: Int) -> (
        equalized: Double,
        filtersOff: Double
    ) {
        var equalized = 0.0
        var filtersOff = 0.0
        let first = orderedEndIndex - Self.gatingBlockSegmentCount + 1
        for orderedIndex in first...orderedEndIndex {
            let storageIndex = segmentStorageIndex(forOrderedIndex: orderedIndex)
            equalized += equalizedSegmentEnergy[storageIndex]
            filtersOff += filtersOffSegmentEnergy[storageIndex]
        }
        let divisor = Double(Self.gatingBlockSegmentCount)
        return (equalized / divisor, filtersOff / divisor)
    }

    private func segmentStorageIndex(forOrderedIndex orderedIndex: Int) -> Int {
        let oldest = (segmentWriteIndex - storedSegmentCount + Self.windowSegmentCount)
            % Self.windowSegmentCount
        return (oldest + orderedIndex) % Self.windowSegmentCount
    }

    private mutating func advanceSmoothedGains() {
        currentEqualizedGain += (
            targetEqualizedGain - currentEqualizedGain
        ) * gainSmoothingCoefficient
        currentFiltersOffGain += (
            targetFiltersOffGain - currentFiltersOffGain
        ) * gainSmoothingCoefficient
    }

    private func currentMatch() -> ProgrammeLoudnessMatch {
        ProgrammeLoudnessMatch(
            isReady: isReady,
            equalizedGain: Float(currentEqualizedGain),
            filtersOffGain: Float(currentFiltersOffGain),
            equalizedAttenuationDB: 20 * log10(max(currentEqualizedGain, .leastNonzeroMagnitude)),
            filtersOffAttenuationDB: 20 * log10(max(currentFiltersOffGain, .leastNonzeroMagnitude))
        )
    }
}

private struct KWeightingChannel: Sendable {
    private var shelf: KWeightingBiquad
    private var highPass: KWeightingBiquad

    init(sampleRate: Double) {
        self.shelf = KWeightingBiquad(coefficients: .kWeightingShelf(sampleRate: sampleRate))
        self.highPass = KWeightingBiquad(coefficients: .kWeightingHighPass(sampleRate: sampleRate))
    }

    mutating func process(_ sample: Float) -> Float {
        highPass.process(shelf.process(sample))
    }

    mutating func reset() {
        shelf.reset()
        highPass.reset()
    }
}

private struct KWeightingBiquad: Sendable {
    private let coefficients: KWeightingCoefficients
    private var z1: Float = 0
    private var z2: Float = 0

    init(coefficients: KWeightingCoefficients) {
        self.coefficients = coefficients
    }

    mutating func process(_ input: Float) -> Float {
        guard input.isFinite else {
            z1 = 0
            z2 = 0
            return 0
        }
        let output = coefficients.b0 * input + z1
        let nextZ1 = coefficients.b1 * input - coefficients.a1 * output + z2
        let nextZ2 = coefficients.b2 * input - coefficients.a2 * output
        guard output.isFinite, nextZ1.isFinite, nextZ2.isFinite else {
            z1 = 0
            z2 = 0
            return 0
        }
        z1 = nextZ1
        z2 = nextZ2
        return output
    }

    mutating func reset() {
        z1 = 0
        z2 = 0
    }
}

struct KWeightingCoefficients: Sendable {
    var b0: Float
    var b1: Float
    var b2: Float
    var a1: Float
    var a2: Float

    static func kWeightingShelf(sampleRate: Double) -> Self {
        let frequency = 1_681.974_450_955_533
        let gainDB = 3.999_843_853_973_347
        let q = 0.707_175_236_955_419_6
        let k = tan(.pi * frequency / sampleRate)
        let highGain = pow(10, gainDB / 20)
        let bandGain = pow(highGain, 0.499_666_774_154_541_6)
        let denominator = 1 + k / q + k * k
        return Self(
            b0: Float((highGain + bandGain * k / q + k * k) / denominator),
            b1: Float(2 * (k * k - highGain) / denominator),
            b2: Float((highGain - bandGain * k / q + k * k) / denominator),
            a1: Float(2 * (k * k - 1) / denominator),
            a2: Float((1 - k / q + k * k) / denominator)
        )
    }

    static func kWeightingHighPass(sampleRate: Double) -> Self {
        let frequency = 38.135_470_876_024_44
        let q = 0.500_327_037_323_877_3
        let k = tan(.pi * frequency / sampleRate)
        let denominator = 1 + k / q + k * k
        return Self(
            b0: 1,
            b1: -2,
            b2: 1,
            a1: Float(2 * (k * k - 1) / denominator),
            a2: Float((1 - k / q + k * k) / denominator)
        )
    }
}
