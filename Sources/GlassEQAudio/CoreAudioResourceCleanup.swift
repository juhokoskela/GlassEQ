import CoreAudio
import Foundation
import Synchronization

final class CoreAudioResourceCleanupLedger: @unchecked Sendable {
    struct IOProcResource {
        var deviceID: AudioObjectID
        var ioProcID: AudioDeviceIOProcID
    }

    struct PendingResources {
        var operation: String
        var ioProcs: [IOProcResource] = []
        var aggregateDeviceIDs: [AudioObjectID] = []
        var tapIDs: [AudioObjectID] = []
        var completion: (@Sendable () -> Void)?
    }

    struct Operations: Sendable {
        let stopIOProc: @Sendable (AudioObjectID, AudioDeviceIOProcID) -> OSStatus
        let destroyIOProc: @Sendable (AudioObjectID, AudioDeviceIOProcID) -> OSStatus
        let destroyAggregate: @Sendable (AudioObjectID) -> OSStatus
        let destroyTap: @Sendable (AudioObjectID) -> OSStatus

        static let live = Operations(
            stopIOProc: AudioDeviceStop,
            destroyIOProc: AudioDeviceDestroyIOProcID,
            destroyAggregate: AudioHardwareDestroyAggregateDevice,
            destroyTap: AudioHardwareDestroyProcessTap
        )
    }

    private static let orphaned = Mutex<[PendingResources]>([])

    private struct AutomaticRetryState {
        var isScheduled = false
        var delayIndex = 0
    }

    private struct CleanupState {
        var isAttempting = false
        var inFlightCount = 0
        var pending: [PendingResources] = []
    }

    private let operations: Operations
    private let preservesFailuresOnDeinit: Bool
    private let automaticRetryDelaysMilliseconds: [Int]
    private let cleanupState = Mutex(CleanupState())
    private let automaticRetryState = Mutex(AutomaticRetryState())
    private let automaticRetryQueue = DispatchQueue(
        label: "com.glasseq.core-audio-cleanup"
    )

    init(
        operations: Operations = .live,
        preservesFailuresOnDeinit: Bool = true,
        automaticRetryDelaysMilliseconds: [Int] = [50, 100, 250, 500, 1_000]
    ) {
        self.operations = operations
        self.preservesFailuresOnDeinit = preservesFailuresOnDeinit
        self.automaticRetryDelaysMilliseconds = automaticRetryDelaysMilliseconds.filter {
            $0 > 0
        }
    }

    deinit {
        guard preservesFailuresOnDeinit else {
            return
        }
        let unresolved = cleanupState.withLock { state in
            defer { state.pending.removeAll(keepingCapacity: false) }
            return state.pending
        }
        guard !unresolved.isEmpty else {
            return
        }
        Self.orphaned.withLock { $0.append(contentsOf: unresolved) }
    }

    @discardableResult
    func dispose(_ resources: PendingResources) -> Bool {
        let ownsAttempt = cleanupState.withLock { state in
            guard !state.isAttempting else {
                state.pending.append(resources)
                return false
            }
            state.isAttempting = true
            state.inFlightCount = 1
            return true
        }
        guard ownsAttempt else {
            updateAutomaticRetryState(completed: false)
            return false
        }

        let unresolved = attempt(resources, using: operations)
        let completed = finishAttempt(unresolved.map { [$0] } ?? [])
        updateAutomaticRetryState(completed: completed)
        return completed
    }

    @discardableResult
    func retryPending() -> Bool {
        let resources = cleanupState.withLock { state -> [PendingResources]? in
            guard !state.isAttempting else {
                return nil
            }
            state.isAttempting = true
            let resources = state.pending
            state.pending.removeAll(keepingCapacity: true)
            state.inFlightCount = resources.count
            return resources
        }
        guard let resources else {
            updateAutomaticRetryState(completed: false)
            return false
        }

        if preservesFailuresOnDeinit {
            Self.retryOrphaned()
        }
        var unresolved: [PendingResources] = []
        unresolved.reserveCapacity(resources.count)
        for resource in resources {
            if let resource = attempt(resource, using: operations) {
                unresolved.append(resource)
            }
        }
        let completed = finishAttempt(unresolved)
        updateAutomaticRetryState(completed: completed)
        return completed
    }

    var pendingCount: Int {
        cleanupState.withLock { state in
            state.inFlightCount + state.pending.count
        }
    }

    static func isTerminalDestructionStatus(_ status: OSStatus) -> Bool {
        status == noErr || status == kAudioHardwareBadObjectError
    }

    private static func retryOrphaned() {
        let resources = orphaned.withLock { orphaned in
            defer { orphaned.removeAll(keepingCapacity: true) }
            return orphaned
        }
        var unresolved: [PendingResources] = []
        unresolved.reserveCapacity(resources.count)
        for resource in resources {
            if let resource = attempt(resource, using: .live) {
                unresolved.append(resource)
            }
        }
        if !unresolved.isEmpty {
            orphaned.withLock { $0.append(contentsOf: unresolved) }
        }
    }

    private static func attempt(
        _ resources: PendingResources,
        using operations: Operations
    ) -> PendingResources? {
        var resources = resources
        var remainingIOProcs: [IOProcResource] = []
        for ioProc in resources.ioProcs {
            _ = operations.stopIOProc(ioProc.deviceID, ioProc.ioProcID)
            let status = operations.destroyIOProc(ioProc.deviceID, ioProc.ioProcID)
            if !isTerminalDestructionStatus(status) {
                remainingIOProcs.append(ioProc)
            }
        }

        var destroyedAggregateIDs: Set<AudioObjectID> = []
        resources.aggregateDeviceIDs.removeAll { deviceID in
            let status = operations.destroyAggregate(deviceID)
            if isTerminalDestructionStatus(status) {
                destroyedAggregateIDs.insert(deviceID)
                return true
            }
            return false
        }
        resources.ioProcs = remainingIOProcs.filter {
            !destroyedAggregateIDs.contains($0.deviceID)
        }
        resources.tapIDs.removeAll { tapID in
            isTerminalDestructionStatus(operations.destroyTap(tapID))
        }

        guard !resources.ioProcs.isEmpty
                || !resources.aggregateDeviceIDs.isEmpty
                || !resources.tapIDs.isEmpty else {
            resources.completion?()
            return nil
        }
        return resources
    }

    private func attempt(
        _ resources: PendingResources,
        using operations: Operations
    ) -> PendingResources? {
        Self.attempt(resources, using: operations)
    }

    private func finishAttempt(_ unresolved: [PendingResources]) -> Bool {
        cleanupState.withLock { state in
            state.pending.append(contentsOf: unresolved)
            state.isAttempting = false
            state.inFlightCount = 0
            return state.pending.isEmpty
        }
    }

    private func updateAutomaticRetryState(completed: Bool) {
        if completed {
            automaticRetryState.withLock { state in
                state.delayIndex = 0
            }
            return
        }
        scheduleAutomaticRetry()
    }

    private func scheduleAutomaticRetry() {
        let delay = automaticRetryState.withLock { state -> Int? in
            guard !automaticRetryDelaysMilliseconds.isEmpty,
                  !state.isScheduled else {
                return nil
            }
            state.isScheduled = true
            return automaticRetryDelaysMilliseconds[state.delayIndex]
        }
        guard let delay else {
            return
        }
        automaticRetryQueue.asyncAfter(deadline: .now() + .milliseconds(delay)) { [weak self] in
            guard let self else {
                return
            }
            self.automaticRetryState.withLock { state in
                state.isScheduled = false
                state.delayIndex = min(
                    state.delayIndex + 1,
                    self.automaticRetryDelaysMilliseconds.count - 1
                )
            }
            self.retryPending()
        }
    }
}
