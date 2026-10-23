import XCTest
@testable import ContinuityCore

final class SMBCompatibilityTests: XCTestCase {
    func testTemporaryPreferenceRestoresOriginalAndConcurrentEdits() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("nsmb.conf"), journal = root.appendingPathComponent("private")
        let original = Data("[OTHER]\nstreams=yes\n".utf8)
        try original.write(to: path); try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: path.path)
        let first = try SMBCompatibility(host: "192.0.2.1", path: path, journalDirectory: journal)
        XCTAssertTrue(try String(contentsOf: path).contains("protocol_vers_map=2"))
        try first.restore(); XCTAssertEqual(try Data(contentsOf: path), original)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? NSNumber)?.intValue, 0o640)
        let second = try SMBCompatibility(host: "192.0.2.1", path: path, journalDirectory: journal)
        let edited = try Data(contentsOf: path) + Data("\n[NEW]\nstreams=no\n".utf8)
        try edited.write(to: path)
        try second.restore()
        XCTAssertEqual(try Data(contentsOf: path), original + Data("\n[NEW]\nstreams=no\n".utf8))
    }
    func testInterruptedMountRecoveryRemovesOnlyOwnedNewFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("nsmb.conf"), journal = root.appendingPathComponent("private")
        _ = try SMBCompatibility(host: "192.0.2.1", path: path, journalDirectory: journal)
        try SMBCompatibility.recover(path: path, journalDirectory: journal)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
        XCTAssertNil(try CredentialFiles.load(SMBCompatibility.journalName, directory: journal))
    }
    func testExistingPhoneSettingsAndSymlinksAreNotOverwritten() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("nsmb.conf"), journal = root.appendingPathComponent("private")
        let original = Data("[192.0.2.1]\nprotocol_vers_map=4\n".utf8)
        try original.write(to: path)
        XCTAssertThrowsError(try SMBCompatibility(host: "192.0.2.1", path: path, journalDirectory: journal))
        XCTAssertEqual(try Data(contentsOf: path), original)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: path)
        XCTAssertThrowsError(try SMBCompatibility(host: "192.0.2.2", path: link, journalDirectory: journal))
    }
}
