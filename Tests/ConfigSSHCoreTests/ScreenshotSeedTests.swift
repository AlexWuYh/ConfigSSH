import Foundation
import XCTest
@testable import ConfigSSHCore

/// Writes backup history into a fixture folder for README screenshots. Does nothing unless the
/// CONFIGSSH_SEED_ROOT environment variable names a `/tmp` fixture, so normal test runs skip it.
final class ScreenshotSeedTests: XCTestCase {
    func testSeedBackupHistory() throws {
        guard let raw = ProcessInfo.processInfo.environment["CONFIGSSH_SEED_ROOT"], raw.hasPrefix("/tmp/") else {
            throw XCTSkip("not seeding")
        }
        let root = URL(fileURLWithPath: "/private" + raw)
        let ssh = root.appendingPathComponent(".ssh")
        let config = ssh.appendingPathComponent("config")
        let passphrase = "correct horse battery"
        let scan = ConfigReader(rootURL: config).scan()
        let snapshots = EncryptedSnapshotService(folder: root.appendingPathComponent("Snapshots"))
        let now = Date()
        for (hours, automatic) in [(2, true), (26, true), (50, false), (98, true)] {
            try snapshots.create(scan: scan, passphrase: passphrase, automatic: automatic, deviceName: "MacBook Pro",
                                 appVersion: "0.3.0", now: now.addingTimeInterval(-Double(hours) * 3600))
        }
        // An unencrypted one, so the browser shows the separate group.
        try snapshots.create(scan: scan, passphrase: nil, automatic: false, deviceName: "MacBook Pro",
                             appVersion: "0.3.0", now: now.addingTimeInterval(-170 * 3600))

        // The cloud service compares normalised paths, so it gets the plain /tmp spelling.
        let cloudRoot = URL(fileURLWithPath: raw).appendingPathComponent("iCloudDrive")
        let service = CloudConfigSyncService(folder: cloudRoot.appendingPathComponent("ConfigSSH"), cloudRoot: cloudRoot)
        for (id, name) in [("00000000-0000-4000-8000-000000000001", "MacBook Pro"), ("00000000-0000-4000-8000-0000000000B2", "Mac mini")] {
            let plan = try service.planPush(scan: scan, deviceID: UUID(uuidString: id)!, deviceName: name, passphrase: passphrase)
            try service.push(plan)
        }
    }
}
