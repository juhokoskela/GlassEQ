import AppKit
import GlassEQSettingsIPC
import SwiftUI

extension Notification.Name {
    static let glassEQBringSettingsToFront = Notification.Name("com.glasseq.bringSettingsToFront")
}

@MainActor
public enum SettingsWindowFocus {
    private static var pendingSection: SettingsSection?

    public static func request(section: SettingsSection? = nil) {
        if let section {
            pendingSection = section
        }
        NotificationCenter.default.post(
            name: .glassEQBringSettingsToFront,
            object: section
        )
    }

    static func consumePendingSection() -> SettingsSection? {
        defer {
            pendingSection = nil
        }
        return pendingSection
    }
}

// Fronts the settings window when it opens and whenever another part of the app asks for it.
// Also takes initial keyboard focus so no text field starts out editing.
struct SettingsWindowFocusBridge: NSViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> FirstResponderSinkView {
        let coordinator = context.coordinator
        let view = FirstResponderSinkView()
        coordinator.view = view
        coordinator.installObserver()
        view.onMoveToWindow = {
            coordinator.windowDidAttach()
        }
        return view
    }

    func updateNSView(_ view: FirstResponderSinkView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject {
        weak var view: FirstResponderSinkView?
        private var didInitialFront = false

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        func installObserver() {
            NotificationCenter.default.removeObserver(self, name: .glassEQBringSettingsToFront, object: nil)
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(bringSettingsToFrontNotification),
                name: .glassEQBringSettingsToFront,
                object: nil
            )
        }

        func windowDidAttach() {
            guard let view, let window = view.window else {
                return
            }
            window.initialFirstResponder = view

            guard !didInitialFront else {
                return
            }
            didInitialFront = true
            // Runs while the view is still being attached to its window, so ordering the window
            // front waits until the scene has finished setting the window up.
            DispatchQueue.main.async { [weak self] in
                self?.bringToFront()
            }
        }

        @objc private func bringSettingsToFrontNotification() {
            bringToFront()
        }

        private func bringToFront() {
            guard let view, let window = view.window else {
                return
            }
            NSApplication.shared.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            window.makeFirstResponder(view)
        }
    }

    final class FirstResponderSinkView: NSView {
        var onMoveToWindow: (() -> Void)?

        override var acceptsFirstResponder: Bool {
            true
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil {
                onMoveToWindow?()
            }
        }
    }
}
