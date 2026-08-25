import Foundation
@preconcurrency import UserNotifications

private extension Notification.Name {
    static let glassEQOpenOutputSettings = Notification.Name(
        "com.glasseq.openOutputSettings"
    )
}

@MainActor
protocol AggregateBufferChangeNotifying: AnyObject {
    func notifyBufferIncrease(
        outputName: String,
        previousFrameSize: UInt32,
        newFrameSize: UInt32
    )
    func notifyFixedBufferRebuild(
        outputName: String,
        frameSize: UInt32
    )
    func notifyTemporaryBufferIncrease(
        outputName: String,
        preferredFrameSize: UInt32,
        runtimeFrameSize: UInt32
    )
}

@MainActor
final class AggregateBufferNotifier: NSObject,
    AggregateBufferChangeNotifying,
    UNUserNotificationCenterDelegate {
    static let shared = AggregateBufferNotifier()

    private nonisolated static let categoryIdentifier = "GLASSEQ_BUFFER_RELIABILITY"
    private nonisolated static let openActionIdentifier = "GLASSEQ_OPEN_OUTPUT_SETTINGS"

    func start() {
        guard Self.canUseUserNotifications() else {
            return
        }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([Self.notificationCategory()])
        Task {
            let settings = await center.notificationSettings()
            if settings.authorizationStatus == .notDetermined {
                _ = try? await center.requestAuthorization(options: [.alert])
            }
        }
    }

    static func canUseUserNotifications(bundleURL: URL = Bundle.main.bundleURL) -> Bool {
        bundleURL.pathExtension == "app"
    }

    static func notificationCategory() -> UNNotificationCategory {
        let openAction = UNNotificationAction(
            identifier: Self.openActionIdentifier,
            title: localized("Open Output Settings"),
            options: []
        )
        return UNNotificationCategory(
            identifier: Self.categoryIdentifier,
            actions: [openAction],
            intentIdentifiers: []
        )
    }

    func notifyBufferIncrease(
        outputName: String,
        previousFrameSize: UInt32,
        newFrameSize: UInt32
    ) {
        notify(
            title: localized("GlassEQ increased the audio buffer"),
            body: localized(
                "GlassEQ detected a timing interruption while \(outputName) was using \(previousFrameSize)-frame buffers. It switched this route to \(newFrameSize) frames for more reliable playback."
            )
        )
    }

    func notifyFixedBufferRebuild(
        outputName: String,
        frameSize: UInt32
    ) {
        notify(
            title: localized("GlassEQ rebuilt the audio engine"),
            body: localized(
                "\(outputName) missed several audio deadlines at \(frameSize) frames. GlassEQ rebuilt the route at the same setting."
            )
        )
    }

    func notifyTemporaryBufferIncrease(
        outputName: String,
        preferredFrameSize: UInt32,
        runtimeFrameSize: UInt32
    ) {
        notify(
            title: localized("GlassEQ temporarily increased the audio buffer"),
            body: localized(
                "\(outputName) remained unstable at \(preferredFrameSize) frames. GlassEQ is using \(runtimeFrameSize) frames for this session. Your fixed setting was not changed."
            )
        )
    }

    private func notify(title: String, body: String) {
        guard Self.canUseUserNotifications() else {
            return
        }
        let center = UNUserNotificationCenter.current()
        Task {
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized
                    || settings.authorizationStatus == .provisional else {
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.categoryIdentifier = Self.categoryIdentifier
            try? await center.add(
                UNNotificationRequest(
                    identifier: "glasseq-buffer-recovery-\(UUID().uuidString)",
                    content: content,
                    trigger: nil
                )
            )
        }
    }

    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter,
        willPresent _: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier
                || response.actionIdentifier == Self.openActionIdentifier else {
            return
        }
        await MainActor.run {
            NotificationCenter.default.post(
                name: .glassEQOpenOutputSettings,
                object: nil
            )
        }
    }
}

@MainActor
final class NoopAggregateBufferNotifier: AggregateBufferChangeNotifying {
    func notifyBufferIncrease(
        outputName _: String,
        previousFrameSize _: UInt32,
        newFrameSize _: UInt32
    ) {}

    func notifyFixedBufferRebuild(
        outputName _: String,
        frameSize _: UInt32
    ) {}

    func notifyTemporaryBufferIncrease(
        outputName _: String,
        preferredFrameSize _: UInt32,
        runtimeFrameSize _: UInt32
    ) {}
}

extension Notification.Name {
    static var glassEQOpenOutputSettingsRequest: Notification.Name {
        .glassEQOpenOutputSettings
    }
}
