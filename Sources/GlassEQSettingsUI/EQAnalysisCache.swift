import Foundation
import GlassEQCore
import Observation

@MainActor
@Observable
final class EQAnalysisCache {
    private enum Slot: Hashable {
        case profile(UUID)
        case draft
    }

    private struct Request {
        var slot: Slot
        var profile: EQProfile
        var signature: EQAnalysisSignature
        var debounce: Bool = false
    }

    private var snapshots: [Slot: EQAnalysisSnapshot] = [:]
    @ObservationIgnored private var requests: [Request] = []
    @ObservationIgnored private var jobs: [Slot: (request: Request, task: Task<Void, Never>)] = [:]
    @ObservationIgnored private var failures: [Slot: EQAnalysisSignature] = [:]
    @ObservationIgnored private var selectedProfileID: UUID?
    @ObservationIgnored private let makeResponse: @Sendable (EQProfile, Double) async throws -> EQAnalysisSnapshot

    init(
        makeResponse: @escaping @Sendable (EQProfile, Double) async throws -> EQAnalysisSnapshot = {
            try await EQAnalysisSnapshot.response(profile: $0, sampleRate: $1)
        }
    ) {
        self.makeResponse = makeResponse
    }

    deinit {
        for job in jobs.values { job.task.cancel() }
    }

    func analysis(for profile: EQProfile, sampleRate: Double) -> EQAnalysisSnapshot? {
        let signature = EQAnalysisSignature(profile: profile, sampleRate: sampleRate)
        let draft = selectedProfileID == profile.id ? snapshots[.draft] : nil
        let stored = snapshots[.profile(profile.id)]
        if draft?.signature == signature { return draft }
        if stored?.signature == signature { return stored }
        // Keep the curve steady during edits, but never offer headroom from an older edit or route.
        guard var previous = draft ?? stored,
            previous.signature.sampleRate == signature.sampleRate,
            previous.signature.mode == signature.mode,
            previous.signature.channelMode == signature.channelMode
        else { return nil }
        previous.recommendedPreampDB = nil
        return previous
    }

    func update(profiles: [EQProfile], selected: EQProfile, sampleRate: Double) {
        let previous = requests.first
        if selectedProfileID != selected.id {
            snapshots[.draft] = nil
        }
        selectedProfileID = selected.id
        let signature = EQAnalysisSignature(profile: selected, sampleRate: sampleRate)
        requests = profiles.map {
            Request(
                slot: .profile($0.id), profile: $0, signature: EQAnalysisSignature(profile: $0, sampleRate: sampleRate))
        }
        if let index = requests.firstIndex(where: { $0.profile.id == selected.id && $0.signature == signature }) {
            requests.insert(requests.remove(at: index), at: 0)
        } else {
            requests.insert(
                Request(
                    slot: .draft, profile: selected, signature: signature,
                    debounce: previous?.profile.id == selected.id
                        && previous?.signature.mode == signature.mode
                        && previous?.signature.channelMode == signature.channelMode
                ), at: 0)
        }
        let slots = Set(requests.map(\.slot))
        snapshots = snapshots.filter { slots.contains($0.key) }
        failures = failures.filter { slots.contains($0.key) }
        for request in requests {
            let existing = snapshots[request.slot] ?? snapshots[.profile(request.profile.id)]
            if existing?.signature != request.signature,
                let updated = existing?.updatingPreamp(profile: request.profile, sampleRate: sampleRate)
            {
                snapshots[request.slot] = updated
            }
        }
        for (slot, job) in jobs
        where !requests.contains(where: {
            $0.slot == slot && $0.signature.hasSameResponseContent(as: job.request.signature)
        }) {
            job.task.cancel()
        }
        if let selected = requests.first, needsAnalysis(selected), jobs[selected.slot] == nil, jobs.count == 2 {
            jobs.values.first?.task.cancel()
        }
        startPendingAnalyses()
    }

    func stop() {
        requests.removeAll()
        for job in jobs.values { job.task.cancel() }
    }

    func waitForPendingAnalyses() async {
        while let job = jobs.values.first {
            await job.task.value
        }
    }

    private func needsAnalysis(_ request: Request) -> Bool {
        let snapshot = snapshots[request.slot]
        return failures[request.slot] != request.signature
            && (snapshot?.signature != request.signature || snapshot?.recommendedPreampDB == nil)
    }

    private func startPendingAnalyses() {
        // Two jobs bound launch work while allowing selection to interrupt background warmup.
        for request in requests where jobs[request.slot] == nil && needsAnalysis(request) {
            guard jobs.count < 2 else { break }
            let makeResponse = makeResponse
            let task = Task { [weak self] in
                do {
                    if request.debounce { try await Task.sleep(for: .milliseconds(50)) }
                    let response = try await makeResponse(request.profile, request.signature.sampleRate)
                    self?.publish(response, for: request)
                    let complete = try await response.analyzingHeadroom(profile: request.profile)
                    self?.publish(complete, for: request)
                } catch {
                    if !Task.isCancelled { self?.failures[request.slot] = request.signature }
                }
                self?.jobs[request.slot] = nil
                self?.startPendingAnalyses()
            }
            jobs[request.slot] = (request, task)
        }
    }

    private func publish(_ analysis: EQAnalysisSnapshot, for request: Request) {
        guard !Task.isCancelled,
            let current = requests.first(where: { $0.slot == request.slot }),
            let updated = analysis.updatingPreamp(
                profile: current.profile, sampleRate: current.signature.sampleRate
            )
        else { return }
        snapshots[request.slot] = updated
    }
}
