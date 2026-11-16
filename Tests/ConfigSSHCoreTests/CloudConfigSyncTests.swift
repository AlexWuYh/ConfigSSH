import Foundation
import XCTest
@testable import ConfigSSHCore

final class CloudConfigSyncTests: XCTestCase {
    private let passphrase = "correct horse battery staple"

    private func fixture() throws -> (home: URL, root: URL, cloud: URL, service: CloudConfigSyncService) {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConfigSSHCloudSync-\(UUID().uuidString)")
        let ssh = home.appendingPathComponent(".ssh")
        let group = ssh.appendingPathComponent("config.d/Work")
        let cloud = home.appendingPathComponent("iCloudDrive")
        try FileManager.default.createDirectory(at: group, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
        let root = ssh.appendingPathComponent("config")
        try Data("Include config.d/*/*.conf\n".utf8).write(to: root)
        try Data("Host demo\n  HostName demo.example\n".utf8)
            .write(to: group.appendingPathComponent("demo.conf"))
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        return (home, root, cloud,
                CloudConfigSyncService(folder: cloud.appendingPathComponent("ConfigSSH"), cloudRoot: cloud))
    }

    func testPushIsEncryptedAndTwoDevicesHaveIndependentSlots() throws {
        let item = try fixture()
        try item.service.testConnection()
        let first = UUID()
        let second = UUID()
        for (device, name) in [(first, "Mac One"), (second, "Mac Two")] {
            let plan = try item.service.planPush(scan: ConfigReader(rootURL: item.root).scan(),
                                                 deviceID: device, deviceName: name, passphrase: passphrase)
            XCTAssertEqual(plan.fileCount, 2)
            try item.service.push(plan)
        }
        XCTAssertEqual(Set(try item.service.slots().map(\.deviceID)), Set([first, second]))
        let summaries = try item.service.describeSlots(passphrase: passphrase)
        XCTAssertEqual(Set(summaries.compactMap(\.deviceName)), Set(["Mac One", "Mac Two"]))
        XCTAssertTrue(summaries.allSatisfy { $0.error == nil })
        XCTAssertTrue(try item.service.describeSlots(passphrase: "wrong password 123")
            .allSatisfy { $0.deviceName == nil && $0.error != nil })
        for slot in try item.service.slots() {
            let data = try Data(contentsOf: slot.url)
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("Host demo"))
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("demo.example"))
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("Mac One"))
        }
        let firstPlan = try item.service.planPush(scan: ConfigReader(rootURL: item.root).scan(),
                                                 deviceID: first, deviceName: "Mac One", passphrase: passphrase)
        try item.service.push(firstPlan)
        XCTAssertEqual(try item.service.slots().count, 2)
        XCTAssertThrowsError(try item.service.planPush(scan: ConfigReader(rootURL: item.root).scan(),
                                                       deviceID: first, deviceName: "Mac One",
                                                       passphrase: "different strong password"))
    }

    func testPullMapsRelativePathsAndBacksUpReplacedFiles() throws {
        let item = try fixture()
        let device = UUID()
        try item.service.push(item.service.planPush(scan: ConfigReader(rootURL: item.root).scan(),
                                                   deviceID: device, deviceName: "Source Mac",
                                                   passphrase: passphrase))
        let secondSSH = item.home.appendingPathComponent("second/.ssh")
        try FileManager.default.createDirectory(at: secondSSH, withIntermediateDirectories: true)
        let secondRoot = secondSSH.appendingPathComponent("config")
        try Data("# local\n".utf8).write(to: secondRoot)
        let writer = ConfigWriter(rootURL: secondRoot,
                                  backupDirectory: item.home.appendingPathComponent("backups"))
        let slot = try XCTUnwrap(item.service.slots().first)
        let plan = try item.service.planPull(slot: slot, writer: writer, passphrase: passphrase)
        XCTAssertEqual(plan.archive.deviceName, "Source Mac")
        XCTAssertEqual(plan.changes.changes.count, 2)
        try item.service.pull(plan, writer: writer)
        XCTAssertEqual(try Data(contentsOf: secondRoot), Data("Include config.d/*/*.conf\n".utf8))
        XCTAssertEqual(ConfigReader(rootURL: secondRoot).scan().hosts.map(\.alias), ["demo"])
        XCTAssertEqual(try writer.backups.list().count, 2)
    }

    func testWrongPassphraseTamperAndPreviewConflictAreRejected() throws {
        let item = try fixture()
        let device = UUID()
        try item.service.push(item.service.planPush(scan: ConfigReader(rootURL: item.root).scan(),
                                                   deviceID: device, deviceName: "Mac",
                                                   passphrase: passphrase))
        let secondRoot = item.home.appendingPathComponent("second/.ssh/config")
        try FileManager.default.createDirectory(at: secondRoot.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("# local\n".utf8).write(to: secondRoot)
        let writer = ConfigWriter(rootURL: secondRoot,
                                  backupDirectory: item.home.appendingPathComponent("backups"))
        let slot = try XCTUnwrap(item.service.slots().first)
        XCTAssertThrowsError(try item.service.planPull(slot: slot, writer: writer,
                                                        passphrase: "wrong password 123"))
        let plan = try item.service.planPull(slot: slot, writer: writer, passphrase: passphrase)
        try Data("# externally changed\n".utf8).write(to: secondRoot)
        XCTAssertThrowsError(try item.service.pull(plan, writer: writer))
        XCTAssertEqual(try Data(contentsOf: secondRoot), Data("# externally changed\n".utf8))
        var encrypted = try Data(contentsOf: slot.url)
        encrypted[encrypted.count - 5] ^= 0x01
        try encrypted.write(to: slot.url)
        XCTAssertThrowsError(try item.service.planPull(slot: slot, writer: writer, passphrase: passphrase))
    }

    func testPushSkipsExternalIncludeWithWarningAndRejectsSymlinkedCloudFolder() throws {
        let item = try fixture()
        let external = item.home.appendingPathComponent("external.conf")
        try Data("Host outside\n".utf8).write(to: external)
        try Data("Include \(external.path)\n".utf8).write(to: item.root)
        let device = UUID()
        let plan = try item.service.planPush(scan: ConfigReader(rootURL: item.root).scan(),
                                             deviceID: device, deviceName: "Mac",
                                             passphrase: passphrase)
        XCTAssertEqual(plan.fileCount, 1)
        XCTAssertEqual(plan.skippedSources, [external.standardizedFileURL.path])
        XCTAssertTrue(plan.warnings.contains { $0.contains("跳过") })
        try item.service.push(plan)
        let archive = try CloudConfigCrypto.decrypt(Data(contentsOf: plan.slot.url),
                                                    deviceID: device, passphrase: passphrase)
        XCTAssertEqual(archive.files.map(\.relativePath), ["config"])
        let link = item.cloud.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: item.home)
        let linked = CloudConfigSyncService(folder: link.appendingPathComponent("ConfigSSH"), cloudRoot: item.cloud)
        XCTAssertThrowsError(try linked.testConnection())
    }

    func testPullRejectsArchiveTargetingPrivateKey() throws {
        let item = try fixture()
        let device = UUID()
        let archive = CloudConfigArchive(deviceID: device, deviceName: "Untrusted",
                                         createdAt: Date(), files: [
                                            CloudConfigFile(relativePath: "config", content: Data("# valid\n".utf8)),
                                            CloudConfigFile(relativePath: "id_ed25519", content: Data("fake secret".utf8))
                                         ])
        let devices = item.cloud.appendingPathComponent("ConfigSSH/Devices")
        try FileManager.default.createDirectory(at: devices, withIntermediateDirectories: true)
        let slotURL = devices.appendingPathComponent("\(device.uuidString.lowercased()).cssh")
        try CloudConfigCrypto.encrypt(archive, passphrase: passphrase).write(to: slotURL)
        let slot = try XCTUnwrap(item.service.slots().first)
        let writer = ConfigWriter(rootURL: item.root,
                                  backupDirectory: item.home.appendingPathComponent("backups"))
        XCTAssertThrowsError(try item.service.planPull(slot: slot, writer: writer, passphrase: passphrase))
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.home.appendingPathComponent(".ssh/id_ed25519").path))
    }

    func testPushSkipsSymlinkedIncludedDirectoryWithWarning() throws {
        let item = try fixture()
        let source = item.home.appendingPathComponent("external")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("Host hidden\n".utf8).write(to: source.appendingPathComponent("hidden.conf"))
        let ssh = item.root.deletingLastPathComponent()
        try FileManager.default.createSymbolicLink(at: ssh.appendingPathComponent("config.d/Linked"),
                                                   withDestinationURL: source)
        try Data("Include config.d/Linked/*.conf\n".utf8).write(to: item.root)
        let plan = try item.service.planPush(scan: ConfigReader(rootURL: item.root).scan(),
                                             deviceID: UUID(), deviceName: "Mac",
                                             passphrase: passphrase)
        XCTAssertEqual(plan.fileCount, 1)
        XCTAssertEqual(plan.skippedSources.count, 1)
        XCTAssertTrue(plan.warnings.contains { $0.contains("跳过") })
    }

    func testCloudPullRejectsCaseOrNormalizationCollidingPaths() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("ConfigSSHPullCase-\(UUID().uuidString)")
        let ssh = home.appendingPathComponent(".ssh")
        try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        let root = ssh.appendingPathComponent("config")
        try Data("# local\n".utf8).write(to: root)
        let writer = ConfigWriter(rootURL: root, backupDirectory: home.appendingPathComponent("backups"))
        let base = CloudConfigFile(relativePath: "config", content: Data("Include config.d/*.conf\n".utf8))
        for pair in [("config.d/Web.conf", "config.d/web.conf"),
                     ("config.d/caf\u{E9}.conf", "config.d/cafe\u{301}.conf")] {
            XCTAssertThrowsError(try writer.planCloudPull([
                base,
                CloudConfigFile(relativePath: pair.0, content: Data("Host a\n".utf8)),
                CloudConfigFile(relativePath: pair.1, content: Data("Host b\n".utf8)),
            ]), "\(pair)")
        }
    }
}
