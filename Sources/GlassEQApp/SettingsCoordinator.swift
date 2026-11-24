import AppKit
import Darwin
import Foundation
import GlassEQCore
import GlassEQSettingsIPC
import GlassEQSettingsUI
import Security
import os

enum SettingsOpenDisposition: Equatable {
    case helper
    case inProcessFallback(reason: String)
    case activeInProcessFallback
}

private let settingsLogger = Logger(subsystem: "com.glasseq.app", category: "Settings")

struct SettingsHelperLaunch {
    var process: Process
    var input: Pipe
    var output: Pipe
    var error: Pipe
}

protocol SettingsHelperLaunching {
    func launch(
        executableURL: URL,
        arguments: [String],
        terminationHandler: @escaping @Sendable (Process) -> Void
    ) throws -> SettingsHelperLaunch
}

struct ProcessSettingsHelperLauncher: SettingsHelperLaunching {
    func launch(
        executableURL: URL,
        arguments: [String],
        terminationHandler: @escaping @Sendable (Process) -> Void
    ) throws -> SettingsHelperLaunch {
        let process = Process()
        let helperInput = Pipe()
        let helperOutput = Pipe()
        let helperError = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = helperInput.fileHandleForReading
        process.standardOutput = helperOutput.fileHandleForWriting
        process.standardError = helperError.fileHandleForWriting
        process.terminationHandler = terminationHandler
        try process.run()
        return SettingsHelperLaunch(
            process: process,
            input: helperInput,
            output: helperOutput,
            error: helperError
        )
    }
}

protocol SettingsHelperLaunchValidating {
    func validatedExecutableURL(for helperURL: URL) throws -> URL
    func validateRunningProcess(processIdentifier: pid_t, expectedHelperURL: URL) throws
}

struct DefaultSettingsHelperLaunchValidator: SettingsHelperLaunchValidating {
    func validatedExecutableURL(for helperURL: URL) throws -> URL {
        try SettingsHelperVerifier.validatedExecutableURL(for: helperURL)
    }

    func validateRunningProcess(processIdentifier: pid_t, expectedHelperURL: URL) throws {
        try SettingsHelperVerifier.validateRunningProcess(
            processIdentifier: processIdentifier,
            expectedHelperURL: expectedHelperURL
        )
    }
}

@MainActor
final class SettingsCoordinator: NSObject {
    private struct ActiveCommand {
        var token: UUID
        var isFileImportPicker: Bool
        var task: Task<Void, Never>
    }

    private weak var model: GlassEQAppModel?
    private let helperLauncher: any SettingsHelperLaunching
    private let helperValidator: any SettingsHelperLaunchValidating
    private let settingsHelperURLProvider: () throws -> URL
    private let fileImportPicker: @MainActor (SettingsFileImportMode) async throws -> SettingsFileImportSelectionDTO?
    private var launchToken: String?
    private var runningApplication: NSRunningApplication?
    private var helperProcess: Process?
    private var pipeWriter: FileHandle?
    private var pipeReader: FileHandle?
    private var pipeErrorReader: FileHandle?
    private var pipeReadPump: SettingsPipeReadPump?
    private var pipeReadDelivery: SettingsPipeOrderedMainActorDelivery?
    private var pipeWritePump: SettingsPipeWritePump?
    private enum ConnectionPhase {
        case waitingForReady, acknowledgingReady, ready
    }

    private var connectionPhase = ConnectionPhase.waitingForReady
    private var pendingFocusRequest = false
    private var pendingSectionRequest: SettingsSection?
    private var lastSentSnapshot: SettingsSnapshot?
    private var commandTasks: [String: ActiveCommand] = [:]

    init(
        model: GlassEQAppModel,
        helperLauncher: any SettingsHelperLaunching = ProcessSettingsHelperLauncher(),
        helperValidator: any SettingsHelperLaunchValidating = DefaultSettingsHelperLaunchValidator(),
        settingsHelperURLProvider: (() throws -> URL)? = nil,
        fileImportPicker:
            @escaping @MainActor (SettingsFileImportMode) async throws -> SettingsFileImportSelectionDTO? = { mode in
                try await SettingsFileImportPicker.choose(mode: mode)
            }
    ) {
        self.model = model
        self.helperLauncher = helperLauncher
        self.helperValidator = helperValidator
        self.settingsHelperURLProvider = settingsHelperURLProvider ?? { try Self.defaultSettingsHelperURL() }
        self.fileImportPicker = fileImportPicker
        super.init()
    }

    @discardableResult
    func openSettings(section: SettingsSection? = nil) -> SettingsOpenDisposition {
        if let helperProcess, helperProcess.isRunning {
            if connectionPhase == .ready {
                if let section {
                    send(.sectionRequested(section))
                } else {
                    send(.focusRequested)
                }
            } else {
                pendingFocusRequest = true
                pendingSectionRequest = section
            }
            focusSettings()
            return .helper
        }

        if helperProcess != nil {
            cleanupSession(terminateHelper: false)
        }
        do {
            let token = try prepareSession()
            pendingFocusRequest = true
            pendingSectionRequest = section
            try launchHelper(token: token)
            return .helper
        } catch {
            let reason = error.localizedDescription
            settingsLogger.error(
                "Settings helper failed to launch; using in-process fallback: \(reason, privacy: .public)")
            cleanupSession(terminateHelper: true)
            return .inProcessFallback(reason: reason)
        }
    }

    func shutdown() {
        send(.shutdown)
        cleanupSession(terminateHelper: true)
    }

    func shutdownAndWait() async {
        send(.shutdown)
        await cleanupSessionAndWait(terminateHelper: true)
    }

    func cancelPendingFileImportPickers() async {
        let commands = commandTasks.filter(\.value.isFileImportPicker)
        for (requestID, command) in commands {
            guard commandTasks[requestID]?.token == command.token else {
                continue
            }
            commandTasks[requestID] = nil
            command.task.cancel()
            sendError("GlassEQ is shutting down.", requestID: requestID)
        }
        for command in commands.values {
            await command.task.value
        }
    }

    func modelDidChange() {
        guard connectionPhase != .waitingForReady,
            let model
        else {
            return
        }
        sendSnapshotUpdate(model.settingsSnapshot())
    }

    func metricsDidChange() {
        guard connectionPhase != .waitingForReady,
            let model
        else {
            return
        }
        let metrics = model.settingsMetricsSnapshot()
        guard lastSentSnapshot?.metrics != metrics else {
            return
        }
        if var snapshot = lastSentSnapshot {
            snapshot.metrics = metrics
            lastSentSnapshot = snapshot
        }
        send(.metricsChanged(metrics))
    }

    private func prepareSession() throws -> String {
        let token = try Self.makeSessionToken()
        launchToken = token
        connectionPhase = .waitingForReady
        pendingFocusRequest = false
        pendingSectionRequest = nil
        lastSentSnapshot = nil
        return token
    }

    private static func makeSessionToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw SettingsCommandFailure(message: localized("Secure random token generation failed: \(status)"))
        }
        return Data(bytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func launchHelper(token: String) throws {
        let helperURL = try settingsHelperURLProvider()
        let executableURL = try helperValidator.validatedExecutableURL(for: helperURL)
        let launch = try helperLauncher.launch(
            executableURL: executableURL,
            arguments: [
                "--glasseq-main-pid", String(ProcessInfo.processInfo.processIdentifier),
            ],
            terminationHandler: { [weak self] process in
                Task { @MainActor in
                    self?.handleHelperTermination(process)
                }
            }
        )
        let process = launch.process
        let helperInput = launch.input
        let helperOutput = launch.output
        let helperError = launch.error
        helperProcess = process
        pipeWriter = helperInput.fileHandleForWriting
        pipeWritePump = SettingsPipeWritePump(
            label: "com.glasseq.settings-coordinator.pipe-write",
            fileHandle: helperInput.fileHandleForWriting
        )
        pipeReader = helperOutput.fileHandleForReading
        pipeErrorReader = helperError.fileHandleForReading
        installPipeReader(helperOutput.fileHandleForReading, sessionToken: token)
        pipeErrorReader?.readabilityHandler = { handle in
            _ = handle.availableData
        }
        runningApplication = NSRunningApplication(processIdentifier: process.processIdentifier)
        do {
            try helperValidator.validateRunningProcess(
                processIdentifier: process.processIdentifier,
                expectedHelperURL: helperURL
            )
            writePipeMessage(.bootstrap(sessionToken: token))
            focusSettings()
        } catch {
            cleanupSession(terminateHelper: true)
            throw error
        }
    }

    private static func defaultSettingsHelperURL() throws -> URL {
        let bundleURL = Bundle.main.bundleURL
        let helperURL: URL
        if bundleURL.pathExtension == "app" {
            helperURL =
                bundleURL
                .appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("Helpers", isDirectory: true)
                .appendingPathComponent("GlassEQSettings.app", isDirectory: true)
        } else {
            helperURL =
                bundleURL
                .deletingLastPathComponent()
                .appendingPathComponent("GlassEQSettings.app", isDirectory: true)
        }
        guard FileManager.default.fileExists(atPath: helperURL.path) else {
            throw SettingsCommandFailure(message: "GlassEQSettings.app was not found in the app bundle.")
        }
        return helperURL
    }

    #if DEBUG
        var hasActiveSessionResourcesForTesting: Bool {
            helperProcess != nil || pipeWriter != nil || pipeReader != nil || pipeErrorReader != nil
                || pipeReadPump != nil || pipeWritePump != nil || launchToken != nil || runningApplication != nil
        }

        var isHelperReadyForTesting: Bool {
            connectionPhase == .ready
        }
    #endif

    private func perform(_ command: SettingsCommand) async throws -> SettingsCommandResponse {
        guard let model else {
            throw SettingsCommandFailure(message: "GlassEQ is shutting down.")
        }
        return try await model.performSettingsCommand(command, picker: fileImportPicker)
    }

    private func focusSettings() {
        runningApplication?.activate(options: [.activateAllWindows])
    }

    private func send(_ event: SettingsEvent) {
        guard connectionPhase != .waitingForReady else {
            return
        }
        guard let launchToken else {
            return
        }
        writePipeMessage(.event(sessionToken: launchToken, event: event))
    }

    private func installPipeReader(_ readHandle: FileHandle, sessionToken: String) {
        let delivery = SettingsPipeOrderedMainActorDelivery(
            label: "com.glasseq.settings-coordinator.pipe-read.delivery"
        )
        let pump = SettingsPipeReadPump(
            label: "com.glasseq.settings-coordinator.pipe-read",
            onMessages: { [weak self, delivery] result in
                delivery.enqueue {
                    switch result {
                    case .success(let messages):
                        self?.handlePipeMessages(messages)
                    case .failure(let error):
                        self?.failPipeSession(error)
                    }
                }
            },
            onEndOfFile: { [weak self, delivery] in
                delivery.enqueue {
                    self?.handlePipeEndOfFile(sessionToken: sessionToken)
                }
            }
        )
        pipeReadDelivery = delivery
        pipeReadPump = pump
        pump.install(on: readHandle)
    }

    private func handleHelperTermination(_ process: Process) {
        guard helperProcess === process else {
            return
        }
        handleHelperExitBeforeConnectionIfNeeded()
    }

    private func handlePipeEndOfFile(sessionToken: String) {
        guard launchToken == sessionToken else {
            return
        }
        handleHelperExitBeforeConnectionIfNeeded()
    }

    private func handleHelperExitBeforeConnectionIfNeeded() {
        let shouldUseFallback = connectionPhase != .ready
        let section = pendingSectionRequest
        cleanupSession(terminateHelper: false)
        guard shouldUseFallback else {
            return
        }
        model?.requestInProcessSettingsPresentation(
            statusMessage: localized("Settings helper exited before connecting. Opened Settings in GlassEQ instead."),
            section: section
        )
    }

    private func handlePipeMessages(_ messages: [SettingsPipeMessage]) {
        do {
            for message in messages {
                try handlePipeMessage(message)
            }
        } catch {
            failPipeSession(error)
        }
    }

    private func handlePipeMessage(_ message: SettingsPipeMessage) throws {
        guard let launchToken else {
            throw SettingsPipeError.sessionTokenMismatch
        }
        try message.validateSessionToken(launchToken)

        switch message {
        case .bootstrap:
            break
        case let .request(_, id, .connect, _):
            handleConnect(requestID: id)
        case let .request(_, id, .ready, _):
            handleReady(requestID: id)
        case let .request(_, id, .command, command):
            guard let command else {
                sendError("Settings IPC command payload was missing.", requestID: id)
                return
            }
            handleCommand(command, requestID: id)
        case let .request(_, id, .cancel, _):
            cancelCommand(requestID: id)
        case .request(_, _, .disconnect, _):
            cleanupSession(terminateHelper: false)
        case .response, .event:
            break
        }
    }

    private func handleConnect(requestID: String) {
        guard let model else {
            sendError("GlassEQ is shutting down.", requestID: requestID)
            return
        }
        let snapshot = model.settingsSnapshot()
        lastSentSnapshot = snapshot
        sendResponse(SettingsCommandResponse(snapshot: snapshot), requestID: requestID)
    }

    private func handleReady(requestID: String) {
        guard connectionPhase == .waitingForReady else {
            return
        }
        connectionPhase = .acknowledgingReady
        sendResponse(SettingsCommandResponse(), requestID: requestID) { [weak self] in
            guard let self, connectionPhase == .acknowledgingReady else {
                return
            }
            connectionPhase = .ready
            if pendingFocusRequest {
                pendingFocusRequest = false
                if let pendingSectionRequest {
                    self.pendingSectionRequest = nil
                    send(.sectionRequested(pendingSectionRequest))
                } else {
                    send(.focusRequested)
                }
            }
        }
        // The writer preserves enqueue order. Catch up before another command can enqueue its reply.
        if let model {
            sendSnapshotUpdate(model.settingsSnapshot())
        }
    }

    private func handleCommand(_ command: SettingsCommand, requestID: String) {
        guard commandTasks[requestID] == nil else {
            sendError("Settings IPC request identifier was reused.", requestID: requestID)
            return
        }
        guard let commandSessionToken = launchToken else {
            return
        }
        let commandToken = UUID()
        let isFileImportPicker = command.presentsFilePanel
        let task = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            guard !Task.isCancelled else {
                return
            }
            guard launchToken == commandSessionToken else {
                return
            }
            defer {
                if commandTasks[requestID]?.token == commandToken {
                    commandTasks[requestID] = nil
                }
            }
            do {
                let response = try await perform(command)
                try Task.checkCancellation()
                guard launchToken == commandSessionToken else { return }
                sendResponse(response, requestID: requestID)
            } catch {
                guard !Task.isCancelled,
                    !(error is CancellationError)
                else {
                    return
                }
                sendError(error.localizedDescription, requestID: requestID)
            }
        }
        commandTasks[requestID] = ActiveCommand(
            token: commandToken,
            isFileImportPicker: isFileImportPicker,
            task: task
        )
    }

    private func cancelCommand(requestID: String) {
        commandTasks[requestID]?.task.cancel()
    }

    private func sendSnapshotUpdate(_ snapshot: SettingsSnapshot) {
        guard connectionPhase != .waitingForReady else {
            return
        }

        let previous = lastSentSnapshot
        lastSentSnapshot = snapshot
        guard let previous, previous.profiles == snapshot.profiles else {
            send(.snapshotChanged(snapshot))
            return
        }

        var patch = SettingsSnapshotPatchDTO()
        var didPatch = false

        if previous.statusMessage != snapshot.statusMessage {
            patch.statusMessage = snapshot.statusMessage
            didPatch = true
        }
        if previous.isRunning != snapshot.isRunning {
            patch.isRunning = snapshot.isRunning
            didPatch = true
        }
        if previous.programmeComparison != snapshot.programmeComparison {
            patch.programmeComparison = snapshot.programmeComparison
            didPatch = true
        }
        if previous.selectedProfileID != snapshot.selectedProfileID {
            patch.selectedProfileID = snapshot.selectedProfileID
            didPatch = true
        }
        if previous.draftProfile != snapshot.draftProfile {
            patch.draftProfile = snapshot.draftProfile
            didPatch = true
        }
        if previous.activeProfileID != snapshot.activeProfileID {
            patch.activeProfileID = snapshot.activeProfileID
            didPatch = true
        }
        if previous.activeProfileMatchesLibrary != snapshot.activeProfileMatchesLibrary {
            patch.activeProfileMatchesLibrary = snapshot.activeProfileMatchesLibrary
            didPatch = true
        }
        if previous.activeProfileName != snapshot.activeProfileName {
            patch.activeProfileName = snapshot.activeProfileName
            didPatch = true
        }
        if previous.fallbackProfileID != snapshot.fallbackProfileID {
            patch.fallbackProfileID = snapshot.fallbackProfileID
            didPatch = true
        }
        if previous.currentOutputName != snapshot.currentOutputName
            || previous.currentOutputUID != snapshot.currentOutputUID
            || previous.currentOutputSampleRate != snapshot.currentOutputSampleRate
            || previous.currentOutputChannelCount != snapshot.currentOutputChannelCount
            || previous.currentOutputBufferFrameSize != snapshot.currentOutputBufferFrameSize
        {
            patch.currentOutput = SettingsOutputDTO(
                name: snapshot.currentOutputName,
                uid: snapshot.currentOutputUID,
                sampleRate: snapshot.currentOutputSampleRate,
                channelCount: snapshot.currentOutputChannelCount,
                bufferFrameSize: snapshot.currentOutputBufferFrameSize
            )
            didPatch = true
        }
        if previous.currentProcessingSampleRate != snapshot.currentProcessingSampleRate {
            patch.currentProcessingSampleRate = snapshot.currentProcessingSampleRate
            didPatch = true
        }
        if previous.currentOutputMappedProfileID != snapshot.currentOutputMappedProfileID {
            if let profileID = snapshot.currentOutputMappedProfileID {
                patch.currentOutputMappedProfileID = .set(profileID)
            } else {
                patch.currentOutputMappedProfileID = .clear
            }
            didPatch = true
        }
        if previous.aggregateBuffer != snapshot.aggregateBuffer {
            patch.aggregateBuffer = snapshot.aggregateBuffer
            didPatch = true
        }
        if previous.profileStoreProtection != snapshot.profileStoreProtection {
            patch.profileStoreProtection = snapshot.profileStoreProtection
            didPatch = true
        }

        if didPatch {
            send(.snapshotPatched(patch))
        }
        if previous.metrics != snapshot.metrics {
            send(.metricsChanged(snapshot.metrics))
        }
    }

    private func sendResponse(
        _ response: SettingsCommandResponse,
        requestID: String,
        onSuccess: (@MainActor @Sendable () -> Void)? = nil
    ) {
        guard let launchToken else {
            return
        }
        writePipeMessage(
            .response(sessionToken: launchToken, id: requestID, response: response, error: nil),
            onSuccess: onSuccess
        )
    }

    private func sendError(_ message: String, requestID: String) {
        guard let launchToken else {
            return
        }
        writePipeMessage(.response(sessionToken: launchToken, id: requestID, response: nil, error: message))
    }

    private func writePipeMessage(
        _ message: SettingsPipeMessage,
        onSuccess: (@MainActor @Sendable () -> Void)? = nil
    ) {
        guard let pipeWritePump else {
            failPipeSession(SettingsCommandFailure(message: localized("Settings IPC pipe is not connected.")))
            return
        }
        let expectedToken = message.sessionToken
        let expectedPump = pipeWritePump
        pipeWritePump.enqueue(message) { [weak self] result in
            Task { @MainActor in
                guard let self,
                    self.launchToken == expectedToken,
                    self.pipeWritePump === expectedPump
                else {
                    return
                }
                switch result {
                case .success:
                    onSuccess?()
                case .failure(let error):
                    self.failPipeSession(
                        SettingsCommandFailure(
                            message: localized("Settings IPC write failed: \(error.localizedDescription)")
                        ))
                }
            }
        }
    }

    private func failPipeSession(_ error: Error) {
        let shouldUseFallback = launchToken != nil && connectionPhase != .ready
        let section = pendingSectionRequest
        cleanupSession(terminateHelper: true)
        if shouldUseFallback {
            model?.requestInProcessSettingsPresentation(
                statusMessage: localized(
                    "Settings IPC failed before connecting: \(error.localizedDescription). Opened Settings in GlassEQ instead."
                ),
                section: section
            )
        } else {
            statusMessageForIPCFailure(error)
        }
    }

    private func statusMessageForIPCFailure(_ error: Error) {
        model?.statusMessage = localized("Settings IPC failed: \(error.localizedDescription)")
        model?.notifyModelDidChange()
    }

    @discardableResult
    private func cleanupSession(terminateHelper: Bool) -> Task<Void, Never>? {
        model?.cancelLibraryImport()
        let hadSession = launchToken != nil
        let processToTerminate = terminateHelper ? helperProcess : nil
        let writePumpToDrain = pipeWritePump
        let writerToCloseDirectly = writePumpToDrain == nil ? pipeWriter : nil
        let commandTasksToCancel = commandTasks.values.map(\.task)
        commandTasks.removeAll()
        commandTasksToCancel.forEach { $0.cancel() }
        pipeReadDelivery?.invalidate()
        pipeReadDelivery = nil
        pipeReadPump?.invalidate(handle: pipeReader)
        pipeReadPump = nil
        pipeWritePump = nil
        pipeErrorReader?.readabilityHandler = nil
        try? pipeReader?.close()
        try? pipeErrorReader?.close()
        if let writerToCloseDirectly {
            try? writerToCloseDirectly.close()
        }
        pipeReader = nil
        pipeErrorReader = nil
        pipeWriter = nil
        launchToken = nil
        pendingFocusRequest = false
        pendingSectionRequest = nil
        lastSentSnapshot = nil
        runningApplication = nil
        helperProcess = nil
        connectionPhase = .waitingForReady
        if hadSession {
            model?.stopMetricsPolling()
            model?.stopProgrammeComparison()
        }
        if writePumpToDrain != nil || processToTerminate != nil || !commandTasksToCancel.isEmpty {
            return Task {
                for task in commandTasksToCancel {
                    await task.value
                }
                if let writePumpToDrain {
                    _ = await writePumpToDrain.drainAndClose()
                }
                if let processToTerminate {
                    await SettingsHelperTerminator.terminate(process: processToTerminate).value
                }
            }
        }
        return nil
    }

    private func cleanupSessionAndWait(terminateHelper: Bool) async {
        let terminationTask = cleanupSession(terminateHelper: terminateHelper)
        await terminationTask?.value
    }
}

private enum SettingsHelperTerminator {
    static func terminate(process: Process) -> Task<Void, Never> {
        let terminator = ProcessTerminator(process: process)
        return Task.detached(priority: .utility) {
            await terminator.run()
        }
    }

    private final class ProcessTerminator: @unchecked Sendable {
        private let process: Process

        init(process: Process) {
            self.process = process
        }

        func run() async {
            if await waitForExit(seconds: 1.0) {
                return
            }
            process.terminate()
            if await waitForExit(seconds: 0.5) {
                return
            }
            Darwin.kill(process.processIdentifier, SIGKILL)
        }

        private func waitForExit(seconds: Double) async -> Bool {
            let deadline = ContinuousClock.now + .milliseconds(Int(seconds * 1_000))
            while ContinuousClock.now < deadline {
                if !process.isRunning {
                    return true
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
            return !process.isRunning
        }
    }
}

struct SettingsCodeSignatureInfo: Equatable, Sendable {
    var signingIdentifier: String?
    var teamIdentifier: String?
}

protocol SettingsCodeSigningValidating {
    func signatureInfo(for url: URL) throws -> SettingsCodeSignatureInfo
    func signatureInfo(forProcessIdentifier processIdentifier: pid_t) throws -> SettingsCodeSignatureInfo
}

enum SettingsHelperVerifier {
    static let hostBundleIdentifier = SettingsBundleIdentity.host
    static let helperBundleIdentifier = SettingsBundleIdentity.helper

    static func validatedExecutableURL(
        for helperURL: URL,
        hostBundleURL: URL = Bundle.main.bundleURL,
        fileManager: FileManager = .default,
        codeSigningValidator: any SettingsCodeSigningValidating = SecuritySettingsCodeSigningValidator()
    ) throws -> URL {
        let standardizedHelperURL = helperURL.standardizedFileURL
        let standardizedHostURL = hostBundleURL.standardizedFileURL

        guard fileManager.fileExists(atPath: standardizedHelperURL.path) else {
            throw SettingsCommandFailure(message: localized("GlassEQSettings.app was not found in the app bundle."))
        }
        if standardizedHostURL.pathExtension == "app" {
            let helpersURL =
                standardizedHostURL
                .appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("Helpers", isDirectory: true)
                .standardizedFileURL
            guard standardizedHelperURL.path.hasPrefix(helpersURL.path + "/") else {
                throw SettingsCommandFailure(
                    message: localized("GlassEQSettings.app is not contained in the GlassEQ app bundle."))
            }
        }

        guard let helperBundle = Bundle(url: standardizedHelperURL),
            helperBundle.bundleIdentifier == helperBundleIdentifier
        else {
            throw SettingsCommandFailure(message: localized("GlassEQSettings.app has an unexpected bundle identifier."))
        }

        let executableURL = try helperExecutableURL(
            for: standardizedHelperURL,
            helperBundle: helperBundle,
            fileManager: fileManager
        )

        let helperSignature = try codeSigningValidator.signatureInfo(for: standardizedHelperURL)
        if let signingIdentifier = helperSignature.signingIdentifier,
            signingIdentifier != helperBundleIdentifier
        {
            throw SettingsCommandFailure(
                message: localized("GlassEQSettings.app has an unexpected code-signing identifier."))
        }

        let hostSignature: SettingsCodeSignatureInfo?
        if standardizedHostURL.pathExtension == "app" {
            hostSignature = try codeSigningValidator.signatureInfo(for: standardizedHostURL)
        } else {
            hostSignature = try? codeSigningValidator.signatureInfo(for: standardizedHostURL)
        }

        guard let hostTeamIdentifier = hostSignature?.teamIdentifier,
            !hostTeamIdentifier.isEmpty
        else {
            return executableURL
        }
        guard helperSignature.teamIdentifier == hostTeamIdentifier else {
            throw SettingsCommandFailure(
                message: localized("GlassEQSettings.app was not signed by the same team as GlassEQ."))
        }

        return executableURL
    }

    static func validateRunningProcess(
        processIdentifier: pid_t,
        expectedHelperURL: URL,
        hostBundleURL: URL = Bundle.main.bundleURL,
        fileManager: FileManager = .default,
        runningBundleURL: (pid_t) -> URL? = { NSRunningApplication(processIdentifier: $0)?.bundleURL },
        processExecutableURL: (pid_t) -> URL? = runningExecutableURL(processIdentifier:),
        codeSigningValidator: any SettingsCodeSigningValidating = SecuritySettingsCodeSigningValidator()
    ) throws {
        let standardizedExpectedHelperURL = expectedHelperURL.standardizedFileURL
        let standardizedHostURL = hostBundleURL.standardizedFileURL
        let resolvedBundleURL = runningBundleURL(processIdentifier)?.standardizedFileURL
        let bundleURL = resolvedBundleURL ?? standardizedExpectedHelperURL

        if let resolvedBundleURL,
            !isSameFile(resolvedBundleURL, standardizedExpectedHelperURL)
        {
            throw SettingsCommandFailure(
                message: localized("GlassEQSettings.app resolved to an unexpected location after launch."))
        }

        guard fileManager.fileExists(atPath: bundleURL.path),
            let helperBundle = Bundle(url: bundleURL),
            helperBundle.bundleIdentifier == helperBundleIdentifier
        else {
            throw SettingsCommandFailure(message: localized("GlassEQSettings.app could not be resolved after launch."))
        }
        let expectedExecutableURL = try helperExecutableURL(
            for: bundleURL,
            helperBundle: helperBundle,
            fileManager: fileManager
        )
        guard let actualExecutableURL = processExecutableURL(processIdentifier)?.standardizedFileURL,
            isSameFile(actualExecutableURL, expectedExecutableURL)
        else {
            throw SettingsCommandFailure(
                message: localized("GlassEQSettings executable could not be resolved after launch."))
        }

        let helperSignature = try codeSigningValidator.signatureInfo(for: bundleURL)
        if let signingIdentifier = helperSignature.signingIdentifier,
            signingIdentifier != helperBundleIdentifier
        {
            throw SettingsCommandFailure(
                message: localized("GlassEQSettings.app has an unexpected code-signing identifier."))
        }

        let processSignature = try codeSigningValidator.signatureInfo(forProcessIdentifier: processIdentifier)
        if let signingIdentifier = processSignature.signingIdentifier,
            signingIdentifier != helperBundleIdentifier
        {
            throw SettingsCommandFailure(
                message: localized("GlassEQSettings.app has an unexpected code-signing identifier."))
        }

        let hostSignature: SettingsCodeSignatureInfo?
        if standardizedHostURL.pathExtension == "app" {
            hostSignature = try codeSigningValidator.signatureInfo(for: standardizedHostURL)
        } else {
            hostSignature = try? codeSigningValidator.signatureInfo(for: standardizedHostURL)
        }
        guard let hostTeamIdentifier = hostSignature?.teamIdentifier,
            !hostTeamIdentifier.isEmpty
        else {
            return
        }
        guard helperSignature.teamIdentifier == hostTeamIdentifier else {
            throw SettingsCommandFailure(
                message: localized("GlassEQSettings.app was not signed by the same team as GlassEQ."))
        }
        if processSignature.teamIdentifier != hostTeamIdentifier {
            throw SettingsCommandFailure(
                message: localized("GlassEQSettings.app was not signed by the same team as GlassEQ."))
        }
    }

    private static func helperExecutableURL(
        for standardizedHelperURL: URL,
        helperBundle: Bundle,
        fileManager: FileManager
    ) throws -> URL {
        let executableName =
            helperBundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String ?? "GlassEQSettings"
        let executableURL =
            standardizedHelperURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent(executableName, isDirectory: false)
            .standardizedFileURL
        guard executableURL.path.hasPrefix(standardizedHelperURL.path + "/"),
            fileManager.fileExists(atPath: executableURL.path)
        else {
            throw SettingsCommandFailure(
                message: localized("GlassEQSettings executable was not found in the app bundle."))
        }
        return executableURL
    }

    private static func isSameFile(_ first: URL, _ second: URL) -> Bool {
        var firstInfo = stat()
        var secondInfo = stat()
        guard stat(first.path, &firstInfo) == 0,
            stat(second.path, &secondInfo) == 0
        else {
            return false
        }
        return firstInfo.st_dev == secondInfo.st_dev && firstInfo.st_ino == secondInfo.st_ino
    }

    private static func runningExecutableURL(processIdentifier: pid_t) -> URL? {
        var pathBuffer = [CChar](repeating: 0, count: 4_096)
        let length = proc_pidpath(processIdentifier, &pathBuffer, UInt32(pathBuffer.count))
        guard length > 0 else {
            return nil
        }
        return executableURL(pathBytes: pathBuffer.prefix(Int(length)))
    }

    static func executableURL(pathBytes: some Sequence<CChar>) -> URL? {
        guard let path = String(validating: pathBytes.lazy.prefix { $0 != 0 }, as: UTF8.self) else {
            return nil
        }
        return URL(filePath: path, directoryHint: .notDirectory).standardizedFileURL
    }
}

struct SecuritySettingsCodeSigningValidator: SettingsCodeSigningValidating {
    func signatureInfo(for url: URL) throws -> SettingsCodeSignatureInfo {
        var staticCode: SecStaticCode?
        var status = SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &staticCode)
        guard status == errSecSuccess, let staticCode else {
            throw SettingsCommandFailure(
                message: localized("Code signing validation failed for \(url.lastPathComponent): \(status)"))
        }

        let validationFlags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures)
        status = SecStaticCodeCheckValidity(staticCode, validationFlags, nil)
        guard status == errSecSuccess else {
            throw SettingsCommandFailure(
                message: localized("Code signing validation failed for \(url.lastPathComponent): \(status)"))
        }

        return try signatureInfo(from: staticCode, label: url.lastPathComponent)
    }

    func signatureInfo(forProcessIdentifier processIdentifier: pid_t) throws -> SettingsCodeSignatureInfo {
        var code: SecCode?
        let attributes = [kSecGuestAttributePid as String: processIdentifier] as CFDictionary
        var status = SecCodeCopyGuestWithAttributes(nil, attributes, SecCSFlags(), &code)
        guard status == errSecSuccess, let code else {
            throw SettingsCommandFailure(
                message: localized("Code signing validation failed for process \(processIdentifier): \(status)"))
        }

        status = SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil)
        guard status == errSecSuccess else {
            throw SettingsCommandFailure(
                message: localized("Code signing validation failed for process \(processIdentifier): \(status)"))
        }

        var staticCode: SecStaticCode?
        status = SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode)
        guard status == errSecSuccess, let staticCode else {
            throw SettingsCommandFailure(
                message: localized(
                    "Code signing information was unavailable for process \(processIdentifier): \(status)"))
        }

        return try signatureInfo(from: staticCode, label: "process \(processIdentifier)")
    }

    private func signatureInfo(from code: SecStaticCode, label: String) throws -> SettingsCodeSignatureInfo {
        var info: CFDictionary?
        let status = SecCodeCopySigningInformation(
            code,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &info
        )
        guard status == errSecSuccess,
            let dictionary = info as? [String: Any]
        else {
            throw SettingsCommandFailure(message: localized("Code signing information was unavailable for \(label)."))
        }
        return SettingsCodeSignatureInfo(
            signingIdentifier: dictionary[kSecCodeInfoIdentifier as String] as? String,
            teamIdentifier: dictionary[kSecCodeInfoTeamIdentifier as String] as? String
        )
    }
}

extension GlassEQAppModel {
    func openAggregateBufferSettings() {
        openSettings(section: .output)
    }

    @discardableResult
    func openSettings(section: SettingsSection? = nil) -> SettingsOpenDisposition {
        guard !inProcessSettingsIsPresented,
            !inProcessSettingsPresentationIsPending
        else {
            requestInProcessSettingsPresentation(section: section)
            return .activeInProcessFallback
        }
        let disposition = settingsCoordinator.openSettings(section: section)
        if case .inProcessFallback(let reason) = disposition {
            requestInProcessSettingsPresentation(
                statusMessage: localized("Settings helper unavailable: \(reason). Opened Settings in GlassEQ instead."),
                section: section
            )
        }
        return disposition
    }

    func requestInProcessSettingsPresentation(statusMessage: String? = nil, section: SettingsSection? = nil) {
        if let section {
            SettingsWindowFocus.request(section: section)
        }
        if let statusMessage {
            self.statusMessage = statusMessage
            notifyModelDidChange()
        }
        inProcessSettingsPresentationIsPending = true
        inProcessSettingsPresentationGeneration &+= 1
    }

    func inProcessSettingsDidAppear() {
        inProcessSettingsPresentationIsPending = false
        inProcessSettingsIsPresented = true
        guard fallbackEditor == nil else { return }
        let editor = GlassEQSettingsViewModel()
        editor.attach(client: InProcessSettingsClient(model: self, editor: editor), snapshot: settingsSnapshot())
        fallbackEditor = editor
    }

    func inProcessSettingsDidDisappear() {
        inProcessSettingsPresentationIsPending = false
        inProcessSettingsIsPresented = false
        cancelLibraryImport()
        fallbackEditor?.disconnect()
        fallbackEditor = nil
        stopMetricsPolling()
        stopProgrammeComparison()
    }

    func performSettingsCommand(
        _ command: SettingsCommand, from editor: GlassEQSettingsViewModel? = nil,
        picker: @MainActor (SettingsFileImportMode) async throws -> SettingsFileImportSelectionDTO? =
            SettingsFileImportPicker.choose(mode:)
    ) async throws -> SettingsCommandResponse {
        try Task.checkCancellation()
        if let editor, editor !== fallbackEditor {
            throw CancellationError()
        }
        try beginSettingsCommand()
        defer {
            finishSettingsCommand()
        }

        switch command {
        case .createProfile(let kind):
            try createProfile(kind: kind)

        case .duplicateProfile(let id):
            try duplicateProfile(id: id)

        case .deleteProfile(let id):
            try deleteProfile(id: id)

        case .applyProfile(let profile):
            try apply(profile: profile)

        case .useProfileForCurrentOutput(let profile):
            try useForCurrentOutput(profile: profile)

        case let .setOutputAssignment(outputUID, profileID):
            try setOutputAssignment(outputUID: outputUID, profileID: profileID)

        case .setFallbackProfile(let id):
            try setFallback(profile: savedProfile(id))

        case let .importProfile(format, name, text):
            let imported = try await importProfile(format: format, name: name, text: text)
            return SettingsCommandResponse(importSucceeded: imported)

        case .importParsedProfile(let profile):
            let imported = try importParsedProfile(profile)
            return SettingsCommandResponse(importSucceeded: imported)

        case .chooseImportFiles(let mode):
            return SettingsCommandResponse(fileImportSelection: try await picker(mode))

        case .showLibraryBackups:
            try showLibraryBackups()
        case .exportLibrary:
            let backup = try makeLibraryBackup()
            guard
                let url = try await LibraryBackupPanels.chooseExportDestination(
                    suggestedName: LibraryBackupFile.suggestedFilename(createdAt: backup.createdAt))
            else { break }
            try await LibraryBackupIO.saveBackup(backup, to: url)
            return SettingsCommandResponse(libraryMessage: localized("Saved the library to \(url.lastPathComponent)."))
        case .chooseLibraryBackup:
            try ensureProfileStoreWritable()
            guard let url = try await LibraryBackupPanels.chooseBackupToImport() else { break }
            let backup = try await LibraryBackupIO.read(from: url)
            try Task.checkCancellation()
            return SettingsCommandResponse(
                libraryImportPreview: try await stageLibraryImport(backup, filename: url.lastPathComponent))
        case .applyLibraryImport(let mode):
            return SettingsCommandResponse(libraryMessage: try await applyLibraryImport(mode: mode))
        case .cancelLibraryImport:
            cancelLibraryImport()
        case .startProgrammeComparison(let profile):
            try validateIncomingProfile(profile)
            try startProgrammeComparison(profile: profile)

        case .selectProgrammeComparison(let selection):
            selectProgrammeComparison(selection)

        case .stopProgrammeComparison:
            stopProgrammeComparison()

        case .resetDiagnostics:
            resetDiagnostics()

        case .setAggregateBufferMode(let mode):
            try setAggregateBufferMode(mode)

        case .retryAutomaticAggregateBuffer:
            try retryAutomaticAggregateBuffer()

        case .retryAudioEngine:
            retryAudioEngine()

        case .openPrivacySettings:
            try openPrivacySettings()

        case .startMetricsPolling:
            startMetricsPolling()

        case .stopMetricsPolling:
            stopMetricsPolling()

        case .resetUnsupportedProfileStore:
            try await resetUnsupportedProfileStore()

        case .showAbout:
            requestAboutPresentation()

        case .showSetupGuide:
            requestOnboardingPresentation()
        }
        return SettingsCommandResponse()
    }

    private func validateIncomingProfile(_ profile: EQProfile) throws {
        try ensureProfileStoreWritable()
        var store = profileStore
        if let index = store.profiles.firstIndex(where: { $0.id == profile.id }) {
            store.profiles[index] = profile
        } else {
            store.profiles.append(profile)
        }
        try ProfilePersistence.validateForCommit(store)
    }
}

@MainActor
private final class InProcessSettingsClient: SettingsCommanding {
    private weak var model: GlassEQAppModel?

    private weak var editor: GlassEQSettingsViewModel?

    init(model: GlassEQAppModel, editor: GlassEQSettingsViewModel) {
        self.model = model
        self.editor = editor
    }

    func perform(_ command: SettingsCommand) async throws -> SettingsCommandResponse {
        guard let model else {
            throw SettingsCommandFailure(message: "GlassEQ is shutting down.")
        }
        guard let editor else {
            throw CancellationError()
        }
        return try await model.performSettingsCommand(command, from: editor)
    }
}
