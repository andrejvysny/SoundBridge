import CSoundBridgeAudio
@testable import SoundBridgeHost
import XCTest

final class ControlFileTests: XCTestCase {
    private func parse(_ data: Data) -> [(uid: String, name: String)]? {
        var entries = [RFControlEntry](repeating: RFControlEntry(), count: Int(RF_CONTROL_MAX_DEVICES))
        let count = data.withUnsafeBytes { bytes in
            rf_control_parse(bytes.baseAddress?.assumingMemoryBound(to: CChar.self), bytes.count, &entries, Int32(entries.count))
        }
        guard count >= 0 else { return nil }
        return entries.prefix(Int(count)).map { entry in
            var copy = entry
            let uid = withUnsafeBytes(of: &copy.uid) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            let name = withUnsafeBytes(of: &copy.name) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            return (uid, name)
        }
    }

    func testWriterOutputIsAcceptedByDriverParser() {
        let data = DeviceRegistry.controlFileContents(for: [
            (name: "DELL U2720Q", uid: "AppleGFXHDAEngineOutputDP:1:0:{1234}"),
            (name: "Écran | HDMI", uid: "uid with spaces/and:colons"),
        ])
        let parsed = parse(data)
        XCTAssertEqual(parsed?.count, 2)
        XCTAssertEqual(parsed?[0].uid, "AppleGFXHDAEngineOutputDP:1:0:{1234}")
        XCTAssertEqual(parsed?[1].name, "Écran | HDMI")
    }

    func testHostileNamesAreCleanedAndHostileUIDsSkipped() {
        let data = DeviceRegistry.controlFileContents(for: [
            (name: "Evil\nname\twith\u{7f}controls", uid: "good-uid"),
            (name: "tab uid", uid: "bad\tuid"),
            (name: "newline uid", uid: "bad\nuid"),
            (name: "empty uid", uid: ""),
            (name: "too long uid", uid: String(repeating: "u", count: Int(RF_DEVICE_UID_MAX) + 1)),
            (name: "duplicate", uid: "good-uid"),
            (name: String(repeating: "é", count: 400), uid: "long-name"),
        ])
        let parsed = parse(data)
        XCTAssertEqual(parsed?.map(\.uid), ["good-uid", "long-name"])
        XCTAssertEqual(parsed?[0].name, "Evil name with controls")
        XCTAssertLessThanOrEqual(parsed?[1].name.utf8.count ?? .max, Int(RF_DEVICE_NAME_MAX))
    }

    func testDeviceCountIsBounded() {
        let entries = (0..<100).map { (name: "Device \($0)", uid: "uid-\($0)") }
        XCTAssertEqual(parse(DeviceRegistry.controlFileContents(for: entries))?.count, Int(RF_CONTROL_MAX_DEVICES))
    }

    func testVolumeSanitizing() {
        XCTAssertEqual(VolumePersistence.sanitizedVolume(.nan), VolumePersistence.defaultVolume)
        XCTAssertEqual(VolumePersistence.sanitizedVolume(.infinity), VolumePersistence.defaultVolume)
        XCTAssertEqual(VolumePersistence.sanitizedVolume(-1), 0)
        XCTAssertEqual(VolumePersistence.sanitizedVolume(42), 1)
        XCTAssertEqual(VolumePersistence.sanitizedVolume(0.5), 0.5)
    }
}
