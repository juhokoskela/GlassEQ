import ServiceManagement
import Testing
@testable import GlassEQApp

@MainActor
@Suite
struct LaunchAtLoginModelTests {
    @Test
    func approvalRequiredRemainsRegisteredAndOpensLoginItemsSettings() {
        let service = FakeLaunchAtLoginService(status: .requiresApproval)
        let model = makeModel(service: service)

        #expect(model.isEnabled)
        #expect(model.requiresApproval)

        model.isEnabled = true
        #expect(service.registerCallCount == 0)

        model.openApprovalSettings()
        #expect(service.openSettingsCallCount == 1)
    }

    @Test
    func approvalRequiredRegistrationCanBeTurnedOff() {
        let service = FakeLaunchAtLoginService(status: .requiresApproval)
        let model = makeModel(service: service)

        model.isEnabled = false

        #expect(service.unregisterCallCount == 1)
        #expect(model.status == .notRegistered)
        #expect(!model.isEnabled)
        #expect(!model.requiresApproval)
    }

    @Test
    func registrationRefreshesTheReportedServiceStatus() {
        let service = FakeLaunchAtLoginService(status: .notRegistered)
        let model = makeModel(service: service)

        model.isEnabled = true

        #expect(service.registerCallCount == 1)
        #expect(model.status == .enabled)
        #expect(model.isEnabled)
        #expect(model.errorMessage == nil)
    }

    private func makeModel(service: FakeLaunchAtLoginService) -> LaunchAtLoginModel {
        LaunchAtLoginModel(
            status: { service.status },
            register: { try service.register() },
            unregister: { try service.unregister() },
            openLoginItemsSettings: { service.openSettings() }
        )
    }
}

@MainActor
private final class FakeLaunchAtLoginService {
    var status: SMAppService.Status
    private(set) var registerCallCount = 0
    private(set) var unregisterCallCount = 0
    private(set) var openSettingsCallCount = 0

    init(status: SMAppService.Status) {
        self.status = status
    }

    func register() throws {
        registerCallCount += 1
        status = .enabled
    }

    func unregister() throws {
        unregisterCallCount += 1
        status = .notRegistered
    }

    func openSettings() {
        openSettingsCallCount += 1
    }
}
