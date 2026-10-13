import CoreAudio
import Foundation

/// Fallback used when the host could not restore the output itself (for
/// example after it had to be force-stopped): move the system default output
/// off a SoundBridge proxy back to its physical device.
enum OutputDeviceRestorer {
    static func restorePhysicalIfOnProxy(logger: (String) -> Void = { print($0) }) {
        logger("[Cleanup] Starting cleanup process...")

        // 1. Restore default device to physical device (if currently on proxy)
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var currentDeviceID: AudioDeviceID = 0
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)

        if AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &currentDeviceID
        ) == noErr {
            // Get current device name
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceNameCFString,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )

            var deviceName: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)

            let nameStatus = withUnsafeMutablePointer(to: &deviceName) { ptr in
                AudioObjectGetPropertyData(currentDeviceID, &nameAddress, 0, nil, &nameSize, ptr)
            }
            if nameStatus == noErr, let name = deviceName?.takeUnretainedValue() as String? {

                // If currently on a SoundBridge proxy, switch back to physical device
                if name.contains("SoundBridge") {
                    logger("[Cleanup] Currently on proxy device: \(name)")

                    // Get proxy UID
                    var uidAddress = AudioObjectPropertyAddress(
                        mSelector: kAudioDevicePropertyDeviceUID,
                        mScope: kAudioObjectPropertyScopeGlobal,
                        mElement: kAudioObjectPropertyElementMain
                    )

                    var deviceUID: Unmanaged<CFString>?
                    var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)

                    let uidStatus = withUnsafeMutablePointer(to: &deviceUID) { ptr in
                        AudioObjectGetPropertyData(currentDeviceID, &uidAddress, 0, nil, &uidSize, ptr)
                    }
                    if uidStatus == noErr, let proxyUIDStr = deviceUID?.takeUnretainedValue() as String? {

                        // Extract physical device UID (remove "-soundbridge" suffix)
                        if let physicalUID = proxyUIDStr.components(separatedBy: "-soundbridge").first {
                            logger("[Cleanup] Looking for physical device with UID: \(physicalUID)")

                            // Find the physical device
                            if let physicalDeviceID = findDeviceByUID(physicalUID) {
                                logger("[Cleanup] Restoring default device to physical device (ID: \(physicalDeviceID))")

                                var newDeviceID = physicalDeviceID
                                let result = AudioObjectSetPropertyData(
                                    AudioObjectID(kAudioObjectSystemObject),
                                    &propertyAddress,
                                    0,
                                    nil,
                                    UInt32(MemoryLayout<AudioDeviceID>.size),
                                    &newDeviceID
                                )

                                // Also restore system output device
                                var systemAddress = AudioObjectPropertyAddress(
                                    mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                    mScope: kAudioObjectPropertyScopeGlobal,
                                    mElement: kAudioObjectPropertyElementMain
                                )
                                var systemDeviceID = physicalDeviceID
                                AudioObjectSetPropertyData(
                                    AudioObjectID(kAudioObjectSystemObject),
                                    &systemAddress,
                                    0,
                                    nil,
                                    UInt32(MemoryLayout<AudioDeviceID>.size),
                                    &systemDeviceID
                                )

                                if result == noErr {
                                    logger("[Cleanup] Restored to physical device")
                                    // CoreAudio device switch is synchronous, no sleep needed
                                } else {
                                    logger("[Cleanup] WARNING: Failed to restore device (error \(result))")
                                }
                            } else {
                                logger("[Cleanup] WARNING: Could not find physical device with UID: \(physicalUID)")
                            }
                        }
                    }
                } else {
                    logger("[Cleanup] Already on physical device: \(name)")
                }
            }
        }

        logger("[Cleanup] Cleanup complete")
    }

    static func findDeviceByUID(_ targetUID: String) -> AudioDeviceID? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize
        ) == noErr else {
            return nil
        }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)

        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceIDs
        ) == noErr else {
            return nil
        }

        // Find device with matching UID
        for deviceID in deviceIDs {
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )

            var deviceUID: Unmanaged<CFString>?
            var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)

            let uidStatus = withUnsafeMutablePointer(to: &deviceUID) { ptr in
                AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, ptr)
            }
            if uidStatus == noErr, let uid = deviceUID?.takeUnretainedValue() as String? {
                if uid == targetUID {
                    return deviceID
                }
            }
        }

        return nil
    }
}
