import AppKit
import Darwin
import Foundation
import GlassEQSettingsIPC
import GlassEQSettingsUI
import SwiftUI

@main
struct GlassEQSettingsApp: App {
    @NSApplicationDelegateAdaptor(SettingsAppDelegate.self) private var appDelegate
    @State private var model = GlassEQSettingsViewModel()

    var body: some Scene {
        WindowGroup(String(localized: "Configure GlassEQ")) {
            SettingsView(model: model)
                .frame(minWidth: 760, minHeight: 500)
                .onAppear {
                    appDelegate.attach(model: model)
                }
        }
        .defaultSize(width: 1180, height: 720)
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)
    }
}

@MainActor
final class SettingsAppDelegate: NSObject, NSApplicationDelegate {
    private let launchCoordinator = SettingsLaunchCoordinator()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Promote from the LSUIElement/agent launch state to a regular app so the Settings window
        // appears in the Cmd-Tab task switcher (and the Dock) while it's open. The helper
        // terminates when the window closes, so both go away with it.
        NSApplication.shared.setActivationPolicy(.regular)
        // The helper is launched as a piped subprocess, so set the Dock/Cmd-Tab icon explicitly
        // from the bundled icns (CFBundleIconFile covers the static bundle icon as well).
        if let iconURL = Bundle.main.url(forResource: "GlassEQ", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApplication.shared.applicationIconImage = icon
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        launchCoordinator.finishLaunching(arguments: CommandLine.arguments)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        launchCoordinator.disconnect()
    }

    func attach(model: GlassEQSettingsViewModel) {
        launchCoordinator.attach(model: model)
    }
}

@MainActor
protocol SettingsPipeClientConnection: SettingsCommanding {
    var token: String? { get }

    func connect() async throws -> SettingsSnapshotDTO
    func acknowledgeReady() async throws
    func disconnect()
}

@MainActor
protocol SettingsPipeClientMaking {
    func makeClient(
        launchInfo: SettingsLaunchInfo,
        model: GlassEQSettingsViewModel
    ) throws -> any SettingsPipeClientConnection
}

@MainActor
struct LiveSettingsPipeClientFactory: SettingsPipeClientMaking {
    func makeClient(
        launchInfo: SettingsLaunchInfo,
        model: GlassEQSettingsViewModel
    ) throws -> any SettingsPipeClientConnection {
        try SettingsPipeClient(launchInfo: launchInfo, model: model)
    }
}

@MainActor
final class SettingsLaunchCoordinator {
    private weak var model: GlassEQSettingsViewModel?
    private var client: (any SettingsPipeClientConnection)?
    private var pendingLaunchInfo: SettingsLaunchInfo?
    private var connectedToken: String?
    private var connectedMainProcessIdentifier: pid_t?
    private var didFinishLaunching = false
    private var connectionTask: Task<Void, Never>?
    private let clientFactory: any SettingsPipeClientMaking

    init(clientFactory: any SettingsPipeClientMaking = LiveSettingsPipeClientFactory()) {
        self.clientFactory = clientFactory
    }

    func finishLaunching(arguments: [String]) {
        didFinishLaunching = true
        pendingLaunchInfo = SettingsLaunchInfo(commandLineArguments: arguments)
        connectIfReady()
    }

    func attach(model: GlassEQSettingsViewModel) {
        self.model = model
        connectIfReady()
    }

    func disconnect() {
        connectionTask?.cancel()
        connectionTask = nil
        client?.disconnect()
        client = nil
        connectedToken = nil
        connectedMainProcessIdentifier = nil
    }

    func waitForConnectionTask() async {
        await connectionTask?.value
    }

    private func connectIfReady() {
        guard let model else {
            return
        }
        guard didFinishLaunching else {
            return
        }
        guard let pendingLaunchInfo else {
            guard !model.isConnected else {
                return
            }
            model.commandErrorMessage = "Settings was not launched by GlassEQ."
            return
        }
        guard pendingLaunchInfo.mainProcessIdentifier != connectedMainProcessIdentifier else {
            return
        }

        self.pendingLaunchInfo = nil
        connectionTask?.cancel()
        connectionTask = Task { @MainActor [weak self, weak model] in
            guard let self,
                  let model else {
                return
            }
            await self.connect(launchInfo: pendingLaunchInfo, model: model)
        }
    }

    private func connect(launchInfo: SettingsLaunchInfo, model: GlassEQSettingsViewModel) async {
        do {
            guard launchInfo.mainProcessIdentifier != connectedMainProcessIdentifier else {
                return
            }
            let client = try clientFactory.makeClient(launchInfo: launchInfo, model: model)
            let snapshot = try await client.connect()
            guard !Task.isCancelled else {
                client.disconnect()
                return
            }
            self.client = client
            connectedToken = client.token
            connectedMainProcessIdentifier = launchInfo.mainProcessIdentifier
            model.attach(client: client, snapshot: snapshot)
            try await client.acknowledgeReady()
        } catch {
            guard !Task.isCancelled else {
                return
            }
            model.commandErrorMessage = error.localizedDescription
        }
    }
}

@MainActor
final class SettingsPipeClient: NSObject, SettingsPipeClientConnection, @unchecked Sendable {
    private(set) var token: String?
    private let mainProcessIdentifier: pid_t
    private weak var model: GlassEQSettingsViewModel?
    private let input: FileHandle
    private let bootstrapTimeout: Duration
    private let requestTimeout: Duration
    private let pipeWritePump: SettingsPipeWritePump
    private let pipeReadDelivery = SettingsPipeOrderedMainActorDelivery(
        label: "com.glasseq.settings.pipe-read.delivery"
    )
    private var mainTerminationObserver: NSObjectProtocol?
    private var continuations: [String: CheckedContinuation<SettingsCommandResponse, any Error>] = [:]
    private var pipeReadPump: SettingsPipeReadPump?
    private var disconnected = false
    private var bootstrapContinuation: CheckedContinuation<String, any Error>?
    private var bootstrapTimeoutTask: Task<Void, Never>?
    private var requestTimeoutTasks: [String: Task<Void, Never>] = [:]

    fileprivate init(
        launchInfo: SettingsLaunchInfo,
        model: GlassEQSettingsViewModel,
        bootstrapTimeout: Duration = .seconds(5),
        requestTimeout: Duration = .seconds(30)
    ) throws {
        self.mainProcessIdentifier = launchInfo.mainProcessIdentifier
        self.model = model
        self.input = FileHandle.standardInput
        self.bootstrapTimeout = bootstrapTimeout
        self.requestTimeout = requestTimeout
        self.pipeWritePump = SettingsPipeWritePump(
            label: "com.glasseq.settings.pipe-write",
            fileHandle: FileHandle.standardOutput
        )
        super.init()
        try SettingsHostValidator.validate(launchInfo: launchInfo)
        installObservers()
    }

    #if DEBUG
    init(
        testingToken: String,
        model: GlassEQSettingsViewModel,
        output: FileHandle,
        requestTimeout: Duration = .seconds(30)
    ) {
        self.token = testingToken
        self.mainProcessIdentifier = getpid()
        self.model = model
        self.input = .nullDevice
        self.bootstrapTimeout = .seconds(5)
        self.requestTimeout = requestTimeout
        self.pipeWritePump = SettingsPipeWritePump(
            label: "com.glasseq.settings.pipe-write.tests",
            fileHandle: output
        )
        super.init()
    }
    #endif

    func connect() async throws -> SettingsSnapshotDTO {
        token = try await waitForBootstrapToken()
        let response = try await send(kind: .connect, timeout: requestTimeout)
        guard let snapshot = response.snapshot else {
            throw SettingsCommandFailure(message: "GlassEQ returned an empty settings snapshot.")
        }
        return snapshot
    }

    func perform(_ command: SettingsCommand) async throws -> SettingsCommandResponse {
        let timeout: Duration?
        if case .chooseImportFiles = command {
            timeout = nil
        } else {
            timeout = requestTimeout
        }
        return try await send(kind: .command, command: command, timeout: timeout)
    }

    func acknowledgeReady() async throws {
        _ = try await send(kind: .ready, timeout: requestTimeout)
    }

    func disconnect() {
        guard !disconnected else {
            return
        }
        disconnected = true
        if let token {
            writePipeMessage(.request(sessionToken: token, id: UUID().uuidString, kind: .disconnect, command: nil))
        }
        let error = SettingsCommandFailure(message: "Settings disconnected from GlassEQ.")
        bootstrapContinuation?.resume(throwing: error)
        bootstrapContinuation = nil
        bootstrapTimeoutTask?.cancel()
        bootstrapTimeoutTask = nil
        requestTimeoutTasks.values.forEach { $0.cancel() }
        requestTimeoutTasks.removeAll()
        continuations.values.forEach { $0.resume(throwing: error) }
        continuations.removeAll()
        pipeReadDelivery.invalidate()
        pipeReadPump?.invalidate(handle: input)
        pipeReadPump = nil
        Task {
            _ = await pipeWritePump.drainAndClose()
        }
        mainTerminationObserver.map(NSWorkspace.shared.notificationCenter.removeObserver)
        mainTerminationObserver = nil
    }

    private func installObservers() {
        let delivery = pipeReadDelivery
        let pump = SettingsPipeReadPump(
            label: "com.glasseq.settings.pipe-read",
            onMessages: { [weak self, delivery] result in
                delivery.enqueue {
                    switch result {
                    case .success(let messages):
                        self?.handlePipeMessages(messages)
                    case .failure(let error):
                        self?.failPending(error)
                        self?.model?.commandErrorMessage = error.localizedDescription
                        NSApplication.shared.terminate(nil)
                    }
                }
            },
            onEndOfFile: { [delivery] in
                delivery.enqueue {
                    NSApplication.shared.terminate(nil)
                }
            }
        )
        pipeReadPump = pump
        pump.install(on: input)
        mainTerminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor in
                guard let self,
                      application?.processIdentifier == self.mainProcessIdentifier else {
                    return
                }
                NSApplication.shared.terminate(nil)
            }
        }
    }

    private func send(
        kind: SettingsPipeRequestKind,
        command: SettingsCommand? = nil,
        timeout: Duration?
    ) async throws -> SettingsCommandResponse {
        guard let token else {
            throw SettingsCommandFailure(message: "Settings IPC session was not initialized.")
        }
        try Task.checkCancellation()
        let requestID = UUID().uuidString
        let response = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                continuations[requestID] = continuation
                if let timeout {
                    requestTimeoutTasks[requestID] = Task { [weak self] in
                        guard let self else {
                            return
                        }
                        try? await Task.sleep(for: timeout)
                        await MainActor.run {
                            self.cancelPendingRequest(
                                requestID,
                                token: token,
                                error: SettingsCommandFailure(message: "Settings IPC request timed out."),
                                notifyMainProcess: true
                            )
                        }
                    }
                }
                let message = SettingsPipeMessage.request(sessionToken: token, id: requestID, kind: kind, command: command)
                pipeWritePump.enqueue(message) { [weak self] result in
                    guard case .failure(let error) = result else {
                        return
                    }
                    Task { @MainActor in
                        guard let self else {
                            return
                        }
                        guard self.continuations.removeValue(forKey: requestID) != nil else {
                            return
                        }
                        self.requestTimeoutTasks.removeValue(forKey: requestID)?.cancel()
                        continuation.resume(throwing: SettingsCommandFailure(
                            message: "Settings IPC write failed: \(error.localizedDescription)"
                        ))
                    }
                }
                if Task.isCancelled {
                    cancelPendingRequest(
                        requestID,
                        token: token,
                        error: CancellationError(),
                        notifyMainProcess: true
                    )
                }
            }
        } onCancel: { [weak self] in
            Task { @MainActor in
                self?.cancelPendingRequest(
                    requestID,
                    token: token,
                    error: CancellationError(),
                    notifyMainProcess: true
                )
            }
        }
        try Task.checkCancellation()
        return response
    }

    private func cancelPendingRequest(
        _ requestID: String,
        token: String,
        error: any Error,
        notifyMainProcess: Bool
    ) {
        guard let continuation = continuations.removeValue(forKey: requestID) else {
            return
        }
        requestTimeoutTasks.removeValue(forKey: requestID)?.cancel()
        if notifyMainProcess,
           !disconnected,
           self.token == token {
            writePipeMessage(.request(
                sessionToken: token,
                id: requestID,
                kind: .cancel,
                command: nil
            ))
        }
        continuation.resume(throwing: error)
    }

    private func handlePipeMessages(_ messages: [SettingsPipeMessage]) {
        do {
            for message in messages {
                try handlePipeMessage(message)
            }
        } catch {
            failPending(error)
            model?.commandErrorMessage = error.localizedDescription
            NSApplication.shared.terminate(nil)
        }
    }

    private func handlePipeMessage(_ message: SettingsPipeMessage) throws {
        if case .bootstrap(let sessionToken) = message {
            acceptBootstrapToken(sessionToken)
            return
        }
        guard let token else {
            throw SettingsPipeError.sessionTokenMismatch
        }
        try message.validateSessionToken(token)

        switch message {
        case let .response(_, id, response, error):
            guard let continuation = continuations.removeValue(forKey: id) else {
                return
            }
            requestTimeoutTasks.removeValue(forKey: id)?.cancel()
            if let error {
                continuation.resume(throwing: SettingsCommandFailure(message: error))
                return
            }
            guard let response else {
                continuation.resume(throwing: SettingsCommandFailure(message: "GlassEQ returned an empty settings response."))
                return
            }
            continuation.resume(returning: response)
        case let .event(_, event):
            handleEvent(event)
        case .bootstrap, .request:
            break
        }
    }

    private func handleEvent(_ event: SettingsEvent) {
        guard let model else {
            return
        }

        switch event {
        case .snapshotChanged(let snapshot):
            model.accept(snapshot: snapshot)
        case .snapshotPatched(let patch):
            model.accept(patch: patch)
        case .metricsChanged(let metrics):
            model.accept(metrics: metrics)
        case .commandFailed(let failure):
            model.commandErrorMessage = failure.message
        case .focusRequested:
            SettingsWindowFocus.request()
        case .sectionRequested(let section):
            SettingsWindowFocus.request(section: section)
        case .shutdown:
            NSApplication.shared.terminate(nil)
        }
    }

    private func writePipeMessage(_ message: SettingsPipeMessage) {
        pipeWritePump.enqueue(message)
    }

    private func failPending(_ error: any Error) {
        bootstrapContinuation?.resume(throwing: error)
        bootstrapContinuation = nil
        bootstrapTimeoutTask?.cancel()
        bootstrapTimeoutTask = nil
        requestTimeoutTasks.values.forEach { $0.cancel() }
        requestTimeoutTasks.removeAll()
        continuations.values.forEach { $0.resume(throwing: error) }
        continuations.removeAll()
    }

    private func waitForBootstrapToken() async throws -> String {
        if let token {
            return token
        }
        let timeout = bootstrapTimeout
        return try await withCheckedThrowingContinuation { continuation in
            bootstrapContinuation = continuation
            bootstrapTimeoutTask?.cancel()
            bootstrapTimeoutTask = Task { [weak self] in
                guard let self else {
                    return
                }
                try? await Task.sleep(for: timeout)
                await MainActor.run {
                    guard let continuation = self.bootstrapContinuation else {
                        return
                    }
                    self.bootstrapContinuation = nil
                    continuation.resume(throwing: SettingsCommandFailure(message: "Settings IPC bootstrap timed out."))
                }
            }
        }
    }

    private func acceptBootstrapToken(_ sessionToken: String) {
        guard token == nil else {
            return
        }
        token = sessionToken
        bootstrapContinuation?.resume(returning: sessionToken)
        bootstrapContinuation = nil
        bootstrapTimeoutTask?.cancel()
        bootstrapTimeoutTask = nil
    }
}

struct SettingsLaunchInfo {
    var mainProcessIdentifier: pid_t

    init?(commandLineArguments arguments: [String]) {
        guard let pidIndex = arguments.firstIndex(of: "--glasseq-main-pid"),
              arguments.indices.contains(pidIndex + 1),
              let mainPID = Int32(arguments[pidIndex + 1]) else {
            return nil
        }
        self.mainProcessIdentifier = mainPID
    }
}

struct SettingsHostProcessSnapshot: Equatable, Sendable {
    var exists: Bool
    var bundleIdentifier: String?
    var parentProcessIdentifier: pid_t?
}

protocol SettingsHostProcessResolving {
    func snapshot(for processIdentifier: pid_t) -> SettingsHostProcessSnapshot
}

enum SettingsHostValidator {
    static let hostBundleIdentifier = "com.glasseq.app"

    static func validate(
        launchInfo: SettingsLaunchInfo,
        resolver: any SettingsHostProcessResolving = RunningApplicationHostProcessResolver()
    ) throws {
        let snapshot = resolver.snapshot(for: launchInfo.mainProcessIdentifier)
        guard snapshot.exists else {
            throw SettingsCommandFailure(message: "GlassEQ is no longer running.")
        }
        if let parentProcessIdentifier = snapshot.parentProcessIdentifier,
           parentProcessIdentifier > 1,
           parentProcessIdentifier != launchInfo.mainProcessIdentifier {
            throw SettingsCommandFailure(message: "Settings was not launched by the current GlassEQ process.")
        }
        if let bundleIdentifier = snapshot.bundleIdentifier,
           !bundleIdentifier.isEmpty,
           bundleIdentifier != hostBundleIdentifier {
            throw SettingsCommandFailure(message: "Settings was launched by an unexpected host application.")
        }
    }
}

struct RunningApplicationHostProcessResolver: SettingsHostProcessResolving {
    func snapshot(for processIdentifier: pid_t) -> SettingsHostProcessSnapshot {
        let application = NSRunningApplication(processIdentifier: processIdentifier)
        let processExists = application != nil || Darwin.kill(processIdentifier, 0) == 0
        return SettingsHostProcessSnapshot(
            exists: processExists,
            bundleIdentifier: application?.bundleIdentifier,
            parentProcessIdentifier: Darwin.getppid()
        )
    }
}
