import Foundation
import CoreAudio
import AudioToolbox
import os.log

private let logger = Logger(subsystem: "com.soundbridge.host", category: "AudioEngine")

class AudioEngine {
    private let renderer: AudioRenderer
    private let registry: DeviceRegistry
    private var outputUnit: AudioUnit?
    private var currentDeviceID: AudioDeviceID?

    init(renderer: AudioRenderer, registry: DeviceRegistry) {
        self.renderer = renderer
        self.registry = registry
    }

    /// Query the nominal sample rate of a device via CoreAudio.
    private func getDeviceNominalSampleRate(_ deviceID: AudioDeviceID) -> UInt32 {
        var rateAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var sampleRate: Float64 = 0
        var dataSize = UInt32(MemoryLayout<Float64>.size)

        guard AudioObjectGetPropertyData(deviceID, &rateAddress, 0, nil, &dataSize, &sampleRate) == noErr else {
            return SoundBridgeConfig.defaultSampleRate
        }

        let supported: [UInt32] = [44100, 48000, 88200, 96000, 176400, 192000]
        let rate = UInt32(sampleRate)
        return supported.min(by: { abs(Int($0) - Int(rate)) < abs(Int($1) - Int(rate)) }) ?? SoundBridgeConfig.defaultSampleRate
    }

    /// Binds the output unit. With a preferred device only that device is tried:
    /// silently moving audio to another output could expose private playback on
    /// speakers the user did not select. Without a preference (no active proxy,
    /// so nothing is rendered) validated devices are tried in order.
    func setup(devices: [PhysicalDevice], preferredDeviceID: AudioDeviceID? = nil) throws {
        stop()
        guard !devices.isEmpty else {
            throw AudioEngineError.noPhysicalDeviceFound
        }

        if let preferredID = preferredDeviceID {
            guard let preferredDevice = devices.first(where: { $0.id == preferredID }) else {
                throw AudioEngineError.preferredDeviceUnavailable
            }
            do {
                try setupWithDevice(preferredDevice)
                logger.info("Bound to preferred device: \(preferredDevice.name)")
                return
            } catch {
                cleanupFailedSetup()
                throw error
            }
        }

        var lastError: Error?
        let sortedDevices = devices.filter(\.validationPassed) + devices.filter { !$0.validationPassed }
        for device in sortedDevices {
            do {
                try setupWithDevice(device)
                logger.info("Bound to: \(device.name)")
                return
            } catch {
                logger.error("Failed: \(String(describing: error))")
                lastError = error
                cleanupFailedSetup()
            }
        }
        throw lastError ?? AudioEngineError.allDevicesFailed
    }

    /// Legacy setup method - uses registry
    func setup() throws {
        try setup(devices: registry.devices)
    }

    /// Attempt setup with a specific device
    private func setupWithDevice(_ device: PhysicalDevice) throws {
        // Detect sample rate mismatch between Proxy Device config and Physical Device
        let proxySampleRate = SoundBridgeConfig.activeSampleRate
        let physicalSampleRate = getDeviceNominalSampleRate(device.id)

        if proxySampleRate != physicalSampleRate {
            print("[AudioEngine] Sample rate mismatch detected: proxy=\(proxySampleRate)Hz, physical=\(physicalSampleRate)Hz (\(device.name))")
            print("[AudioEngine] Updating activeSampleRate to \(physicalSampleRate)Hz to match physical device")
            SoundBridgeConfig.activeSampleRate = physicalSampleRate
            renderer.updateSampleRate(physicalSampleRate)
        } else {
            print("[AudioEngine] Sample rate matched: \(physicalSampleRate)Hz (\(device.name))")
        }

        var componentDesc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        guard let component = AudioComponentFindNext(nil, &componentDesc) else {
            throw AudioEngineError.componentNotFound
        }

        var unit: AudioUnit?
        let status = AudioComponentInstanceNew(component, &unit)
        guard status == noErr, let audioUnit = unit else {
            throw AudioEngineError.instanceCreationFailed(status)
        }

        outputUnit = audioUnit

        try setOutputDevice(device.id)
        try setFormat()
        try setRenderCallback()
        try initialize()

        currentDeviceID = device.id

        print("    Using device ID: \(device.id)")
    }

    /// Cleanup after a failed setup attempt
    private func cleanupFailedSetup() {
        guard let unit = outputUnit else { return }
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        outputUnit = nil
        currentDeviceID = nil
    }

    func start() throws {
        guard let unit = outputUnit else {
            throw AudioEngineError.unitNotInitialized
        }

        let status = AudioOutputUnitStart(unit)
        guard status == noErr else {
            throw AudioEngineError.startFailed(status)
        }
    }

    func stop() {
        guard let unit = outputUnit else { return }

        print("[Cleanup] Stopping audio unit...")
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        outputUnit = nil
        currentDeviceID = nil
    }

    func switchDevice(_ deviceID: AudioDeviceID) throws {
        guard let unit = outputUnit else {
            throw AudioEngineError.unitNotInitialized
        }

        let newSampleRate = getDeviceNominalSampleRate(deviceID)
        let needsFormatUpdate = (newSampleRate != SoundBridgeConfig.activeSampleRate)

        var isRunning: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let wasRunning = AudioUnitGetProperty(
            unit,
            kAudioOutputUnitProperty_IsRunning,
            kAudioUnitScope_Global,
            0,
            &isRunning,
            &size
        ) == noErr && isRunning != 0

        // Stop before touching sample-rate-dependent DSP state the callback uses.
        if wasRunning {
            AudioOutputUnitStop(unit)
        }
        if needsFormatUpdate {
            logger.info("Sample rate change: \(SoundBridgeConfig.activeSampleRate) Hz -> \(newSampleRate) Hz")
            SoundBridgeConfig.activeSampleRate = newSampleRate
            renderer.updateSampleRate(newSampleRate)
        }

        // Switch device
        var newDeviceID = deviceID
        let status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &newDeviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            if wasRunning { AudioOutputUnitStart(unit) }
            throw AudioEngineError.deviceSwitchFailed(status)
        }

        currentDeviceID = deviceID

        // Sample rate changed: reapply the stream format
        if needsFormatUpdate {
            AudioUnitUninitialize(unit)
            try setFormat()
            try initialize()
            print("[AudioEngine] Stream format updated to \(newSampleRate)Hz")
        }

        if wasRunning {
            AudioOutputUnitStart(unit)
        }
    }

    private func setOutputDevice(_ deviceID: AudioDeviceID) throws {
        guard let unit = outputUnit else {
            throw AudioEngineError.unitNotInitialized
        }

        var newDeviceID = deviceID
        let status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &newDeviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )

        guard status == noErr else {
            throw AudioEngineError.setDeviceFailed(status)
        }
    }

    private func setFormat() throws {
        guard let unit = outputUnit else {
            throw AudioEngineError.unitNotInitialized
        }

        var format = AudioStreamBasicDescription(
            mSampleRate: Double(SoundBridgeConfig.activeSampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: SoundBridgeConfig.defaultChannels,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        let status = AudioUnitSetProperty(
            unit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input,
            0,
            &format,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )

        guard status == noErr else {
            throw AudioEngineError.setFormatFailed(status)
        }

        // Read back the actual format to confirm what the audio unit accepted.
        var actualFormat = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let getStatus = AudioUnitGetProperty(
            unit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input,
            0,
            &actualFormat,
            &size
        )

        if getStatus == noErr {
            print("[AudioEngine] Stream format: \(actualFormat.mSampleRate) Hz, ch=\(actualFormat.mChannelsPerFrame), flags=0x\(String(actualFormat.mFormatFlags, radix: 16))")
        } else {
            logger.warning("Failed to read back stream format (OSStatus: \(getStatus))")
        }
    }

    private func setRenderCallback() throws {
        guard let unit = outputUnit else {
            throw AudioEngineError.unitNotInitialized
        }

        let rendererPtr = Unmanaged.passUnretained(renderer).toOpaque()

        var callbackStruct = AURenderCallbackStruct(
            inputProc: renderer.createRenderCallback(),
            inputProcRefCon: rendererPtr
        )

        let status = AudioUnitSetProperty(
            unit,
            kAudioUnitProperty_SetRenderCallback,
            kAudioUnitScope_Input,
            0,
            &callbackStruct,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        )

        guard status == noErr else {
            throw AudioEngineError.setCallbackFailed(status)
        }
    }

    private func initialize() throws {
        guard let unit = outputUnit else {
            throw AudioEngineError.unitNotInitialized
        }

        let status = AudioUnitInitialize(unit)
        guard status == noErr else {
            throw AudioEngineError.initializationFailed(status)
        }
    }

}

enum AudioEngineError: Error, CustomStringConvertible {
    case componentNotFound
    case instanceCreationFailed(OSStatus)
    case unitNotInitialized
    case setDeviceFailed(OSStatus)
    case setFormatFailed(OSStatus)
    case setCallbackFailed(OSStatus)
    case initializationFailed(OSStatus)
    case startFailed(OSStatus)
    case deviceSwitchFailed(OSStatus)
    case preferredDeviceUnavailable
    case noPhysicalDeviceFound
    case noValidDeviceFound
    case allDevicesFailed

    var description: String {
        switch self {
        case .componentNotFound:
            return "HAL output component not found"
        case .instanceCreationFailed(let status):
            return "Failed to create audio unit instance (OSStatus: \(status))"
        case .unitNotInitialized:
            return "Audio unit not initialized"
        case .setDeviceFailed(let status):
            return "Failed to set output device (OSStatus: \(status))"
        case .setFormatFailed(let status):
            return "Failed to set stream format (OSStatus: \(status))"
        case .setCallbackFailed(let status):
            return "Failed to set render callback (OSStatus: \(status))"
        case .initializationFailed(let status):
            return "Failed to initialize audio unit (OSStatus: \(status))"
        case .startFailed(let status):
            return "Failed to start audio unit (OSStatus: \(status))"
        case .deviceSwitchFailed(let status):
            return "Failed to switch device (OSStatus: \(status))"
        case .preferredDeviceUnavailable:
            return "Preferred output device is no longer available"
        case .noPhysicalDeviceFound:
            return "No physical output device found in registry"
        case .noValidDeviceFound:
            return "No validated output devices available"
        case .allDevicesFailed:
            return "All available devices failed to initialize"
        }
    }
}
