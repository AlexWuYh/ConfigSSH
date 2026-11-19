import Foundation
import XCTest
@testable import ConfigSSHCore

final class EncryptedBackupTests: XCTestCase {
    private let passphrase = "correct horse battery"

    private func fixture() throws -> (home: URL, root: URL, snapshots: URL, writer: ConfigWriter) {
        // Snapshot folders refuse symlinked components, and /var is a symlink to /private/var.
        let home = URL(fileURLWithPath: "/private" + FileManager.default.temporaryDirectory.path)
            .appendingPathComponent("ConfigSSHEnc-\(UUID().uuidString)")
        let ssh = home.appendingPathComponent(".ssh")
        try FileManager.default.createDirectory(at: ssh.appendingPathComponent("config.d"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        let root = ssh.appendingPathComponent("config")
        try Data("Include config.d/*.conf\nServerAliveInterval 60\n".utf8).write(to: root)
        try Data("Host web\n  HostName web.example\n".utf8).write(to: ssh.appendingPathComponent("config.d/web.conf"))
        try Data("PRIVATE-KEY".utf8).write(to: ssh.appendingPathComponent("id_ed25519"))
        return (home, root, home.appendingPathComponent("Snapshots"),
                ConfigWriter(rootURL: root, backupDirectory: home.appendingPathComponent("backups")))
    }

    private func scan(_ root: URL) -> ConfigScan { ConfigReader(rootURL: root).scan() }

    func testCryptoRoundTripWrongPassphraseAndTampering() throws {
        let sealed = try BackupCrypto.seal(Data("hello".utf8), kind: .snapshot, passphrase: passphrase)
        XCTAssertFalse(String(decoding: sealed, as: UTF8.self).contains("hello"))
        XCTAssertEqual(try BackupCrypto.header(of: sealed).kind, .snapshot, "the header is readable without the passphrase")
        XCTAssertEqual(try BackupCrypto.open(sealed, passphrase: passphrase, expectedKind: .snapshot).plaintext, Data("hello".utf8))
        XCTAssertThrowsError(try BackupCrypto.open(sealed, passphrase: "another passphrase!", expectedKind: .snapshot)) { error in
            XCTAssertTrue(error.localizedDescription.contains("口令不正确"), error.localizedDescription)
        }
        XCTAssertThrowsError(try BackupCrypto.open(sealed, passphrase: passphrase, expectedKind: .export), "kinds are not interchangeable")
        XCTAssertThrowsError(try BackupCrypto.seal(Data(), kind: .snapshot, passphrase: "short"))
        XCTAssertThrowsError(try BackupCrypto.header(of: Data("not a backup".utf8)))

        var text = String(decoding: sealed, as: UTF8.self)
        text = text.replacingOccurrences(of: "\"isAutomatic\":false", with: "\"isAutomatic\":true")
        XCTAssertThrowsError(try BackupCrypto.open(Data(text.utf8), passphrase: passphrase, expectedKind: .snapshot),
                             "editing the header breaks authentication")
    }

    func testSnapshotContainsConfigFilesButNeverKeysAndIsNotPlaintext() throws {
        let paths = try fixture()
        let url = try EncryptedSnapshotService(folder: paths.snapshots).create(scan: scan(paths.root), passphrase: passphrase)
        XCTAssertEqual(url.pathExtension, "cssh")
        let bytes = try Data(contentsOf: url)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("web.example"), "file content is encrypted")
        XCTAssertFalse(bytes.range(of: Data("PRIVATE-KEY".utf8)) != nil)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: url.path))[.posixPermissions] as? Int, 0o600)

        let service = EncryptedSnapshotService(folder: paths.snapshots)
        let record = try XCTUnwrap(try service.list().records.first)
        let archive = try service.open(record, passphrase: passphrase)
        XCTAssertEqual(Set(archive.entries.map(\.path)), ["config", "config.d/web.conf"])
        XCTAssertThrowsError(try service.open(record, passphrase: "wrong passphrase 123"))
    }

    func testRestoreFromADecryptedSnapshotPreviewsAndWritesOnlyConfigFiles() throws {
        let paths = try fixture()
        let service = EncryptedSnapshotService(folder: paths.snapshots)
        _ = try service.create(scan: scan(paths.root), passphrase: passphrase)
        try Data("Include config.d/*.conf\nServerAliveInterval 999\n".utf8).write(to: paths.root)
        try FileManager.default.removeItem(at: paths.root.deletingLastPathComponent().appendingPathComponent("config.d/web.conf"))

        let archive = try service.open(try XCTUnwrap(try service.list().records.first), passphrase: passphrase)
        let plan = try paths.writer.planArchiveRestore(archive, title: "从快照恢复")
        XCTAssertEqual(plan.changes.last?.url.lastPathComponent, "config", "the root config is written last")
        _ = try paths.writer.commit(plan)
        XCTAssertEqual(try String(contentsOf: paths.root, encoding: .utf8), "Include config.d/*.conf\nServerAliveInterval 60\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.root.deletingLastPathComponent().appendingPathComponent("config.d/web.conf").path))
        XCTAssertEqual(try String(contentsOf: paths.root.deletingLastPathComponent().appendingPathComponent("id_ed25519"), encoding: .utf8),
                       "PRIVATE-KEY", "keys are untouched")
        XCTAssertThrowsError(try paths.writer.planArchiveRestore(archive, title: "again"), "identical config needs no restore")
    }

    func testRestoreRefusesTraversalKeysAndExternalEntries() throws {
        let paths = try fixture()
        let main = BackupArchive.Entry(path: "config", isExternal: false, content: Data("Host x\n".utf8))
        for bad in ["../evil", "id_ed25519", "authorized_keys", "known_hosts", "/etc/passwd", "a//b", "config.d/../../x"] {
            let archive = BackupArchive(appVersion: "", deviceName: "t",
                                        entries: [main, .init(path: bad, isExternal: false, content: Data("x".utf8))])
            XCTAssertThrowsError(try paths.writer.planArchiveRestore(archive, title: "t"), bad)
        }
        let external = BackupArchive(appVersion: "", deviceName: "t",
                                     entries: [main, .init(path: "/Users/x/shared.conf", isExternal: true, content: Data("x".utf8))])
        let plan = try paths.writer.planArchiveRestore(external, title: "t")
        XCTAssertEqual(plan.changes.map { $0.url.lastPathComponent }, ["config"], "external files are never written")
        XCTAssertTrue(plan.warnings.contains { $0.contains("之外") })
        XCTAssertThrowsError(try paths.writer.planArchiveRestore(BackupArchive(appVersion: "", deviceName: "t", entries: []), title: "t"))
    }

    func testCatalogMixesLegacyFoldersWithEncryptedFiles() throws {
        let paths = try fixture()
        _ = try BackupSnapshotService().create(scan: scan(paths.root), destination: .local(paths.snapshots))
        Thread.sleep(forTimeInterval: 1.05)
        _ = try EncryptedSnapshotService(folder: paths.snapshots).create(scan: scan(paths.root), passphrase: passphrase)
        let items = try SnapshotCatalog.list(folder: paths.snapshots).items
        XCTAssertEqual(items.map(\.isEncrypted), [true, false], "newest first; plaintext legacy snapshots stay listed")
    }
}
