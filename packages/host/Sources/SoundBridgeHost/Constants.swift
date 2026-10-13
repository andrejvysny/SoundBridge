import Foundation
import CSoundBridgeAudio

struct SoundBridgeConfig {
    /// Thread-safe access to the active sample rate
    private static var _activeSampleRate: UInt32 = 48000
    private static var sampleRateLock = os_unfair_lock()

    static var activeSampleRate: UInt32 {
        get {
            os_unfair_lock_lock(&sampleRateLock)
            defer { os_unfair_lock_unlock(&sampleRateLock) }
            return _activeSampleRate
        }
        set {
            os_unfair_lock_lock(&sampleRateLock)
            _activeSampleRate = newValue
            os_unfair_lock_unlock(&sampleRateLock)
        }
    }
    /// Fallback sample rate if device query fails
    static let defaultSampleRate: UInt32 = 48000
    static let defaultChannels: UInt32 = 2
    static let defaultDurationMs: UInt32 = 100

    static let heartbeatInterval: TimeInterval = 1.0
    static let wakeRecoveryDelay: TimeInterval = 1.5
    static let wakeRetryMaxAttempts = 4
    static let wakeRetryDelays: [TimeInterval] = [0, 2.0, 4.0, 8.0]

    static let deviceWaitTimeout: TimeInterval = 2.0
    static let cleanupWaitTimeout: TimeInterval = 1.2
    /// Minimum spacing between reconnect bounces, whatever triggers them.
    static let bounceMinInterval: TimeInterval = 2.0
    static let physicalDeviceSwitchDelay: TimeInterval = 0.5
}
