import Foundation
import ServiceManagement

@MainActor
final class LoginItemController {
    var isRegistered: Bool {
        SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval
    }

    var requiresApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            if !isRegistered {
                try SMAppService.mainApp.register()
            }
        } else if isRegistered {
            try SMAppService.mainApp.unregister()
        }
    }
}
