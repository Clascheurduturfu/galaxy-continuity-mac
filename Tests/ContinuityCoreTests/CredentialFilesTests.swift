import XCTest
import Darwin
@testable import ContinuityCore

final class CredentialFilesTests: XCTestCase {
    func testPrivateReplacementAndDeletion() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try CredentialFiles.save(Data("first".utf8), name: "login.json", directory: directory)
        try CredentialFiles.save(Data("replacement".utf8), name: "login.json", directory: directory)
        XCTAssertEqual(try CredentialFiles.load("login.json", directory: directory), Data("replacement".utf8))
        let attrs = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("login.json").path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["login.json"])
        try CredentialFiles.delete("login.json", directory: directory)
        XCTAssertNil(try CredentialFiles.load("login.json", directory: directory))
    }
    func testRejectsLinksAndExposedFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try CredentialFiles.save(Data("test".utf8), name: "login.json", directory: directory)
        let file = directory.appendingPathComponent("login.json")
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("link"), withDestinationURL: file)
        XCTAssertThrowsError(try CredentialFiles.load("link", directory: directory))
        XCTAssertEqual(chmod(file.path, 0o644), 0)
        XCTAssertThrowsError(try CredentialFiles.load("login.json", directory: directory))
    }
}
