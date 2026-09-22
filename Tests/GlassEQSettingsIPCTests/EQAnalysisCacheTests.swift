import GlassEQCore
import GlassEQSettingsIPC
import Testing
@testable import GlassEQSettingsUI

@Suite
@MainActor
struct EQAnalysisCacheTests {
    @Test
    func foregroundSharesWarmupAndClosingRejectsAnAlreadyComputedResponse() async {
        let profiles = [profile("First", gain: 2), profile("Second", gain: -4), profile("Third", gain: 6)]
        let gate = AnalysisGate()
        let cache = EQAnalysisCache { profile, rate in
            let response = try await EQAnalysisSnapshot.response(profile: profile, sampleRate: rate)
            await gate.pause()
            return response
        }
        cache.update(profiles: profiles, selected: profiles[0], sampleRate: 48_000)
        await gate.waitForTwoJobs()
        cache.update(profiles: profiles, selected: profiles[1], sampleRate: 48_000)
        #expect(await gate.started == 2)
        cache.stop()
        await gate.resume()
        await cache.waitForPendingAnalyses()
        #expect(await gate.started == 2)
        for profile in profiles {
            #expect(cache.analysis(for: profile, sampleRate: 48_000) == nil)
        }
    }

    @Test
    func warmedSelectionIsImmediatelyReadyAndDraftEditsKeepTheStoredAnalysis() async throws {
        let first = profile("First", gain: 2)
        let second = profile("Second", gain: -4)
        let cache = EQAnalysisCache()
        cache.update(profiles: [first, second], selected: first, sampleRate: 48_000)
        await cache.waitForPendingAnalyses()
        let stored = try #require(cache.analysis(for: second, sampleRate: 48_000))
        cache.update(profiles: [first, second], selected: second, sampleRate: 48_000)
        #expect(cache.analysis(for: second, sampleRate: 48_000) == stored)

        var edited = second
        edited.filters[0].gainDB = 7
        cache.update(profiles: [first, second], selected: edited, sampleRate: 48_000)
        #expect(cache.analysis(for: edited, sampleRate: 48_000)?.linkedPoints == stored.linkedPoints)
        #expect(cache.analysis(for: edited, sampleRate: 48_000)?.recommendedPreampDB == nil)
        await cache.waitForPendingAnalyses()
        #expect(
            cache.analysis(for: edited, sampleRate: 48_000)?.signature
                == EQAnalysisSignature(profile: edited, sampleRate: 48_000))

        cache.update(profiles: [first, second], selected: first, sampleRate: 48_000)
        cache.update(profiles: [first, second], selected: second, sampleRate: 48_000)
        #expect(cache.analysis(for: second, sampleRate: 48_000) == stored)
    }

    @Test
    func savedEditsAndSampleRateChangesReplaceStaleEntries() async throws {
        var saved = profile("Saved", gain: 2)
        let cache = EQAnalysisCache()
        cache.update(profiles: [saved], selected: saved, sampleRate: 48_000)
        await cache.waitForPendingAnalyses()
        saved.filters[0].gainDB = 8
        cache.update(profiles: [saved], selected: saved, sampleRate: 48_000)
        #expect(cache.analysis(for: saved, sampleRate: 48_000)?.recommendedPreampDB == nil)
        await cache.waitForPendingAnalyses()
        #expect(
            cache.analysis(for: saved, sampleRate: 48_000)
                == (try await EQAnalysisSnapshot.analyze(profile: saved, sampleRate: 48_000)))

        cache.update(profiles: [saved], selected: saved, sampleRate: 96_000)
        #expect(cache.analysis(for: saved, sampleRate: 96_000) == nil)
        await cache.waitForPendingAnalyses()
        #expect(
            cache.analysis(for: saved, sampleRate: 96_000)
                == (try await EQAnalysisSnapshot.analyze(profile: saved, sampleRate: 96_000)))
    }

    @Test
    func preampChangesReuseCompleteAnalysisSynchronously() async throws {
        let saved = profile("Saved", gain: 2)
        let cache = EQAnalysisCache()
        cache.update(profiles: [saved], selected: saved, sampleRate: 48_000)
        await cache.waitForPendingAnalyses()
        var draft = saved
        draft.preampDB = -6
        cache.update(profiles: [saved], selected: draft, sampleRate: 48_000)
        let immediate = try #require(cache.analysis(for: draft, sampleRate: 48_000))
        #expect(immediate.recommendedPreampDB != nil)
        #expect(immediate == (try await EQAnalysisSnapshot.analyze(profile: draft, sampleRate: 48_000)))
    }

    @Test
    func rapidReplacementDeletionAndClosingCannotPublishObsoleteWork() async throws {
        let first = profile("First", gain: 2)
        let second = profile("Second", gain: -4)
        let cache = EQAnalysisCache()
        cache.update(profiles: [first, second], selected: first, sampleRate: 48_000)
        cache.update(profiles: [second], selected: second, sampleRate: 96_000)
        cache.stop()
        await cache.waitForPendingAnalyses()
        #expect(cache.analysis(for: first, sampleRate: 48_000) == nil)
        #expect(cache.analysis(for: second, sampleRate: 96_000) == nil)
        cache.update(profiles: [second], selected: second, sampleRate: 96_000)
        await cache.waitForPendingAnalyses()
        #expect(
            cache.analysis(for: second, sampleRate: 96_000)
                == (try await EQAnalysisSnapshot.analyze(profile: second, sampleRate: 96_000)))
    }

    @Test
    func controllerSelectionAndRoutePatchRefreshTheCache() async throws {
        let first = profile("First", gain: 2)
        let second = profile("Second", gain: -4)
        var snapshot = SettingsSnapshotDTO.disconnected
        snapshot.profiles = [first, second]
        snapshot.selectedProfileID = first.id
        snapshot.draftProfile = first
        snapshot.currentProcessingSampleRate = 48_000
        let model = GlassEQSettingsViewModel(snapshot: snapshot)
        let controller = SettingsController(model: model)
        controller.startAnalyses()
        await controller.analysisCache.waitForPendingAnalyses()
        controller.selectProfile(second.id)
        #expect(
            controller.analysisCache.analysis(for: controller.draftProfile, sampleRate: controller.analysisSampleRate)?
                .recommendedPreampDB != nil)
        model.accept(patch: SettingsSnapshotPatchDTO(currentProcessingSampleRate: 96_000))
        controller.refreshAnalyses()
        await controller.analysisCache.waitForPendingAnalyses()
        #expect(controller.analysisCache.analysis(for: second, sampleRate: 96_000)?.signature.sampleRate == 96_000)
        controller.stopAnalyses()
    }

    private func profile(_ name: String, gain: Double) -> EQProfile {
        EQProfile(name: name, mode: .parametric, filters: [EQFilter(kind: .peak, frequency: 1_000, gainDB: gain, q: 1)])
    }
}

private actor AnalysisGate {
    private(set) var started = 0
    private var paused: [CheckedContinuation<Void, Never>] = []
    private var observer: CheckedContinuation<Void, Never>?

    func pause() async {
        await withCheckedContinuation { continuation in
            paused.append(continuation)
            started += 1
            if started == 2 {
                observer?.resume()
                observer = nil
            }
        }
    }

    func waitForTwoJobs() async {
        guard started < 2 else { return }
        await withCheckedContinuation { observer = $0 }
    }

    func resume() {
        for continuation in paused { continuation.resume() }
        paused.removeAll()
    }
}
