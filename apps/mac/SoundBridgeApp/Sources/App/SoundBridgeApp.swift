import SwiftUI
import Foundation
import Darwin
import AppKit
import CoreText
import CoreGraphics
import CoreAudio
import Sparkle

// Main entry point - AppKit-based app with SwiftUI views
@main
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var popover: NSPopover?
    let hostController = HostProcessController()
    var eventMonitor: EventMonitor?
    var onboardingCoordinator: OnboardingCoordinator?
    var updaterController: SPUStandardUpdaterController?
    var driverUpdateWindow: DriverUpdateWindow?
    /// Set during uninstall so the host's exit does not quit the app early.
    var isUninstalling = false
    private var hostRestartTimes: [Date] = []
    private static let maxHostRestarts = 3
    private static let hostRestartWindow: TimeInterval = 60
    private static let hostRestartDelay: TimeInterval = 2

    func applicationDidFinishLaunching(_ notification: Notification) {
        registerCustomFont()
        initializeUpdater()
        AppSessionIPC.removeLegacyFiles()

        hostController.onUnexpectedExit = { [weak self] status in
            guard let self, !self.isUninstalling, status != HostProcessController.exitCodeAlreadyRunning else { return }
            self.restartHostAfterCrash()
        }

        if !OnboardingState.hasCompleted() {
            // Will switch to .regular in showOnboarding()
            showOnboarding()
            return
        }

        // Onboarding complete - run as menu bar app only
        NSApp.setActivationPolicy(.accessory)
        LaunchAtLogin.shared.enableOnFirstRun()

        checkDriverStatus()
        launchHostIfNeeded()

        // Start IPC monitoring for device state updates from Host
        IPCController.shared.onDeviceStateChanged = { _ in
            VolumeController.shared.refreshDeviceList()
            VolumeController.shared.findAndBindProxyDevice()
        }
        IPCController.shared.startMonitoring()

        // Retry proxy binding: the host may not have created proxies yet.
        // Off the main thread in case CoreAudio HAL is slow to respond.
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 2.0) {
            VolumeController.shared.refreshDeviceList()
            VolumeController.shared.findAndBindProxyDevice()
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 5.0) {
            VolumeController.shared.refreshDeviceList()
            VolumeController.shared.findAndBindProxyDevice()
        }

        setupMenuBar()
    }

    /// Sparkle starts only when this build carries an HTTPS feed and an EdDSA
    /// key. Scheduled checks then follow the user's preference; nothing is
    /// forced at launch.
    func initializeUpdater() {
        guard Self.isUpdateChannelConfigured(Bundle.main.infoDictionary ?? [:]) else {
            print("Sparkle disabled: SUFeedURL/SUPublicEDKey not configured for this build")
            return
        }
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    static func isUpdateChannelConfigured(_ info: [String: Any]) -> Bool {
        guard let feed = info["SUFeedURL"] as? String,
              let url = URL(string: feed), url.scheme == "https", url.host != nil,
              let key = info["SUPublicEDKey"] as? String,
              let keyData = Data(base64Encoded: key), keyData.count == 32 else {
            return false
        }
        return true
    }

    /// The host owns the audio path, so a crash is recovered rather than ending
    /// the app. A crash loop still quits instead of restarting forever.
    func restartHostAfterCrash() {
        let now = Date()
        hostRestartTimes = hostRestartTimes.filter { now.timeIntervalSince($0) < Self.hostRestartWindow }
        guard hostRestartTimes.count < Self.maxHostRestarts else {
            showAlert("SoundBridge Stopped", "The audio host keeps exiting, so SoundBridge has stopped. Audio plays directly on your devices.")
            NSApp.terminate(nil)
            return
        }
        hostRestartTimes.append(now)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hostRestartDelay) { [weak self] in
            guard let self, !self.isUninstalling else { return }
            self.launchHostIfNeeded()
        }
    }

    func launchHostIfNeeded() {
        switch hostController.launchIfNeeded() {
        case .started, .alreadyRunning:
            break
        case .notFound:
            showAlert("SoundBridge Host Not Found", "This copy of SoundBridge is incomplete. Please reinstall it.")
        case .failed(let error):
            showAlert("Failed to Launch Host", error.localizedDescription)
        }
    }

    /// Prompts on every launch until the installed driver matches this app.
    func checkDriverStatus() {
        let action = VersionManager.currentDriverAction()
        let installed = VersionManager.installedDriverVersion()
        let bundled = VersionManager.bundledDriverVersion() ?? "unknown"

        switch action {
        case .none:
            return
        case .bundleMissing:
            print("No bundled driver in this build; skipping driver check")
        case .newerIncompatibleInstalled(let version):
            showAlert(
                "Update SoundBridge",
                "The installed audio driver (\(version)) is newer than this app supports. Install the latest SoundBridge."
            )
        case .install:
            showDriverUpdatePrompt(currentVersion: "Not installed", newVersion: bundled, operation: .install)
        case .update, .repair:
            let operation = DriverOperation(action: action) ?? .repair
            showDriverUpdatePrompt(currentVersion: installed ?? "Damaged", newVersion: bundled, operation: operation)
        case .reloadRequired(let loaded):
            showDriverUpdatePrompt(currentVersion: loaded, newVersion: bundled, operation: .repair)
        }
    }

    func showDriverUpdatePrompt(currentVersion: String, newVersion: String, operation: DriverOperation) {
        driverUpdateWindow?.close()
        driverUpdateWindow = DriverUpdateWindow(
            currentVersion: currentVersion,
            newVersion: newVersion,
            onUpdate: { [weak self] in
                self?.performDriverUpdate(operation)
            },
            onDismiss: { [weak self] in
                self?.driverUpdateWindow?.close()
                self?.driverUpdateWindow = nil
            }
        )
        driverUpdateWindow?.center()
        driverUpdateWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Reports success only after the installed bundle (and, when Core Audio
    /// exposes it, the loaded driver) has been verified.
    func performDriverUpdate(_ operation: DriverOperation) {
        driverUpdateWindow?.close()
        driverUpdateWindow = nil

        Task { @MainActor in
            let installer = DriverInstaller()
            do {
                switch try await installer.perform(operation) {
                case .verified(let identity):
                    showAlert(
                        "Driver Updated",
                        "The SoundBridge audio driver \(identity.version) is installed and running.",
                        style: .informational
                    )
                case .removed:
                    break
                }
            } catch DriverInstallError.cancelled {
                showAlert("Driver Not Updated", "Authorization was cancelled. The previous driver is still in use; you will be asked again next time SoundBridge starts.")
            } catch {
                showAlert("Update Failed", error.localizedDescription, style: .critical)
            }
        }
    }

    func showOnboarding() {
        // Switch to regular activation policy to show window properly
        NSApp.setActivationPolicy(.regular)

        // Create and show onboarding
        onboardingCoordinator = OnboardingCoordinator()
        onboardingCoordinator?.show(onComplete: { [weak self] in
            print("Onboarding completion callback called")
            self?.launchHostIfNeeded()
            self?.setupMenuBar()
            // Retry proxy binding after host has time to start
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 2.0) {
                VolumeController.shared.refreshDeviceList()
                VolumeController.shared.findAndBindProxyDevice()
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 5.0) {
                VolumeController.shared.refreshDeviceList()
                VolumeController.shared.findAndBindProxyDevice()
            }
            print("Host and menu bar setup complete")
        })

        print("Showing onboarding")
    }

    func setupMenuBar() {
        print("setupMenuBar() called")

        // Hide from Dock (menu bar only)
        NSApp.setActivationPolicy(.accessory)
        print("Activation policy set to .accessory")

        // Create status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        print("Status bar item created: \(statusItem != nil)")

        if let button = statusItem?.button {
            // Load logo SVG and set as template for light/dark mode adaptation
            if let logoImage = loadLogoImage() {
                logoImage.isTemplate = true // Makes it adapt to light/dark mode
                button.image = logoImage
            } else {
                // Fallback to system icon if logo fails to load
                button.image = NSImage(systemSymbolName: "waveform.circle.fill", accessibilityDescription: "SoundBridge")
            }
            button.action = #selector(togglePopover)
            button.target = self
            print("Status bar button configured with waveform icon")
        } else {
            print("ERROR: Could not get status bar button!")
        }

        // Create popover with menu content
        popover = NSPopover()
        popover?.behavior = .transient
        popover?.animates = false
        popover?.contentViewController = NSHostingController(rootView: MenuBarView())
        
        // Set up event monitor to dismiss popover when clicking outside
        eventMonitor = EventMonitor(mask: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if let popover = self?.popover, popover.isShown {
                self?.popover?.performClose(event)
            }
        }
        print("Menu bar setup complete - icon should be visible")
    }

    func applicationWillTerminate(_ notification: Notification) {
        // The uninstall flow has already stopped the host.
        guard !isUninstalling else { return }

        VolumeController.shared.cleanup()
        IPCController.shared.stopMonitoring()

        // The host restores the physical output and withdraws its proxies itself;
        // the app only falls back to restoring output if the host had to be killed.
        if !hostController.stop() {
            OutputDeviceRestorer.restorePhysicalIfOnProxy()
        }
    }

    func showAlert(_ title: String, _ message: String, style: NSAlert.Style = .warning) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc func togglePopover() {
        guard let button = statusItem?.button else { return }

        if let popover = popover {
            if popover.isShown {
                popover.performClose(nil)
                eventMonitor?.stop()
            } else {
                // Position the popover directly below the menu bar button
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

                // Make popover window key immediately for proper glass effect
                if let popoverWindow = popover.contentViewController?.view.window {
                    popoverWindow.makeKeyAndOrderFront(nil)
                }

                // On macOS 15+ (Tahoe/Sequoia), NSPopover positioning can be off on external
                // monitors. Manually reposition if needed.
                if #available(macOS 15.0, *) {
                    if let popoverWindow = popover.contentViewController?.view.window,
                       let buttonWindow = button.window {
                        let buttonScreenFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
                        let popoverFrame = popoverWindow.frame

                        // Calculate where the popover should be: directly below the button
                        let targetY = buttonScreenFrame.minY - popoverFrame.height

                        // Only adjust if there's a significant gap (more than 10 pixels)
                        if abs(popoverFrame.maxY - buttonScreenFrame.minY) > 10 {
                            popoverWindow.setFrameOrigin(NSPoint(x: popoverFrame.origin.x, y: targetY))
                        }
                    }
                }

                eventMonitor?.start()
            }
        }
    }
}

// EventMonitor to detect clicks outside the popover
class EventMonitor {
    private var monitor: Any?
    private let mask: NSEvent.EventTypeMask
    private let handler: (NSEvent?) -> Void

    init(mask: NSEvent.EventTypeMask, handler: @escaping (NSEvent?) -> Void) {
        self.mask = mask
        self.handler = handler
    }

    deinit {
        stop()
    }

    func start() {
        monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler)
    }

    func stop() {
        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}

// Main entry point - check for command-line flags before launching app
extension AppDelegate {
    static func main() {
        // Check for --reset-onboarding flag
        if CommandLine.arguments.contains("--reset-onboarding") {
            OnboardingState.reset()
            print("Onboarding reset - will show on next launch")
        }

        // Launch the app
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
