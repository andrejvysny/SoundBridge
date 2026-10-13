import CSoundBridgeAudio
import Darwin
@testable import SoundBridgeHost
import XCTest

final class BounceTokenTests: XCTestCase {
    private func writeToken(_ directory: SessionDirectory, createdMs: UInt64) throws {
        var token = RFBounceToken()
        rf_bounce_token_init(&token, createdMs)
        try directory.writeFile(RF_IPC_BOUNCE_FILE, data: Data(bytes: &token, count: MemoryLayout<RFBounceToken>.size), access: .none)
    }

    func testValidTokenTriggersOnceAndStaleOrMissingTokensDoNot() throws {
        let directory = try SessionDirectory()
        let triggered = expectation(description: "bounce performed")
        triggered.expectedFulfillmentCount = 1
        var count = 0
        let listener = BounceRequestListener(directory: directory) {
            count += 1
            triggered.fulfill()
        }
        listener.start()
        defer { listener.stop() }

        try writeToken(directory, createdMs: rf_realtime_ms())
        notify_post_bounce()
        wait(for: [triggered], timeout: 2)

        // Stale token: ignored, and consumed so it cannot be replayed later.
        try writeToken(directory, createdMs: rf_realtime_ms() - 60_000)
        notify_post_bounce()
        // Notification without token: ignored.
        notify_post_bounce()
        let settle = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { settle.fulfill() }
        wait(for: [settle], timeout: 2)
        XCTAssertEqual(count, 1)
        XCTAssertNil(directory.openFile(RF_IPC_BOUNCE_FILE, flags: O_RDONLY, minSize: 0, maxSize: 64))
    }
}

@_silgen_name("notify_post")
private func _notify_post(_ name: UnsafePointer<CChar>) -> UInt32

private func notify_post_bounce() {
    _ = _notify_post("com.soundbridge.bounce-request")
}
