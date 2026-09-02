import Observation

@MainActor
@Observable
final class ProfileImportModel {
    enum Phase: Equatable {
        case idle
        case preparing
        case committing
    }

    private(set) var phase = Phase.idle
    var errorMessage: String?
    @ObservationIgnored private var commitTask: Task<Void, Never>?

    var isBusy: Bool {
        phase != .idle
    }

    var isCommitInFlight: Bool {
        phase == .committing
    }

    // `prepare` runs while the import can still be cancelled; `operation` is the
    // point of no return and is reported through `isCommitInFlight`.
    func commit<Prepared>(
        preparing prepare: @escaping @MainActor () async throws -> Prepared,
        _ operation: @escaping @MainActor (Prepared) async -> String?,
        onSuccess: @escaping @MainActor () -> Void
    ) {
        guard phase == .idle else {
            return
        }
        errorMessage = nil
        phase = .preparing
        commitTask = Task {
            do {
                let prepared = try await prepare()
                try Task.checkCancellation()
                phase = .committing
                let importError = await operation(prepared)
                try Task.checkCancellation()
                if let importError {
                    errorMessage = importError
                } else {
                    onSuccess()
                }
            } catch where Task.isCancelled {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
            phase = .idle
        }
    }

    func cancel() {
        commitTask?.cancel()
        commitTask = nil
        phase = .idle
    }
}
