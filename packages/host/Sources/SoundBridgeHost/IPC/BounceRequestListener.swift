import CSoundBridgeAudio
import Darwin
import Foundation
import os.log

@_silgen_name("notify_register_dispatch")
private func _notify_register_dispatch(
    _ name: UnsafePointer<CChar>,
    _ out_token: UnsafeMutablePointer<Int32>,
    _ queue: DispatchQueue,
    _ handler: @escaping @convention(block) (Int32) -> Void
) -> UInt32

@_silgen_name("notify_cancel")
private func _notify_cancel(_ token: Int32) -> UInt32

private let logger = Logger(subsystem: "com.soundbridge.host", category: "BounceRequest")

/// Handles "Reconnect Audio" requests from the app.
///
/// Anyone can post a Darwin notification, so the notification only triggers a
/// check for a fresh, single-use token file in the owner-only session
/// directory. Bursts are coalesced and bounces are rate limited.
final class BounceRequestListener {
    private let directory: SessionDirectory
    private let queue = DispatchQueue(label: "com.soundbridge.host.bounce-request")
    private let perform: () -> Void
    private var token: Int32 = 0
    private var registered = false
    private var lastNonce = [UInt8](repeating: 0, count: 16)
    private var lastBounce: Date = .distantPast

    init(directory: SessionDirectory, perform: @escaping () -> Void) {
        self.directory = directory
        self.perform = perform
    }

    func start() {
        let status = _notify_register_dispatch("com.soundbridge.bounce-request", &token, queue) { [weak self] _ in
            self?.handleHint()
        }
        registered = status == 0
        if !registered {
            logger.error("Failed to register bounce listener (status: \(status))")
        }
    }

    func stop() {
        if registered {
            _ = _notify_cancel(token)
            registered = false
        }
    }

    private func handleHint() {
        guard consumeToken() else { return }
        let now = Date()
        guard now.timeIntervalSince(lastBounce) >= SoundBridgeConfig.bounceMinInterval else {
            logger.info("Bounce request rate limited")
            return
        }
        lastBounce = now
        DispatchQueue.main.async(execute: perform)
    }

    /// Reads and deletes the token. Returns true only for a valid, fresh, unseen token.
    private func consumeToken() -> Bool {
        let tokenSize = Int(RF_BOUNCE_TOKEN_SIZE)
        guard let file = directory.openFile(RF_IPC_BOUNCE_FILE, flags: O_RDONLY, minSize: tokenSize, maxSize: tokenSize) else {
            return false
        }
        defer { close(file.fd) }
        directory.removeFile(RF_IPC_BOUNCE_FILE)

        var token = RFBounceToken()
        let status = withUnsafeMutableBytes(of: &token) { rf_ipc_read_exact(file.fd, $0.baseAddress, tokenSize) }
        guard status == 0 else { return false }
        let valid = lastNonce.withUnsafeBufferPointer { rf_bounce_token_is_valid(&token, rf_realtime_ms(), $0.baseAddress) }
        guard valid else {
            logger.warning("Rejected invalid or replayed bounce token")
            return false
        }
        withUnsafeBytes(of: &token.nonce) { lastNonce = Array($0) }
        return true
    }
}
