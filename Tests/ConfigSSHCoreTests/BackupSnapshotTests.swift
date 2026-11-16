import Foundation
import XCTest
@testable import ConfigSSHCore

final class BackupSnapshotTests: XCTestCase {
    private func fixture() throws -> (root: URL, scan: ConfigScan, key: URL, home: URL) {
        let home = URL(fileURLWithPath: "/private" + FileManager.default.temporaryDirectory.path)
            .appendingPathComponent("ConfigSSHSnapshot-\(UUID().uuidString)")
        let ssh = home.appendingPathComponent(".ssh")
        try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        let key = home.appendingPathComponent("external-key")
        try SSHKeyGenerator.generate(path: key, algorithm: .ed25519, comment: "fixture")
        let hostFile = ssh.appendingPathComponent("hosts.conf")
        try Data("Host demo\n  HostName demo.example\n  IdentityFile \(key.path)\n".utf8).write(to: hostFile)
        let root = ssh.appendingPathComponent("config")
        try Data("Include hosts.conf\n".utf8).write(to: root)
        return (root, ConfigReader(rootURL: root).scan(), key, home)
    }

    func testLocalSnapshotDefaultsToConfigOnly() throws {
        let fixture = try fixture()
        let destination = fixture.home.appendingPathComponent("snapshots")
        let result = try BackupSnapshotService().create(scan: fixture.scan, destination: .local(destination))
        XCTAssertEqual(result.fileCount, 2)
        XCTAssertEqual(result.keyCount, 0)
        let manifestData = try Data(contentsOf: result.url.appendingPathComponent("manifest.json"))
        let manifest = try JSONDecoder().decode(SnapshotManifest.self, from: manifestData)
        XCTAssertEqual(manifest.entries.filter { $0.kind == "ssh-config" }.count, 2)
        XCTAssertFalse(manifest.includesKeys)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: result.url.path).filter {
            $0.hasPrefix("key-")
        }.count, 0)
    }

    func testExplicitKeySnapshotCopiesPrivateWithOwnerOnlyPermissions() throws {
        let fixture = try fixture()
        let result = try BackupSnapshotService().create(
            scan: fixture.scan,
            destination: .local(fixture.home.appendingPathComponent("snapshots")),
            includeKeys: true
        )
        XCTAssertEqual(result.fileCount, 4)
        XCTAssertEqual(result.keyCount, 2)
        let manifest = try JSONDecoder().decode(SnapshotManifest.self,
                                                from: Data(contentsOf: result.url.appendingPathComponent("manifest.json")))
        let privateEntry = try XCTUnwrap(manifest.entries.first { $0.kind == "private-key" })
        let copiedKey = result.url.appendingPathComponent(privateEntry.backupFile)
        XCTAssertEqual(try Data(contentsOf: copiedKey), try Data(contentsOf: fixture.key))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: copiedKey.path))[.posixPermissions] as? Int, 0o600)
        XCTAssertTrue(manifest.includesKeys)
    }

    func testExplicitSelectionBacksUpOnlyChosenIndexedKey() throws {
        let fixture = try fixture()
        let otherKey = fixture.home.appendingPathComponent("other-key")
        try SSHKeyGenerator.generate(path: otherKey, algorithm: .ed25519, comment: "other-fixture")
        let hostFile = fixture.root.deletingLastPathComponent().appendingPathComponent("hosts.conf")
        try Data("Host demo\n  IdentityFile \(fixture.key.path)\nHost second\n  IdentityFile \(otherKey.path)\n".utf8)
            .write(to: hostFile)
        let scan = ConfigReader(rootURL: fixture.root).scan()
        let chosenID = URL(fileURLWithPath: fixture.key.path + ".pub").standardizedFileURL.path
        XCTAssertTrue(KeyIndex(sshDirectory: fixture.root.deletingLastPathComponent())
            .scan(hosts: scan.hosts, globalOptions: scan.globalOptions).keys.map(\.id).contains(chosenID))
        let result = try BackupSnapshotService().create(
            scan: scan, destination: .local(fixture.home.appendingPathComponent("snapshots")),
            includeKeys: true, selectedKeyIDs: [chosenID]
        )
        let manifest = try JSONDecoder().decode(SnapshotManifest.self,
            from: Data(contentsOf: result.url.appendingPathComponent("manifest.json")))
        XCTAssertEqual(result.keyCount, 2)
        XCTAssertEqual(Set(manifest.entries.filter { $0.kind != "ssh-config" }.map(\.sourcePath)),
                       Set([fixture.key.standardizedFileURL.path, chosenID]))
        XCTAssertFalse(manifest.entries.contains { $0.sourcePath == otherKey.standardizedFileURL.path })
    }

    func testExplicitSelectionRejectsEmptyAndUnknownKeys() throws {
        let fixture = try fixture()
        let folder = fixture.home.appendingPathComponent("snapshots")
        for selection: Set<String> in [[], [fixture.home.appendingPathComponent("unknown.pub").path]] {
            XCTAssertThrowsError(try BackupSnapshotService().create(
                scan: fixture.scan, destination: .local(folder),
                includeKeys: true, selectedKeyIDs: selection
            ))
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    func testCloudSnapshotRefusesPrivateKeysBeforeCreatingAnyFiles() throws {
        let fixture = try fixture()
        let cloudRoot = fixture.home.appendingPathComponent("fake-cloud-drive")
        try FileManager.default.createDirectory(at: cloudRoot, withIntermediateDirectories: true)
        XCTAssertThrowsError(try BackupSnapshotService().create(
            scan: fixture.scan,
            destination: .iCloudDrive(folder: cloudRoot.appendingPathComponent("ConfigSSH"), cloudRoot: cloudRoot),
            includeKeys: true
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cloudRoot.appendingPathComponent("ConfigSSH").path))
    }

    func testPlaintextCloudSnapshotIsRejectedEvenWithoutKeys() throws {
        let fixture = try fixture()
        let cloudRoot = fixture.home.appendingPathComponent("fake-cloud-drive")
        try FileManager.default.createDirectory(at: cloudRoot, withIntermediateDirectories: true)
        XCTAssertThrowsError(try BackupSnapshotService().create(
            scan: fixture.scan,
            destination: .iCloudDrive(folder: cloudRoot.appendingPathComponent("ConfigSSH"), cloudRoot: cloudRoot)
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cloudRoot.appendingPathComponent("ConfigSSH").path))
    }

    func testKeySnapshotRejectsSameSizeCorruptionAndRemovesStaging() throws {
        let fixture = try fixture()
        let folder = fixture.home.appendingPathComponent("snapshots")
        XCTAssertThrowsError(try BackupSnapshotService().create(
            scan: fixture.scan, destination: .local(folder), includeKeys: true,
            afterKeyCopy: { target in
                let count = try Data(contentsOf: target).count
                try Data(repeating: 0x41, count: count).write(to: target)
            }
        ))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.key.path))
    }

    func testSnapshotRejectsChangedConfigAndOutsideCloudDestination() throws {
        let fixture = try fixture()
        let cloudRoot = fixture.home.appendingPathComponent("fake-cloud-drive")
        try FileManager.default.createDirectory(at: cloudRoot, withIntermediateDirectories: true)
        XCTAssertThrowsError(try BackupSnapshotService().create(
            scan: fixture.scan,
            destination: .iCloudDrive(folder: fixture.home.appendingPathComponent("outside"), cloudRoot: cloudRoot)
        ))
        try Data("# changed\n".utf8).write(to: fixture.root)
        XCTAssertThrowsError(try BackupSnapshotService().create(
            scan: fixture.scan, destination: .local(fixture.home.appendingPathComponent("snapshots"))
        ))
    }

    func testKeySnapshotRejectsSymlinkedPrivateKey() throws {
        let fixture = try fixture()
        let link = fixture.home.appendingPathComponent("linked-key")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.key)
        let hostFile = fixture.root.deletingLastPathComponent().appendingPathComponent("hosts.conf")
        try Data("Host demo\n  HostName demo.example\n  IdentityFile \(link.path)\n".utf8).write(to: hostFile)
        let newScan = ConfigReader(rootURL: fixture.root).scan()
        XCTAssertThrowsError(try BackupSnapshotService().create(
            scan: newScan, destination: .local(fixture.home.appendingPathComponent("snapshots")),
            includeKeys: true
        ))
    }

    func testLocalSnapshotCanBeListedPreviewedAndRestoredWithoutKeys() throws {
        let fixture = try fixture()
        let folder = fixture.home.appendingPathComponent("snapshots")
        let originalRoot = try Data(contentsOf: fixture.root)
        let included = fixture.root.deletingLastPathComponent().appendingPathComponent("hosts.conf")
        let originalIncluded = try Data(contentsOf: included)
        let originalKey = try Data(contentsOf: fixture.key)
        _ = try BackupSnapshotService().create(scan: fixture.scan, destination: .local(folder), includeKeys: true)
        let index = try BackupSnapshotService().list(in: folder)
        XCTAssertEqual(index.records.count, 1)
        XCTAssertTrue(index.issues.isEmpty)
        try Data("# changed\nInclude hosts.conf\n".utf8).write(to: fixture.root)
        try Data("Host demo\n  HostName changed.example\n".utf8).write(to: included)
        let writer = ConfigWriter(rootURL: fixture.root, backupDirectory: fixture.home.appendingPathComponent("backups"))
        let plan = try writer.planSnapshotRestore(try XCTUnwrap(index.records.first))
        XCTAssertEqual(plan.changes.count, 2)
        XCTAssertTrue(plan.warnings.contains { $0.contains("不会恢复私钥") })
        XCTAssertEqual(try String(contentsOf: included, encoding: .utf8), "Host demo\n  HostName changed.example\n")
        _ = try writer.commit(plan)
        XCTAssertEqual(try Data(contentsOf: fixture.root), originalRoot)
        XCTAssertEqual(try Data(contentsOf: included), originalIncluded)
        XCTAssertEqual(try Data(contentsOf: fixture.key), originalKey)
        XCTAssertEqual(try writer.backups.list().count, 2)
    }

    func testSnapshotRestoreRejectsChangedTargetAndTamperedArchive() throws {
        let fixture = try fixture()
        let folder = fixture.home.appendingPathComponent("snapshots")
        let result = try BackupSnapshotService().create(scan: fixture.scan, destination: .local(folder))
        let record = try XCTUnwrap(BackupSnapshotService().list(in: folder).records.first)
        let writer = ConfigWriter(rootURL: fixture.root, backupDirectory: fixture.home.appendingPathComponent("backups"))
        try Data("# changed\nInclude hosts.conf\n".utf8).write(to: fixture.root)
        let plan = try writer.planSnapshotRestore(record)
        try Data("# external edit\nInclude hosts.conf\n".utf8).write(to: fixture.root)
        XCTAssertThrowsError(try writer.commit(plan))
        XCTAssertEqual(try String(contentsOf: fixture.root, encoding: .utf8), "# external edit\nInclude hosts.conf\n")
        let rootEntry = try XCTUnwrap(record.manifest.entries.first {
            $0.sourcePath == fixture.root.standardizedFileURL.path
        })
        try Data("# tampered\n".utf8).write(to: result.url.appendingPathComponent(rootEntry.backupFile))
        XCTAssertThrowsError(try writer.planSnapshotRestore(record))
    }

    func testCloudSnapshotIsBrowsableButNotAutoRestored() throws {
        let fixture = try fixture()
        let legacy = try BackupSnapshotService().create(
            scan: fixture.scan, destination: .local(fixture.home.appendingPathComponent("original")))
        let cloudRoot = fixture.home.appendingPathComponent("fake-cloud-drive")
        try FileManager.default.createDirectory(at: cloudRoot, withIntermediateDirectories: true)
        let folder = cloudRoot.appendingPathComponent("ConfigSSH")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: legacy.url,
                                         to: folder.appendingPathComponent(legacy.url.lastPathComponent))
        let record = try XCTUnwrap(BackupSnapshotService().list(in: folder, isCloud: true).records.first)
        XCTAssertTrue(record.isCloud)
        XCTAssertThrowsError(try ConfigWriter(rootURL: fixture.root,
                                             backupDirectory: fixture.home.appendingPathComponent("backups"))
            .planSnapshotRestore(record))
    }

    func testCloudSnapshotImportsVerifiedConfigOnlyBeforeLocalRestore() throws {
        let fixture = try fixture()
        let localArchive = try BackupSnapshotService().create(
            scan: fixture.scan, destination: .local(fixture.home.appendingPathComponent("original")),
            includeKeys: true
        )
        let fakeCloud = fixture.home.appendingPathComponent("fake-cloud-drive/ConfigSSH")
        try FileManager.default.createDirectory(at: fakeCloud, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: localArchive.url,
            to: fakeCloud.appendingPathComponent(localArchive.url.lastPathComponent))
        let cloudRecord = try XCTUnwrap(BackupSnapshotService().list(in: fakeCloud, isCloud: true).records.first)
        let imported = try BackupSnapshotService().importCloudSnapshot(
            cloudRecord, to: fixture.home.appendingPathComponent("imported")
        )
        XCTAssertEqual(imported.keyCount, 0)
        let localRecord = try XCTUnwrap(BackupSnapshotService().list(
            in: imported.url.deletingLastPathComponent()).records.first)
        XCTAssertFalse(localRecord.isCloud)
        XCTAssertFalse(localRecord.manifest.includesKeys)
        XCTAssertTrue(localRecord.manifest.entries.allSatisfy { $0.kind == "ssh-config" })
        XCTAssertEqual(imported.fileCount, 2)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: imported.url.path)
            .filter { $0.hasPrefix("key-") }.count, 0)

        try Data("# modified\nInclude hosts.conf\n".utf8).write(to: fixture.root)
        let writer = ConfigWriter(rootURL: fixture.root,
            backupDirectory: fixture.home.appendingPathComponent("backups"))
        let plan = try writer.planSnapshotRestore(localRecord)
        _ = try writer.commit(plan)
        XCTAssertEqual(try Data(contentsOf: fixture.root),
                       try Data(contentsOf: localArchive.url.appendingPathComponent("config-001.conf")))
    }

    func testCloudImportRejectsArchiveChangedAfterBrowsing() throws {
        let fixture = try fixture()
        let legacy = try BackupSnapshotService().create(
            scan: fixture.scan, destination: .local(fixture.home.appendingPathComponent("original")))
        let fakeCloud = fixture.home.appendingPathComponent("fake-cloud-drive")
        try FileManager.default.createDirectory(at: fakeCloud, withIntermediateDirectories: true)
        let folder = fakeCloud.appendingPathComponent("ConfigSSH")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let cloudArchive = folder.appendingPathComponent(legacy.url.lastPathComponent)
        try FileManager.default.copyItem(at: legacy.url, to: cloudArchive)
        let record = try XCTUnwrap(BackupSnapshotService().list(
            in: folder, isCloud: true).records.first)
        try Data("tampered".utf8).write(to: cloudArchive.appendingPathComponent("config-001.conf"))
        let local = fixture.home.appendingPathComponent("imported")
        XCTAssertThrowsError(try BackupSnapshotService().importCloudSnapshot(record, to: local))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: local.path).isEmpty)
    }

    func testSnapshotRestoreRejectsExternalIncludeDestination() throws {
        let fixture = try fixture()
        let external = fixture.home.appendingPathComponent("external.conf")
        try Data("Host outside\n HostName outside.example\n".utf8).write(to: external)
        try Data("Include \(external.path)\n".utf8).write(to: fixture.root)
        let scan = ConfigReader(rootURL: fixture.root).scan()
        let folder = fixture.home.appendingPathComponent("snapshots")
        _ = try BackupSnapshotService().create(scan: scan, destination: .local(folder))
        let record = try XCTUnwrap(BackupSnapshotService().list(in: folder).records.first)
        try Data("# changed\nInclude \(external.path)\n".utf8).write(to: fixture.root)
        XCTAssertThrowsError(try ConfigWriter(rootURL: fixture.root,
                                             backupDirectory: fixture.home.appendingPathComponent("backups"))
            .planSnapshotRestore(record))
        XCTAssertEqual(try String(contentsOf: external, encoding: .utf8), "Host outside\n HostName outside.example\n")
    }

    func testSnapshotRestoreRefusesArchiveModifiedAfterPreview() throws {
        let fixture = try fixture()
        let folder = fixture.home.appendingPathComponent("snapshots")
        let archived = try BackupSnapshotService().create(scan: fixture.scan, destination: .local(folder))
        let record = try XCTUnwrap(BackupSnapshotService().list(in: folder).records.first)
        try Data("# current\nInclude hosts.conf\n".utf8).write(to: fixture.root)
        let writer = ConfigWriter(rootURL: fixture.root, backupDirectory: fixture.home.appendingPathComponent("backups"))
        let plan = try writer.planSnapshotRestore(record)
        let entry = try XCTUnwrap(record.manifest.entries.first {
            $0.sourcePath == fixture.root.standardizedFileURL.path
        })
        try Data("# tampered\n".utf8).write(to: archived.url.appendingPathComponent(entry.backupFile))
        XCTAssertThrowsError(try writer.commit(plan))
        XCTAssertEqual(try String(contentsOf: fixture.root, encoding: .utf8), "# current\nInclude hosts.conf\n")
    }

    func testSnapshotRestoreRefusesSymlinkDestination() throws {
        let fixture = try fixture()
        let folder = fixture.home.appendingPathComponent("snapshots")
        _ = try BackupSnapshotService().create(scan: fixture.scan, destination: .local(folder))
        let record = try XCTUnwrap(BackupSnapshotService().list(in: folder).records.first)
        let included = fixture.root.deletingLastPathComponent().appendingPathComponent("hosts.conf")
        let sentinel = fixture.home.appendingPathComponent("sentinel")
        try Data("untouched".utf8).write(to: sentinel)
        try FileManager.default.removeItem(at: included)
        try FileManager.default.createSymbolicLink(at: included, withDestinationURL: sentinel)
        XCTAssertThrowsError(try ConfigWriter(rootURL: fixture.root,
                                             backupDirectory: fixture.home.appendingPathComponent("backups"))
            .planSnapshotRestore(record))
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "untouched")
    }

    func testLegacySnapshotWithoutConfigHashesCanBrowseButNotAutoRestore() throws {
        let fixture = try fixture()
        let folder = fixture.home.appendingPathComponent("snapshots")
        let result = try BackupSnapshotService().create(scan: fixture.scan, destination: .local(folder))
        let manifestURL = result.url.appendingPathComponent("manifest.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        let entries = try XCTUnwrap(json["entries"] as? [[String: Any]])
        json["entries"] = entries.map { entry in
            var legacy = entry
            legacy.removeValue(forKey: "sha256")
            return legacy
        }
        try JSONSerialization.data(withJSONObject: json).write(to: manifestURL)
        let index = try BackupSnapshotService().list(in: folder)
        XCTAssertEqual(index.records.count, 1)
        try Data("# current\nInclude hosts.conf\n".utf8).write(to: fixture.root)
        XCTAssertThrowsError(try ConfigWriter(rootURL: fixture.root,
                                             backupDirectory: fixture.home.appendingPathComponent("backups"))
            .planSnapshotRestore(try XCTUnwrap(index.records.first)))
    }
}
