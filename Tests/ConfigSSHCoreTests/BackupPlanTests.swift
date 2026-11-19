import XCTest
@testable import ConfigSSHCore

final class BackupPlanTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func inputs(passphrase: Bool = true, icloud: Bool = true, digest: [String] = ["a"],
                        snapshotDigest: [String]? = nil, snapshotAgo: TimeInterval? = nil,
                        cloudDigest: [String]? = nil, changedAgo: TimeInterval? = nil) -> BackupPlan.Inputs {
        BackupPlan.Inputs(hasPassphrase: passphrase, iCloudAvailable: icloud, configDigest: digest,
                          lastSnapshotDigest: snapshotDigest, lastSnapshotAt: snapshotAgo.map { now.addingTimeInterval(-$0) },
                          lastCloudDigest: cloudDigest, lastChangeAt: changedAgo.map { now.addingTimeInterval(-$0) }, now: now)
    }

    private func plan(enabled: Bool = true, _ frequency: SnapshotFrequency = .daily, cloud: Bool = true) -> BackupPlan {
        BackupPlan(isEnabled: enabled, snapshotFrequency: frequency, syncToICloud: cloud)
    }

    func testOffByDefaultAndWhenSwitchedOff() {
        XCTAssertFalse(BackupPlan.default.isEnabled)
        XCTAssertEqual(plan(enabled: false).decide(inputs()).actions, [])
    }

    func testNothingRunsWithoutABackupPassphrase() {
        let decision = plan().decide(inputs(passphrase: false))
        XCTAssertEqual(decision.actions, [])
        XCTAssertTrue(decision.notes.first?.contains("备份口令") == true)
    }

    func testFirstRunTakesASnapshotAndUploads() {
        XCTAssertEqual(plan().decide(inputs()).actions, [.takeSnapshot, .pushToICloud])
    }

    func testSnapshotsAreAtMostOncePerFrequencyAndOnlyWhenTheConfigChanged() {
        XCTAssertEqual(plan(.daily, cloud: false).decide(inputs(snapshotDigest: ["old"], snapshotAgo: 3600)).actions, [],
                       "changed, but a snapshot was taken an hour ago")
        XCTAssertEqual(plan(.daily, cloud: false).decide(inputs(snapshotDigest: ["old"], snapshotAgo: 86_400 + 1)).actions, [.takeSnapshot])
        XCTAssertEqual(plan(.daily, cloud: false).decide(inputs(snapshotDigest: ["a"], snapshotAgo: 5 * 86_400)).actions, [],
                       "due, but nothing changed")
        XCTAssertEqual(plan(.weekly, cloud: false).decide(inputs(snapshotDigest: ["old"], snapshotAgo: 3 * 86_400)).actions, [])
        XCTAssertEqual(plan(.weekly, cloud: false).decide(inputs(snapshotDigest: ["old"], snapshotAgo: 8 * 86_400)).actions, [.takeSnapshot])
        XCTAssertEqual(plan(.off, cloud: false).decide(inputs()).actions, [], "snapshots can be switched off on their own")
    }

    func testCloudFollowsEveryChangeAfterTheDebounce() {
        let uploaded = plan(.off).decide(inputs(cloudDigest: ["old"], changedAgo: 30))
        XCTAssertEqual(uploaded.actions, [.pushToICloud], "changed 30 s ago, past the debounce")
        let waiting = plan(.off).decide(inputs(cloudDigest: ["old"], changedAgo: 1))
        XCTAssertEqual(waiting.actions, [])
        XCTAssertEqual(waiting.recheckAt, now.addingTimeInterval(BackupPlan.cloudDebounce - 1), "look again when the debounce ends")
        XCTAssertEqual(plan(.off).decide(inputs(cloudDigest: ["a"], changedAgo: 30)).actions, [], "already in sync")
    }

    func testCloudIsIndependentOfTheSnapshotFrequency() {
        XCTAssertEqual(plan(.weekly).decide(inputs(snapshotDigest: ["a"], snapshotAgo: 3600, cloudDigest: ["old"], changedAgo: 60)).actions,
                       [.pushToICloud])
    }

    func testMissingICloudPausesOnlyTheCloudPart() {
        let decision = plan().decide(inputs(icloud: false))
        XCTAssertEqual(decision.actions, [.takeSnapshot])
        XCTAssertTrue(decision.notes.contains { $0.contains("iCloud") })
    }

    func testPlainLocalSnapshotsNeedNoPassphraseButICloudStillDoes() {
        let plain = BackupPlan(isEnabled: true, snapshotFrequency: .daily, syncToICloud: false, encryptSnapshots: false)
        XCTAssertEqual(plain.decide(inputs(passphrase: false)).actions, [.takeSnapshot], "plain snapshots run without a passphrase")
        let both = BackupPlan(isEnabled: true, snapshotFrequency: .daily, syncToICloud: true, encryptSnapshots: false)
        let decision = both.decide(inputs(passphrase: false, cloudDigest: ["old"], changedAgo: 60))
        XCTAssertEqual(decision.actions, [.takeSnapshot], "the cloud copy is always encrypted, so it waits for a passphrase")
        XCTAssertTrue(decision.notes.contains { $0.contains("iCloud") && $0.contains("口令") })
        XCTAssertEqual(both.decide(inputs(passphrase: true, cloudDigest: ["old"], changedAgo: 60)).actions, [.takeSnapshot, .pushToICloud])
        XCTAssertEqual(plan().decide(inputs(passphrase: false)).actions, [], "encrypted snapshots still need one")
    }

    func testEncryptionIsOnByDefault() {
        XCTAssertTrue(BackupPlan.default.encryptSnapshots)
        XCTAssertTrue(BackupPlan(isEnabled: true, snapshotFrequency: .daily, syncToICloud: false).encryptSnapshots)
    }
}
