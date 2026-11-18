import Foundation
import GlassEQCore

private enum DSPWorkload: String {
    case steady, edit, comparison
}

private struct DSPBenchmarkCase {
    var profile: EQProfile
    var sampleRate: Double
    var frames = [16]
    var workload = DSPWorkload.steady
}

func runDSPBenchmark(curvePath: String?, maximumCallbackBudgetPercent: Double?) -> Bool {
    let convolutionProfile: EQProfile
    do {
        if let curvePath {
            let text = try String(contentsOfFile: curvePath, encoding: .utf8)
            convolutionProfile = try EQProfileTextImporter.importAutoEQ(
                text, profileName: URL(fileURLWithPath: curvePath).deletingPathExtension().lastPathComponent
            )
            guard convolutionProfile.mode == .convolution else {
                print("Expected an EqualizerAPO GraphicEQ response at \(curvePath)")
                return false
            }
        } else {
            convolutionProfile = benchmarkConvolutionProfile()
        }
    } catch {
        print("Could not load the benchmark curve: \(error)")
        return false
    }

    var cases = [
        DSPBenchmarkCase(profile: .flatParametric, sampleRate: 48_000),
        DSPBenchmarkCase(profile: complexStereoProfile(), sampleRate: 48_000),
    ]
    for rate in [48_000.0, 96_000, 192_000] {
        for profile in [EQProfile.flatGraphic31, convolutionProfile] {
            cases.append(DSPBenchmarkCase(profile: profile, sampleRate: rate))
            if rate != 96_000 {
                cases.append(DSPBenchmarkCase(profile: profile, sampleRate: rate, workload: .edit))
            }
        }
    }
    let maximumSections = EQProfile(
        name: "128 biquads per channel", mode: .parametric, preampDB: -6,
        filters: (0..<128).map { index in
            EQFilter(kind: .peak, frequency: Double(60 + 100 * index), gainDB: index.isMultiple(of: 2) ? -1 : 1, q: 1)
        }
    )
    cases.append(DSPBenchmarkCase(profile: maximumSections, sampleRate: 192_000))
    cases.append(DSPBenchmarkCase(profile: maximumSections, sampleRate: 192_000, workload: .edit))
    for workload in [DSPWorkload.steady, .edit, .comparison] {
        cases.append(
            DSPBenchmarkCase(
                profile: convolutionProfile, sampleRate: 48_000, frames: [17, 255, 1, 257, 480], workload: workload
            ))
    }

    print("Offline stereo DSP, 20,000 measured renders per case. Device scheduling requires a live HAL trace.")
    var passed = true
    for item in cases {
        do {
            if try !measure(item, maximumCallbackBudgetPercent: maximumCallbackBudgetPercent) {
                passed = false
            }
        } catch {
            print("Failed to prepare \(item.profile.name): \(error)")
            passed = false
        }
    }
    return passed
}

private func measure(_ item: DSPBenchmarkCase, maximumCallbackBudgetPercent: Double?) throws -> Bool {
    let maximumFrames = item.frames.max()!
    let config = try EQRenderConfiguration.prepare(profile: item.profile, sampleRate: item.sampleRate, channelCount: 2)
    var renderer = RealtimeEQTransition(
        activeProcessor: EQProcessor(renderConfiguration: config),
        maximumFrameCount: maximumFrames, channelCount: 2, sampleRate: item.sampleRate
    )
    var edited = item.profile
    edited.preampDB -= 1
    let editedConfig = try EQRenderConfiguration.prepare(profile: edited, sampleRate: item.sampleRate, channelCount: 2)

    let period = 8192
    let source = makeStereoTestBlock(frameCount: period + maximumFrames, period: period)
    var storage = [Float](repeating: 0, count: 2 * maximumFrames)
    var stats = DSPRenderMeasurements()
    var sourceFrame = 0
    var completedEdits = 0
    var nextSelectionFrame = 0
    var renderedFrames = 0
    var selection = EQProgrammeComparisonSelection.equalized
    if item.workload == .comparison {
        var draft: EQProcessor? = EQProcessor(renderConfiguration: editedConfig)
        precondition(renderer.beginProgrammeComparison(equalizedProcessor: &draft))
    }

    // Keep the two allocations borrowed for the entire run. Input refill, bank preparation,
    // retired-bank release, and result sampling all happen outside the render interval.
    source.withUnsafeBufferPointer { input in
        storage.withUnsafeMutableBufferPointer { output in
            for iteration in -1000..<20_000 {
                let frames = item.frames[(iteration + 1000) % item.frames.count]
                output.baseAddress!.update(from: input.baseAddress! + 2 * sourceFrame, count: 2 * frames)
                sourceFrame = (sourceFrame + frames) % period
                if item.workload == .edit, !renderer.isTransitioning {
                    let next = completedEdits.isMultiple(of: 2) ? editedConfig : config
                    var candidate: EQProcessor? = EQProcessor(renderConfiguration: next)
                    precondition(renderer.beginTransition(to: &candidate))
                }
                if item.workload == .comparison, renderedFrames >= nextSelectionFrame {
                    selection = selection == .equalized ? .reference : .equalized
                    renderer.setProgrammeComparisonSelection(selection)
                    nextSelectionFrame += Int(item.sampleRate)
                }
                renderedFrames += frames

                let start = DispatchTime.now().uptimeNanoseconds
                let result = renderer.processInterleavedWithDiagnostics(output, frameCount: frames, channelCount: 2)
                let elapsed = DispatchTime.now().uptimeNanoseconds - start

                if result.completedTransition { completedEdits += 1 }
                if iteration >= 0 {
                    stats.record(
                        elapsed: elapsed, frames: frames, sampleRate: item.sampleRate,
                        timing: result.workTiming, saturated: result.saturatedSamples,
                        sample: Double(output[0]) + Double(output[2 * frames - 1]))
                }
                _ = consume result
            }
        }
    }
    let buffers = item.frames.map(String.init).joined(separator: "/")
    print("\(item.profile.name), \(item.workload.rawValue), stereo \(Int(item.sampleRate)) Hz, \(buffers) frames")
    if item.workload == .edit, completedEdits == 0 {
        print("No profile edit completed.")
        return false
    }
    if item.workload == .comparison, !renderer.programmeComparisonSnapshot.isReady {
        print("The programme comparison did not reach its ready state.")
        return false
    }
    return stats.report(maximumCallbackBudgetPercent: maximumCallbackBudgetPercent)
}

private struct DSPRenderMeasurements {
    var durations = [UInt64]()
    var totalBudget = 0.0
    var budgetMisses = 0
    var minimumSlack = Double.infinity
    var minimumTailFrames = Int.max
    var tailMisses: UInt64 = 0
    var saturation: UInt64 = 0
    var checksum = 0.0

    init() {
        durations.reserveCapacity(20_000)
    }

    mutating func record(
        elapsed: UInt64, frames: Int, sampleRate: Double, timing: EQRenderWorkTiming, saturated: UInt64, sample: Double
    ) {
        let budget = Double(frames) * 1e9 / sampleRate
        let slack = budget - Double(elapsed)
        durations.append(elapsed)
        totalBudget += budget
        minimumSlack = min(minimumSlack, slack)
        if slack < 0 { budgetMisses += 1 }
        if timing.tailCompletionObservations > 0 {
            minimumTailFrames = min(minimumTailFrames, timing.minimumTailCompletionSlackFrames)
        }
        tailMisses += timing.tailDeadlineMisses
        saturation += saturated
        checksum += sample
    }

    func report(maximumCallbackBudgetPercent: Double?) -> Bool {
        let sorted = durations.sorted()
        let total = Double(sorted.reduce(0, +))
        let used = 100 * total / totalBudget
        func percentile(_ fraction: Double) -> Double {
            Double(sorted[Int(ceil(fraction * Double(sorted.count))) - 1]) / 1000
        }
        print(
            String(
                format: "  DSP µs mean %.3f, p99.9 %.3f, p99.99 %.3f, max %.3f",
                total / Double(sorted.count) / 1000, percentile(0.999), percentile(0.9999), percentile(1)))
        print(
            String(
                format: "  Render budget used %.2f%%, minimum slack %.3f µs, over budget %d/%d",
                used, minimumSlack / 1000, budgetMisses, sorted.count))
        if minimumTailFrames != .max {
            print("  FIR tail minimum slack \(minimumTailFrames) frames, missed jobs \(tailMisses)")
        }
        print("  Saturated samples \(saturation), output checksum \(checksum)")
        if let maximumCallbackBudgetPercent, used >= maximumCallbackBudgetPercent {
            print("  Mean DSP time exceeded the \(maximumCallbackBudgetPercent)% limit.")
            return false
        }
        return checksum.isFinite && tailMisses == 0
    }
}

private func makeStereoTestBlock(frameCount: Int, period: Int) -> [Float] {
    var samples = [Float](repeating: 0, count: 2 * frameCount)
    for frame in 0..<frameCount {
        let phase = 2 * Double.pi * Double(frame % period) / Double(period)
        samples[frame * 2] = Float(0.18 * sin(13 * phase) + 0.07 * sin(171 * phase))
        samples[frame * 2 + 1] = Float(0.16 * sin(37 * phase) - 0.05 * sin(1073 * phase))
    }
    return samples
}

private func complexStereoProfile() -> EQProfile {
    EQProfile(
        name: "Complex Stereo",
        mode: .parametric,
        channelMode: .stereo,
        preampDB: -3,
        filters: [],
        leftPreampDB: -3,
        leftFilters: [
            EQFilter(kind: .peak, frequency: 55, gainDB: 4.5, q: 4),
            EQFilter(kind: .lowShelf, frequency: 110, gainDB: 2.5, q: 0.8),
            EQFilter(kind: .highShelf, frequency: 9_000, gainDB: -3.5, q: 0.7),
            EQFilter(kind: .highPass, frequency: 24, gainDB: 0, q: 0.707),
        ],
        rightPreampDB: -4,
        rightFilters: [
            EQFilter(kind: .peak, frequency: 1_250, gainDB: -5, q: 7),
            EQFilter(kind: .lowPass, frequency: 18_000, gainDB: 0, q: 0.707),
            EQFilter(kind: .highShelf, frequency: 12_000, gainDB: 2, q: 0.9),
            EQFilter(kind: .peak, frequency: 72, gainDB: 3, q: 5),
        ]
    )
}

private func benchmarkConvolutionProfile() -> EQProfile {
    EQProfile(
        name: "Benchmark Convolution",
        mode: .convolution,
        preampDB: -6,
        filters: [],
        convolution: .magnitudeCurve(
            MagnitudeCurveSource(points: [
                EQMagnitudePoint(frequency: 20, gainDB: 4),
                EQMagnitudePoint(frequency: 80, gainDB: -2),
                EQMagnitudePoint(frequency: 250, gainDB: 3),
                EQMagnitudePoint(frequency: 1_000, gainDB: -4),
                EQMagnitudePoint(frequency: 4_000, gainDB: 5),
                EQMagnitudePoint(frequency: 10_000, gainDB: -3),
                EQMagnitudePoint(frequency: 20_000, gainDB: 1),
            ]))
    )
}
