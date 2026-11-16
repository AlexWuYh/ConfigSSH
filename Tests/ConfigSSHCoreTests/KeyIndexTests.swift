import Foundation
import XCTest
@testable import ConfigSSHCore

final class KeyIndexTests: XCTestCase {
    func testIndexesPublicKeyWithoutReadingOrChangingPrivateKey() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ConfigSSHKeys-\(UUID().uuidString)")
        let ssh = directory.appendingPathComponent(".ssh")
        try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let privateURL = ssh.appendingPathComponent("id_demo")
        let privateSentinel = Data("PRIVATE-CONTENT-MUST-STAY-UNREAD".utf8)
        try privateSentinel.write(to: privateURL)
        let publicText = "ssh-ed25519 AQIDBA== comment@example\n"
        try Data(publicText.utf8).write(to: ssh.appendingPathComponent("id_demo.pub"))
        try Data("invalid key".utf8).write(to: ssh.appendingPathComponent("broken.pub"))
        let config = ssh.appendingPathComponent("config")
        try Data("Host demo\n IdentityFile ~/.ssh/id_demo\n".utf8).write(to: config)

        let hosts = ConfigReader(rootURL: config).scan().hosts
        let result = KeyIndex(sshDirectory: ssh).scan(hosts: hosts)
        XCTAssertEqual(result.keys.count, 1)
        let key = try XCTUnwrap(result.keys.first)
        XCTAssertEqual(key.type, "ssh-ed25519")
        XCTAssertTrue(try XCTUnwrap(key.fingerprint).hasPrefix("SHA256:"))
        XCTAssertTrue(key.privateKeyExists)
        XCTAssertEqual(key.associatedHosts, ["demo"])
        XCTAssertEqual(key.publicKeyText, publicText.trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertTrue(result.issues.contains { $0.contains("broken.pub") })
        XCTAssertEqual(try Data(contentsOf: privateURL), privateSentinel)
    }

    func testIndexesIdentityFilesReferencedOutsideSSHDirectory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ConfigSSHExternalKeys-\(UUID().uuidString)")
        let ssh = directory.appendingPathComponent(".ssh")
        let external = directory.appendingPathComponent("keys/company")
        try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let privateKey = external.appendingPathComponent("work_key")
        let sentinel = Data("PRIVATE-KEY-SENTINEL".utf8)
        try sentinel.write(to: privateKey)
        let publicText = "ssh-ed25519 AQIDBA== company-key\n"
        try Data(publicText.utf8).write(to: external.appendingPathComponent("work_key.pub"))
        let config = ssh.appendingPathComponent("config")
        try Data("Host company\n  IdentityFile \(privateKey.path)\n".utf8).write(to: config)

        let result = KeyIndex(sshDirectory: ssh).scan(hosts: ConfigReader(rootURL: config).scan().hosts)
        let record = try XCTUnwrap(result.keys.first)
        XCTAssertEqual(result.keys.count, 1)
        XCTAssertEqual(record.privateKeyURL, privateKey)
        XCTAssertEqual(record.associatedHosts, ["company"])
        XCTAssertTrue(record.publicKeyExists)
        XCTAssertEqual(try Data(contentsOf: privateKey), sentinel)
    }

    func testShowsReferencedPrivateKeyWhenPublicFileIsMissing() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ConfigSSHMissingPublicKey-\(UUID().uuidString)")
        let ssh = directory.appendingPathComponent(".ssh")
        let external = directory.appendingPathComponent("keys/key_no_pub")
        try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: external.deletingLastPathComponent(), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        try Data("PRIVATE-SENTINEL".utf8).write(to: external)
        let config = ssh.appendingPathComponent("config")
        try Data("Host missing-pub\n  IdentityFile \(external.path)\n".utf8).write(to: config)

        let result = KeyIndex(sshDirectory: ssh).scan(hosts: ConfigReader(rootURL: config).scan().hosts)
        let record = try XCTUnwrap(result.keys.first)
        XCTAssertFalse(record.publicKeyExists)
        XCTAssertTrue(record.privateKeyExists)
        XCTAssertEqual(record.associatedHosts, ["missing-pub"])
        XCTAssertNil(record.publicKeyText)
    }

    func testIndexesNestedPublicKeysAndGlobalIdentityFileWithoutReadingPrivateBytes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ConfigSSHNestedKeys-\(UUID().uuidString)")
        let ssh = directory.appendingPathComponent(".ssh")
        let nested = ssh.appendingPathComponent("keys/team")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let privateURL = nested.appendingPathComponent("id_team")
        let sentinel = Data("PRIVATE-KEY-UNREAD".utf8)
        try sentinel.write(to: privateURL)
        try Data("ssh-ed25519 AQIDBA== team\n".utf8)
            .write(to: URL(fileURLWithPath: privateURL.path + ".pub"))
        let config = ssh.appendingPathComponent("config")
        try Data("IdentityFile ~/.ssh/keys/team/id_team\nHost demo\n  HostName demo.example\n".utf8).write(to: config)
        let scan = ConfigReader(rootURL: config).scan()
        let indexed = KeyIndex(sshDirectory: ssh).scan(hosts: scan.hosts, globalOptions: scan.globalOptions)
        let key = try XCTUnwrap(indexed.keys.first)
        XCTAssertEqual(indexed.keys.count, 1)
        XCTAssertTrue(key.isReferencedGlobally)
        XCTAssertTrue(key.associatedHosts.isEmpty)
        XCTAssertEqual(key.privateKeyURL, privateURL)
        XCTAssertEqual(try Data(contentsOf: privateURL), sentinel)
    }

    func testSSHKeyGenerationCreatesPrivatePermissionsAndNeverOverwrites() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ConfigSSHGeneratedKey-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let key = directory.appendingPathComponent("id_configssh")
        try SSHKeyGenerator.generate(path: key, algorithm: .ed25519, comment: "configssh-test")
        XCTAssertTrue(FileManager.default.fileExists(atPath: key.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: key.path + ".pub"))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: key.path))[.posixPermissions] as? Int, 0o600)
        XCTAssertThrowsError(try SSHKeyGenerator.generate(path: key, algorithm: .ed25519, comment: "again"))
    }

    func testSuggestedKeyNameUsesTimestampAndIsUniqueForRepeatedClicks() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ConfigSSHName-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let suggestions = (0..<50).map { _ in
            SSHKeyGenerator.suggestedPath(in: directory, algorithm: .ed25519, now: fixedDate)
        }
        XCTAssertEqual(Set(suggestions.map(\.path)).count, suggestions.count)
        XCTAssertEqual(suggestions.first?.lastPathComponent, "id_ed25519_1700000000000")
        XCTAssertEqual(suggestions.last?.lastPathComponent, "id_ed25519_1700000000049")
        XCTAssertTrue(suggestions.allSatisfy { $0.lastPathComponent.count <= 25 })
    }

    func testSSHKeyGenerationRefusesExistingSymlinkTargets() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ConfigSSHKeySymlink-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("id_link")
        let sentinel = directory.appendingPathComponent("sentinel")
        try Data("untouched".utf8).write(to: sentinel)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: sentinel)
        XCTAssertThrowsError(try SSHKeyGenerator.generate(path: target, algorithm: .ed25519, comment: "test"))
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "untouched")
    }

    func testKeyGenerationNeverOverwritesTargetCreatedDuringGeneration() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ConfigSSHKeyRace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("id_race")
        let sentinel = Data("existing private key".utf8)
        XCTAssertThrowsError(try SSHKeyGenerator.generate(path: target, algorithm: .ed25519,
                                                           comment: "fixture", beforePublish: {
            try sentinel.write(to: target)
        }))
        XCTAssertEqual(try Data(contentsOf: target), sentinel)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path + ".pub"))
    }

    func testKeyGenerationRollsBackPrivateKeyWhenPublicTargetAppears() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ConfigSSHKeyRacePub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("id_race")
        let sentinel = Data("existing public key".utf8)
        XCTAssertThrowsError(try SSHKeyGenerator.generate(path: target, algorithm: .ed25519,
                                                           comment: "fixture", beforePublish: {
            try sentinel.write(to: URL(fileURLWithPath: target.path + ".pub"))
        }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: target.path + ".pub")), sentinel)
    }

    func testExternalProcessTimeoutStopsProcess() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["2"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let started = Date()
        XCTAssertThrowsError(try BoundedProcessRunner.run(process, timeout: 0.05))
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
        XCTAssertFalse(process.isRunning)
    }
}
