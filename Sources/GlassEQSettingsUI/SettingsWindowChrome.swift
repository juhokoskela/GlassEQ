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

// Top inset for the sidebar header and content pane so they clear the window controls (which are
// nudged downward by `windowControlTopMargin`).
let settingsTitlebarInset: CGFloat = 38

// Distance from the window's top edge to the top of the traffic lights. `.hiddenTitleBar` parks
// them about 9pt from the top (centered in the 32pt titlebar); System Settings sits them lower.
private let windowControlTopMargin: CGFloat = 16

// Distance from the window's left edge to the leftmost traffic light (default is about 9pt).
private let windowControlLeadingMargin: CGFloat = 13

// Leading inset for the sidebar's content text. Kept independent of the traffic lights so the
// selection capsule keeps its inset; the lights sit slightly to its left, like System Settings.
let sidebarContentLeading: CGFloat = 19

struct FinderStyleWindowConfigurator: NSViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> FirstResponderSinkView {
        let coordinator = context.coordinator
        let view = FirstResponderSinkView()
        coordinator.view = view
        coordinator.installObserver()
        view.onMoveToWindow = {
            coordinator.configureWindowIfAvailable()
        }
        return view
    }

    func updateNSView(_ view: FirstResponderSinkView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject {
        weak var view: FirstResponderSinkView?
        private var didInitialFront = false
        private var observingWindow = false

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

        func configureWindowIfAvailable() {
            guard let view, let window = view.window else {
                return
            }
            // Solid base layer that the sidebar card and content cards float on. The hidden title
            // bar (.windowStyle(.hiddenTitleBar) on the scene) handles the window chrome; the
            // content is pulled up under the controls by .ignoresSafeArea(.top) in the body.
            window.isOpaque = true
            window.backgroundColor = .windowBackgroundColor
            window.initialFirstResponder = view
            startObservingGeometry(of: window)
            positionSettingsWindowControls(in: window)

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

        private func startObservingGeometry(of window: NSWindow) {
            guard !observingWindow else {
                return
            }
            observingWindow = true
            let center = NotificationCenter.default
            for name in [NSWindow.didResizeNotification, NSWindow.didBecomeKeyNotification, NSWindow.didExitFullScreenNotification] {
                center.addObserver(self, selector: #selector(windowGeometryDidChange(_:)), name: name, object: window)
            }
        }

        @objc private func windowGeometryDidChange(_ note: Notification) {
            guard let window = note.object as? NSWindow else {
                return
            }
            positionSettingsWindowControls(in: window)
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

        // Position the controls as soon as we're in the window, before it's shown, so they don't
        // visibly jump from the default position when the settings window opens.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else {
                return
            }
            positionSettingsWindowControls(in: window)
            onMoveToWindow?()
        }
    }
}

// Moves the traffic lights to (windowControlLeadingMargin, windowControlTopMargin), preserving
// their spacing. Idempotent: safe to re-apply on geometry changes and to call early (before the
// window is shown) so the controls don't visibly jump into place on open.
@MainActor
private func positionSettingsWindowControls(in window: NSWindow) {
    let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
        .compactMap { window.standardWindowButton($0) }
    guard let titlebar = buttons.first?.superview,
          let leftmost = buttons.map(\.frame.minX).min() else {
        return
    }
    let dx = windowControlLeadingMargin - leftmost
    for button in buttons {
        let targetX = button.frame.minX + dx
        let targetY = max(0, titlebar.bounds.height - windowControlTopMargin - button.frame.height)
        if abs(button.frame.origin.x - targetX) > 0.5 || abs(button.frame.origin.y - targetY) > 0.5 {
            button.setFrameOrigin(NSPoint(x: targetX, y: targetY))
        }
    }
}
