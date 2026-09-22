import Foundation
import Testing
import UserNotifications
@testable import GlassEQApp

@MainActor
@Suite
struct AggregateBufferNotifierTests {
    @Test
    func notificationSetupIsDisabledOutsideAnAppBundle() {
        #expect(
            !AggregateBufferNotifier.canUseUserNotifications(
                bundleURL: URL(fileURLWithPath: "/tmp/GlassEQ")
            ))
        AggregateBufferNotifier.shared.start()
    }

    @Test
    func outputSettingsActionDoesNotRelaunchTheMainApp() throws {
        let category = AggregateBufferNotifier.notificationCategory()
        let action = try #require(category.actions.first)

        #expect(!action.options.contains(.foreground))
    }

    @Test
    func bluetoothNoticeIsDeliveredOnceAcrossConnectionsAndLaunches() async throws {
        let suiteName = "AggregateBufferNotifierTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var requests: [UNNotificationRequest] = []
        let notifier = AggregateBufferNotifier(defaults: defaults) { request in
            requests.append(request)
            return true
        }

        notifier.notifyBluetoothBufferDefault()
        notifier.notifyBluetoothBufferDefault()
        await notifier.bluetoothNotificationTask?.value
        notifier.notifyBluetoothBufferDefault()
        await notifier.bluetoothNotificationTask?.value

        let relaunchedNotifier = AggregateBufferNotifier(defaults: defaults) { request in
            requests.append(request)
            return true
        }
        relaunchedNotifier.notifyBluetoothBufferDefault()
        await relaunchedNotifier.bluetoothNotificationTask?.value

        let request = try #require(requests.first)
        #expect(requests.count == 1)
        #expect(request.content.categoryIdentifier == AggregateBufferNotifier.notificationCategory().identifier)
        #expect(request.content.sound == nil)
    }

    @Test(arguments: [false, true])
    func bluetoothNoticeRetriesAfterDeniedPermissionOrDeliveryFailure(throwsError: Bool) async throws {
        let suiteName = "AggregateBufferNotifierTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var attempts = 0
        let notifier = AggregateBufferNotifier(defaults: defaults) { _ in
            attempts += 1
            if attempts == 1 {
                if throwsError {
                    throw CocoaError(.fileWriteUnknown)
                }
                return false
            }
            return true
        }

        notifier.notifyBluetoothBufferDefault()
        await notifier.bluetoothNotificationTask?.value
        #expect(attempts == 1)

        notifier.notifyBluetoothBufferDefault()
        await notifier.bluetoothNotificationTask?.value
        notifier.notifyBluetoothBufferDefault()
        await notifier.bluetoothNotificationTask?.value
        #expect(attempts == 2)
    }

}
