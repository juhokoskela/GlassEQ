import Foundation
import GlassEQSettingsIPC
import Observation

@MainActor
public protocol SettingsCommanding: AnyObject, Sendable {
    func perform(_ command: SettingsCommand) async throws -> SettingsCommandResponse
}

@MainActor
@Observable
public final class GlassEQSettingsViewModel {
    public private(set) var snapshot: SettingsSnapshotDTO
    public private(set) var snapshotVersion = 0
    public private(set) var isConnected = false
    public var commandErrorMessage: String?

    private var client: (any SettingsCommanding)?
    private var fileImportCommandTasks: [UUID: Task<SettingsCommandResponse, Error>] = [:]

    public init(snapshot: SettingsSnapshotDTO = .disconnected, client: (any SettingsCommanding)? = nil) {
        self.snapshot = snapshot
        self.client = client
    }

    public func attach(client: any SettingsCommanding, snapshot: SettingsSnapshotDTO) {
        self.client = client
        isConnected = true
        accept(snapshot: snapshot)
        commandErrorMessage = nil
    }

    public func accept(snapshot: SettingsSnapshotDTO) {
        self.snapshot = snapshot
        snapshotVersion += 1
    }

    public func accept(patch: SettingsSnapshotPatchDTO) {
        if let statusMessage = patch.statusMessage {
            snapshot.statusMessage = statusMessage
        }
        if let isRunning = patch.isRunning {
            snapshot.isRunning = isRunning
        }
        if let isPreviewing = patch.isPreviewing {
            snapshot.isPreviewing = isPreviewing
        }
        if let programmeComparison = patch.programmeComparison {
            snapshot.programmeComparison = programmeComparison
        }
        if let selectedProfileID = patch.selectedProfileID {
            snapshot.selectedProfileID = selectedProfileID
        }
        if let draftProfile = patch.draftProfile {
            snapshot.draftProfile = draftProfile
        }
        if let activeProfileID = patch.activeProfileID {
            snapshot.activeProfileID = activeProfileID
        }
        if let activeProfileName = patch.activeProfileName {
            snapshot.activeProfileName = activeProfileName
        }
        if let fallbackProfileID = patch.fallbackProfileID {
            snapshot.fallbackProfileID = fallbackProfileID
        }
        if let currentOutput = patch.currentOutput {
            snapshot.currentOutputName = currentOutput.name
            snapshot.currentOutputUID = currentOutput.uid
            snapshot.currentOutputSampleRate = currentOutput.sampleRate
            snapshot.currentOutputChannelCount = currentOutput.channelCount
            snapshot.currentOutputBufferFrameSize = currentOutput.bufferFrameSize
        }
        if let profileStoreProtection = patch.profileStoreProtection {
            snapshot.profileStoreProtection = profileStoreProtection
        }
        if let aggregateBuffer = patch.aggregateBuffer {
            snapshot.aggregateBuffer = aggregateBuffer
        }
        switch patch.currentOutputMappedProfileID {
        case .set(let profileID):
            snapshot.currentOutputMappedProfileID = profileID
        case .clear:
            snapshot.currentOutputMappedProfileID = nil
        case nil:
            break
        }
        snapshotVersion += 1
    }

    public func accept(metrics: SettingsAudioMetricsDTO) {
        snapshot.metrics = metrics
        snapshotVersion += 1
    }

    public func cancelPendingFileImportPickers() async {
        let tasks = Array(fileImportCommandTasks.values)
        tasks.forEach { $0.cancel() }
        for task in tasks {
            _ = try? await task.value
        }
    }

    @discardableResult
    public func perform(_ command: SettingsCommand) async -> SettingsCommandResponse? {
        guard let client else {
            switch command {
            case .startMetricsPolling, .stopMetricsPolling:
                return nil
            default:
                break
            }
            commandErrorMessage = "Settings is not connected to GlassEQ."
            return nil
        }

        do {
            let response: SettingsCommandResponse
            if case .chooseImportFiles = command {
                response = try await performFileImportCommand(command, using: client)
            } else {
                response = try await client.perform(command)
            }
            if let snapshot = response.snapshot {
                accept(snapshot: snapshot)
            }
            commandErrorMessage = nil
            return response
        } catch is CancellationError {
            commandErrorMessage = nil
            return nil
        } catch {
            commandErrorMessage = error.localizedDescription
            return nil
        }
    }

    private func performFileImportCommand(
        _ command: SettingsCommand,
        using client: any SettingsCommanding
    ) async throws -> SettingsCommandResponse {
        let commandID = UUID()
        let task = Task { @MainActor in
            try await client.perform(command)
        }
        fileImportCommandTasks[commandID] = task
        defer {
            fileImportCommandTasks[commandID] = nil
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { [weak self] in
            Task { @MainActor in
                self?.fileImportCommandTasks[commandID]?.cancel()
            }
        }
    }
}
