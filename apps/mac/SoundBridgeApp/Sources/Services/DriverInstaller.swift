import AppKit
import Foundation

enum DriverOperation: String {
    case install
    case update
    case repair
    case uninstall

    /// Privileged operation needed to resolve an action, if any.
    init?(action: DriverAction) {
        switch action {
        case .install: self = .install
        case .update: self = .update
        case .repair, .reloadRequired: self = .repair
        case .none, .newerIncompatibleInstalled, .bundleMissing: return nil
        }
    }
}

enum DriverInstallResult: Equatable {
    /// Installed bundle verified and Core Audio reports the expected build.
    case verified(DriverIdentity)
    case removed
}

/// Driver installation states
enum DriverInstallState: Equatable {
    case notStarted
    case authorizing
    case verifying
    case complete
    case failed(String)

    var isComplete: Bool { self == .complete }

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    var description: String {
        switch self {
        case .notStarted: return "Ready to install"
        case .authorizing: return "Installing driver..."
        case .verifying: return "Verifying installation..."
        case .complete: return "Installation complete!"
        case .failed(let error): return "Failed: \(error)"
        }
    }
}

/// Installs, updates, repairs, and removes the HAL driver through the fixed
/// privileged script, then verifies the result independently.
@MainActor
final class DriverInstaller: ObservableObject {
    @Published var state: DriverInstallState = .notStarted
    @Published var progress: Double = 0.0

    /// Seconds to wait for Core Audio to reload the plug-in after a restart.
    private let loadTimeout: TimeInterval = 8.0

    func currentAction() -> DriverAction {
        return VersionManager.currentDriverAction()
    }

    func perform(_ operation: DriverOperation) async throws -> DriverInstallResult {
        state = .authorizing
        progress = 0.2
        do {
            let result = try await run(operation)
            state = .complete
            progress = 1.0
            return result
        } catch DriverInstallError.cancelled {
            state = .notStarted
            progress = 0.0
            throw DriverInstallError.cancelled
        } catch {
            state = .failed(error.localizedDescription)
            progress = 0.0
            throw error
        }
    }

    private func run(_ operation: DriverOperation) async throws -> DriverInstallResult {
        let teamIdentifier = CodeIdentity.currentTeamIdentifier()
        var arguments = [operation.rawValue, "", "", "0", teamIdentifier ?? ""]
        var expected: DriverIdentity?

        if operation != .uninstall {
            guard let source = VersionManager.bundledDriverPath(),
                  let bundled = VersionManager.driverIdentity(atBundlePath: source),
                  let protocolVersion = bundled.protocolVersion else {
                throw DriverInstallError.driverNotFound
            }
            if let installed = VersionManager.installedDriverIdentity(),
               VersionManager.isVersionOlder(bundled.version, than: installed.version),
               installed.protocolVersion != bundled.protocolVersion {
                throw DriverInstallError.downgradeRefused(installed.version)
            }
            // Early UI-side check only; the privileged script re-verifies the staged copy.
            if let teamIdentifier, !CodeIdentity.verifyDriverSignature(at: source, teamIdentifier: teamIdentifier) {
                throw DriverInstallError.signatureInvalid
            }
            arguments = [operation.rawValue, source, bundled.version, String(protocolVersion), teamIdentifier ?? ""]
            expected = bundled
        }

        switch PrivilegedRunner.run(script: DriverInstallScript.source, arguments: arguments) {
        case .success:
            break
        case .failure(.cancelled):
            throw DriverInstallError.cancelled
        case .failure(.failed(let code, let message)):
            throw DriverInstallError.privilegedStepFailed(DriverInstallScript.exitCodeMessages[code] ?? message)
        }

        state = .verifying
        progress = 0.8
        guard let expected else {
            guard !VersionManager.installedDriverExists() else { throw DriverInstallError.uninstallFailed("driver still present") }
            return .removed
        }
        return try await verifyInstalled(expected, teamIdentifier: teamIdentifier)
    }

    private func verifyInstalled(_ expected: DriverIdentity, teamIdentifier: String?) async throws -> DriverInstallResult {
        guard VersionManager.installedDriverIdentity() == expected else {
            throw DriverInstallError.verificationFailed
        }
        if let teamIdentifier,
           !CodeIdentity.verifyDriverSignature(at: VersionManager.installedDriverPath, teamIdentifier: teamIdentifier) {
            throw DriverInstallError.signatureInvalid
        }

        // Success means the expected driver is running, not merely on disk.
        let deadline = Date().addingTimeInterval(loadTimeout)
        while true {
            switch VersionManager.loadedDriverState() {
            case .identified(let loaded):
                guard loaded == expected else { throw DriverInstallError.staleDriverLoaded(loaded.version) }
                return .verified(expected)
            case .unidentified:
                throw DriverInstallError.staleDriverLoaded("an older build")
            case .notLoaded:
                guard Date() < deadline else { throw DriverInstallError.loadUnconfirmed }
                try await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }
}

enum DriverInstallError: Error, LocalizedError, Equatable {
    case cancelled
    case driverNotFound
    case downgradeRefused(String)
    case signatureInvalid
    case privilegedStepFailed(String)
    case verificationFailed
    case staleDriverLoaded(String)
    case loadUnconfirmed
    case uninstallFailed(String)

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return "Authorization was cancelled. Nothing was changed."
        case .driverNotFound:
            return "This copy of SoundBridge does not contain a valid audio driver."
        case .downgradeRefused(let version):
            return "A newer, incompatible driver (\(version)) is installed. Update SoundBridge instead."
        case .signatureInvalid:
            return "The audio driver is not signed by the same developer as SoundBridge."
        case .privilegedStepFailed(let message):
            return message
        case .verificationFailed:
            return "The installed driver does not match the expected version."
        case .staleDriverLoaded(let version):
            return "Core Audio is still running \(version) of the driver. Restart your Mac to finish the update."
        case .loadUnconfirmed:
            return "The driver was installed but Core Audio has not loaded it. Restart your Mac to finish the update."
        case .uninstallFailed(let message):
            return "Failed to remove the driver: \(message)"
        }
    }
}
