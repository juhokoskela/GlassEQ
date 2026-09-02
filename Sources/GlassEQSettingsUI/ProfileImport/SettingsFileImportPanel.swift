import AppKit
import GlassEQProfileImport
import GlassEQSettingsIPC
import UniformTypeIdentifiers

public enum SettingsFileImportPicker {
    @MainActor
    public static func choose(
        mode: SettingsFileImportMode
    ) async throws -> SettingsFileImportSelectionDTO? {
        let previousApplication = NSWorkspace.shared.frontmostApplication
        NSApp.activate()
        defer {
            if let previousApplication,
               previousApplication.processIdentifier != NSRunningApplication.current.processIdentifier {
                previousApplication.activate(from: .current, options: [.activateAllWindows])
            }
        }

        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .wav]
        panel.canChooseDirectories = false

        switch mode {
        case .single:
            panel.title = localized("Import EQ Settings")
            panel.message = localized("Choose EQ settings or a mono or stereo WAV impulse response.")
            panel.prompt = localized("Open")
            panel.allowsMultipleSelection = false
        case .stereoPair:
            panel.title = localized("Import Separate Left and Right Files")
            panel.message = localized("Choose two text files or two mono WAV files. GlassEQ will show their left and right assignment before importing them.")
            panel.prompt = localized("Choose")
            panel.allowsMultipleSelection = true
        }

        let response = try await waitForPanelResponse(
            begin: { completion in
                panel.begin(completionHandler: completion)
            },
            cancel: {
                panel.cancel(nil)
            }
        )
        guard response == .OK else {
            return nil
        }

        let urls = panel.urls
        switch mode {
        case .single:
            guard urls.count == 1 else {
                throw SettingsCommandFailure(message: localized("Select one file to import."))
            }
        case .stereoPair:
            guard urls.count == 2 else {
                throw SettingsCommandFailure(message: localized("Select exactly two files: one for the left channel and one for the right."))
            }
        }

        let loadTask = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let selection = try SettingsFileImportLoader.load(mode: mode, urls: urls)
            try Task.checkCancellation()
            return selection
        }
        return try await withTaskCancellationHandler {
            let selection = try await loadTask.value
            try Task.checkCancellation()
            return selection
        } onCancel: {
            loadTask.cancel()
        }
    }

    @MainActor
    static func waitForPanelResponse(
        begin: (@escaping (NSApplication.ModalResponse) -> Void) -> Void,
        cancel: @escaping @MainActor () -> Void
    ) async throws -> NSApplication.ModalResponse {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            let response = await withCheckedContinuation { continuation in
                begin { response in
                    continuation.resume(returning: response)
                }
            }
            try Task.checkCancellation()
            return response
        } onCancel: {
            Task { @MainActor in
                cancel()
            }
        }
    }
}
