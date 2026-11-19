import Foundation
import XCTest
@testable import ConfigSSHCore

final class HostTransferTests: XCTestCase {
    private let passphrase = "export passphrase 42"

    private func fixture(config: String = "Include config.d/*/*.conf\nServerAliveInterval 60\n") throws -> (ssh: URL, root: URL, writer: ConfigWriter) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("ConfigSSHXfer-\(UUID().uuidString)")
        let ssh = home.appendingPathComponent(".ssh")
        try FileManager.default.createDirectory(at: ssh.appendingPathComponent("config.d/Work"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        let root = ssh.appendingPathComponent("config")
        try Data(config.utf8).write(to: root)
        try Data("Host api\n  HostName api.example\n  User deploy\n".utf8).write(to: ssh.appendingPathComponent("config.d/Work/生产 API.conf"))
        try Data("Host db\n  HostName db.example\n".utf8).write(to: ssh.appendingPathComponent("config.d/Work/db.conf"))
        try Data("PRIVATE".utf8).write(to: ssh.appendingPathComponent("id_ed25519"))
        return (ssh, root, ConfigWriter(rootURL: root, backupDirectory: home.appendingPathComponent("backups")))
    }

    private func scan(_ root: URL) -> ConfigScan { ConfigReader(rootURL: root).scan() }

    // MARK: Zip

    func testZipRoundTripKeepsContentIncludingUnicodeNamesAndEmptyFiles() throws {
        let entries = [ZipArchive.Entry(path: "config", content: Data("Host a\n".utf8)),
                       .init(path: "config.d/生产 环境.conf", content: Data(String(repeating: "HostName x\n", count: 500).utf8)),
                       .init(path: "empty.conf", content: Data())]
        let zip = try ZipArchive.write(entries)
        XCTAssertTrue(ZipArchive.isZip(zip))
        XCTAssertLessThan(zip.count, entries.map(\.content.count).reduce(0, +), "repetitive text is compressed")
        XCTAssertEqual(try ZipArchive.read(zip), entries)
    }

    func testZipReadingRefusesDamageEncryptionAndBombs() throws {
        let zip = try ZipArchive.write([.init(path: "config", content: Data("Host a\n".utf8))])
        XCTAssertThrowsError(try ZipArchive.read(Data("not a zip".utf8)))
        XCTAssertThrowsError(try ZipArchive.read(zip.prefix(zip.count - 6)), "truncated")
        var corrupted = zip
        corrupted[corrupted.startIndex + 40] ^= 0xFF   // inside the data
        XCTAssertThrowsError(try ZipArchive.read(corrupted), "CRC mismatch")
        XCTAssertThrowsError(try ZipArchive.write([.init(path: "big", content: Data(count: ZipArchive.maxEntrySize + 1))]))
        var many: [ZipArchive.Entry] = []
        for index in 0...ZipArchive.maxEntries { many.append(.init(path: "f\(index)", content: Data())) }
        XCTAssertThrowsError(try ZipArchive.write(many))
    }

    func testZipsMadeByTheSystemZipToolAreReadable() throws {
        let fixture = try fixture()
        let zipURL = fixture.ssh.deletingLastPathComponent().appendingPathComponent("system.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = fixture.ssh
        process.arguments = ["-q", "-r", zipURL.path, "config", "config.d"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        XCTAssertEqual(try BoundedProcessRunner.run(process, timeout: 20), 0)
        let entries = try ZipArchive.read(try Data(contentsOf: zipURL))
        XCTAssertEqual(Set(entries.map(\.path)), ["config", "config.d/Work/生产 API.conf", "config.d/Work/db.conf"])
        let imported = try HostTransfer.readZip(try Data(contentsOf: zipURL))
        XCTAssertFalse(imported.hasManifest)
        XCTAssertEqual(imported.archive.entries.count, 3)
    }

    // MARK: Export and import

    func testZipExportHasConfigFilesAndManifestButNeverKeys() throws {
        let f = try fixture()
        let export = try HostTransfer.zipExport(scan: scan(f.root), appVersion: "0.3.0", deviceName: "Mac")
        XCTAssertEqual(export.fileCount, 3)
        let paths = try ZipArchive.read(export.data).map(\.path)
        XCTAssertEqual(Set(paths), ["config", "config.d/Work/生产 API.conf", "config.d/Work/db.conf", HostTransfer.manifestName])
        XCTAssertFalse(String(decoding: export.data, as: UTF8.self).contains("PRIVATE"))
        let imported = try HostTransfer.readZip(export.data)
        XCTAssertTrue(imported.hasManifest)
        XCTAssertEqual(imported.archive.deviceName, "Mac")
    }

    func testExternalIncludeFilesAreSkippedAndReported() throws {
        let f = try fixture()
        let outside = f.ssh.deletingLastPathComponent().appendingPathComponent("shared.conf")
        try Data("Host ext\n  HostName e.example\n".utf8).write(to: outside)
        try Data("Include config.d/*/*.conf\nInclude \(outside.path)\n".utf8).write(to: f.root)
        let export = try HostTransfer.zipExport(scan: scan(f.root), appVersion: "", deviceName: "Mac")
        XCTAssertEqual(export.skippedExternal.count, 1)
        XCTAssertEqual(export.fileCount, 3)
        XCTAssertFalse(String(decoding: export.data, as: UTF8.self).contains("e.example"))
    }

    func testTamperedZipContentIsRefusedByTheManifest() throws {
        let f = try fixture()
        var entries = try ZipArchive.read(try HostTransfer.zipExport(scan: scan(f.root), appVersion: "", deviceName: "Mac").data)
        let index = try XCTUnwrap(entries.firstIndex { $0.path == "config.d/Work/db.conf" })
        entries[index] = .init(path: entries[index].path, content: Data("Host db\n  ProxyCommand evil\n".utf8))
        XCTAssertThrowsError(try HostTransfer.readZip(try ZipArchive.write(entries))) { error in
            XCTAssertTrue(error.localizedDescription.contains("校验失败"), error.localizedDescription)
        }
        let extra = entries + [.init(path: "config.d/injected.conf", content: Data("Host x\n".utf8))]
        XCTAssertThrowsError(try HostTransfer.readZip(try ZipArchive.write(extra)), "files not in the manifest")
    }

    func testEncryptedExportNeedsTheRightPassphraseAndRevealsNothingWithoutIt() throws {
        let f = try fixture()
        let export = try HostTransfer.encryptedExport(scan: scan(f.root), passphrase: passphrase, appVersion: "", deviceName: "Mac")
        XCTAssertNil(export.data.range(of: Data("api.example".utf8)))
        XCTAssertFalse(ZipArchive.isZip(export.data))
        guard case .encrypted = try HostTransfer.inspect(export.data) else { return XCTFail("recognised as encrypted") }
        XCTAssertThrowsError(try HostTransfer.readEncrypted(export.data, passphrase: "wrong passphrase 123")) { error in
            XCTAssertTrue(error.localizedDescription.contains("口令不正确"), error.localizedDescription)
        }
        XCTAssertThrowsError(try HostTransfer.readEncrypted(export.data, passphrase: ""))
        XCTAssertEqual(try HostTransfer.readEncrypted(export.data, passphrase: passphrase).archive.entries.count, 3)
        XCTAssertThrowsError(try HostTransfer.encryptedExport(scan: scan(f.root), passphrase: "short", appVersion: "", deviceName: "Mac"))
    }

    func testInspectRefusesSnapshotsAndUnrelatedFiles() throws {
        XCTAssertThrowsError(try HostTransfer.inspect(Data("hello".utf8)))
        let snapshot = try BackupCrypto.seal(Data("x".utf8), kind: .snapshot, passphrase: passphrase)
        XCTAssertThrowsError(try HostTransfer.inspect(snapshot)) { error in
            XCTAssertTrue(error.localizedDescription.contains("快照"), error.localizedDescription)
        }
    }

    func testImportIntoAnEmptySetupWritesHostsAndKeepsTheirNames() throws {
        let source = try fixture()
        let export = try HostTransfer.zipExport(scan: scan(source.root), appVersion: "", deviceName: "Mac")
        let target = try fixture(config: "# my own settings\nServerAliveInterval 5\n")
        try FileManager.default.removeItem(at: target.ssh.appendingPathComponent("config.d"))
        try FileManager.default.createDirectory(at: target.ssh.appendingPathComponent("config.d"), withIntermediateDirectories: true)

        let imported = try HostTransfer.readZip(export.data)
        let plan = try target.writer.planArchiveRestore(imported.archive, title: "导入", includeRoot: false)
        XCTAssertFalse(plan.changes.contains { $0.url.lastPathComponent == "config" }, "the main config is left alone")
        _ = try target.writer.commit(plan)
        XCTAssertEqual(try String(contentsOf: target.root, encoding: .utf8), "# my own settings\nServerAliveInterval 5\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.ssh.appendingPathComponent("config.d/Work/生产 API.conf").path))
        XCTAssertEqual(HostTransfer.unreferencedFiles(imported.archive, in: scan(target.root)).count, 2,
                       "no Include in the current config, so the hosts are not read yet")

        let withRoot = try target.writer.planArchiveRestore(imported.archive, title: "导入", includeRoot: true)
        _ = try target.writer.commit(withRoot)
        XCTAssertEqual(Set(scan(target.root).hosts.map(\.alias)), ["api", "db"])
        XCTAssertTrue(HostTransfer.unreferencedFiles(imported.archive, in: scan(target.root)).isEmpty)
    }

    func testImportRefusesKeysTraversalAndOpenSSHStateEvenFromAValidZip() throws {
        let f = try fixture()
        let main = ZipArchive.Entry(path: "config", content: Data("Host x\n".utf8))
        for bad in ["id_ed25519", "id_rsa.pub", "authorized_keys", "known_hosts", "../evil.conf", "config.d/../../x", ".hidden", "server.pem"] {
            let zip = try ZipArchive.write([main, .init(path: bad, content: Data("x".utf8))])
            let archive = try HostTransfer.readZip(zip).archive
            XCTAssertThrowsError(try f.writer.planArchiveRestore(archive, title: "t", includeRoot: false), bad)
        }
    }

    func testFinderStyleZipWithATopLevelFolderAndMacMetadataIsAccepted() throws {
        let zip = try ZipArchive.write([.init(path: "ssh-backup/config", content: Data("Host a\n".utf8)),
                                        .init(path: "ssh-backup/config.d/a.conf", content: Data("Host a\n".utf8)),
                                        .init(path: "__MACOSX/ssh-backup/._config", content: Data("x".utf8)),
                                        .init(path: "ssh-backup/.DS_Store", content: Data("x".utf8))])
        let imported = try HostTransfer.readZip(zip)
        XCTAssertEqual(Set(imported.archive.entries.map(\.path)), ["config", "config.d/a.conf"])
        XCTAssertEqual(imported.ignored.sorted(), ["__MACOSX/ssh-backup/._config", "ssh-backup/.DS_Store"], "macOS metadata is dropped and reported")
        XCTAssertThrowsError(try HostTransfer.readZip(try ZipArchive.write([.init(path: "notes.txt", content: Data("x".utf8))])), "no config inside")
    }
}
