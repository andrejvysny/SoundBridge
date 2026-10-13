import Foundation

/// Identity of a driver bundle: marketing version plus the shared-memory
/// protocol it speaks (from `SoundBridgeProtocolVersion`).
struct DriverIdentity: Equatable {
    let version: String
    let protocolVersion: Int?
}

/// What Core Audio currently has loaded.
enum LoadedDriverState: Equatable {
    /// No SoundBridge plug-in is loaded (Core Audio has not been restarted, or the driver is gone).
    case notLoaded
    /// A plug-in is loaded but does not report its identity: a build older than protocol 3.
    case unidentified
    case identified(DriverIdentity)
}

/// What the app must do to reach a working, compatible driver. Decided from
/// component identity, never from mere path existence.
enum DriverAction: Equatable {
    /// Installed bundle matches the bundled one (and the loaded one, when known).
    case none
    case install
    case update(from: String)
    /// Installed bundle is unreadable or inconsistent with its version.
    case repair
    /// Installed bundle is correct but Core Audio is still running another build.
    case reloadRequired(loaded: String)
    /// A newer, protocol-incompatible driver is installed; downgrading is refused.
    case newerIncompatibleInstalled(String)
    /// This app build ships no driver.
    case bundleMissing

    var needsPrivilegedInstall: Bool {
        switch self {
        case .install, .update, .repair, .reloadRequired: return true
        case .none, .newerIncompatibleInstalled, .bundleMissing: return false
        }
    }
}

enum DriverStatus {
    static func decide(
        bundled: DriverIdentity?,
        installedExists: Bool,
        installed: DriverIdentity?,
        loaded: LoadedDriverState
    ) -> DriverAction {
        guard let bundled else { return .bundleMissing }
        guard installedExists else { return .install }
        guard let installed else { return .repair }

        if VersionManager.isVersionOlder(installed.version, than: bundled.version) {
            return .update(from: installed.version)
        }
        if VersionManager.isVersionOlder(bundled.version, than: installed.version) {
            return installed.protocolVersion == bundled.protocolVersion
                ? .none
                : .newerIncompatibleInstalled(installed.version)
        }
        guard installed.protocolVersion == bundled.protocolVersion else { return .repair }

        // The on-disk driver is right; only a running driver with the same
        // identity proves the fix is actually in effect.
        switch loaded {
        case .identified(let running):
            return running == installed ? .none : .reloadRequired(loaded: running.version)
        case .unidentified:
            return .reloadRequired(loaded: "an older build")
        case .notLoaded:
            return .reloadRequired(loaded: "no driver running")
        }
    }
}
