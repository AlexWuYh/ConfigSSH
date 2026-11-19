import Foundation
import XCTest
@testable import ConfigSSHCore

final class HostDisplayNameTests: XCTestCase {
    private func fixture() throws -> (root: URL, writer: ConfigWriter) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ConfigSSHDisplay-\(UUID().uuidString)")
        let ssh = directory.appendingPathComponent(".ssh")
        try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let root = ssh.appendingPathComponent("config")
        return (root, ConfigWriter(rootURL: root, backupDirectory: directory.appendingPathComponent("backups")))
    }

    private func add(_ paths: (root: URL, writer: ConfigWriter), _ input: HostInput) throws {
        let scan = ConfigReader(rootURL: paths.root).scan()
        _ = try paths.writer.commit(paths.writer.plan(.add(input), from: scan))
    }

    func testFileIsNamedAfterTheDisplayNameWhenGivenAndTheAliasOtherwise() throws {
        let paths = try fixture()
        try add(paths, HostInput(alias: "api", hostName: "api.example.net", group: "Work", displayName: "生产环境 API"))
        try add(paths, HostInput(alias: "db", hostName: "db.example.net", displayName: "   "))
        let managed = paths.writer.managedDirectoryURL
        XCTAssertTrue(FileManager.default.fileExists(atPath: managed.appendingPathComponent("Work/生产环境 API.conf").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: managed.appendingPathComponent("db.conf").path), "blank display name falls back to the alias")
        XCTAssertEqual(try String(contentsOf: managed.appendingPathComponent("Work/生产环境 API.conf"), encoding: .utf8),
                       "Host api\n  HostName api.example.net\n  Port 22\n", "the display name is not written into the config")
    }

    func testDisplayNameSurvivesInTheFileNameAndOnlyThere() throws {
        let paths = try fixture()
        try add(paths, HostInput(alias: "api", hostName: "api.example.net", displayName: "Production API"))
        try add(paths, HostInput(alias: "db", hostName: "db.example.net"))
        let scan = ConfigReader(rootURL: paths.root).scan()
        let api = try XCTUnwrap(scan.hosts.first { $0.alias == "api" })
        let db = try XCTUnwrap(scan.hosts.first { $0.alias == "db" })
        XCTAssertEqual(scan.fileDisplayName(for: api), "Production API")
        XCTAssertNil(scan.fileDisplayName(for: db), "a file named after the alias carries no display name")
    }

    func testInvalidDisplayNamesAreRefusedBeforeAnythingIsWritten() throws {
        let paths = try fixture()
        for name in ["a/b", "a\\b", ".hidden", "x:y", "a\u{0}b", String(repeating: "长", count: 81), "con\"fig"] {
            let scan = ConfigReader(rootURL: paths.root).scan()
            XCTAssertThrowsError(try paths.writer.plan(.add(HostInput(alias: "web", hostName: "w.example", displayName: name)), from: scan), name)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.root.path))
        XCTAssertNil(HostFileName.problem("  "))
        XCTAssertNil(HostFileName.problem("生产 环境-1"))
    }

    func testNameCollisionWithAnExistingFileIsAConflict() throws {
        let paths = try fixture()
        try add(paths, HostInput(alias: "api", hostName: "api.example.net", displayName: "Shared"))
        let scan = ConfigReader(rootURL: paths.root).scan()
        XCTAssertThrowsError(try paths.writer.plan(.add(HostInput(alias: "other", hostName: "o.example", displayName: "shared")), from: scan),
                             "case-insensitive file systems would overwrite it")
    }

    func testDeletingAHostWhoseFileHasADisplayNameRemovesTheWholeFile() throws {
        let paths = try fixture()
        try add(paths, HostInput(alias: "api", hostName: "api.example.net", group: "Work", displayName: "生产环境 API"))
        var scan = ConfigReader(rootURL: paths.root).scan()
        let host = try XCTUnwrap(scan.hosts.first)
        let plan = try paths.writer.plan(.delete(hostID: host.id), from: scan)
        XCTAssertNil(plan.changes.first?.after, "the single-host managed file is deleted whole")
        _ = try paths.writer.commit(plan)
        scan = ConfigReader(rootURL: paths.root).scan()
        XCTAssertTrue(scan.hosts.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.writer.managedDirectoryURL.appendingPathComponent("Work").path), "the group stays")
    }

    func testDeletingAGroupMovesFilesNamedAfterDisplayNames() throws {
        let paths = try fixture()
        try add(paths, HostInput(alias: "api", hostName: "api.example.net", group: "Work", displayName: "生产环境 API"))
        let scan = ConfigReader(rootURL: paths.root).scan()
        let plan = try paths.writer.planGroupDeletion(named: "Work", from: scan)
        XCTAssertEqual(plan.movedHosts.map(\.alias), ["api"])
        let destination = plan.changePlan?.changes.first { $0.after != nil && $0.url.lastPathComponent.hasSuffix(".conf") }
        XCTAssertEqual(destination?.url.lastPathComponent, "生产环境 API.conf")
    }
}
