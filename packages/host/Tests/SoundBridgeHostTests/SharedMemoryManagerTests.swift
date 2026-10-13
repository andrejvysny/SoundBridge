import CSoundBridgeAudio
import Darwin
@testable import SoundBridgeHost
import XCTest

/// Exercises the real session directory for the current user with unique test
/// device UIDs, and checks the files the way the driver validates them.
final class SharedMemoryManagerTests: XCTestCase {
    private var directory: SessionDirectory!
    private var manager: SharedMemoryManager!
    private let uid = "sbtest-\(UUID().uuidString)"

    override func setUpWithError() throws {
        directory = try SessionDirectory()
        manager = SharedMemoryManager(directory: directory)
    }

    override func tearDown() {
        manager.cleanup()
        manager = nil
        directory = nil
    }

    private func hash(_ uid: String) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: Int(RF_UID_HASH_SIZE))
        let bytes = Array(uid.utf8)
        bytes.withUnsafeBufferPointer { buffer in
            buffer.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buffer.count) {
                rf_uid_hash($0, buffer.count, &out)
            }
        }
        return out
    }

    func testSessionDirectoryIsPrivate() throws {
        var st = stat()
        XCTAssertEqual(fstat(directory.fd, &st), 0)
        XCTAssertEqual(st.st_uid, geteuid())
        XCTAssertEqual(st.st_mode & 0o7777, 0o700)
        XCTAssertGreaterThanOrEqual(rf_ipc_open_dir(geteuid()).closingDescriptor(), 0)
    }

    func testAudioFileIsDriverValidatableAndEQFileIsOwnerOnly() throws {
        XCTAssertNotNil(manager.createMemory(for: uid, sampleRate: 48000))
        let audioName = try XCTUnwrap(SessionDirectory.fileName(prefix: RF_IPC_AUDIO_PREFIX, deviceUID: uid))
        let eqName = try XCTUnwrap(SessionDirectory.fileName(prefix: RF_IPC_EQ_PREFIX, deviceUID: uid))

        // Same checks the driver performs.
        let file = try XCTUnwrap(directory.openFile(audioName, flags: O_RDONLY, minSize: 256, maxSize: rf_shared_audio_max_size()))
        defer { close(file.fd) }
        var st = stat()
        XCTAssertEqual(fstat(file.fd, &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o600)
        let base = try XCTUnwrap(mmap(nil, file.size, PROT_READ, MAP_SHARED, file.fd, 0))
        defer { munmap(base, file.size) }
        var layout = RFAudioLayout()
        let expected = hash(uid)
        XCTAssertEqual(rf_validate_layout(base.assumingMemoryBound(to: RFSharedAudio.self), file.size, expected, &layout), RF_LAYOUT_OK)
        XCTAssertEqual(layout.sample_rate, 48000)

        let acl = acl_get_fd_np(file.fd, ACL_TYPE_EXTENDED)
        XCTAssertNotNil(acl, "audio file must carry the driver-service ACL")
        if let acl { acl_free(UnsafeMutableRawPointer(acl)) }

        let eq = try XCTUnwrap(directory.openFile(eqName, flags: O_RDONLY, minSize: Int(RF_EQ_CONTROL_SIZE), maxSize: Int(RF_EQ_CONTROL_SIZE)))
        defer { close(eq.fd) }
        XCTAssertNil(acl_get_fd_np(eq.fd, ACL_TYPE_EXTENDED), "EQ control must not be shared with the driver service")
    }

    func testSameRateKeepsGenerationAndRateChangeReplacesIt() {
        let first = manager.createMemory(for: uid, sampleRate: 48000)
        XCTAssertEqual(manager.createMemory(for: uid, sampleRate: 48000), first)
        let second = manager.createMemory(for: uid, sampleRate: 96000)
        XCTAssertNotNil(second)
        XCTAssertNotEqual(second, first)
    }

    func testDelayedRemovalDoesNotTearDownReplug() throws {
        manager.createMemory(for: uid, sampleRate: 48000)
        let staleToken = try XCTUnwrap(manager.removalToken(for: uid))
        manager.createMemory(for: uid, sampleRate: 48000) // replug before the delayed removal fires
        manager.removeMemory(for: uid, token: staleToken)
        XCTAssertNotNil(manager.removalToken(for: uid))

        let currentToken = try XCTUnwrap(manager.removalToken(for: uid))
        manager.removeMemory(for: uid, token: currentToken)
        XCTAssertNil(manager.removalToken(for: uid))
        let audioName = try XCTUnwrap(SessionDirectory.fileName(prefix: RF_IPC_AUDIO_PREFIX, deviceUID: uid))
        XCTAssertNil(directory.openFile(audioName, flags: O_RDONLY, minSize: 0, maxSize: 1 << 20))
    }

    /// A crashed host leaves mappings behind; the next host owns the session and
    /// must drop them (they still hold routed audio).
    func testStaleArtifactsAreRemovedButTheLockIsKept() throws {
        manager.createMemory(for: uid, sampleRate: 48000)
        let audioName = try XCTUnwrap(SessionDirectory.fileName(prefix: RF_IPC_AUDIO_PREFIX, deviceUID: uid))
        XCTAssertNotNil(directory.openFile(audioName, flags: O_RDONLY, minSize: 0, maxSize: 1 << 20))
        let lock = rf_ipc_open_lock_file(directory.fd, true)
        XCTAssertGreaterThanOrEqual(lock, 0)
        close(lock)

        XCTAssertGreaterThan(directory.removeStaleArtifacts(), 0)
        XCTAssertNil(directory.openFile(audioName, flags: O_RDONLY, minSize: 0, maxSize: 1 << 20))
        XCTAssertGreaterThanOrEqual(rf_ipc_open_lock_file(directory.fd, false).closingDescriptor(), 0)
    }

    /// Audio written into a ring while it was not the active device (for example
    /// during a bounce) must not play when that device becomes active.
    func testActivatingADeviceDropsAudioBufferedWhileInactive() throws {
        manager.createMemory(for: uid, sampleRate: 48000)
        let audioName = try XCTUnwrap(SessionDirectory.fileName(prefix: RF_IPC_AUDIO_PREFIX, deviceUID: uid))
        let file = try XCTUnwrap(directory.openFile(audioName, flags: O_RDWR, minSize: 0, maxSize: rf_shared_audio_max_size()))
        defer { close(file.fd) }
        let base = try XCTUnwrap(mmap(nil, file.size, PROT_READ | PROT_WRITE, MAP_SHARED, file.fd, 0))
        defer { munmap(base, file.size) }
        let audio = base.assumingMemoryBound(to: RFSharedAudio.self)
        var layout = RFAudioLayout()
        XCTAssertEqual(rf_validate_layout(audio, file.size, hash(uid), &layout), RF_LAYOUT_OK)

        var samples = [Float](repeating: 0.5, count: 256)
        XCTAssertEqual(rf_ring_write(audio, &layout, &samples, samples.count), 128)
        XCTAssertEqual(rf_ring_fill(audio, &layout), 128)

        manager.setActiveDevice(uid: uid)
        XCTAssertEqual(rf_ring_fill(audio, &layout), 0, "stale audio must be dropped when the device becomes active")
    }

    func testRenderSlotFollowsActiveDeviceAndRetiresSafely() throws {
        manager.createMemory(for: uid, sampleRate: 48000)
        XCTAssertNil(acquireGeneration())
        manager.setActiveDevice(uid: uid)
        let generation = try XCTUnwrap(acquireGeneration())

        // Concurrent render-like reader while the control plane replaces and removes the mapping.
        let stop = ManagedAtomicFlag()
        let finished = DispatchSemaphore(value: 0)
        let slot = manager.renderSlot
        let reader = Thread {
            var samples = [Float](repeating: 0, count: 512)
            while !stop.isSet {
                if let session = rf_render_slot_acquire(slot) {
                    _ = rf_render_session_read(session, &samples, samples.count)
                    _ = rf_render_session_volume(session)
                }
                rf_render_slot_release(slot)
            }
            finished.signal()
        }
        reader.start()
        for index in 0..<50 {
            manager.createMemory(for: uid, sampleRate: index % 2 == 0 ? 96000 : 48000)
        }
        XCTAssertNotEqual(acquireGeneration(), generation)
        manager.setActiveDevice(uid: nil)
        XCTAssertNil(acquireGeneration())
        stop.set()
        finished.wait()
    }

    private func acquireGeneration() -> UInt64? {
        defer { rf_render_slot_release(manager.renderSlot) }
        return rf_render_slot_acquire(manager.renderSlot).map { rf_render_session_generation($0) }
    }
}

private final class ManagedAtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}

private extension Int32 {
    /// Closes a descriptor returned by a C helper and passes the value through for assertions.
    func closingDescriptor() -> Int32 {
        if self >= 0 { close(self) }
        return self
    }
}
