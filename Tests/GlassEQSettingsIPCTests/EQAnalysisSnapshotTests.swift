import Foundation
import GlassEQCore
import Synchronization
import Testing
@testable import GlassEQSettingsUI

@Suite
struct EQAnalysisSnapshotTests {
    @Test
    func asynchronousAnalysisMatchesSynchronousAnalysis() async throws {
        let sampleRate = 48_000.0
        let leftSamples = (0..<1_024).map { index in
            Float(0.25 * sin(2 * Double.pi * Double(index) / 31))
        }
        let rightSamples = (0..<1_024).map { index in
            Float(0.125 * cos(2 * Double.pi * Double(index) / 47))
        }
        let profile = EQProfile(
            name: "Stereo analysis",
            mode: .convolution,
            channelMode: .stereo,
            filters: [],
            leftPreampDB: -2,
            leftFilters: [],
            rightPreampDB: -4,
            rightFilters: [],
            leftConvolution: .impulseResponse(ImpulseResponseSource(
                sampleRate: sampleRate,
                samples: leftSamples
            )),
            rightConvolution: .impulseResponse(ImpulseResponseSource(
                sampleRate: sampleRate,
                samples: rightSamples
            ))
        )

        let synchronous = EQAnalysisSnapshot(profile: profile, sampleRate: sampleRate)
        let asynchronous = try await EQAnalysisSnapshot.analyze(
            profile: profile,
            sampleRate: sampleRate
        )

        #expect(asynchronous == synchronous)
    }

    @Test
    func preCancelledAnalysisStopsBeforeInspectingImpulseResponse() async {
        let checkCount = Mutex(0)
        let start = AnalysisPause()
        let profile = impulseResponseProfile(samples: [1])
        let task = Task {
            start.wait()
            return try await EQAnalysisSnapshot.analyze(
                profile: profile,
                sampleRate: 48_000,
                cancellationCheck: {
                    checkCount.withLock { $0 += 1 }
                    try Task.checkCancellation()
                }
            )
        }

        await start.waitUntilReached()
        task.cancel()
        start.resume()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(checkCount.withLock { $0 } == 1)
    }

    @Test
    func cancellationStopsImpulseResponseDFTWithinOneChunk() async {
        let checkCount = Mutex(0)
        let pause = AnalysisPause()
        let samples = (0..<4_096).map { index in
            Float(sin(2 * Double.pi * Double(index) / 29))
        }
        let profile = impulseResponseProfile(samples: samples)
        let task = Task {
            try await EQAnalysisSnapshot.analyze(
                profile: profile,
                sampleRate: 48_000,
                cancellationCheck: {
                    let count = checkCount.withLock { count in
                        count += 1
                        return count
                    }
                    if count == 10 {
                        pause.wait()
                    }
                    try Task.checkCancellation()
                }
            )
        }

        await pause.waitUntilReached()
        task.cancel()
        pause.resume()
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(checkCount.withLock { $0 } == 10)
    }

    private func impulseResponseProfile(samples: [Float]) -> EQProfile {
        EQProfile(
            name: "Impulse response analysis",
            mode: .convolution,
            filters: [],
            convolution: .impulseResponse(ImpulseResponseSource(
                sampleRate: 48_000,
                samples: samples
            ))
        )
    }
}

private final class AnalysisPause: Sendable {
    private struct State {
        var isWaiting = false
        var continuation: CheckedContinuation<Void, Never>?
    }

    private let state = Mutex(State())
    private let release = DispatchSemaphore(value: 0)

    func wait() {
        let continuation = state.withLock { state in
            state.isWaiting = true
            defer { state.continuation = nil }
            return state.continuation
        }
        continuation?.resume()
        release.wait()
    }

    func waitUntilReached() async {
        await withCheckedContinuation { continuation in
            let shouldResume = state.withLock { state in
                guard !state.isWaiting else {
                    return true
                }
                state.continuation = continuation
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }

    func resume() {
        release.signal()
    }
}
