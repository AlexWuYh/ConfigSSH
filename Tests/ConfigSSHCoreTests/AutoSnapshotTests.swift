import Foundation
import XCTest
@testable import ConfigSSHCore

final class AutoSnapshotTests: XCTestCase {
    private func fixture() throws -> (root: URL, folder: URL) {
        // Snapshot folders refuse symlinked components, and /var is a symlink to /private/var.
        let directory = URL(fileURLWithPath: "/private" + FileManager.default.temporaryDirectory.path)
            .appendingPathComponent("ConfigSSHAuto-\(UUID().uuidString)")
        let ssh = directory.appendingPathComponent(".ssh")
        try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let root = ssh.appendingPathComponent("config")
        try Data("Host web\n  HostName web.example\n".utf8).write(to: root)
        try Data("PRIVATE".utf8).write(to: ssh.appendingPathComponent("id_ed25519"))
        try Data("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl a\n".utf8)
            .write(to: ssh.appendingPathComponent("id_ed25519.pub"))
        return (root, directory.appendingPathComponent("Snapshots"))
    }

    private func run(_ paths: (root: URL, folder: URL), _ interval: AutoSnapshotInterval = .daily,
                     keep: Int = 14, at now: Date = Date()) throws -> AutoSnapshotOutcome {
        try AutoSnapshotService().runIfDue(scan: ConfigReader(rootURL: paths.root).scan(), folder: paths.folder,
                                           interval: interval, keep: keep, now: now)
    }

    private func records(_ folder: URL) throws -> [SnapshotRecord] {
        try BackupSnapshotService().list(in: folder).records
    }

    func testCreatesConfigOnlySnapshotThenWaitsForTheInterval() throws {
        let paths = try fixture()
        guard case .created(let url) = try run(paths) else { return XCTFail("expected a snapshot") }
        XCTAssertTrue(url.lastPathComponent.hasPrefix("ConfigSSH-auto-"))
        let record = try XCTUnwrap(try records(paths.folder).first)
        XCTAssertEqual(record.manifest.isAutomatic, true)
        XCTAssertFalse(record.manifest.includesKeys)
        XCTAssertEqual(record.manifest.entries.map(\.kind), ["ssh-config"], "keys are never included")

        try Data("Host web\n  HostName changed.example\n".utf8).write(to: paths.root)
        guard case .notDue = try run(paths, at: Date().addingTimeInterval(3600)) else { return XCTFail("not due yet") }
        guard case .created = try run(paths, at: Date().addingTimeInterval(86_400 + 60)) else { return XCTFail("due after a day") }
        XCTAssertEqual(try records(paths.folder).count, 2)
    }

    func testUnchangedConfigIsSkippedEvenWhenDue() throws {
        let paths = try fixture()
        _ = try run(paths)
        XCTAssertEqual(try run(paths, at: Date().addingTimeInterval(86_400 * 2)), .unchanged)
        XCTAssertEqual(try records(paths.folder).count, 1)
    }

    func testRecentManualSnapshotOfSameContentAlsoCountsAsUnchanged() throws {
        let paths = try fixture()
        _ = try BackupSnapshotService().create(scan: ConfigReader(rootURL: paths.root).scan(), destination: .local(paths.folder))
        XCTAssertEqual(try run(paths), .unchanged)
    }

    func testDisabledDoesNothing() throws {
        let paths = try fixture()
        XCTAssertEqual(try run(paths, .off), .disabled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.folder.path))
    }

    func testPruningKeepsManualSnapshotsAndNewestAutomaticOnes() throws {
        let paths = try fixture()
        let manual = try BackupSnapshotService().create(scan: ConfigReader(rootURL: paths.root).scan(),
                                                        destination: .local(paths.folder))
        var created: [URL] = []
        for day in 1...4 {
            try Data("Host web\n  HostName v\(day).example\n".utf8).write(to: paths.root)
            guard case .created(let url) = try run(paths, keep: 2, at: Date().addingTimeInterval(Double(day) * 86_400 + 60))
            else { return XCTFail("day \(day)") }
            created.append(url)
            // Distinct createdAt ordering even within the same second.
            Thread.sleep(forTimeInterval: 1.05)
        }
        let remaining = Set(try records(paths.folder).map(\.url.lastPathComponent))
        XCTAssertTrue(remaining.contains(manual.url.lastPathComponent), "manual snapshots are never pruned")
        XCTAssertEqual(remaining.subtracting([manual.url.lastPathComponent]),
                       Set(created.suffix(2).map(\.lastPathComponent)))
    }

    func testAutomaticSnapshotsRefuseKeys() throws {
        let paths = try fixture()
        XCTAssertThrowsError(try BackupSnapshotService().create(scan: ConfigReader(rootURL: paths.root).scan(),
                                                                destination: .local(paths.folder),
                                                                includeKeys: true, automatic: true))
    }

    func testOlderManifestsWithoutTheFlagStillDecode() throws {
        let json = #"{"createdAt":0,"includesKeys":false,"entries":[]}"#
        let manifest = try JSONDecoder().decode(SnapshotManifest.self, from: Data(json.utf8))
        XCTAssertNil(manifest.isAutomatic)
    }
}
