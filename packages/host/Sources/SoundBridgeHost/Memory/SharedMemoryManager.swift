import CSoundBridgeAudio
import Darwin
import Foundation
import os.log

private let logger = Logger(subsystem: "com.soundbridge.host", category: "SharedMemoryManager")

/// One device's audio ring and EQ control mappings. Unmapped in `deinit`, so a
/// strong reference keeps the memory valid; lengths are captured locally.
final class SharedAudioMapping {
    let uid: String
    let generation: UInt64
    let audioName: String
    let eqName: String
    let audio: UnsafeMutablePointer<RFSharedAudio>
    let audioLength: Int
    let eq: UnsafeMutablePointer<RFEQControl>
    let session: UnsafeMutablePointer<RFRenderSession>

    init(
        uid: String,
        generation: UInt64,
        audioName: String,
        eqName: String,
        audio: UnsafeMutablePointer<RFSharedAudio>,
        audioLength: Int,
        layout: RFAudioLayout,
        eq: UnsafeMutablePointer<RFEQControl>
    ) {
        self.uid = uid
        self.generation = generation
        self.audioName = audioName
        self.eqName = eqName
        self.audio = audio
        self.audioLength = audioLength
        self.eq = eq
        session = .allocate(capacity: 1)
        session.initialize(to: RFRenderSession(audio: audio, layout: layout, eq: eq, generation: generation))
    }

    var sampleRate: UInt32 { session.pointee.layout.sample_rate }

    deinit {
        munmap(audio, audioLength)
        munmap(eq, Int(RF_EQ_CONTROL_SIZE))
        session.deinitialize(count: 1)
        session.deallocate()
    }
}

/// Owns all host mappings. Control-plane methods may be called from any
/// non-realtime thread; the render callback only touches `renderSlot`.
final class SharedMemoryManager {
    let renderSlot: UnsafeMutablePointer<RFRenderSlot>

    private let directory: SessionDirectory
    private let lock = NSLock()
    private var mappings: [String: SharedAudioMapping] = [:]
    private var activeUID: String?
    private var published: SharedAudioMapping?
    private var nextGeneration: UInt64 = 1
    /// Bumped on every create request; delayed removals only proceed if unchanged.
    private var claims: [String: UInt64] = [:]
    /// Mappings whose readers never quiesced. Never unmapped: leaking beats a use-after-free.
    private var quarantined: [SharedAudioMapping] = []

    private let heartbeatQueue = DispatchQueue(label: "com.soundbridge.host.heartbeat")
    private var heartbeatTimer: DispatchSourceTimer?
    private var lastUnderruns: [String: UInt64] = [:]
    private var lastOverruns: [String: UInt64] = [:]
    private var telemetryCounter = 0

    init(directory: SessionDirectory) {
        self.directory = directory
        guard let slot = rf_render_slot_create() else { fatalError("Failed to allocate render slot") }
        renderSlot = slot
    }

    func createMemory(for devices: [PhysicalDevice], sampleRate: UInt32) {
        for device in devices where createMemory(for: device.uid, sampleRate: sampleRate) == nil {
            logger.error("Failed to create shared memory for a device")
        }
    }

    /// Creates (or keeps, when the rate is unchanged) the mappings for `uid`.
    /// Returns the current generation.
    @discardableResult
    func createMemory(for uid: String, sampleRate: UInt32) -> UInt64? {
        lock.lock()
        claims[uid, default: 0] += 1
        if let existing = mappings[uid], existing.sampleRate == sampleRate {
            lock.unlock()
            return existing.generation
        }
        let generation = nextGeneration
        nextGeneration += 1
        lock.unlock()

        guard let mapping = makeMapping(uid: uid, sampleRate: sampleRate, generation: generation) else {
            return nil
        }

        lock.lock()
        let replaced = mappings[uid]
        mappings[uid] = mapping
        lock.unlock()

        publishActive()
        withExtendedLifetime(replaced) {} // unmapped only after the render slot moved off it
        logger.info("Shared memory ready (generation \(generation), \(sampleRate) Hz)")
        return generation
    }

    /// Token for a later `removeMemory`. Any `createMemory` for the same UID in
    /// between (unplug then replug) invalidates it.
    func removalToken(for uid: String) -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        return mappings[uid] == nil ? nil : claims[uid, default: 0]
    }

    func removeMemory(for uid: String, token: UInt64) {
        lock.lock()
        guard let mapping = mappings[uid], claims[uid, default: 0] == token else {
            lock.unlock()
            return
        }
        mappings.removeValue(forKey: uid)
        claims.removeValue(forKey: uid)
        lock.unlock()

        publishActive()
        directory.removeFile(mapping.audioName)
        directory.removeFile(mapping.eqName)
    }

    /// Selects which device's ring the render callback consumes (nil = silence).
    func setActiveDevice(uid: String?) {
        lock.lock()
        activeUID = uid
        lock.unlock()
        publishActive()
    }

    func startHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: heartbeatQueue)
        timer.schedule(deadline: .now(), repeating: SoundBridgeConfig.heartbeatInterval)
        timer.setEventHandler { [weak self] in
            self?.heartbeatTick()
        }
        heartbeatTimer = timer
        timer.resume()
    }

    func stopHeartbeat() {
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
    }

    /// Stops rendering from shared memory, unlinks all IPC mappings, and drops them.
    func cleanup() {
        stopHeartbeat()
        lock.lock()
        let all = Array(mappings.values)
        mappings.removeAll()
        claims.removeAll()
        activeUID = nil
        lock.unlock()
        publishActive()
        for mapping in all {
            directory.removeFile(mapping.audioName)
            directory.removeFile(mapping.eqName)
        }
    }

    // MARK: - Private

    private func makeMapping(uid: String, sampleRate: UInt32, generation: UInt64) -> SharedAudioMapping? {
        guard let audioName = SessionDirectory.fileName(prefix: RF_IPC_AUDIO_PREFIX, deviceUID: uid),
              let eqName = SessionDirectory.fileName(prefix: RF_IPC_EQ_PREFIX, deviceUID: uid) else {
            logger.error("Device UID rejected for IPC naming")
            return nil
        }
        let capacity = rf_frames_for_duration(sampleRate, SoundBridgeConfig.defaultDurationMs)
        let audioLength = rf_shared_audio_size(capacity)
        guard audioLength > 0 else {
            logger.error("Unsupported ring geometry for \(sampleRate) Hz")
            return nil
        }

        var hash = [UInt8](repeating: 0, count: Int(RF_UID_HASH_SIZE))
        let utf8 = Array(uid.utf8)
        utf8.withUnsafeBufferPointer { bytes in
            bytes.baseAddress!.withMemoryRebound(to: CChar.self, capacity: bytes.count) {
                rf_uid_hash($0, bytes.count, &hash)
            }
        }

        do {
            // Only the audio ring is shared with the driver service; EQ stays owner-only.
            let audioBase = try directory.createMapping(audioName, length: audioLength, access: .readWrite) { base in
                rf_shared_audio_init(
                    base.assumingMemoryBound(to: RFSharedAudio.self), audioLength,
                    sampleRate, SoundBridgeConfig.defaultDurationMs, hash
                )
            }
            let audio = audioBase.assumingMemoryBound(to: RFSharedAudio.self)
            var layout = RFAudioLayout()
            guard rf_validate_layout(audio, audioLength, hash, &layout) == RF_LAYOUT_OK else {
                munmap(audioBase, audioLength)
                return nil
            }

            let eqBase: UnsafeMutableRawPointer
            do {
                eqBase = try directory.createMapping(eqName, length: Int(RF_EQ_CONTROL_SIZE), access: .none) { base in
                    rf_eq_control_init(base.assumingMemoryBound(to: RFEQControl.self), hash)
                    return true
                }
            } catch {
                munmap(audioBase, audioLength)
                throw error
            }

            return SharedAudioMapping(
                uid: uid,
                generation: generation,
                audioName: audioName,
                eqName: eqName,
                audio: audio,
                audioLength: audioLength,
                layout: layout,
                eq: eqBase.assumingMemoryBound(to: RFEQControl.self)
            )
        } catch {
            logger.error("Shared memory creation failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Points the render slot at the active device's mapping (or nil) and waits
    /// until no callback can still hold the previous session.
    private func publishActive() {
        lock.lock()
        let mapping = activeUID.flatMap { mappings[$0] }
        let previous = published
        // Whatever a driver wrote into this ring while it was not rendered
        // (for example during a bounce) is stale and must not be played now.
        if let mapping, mapping !== previous {
            rf_ring_consumer_drain(mapping.audio)
        }
        published = mapping
        _ = rf_render_slot_exchange(renderSlot, mapping?.session)
        lock.unlock()

        guard previous != nil, previous !== mapping else { return }
        if !waitForRenderQuiescence(), let previous {
            logger.error("Render callback did not quiesce; quarantining retired mapping")
            lock.lock()
            quarantined.append(previous)
            lock.unlock()
        }
    }

    private func waitForRenderQuiescence() -> Bool {
        let deadline = DispatchTime.now() + .milliseconds(500)
        while rf_render_slot_readers(renderSlot) != 0 {
            if DispatchTime.now() > deadline { return false }
            usleep(500)
        }
        return true
    }

    private func heartbeatTick() {
        lock.lock()
        let snapshot = Array(mappings.values) // strong references keep mappings alive while used
        lock.unlock()

        for mapping in snapshot {
            rf_update_host_heartbeat(mapping.audio)
        }

        telemetryCounter += 1
        guard telemetryCounter % 5 == 0 else { return }
        for mapping in snapshot {
            let underruns = rf_get_underrun_count(mapping.audio)
            let overruns = rf_get_overrun_count(mapping.audio)
            if underruns > lastUnderruns[mapping.uid, default: 0] {
                logger.debug("Buffer underruns: \(underruns)")
            }
            if overruns > lastOverruns[mapping.uid, default: 0] {
                logger.debug("Buffer overruns: \(overruns)")
            }
            lastUnderruns[mapping.uid] = underruns
            lastOverruns[mapping.uid] = overruns
        }
    }
}
