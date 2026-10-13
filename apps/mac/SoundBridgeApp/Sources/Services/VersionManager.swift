import CoreAudio
import Foundation

/// Reads app and driver component identities.
struct VersionManager {
    static let installedDriverPath = "/Library/Audio/Plug-Ins/HAL/SoundBridgeDriver.driver"

    // MARK: - App Version

    static func appVersion() -> String? {
        return Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    static func appBuildNumber() -> String? {
        return Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }

    // MARK: - Driver Identities

    /// Identity of the bundle at `path`, or nil if its Info.plist is missing,
    /// unreadable, or not a SoundBridge driver.
    static func driverIdentity(atBundlePath path: String) -> DriverIdentity? {
        let plistURL = URL(fileURLWithPath: path).appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL, options: .mappedIfSafe), data.count < 1 << 20,
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              plist["CFBundleIdentifier"] as? String == CodeIdentity.driverBundleIdentifier,
              let version = plist["CFBundleShortVersionString"] as? String else {
            return nil
        }
        return DriverIdentity(version: version, protocolVersion: plist["SoundBridgeProtocolVersion"] as? Int)
    }

    static func installedDriverExists() -> Bool {
        var st = stat()
        return lstat(installedDriverPath, &st) == 0
    }

    static func installedDriverIdentity() -> DriverIdentity? {
        return driverIdentity(atBundlePath: installedDriverPath)
    }

    static func bundledDriverIdentity() -> DriverIdentity? {
        return bundledDriverPath().flatMap(driverIdentity(atBundlePath:))
    }

    static func installedDriverVersion() -> String? {
        return installedDriverIdentity()?.version
    }

    static func bundledDriverVersion() -> String? {
        return bundledDriverIdentity()?.version
    }

    static func isDriverInstalled() -> Bool {
        return installedDriverExists()
    }

    /// What Core Audio has loaded right now, from the custom plug-in property
    /// 'sbvi'. A loaded plug-in without that property is a pre-protocol-3 build.
    static func loadedDriverState() -> LoadedDriverState {
        guard let identity = loadedDriverIdentity() else {
            return isDriverPluginLoaded() ? .unidentified : .notLoaded
        }
        return .identified(identity)
    }

    /// Identity reported by the driver instance Core Audio actually loaded.
    /// nil when no SoundBridge plug-in is loaded or it predates the property.
    static func loadedDriverIdentity() -> DriverIdentity? {
        guard let pluginID = loadedPluginObjectID() else { return nil }
        var address = AudioObjectPropertyAddress(
            mSelector: driverInfoSelector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(pluginID, &address) else { return nil }
        var info: Unmanaged<CFPropertyList>?
        var size = UInt32(MemoryLayout<Unmanaged<CFPropertyList>?>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            AudioObjectGetPropertyData(pluginID, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let dictionary = info?.takeRetainedValue() as? [String: Any],
              let version = dictionary["version"] as? String else {
            return nil
        }
        return DriverIdentity(version: version, protocolVersion: dictionary["protocol"] as? Int)
    }

    static func isDriverPluginLoaded() -> Bool {
        return loadedPluginObjectID() != nil
    }

    static func currentDriverAction() -> DriverAction {
        return DriverStatus.decide(
            bundled: bundledDriverIdentity(),
            installedExists: installedDriverExists(),
            installed: installedDriverIdentity(),
            loaded: loadedDriverState()
        )
    }

    // MARK: - Version Comparison

    /// true if v1 < v2 (numeric dotted components; missing components are 0)
    static func isVersionOlder(_ v1: String, than v2: String) -> Bool {
        let components1 = v1.split(separator: ".").compactMap { Int($0) }
        let components2 = v2.split(separator: ".").compactMap { Int($0) }

        for i in 0..<max(components1.count, components2.count) {
            let c1 = i < components1.count ? components1[i] : 0
            let c2 = i < components2.count ? components2[i] : 0
            if c1 < c2 { return true }
            if c1 > c2 { return false }
        }
        return false
    }

    // MARK: - Bundle Discovery

    static func bundledDriverPath() -> String? {
        if let resourcePath = Bundle.main.resourcePath {
            let driverPath = "\(resourcePath)/SoundBridgeDriver.driver"
            if FileManager.default.fileExists(atPath: driverPath) {
                return driverPath
            }
        }
        #if DEBUG
        if let executablePath = Bundle.main.executablePath {
            let devPath = ((executablePath as NSString).deletingLastPathComponent as NSString)
                .appendingPathComponent("../../../../../packages/driver/build/SoundBridgeDriver.driver")
            let normalized = (devPath as NSString).standardizingPath
            if FileManager.default.fileExists(atPath: normalized) {
                return normalized
            }
        }
        #endif
        return nil
    }

    // MARK: - Formatted Display

    static func formattedAppVersion() -> String {
        guard let version = appVersion() else { return "Unknown" }
        return "v\(version)"
    }

    static func detailedAppVersion() -> String {
        guard let version = appVersion() else { return "Unknown" }
        if let build = appBuildNumber(), build != "1" {
            return "v\(version) (build \(build))"
        }
        return "v\(version)"
    }

    // MARK: - Private

    /// 'sbvi', matching kDriverInfoProperty in packages/driver/src/Plugin.cpp.
    private static let driverInfoSelector: AudioObjectPropertySelector = 0x7362_7669

    private static func loadedPluginObjectID() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateBundleIDToPlugIn,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var bundleID = CodeIdentity.driverBundleIdentifier as CFString
        var pluginID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &bundleID) { qualifier in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<CFString>.size), qualifier, &size, &pluginID
            )
        }
        return status == noErr && pluginID != kAudioObjectUnknown ? pluginID : nil
    }
}
