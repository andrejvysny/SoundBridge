import Darwin
import XCTest
@testable import SoundBridgeApp

final class AppSessionIPCTests: XCTestCase {
    func testLegacyCleanupOnlyRemovesOwnRegularFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sb-legacy-\(UUID().uuidString)")
        let canary = root.appendingPathComponent("canary")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("keep".utf8).write(to: canary)

        try Data().write(to: root.appendingPathComponent("soundbridge-devices.txt"))
        try Data().write(to: root.appendingPathComponent("soundbridge-AppleHDAEngineOutput_1"))
        try Data().write(to: root.appendingPathComponent("unrelated-file"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("soundbridge-link"), withDestinationURL: canary)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("soundbridge-dir"), withIntermediateDirectories: true)

        AppSessionIPC.removeLegacyFiles(in: root.path)

        let remaining = Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
        XCTAssertEqual(remaining, ["canary", "unrelated-file", "soundbridge-link", "soundbridge-dir"])
        XCTAssertEqual(try String(contentsOf: canary), "keep")
    }

    func testFileNamesMatchHostScheme() {
        XCTAssertEqual(AppSessionIPC.fileName(prefix: "eq-", deviceUID: "a:b")?.count, 3 + 32)
        XCTAssertNotEqual(AppSessionIPC.fileName(prefix: "eq-", deviceUID: "a:b"), AppSessionIPC.fileName(prefix: "eq-", deviceUID: "a_b"))
        XCTAssertNil(AppSessionIPC.fileName(prefix: "eq-", deviceUID: ""))
    }
}
