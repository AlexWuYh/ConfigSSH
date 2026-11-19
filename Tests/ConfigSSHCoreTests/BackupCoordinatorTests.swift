import Foundation
import XCTest
@testable import ConfigSSHCore

final class BackupCoordinatorTests: XCTestCase {
    private let passphrase = "correct horse battery"
    private let deviceID = UUID(uuidString: "00000000-0000-4000-8000-0000000000AA")!

    private struct Fixture {
        let home: URL, root: URL, snapshots: URL, cloudRoot: URL, cloudFolder: URL
    }

    private func fixture() throws -> Fixture {
        let home = URL(fileURLWithPath: "/private" + FileManager.default.temporaryDirectory.path)
            .appendingPathComponent("ConfigSSHCoord-\(UUID().uuidString)")
        let ssh = home.appendingPathComponent(".ssh")
        // Snapshot folders need the /private/var spelling; the cloud service normalises an existing
        // directory to /var, so the fake iCloud Drive uses that spelling for root and folder alike.
        let cloudRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ConfigSSHCoordCloud-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: ssh.appendingPathComponent("config.d"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cloudRoot, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home); try? FileManager.default.removeItem(at: cloudRoot) }
        let root = ssh.appendingPathComponent("config")
        try Data("Include config.d/*.conf\nServerAliveInterval 60\n".utf8).write(to: root)
        try Data("Host web\n  HostName web.example\n".utf8).write(to: ssh.appendingPathComponent("config.d/web.conf"))
        return Fixture(home: home, root: root, snapshots: home.appendingPathComponent("Snapshots"),
                       cloudRoot: cloudRoot, cloudFolder: cloudRoot.appendingPathComponent("ConfigSSH"))
    }

    private func environment(_ f: Fixture, cloud: Bool = true, accepts: Bool = true, available: Bool = true, keep: Int = 14) -> BackupEnvironment {
        BackupEnvironment(snapshotFolder: f.snapshots, keepAutomatic: keep, appVersion: "0.3.0", deviceName: "Test Mac",
                          cloud: cloud ? BackupCloudTarget(service: CloudConfigSyncService(folder: f.cloudFolder, cloudRoot: f.cloudRoot),
                                                           deviceID: deviceID, deviceName: "Test Mac", acceptsIncompleteMirror: accepts) : nil,
                          iCloudAvailable: available)
    }

    private func run(_ f: Fixture, _ plan: BackupPlan, state: BackupState = BackupState(), passphrase: String? = "correct horse battery",
                     env: BackupEnvironment? = nil, changedAgo: TimeInterval? = nil, at now: Date = Date()) -> (state: BackupState, report: BackupReport) {
        BackupCoordinator.run(plan: plan, scan: ConfigReader(rootURL: f.root).scan(), passphrase: passphrase,
                              environment: env ?? environment(f), state: state,
                              lastChangeAt: changedAgo.map { now.addingTimeInterval(-$0) }, now: now)
    }

    private let all = BackupPlan(isEnabled: true, snapshotFrequency: .daily, syncToICloud: true)

    func testFirstRunTakesAnEncryptedSnapshotAndUploadsAnEncryptedDeviceFile() throws {
        let f = try fixture()
        let result = run(f, all)
        XCTAssertTrue(result.report.errors.isEmpty, "\(result.report.errors)")
        XCTAssertNotNil(result.report.snapshotURL)
        XCTAssertEqual(result.report.pushedFileCount, 2)
        let cloudFile = f.cloudFolder.appendingPathComponent("Devices/\(deviceID.uuidString.lowercased()).cssh")
        let bytes = try Data(contentsOf: cloudFile)
        XCTAssertNil(bytes.range(of: Data("web.example".utf8)), "the cloud file is encrypted")
        XCTAssertNotNil(result.state.lastSnapshotAt)
        XCTAssertNotNil(result.state.lastCloudAt)
    }

    func testNothingIsDoneWhenNothingChangedAndTheCloudFollowsEveryEditWhileSnapshotsStayDaily() throws {
        let f = try fixture()
        let now = Date()
        var state = run(f, all, at: now).state
        XCTAssertFalse(run(f, all, state: state, at: now.addingTimeInterval(60)).report.didSomething, "unchanged")

        try Data("Include config.d/*.conf\nServerAliveInterval 120\n".utf8).write(to: f.root)
        let later = now.addingTimeInterval(120)
        let afterEdit = run(f, all, state: state, changedAgo: 30, at: later)
        XCTAssertNil(afterEdit.report.snapshotURL, "a snapshot was taken two minutes ago; at most one a day")
        XCTAssertNotNil(afterEdit.report.pushedFileCount, "the cloud copy follows the edit")
        state = afterEdit.state

        let nextDay = run(f, all, state: state, at: later.addingTimeInterval(86_400 + 5))
        XCTAssertNotNil(nextDay.report.snapshotURL, "a day later the changed config gets a new snapshot")
        XCTAssertNil(nextDay.report.pushedFileCount, "the cloud already has this version")
    }

    func testDebouncedEditsWaitAndReportWhenToLookAgain() throws {
        let f = try fixture()
        let now = Date()
        let state = run(f, BackupPlan(isEnabled: true, snapshotFrequency: .off, syncToICloud: true), at: now).state
        try Data("Include config.d/*.conf\nServerAliveInterval 7\n".utf8).write(to: f.root)
        let waiting = run(f, BackupPlan(isEnabled: true, snapshotFrequency: .off, syncToICloud: true), state: state, changedAgo: 1, at: now.addingTimeInterval(10))
        XCTAssertFalse(waiting.report.didSomething)
        XCTAssertNotNil(waiting.report.recheckAt)
    }

    func testNoPassphraseMeansNoBackupAtAll() throws {
        let f = try fixture()
        let result = run(f, all, passphrase: nil)
        XCTAssertFalse(result.report.didSomething)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.snapshots.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.cloudFolder.path))
    }

    func testExternalIncludeFilesNeedAcknowledgementBeforeAutomaticUpload() throws {
        let f = try fixture()
        let external = f.home.appendingPathComponent("shared.conf")
        try Data("Host ext\n  HostName ext.example\n".utf8).write(to: external)
        try Data("Include config.d/*.conf\nInclude \(external.path)\n".utf8).write(to: f.root)
        let blocked = run(f, all, env: environment(f, accepts: false))
        XCTAssertNil(blocked.report.pushedFileCount)
        XCTAssertTrue(blocked.report.notes.contains { $0.contains("确认") }, "\(blocked.report.notes)")
        XCTAssertNotNil(blocked.report.snapshotURL, "the local snapshot is not blocked by the cloud rule")
        let allowed = run(f, all, env: environment(f, accepts: true))
        XCTAssertEqual(allowed.report.pushedFileCount, 2, "only the files inside ~/.ssh are uploaded")
    }

    func testAnUnreadableOwnSlotIsNeverReplacedAutomatically() throws {
        let f = try fixture()
        _ = run(f, all)
        let other = "another passphrase 123"
        try Data("Include config.d/*.conf\nServerAliveInterval 5\n".utf8).write(to: f.root)
        let result = run(f, BackupPlan(isEnabled: true, snapshotFrequency: .off, syncToICloud: true), passphrase: other)
        XCTAssertNil(result.report.pushedFileCount)
        XCTAssertTrue(result.report.errors.first?.contains("覆盖") == true, "\(result.report.errors)")
    }

    func testICloudUnavailablePausesOnlyTheCloudPart() throws {
        let f = try fixture()
        let result = run(f, all, env: environment(f, available: false))
        XCTAssertNotNil(result.report.snapshotURL)
        XCTAssertNil(result.report.pushedFileCount)
        XCTAssertTrue(result.report.notes.contains { $0.contains("iCloud") })
    }

    func testAFailingSnapshotDoesNotAdvanceStateOrStopTheUpload() throws {
        let f = try fixture()
        try Data("file".utf8).write(to: f.snapshots) // a file where the folder should be
        let result = run(f, all)
        XCTAssertNil(result.state.lastSnapshotAt)
        XCTAssertTrue(result.report.errors.contains { $0.contains("本机快照失败") })
        XCTAssertNotNil(result.report.pushedFileCount)
    }

    func testBackupNowIgnoresTheDailyLimitAndTheUnchangedCheck() throws {
        let f = try fixture()
        let first = run(f, all)
        let now = BackupCoordinator.backupNow(scan: ConfigReader(rootURL: f.root).scan(), passphrase: passphrase,
                                              environment: environment(f), state: first.state, includeCloud: true,
                                              now: Date().addingTimeInterval(10))
        XCTAssertNotNil(now.report.snapshotURL, "a manual snapshot even though nothing changed")
        XCTAssertEqual(try EncryptedSnapshotService(folder: f.snapshots).list().records.map(\.header.isAutomatic).sorted { !$0 && $1 }, [false, true])
        XCTAssertEqual(now.report.pushedFileCount, 2)
        XCTAssertNotNil(BackupCoordinator.backupNow(scan: ConfigReader(rootURL: f.root).scan(), passphrase: "short",
                                                    environment: environment(f), state: BackupState(), includeCloud: true).report.errors.first)
    }

    func testStatSignatureChangesWhenAFileIsEditedAddedOrRemovedAndOtherwiseStaysPut() throws {
        let f = try fixture()
        let sources = ConfigReader(rootURL: f.root).scan().sources.map(\.url)
        let before = ConfigStatSignature.make(rootURL: f.root, sources: sources)
        XCTAssertEqual(before, ConfigStatSignature.make(rootURL: f.root, sources: sources), "stable when nothing changes")
        let host = f.root.deletingLastPathComponent().appendingPathComponent("config.d/web.conf")
        Thread.sleep(forTimeInterval: 0.02)
        try Data("Host web\n  HostName changed.example\n".utf8).write(to: host)
        let edited = ConfigStatSignature.make(rootURL: f.root, sources: sources)
        XCTAssertNotEqual(before, edited)
        try Data("Host db\n".utf8).write(to: f.root.deletingLastPathComponent().appendingPathComponent("config.d/db.conf"))
        XCTAssertNotEqual(edited, ConfigStatSignature.make(rootURL: f.root, sources: sources), "a new file changes the directory")
        try FileManager.default.removeItem(at: host)
        XCTAssertTrue(ConfigStatSignature.make(rootURL: f.root, sources: sources).contains { $0.hasSuffix("|missing") })
    }

    func testPlainSnapshotsAreWrittenUnencryptedWithoutAPassphraseAndTheCloudIsSkipped() throws {
        let f = try fixture()
        let plan = BackupPlan(isEnabled: true, snapshotFrequency: .daily, syncToICloud: true, encryptSnapshots: false)
        let result = run(f, plan, passphrase: nil)
        let record = try XCTUnwrap(try EncryptedSnapshotService(folder: f.snapshots).list().records.first)
        XCTAssertFalse(record.header.isEncrypted)
        XCTAssertNil(result.report.pushedFileCount)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.cloudFolder.path), "nothing reaches iCloud without a passphrase")

        let withPassphrase = run(f, plan, state: result.state, passphrase: passphrase, changedAgo: 60)
        XCTAssertEqual(withPassphrase.report.pushedFileCount, 2)
        let cloudBytes = try Data(contentsOf: f.cloudFolder.appendingPathComponent("Devices/\(deviceID.uuidString.lowercased()).cssh"))
        XCTAssertNil(cloudBytes.range(of: Data("web.example".utf8)), "the cloud file is encrypted even when local snapshots are not")
    }

    func testBackupNowWithPlainSnapshotsAndNoPassphraseStillWorks() throws {
        let f = try fixture()
        let now = BackupCoordinator.backupNow(scan: ConfigReader(rootURL: f.root).scan(), passphrase: nil, encryptSnapshots: false,
                                              environment: environment(f), state: BackupState(), includeCloud: false)
        XCTAssertNotNil(now.report.snapshotURL)
        XCTAssertTrue(now.report.errors.isEmpty, "\(now.report.errors)")
        let blocked = BackupCoordinator.backupNow(scan: ConfigReader(rootURL: f.root).scan(), passphrase: nil, encryptSnapshots: true,
                                                  environment: environment(f), state: BackupState(), includeCloud: false)
        XCTAssertNil(blocked.report.snapshotURL)
        XCTAssertFalse(blocked.report.errors.isEmpty)
    }
}
