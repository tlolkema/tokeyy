import Foundation
import ServiceManagement

@MainActor
enum LaunchAtLogin {
    static var canConfigure: Bool { Bundle.main.bundleURL.pathExtension == "app" }
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval
    }
    static var requiresApproval: Bool { SMAppService.mainApp.status == .requiresApproval }
    static var statusDescription: String {
        switch SMAppService.mainApp.status {
        case .enabled: "enabled"
        case .requiresApproval: "requires approval in System Settings"
        case .notRegistered: "disabled"
        case .notFound: "not found"
        @unknown default: "unknown"
        }
    }

    static func setEnabled(_ enabled: Bool) throws {
        guard canConfigure else {
            throw NSError(domain: "app.tokeyy.mac", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Install Tokeyy in Applications to configure launch at login."])
        }
        if enabled && !isEnabled {
            try SMAppService.mainApp.register()
        } else if !enabled && isEnabled {
            try SMAppService.mainApp.unregister()
        }
    }

    static func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}
