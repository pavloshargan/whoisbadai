import Foundation
import ServiceManagement

/// Thin wrapper over `SMAppService`, the modern (macOS 13+) launch-at-login
/// API. No helper bundle is required: the main app registers itself.
///
/// Caveat worth knowing: `SMAppService` only works for apps that live in a
/// real location (/Applications or ~/Applications). Running from Xcode's
/// DerivedData it may return `.notFound` — the UI surfaces that instead of
/// pretending it worked.
enum LaunchAtLogin {

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Attempts to set the desired state, returning the state that actually
    /// took effect so the caller can reconcile its toggle.
    @discardableResult
    static func set(enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("LaunchAtLogin: failed to \(enabled ? "register" : "unregister"): \(error)")
        }
        return isEnabled
    }
}
