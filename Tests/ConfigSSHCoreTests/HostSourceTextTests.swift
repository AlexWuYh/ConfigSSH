import Foundation
import XCTest
@testable import ConfigSSHCore

final class HostSourceTextTests: XCTestCase {
    func testSourceTextKeepsCommentsAndIndentationAndStopsAtTheBlockEnd() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ConfigSSHSource-\(UUID().uuidString)")
        let ssh = directory.appendingPathComponent(".ssh")
        try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let root = ssh.appendingPathComponent("config")
        try Data("# top\r\nHost web\r\n  HostName web.example # main\r\n\r\n    # note\r\n\tUser = deploy\r\n\r\n# next block\r\nHost db\r\n  HostName db.example".utf8).write(to: root)
        let scan = ConfigReader(rootURL: root).scan()
        let web = try XCTUnwrap(scan.hosts.first { $0.alias == "web" })
        XCTAssertEqual(scan.sourceText(for: web), "Host web\n  HostName web.example # main\n\n    # note\n\tUser = deploy")
        let db = try XCTUnwrap(scan.hosts.first { $0.alias == "db" })
        XCTAssertEqual(scan.sourceText(for: db), "Host db\n  HostName db.example")
    }
}

final class HostMatchingTests: XCTestCase {
    func testMatchesAliasAddressUserAndGroup() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ConfigSSHMatch-\(UUID().uuidString)")
        let group = directory.appendingPathComponent(".ssh/config.d/Engineering")
        try FileManager.default.createDirectory(at: group, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent(".ssh/config")
        try Data("Include config.d/*/*.conf\n".utf8).write(to: root)
        try Data("Host api\n  HostName api.example.net\n  User deploy\n".utf8).write(to: group.appendingPathComponent("api.conf"))
        let host = try XCTUnwrap(ConfigReader(rootURL: root).scan().hosts.first)
        for query in ["api", "EXAMPLE", "deploy", "engineer", "api deploy"] { XCTAssertTrue(host.matches(query), query) }
        XCTAssertFalse(host.matches("db"))
        XCTAssertFalse(host.matches("api root"))
    }
}
