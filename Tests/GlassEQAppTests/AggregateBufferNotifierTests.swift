import Foundation
import Testing
import UserNotifications
@testable import GlassEQApp

@MainActor
@Suite
struct AggregateBufferNotifierTests {
    @Test
    func notificationSetupIsDisabledOutsideAnAppBundle() {
        #expect(!AggregateBufferNotifier.canUseUserNotifications(
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
}
