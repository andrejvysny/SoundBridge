import CSoundBridgeAudio
import Darwin
import Foundation
import os.log

private let logger = Logger(subsystem: "com.soundbridge.host", category: "HostLifecycle")

/// Holds an exclusive flock on the session's host lock file for the process
/// lifetime. The app checks the same lock instead of matching command lines.
final class HostInstanceLock {
    private let fd: Int32

    init?(directory: SessionDirectory) {
        let descriptor = rf_ipc_open_lock_file(directory.fd, true)
        guard descriptor >= 0 else {
            logger.error("Cannot open host lock file: \(String(cString: strerror(errno)), privacy: .public)")
            return nil
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return nil
        }
        fd = descriptor
    }

    deinit {
        flock(fd, LOCK_UN)
        close(fd)
    }
}

/// Exits the host when the process that launched it goes away, so a crashed or
/// force-quit app never leaves an orphaned host behind.
final class ParentProcessWatcher {
    private var source: DispatchSourceProcess?

    func start(onExit: @escaping () -> Void) {
        let parent = getppid()
        guard parent > 1 else { return } // launched directly by launchd: nothing to watch
        let source = DispatchSource.makeProcessSource(identifier: parent, eventMask: .exit, queue: .main)
        source.setEventHandler(handler: onExit)
        source.resume()
        self.source = source
        // The parent may have exited before the source was armed.
        if getppid() != parent {
            onExit()
        }
    }

    func stop() {
        source?.cancel()
        source = nil
    }
}
