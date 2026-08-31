import Foundation
@_spi(GlassEQSettingsUI) import GlassEQCore
import Synchronization
import Testing
@testable import GlassEQSettingsUI

@Suite
struct EQAnalysisSnapshotTests {
    @Test
    func asynchronousAnalysisMatchesCoreReference() async throws {
        let sampleRate = 48_000.0
        let leftSource = EQConvolutionSource.impulseResponse(ImpulseResponseSource(
            sampleRate: sampleRate,
            samples: (0..<1_024).map { index in
                Float(0.25 * sin(2 * Double.pi * Double(index) / 31))
            }
        ))
        let rightSource = EQConvolutionSource.impulseResponse(ImpulseResponseSource(
            sampleRate: sampleRate,
            samples: (0..<1_024).map { index in
                Float(0.125 * cos(2 * Double.pi * Double(index) / 47))
            }
        ))
        let profile = EQProfile(
            name: "Stereo analysis",
            mode: .convolution,
            channelMode: .stereo,
            filters: [],
            leftPreampDB: -2,
            leftFilters: [],
            rightPreampDB: -4,
            rightFilters: [],
            leftConvolution: leftSource,
            rightConvolution: rightSource
        )

        let analysis = try await EQAnalysisSnapshot.analyze(
            profile: profile,
            sampleRate: sampleRate
        )

        #expect(analysis.signature == EQAnalysisSignature(
            profile: profile,
            sampleRate: sampleRate
        ))
        #expect(analysis.channelMode == .stereo)
        #expect(analysis.recommendedPreampDB == (try EQProfileAnalysis.recommendedPreampDB(
            profile: profile,
            sampleRate: sampleRate,
            cancellationCheck: {}
        )))
        #expect(analysis.maximumUsableFrequency == EQRouteFrequencyPolicy.maximumUsableFrequency(
            sampleRate: sampleRate
        ))
        #expect(analysis.inactiveEnabledFilterCount == EQRouteFrequencyPolicy.inactiveEnabledFilterCount(
            profile: profile,
            sampleRate: sampleRate
        ))
        #expect(analysis.linkedPoints.isEmpty)
        #expect(analysis.leftPoints == FrequencyResponse.points(
            for: leftSource,
            preampDB: profile.leftPreampDB,
            sampleRate: sampleRate,
            cancellationCheck: {}
        ))
        #expect(analysis.rightPoints == FrequencyResponse.points(
            for: rightSource,
            preampDB: profile.rightPreampDB,
            sampleRate: sampleRate,
            cancellationCheck: {}
        ))
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

    @Test
    func preampOnlyUpdateReusesPreparedImpulseResponseAnalysis() async throws {
        let profile = impulseResponseProfile(samples: (0..<1_024).map { index in
            Float(0.2 * sin(2 * Double.pi * Double(index) / 37))
        })
        let analysis = try await EQAnalysisSnapshot.analyze(
            profile: profile,
            sampleRate: 48_000
        )
        var updatedProfile = profile
        updatedProfile.preampDB = -7.25

        let updated = try #require(analysis.updatingPreamp(
            profile: updatedProfile,
            sampleRate: 48_000
        ))
        let reference = try await EQAnalysisSnapshot.analyze(
            profile: updatedProfile,
            sampleRate: 48_000
        )

        #expect(updated == reference)
    }

    @Test
    func preampUpdateRejectsChangedResponseContent() async throws {
        let profile = impulseResponseProfile(samples: [1, 0.5])
        let analysis = try await EQAnalysisSnapshot.analyze(
            profile: profile,
            sampleRate: 48_000
        )
        var changedProfile = profile
        changedProfile.convolution = .impulseResponse(ImpulseResponseSource(
            sampleRate: 48_000,
            samples: [1, 0.25]
        ))

        #expect(analysis.updatingPreamp(
            profile: changedProfile,
            sampleRate: 48_000
        ) == nil)
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
