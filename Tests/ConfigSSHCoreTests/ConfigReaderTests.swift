import Foundation
import XCTest
@testable import ConfigSSHCore

final class ConfigReaderTests: XCTestCase {
    private func rootURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConfigSSHTests-\(UUID().uuidString)")
            .appendingPathComponent(".ssh")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory.deletingLastPathComponent())
        }
        return directory.appendingPathComponent("config")
    }

    func testMissingRootIsReportedWithoutCreatingIt() throws {
        let root = try rootURL()
        let scan = ConfigReader(rootURL: root).scan()
        XCTAssertEqual(scan.availability, .missing)
        XCTAssertTrue(scan.hosts.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testSimpleHostPreservesSourceBytesAndExplicitFields() throws {
        let root = try rootURL()
        let original = Data("# note\r\nHost Demo\r\n  HostName demo.example\r\n  User admin\r\n  Port 2202\r\n  CustomOption kept\r\n".utf8)
        try original.write(to: root)

        let scan = ConfigReader(rootURL: root).scan()
        XCTAssertEqual(scan.availability, .available)
        XCTAssertEqual(scan.hosts.count, 1)
        let host = try XCTUnwrap(scan.hosts.first)
        XCTAssertEqual(host.alias, "Demo")
        XCTAssertEqual(host.sourceLine, 2)
        XCTAssertEqual(host.hostName, "demo.example")
        XCTAssertEqual(host.user, "admin")
        XCTAssertEqual(host.port, "2202")
        XCTAssertEqual(host.explicitOptions.last?.rawValue, "kept")
        XCTAssertTrue(host.isSimple)
        XCTAssertEqual(String(decoding: original.subdata(in: host.byteRange), as: UTF8.self),
                       "Host Demo\r\n  HostName demo.example\r\n  User admin\r\n  Port 2202\r\n  CustomOption kept\r\n")
        XCTAssertEqual(scan.sources.first?.data, original)
        XCTAssertEqual(scan.sources.first?.sha256.count, 64)
        XCTAssertEqual(try Data(contentsOf: root), original)
    }

    func testIncludesRulesDuplicatesAndCyclesAreVisibleWithoutExecutingMatch() throws {
        let root = try rootURL()
        let includeDirectory = root.deletingLastPathComponent().appendingPathComponent("config.d")
        try FileManager.default.createDirectory(at: includeDirectory, withIntermediateDirectories: true)
        let marker = root.deletingLastPathComponent().appendingPathComponent("should-not-exist")
        let rootText = "Include config.d/*.conf\nHost *\n  User fallback\nMatch exec /usr/bin/touch \(marker.path)\n  Port 9999\nHost direct\n  HostName direct.example\n"
        try Data(rootText.utf8).write(to: root)
        try Data("Host alpha\n HostName alpha.example\n".utf8)
            .write(to: includeDirectory.appendingPathComponent("a.conf"))
        try Data("Include config.d/b.conf\nHost alpha\n HostName duplicate.example\n".utf8)
            .write(to: includeDirectory.appendingPathComponent("b.conf"))

        let scan = ConfigReader(rootURL: root).scan()
        XCTAssertEqual(scan.availability, .available)
        XCTAssertEqual(scan.hosts.map(\.alias), ["alpha", "alpha", "direct"])
        XCTAssertEqual(scan.rules.count, 2)
        XCTAssertEqual(scan.hosts.filter { $0.alias == "alpha" && !$0.isSimple }.count, 2)
        XCTAssertTrue(scan.issues.contains { $0.message.contains("循环") })
        XCTAssertTrue(scan.issues.contains { $0.message.contains("重复") })
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(try String(contentsOf: root, encoding: .utf8), rootText)
    }

    func testConditionalIncludeAndInvalidEncodingAreIsolated() throws {
        let root = try rootURL()
        try Data("Host parent\n Include nested.conf\nInclude invalid.conf\nHost good\n HostName good.example\n".utf8)
            .write(to: root)
        try Data("Host child\n HostName child.example\n".utf8)
            .write(to: root.deletingLastPathComponent().appendingPathComponent("nested.conf"))
        try Data([0xff, 0xfe]).write(to: root.deletingLastPathComponent().appendingPathComponent("invalid.conf"))

        let scan = ConfigReader(rootURL: root).scan()
        XCTAssertEqual(scan.hosts.map(\.alias), ["parent", "child", "good"])
        XCTAssertFalse(try XCTUnwrap(scan.hosts.first { $0.alias == "child" }).isSimple)
        XCTAssertFalse(try XCTUnwrap(scan.hosts.first { $0.alias == "parent" }).isSimple)
        XCTAssertTrue(try XCTUnwrap(scan.hosts.first { $0.alias == "good" }).isSimple)
        XCTAssertTrue(scan.issues.contains { $0.message.contains("UTF-8") })
    }

    func testSearchMatchesAliasHostNameAndUser() throws {
        let root = try rootURL()
        try Data("Host Staging\n HostName stage.example.org\n User deploy\n".utf8).write(to: root)
        let host = try XCTUnwrap(ConfigReader(rootURL: root).scan().hosts.first)
        XCTAssertTrue(host.matches("staging"))
        XCTAssertTrue(host.matches("EXAMPLE deploy"))
        XCTAssertFalse(host.matches("production"))
    }

    func testMalformedLineIsReportedAndHostRemainsReadOnly() throws {
        let root = try rootURL()
        try Data("Host broken\n User \"unfinished\nHost valid\n HostName valid.example\n".utf8).write(to: root)

        let scan = ConfigReader(rootURL: root).scan()
        XCTAssertEqual(scan.hosts.map(\.alias), ["broken", "valid"])
        XCTAssertFalse(try XCTUnwrap(scan.hosts.first).isSimple)
        XCTAssertTrue(try XCTUnwrap(scan.hosts.last).isSimple)
        XCTAssertTrue(scan.issues.contains { $0.line == 2 && $0.message.contains("引号") })
    }

    func testMissingOptionValueCannotBeEdited() throws {
        let root = try rootURL()
        try Data("Host broken\n User\n".utf8).write(to: root)
        let scan = ConfigReader(rootURL: root).scan()
        XCTAssertFalse(try XCTUnwrap(scan.hosts.first).isSimple)
        XCTAssertTrue(scan.issues.contains { $0.message.contains("缺少值") })
    }

    func testReadsOnlyRootGlobalOptionsSeparatelyFromHostOptions() throws {
        let root = try rootURL()
        try Data("# global comment\nServerAliveInterval 30\nInclude config.d/*.conf\nInclude config.d/*/*.conf\nHost root-host\n User deploy\n".utf8)
            .write(to: root)
        let groupDirectory = root.deletingLastPathComponent().appendingPathComponent("config.d/Work")
        try FileManager.default.createDirectory(at: groupDirectory, withIntermediateDirectories: true)
        try Data("Host grouped-host\n Port 2200\n ServerAliveInterval 60\n".utf8)
            .write(to: groupDirectory.appendingPathComponent("host.conf"))

        let scan = ConfigReader(rootURL: root).scan()
        XCTAssertEqual(scan.globalOptions.map(\.keyword), ["ServerAliveInterval"])
        XCTAssertEqual(scan.globalOptions.first?.sourceURL, root)
        XCTAssertEqual(scan.hosts.map(\.alias), ["grouped-host", "root-host"])
        XCTAssertEqual(scan.hosts.first?.option("ServerAliveInterval"), "60")
    }
}
