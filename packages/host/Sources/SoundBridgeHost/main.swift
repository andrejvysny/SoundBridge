import AudioToolbox
import CSoundBridgeAudio
import CoreAudio
import Darwin
import Foundation
import os.log

private let logger = Logger(subsystem: "com.soundbridge.host", category: "Main")

/// Exit code when another host already owns this user's session.
private let exitCodeAlreadyRunning: Int32 = 3

let sessionDirectory: SessionDirectory = {
    do {
        return try SessionDirectory()
    } catch {
        logger.error("\(String(describing: error), privacy: .public)")
        exit(1)
    }
}()

let deviceDiscovery = DeviceDiscovery()
let deviceRegistry = DeviceRegistry(directory: sessionDirectory)
let memoryManager = SharedMemoryManager(directory: sessionDirectory)
let volumePersistence = VolumePersistence()
let proxyManager = ProxyDeviceManager(registry: deviceRegistry, volumePersistence: volumePersistence)
let renderer = AudioRenderer(renderSlot: memoryManager.renderSlot)
let audioEngine = AudioEngine(renderer: renderer, registry: deviceRegistry)
let deviceMonitor = DeviceMonitor(
    registry: deviceRegistry,
    proxyManager: proxyManager,
    memoryManager: memoryManager,
    discovery: deviceDiscovery,
    audioEngine: audioEngine
)
let sleepWakeMonitor = SleepWakeMonitor()
let parentWatcher = ParentProcessWatcher()
let bounceListener = BounceRequestListener(directory: sessionDirectory) {
    proxyManager.bounceDevice()
}
var instanceLock: HostInstanceLock?
private var signalSources: [DispatchSourceSignal] = []

func main() {
    // Prevent App Nap from throttling timers during long playback (heartbeat timeouts).
    let _ = ProcessInfo.processInfo.beginActivity(
        options: [.userInitiated, .latencyCritical],
        reason: "SoundBridge realtime audio processing"
    )

    instanceLock = HostInstanceLock(directory: sessionDirectory)
    guard instanceLock != nil else {
        logger.error("Another SoundBridge host is already running for this user")
        exit(exitCodeAlreadyRunning)
    }
    // We own the session: drop anything a crashed host left behind, including
    // its audio buffers.
    let staleFiles = sessionDirectory.removeStaleArtifacts()
    if staleFiles > 0 {
        logger.info("Removed \(staleFiles) stale session file(s) from a previous run")
    }

    print("[Step 0] Setting up directories...")
    do {
        try PathManager.ensureDirectories()
    } catch {
        logger.error("Failed to create directories: \(error.localizedDescription)")
        exit(1)
    }

    print("[Step 1] Discovering physical audio devices...")
    let devices = deviceDiscovery.enumeratePhysicalDevices()
    guard !devices.isEmpty else {
        logger.error("No physical output devices found")
        exit(1)
    }
    let validatedDevices = devices.filter { $0.validationPassed }
    logger.info("Found \(devices.count) physical output device(s) (\(validatedDevices.count) validated)")

    proxyManager.onActiveProxyChanged = { uid in
        memoryManager.setActiveDevice(uid: uid)
    }

    // Query device sample rate for HiFi/lossless audio support
    let preferredDevice = proxyManager.resolveCurrentOutputDevice(in: devices)
        ?? validatedDevices.first
        ?? devices.first!
    SoundBridgeConfig.activeSampleRate = deviceDiscovery.getDeviceNominalSampleRate(preferredDevice.id)
    print("[Step 1.5] Sample rate: \(SoundBridgeConfig.activeSampleRate) Hz")

    print("[Step 2] Creating shared memory...")
    // Mappings must exist before the control file announces the devices.
    memoryManager.createMemory(for: devices, sampleRate: SoundBridgeConfig.activeSampleRate)
    memoryManager.startHeartbeat()

    print("[Step 3] Publishing device list and registering listeners...")
    deviceRegistry.update(devices)
    deviceMonitor.registerListeners()

    print("[Step 4] Waiting for driver to create proxy devices...")
    Thread.sleep(forTimeInterval: SoundBridgeConfig.deviceWaitTimeout)

    print("[Step 5] Auto-selecting proxy device...")
    proxyManager.autoSelectProxy()

    // Bounce to recapture apps that were already playing. Runs on the main
    // queue, which owns all control-plane state.
    if proxyManager.activeProxyDeviceID != 0 {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            proxyManager.bounceDevice()
        }
    }

    sleepWakeMonitor.onSleep = {
        audioEngine.stop()
        logger.info("AudioEngine stopped before sleep")
    }
    sleepWakeMonitor.onWake = {
        deviceMonitor.reregisterListeners()
        deviceMonitor.resetDebounce()
        proxyManager.reregisterVolumeForwarding()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let preferred = proxyManager.activePhysicalDeviceID
            do {
                try audioEngine.setup(devices: deviceRegistry.devices, preferredDeviceID: preferred != 0 ? preferred : nil)
                try audioEngine.start()
                logger.info("AudioEngine restarted after wake")
            } catch {
                logger.error("AudioEngine restart failed; output stays silent: \(String(describing: error), privacy: .public)")
            }
        }
    }
    sleepWakeMonitor.start()

    print("[Step 6] Starting audio engine...")
    let preferredDeviceID = proxyManager.activePhysicalDeviceID
    do {
        try audioEngine.setup(devices: devices, preferredDeviceID: preferredDeviceID != 0 ? preferredDeviceID : nil)
        try audioEngine.start()
        logger.info("Audio engine started successfully")

        // After IO starts the driver maps shared memory; re-apply the proxy
        // volume so the driver publishes the real value instead of silence.
        if proxyManager.activeProxyDeviceID != 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if let physicalUID = proxyManager.activeProxyUID {
                    proxyManager.restoreVolumeState(
                        proxyDeviceID: proxyManager.activeProxyDeviceID,
                        physicalUID: physicalUID
                    )
                }
            }
        }
    } catch {
        logger.error("Audio engine setup failed: \(String(describing: error), privacy: .public)")
        cleanup()
        exit(1)
    }

    setupSignalHandlers()
    parentWatcher.start {
        logger.info("Launching process exited, shutting down")
        cleanup()
        exit(0)
    }
    bounceListener.start()

    RunLoop.current.run()
}

func setupSignalHandlers() {
    for signalNumber in [SIGINT, SIGTERM] {
        signal(signalNumber, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
        source.setEventHandler {
            cleanup()
            exit(0)
        }
        source.resume()
        signalSources.append(source)
    }
}

/// Restores the physical output, withdraws the proxies, and removes IPC files.
/// Bounded and fast so the app's graceful-stop deadline is rarely reached.
func cleanup() {
    bounceListener.stop()
    parentWatcher.stop()
    sleepWakeMonitor.stop()

    // Restore before withdrawing proxies so CoreAudio does not pick an unrelated default.
    _ = proxyManager.restorePhysicalDevice()
    audioEngine.stop()

    // The driver re-reads the session on this notification and removes proxies.
    deviceRegistry.removeControlFile()
    memoryManager.cleanup()
    instanceLock = nil
    logger.info("Cleanup complete")
}

main()
