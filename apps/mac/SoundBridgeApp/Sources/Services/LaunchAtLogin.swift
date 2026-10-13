import Foundation
import ServiceManagement
import os.log

private let logger = Logger(subsystem: "com.soundbridge.menubar", category: "LaunchAtLogin")

/// Registers the app as a login item so volume control is back after a reboot
/// without the user starting it.
final class LaunchAtLogin: ObservableObject {
    static let shared = LaunchAtLogin()

    private static let configuredKey = "launchAtLoginConfigured"

    @Published private(set) var isEnabled: Bool = SMAppService.mainApp.status == .enabled

    /// On by default: enabled once on the first menu-bar launch; afterwards
    /// the user's choice in the menu is left alone.
    func enableOnFirstRun() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.configuredKey) else { return }
        defaults.set(true, forKey: Self.configuredKey)
        setEnabled(true)
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            logger.error("Login item change failed: \(error.localizedDescription, privacy: .public)")
        }
        isEnabled = SMAppService.mainApp.status == .enabled
    }
}
