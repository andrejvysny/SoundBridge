import AudioToolbox
import CSoundBridgeAudio
import CSoundBridgeDSP
import CoreAudio
import Foundation
import os.log

private let logger = Logger(subsystem: "com.soundbridge.host", category: "AudioRenderer")

/// Realtime render path: ring read -> input bounds -> EQ -> DSP -> gain -> output bounds.
/// Everything reachable from `render` is allocation-, lock-, and log-free; the
/// active mapping arrives through the RCU render slot owned by SharedMemoryManager.
final class AudioRenderer {
    /// Largest callback size served; larger requests render silence.
    static let maxFramesPerCallback = 8192

    private let renderSlot: UnsafeMutablePointer<RFRenderSlot>
    private let buffer: UnsafeMutablePointer<Float>
    private let useTestTone: Bool
    private var testTonePhase: Float = 0
    private var testTonePhaseIncrement: Float
    private var dspEngine: OpaquePointer?

    // Gain stage
    private var currentGain: Float = -1.0 // negative = uninitialized, snap on first frame
    private let smoothingCoeff: Float = 0.995 // ~10ms at 48kHz

    // EQ state, reapplied whenever the published mapping changes
    private var lastEQSnapshot = RFEQSnapshot()
    private var lastGeneration: UInt64 = 0

    /// Pre-DSP bound: generous headroom for hot float sources, but finite.
    private static let inputSampleLimit: Float = 8.0
    /// Final bound after all gain stages, including bypass and unity gain.
    private static let outputSampleLimit: Float = 1.0

    init(renderSlot: UnsafeMutablePointer<RFRenderSlot>) {
        self.renderSlot = renderSlot
        buffer = .allocate(capacity: Self.maxFramesPerCallback * 2)
        buffer.initialize(repeating: 0, count: Self.maxFramesPerCallback * 2)
        useTestTone = ProcessInfo.processInfo.environment["RF_TEST_TONE"] == "1"
        let sampleRate = SoundBridgeConfig.activeSampleRate
        testTonePhaseIncrement = (2.0 * Float.pi * 440.0) / Float(sampleRate)
        dspEngine = soundbridge_dsp_create(sampleRate)
        if let engine = dspEngine {
            applyInitialPreset(engine: engine)
        }
    }

    deinit {
        if let engine = dspEngine {
            soundbridge_dsp_destroy(engine)
        }
        buffer.deallocate()
    }

    /// Must only be called while the output unit is stopped.
    func updateSampleRate(_ sampleRate: UInt32) {
        testTonePhaseIncrement = (2.0 * Float.pi * 440.0) / Float(sampleRate)
        guard let engine = dspEngine else { return }
        let result = soundbridge_dsp_set_sample_rate(engine, sampleRate)
        if result != SOUNDBRIDGE_OK {
            logger.error("Failed to update DSP sample rate (error: \(result.rawValue))")
        }
    }

    func createRenderCallback() -> AURenderCallback {
        return { inRefCon, _, _, _, inNumberFrames, ioData -> OSStatus in
            guard let bufferList = ioData else { return noErr }
            let renderer = Unmanaged<AudioRenderer>.fromOpaque(inRefCon).takeUnretainedValue()
            renderer.render(bufferList: bufferList, frameCount: inNumberFrames)
            return noErr
        }
    }

    private func render(bufferList: UnsafeMutablePointer<AudioBufferList>, frameCount: UInt32) {
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        let frames = Int(frameCount)
        let byteCount = frames * MemoryLayout<Float>.size
        guard frames <= Self.maxFramesPerCallback, buffers.count == 2,
              let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
              let right = buffers[1].mData?.assumingMemoryBound(to: Float.self),
              Int(buffers[0].mDataByteSize) >= byteCount, Int(buffers[1].mDataByteSize) >= byteCount
        else {
            outputSilence(bufferList: bufferList)
            return
        }

        let sampleCount = frames * 2
        guard let session = rf_render_slot_acquire(renderSlot) else {
            rf_render_slot_release(renderSlot)
            currentGain = -1.0
            outputSilence(bufferList: bufferList)
            return
        }
        defer { rf_render_slot_release(renderSlot) }

        let framesRead: Int
        if useTestTone {
            renderTestTone(frames: frames)
            framesRead = frames
        } else {
            framesRead = Int(rf_render_session_read(session, buffer, sampleCount))
        }
        let readSamples = framesRead * 2
        _ = rf_sanitize_samples(buffer, readSamples, Self.inputSampleLimit)

        if let engine = dspEngine, framesRead > 0 {
            applyEQChanges(session: session, engine: engine)
            soundbridge_dsp_process_interleaved(engine, buffer, buffer, UInt32(framesRead))
            // A poisoned filter state would keep emitting NaN; reset and drop this block.
            if rf_sanitize_samples(buffer, readSamples, Float.greatestFiniteMagnitude) > 0 {
                soundbridge_dsp_reset(engine)
                buffer.update(repeating: 0, count: readSamples)
            }
        }

        applyGain(session: session, frames: framesRead)
        _ = rf_sanitize_samples(buffer, sampleCount, Self.outputSampleLimit)

        for frame in 0..<frames {
            left[frame] = buffer[frame * 2]
            right[frame] = buffer[frame * 2 + 1]
        }
    }

    private func applyEQChanges(session: UnsafePointer<RFRenderSession>, engine: OpaquePointer) {
        var snapshot = RFEQSnapshot()
        // On a failed or torn read keep the last accepted snapshot.
        guard rf_render_session_load_eq(session, &snapshot) else { return }
        let generation = rf_render_session_generation(session)
        let changed = generation != lastGeneration || withUnsafeBytes(of: &snapshot, { new in
            withUnsafeBytes(of: &lastEQSnapshot) { old in
                memcmp(new.baseAddress!, old.baseAddress!, MemoryLayout<RFEQSnapshot>.size) != 0
            }
        })
        guard changed else { return }

        withUnsafePointer(to: &snapshot.bands) { pointer in
            pointer.withMemoryRebound(to: Float.self, capacity: Int(RF_EQ_BAND_COUNT)) { bands in
                for index in 0..<Int(RF_EQ_BAND_COUNT) {
                    soundbridge_dsp_update_band_gain(engine, UInt32(index), bands[index])
                }
            }
        }
        soundbridge_dsp_update_preamp(engine, snapshot.preamp)
        soundbridge_dsp_set_bypass(engine, snapshot.bypass != 0)
        lastEQSnapshot = snapshot
        lastGeneration = generation
    }

    /// macOS volumeScalar is already perceptually mapped, so it is used directly
    /// as linear gain. Values are sanitized to [0, 1] by the protocol accessor.
    private func applyGain(session: UnsafePointer<RFRenderSession>, frames: Int) {
        let volume = rf_render_session_volume(session)
        let targetGain: Float = rf_render_session_muted(session) ? 0.0 : volume

        if currentGain < 0.0 {
            currentGain = targetGain
        }
        if targetGain == 0.0 {
            // Mute / zero volume: hard silence, no smoothing tail.
            currentGain = 0.0
            buffer.update(repeating: 0, count: frames * 2)
        } else if targetGain == 1.0 && currentGain > 0.999 {
            currentGain = 1.0
        } else {
            for frame in 0..<frames {
                currentGain = currentGain * smoothingCoeff + targetGain * (1.0 - smoothingCoeff)
                if currentGain < 1.0e-6 { currentGain = 0.0 }
                buffer[frame * 2] *= currentGain
                buffer[frame * 2 + 1] *= currentGain
            }
        }
    }

    private func renderTestTone(frames: Int) {
        for frame in 0..<frames {
            let sample = sin(testTonePhase) * 0.2
            buffer[frame * 2] = sample
            buffer[frame * 2 + 1] = sample
            testTonePhase += testTonePhaseIncrement
            if testTonePhase > 2.0 * Float.pi {
                testTonePhase -= 2.0 * Float.pi
            }
        }
    }

    private func applyInitialPreset(engine: OpaquePointer) {
        var preset = soundbridge_preset_t()
        preset.num_bands = 10
        preset.preamp_db = 0.0
        preset.limiter_enabled = true

        // Band 0: lowShelf, 32 Hz, enabled
        preset.bands.0.frequency_hz = 32.0
        preset.bands.0.gain_db = 0.0
        preset.bands.0.q_factor = 0.7
        preset.bands.0.type = SOUNDBRIDGE_FILTER_LOW_SHELF
        preset.bands.0.enabled = true

        // Band 1: lowShelf, 64 Hz, enabled
        preset.bands.1.frequency_hz = 64.0
        preset.bands.1.gain_db = 0.0
        preset.bands.1.q_factor = 0.7
        preset.bands.1.type = SOUNDBRIDGE_FILTER_LOW_SHELF
        preset.bands.1.enabled = true

        // Band 2: lowShelf, 125 Hz, enabled
        preset.bands.2.frequency_hz = 125.0
        preset.bands.2.gain_db = 0.0
        preset.bands.2.q_factor = 0.7
        preset.bands.2.type = SOUNDBRIDGE_FILTER_LOW_SHELF
        preset.bands.2.enabled = true

        // Band 3: peak, 250 Hz, DISABLED
        preset.bands.3.frequency_hz = 250.0
        preset.bands.3.gain_db = 0.0
        preset.bands.3.q_factor = 1.0
        preset.bands.3.type = SOUNDBRIDGE_FILTER_PEAK
        preset.bands.3.enabled = false

        // Band 4: peak, 500 Hz, enabled
        preset.bands.4.frequency_hz = 500.0
        preset.bands.4.gain_db = 0.0
        preset.bands.4.q_factor = 1.2
        preset.bands.4.type = SOUNDBRIDGE_FILTER_PEAK
        preset.bands.4.enabled = true

        // Band 5: peak, 1000 Hz, enabled
        preset.bands.5.frequency_hz = 1000.0
        preset.bands.5.gain_db = 0.0
        preset.bands.5.q_factor = 1.2
        preset.bands.5.type = SOUNDBRIDGE_FILTER_PEAK
        preset.bands.5.enabled = true

        // Band 6: peak, 2000 Hz, DISABLED
        preset.bands.6.frequency_hz = 2000.0
        preset.bands.6.gain_db = 0.0
        preset.bands.6.q_factor = 1.0
        preset.bands.6.type = SOUNDBRIDGE_FILTER_PEAK
        preset.bands.6.enabled = false

        // Band 7: peak, 4000 Hz, DISABLED
        preset.bands.7.frequency_hz = 4000.0
        preset.bands.7.gain_db = 0.0
        preset.bands.7.q_factor = 1.0
        preset.bands.7.type = SOUNDBRIDGE_FILTER_PEAK
        preset.bands.7.enabled = false

        // Band 8: highShelf, 8000 Hz, enabled
        preset.bands.8.frequency_hz = 8000.0
        preset.bands.8.gain_db = 0.0
        preset.bands.8.q_factor = 0.7
        preset.bands.8.type = SOUNDBRIDGE_FILTER_HIGH_SHELF
        preset.bands.8.enabled = true

        // Band 9: highShelf, 16000 Hz, enabled
        preset.bands.9.frequency_hz = 16000.0
        preset.bands.9.gain_db = 0.0
        preset.bands.9.q_factor = 0.7
        preset.bands.9.type = SOUNDBRIDGE_FILTER_HIGH_SHELF
        preset.bands.9.enabled = true

        soundbridge_dsp_apply_preset(engine, &preset)
    }

    private func outputSilence(bufferList: UnsafeMutablePointer<AudioBufferList>) {
        for audioBuffer in UnsafeMutableAudioBufferListPointer(bufferList) {
            guard let data = audioBuffer.mData else { continue }
            memset(data, 0, Int(audioBuffer.mDataByteSize))
        }
    }
}
