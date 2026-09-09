import Foundation
@preconcurrency import UserNotifications

private extension Notification.Name {
    static let glassEQOpenOutputSettings = Notification.Name(
        "com.glasseq.openOutputSettings"
    )
}

@MainActor
protocol AggregateBufferChangeNotifying: AnyObject {
    func notifyBluetoothBufferDefault()
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

    private static let bluetoothNoticeDefaultsKey = "hasShownBluetoothBufferNotice"

    private let defaults: UserDefaults
    private let deliverNotification: @MainActor (UNNotificationRequest) async throws -> Bool
    private var authorizationTask: Task<Void, Never>?
    private(set) var bluetoothNotificationTask: Task<Void, Never>?

    init(
        defaults: UserDefaults = .standard,
        deliverNotification: @escaping @MainActor (UNNotificationRequest) async throws -> Bool =
            AggregateBufferNotifier.deliverAuthorizedNotification
    ) {
        self.defaults = defaults
        self.deliverNotification = deliverNotification
        super.init()
    }

    func start() {
        guard authorizationTask == nil, Self.canUseUserNotifications() else {
            return
        }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([Self.notificationCategory()])
        authorizationTask = Task {
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

    func notifyBluetoothBufferDefault() {
        guard !defaults.bool(forKey: Self.bluetoothNoticeDefaultsKey),
              bluetoothNotificationTask == nil else {
            return
        }
        bluetoothNotificationTask = Task {
            defer { bluetoothNotificationTask = nil }
            await authorizationTask?.value
            let request = Self.notificationRequest(
                identifier: "glasseq-bluetooth-buffer-default",
                title: localized("Smoother Bluetooth playback"),
                body: localized(
                    "Automatic uses a larger buffer for smoother playback. Customize it in Output settings."
                )
            )
            if (try? await deliverNotification(request)) == true {
                defaults.set(true, forKey: Self.bluetoothNoticeDefaultsKey)
            }
        }
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
        Task {
            await authorizationTask?.value
            _ = try? await deliverNotification(Self.notificationRequest(
                identifier: "glasseq-buffer-recovery-\(UUID().uuidString)",
                title: title,
                body: body
            ))
        }
    }

    private static func notificationRequest(
        identifier: String,
        title: String,
        body: String
    ) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = Self.categoryIdentifier
        return UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
    }

    private static func deliverAuthorizedNotification(
        _ request: UNNotificationRequest
    ) async throws -> Bool {
        guard canUseUserNotifications() else {
            return false
        }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional else {
            return false
        }
        try await center.add(request)
        return true
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
    func notifyBluetoothBufferDefault() {}

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
