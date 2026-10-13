import CSoundBridgeAudio
import Darwin
import Foundation

enum SessionDirectoryError: Error, CustomStringConvertible {
    case unavailable(Int32)
    case invalidName(String)
    case io(String, Int32)

    var description: String {
        switch self {
        case .unavailable(let code):
            return "Session directory unavailable: \(String(cString: strerror(code)))"
        case .invalidName(let name):
            return "Invalid IPC file name: \(name)"
        case .io(let step, let code):
            return "\(step) failed: \(String(cString: strerror(code)))"
        }
    }
}

/// Who besides the owning user may open a file in the session directory.
enum ServiceAccess {
    case none
    case read
    case readWrite
}

/// Per-user IPC directory (`/private/tmp/com.soundbridge.<uid>`, 0700 + ACL for
/// the HAL driver service). Every operation is relative to the descriptor opened
/// at startup, so path substitution after validation has no effect.
final class SessionDirectory {
    let fd: Int32

    init() throws {
        let descriptor = rf_ipc_create_dir(true)
        guard descriptor >= 0 else { throw SessionDirectoryError.unavailable(errno) }
        fd = descriptor
    }

    deinit {
        close(fd)
    }

    static func fileName(prefix: String, deviceUID: String) -> String? {
        let utf8 = Array(deviceUID.utf8)
        guard !utf8.isEmpty else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(RF_IPC_NAME_MAX))
        let status = utf8.withUnsafeBufferPointer { bytes in
            bytes.baseAddress!.withMemoryRebound(to: CChar.self, capacity: bytes.count) { uid in
                rf_ipc_file_name(prefix, uid, bytes.count, &buffer, buffer.count)
            }
        }
        guard status == 0 else { return nil }
        return String(cString: buffer)
    }

    /// Atomically replaces `name` with `data`.
    func writeFile(_ name: String, data: Data, access: ServiceAccess) throws {
        try createFile(name, access: access) { temp in
            let status = data.withUnsafeBytes { bytes in
                rf_ipc_write_all(temp, bytes.baseAddress, bytes.count)
            }
            guard status == 0 else { throw SessionDirectoryError.io("write", errno) }
        }
    }

    /// Creates a sized, initialized shared mapping and atomically publishes it
    /// under `name`. Readers never observe a partially initialized file.
    func createMapping(
        _ name: String,
        length: Int,
        access: ServiceAccess,
        initialize: (UnsafeMutableRawPointer) -> Bool
    ) throws -> UnsafeMutableRawPointer {
        var mapping: UnsafeMutableRawPointer?
        do {
            try createFile(name, access: access) { temp in
                guard ftruncate(temp, off_t(length)) == 0 else { throw SessionDirectoryError.io("ftruncate", errno) }
                let base = mmap(nil, length, PROT_READ | PROT_WRITE, MAP_SHARED, temp, 0)
                guard let base, base != MAP_FAILED else { throw SessionDirectoryError.io("mmap", errno) }
                mapping = base
                guard initialize(base) else { throw SessionDirectoryError.io("initialize", EINVAL) }
            }
        } catch {
            if let mapping { munmap(mapping, length) }
            throw error
        }
        return mapping!
    }

    func removeFile(_ name: String) {
        _ = rf_ipc_unlink(fd, name)
    }

    /// Deletes every session file except the host lock. Call once the
    /// single-instance lock is held: anything present then was left by a
    /// crashed host, still holds routed audio, and nothing else owns it.
    @discardableResult
    func removeStaleArtifacts() -> Int {
        let removed = rf_ipc_remove_session_artifacts(fd)
        return removed > 0 ? Int(removed) : 0
    }

    /// Opens an existing owner-only file with validated type, link count, and size.
    func openFile(_ name: String, flags: Int32, minSize: Int, maxSize: Int) -> (fd: Int32, size: Int)? {
        var size: off_t = 0
        let descriptor = rf_ipc_open_file(fd, name, flags, geteuid(), off_t(minSize), off_t(maxSize), &size)
        guard descriptor >= 0 else { return nil }
        return (descriptor, Int(size))
    }

    private func createFile(
        _ name: String,
        access: ServiceAccess,
        fill: (Int32) throws -> Void
    ) throws {
        guard rf_ipc_name_is_valid(name) else { throw SessionDirectoryError.invalidName(name) }
        var tempName = [CChar](repeating: 0, count: Int(RF_IPC_NAME_MAX))
        let temp = rf_ipc_create_temp(fd, &tempName, tempName.count)
        guard temp >= 0 else { throw SessionDirectoryError.io("create temp", errno) }
        defer { close(temp) }

        do {
            switch access {
            case .none:
                break
            case .read, .readWrite:
                guard rf_ipc_grant_service_access(temp, false, access == .readWrite) == 0 else {
                    throw SessionDirectoryError.io("grant service ACL", errno)
                }
            }
            try fill(temp)
            guard rf_ipc_commit(fd, tempName, name) == 0 else { throw SessionDirectoryError.io("rename", errno) }
        } catch {
            _ = rf_ipc_unlink(fd, tempName)
            throw error
        }
    }
}
