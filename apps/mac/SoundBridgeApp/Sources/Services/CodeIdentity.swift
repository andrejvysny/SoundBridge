import Foundation
import Security

/// Code-signing identity checks used around the privileged installer.
enum CodeIdentity {
    static let driverBundleIdentifier = "com.soundbridge.driver"

    /// Team identifier of the running app, taken from its validated dynamic
    /// signature (not from files on disk). nil for unsigned/ad-hoc dev builds.
    static func currentTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any],
              let team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String,
              isValidTeamIdentifier(team) else {
            return nil
        }
        return team
    }

    static func isValidTeamIdentifier(_ value: String) -> Bool {
        return value.count == 10 && value.unicodeScalars.allSatisfy {
            ("A"..."Z").contains($0) || ("0"..."9").contains($0)
        }
    }

    /// Designated requirement for a driver signed by `teamIdentifier`.
    static func driverRequirement(teamIdentifier: String) -> String {
        return "anchor apple generic and identifier \"\(driverBundleIdentifier)\" " +
            "and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    }

    /// Verifies the bundle at `path` is intact and, when a team is given, signed by it.
    static func verifyDriverSignature(at path: String, teamIdentifier: String?) -> Bool {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else {
            return false
        }
        var requirement: SecRequirement?
        if let teamIdentifier {
            guard isValidTeamIdentifier(teamIdentifier),
                  SecRequirementCreateWithString(driverRequirement(teamIdentifier: teamIdentifier) as CFString, [], &requirement) == errSecSuccess else {
                return false
            }
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        return SecStaticCodeCheckValidity(staticCode, flags, requirement) == errSecSuccess
    }
}
