import AppKit
import Darwin
import Foundation
import GlassEQCore
import GlassEQSettingsIPC
import GlassEQSettingsUI
import OSLog
import Security

private struct UncheckedSendable<Value>: @unchecked Sendable {
    var value: Value
}

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
    private var settingsConnected = false
    private var readyAcknowledgmentPending = false
    private var pendingFocusRequest = false
    private var pendingSectionRequest: SettingsSection?
    private var suppressedModelChangeDepth = 0
    private var lastSentSnapshot: SettingsSnapshot?
    private var commandTasks: [String: ActiveCommand] = [:]

    init(
        model: GlassEQAppModel,
        helperLauncher: any SettingsHelperLaunching = ProcessSettingsHelperLauncher(),
        helperValidator: any SettingsHelperLaunchValidating = DefaultSettingsHelperLaunchValidator(),
        settingsHelperURLProvider: (() throws -> URL)? = nil,
        fileImportPicker: @escaping @MainActor (SettingsFileImportMode) async throws -> SettingsFileImportSelectionDTO? = { mode in
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
            if settingsConnected {
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

        do {
            let token = try prepareSession()
            pendingFocusRequest = true
            pendingSectionRequest = section
            try launchHelper(token: token)
            return .helper
        } catch {
            let reason = error.localizedDescription
            settingsLogger.error("Settings helper failed to launch; using in-process fallback: \(reason, privacy: .public)")
            cleanupSession(terminateHelper: true)
            return .inProcessFallback(reason: reason)
        }
    }

    var hasRunningSettingsHelper: Bool {
        helperProcess?.isRunning == true
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
        guard suppressedModelChangeDepth == 0,
              let model else {
            return
        }
        sendSnapshotUpdate(model.settingsSnapshot())
    }

    func metricsDidChange() {
        guard settingsConnected,
              let model else {
            return
        }
        let metrics = SettingsAudioMetricsDTO(model.engineMetrics)
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
        settingsConnected = false
        readyAcknowledgmentPending = false
        pendingFocusRequest = false
        pendingSectionRequest = nil
        suppressedModelChangeDepth = 0
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
                "--glasseq-main-pid", String(ProcessInfo.processInfo.processIdentifier)
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
            helperURL = bundleURL
                .appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("Helpers", isDirectory: true)
                .appendingPathComponent("GlassEQSettings.app", isDirectory: true)
        } else {
            helperURL = bundleURL
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
        helperProcess != nil ||
            pipeWriter != nil ||
            pipeReader != nil ||
            pipeErrorReader != nil ||
            pipeReadPump != nil ||
            pipeWritePump != nil ||
            launchToken != nil ||
            runningApplication != nil
    }

    var isHelperReadyForTesting: Bool {
        settingsConnected
    }
    #endif

    private func perform(_ command: SettingsCommand) async throws -> SettingsCommandResponse {
        guard let model else {
            throw SettingsCommandFailure(message: "GlassEQ is shutting down.")
        }
        if let response = try await fileImportPickerResponse(
            for: command,
            model: model,
            picker: fileImportPicker
        ) {
            return response
        }
        return try await model.performSettingsCommand(command)
    }

    private func focusSettings() {
        runningApplication?.activate(options: [.activateAllWindows])
    }

    private func send(_ event: SettingsEvent) {
        guard settingsConnected else {
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
        let shouldUseFallback = !settingsConnected
        cleanupSession(terminateHelper: false)
        guard shouldUseFallback else {
            return
        }
        model?.requestInProcessSettingsPresentation(
            statusMessage: localized("Settings helper exited before connecting. Opened Settings in GlassEQ instead.")
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
        guard !settingsConnected,
              !readyAcknowledgmentPending else {
            return
        }
        readyAcknowledgmentPending = true
        sendResponse(SettingsCommandResponse(), requestID: requestID) { [weak self] in
            guard let self,
                  readyAcknowledgmentPending else {
                return
            }
            readyAcknowledgmentPending = false
            settingsConnected = true
            if let model {
                let snapshot = model.settingsSnapshot()
                lastSentSnapshot = snapshot
                send(.snapshotChanged(snapshot))
            }
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
        let isFileImportPicker: Bool
        if case .chooseImportFiles = command {
            isFileImportPicker = true
        } else {
            isFileImportPicker = false
        }
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
            let shouldSuppressModelChanges: Bool
            if case .chooseImportFiles = command {
                shouldSuppressModelChanges = false
            } else {
                shouldSuppressModelChanges = true
            }
            do {
                if shouldSuppressModelChanges {
                    suppressedModelChangeDepth += 1
                }
                let response = try await perform(command)
                try Task.checkCancellation()
                if shouldSuppressModelChanges,
                   launchToken == commandSessionToken {
                    suppressedModelChangeDepth = max(suppressedModelChangeDepth - 1, 0)
                }
                guard launchToken == commandSessionToken else {
                    return
                }
                if let snapshot = response.snapshot {
                    lastSentSnapshot = snapshot
                }
                sendResponse(response, requestID: requestID)
            } catch {
                if shouldSuppressModelChanges,
                   launchToken == commandSessionToken {
                    suppressedModelChangeDepth = max(suppressedModelChangeDepth - 1, 0)
                    if suppressedModelChangeDepth == 0, let model {
                        sendSnapshotUpdate(model.settingsSnapshot())
                    }
                }
                guard !Task.isCancelled,
                      !(error is CancellationError) else {
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
        guard settingsConnected else {
            return
        }

        guard let previous = lastSentSnapshot else {
            lastSentSnapshot = snapshot
            send(.snapshotChanged(snapshot))
            return
        }

        if previous.profiles != snapshot.profiles {
            lastSentSnapshot = snapshot
            send(.snapshotChanged(snapshot))
            return
        }

        let metricsChanged = previous.metrics != snapshot.metrics

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
        if previous.isPreviewing != snapshot.isPreviewing {
            patch.isPreviewing = snapshot.isPreviewing
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
        if previous.activeProfileName != snapshot.activeProfileName {
            patch.activeProfileName = snapshot.activeProfileName
            didPatch = true
        }
        if previous.fallbackProfileID != snapshot.fallbackProfileID {
            patch.fallbackProfileID = snapshot.fallbackProfileID
            didPatch = true
        }
        if previous.currentOutputName != snapshot.currentOutputName ||
            previous.currentOutputUID != snapshot.currentOutputUID ||
            previous.currentOutputSampleRate != snapshot.currentOutputSampleRate ||
            previous.currentOutputChannelCount != snapshot.currentOutputChannelCount ||
            previous.currentOutputBufferFrameSize != snapshot.currentOutputBufferFrameSize {
            patch.currentOutput = SettingsOutputDTO(
                name: snapshot.currentOutputName,
                uid: snapshot.currentOutputUID,
                sampleRate: snapshot.currentOutputSampleRate,
                channelCount: snapshot.currentOutputChannelCount,
                bufferFrameSize: snapshot.currentOutputBufferFrameSize
            )
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

        guard didPatch else {
            lastSentSnapshot = snapshot
            if metricsChanged {
                send(.metricsChanged(snapshot.metrics))
            }
            return
        }

        lastSentSnapshot = snapshot
        send(.snapshotPatched(patch))
        if metricsChanged {
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
                      self.pipeWritePump === expectedPump else {
                    return
                }
                switch result {
                case .success:
                    onSuccess?()
                case .failure(let error):
                    self.failPipeSession(SettingsCommandFailure(
                        message: localized("Settings IPC write failed: \(error.localizedDescription)")
                    ))
                }
            }
        }
    }

    private func failPipeSession(_ error: Error) {
        let shouldUseFallback = launchToken != nil && !settingsConnected
        cleanupSession(terminateHelper: true)
        if shouldUseFallback {
            model?.requestInProcessSettingsPresentation(
                statusMessage: localized("Settings IPC failed before connecting: \(error.localizedDescription). Opened Settings in GlassEQ instead.")
            )
        } else {
            statusMessageForIPCFailure(error)
        }
    }

    private func statusMessageForIPCFailure(_ error: Error) {
        model?.statusMessage = localized("Settings IPC failed: \(error.localizedDescription)")
        model?.notifyModelDidChangeFromCoordinator()
    }

    @discardableResult
    private func cleanupSession(terminateHelper: Bool) -> Task<Void, Never>? {
        if settingsConnected {
            model?.stopMetricsPolling()
        }
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
        suppressedModelChangeDepth = 0
        lastSentSnapshot = nil
        runningApplication = nil
        helperProcess = nil
        settingsConnected = false
        readyAcknowledgmentPending = false
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
    static let hostBundleIdentifier = "com.glasseq.app"
    static let helperBundleIdentifier = "com.glasseq.app.settings"

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
            let helpersURL = standardizedHostURL
                .appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("Helpers", isDirectory: true)
                .standardizedFileURL
            guard standardizedHelperURL.path.hasPrefix(helpersURL.path + "/") else {
                throw SettingsCommandFailure(message: localized("GlassEQSettings.app is not contained in the GlassEQ app bundle."))
            }
        }

        guard let helperBundle = Bundle(url: standardizedHelperURL),
              helperBundle.bundleIdentifier == helperBundleIdentifier else {
            throw SettingsCommandFailure(message: localized("GlassEQSettings.app has an unexpected bundle identifier."))
        }

        let executableURL = try helperExecutableURL(
            for: standardizedHelperURL,
            helperBundle: helperBundle,
            fileManager: fileManager
        )

        let helperSignature = try codeSigningValidator.signatureInfo(for: standardizedHelperURL)
        if let signingIdentifier = helperSignature.signingIdentifier,
           signingIdentifier != helperBundleIdentifier {
            throw SettingsCommandFailure(message: localized("GlassEQSettings.app has an unexpected code-signing identifier."))
        }

        let hostSignature: SettingsCodeSignatureInfo?
        if standardizedHostURL.pathExtension == "app" {
            hostSignature = try codeSigningValidator.signatureInfo(for: standardizedHostURL)
        } else {
            hostSignature = try? codeSigningValidator.signatureInfo(for: standardizedHostURL)
        }

        guard let hostTeamIdentifier = hostSignature?.teamIdentifier,
              !hostTeamIdentifier.isEmpty else {
            return executableURL
        }
        guard helperSignature.teamIdentifier == hostTeamIdentifier else {
            throw SettingsCommandFailure(message: localized("GlassEQSettings.app was not signed by the same team as GlassEQ."))
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
           resolvedBundleURL.path != standardizedExpectedHelperURL.path {
            throw SettingsCommandFailure(message: localized("GlassEQSettings.app resolved to an unexpected location after launch."))
        }

        guard fileManager.fileExists(atPath: bundleURL.path),
              let helperBundle = Bundle(url: bundleURL),
              helperBundle.bundleIdentifier == helperBundleIdentifier else {
            throw SettingsCommandFailure(message: localized("GlassEQSettings.app could not be resolved after launch."))
        }
        let expectedExecutableURL = try helperExecutableURL(
            for: bundleURL,
            helperBundle: helperBundle,
            fileManager: fileManager
        )
        guard let actualExecutableURL = processExecutableURL(processIdentifier)?.standardizedFileURL,
              actualExecutableURL.path == expectedExecutableURL.path else {
            throw SettingsCommandFailure(message: localized("GlassEQSettings executable could not be resolved after launch."))
        }

        let helperSignature = try codeSigningValidator.signatureInfo(for: bundleURL)
        if let signingIdentifier = helperSignature.signingIdentifier,
           signingIdentifier != helperBundleIdentifier {
            throw SettingsCommandFailure(message: localized("GlassEQSettings.app has an unexpected code-signing identifier."))
        }

        let processSignature = try codeSigningValidator.signatureInfo(forProcessIdentifier: processIdentifier)
        if let signingIdentifier = processSignature.signingIdentifier,
           signingIdentifier != helperBundleIdentifier {
            throw SettingsCommandFailure(message: localized("GlassEQSettings.app has an unexpected code-signing identifier."))
        }

        let hostSignature: SettingsCodeSignatureInfo?
        if standardizedHostURL.pathExtension == "app" {
            hostSignature = try codeSigningValidator.signatureInfo(for: standardizedHostURL)
        } else {
            hostSignature = try? codeSigningValidator.signatureInfo(for: standardizedHostURL)
        }
        guard let hostTeamIdentifier = hostSignature?.teamIdentifier,
              !hostTeamIdentifier.isEmpty else {
            return
        }
        guard helperSignature.teamIdentifier == hostTeamIdentifier else {
            throw SettingsCommandFailure(message: localized("GlassEQSettings.app was not signed by the same team as GlassEQ."))
        }
        if processSignature.teamIdentifier != hostTeamIdentifier {
            throw SettingsCommandFailure(message: localized("GlassEQSettings.app was not signed by the same team as GlassEQ."))
        }
    }

    private static func helperExecutableURL(
        for standardizedHelperURL: URL,
        helperBundle: Bundle,
        fileManager: FileManager
    ) throws -> URL {
        let executableName = helperBundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String ?? "GlassEQSettings"
        let executableURL = standardizedHelperURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent(executableName, isDirectory: false)
            .standardizedFileURL
        guard executableURL.path.hasPrefix(standardizedHelperURL.path + "/"),
              fileManager.fileExists(atPath: executableURL.path) else {
            throw SettingsCommandFailure(message: localized("GlassEQSettings executable was not found in the app bundle."))
        }
        return executableURL
    }

    private static func runningExecutableURL(processIdentifier: pid_t) -> URL? {
        var pathBuffer = [CChar](repeating: 0, count: 4_096)
        let length = proc_pidpath(processIdentifier, &pathBuffer, UInt32(pathBuffer.count))
        guard length > 0 else {
            return nil
        }
        let bytes = pathBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let path = String(decoding: bytes, as: UTF8.self)
        return URL(fileURLWithPath: path).standardizedFileURL
    }
}

struct SecuritySettingsCodeSigningValidator: SettingsCodeSigningValidating {
    func signatureInfo(for url: URL) throws -> SettingsCodeSignatureInfo {
        var staticCode: SecStaticCode?
        var status = SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &staticCode)
        guard status == errSecSuccess, let staticCode else {
            throw SettingsCommandFailure(message: localized("Code signing validation failed for \(url.lastPathComponent): \(status)"))
        }

        let validationFlags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures)
        status = SecStaticCodeCheckValidity(staticCode, validationFlags, nil)
        guard status == errSecSuccess else {
            throw SettingsCommandFailure(message: localized("Code signing validation failed for \(url.lastPathComponent): \(status)"))
        }

        return try signatureInfo(from: staticCode, label: url.lastPathComponent)
    }

    func signatureInfo(forProcessIdentifier processIdentifier: pid_t) throws -> SettingsCodeSignatureInfo {
        var code: SecCode?
        let attributes = [kSecGuestAttributePid as String: processIdentifier] as CFDictionary
        var status = SecCodeCopyGuestWithAttributes(nil, attributes, SecCSFlags(), &code)
        guard status == errSecSuccess, let code else {
            throw SettingsCommandFailure(message: localized("Code signing validation failed for process \(processIdentifier): \(status)"))
        }

        status = SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil)
        guard status == errSecSuccess else {
            throw SettingsCommandFailure(message: localized("Code signing validation failed for process \(processIdentifier): \(status)"))
        }

        var staticCode: SecStaticCode?
        status = SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode)
        guard status == errSecSuccess, let staticCode else {
            throw SettingsCommandFailure(message: localized("Code signing information was unavailable for process \(processIdentifier): \(status)"))
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
              let dictionary = info as? [String: Any] else {
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
        if settingsCoordinator.hasRunningSettingsHelper {
            openSettings(section: .output)
            return
        }
        SettingsWindowFocus.request(section: .output)
        requestInProcessSettingsPresentation()
    }

    @discardableResult
    func openSettings(section: SettingsSection? = nil) -> SettingsOpenDisposition {
        guard !inProcessSettingsIsPresented,
              !inProcessSettingsPresentationIsPending else {
            if let section {
                SettingsWindowFocus.request(section: section)
            }
            requestInProcessSettingsPresentation()
            return .activeInProcessFallback
        }
        let disposition = settingsCoordinator.openSettings(section: section)
        if case .inProcessFallback(let reason) = disposition {
            if let section {
                SettingsWindowFocus.request(section: section)
            }
            requestInProcessSettingsPresentation(
                statusMessage: localized("Settings helper unavailable: \(reason). Opened Settings in GlassEQ instead.")
            )
        }
        return disposition
    }

    func requestInProcessSettingsPresentation(statusMessage: String? = nil) {
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
    }

    func inProcessSettingsDidDisappear() {
        inProcessSettingsPresentationIsPending = false
        inProcessSettingsIsPresented = false
    }

    func inProcessSettingsViewModel() -> GlassEQSettingsViewModel {
        if let inProcessSettingsViewModelStorage {
            return inProcessSettingsViewModelStorage
        }

        let settingsModel = GlassEQSettingsViewModel()
        settingsModel.attach(
            client: InProcessSettingsClient(model: self),
            snapshot: settingsSnapshot()
        )
        inProcessSettingsViewModelStorage = settingsModel
        return settingsModel
    }

    func refreshInProcessSettingsSnapshot() {
        inProcessSettingsViewModelStorage?.accept(snapshot: settingsSnapshot())
    }

    func refreshInProcessSettingsMetrics() {
        inProcessSettingsViewModelStorage?.accept(metrics: SettingsAudioMetricsDTO(engineMetrics))
    }

    func notifyModelDidChangeFromCoordinator() {
        notifyModelDidChange()
    }

    func performSettingsCommand(_ command: SettingsCommand) async throws -> SettingsCommandResponse {
        try beginSettingsCommand()
        defer {
            finishSettingsCommand()
        }

        switch command {
        case .createProfile(let kind):
            try createProfile(kind: kind)
            return SettingsCommandResponse(snapshot: settingsSnapshot())

        case .duplicateProfile(let id):
            try duplicateProfile(id: id)
            return SettingsCommandResponse(snapshot: settingsSnapshot())

        case .deleteProfile(let id):
            try deleteProfile(id: id)
            return SettingsCommandResponse(snapshot: settingsSnapshot())

        case .applyProfile(let profile):
            try validateIncomingProfile(profile)
            try apply(profile: profile)
            return SettingsCommandResponse(snapshot: settingsSnapshot())

        case .useProfileForCurrentOutput(let profile):
            try validateIncomingProfile(profile)
            try useForCurrentOutput(profile: profile)
            return SettingsCommandResponse(snapshot: settingsSnapshot())

        case .setFallback(let profile):
            try validateIncomingProfile(profile)
            try setFallback(profile: profile)
            return SettingsCommandResponse(snapshot: settingsSnapshot())

        case let .importProfile(format, name, text):
            let imported = try await importProfile(format: format, name: name, text: text)
            return SettingsCommandResponse(snapshot: settingsSnapshot(), importSucceeded: imported)

        case .importParsedProfile(let profile):
            let imported = try importParsedProfile(profile)
            return SettingsCommandResponse(snapshot: settingsSnapshot(), importSucceeded: imported)

        case .chooseImportFiles:
            throw SettingsCommandFailure(message: localized("File selection is unavailable from this settings connection."))

        case .preview(let profile):
            try validateIncomingProfile(profile)
            preview(profile: profile)
            return SettingsCommandResponse(snapshot: settingsSnapshot())

        case .stopPreview:
            stopPreview()
            return SettingsCommandResponse(snapshot: settingsSnapshot())

        case .startProgrammeComparison(let profile):
            try validateIncomingProfile(profile)
            try startProgrammeComparison(profile: profile)
            return SettingsCommandResponse(snapshot: settingsSnapshot())

        case .selectProgrammeComparison(let selection):
            selectProgrammeComparison(selection)
            return SettingsCommandResponse(snapshot: settingsSnapshot())

        case .stopProgrammeComparison:
            stopProgrammeComparison()
            return SettingsCommandResponse(snapshot: settingsSnapshot())

        case .resetDiagnostics:
            resetDiagnostics()
            return SettingsCommandResponse(snapshot: settingsSnapshot())

        case .setAggregateBufferMode(let mode):
            try setAggregateBufferMode(mode)
            return SettingsCommandResponse(snapshot: settingsSnapshot())

        case .retryAutomaticAggregateBuffer:
            try retryAutomaticAggregateBuffer()
            return SettingsCommandResponse(snapshot: settingsSnapshot())

        case .retryAudioEngine:
            retryAudioEngine()
            return SettingsCommandResponse(snapshot: settingsSnapshot())

        case .openPrivacySettings:
            try openPrivacySettings()
            return SettingsCommandResponse(snapshot: settingsSnapshot())

        case .startMetricsPolling:
            startMetricsPolling()
            return SettingsCommandResponse()

        case .stopMetricsPolling:
            stopMetricsPolling()
            return SettingsCommandResponse()

        case .resetUnsupportedProfileStore:
            try await resetUnsupportedProfileStore()
            return SettingsCommandResponse(snapshot: settingsSnapshot())
        }
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

    init(model: GlassEQAppModel) {
        self.model = model
    }

    func perform(_ command: SettingsCommand) async throws -> SettingsCommandResponse {
        guard let model else {
            throw SettingsCommandFailure(message: "GlassEQ is shutting down.")
        }
        if let response = try await fileImportPickerResponse(for: command, model: model) {
            return response
        }
        return try await model.performSettingsCommand(command)
    }
}

@MainActor
func fileImportPickerResponse(
    for command: SettingsCommand,
    model: GlassEQAppModel,
    picker: @MainActor (SettingsFileImportMode) async throws -> SettingsFileImportSelectionDTO? = { mode in
        try await SettingsFileImportPicker.choose(mode: mode)
    }
) async throws -> SettingsCommandResponse? {
    guard case let .chooseImportFiles(mode) = command else {
        return nil
    }
    try model.beginSettingsCommand()
    defer {
        model.finishSettingsCommand()
    }
    return SettingsCommandResponse(fileImportSelection: try await picker(mode))
}
