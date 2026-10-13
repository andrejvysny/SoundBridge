import Darwin
import Foundation
import os.log

private let logger = Logger(subsystem: "com.soundbridge.app", category: "HostProcess")

/// Launches and stops the audio host.
///
/// Running hosts are detected through the per-user session lock, never by
/// matching command lines, and only the process this controller started is
/// ever signalled.
final class HostProcessController {
    /// Host exit code when another host already owns the session.
    static let exitCodeAlreadyRunning: Int32 = 3
    /// Upper bound for the host's own cleanup (restore output, withdraw proxies).
    static let gracefulStopTimeout: TimeInterval = 3.0

    enum LaunchResult {
        case started
        case alreadyRunning
        case notFound
        case failed(Error)
    }

    /// Called on the main queue when the tracked host exits without being asked to.
    var onUnexpectedExit: ((Int32) -> Void)?

    private var process: Process?
    private var isStopping = false

    func launchIfNeeded() -> LaunchResult {
        if let process, process.isRunning {
            return .alreadyRunning
        }
        if AppSessionIPC.isHostRunning() {
            logger.info("A SoundBridge host already owns this session")
            return .alreadyRunning
        }
        guard let hostURL = Self.hostExecutableURL() else {
            logger.error("SoundBridgeHost executable not found")
            return .notFound
        }

        let process = Process()
        process.executableURL = hostURL
        process.arguments = []
        #if !DEBUG
        // Nothing drains host stdout in release builds; a full pipe would block
        // the host. Diagnostics go to unified logging instead.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        #endif
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            DispatchQueue.main.async {
                guard let self, !self.isStopping else { return }
                self.process = nil
                logger.info("Host exited with status \(status)")
                self.onUnexpectedExit?(status)
            }
        }

        do {
            isStopping = false
            try process.run()
            self.process = process
            return .started
        } catch {
            logger.error("Failed to launch host: \(error.localizedDescription, privacy: .public)")
            return .failed(error)
        }
    }

    /// Asks the tracked host to clean up and exit; force-kills it only after the
    /// deadline. Returns true if it exited on its own.
    @discardableResult
    func stop(timeout: TimeInterval = gracefulStopTimeout) -> Bool {
        guard let process else { return true }
        isStopping = true
        defer { self.process = nil }
        guard process.isRunning else { return true }

        process.terminate()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard process.isRunning else { return true }

        logger.error("Host did not exit within \(timeout)s; forcing termination")
        kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
        // The host could not withdraw its devices; do it so the driver drops the proxies.
        AppSessionIPC.withdrawDevicesIfHostGone()
        return false
    }

    private static func hostExecutableURL() -> URL? {
        var candidates: [URL] = []
        if let helper = Bundle.main.url(forAuxiliaryExecutable: "SoundBridgeHost") {
            candidates.append(helper)
        }
        if let executableDirectory = Bundle.main.executableURL?.deletingLastPathComponent() {
            candidates.append(executableDirectory.appendingPathComponent("SoundBridgeHost"))
        }
        candidates.append(Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/SoundBridgeHost"))

        #if DEBUG
        var roots: [String] = [FileManager.default.currentDirectoryPath]
        if let root = ProcessInfo.processInfo.environment["SOUNDBRIDGE_ROOT"] {
            roots.insert(root, at: 0)
        }
        let appPath = Bundle.main.bundlePath
        if appPath.contains("/SoundBridgeApp/") {
            let projectRoot = URL(fileURLWithPath: appPath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            roots.append(projectRoot.path)
        }
        for root in roots {
            for configuration in ["arm64-apple-macosx/debug", "debug", "arm64-apple-macosx/release", "release"] {
                candidates.append(URL(fileURLWithPath: "\(root)/packages/host/.build/\(configuration)/SoundBridgeHost"))
            }
        }
        #endif

        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}
