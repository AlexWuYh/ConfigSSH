import Foundation
import XCTest
@testable import ConfigSSHCore

final class GroupManagementTests: XCTestCase {
    private enum InjectedFailure: Error { case afterFiles }

    private func fixture() throws -> (ConfigWriter, URL) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("ConfigSSHGroups-\(UUID().uuidString)")
        let ssh = home.appendingPathComponent(".ssh")
        try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        let root = ssh.appendingPathComponent("config")
        return (ConfigWriter(rootURL: root, backupDirectory: home.appendingPathComponent("backups")), root)
    }

    func testEmptyGroupPersistsWhenItsLastHostIsDeleted() throws {
        let (writer, root) = try fixture()
        try writer.createGroup(named: "Work")
        XCTAssertEqual(writer.groupDirectories(), ["Work"])
        let add = try writer.plan(.add(HostInput(alias: "demo", hostName: "demo.example", group: "Work")),
                                  from: ConfigReader(rootURL: root).scan())
        _ = try writer.commit(add)
        let host = try XCTUnwrap(ConfigReader(rootURL: root).scan().hosts.first)
        _ = try writer.commit(writer.plan(.delete(hostID: host.id), from: ConfigReader(rootURL: root).scan()))
        XCTAssertTrue(ConfigReader(rootURL: root).scan().hosts.isEmpty)
        XCTAssertEqual(writer.groupDirectories(), ["Work"])
    }

    func testDeleteGroupMovesHostsToUngroupedWithoutChangingTheirBytes() throws {
        let (writer, root) = try fixture()
        try writer.createGroup(named: "Work")
        _ = try writer.commit(writer.plan(.add(HostInput(alias: "demo", hostName: "demo.example", group: "Work")),
                                          from: ConfigReader(rootURL: root).scan()))
        let before = try Data(contentsOf: writer.managedDirectoryURL.appendingPathComponent("Work/demo.conf"))
        let rootBefore = try Data(contentsOf: root)
        let plan = try writer.planGroupDeletion(named: "Work", from: ConfigReader(rootURL: root).scan())
        XCTAssertEqual(plan.movedHosts.map(\.alias), ["demo"])
        XCTAssertEqual(plan.changePlan?.changes.count, 2)
        _ = try writer.commit(try XCTUnwrap(plan.changePlan))
        try writer.removeEmptyGroupDirectory(plan)
        XCTAssertEqual(try Data(contentsOf: writer.managedDirectoryURL.appendingPathComponent("demo.conf")), before)
        XCTAssertEqual(try Data(contentsOf: root), rootBefore)
        XCTAssertFalse(writer.groupDirectories().contains("Work"))
        let newHost = try XCTUnwrap(ConfigReader(rootURL: root).scan().hosts.first)
        XCTAssertNil(newHost.configGroup)
    }

    func testDeletingEmptyGroupDoesNotTouchRootConfig() throws {
        let (writer, root) = try fixture()
        try writer.createGroup(named: "Empty")
        let plan = try writer.planGroupDeletion(named: "Empty", from: ConfigReader(rootURL: root).scan())
        XCTAssertNil(plan.changePlan)
        try writer.removeEmptyGroupDirectory(plan)
        XCTAssertFalse(writer.groupDirectories().contains("Empty"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testDeletingGroupInstallsUngroupedIncludeWhenNeeded() throws {
        let (writer, root) = try fixture()
        try writer.createGroup(named: "Work")
        try Data("Include config.d/*/*.conf\n".utf8).write(to: root)
        try Data("Host demo\n  HostName demo.example\n".utf8)
            .write(to: writer.managedDirectoryURL.appendingPathComponent("Work/demo.conf"))
        let scan = ConfigReader(rootURL: root).scan()
        XCTAssertEqual(scan.hosts.map(\.alias), ["demo"])
        let plan = try writer.planGroupDeletion(named: "Work", from: scan)
        XCTAssertEqual(plan.changePlan?.changes.count, 3)
        _ = try writer.commit(try XCTUnwrap(plan.changePlan))
        try writer.removeEmptyGroupDirectory(plan)
        XCTAssertTrue(try String(contentsOf: root, encoding: .utf8).contains("Include config.d/*.conf"))
        XCTAssertEqual(ConfigReader(rootURL: root).scan().hosts.map(\.alias), ["demo"])
    }

    func testUnsafeGroupNamesAndUnexpectedFilesAreRejected() throws {
        let (writer, root) = try fixture()
        for name in ["", "未分组", "../x", "a/b", "foo*", " bad"] {
            XCTAssertThrowsError(try writer.createGroup(named: name))
        }
        try writer.createGroup(named: "Work")
        let extra = writer.managedDirectoryURL.appendingPathComponent("Work/readme.txt")
        try Data("keep".utf8).write(to: extra)
        XCTAssertThrowsError(try writer.planGroupDeletion(named: "Work", from: ConfigReader(rootURL: root).scan()))
        XCTAssertEqual(try Data(contentsOf: extra), Data("keep".utf8))
    }

    func testDeletingGroupDoesNotOverwriteUngroupedFile() throws {
        let (writer, root) = try fixture()
        try writer.createGroup(named: "Work")
        try Data("Include config.d/*.conf\nInclude config.d/*/*.conf\n".utf8).write(to: root)
        let grouped = writer.managedDirectoryURL.appendingPathComponent("Work/demo.conf")
        let ungrouped = writer.managedDirectoryURL.appendingPathComponent("demo.conf")
        try Data("Host demo\n  HostName grouped.example\n".utf8).write(to: grouped)
        let existing = Data("Host other\n  HostName other.example\n".utf8)
        try existing.write(to: ungrouped)
        XCTAssertThrowsError(try writer.planGroupDeletion(named: "Work", from: ConfigReader(rootURL: root).scan()))
        XCTAssertEqual(try Data(contentsOf: ungrouped), existing)
        XCTAssertTrue(FileManager.default.fileExists(atPath: grouped.path))
    }

    func testGroupDeletionRollsBackFilesAndKeepsMetadataWhenNextStepFails() throws {
        let (writer, root) = try fixture()
        try writer.createGroup(named: "Work")
        _ = try writer.commit(writer.plan(.add(HostInput(alias: "demo", hostName: "demo.example", group: "Work")),
                                          from: ConfigReader(rootURL: root).scan()))
        let store = try MetadataStore(databaseURL: root.deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("metadata.sqlite"))
        let host = try XCTUnwrap(ConfigReader(rootURL: root).scan().hosts.first)
        try store.save(HostMetadata(hostKey: host.metadataKey, displayName: "测试", groupName: "Work", isFavorite: true))
        try store.recordLaunch(hostKey: host.metadataKey, terminal: "com.apple.Terminal")
        let original = try Data(contentsOf: host.sourceURL)
        let service = GroupDeletionService(writer: writer, metadataStore: store)
        let plan = try writer.planGroupDeletion(named: "Work", from: ConfigReader(rootURL: root).scan())

        XCTAssertThrowsError(try service.delete(plan, afterFilesCommitted: { throw InjectedFailure.afterFiles }))
        XCTAssertEqual(try Data(contentsOf: host.sourceURL), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: writer.managedDirectoryURL.appendingPathComponent("demo.conf").path))
        XCTAssertTrue(try XCTUnwrap(store.allMetadata()[host.metadataKey]).isFavorite)
        XCTAssertEqual(try store.recentEvents().first?.hostKey, host.metadataKey)
        XCTAssertTrue(try service.pendingOperations().isEmpty)
    }

    func testGroupDeletionCanResumeAfterFilesWereCommitted() throws {
        let (writer, root) = try fixture()
        try writer.createGroup(named: "Work")
        _ = try writer.commit(writer.plan(.add(HostInput(alias: "demo", hostName: "demo.example", group: "Work")),
                                          from: ConfigReader(rootURL: root).scan()))
        let store = try MetadataStore(databaseURL: root.deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("metadata.sqlite"))
        let host = try XCTUnwrap(ConfigReader(rootURL: root).scan().hosts.first)
        try store.save(HostMetadata(hostKey: host.metadataKey, displayName: "测试", groupName: "Work", isFavorite: true))
        let service = GroupDeletionService(writer: writer, metadataStore: store)
        let plan = try writer.planGroupDeletion(named: "Work", from: ConfigReader(rootURL: root).scan())
        let journal = try service.prepare(plan)
        let journalURL = writer.backups.directoryURL
            .appendingPathComponent("GroupOperations/\(journal.id.uuidString).json")
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: journalURL.path))[.posixPermissions] as? Int, 0o600)
        _ = try writer.commit(try XCTUnwrap(plan.changePlan))

        XCTAssertEqual(try service.pendingOperations().count, 1)
        try service.resume(journal)
        XCTAssertTrue(try service.pendingOperations().isEmpty)
        XCTAssertFalse(writer.groupDirectories().contains("Work"))
        let moved = try XCTUnwrap(ConfigReader(rootURL: root).scan().hosts.first)
        XCTAssertNil(moved.configGroup)
        XCTAssertTrue(try XCTUnwrap(store.allMetadata()[moved.metadataKey]).isFavorite)
    }

    func testResumeRefusesExternalEditAndKeepsRecoveryJournal() throws {
        let (writer, root) = try fixture()
        try writer.createGroup(named: "Work")
        _ = try writer.commit(writer.plan(.add(HostInput(alias: "demo", hostName: "demo.example", group: "Work")),
                                          from: ConfigReader(rootURL: root).scan()))
        let store = try MetadataStore(databaseURL: root.deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("metadata.sqlite"))
        let service = GroupDeletionService(writer: writer, metadataStore: store)
        let plan = try writer.planGroupDeletion(named: "Work", from: ConfigReader(rootURL: root).scan())
        let journal = try service.prepare(plan)
        _ = try writer.commit(try XCTUnwrap(plan.changePlan))
        let target = writer.managedDirectoryURL.appendingPathComponent("demo.conf")
        try Data("# external edit\n".utf8).write(to: target)

        XCTAssertThrowsError(try service.resume(journal))
        XCTAssertEqual(try service.pendingOperations().count, 1)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "# external edit\n")
    }

    func testResumeAfterMetadataCommitIsIdempotent() throws {
        let (writer, root) = try fixture()
        try writer.createGroup(named: "Work")
        _ = try writer.commit(writer.plan(.add(HostInput(alias: "demo", hostName: "demo.example", group: "Work")),
                                          from: ConfigReader(rootURL: root).scan()))
        let store = try MetadataStore(databaseURL: root.deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("metadata.sqlite"))
        let host = try XCTUnwrap(ConfigReader(rootURL: root).scan().hosts.first)
        try store.save(HostMetadata(hostKey: host.metadataKey, displayName: "测试", groupName: "Work", isFavorite: true))
        let service = GroupDeletionService(writer: writer, metadataStore: store)
        let plan = try writer.planGroupDeletion(named: "Work", from: ConfigReader(rootURL: root).scan())
        let journal = try service.prepare(plan)
        _ = try writer.commit(try XCTUnwrap(plan.changePlan))
        try writer.removeEmptyGroupDirectory(plan)
        let destination = writer.managedDirectoryURL.appendingPathComponent("demo.conf")
        let newKey = "\(destination.path)\u{1F}demo"
        try store.completeGroupDeletion(mappings: [(host.metadataKey, newKey)], groupName: "Work")

        try service.resume(journal)
        XCTAssertTrue(try service.pendingOperations().isEmpty)
        XCTAssertTrue(try XCTUnwrap(store.allMetadata()[newKey]).isFavorite)
        XCTAssertFalse(writer.groupDirectories().contains("Work"))
    }

    func testGroupDeletionDoesNotOverwriteConflictingMetadata() throws {
        let (writer, root) = try fixture()
        try writer.createGroup(named: "Work")
        _ = try writer.commit(writer.plan(.add(HostInput(alias: "demo", hostName: "demo.example", group: "Work")),
                                          from: ConfigReader(rootURL: root).scan()))
        let store = try MetadataStore(databaseURL: root.deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("metadata.sqlite"))
        let host = try XCTUnwrap(ConfigReader(rootURL: root).scan().hosts.first)
        let targetKey = "\(writer.managedDirectoryURL.appendingPathComponent("demo.conf").path)\u{1F}demo"
        try store.save(HostMetadata(hostKey: host.metadataKey, displayName: "原始"))
        try store.save(HostMetadata(hostKey: targetKey, displayName: "现有"))
        let service = GroupDeletionService(writer: writer, metadataStore: store)
        let plan = try writer.planGroupDeletion(named: "Work", from: ConfigReader(rootURL: root).scan())

        XCTAssertThrowsError(try service.delete(plan))
        XCTAssertTrue(FileManager.default.fileExists(atPath: host.sourceURL.path))
        XCTAssertEqual(try store.allMetadata()[host.metadataKey]?.displayName, "原始")
        XCTAssertEqual(try store.allMetadata()[targetKey]?.displayName, "现有")
        XCTAssertTrue(try service.pendingOperations().isEmpty)
    }

    func testDirectoryRemovalFailureRestoresMovedHosts() throws {
        let (writer, root) = try fixture()
        try writer.createGroup(named: "Work")
        _ = try writer.commit(writer.plan(.add(HostInput(alias: "demo", hostName: "demo.example", group: "Work")),
                                          from: ConfigReader(rootURL: root).scan()))
        let store = try MetadataStore(databaseURL: root.deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("metadata.sqlite"))
        let service = GroupDeletionService(writer: writer, metadataStore: store)
        let plan = try writer.planGroupDeletion(named: "Work", from: ConfigReader(rootURL: root).scan())
        let unexpected = writer.managedDirectoryURL.appendingPathComponent("Work/unexpected.txt")

        XCTAssertThrowsError(try service.delete(plan, afterFilesCommitted: {
            try Data("other app wrote this".utf8).write(to: unexpected)
        }))
        XCTAssertTrue(FileManager.default.fileExists(atPath: writer.managedDirectoryURL.appendingPathComponent("Work/demo.conf").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: writer.managedDirectoryURL.appendingPathComponent("demo.conf").path))
        XCTAssertEqual(try String(contentsOf: unexpected, encoding: .utf8), "other app wrote this")
        XCTAssertTrue(try service.pendingOperations().isEmpty)
    }
}
