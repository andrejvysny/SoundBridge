import CSoundBridgeAudio
import Darwin
import Foundation
import os.log

@_silgen_name("notify_post")
private func _notify_post(_ name: UnsafePointer<CChar>) -> UInt32

private let logger = Logger(subsystem: "com.soundbridge.app", category: "SessionIPC")

/// App-side access to the host's per-user session directory. The app never
/// creates the directory; it only uses one that passes owner/mode validation.
enum AppSessionIPC {
    /// Opens the validated session directory, or nil if the host has not created it.
    static func openDirectory() -> Int32? {
        let fd = rf_ipc_open_dir(geteuid())
        return fd >= 0 ? fd : nil
    }

    static func fileName(prefix: String, deviceUID: String) -> String? {
        let utf8 = Array(deviceUID.utf8)
        guard !utf8.isEmpty else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(RF_IPC_NAME_MAX))
        let status = utf8.withUnsafeBufferPointer { bytes in
            bytes.baseAddress!.withMemoryRebound(to: CChar.self, capacity: bytes.count) {
                rf_ipc_file_name(prefix, $0, bytes.count, &buffer, buffer.count)
            }
        }
        return status == 0 ? String(cString: buffer) : nil
    }

    static func uidHash(_ deviceUID: String) -> [UInt8] {
        var hash = [UInt8](repeating: 0, count: Int(RF_UID_HASH_SIZE))
        let utf8 = Array(deviceUID.utf8)
        guard !utf8.isEmpty else { return hash }
        utf8.withUnsafeBufferPointer { bytes in
            bytes.baseAddress!.withMemoryRebound(to: CChar.self, capacity: bytes.count) {
                rf_uid_hash($0, bytes.count, &hash)
            }
        }
        return hash
    }

    /// True while some host holds this user's single-instance lock.
    static func isHostRunning() -> Bool {
        guard let dir = openDirectory() else { return false }
        defer { close(dir) }
        let lock = rf_ipc_open_lock_file(dir, false)
        guard lock >= 0 else { return false }
        defer { close(lock) }
        if flock(lock, LOCK_SH | LOCK_NB) == 0 {
            flock(lock, LOCK_UN)
            return false
        }
        return errno == EWOULDBLOCK
    }

    /// Asks the host to reconnect audio. The notification alone is ignored by the
    /// host; it acts only on this fresh single-use token in the owner-only directory.
    @discardableResult
    static func requestBounce() -> Bool {
        guard let dir = openDirectory() else { return false }
        defer { close(dir) }
        var token = RFBounceToken()
        rf_bounce_token_init(&token, rf_realtime_ms())
        guard writeAtomically(dir: dir, name: RF_IPC_BOUNCE_FILE, bytes: &token, count: MemoryLayout<RFBounceToken>.size) else {
            logger.error("Failed to write bounce token")
            return false
        }
        _ = _notify_post("com.soundbridge.bounce-request")
        return true
    }

    /// Fallback after a host was force-killed: withdraw the device list so the
    /// driver removes proxies. Never touches files while a host is alive.
    static func withdrawDevicesIfHostGone() {
        guard !isHostRunning(), let dir = openDirectory() else { return }
        defer { close(dir) }
        if rf_ipc_unlink(dir, RF_IPC_CONTROL_FILE) == 0 {
            _ = _notify_post("com.soundbridge.devices-changed")
        }
    }

    /// Removes world-accessible IPC files left by pre-hardening versions
    /// (`/tmp/soundbridge-*`). Only regular files owned by this user are touched.
    static func removeLegacyFiles(in directory: String = "/private/tmp") {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return }
        for entry in entries where entry.hasPrefix("soundbridge-") {
            let path = (directory as NSString).appendingPathComponent(entry)
            var st = stat()
            guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == geteuid() else { continue }
            if unlink(path) == 0 {
                logger.info("Removed legacy IPC file")
            }
        }
    }

    private static func writeAtomically(dir: Int32, name: String, bytes: UnsafeRawPointer, count: Int) -> Bool {
        var tempName = [CChar](repeating: 0, count: Int(RF_IPC_NAME_MAX))
        let temp = rf_ipc_create_temp(dir, &tempName, tempName.count)
        guard temp >= 0 else { return false }
        defer { close(temp) }
        guard rf_ipc_write_all(temp, bytes, count) == 0, rf_ipc_commit(dir, tempName, name) == 0 else {
            _ = rf_ipc_unlink(dir, tempName)
            return false
        }
        return true
    }
}
