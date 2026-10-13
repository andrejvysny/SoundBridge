import AppKit
import CoreText
import Foundation

// Bundle resource lookup. Source-tree and home-directory fallbacks exist only in
// DEBUG builds so a release app never loads fonts or images from user-writable paths.
extension AppDelegate {
    func loadLogoImage() -> NSImage? {
        let fileManager = FileManager.default
        var logoURL: URL?

        // PRIORITY 1: Try using Bundle's resource API (works across bundle structures)
        // First try to find the resource bundle
        if let resourceBundleURL = Bundle.main.url(forResource: "SoundBridgeApp_SoundBridgeApp", withExtension: "bundle"),
           let resourceBundle = Bundle(url: resourceBundleURL),
           let logoPath = resourceBundle.url(forResource: "icons/soundbridge-menu", withExtension: "svg") {
            print("Found menu icon via resource bundle API: \(logoPath.path)")
            logoURL = logoPath
        }

        // PRIORITY 2: Try SwiftPM resource bundle (production builds)
        // SwiftPM creates a separate bundle named "<Target>_<Target>.bundle"
        if logoURL == nil, let executableURL = Bundle.main.executableURL {
            let bundleName = "SoundBridgeApp_SoundBridgeApp.bundle"
            let resourceBundleURL = executableURL
                .deletingLastPathComponent()
                .appendingPathComponent(bundleName)
                .appendingPathComponent("Resources/icons/soundbridge-menu.svg")

            if fileManager.fileExists(atPath: resourceBundleURL.path) {
                print("Found logo in SwiftPM bundle: \(resourceBundleURL.path)")
                logoURL = resourceBundleURL
            }
        }

        // PRIORITY 3: Try main bundle's built-in resource lookup
        if logoURL == nil, let mainBundleURL = Bundle.main.url(forResource: "icons/soundbridge-menu", withExtension: "svg") {
            print("Found menu icon via main bundle: \(mainBundleURL.path)")
            logoURL = mainBundleURL
        }

        // PRIORITY 4: Try main bundle resources (alternative bundle structure)
        if logoURL == nil, let resourcePath = Bundle.main.resourcePath {
            let possiblePaths = [
                "\(resourcePath)/Resources/icons/soundbridge-menu.svg",
                "\(resourcePath)/icons/soundbridge-menu.svg"
            ]

            for path in possiblePaths {
                if fileManager.fileExists(atPath: path) {
                    print("Found logo in main bundle: \(path)")
                    logoURL = URL(fileURLWithPath: path)
                    break
                }
            }
        }

        #if DEBUG
        // PRIORITY 5: Development - relative to executable
        if logoURL == nil, let executablePath = Bundle.main.executablePath {
            let executableDir = (executablePath as NSString).deletingLastPathComponent
            let sourcePath = (executableDir as NSString).appendingPathComponent("../../../Sources/Resources/icons/soundbridge-menu.svg")
            let normalizedPath = (sourcePath as NSString).standardizingPath
            if fileManager.fileExists(atPath: normalizedPath) {
                print("Found logo in development Sources: \(normalizedPath)")
                logoURL = URL(fileURLWithPath: normalizedPath)
            }
        }

        // PRIORITY 6: Development - absolute path from repo root
        if logoURL == nil {
            let homeDir = ProcessInfo.processInfo.environment["HOME"] ?? ""
            let absolutePath = "\(homeDir)/soundbridge/apps/mac/SoundBridgeApp/Sources/Resources/icons/soundbridge-menu.svg"
            if fileManager.fileExists(atPath: absolutePath) {
                print("Found menu icon at absolute path: \(absolutePath)")
                logoURL = URL(fileURLWithPath: absolutePath)
            }
        }

        #endif

        guard let url = logoURL else {
            print("Failed to find soundbridge-menu.svg in any location")
            return nil
        }

        // Load SVG (NSImage supports SVG on macOS 10.15+)
        guard let image = NSImage(contentsOf: url) else {
            print("Failed to load image from: \(url.path)")
            return nil
        }

        // Resize to appropriate menu bar size (typically 18-22px)
        let size = NSSize(width: 16, height: 16)
        let resizedImage = NSImage(size: size)
        resizedImage.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: size), from: NSRect(origin: .zero, size: image.size), operation: .sourceOver, fraction: 1.0)
        resizedImage.unlockFocus()

        print("Successfully loaded and resized logo")
        return resizedImage
    }
    
    func registerCustomFont() {
        let fileManager = FileManager.default
        var fontURL: URL?

        // PRIORITY 1: Try using Bundle's resource API (works across bundle structures)
        if let resourceBundleURL = Bundle.main.url(forResource: "SoundBridgeApp_SoundBridgeApp", withExtension: "bundle"),
           let resourceBundle = Bundle(url: resourceBundleURL),
           let fontPath = resourceBundle.url(forResource: "fonts/SignPainterHouseScript", withExtension: "ttf") {
            print("Found font via resource bundle API: \(fontPath.path)")
            fontURL = fontPath
        }

        // PRIORITY 2: Try SwiftPM resource bundle (production builds)
        if fontURL == nil, let executableURL = Bundle.main.executableURL {
            let bundleName = "SoundBridgeApp_SoundBridgeApp.bundle"
            let resourceBundleURL = executableURL
                .deletingLastPathComponent()
                .appendingPathComponent(bundleName)
                .appendingPathComponent("Resources/fonts/SignPainterHouseScript.ttf")

            if fileManager.fileExists(atPath: resourceBundleURL.path) {
                print("Found font in SwiftPM bundle: \(resourceBundleURL.path)")
                fontURL = resourceBundleURL
            }
        }

        // PRIORITY 3: Try main bundle's built-in resource lookup
        if fontURL == nil, let mainBundleURL = Bundle.main.url(forResource: "fonts/SignPainterHouseScript", withExtension: "ttf") {
            print("Found font via main bundle: \(mainBundleURL.path)")
            fontURL = mainBundleURL
        }

        // PRIORITY 4: Try main bundle resources (alternative bundle structure)
        if fontURL == nil, let resourcePath = Bundle.main.resourcePath {
            let possiblePaths = [
                "\(resourcePath)/Resources/fonts/SignPainterHouseScript.ttf",
                "\(resourcePath)/fonts/SignPainterHouseScript.ttf"
            ]

            for path in possiblePaths {
                if fileManager.fileExists(atPath: path) {
                    print("Found font in main bundle: \(path)")
                    fontURL = URL(fileURLWithPath: path)
                    break
                }
            }
        }

        #if DEBUG
        // PRIORITY 5: Development - relative to executable
        if fontURL == nil, let executablePath = Bundle.main.executablePath {
            let executableDir = (executablePath as NSString).deletingLastPathComponent
            let sourcePath = (executableDir as NSString).appendingPathComponent("../../../Sources/Resources/fonts/SignPainterHouseScript.ttf")
            let normalizedPath = (sourcePath as NSString).standardizingPath
            if fileManager.fileExists(atPath: normalizedPath) {
                print("Found font in development Sources: \(normalizedPath)")
                fontURL = URL(fileURLWithPath: normalizedPath)
            }
        }

        // PRIORITY 6: Development - absolute path from repo root
        if fontURL == nil {
            let homeDir = ProcessInfo.processInfo.environment["HOME"] ?? ""
            let absolutePath = "\(homeDir)/soundbridge/apps/mac/SoundBridgeApp/Sources/Resources/fonts/SignPainterHouseScript.ttf"
            if fileManager.fileExists(atPath: absolutePath) {
                print("Found font at absolute path: \(absolutePath)")
                fontURL = URL(fileURLWithPath: absolutePath)
            }
        }

        #endif

        guard let url = fontURL else {
            print("Failed to find SignPainterHouseScript.ttf in any location")
            return
        }

        var error: Unmanaged<CFError>?
        let result = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)

        if result {
            print("Successfully registered custom font")
        } else if let error = error {
            print("Failed to register font: \(error.takeRetainedValue())")
        }
    }
}
