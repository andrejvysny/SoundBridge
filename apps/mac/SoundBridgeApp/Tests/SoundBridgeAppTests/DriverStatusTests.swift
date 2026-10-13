import XCTest
@testable import SoundBridgeApp

final class DriverStatusTests: XCTestCase {
    private let v1 = DriverIdentity(version: "1.1.1", protocolVersion: 0x20000)
    private let v2 = DriverIdentity(version: "1.2.0", protocolVersion: 0x30000)

    private func decide(
        bundled: DriverIdentity?, exists: Bool = true, installed: DriverIdentity?,
        loaded: LoadedDriverState = .notLoaded
    ) -> DriverAction {
        DriverStatus.decide(bundled: bundled, installedExists: exists, installed: installed, loaded: loaded)
    }

    func testExistingOlderDriverIsUpdatedNotSkipped() {
        // Regression for SB-03: an existing path must never count as "installed and current".
        XCTAssertEqual(decide(bundled: v2, installed: v1), .update(from: "1.1.1"))
        XCTAssertEqual(DriverOperation(action: .update(from: "1.1.1")), .update)
    }

    func testMissingDriverIsInstalled() {
        XCTAssertEqual(decide(bundled: v2, exists: false, installed: nil), .install)
    }

    func testUnreadableDriverIsRepaired() {
        XCTAssertEqual(decide(bundled: v2, exists: true, installed: nil), .repair)
        let sameVersionWrongProtocol = DriverIdentity(version: "1.2.0", protocolVersion: 0x20000)
        XCTAssertEqual(decide(bundled: v2, installed: sameVersionWrongProtocol), .repair)
    }

    func testMatchingAndRunningDriverNeedsNothing() {
        XCTAssertEqual(decide(bundled: v2, installed: v2, loaded: .identified(v2)), .none)
        XCTAssertEqual(DriverOperation(action: .none), nil)
    }

    /// The on-disk bundle matching is not enough: an old driver may still be the
    /// one Core Audio is running, so the security fix would not be in effect.
    func testUnconfirmedOrStaleRunningDriverRequiresReload() {
        XCTAssertEqual(decide(bundled: v2, installed: v2, loaded: .identified(v1)), .reloadRequired(loaded: "1.1.1"))
        XCTAssertEqual(decide(bundled: v2, installed: v2, loaded: .unidentified), .reloadRequired(loaded: "an older build"))
        XCTAssertEqual(decide(bundled: v2, installed: v2, loaded: .notLoaded), .reloadRequired(loaded: "no driver running"))
        XCTAssertEqual(DriverOperation(action: .reloadRequired(loaded: "1.1.1")), .repair)
    }

    func testDowngradeIsRefusedWhenIncompatible() {
        let newer = DriverIdentity(version: "2.0.0", protocolVersion: 0x40000)
        XCTAssertEqual(decide(bundled: v2, installed: newer), .newerIncompatibleInstalled("2.0.0"))
        XCTAssertNil(DriverOperation(action: .newerIncompatibleInstalled("2.0.0")))
        let newerCompatible = DriverIdentity(version: "1.2.5", protocolVersion: 0x30000)
        XCTAssertEqual(decide(bundled: v2, installed: newerCompatible), .none)
    }

    func testMissingBundle() {
        XCTAssertEqual(decide(bundled: nil, installed: v1), .bundleMissing)
    }

    func testUpdateChannelConfiguration() {
        let key = Data(repeating: 7, count: 32).base64EncodedString()
        XCTAssertTrue(AppDelegate.isUpdateChannelConfigured(["SUFeedURL": "https://example.com/appcast.xml", "SUPublicEDKey": key]))
        XCTAssertFalse(AppDelegate.isUpdateChannelConfigured(["SUFeedURL": "", "SUPublicEDKey": ""]))
        XCTAssertFalse(AppDelegate.isUpdateChannelConfigured(["SUFeedURL": "http://example.com/appcast.xml", "SUPublicEDKey": key]))
        XCTAssertFalse(AppDelegate.isUpdateChannelConfigured(["SUFeedURL": "https://example.com/appcast.xml", "SUPublicEDKey": "not-a-key"]))
        XCTAssertFalse(AppDelegate.isUpdateChannelConfigured([:]))
    }

    func testTeamIdentifierValidation() {
        XCTAssertTrue(CodeIdentity.isValidTeamIdentifier("ABCDE12345"))
        XCTAssertFalse(CodeIdentity.isValidTeamIdentifier("abcde12345"))
        XCTAssertFalse(CodeIdentity.isValidTeamIdentifier("ABCDE1234"))
        XCTAssertFalse(CodeIdentity.isValidTeamIdentifier("ABCDE\"1234"))
    }
}
