import Foundation
import XCTest
@testable import ConfigSSHCore

final class KeyLoginConfigTests: XCTestCase {
    private func fixture(_ config: String) throws -> (root: URL, writer: ConfigWriter, backup: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ConfigSSHKeyLogin-\(UUID().uuidString)")
        let ssh = directory.appendingPathComponent(".ssh")
        try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let root = ssh.appendingPathComponent("config")
        try Data(config.utf8).write(to: root)
        let backup = directory.appendingPathComponent("backups")
        return (root, ConfigWriter(rootURL: root, backupDirectory: backup), backup)
    }

    private let keyURL = URL(fileURLWithPath: "/tmp/keys/id_ed25519_new")
    private func proof(_ alias: String = "web") -> VerifiedKeyLogin {
        VerifiedKeyLogin(alias: alias, privateKeyURL: keyURL, fingerprint: "SHA256:NEW")
    }

    private func apply(_ paths: (root: URL, writer: ConfigWriter, backup: URL), alias: String = "web",
                       mode: IdentityFileUpdateMode = .replace) throws -> String {
        let scan = ConfigReader(rootURL: paths.root).scan()
        let host = try XCTUnwrap(scan.hosts.first { $0.alias == alias })
        let plan = try paths.writer.planKeyLogin(proof(alias), hostID: host.id, mode: mode, from: scan)
        _ = try paths.writer.commit(plan)
        return try String(contentsOf: paths.root, encoding: .utf8)
    }

    func testAddsKeyAndIdentitiesOnlyWithoutTouchingOtherBytes() throws {
        let paths = try fixture("# top\r\nHost web\r\n  HostName web.example # keep\r\n\r\n# next\r\nHost db\r\n  HostName db.example\r\n")
        XCTAssertEqual(try apply(paths),
                       "# top\r\nHost web\r\n  HostName web.example # keep\r\n  IdentityFile /tmp/keys/id_ed25519_new\r\n  IdentitiesOnly yes\r\n\r\n# next\r\nHost db\r\n  HostName db.example\r\n")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: paths.backup.path).filter { $0.hasSuffix(".bak") }.count, 1,
                       "the original file was backed up")
    }

    func testReplaceKeepsLinePositionAndFixesIdentitiesOnly() throws {
        let paths = try fixture("Host web\n  IdentityFile ~/.ssh/old\n  IdentitiesOnly no\n  User deploy\n")
        XCTAssertEqual(try apply(paths), "Host web\n  IdentityFile /tmp/keys/id_ed25519_new\n  IdentitiesOnly yes\n  User deploy\n")
    }

    func testAppendKeepsExistingKeysAndExistingYesSpelling() throws {
        let paths = try fixture("Host web\n  IdentityFile ~/.ssh/a\n  IdentityFile ~/.ssh/b\n  IdentitiesOnly True\n")
        XCTAssertEqual(try apply(paths, mode: .append),
                       "Host web\n  IdentityFile ~/.ssh/a\n  IdentityFile ~/.ssh/b\n  IdentitiesOnly True\n  IdentityFile /tmp/keys/id_ed25519_new\n")
    }

    func testReplaceIsRefusedWhenSeveralKeysAreListed() throws {
        let original = "Host web\n  IdentityFile ~/.ssh/a\n  IdentityFile ~/.ssh/b\n"
        let paths = try fixture(original)
        XCTAssertThrowsError(try apply(paths, mode: .replace)) { error in
            XCTAssertTrue(error.localizedDescription.contains("追加"), error.localizedDescription)
        }
        XCTAssertEqual(try String(contentsOf: paths.root, encoding: .utf8), original)
    }

    func testAlreadyConfiguredKeyNeedsNoChange() throws {
        let paths = try fixture("Host web\n  IdentityFile /tmp/keys/id_ed25519_new\n  IdentitiesOnly yes\n")
        XCTAssertThrowsError(try apply(paths)) { error in
            XCTAssertTrue(error.localizedDescription.contains("无需修改"), error.localizedDescription)
        }
    }

    func testComplexHostIsNotWrittenAndSnippetIsOffered() throws {
        let original = "Host web\n  HostName web.example\n  ProxyCommand nc %h %p\n"
        let paths = try fixture(original)
        let scan = ConfigReader(rootURL: paths.root).scan()
        let host = try XCTUnwrap(scan.hosts.first { $0.alias == "web" })
        XCTAssertFalse(host.isSimple)
        XCTAssertThrowsError(try paths.writer.planKeyLogin(proof(), hostID: host.id, mode: .replace, from: scan))
        XCTAssertEqual(try String(contentsOf: paths.root, encoding: .utf8), original)
        XCTAssertEqual(KeyDeployment.configSnippet(alias: "web", identityFile: keyURL.path),
                       "Host web\n  IdentityFile /tmp/keys/id_ed25519_new\n  IdentitiesOnly yes\n")
    }

    func testProofForAnotherHostIsRefused() throws {
        let paths = try fixture("Host web\n  HostName web.example\nHost db\n  HostName db.example\n")
        let scan = ConfigReader(rootURL: paths.root).scan()
        let db = try XCTUnwrap(scan.hosts.first { $0.alias == "db" })
        XCTAssertThrowsError(try paths.writer.planKeyLogin(proof("web"), hostID: db.id, mode: .replace, from: scan))
    }

    func testExternalChangeAfterPreviewIsAConflict() throws {
        let paths = try fixture("Host web\n  HostName web.example\n")
        let scan = ConfigReader(rootURL: paths.root).scan()
        let host = try XCTUnwrap(scan.hosts.first)
        let plan = try paths.writer.planKeyLogin(proof(), hostID: host.id, mode: .replace, from: scan)
        try Data("Host web\n  HostName changed.example\n".utf8).write(to: paths.root)
        XCTAssertThrowsError(try paths.writer.commit(plan))
        XCTAssertEqual(try String(contentsOf: paths.root, encoding: .utf8), "Host web\n  HostName changed.example\n")
    }

    func testPathWithSpacesIsQuotedAndHomeIsShortened() throws {
        XCTAssertEqual(ConfigWriter.displayPath(FileManager.default.homeDirectoryForCurrentUser.path + "/.ssh/id_x"), "~/.ssh/id_x")
        let paths = try fixture("Host web\n  HostName web.example\n")
        let scan = ConfigReader(rootURL: paths.root).scan()
        let host = try XCTUnwrap(scan.hosts.first)
        let spaced = VerifiedKeyLogin(alias: "web", privateKeyURL: URL(fileURLWithPath: "/tmp/my keys/id"), fingerprint: "SHA256:X")
        _ = try paths.writer.commit(paths.writer.planKeyLogin(spaced, hostID: host.id, mode: .replace, from: scan))
        XCTAssertEqual(try String(contentsOf: paths.root, encoding: .utf8),
                       "Host web\n  HostName web.example\n  IdentityFile \"/tmp/my keys/id\"\n  IdentitiesOnly yes\n")
    }

    func testEndToEndDeployVerifyAndWrite() throws {
        let server = try TestSSHServer()
        let key = try server.makeKey("newkey")
        XCTAssertEqual(KeyDeployment.deploy(alias: "target", key: key, options: server.options()), .installed)
        let verification = KeyDeployment.verify(alias: "target", key: key, options: server.options())
        let proof = try XCTUnwrap(verification.proof)

        let paths = try fixture("Host target\n  HostName 127.0.0.1\n")
        let scan = ConfigReader(rootURL: paths.root).scan()
        let host = try XCTUnwrap(scan.hosts.first)
        _ = try paths.writer.commit(paths.writer.planKeyLogin(proof, hostID: host.id, mode: .replace, from: scan))
        XCTAssertEqual(try String(contentsOf: paths.root, encoding: .utf8),
                       "Host target\n  HostName 127.0.0.1\n  IdentityFile \(key.privateKeyURL.path)\n  IdentitiesOnly yes\n")

        try Data().write(to: server.authorizedKeys)
        XCTAssertNil(KeyDeployment.verify(alias: "target", key: key, options: server.options()).proof,
                     "no proof, and therefore no config write, when the key no longer logs in")
    }
}
