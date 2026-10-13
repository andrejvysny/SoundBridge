import XCTest
@testable import SoundBridgeApp

/// Runs the real installer script unprivileged against a scratch "HAL"
/// directory. Only the fixed destination, the root-ownership check, and the
/// coreaudiod restart are substituted.
final class PrivilegedInstallScriptTests: XCTestCase {
    private var root: URL!
    private var halDirectory: URL { root.appendingPathComponent("HAL") }
    private var target: URL { halDirectory.appendingPathComponent("SoundBridgeDriver.driver") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("sb-installer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: halDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var testScript: String {
        let script = DriverInstallScript.source
            .replacingOccurrences(of: "HAL_DIR=/Library/Audio/Plug-Ins/HAL", with: "HAL_DIR='\(halDirectory.path)'")
            .replacingOccurrences(of: "[ \"$(stat -f %u \"$HAL_DIR\")\" = 0 ]", with: "[ \"$(stat -f %u \"$HAL_DIR\")\" = \"$(id -u)\" ]")
            .replacingOccurrences(of: "killall coreaudiod", with: "true")
            .replacingOccurrences(of: "chown -R root:wheel", with: "chown -R \"$(id -u)\"")
        XCTAssertNotEqual(script, DriverInstallScript.source)
        return script
    }

    @discardableResult
    private func makeBundle(at url: URL, identifier: String = "com.soundbridge.driver", version: String, protocolVersion: Int = 196608) throws -> URL {
        let contents = url.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": identifier,
            "CFBundleShortVersionString": version,
            "SoundBridgeProtocolVersion": protocolVersion,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        try Data("binary".utf8).write(to: contents.appendingPathComponent("MacOS/SoundBridgeDriver"))
        return url
    }

    private func run(_ arguments: [String]) -> Result<String, PrivilegedRunnerError> {
        PrivilegedRunner.run(script: testScript, arguments: arguments, asRoot: false)
    }

    private func installedVersion() -> String? {
        VersionManager.driverIdentity(atBundlePath: target.path)?.version
    }

    func testArgumentsAreNeverInterpreted() {
        let canary = root.appendingPathComponent("pwned")
        let hostile = [
            "it's",
            "quote\" & do shell script \"touch \(canary.path)\" & \"",
            "back\\slash",
            "$(touch \(canary.path))",
            "`touch \(canary.path)`",
            "new\nline",
            "ünïcødé ✓",
            "",
        ]
        let result = PrivilegedRunner.run(script: #"for a in "$@"; do printf '[%s]' "$a"; done"#, arguments: hostile, asRoot: false)
        // do shell script converts \n to \r in output by default.
        let expected = hostile.map { "[\($0)]" }.joined().replacingOccurrences(of: "\n", with: "\r")
        XCTAssertEqual(try? result.get(), expected)
        XCTAssertFalse(FileManager.default.fileExists(atPath: canary.path))
    }

    func testInstallFromHostilePathAndUpdateReplacesExistingDriver() throws {
        let canary = root.appendingPathComponent("pwned")
        let hostileDirectory = root.appendingPathComponent("App's \"dir\" $(touch \(canary.path)) \\ ✓")
        try makeBundle(at: target, version: "1.1.1", protocolVersion: 131072) // driver N already installed
        let source = try makeBundle(at: hostileDirectory.appendingPathComponent("SoundBridgeDriver.driver"), version: "1.2.0")

        let result = run(["update", source.path, "1.2.0", "196608", ""])
        XCTAssertNoThrow(try result.get())
        XCTAssertEqual(installedVersion(), "1.2.0")
        XCTAssertFalse(FileManager.default.fileExists(atPath: canary.path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: halDirectory.path)
        XCTAssertEqual(leftovers, ["SoundBridgeDriver.driver"], "staging directory must be cleaned up")
    }

    func testVerificationFailuresKeepPreviousDriver() throws {
        try makeBundle(at: target, version: "1.1.1")
        let cases: [(identifier: String, version: String, protocolVersion: Int, code: Int)] = [
            ("com.example.evil", "1.2.0", 196608, 9),
            ("com.soundbridge.driver", "9.9.9", 196608, 10),
            ("com.soundbridge.driver", "1.2.0", 1, 11),
        ]
        for testCase in cases {
            let source = root.appendingPathComponent("case-\(testCase.code)/SoundBridgeDriver.driver")
            try makeBundle(at: source, identifier: testCase.identifier, version: testCase.version, protocolVersion: testCase.protocolVersion)
            guard case .failure(.failed(let code, _)) = run(["update", source.path, "1.2.0", "196608", ""]) else {
                XCTFail("expected failure for code \(testCase.code)")
                continue
            }
            XCTAssertEqual(code, testCase.code)
            XCTAssertEqual(installedVersion(), "1.1.1")
        }
    }

    func testRejectsSymlinksAndBadArguments() throws {
        let source = try makeBundle(at: root.appendingPathComponent("src/SoundBridgeDriver.driver"), version: "1.2.0")
        try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("Contents/link").path, withDestinationPath: "/etc/passwd")
        XCTAssertEqual(run(["install", source.path, "1.2.0", "196608", ""]), .failure(.failed(code: 8, message: "symlinks in bundle")))
        try FileManager.default.removeItem(atPath: source.appendingPathComponent("Contents/link").path)

        let decoy = root.appendingPathComponent("decoy")
        try FileManager.default.createDirectory(at: decoy, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: decoy)
        XCTAssertEqual(run(["install", source.path, "1.2.0", "196608", ""]), .failure(.failed(code: 4, message: "symlinked destination")))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: decoy.path), [])
        try FileManager.default.removeItem(at: target)

        XCTAssertEqual(run(["install", "relative/path", "1.2.0", "196608", ""]), .failure(.failed(code: 2, message: "source must be absolute")))
        XCTAssertEqual(run(["install", source.path, "1.2.0", "1; rm -rf /", ""]), .failure(.failed(code: 2, message: "bad protocol argument")))
        XCTAssertEqual(run(["install", source.path, "1.2.0", "196608", "ABCDE\" or 1"]), .failure(.failed(code: 2, message: "bad team argument")))
        XCTAssertEqual(run(["format", source.path, "1.2.0", "196608", ""]), .failure(.failed(code: 2, message: "unknown mode")))
        XCTAssertEqual(run(["install"]), .failure(.failed(code: 2, message: "expected 5 arguments")))
        XCTAssertNil(installedVersion())
    }

    /// Killed between moving the old driver aside and moving the new one in,
    /// the script must put the old driver back instead of leaving none.
    func testInterruptedReplacementRestoresThePreviousDriver() throws {
        try makeBundle(at: target, version: "1.1.1")
        let source = try makeBundle(at: root.appendingPathComponent("src/SoundBridgeDriver.driver"), version: "1.2.0")
        let interrupted = testScript.replacingOccurrences(
            of: "if ! mv \"$STAGED\" \"$TARGET\"; then",
            with: "kill -TERM $$\nif ! mv \"$STAGED\" \"$TARGET\"; then"
        )
        XCTAssertNotEqual(interrupted, testScript)

        let result = PrivilegedRunner.run(script: interrupted, arguments: ["update", source.path, "1.2.0", "196608", ""], asRoot: false)
        guard case .failure = result else {
            XCTFail("interrupted script should not report success")
            return
        }
        XCTAssertEqual(installedVersion(), "1.1.1", "previous driver must be restored")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: halDirectory.path)
        XCTAssertEqual(leftovers, ["SoundBridgeDriver.driver"])
    }

    func testUninstallRemovesOnlyTheDriver() throws {
        try makeBundle(at: target, version: "1.2.0")
        let neighbour = halDirectory.appendingPathComponent("Other.driver")
        try FileManager.default.createDirectory(at: neighbour, withIntermediateDirectories: true)
        XCTAssertNoThrow(try run(["uninstall", "", "", "0", ""]).get())
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: neighbour.path))
    }
}
