import XCTest
@testable import ContinuityCore

final class CallingDiagnosticsTests: XCTestCase {
    func testLogIsPrivateBoundedAndKeepsNewestLines() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("diag-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = CallingDiagnostics(directory: dir)
        for i in 0..<9000 { log.log("line \(i) " + String(repeating: "x", count: 60)) }
        log.flush()
        let attributes = try FileManager.default.attributesOfItem(atPath: log.url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? Int) ?? 0, 0o600)
        let size = (attributes[.size] as? Int) ?? 0
        XCTAssertLessThanOrEqual(size, CallingDiagnostics.limit + 512)
        let text = try String(contentsOf: log.url, encoding: .utf8)
        XCTAssertTrue(text.contains("line 8999 "))
        XCTAssertFalse(text.contains("line 0 "))
        XCTAssertTrue(text.hasPrefix(text.prefix(2)) && !(text.split(separator: "\n").first ?? "").isEmpty)
    }
}
