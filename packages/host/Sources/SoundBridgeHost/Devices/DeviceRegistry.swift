import CSoundBridgeAudio
import Darwin
import Foundation
import os.log

// notify_post is available via <notify.h> but not always visible in cross-compilation.
@_silgen_name("notify_post")
private func _notify_post(_ name: UnsafePointer<CChar>) -> UInt32

private let logger = Logger(subsystem: "com.soundbridge.host", category: "DeviceRegistry")

class DeviceRegistry {
    private(set) var devices: [PhysicalDevice] = []
    var activeDeviceUID: String?
    private let directory: SessionDirectory

    init(directory: SessionDirectory) {
        self.directory = directory
    }

    func update(_ newDevices: [PhysicalDevice]) {
        devices = newDevices
        writeControlFile()
        writeDeviceStateFile()
    }

    func find(uid: String) -> PhysicalDevice? {
        return devices.first { $0.uid == uid }
    }

    func findAdded(comparing old: [PhysicalDevice]) -> [PhysicalDevice] {
        return devices.filter { new in
            !old.contains { $0.uid == new.uid }
        }
    }

    func findRemoved(comparing old: [PhysicalDevice]) -> [PhysicalDevice] {
        return old.filter { old in
            !devices.contains { $0.uid == old.uid }
        }
    }

    /// Publishes the device list for the driver (session directory, read-only ACL
    /// for the driver service) and wakes it. The notification is only a hint;
    /// the driver re-reads and validates the file.
    func writeControlFile() {
        let entries = devices.map { (name: $0.name, uid: $0.uid) }
        do {
            try directory.writeFile(RF_IPC_CONTROL_FILE, data: Self.controlFileContents(for: entries), access: .read)
            _ = _notify_post("com.soundbridge.devices-changed")
        } catch {
            logger.error("Failed to write control file: \(String(describing: error), privacy: .public)")
        }
    }

    func removeControlFile() {
        directory.removeFile(RF_IPC_CONTROL_FILE)
        _ = _notify_post("com.soundbridge.devices-changed")
    }

    /// Serializes entries in the format `rf_control_parse` accepts. UIDs that
    /// cannot be represented are skipped; names are cleaned and truncated.
    static func controlFileContents(for entries: [(name: String, uid: String)]) -> Data {
        var output = RF_CONTROL_HEADER + "\n"
        var seen = Set<String>()
        for entry in entries where seen.count < Int(RF_CONTROL_MAX_DEVICES) {
            guard !entry.uid.isEmpty,
                  entry.uid.utf8.count <= Int(RF_DEVICE_UID_MAX),
                  !entry.uid.unicodeScalars.contains(where: isControl),
                  seen.insert(entry.uid).inserted else {
                continue
            }
            output += entry.uid + "\t" + sanitizedName(entry.name) + "\n"
        }
        return Data(output.utf8)
    }

    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        return scalar.value < 0x20 || scalar.value == 0x7f
    }

    private static func sanitizedName(_ name: String) -> String {
        var result = ""
        var byteCount = 0
        for character in name {
            let cleaned = character.unicodeScalars.contains(where: isControl) ? " " : String(character)
            byteCount += cleaned.utf8.count
            if byteCount > Int(RF_DEVICE_NAME_MAX) { break }
            result += cleaned
        }
        return result
    }

    /// Write device-state.json for the menu bar App IPC.
    /// Contains only device list and active device — no volume/mute state.
    func writeDeviceStateFile() {
        struct IPCDeviceInfo: Codable {
            let name: String
            let uid: String
            let isFixedVolume: Bool
        }

        struct IPCDeviceState: Codable {
            let devices: [IPCDeviceInfo]
            let activeDeviceUID: String?
        }

        let ipcDevices = devices.map {
            IPCDeviceInfo(name: $0.name, uid: $0.uid, isFixedVolume: $0.isFixedVolume)
        }
        let state = IPCDeviceState(devices: ipcDevices, activeDeviceUID: activeDeviceUID)

        do {
            let data = try JSONEncoder().encode(state)
            let fileURL = PathManager.appSupportDir.appendingPathComponent("device-state.json")
            // .atomic writes a temporary file and renames it over the destination.
            try data.write(to: fileURL, options: [.atomic])
            _ = _notify_post("com.soundbridge.device-state-changed")
            logger.info("Wrote device-state.json (\(self.devices.count) devices)")
        } catch {
            logger.error("Failed to write device-state.json: \(error.localizedDescription)")
        }
    }
}
