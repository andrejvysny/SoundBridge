import AppKit
import CSoundBridgeAudio
import Foundation
import os.log

private let logger = Logger(subsystem: "com.soundbridge.app", category: "Uninstall")

/// Removes the system driver and, only if the user asks, this user's data.
/// Cancellation changes nothing; failures and partial results are reported.
@MainActor
enum UninstallCoordinator {
    static func run() {
        let deleteDataCheckbox = NSButton(checkboxWithTitle: "Also delete my SoundBridge settings, EQ and logs", target: nil, action: nil)
        deleteDataCheckbox.state = .off

        let alert = NSAlert()
        alert.messageText = "Uninstall SoundBridge Driver"
        alert.informativeText = "This removes the audio driver for all users of this Mac and stops SoundBridge. The app itself is not deleted."
        alert.alertStyle = .warning
        alert.accessoryView = deleteDataCheckbox
        alert.addButton(withTitle: "Uninstall Driver")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let deleteData = deleteDataCheckbox.state == .on

        guard let appDelegate = NSApp.delegate as? AppDelegate else { return }
        appDelegate.isUninstalling = true
        // Stop the host first so it restores the physical output while its proxy still exists.
        if !appDelegate.hostController.stop() {
            OutputDeviceRestorer.restorePhysicalIfOnProxy()
        }

        Task { @MainActor in
            do {
                _ = try await DriverInstaller().perform(.uninstall)
            } catch {
                appDelegate.isUninstalling = false
                appDelegate.launchHostIfNeeded()
                let cancelled = (error as? DriverInstallError) == .cancelled
                appDelegate.showAlert(
                    cancelled ? "Uninstall Cancelled" : "Uninstall Failed",
                    cancelled ? "Nothing was removed." : "\(error.localizedDescription) Your settings were not changed.",
                    style: cancelled ? .informational : .critical
                )
                return
            }

            // Without the driver the app has nothing to do at login.
            LaunchAtLogin.shared.setEnabled(false)
            let failures = deleteData ? UserDataEraser.eraseAll() : []
            var message = "The SoundBridge driver was removed."
            if deleteData {
                message += failures.isEmpty
                    ? " Your SoundBridge settings, EQ and logs were deleted."
                    : " Some data could not be deleted: \(failures.joined(separator: ", "))."
            } else {
                message += " Your settings were kept."
            }
            appDelegate.showAlert("Driver Uninstalled", message, style: failures.isEmpty ? .informational : .warning)
            NSApp.terminate(nil)
        }
    }
}

/// Deletes data owned by this app for the current user only.
enum UserDataEraser {
    /// Returns human-readable names of items that could not be removed.
    static func eraseAll() -> [String] {
        var failures: [String] = []
        let fm = FileManager.default
        let library = fm.urls(for: .libraryDirectory, in: .userDomainMask).first!
        for (label, url) in [
            ("application data", library.appendingPathComponent("Application Support/SoundBridge")),
            ("logs", library.appendingPathComponent("Logs/SoundBridge")),
        ] where fm.fileExists(atPath: url.path) {
            do {
                try fm.removeItem(at: url)
            } catch {
                failures.append(label)
            }
        }

        // All preferences, including per-device EQ keys and updater state.
        let domain = Bundle.main.bundleIdentifier ?? "com.soundbridge.menubar"
        UserDefaults.standard.removePersistentDomain(forName: domain)
        UserDefaults.standard.synchronize()

        if !removeSessionDirectory() {
            failures.append("temporary session files")
        }
        logger.info("User data erase finished with \(failures.count) failure(s)")
        return failures
    }

    /// Removes this user's IPC session directory once no host holds it.
    private static func removeSessionDirectory() -> Bool {
        guard !AppSessionIPC.isHostRunning() else { return false }
        guard let dir = AppSessionIPC.openDirectory() else { return true }
        defer { close(dir) }
        var path = [CChar](repeating: 0, count: Int(RF_IPC_PATH_MAX))
        guard rf_ipc_dir_path(geteuid(), &path, path.count) == 0 else { return false }
        let directoryPath = String(cString: path)
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: directoryPath)) ?? []
        for name in entries {
            _ = rf_ipc_unlink(dir, name)
        }
        return rmdir(directoryPath) == 0 || errno == ENOENT
    }
}
