import Foundation

/// What the coordinator remembers between runs. The app stores it; tests keep it in memory.
package struct BackupState: Codable, Equatable, Sendable {
    package var lastSnapshotDigest: [String]?
    package var lastSnapshotAt: Date?
    package var lastCloudDigest: [String]?
    package var lastCloudAt: Date?

    package init(lastSnapshotDigest: [String]? = nil, lastSnapshotAt: Date? = nil,
                 lastCloudDigest: [String]? = nil, lastCloudAt: Date? = nil) {
        self.lastSnapshotDigest = lastSnapshotDigest
        self.lastSnapshotAt = lastSnapshotAt
        self.lastCloudDigest = lastCloudDigest
        self.lastCloudAt = lastCloudAt
    }
}

package struct BackupCloudTarget: Sendable {
    package let service: CloudConfigSyncService
    package let deviceID: UUID
    package let deviceName: String
    /// The user agreed that files outside `~/.ssh` are not uploaded, so the cloud copy may be
    /// incomplete. Without it an automatic push that would skip files does not run.
    package let acceptsIncompleteMirror: Bool

    package init(service: CloudConfigSyncService, deviceID: UUID, deviceName: String, acceptsIncompleteMirror: Bool) {
        self.service = service
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.acceptsIncompleteMirror = acceptsIncompleteMirror
    }
}

package struct BackupEnvironment: Sendable {
    package let snapshotFolder: URL
    package let keepAutomatic: Int
    package let appVersion: String
    package let deviceName: String
    package let cloud: BackupCloudTarget?
    package let iCloudAvailable: Bool

    package init(snapshotFolder: URL, keepAutomatic: Int, appVersion: String, deviceName: String,
                 cloud: BackupCloudTarget?, iCloudAvailable: Bool) {
        self.snapshotFolder = snapshotFolder
        self.keepAutomatic = keepAutomatic
        self.appVersion = appVersion
        self.deviceName = deviceName
        self.cloud = cloud
        self.iCloudAvailable = iCloudAvailable
    }
}

package struct BackupReport: Equatable, Sendable {
    package var snapshotURL: URL?
    package var pushedFileCount: Int?
    package var notes: [String] = []
    package var errors: [String] = []
    package var recheckAt: Date?

    package var didSomething: Bool { snapshotURL != nil || pushedFileCount != nil }
}

/// Runs one pass of automatic backup: asks `BackupPlan` what is due, then takes an encrypted
/// local snapshot and/or pushes this device's encrypted file to iCloud. One failing step never
/// stops the other, and state only advances for steps that succeeded.
package enum BackupCoordinator {
    package static func run(plan: BackupPlan, scan: ConfigScan, passphrase: String?, environment: BackupEnvironment,
                            state: BackupState, lastChangeAt: Date?, now: Date = Date()) -> (state: BackupState, report: BackupReport) {
        var state = state
        var report = BackupReport()
        guard scan.availability == .available, !scan.sources.isEmpty else {
            return (state, report)
        }
        let digest = BackupArchive.digest(of: scan)
        let cloudDigest = BackupArchive.digest(of: scan, includeExternal: false)
        let inputs = BackupPlan.Inputs(
            hasPassphrase: passphrase.map { BackupCrypto.passphraseProblem($0) == nil } ?? false,
            iCloudAvailable: environment.iCloudAvailable, configDigest: digest, cloudDigest: cloudDigest,
            lastSnapshotDigest: state.lastSnapshotDigest, lastSnapshotAt: state.lastSnapshotAt,
            lastCloudDigest: state.lastCloudDigest, lastChangeAt: lastChangeAt, now: now)
        let decision = plan.decide(inputs)
        report.notes = decision.notes
        report.recheckAt = decision.recheckAt
        guard let passphrase else { return (state, report) }

        for action in decision.actions {
            switch action {
            case .takeSnapshot:
                do {
                    let url = try EncryptedSnapshotService(folder: environment.snapshotFolder)
                        .create(scan: scan, passphrase: passphrase, automatic: true,
                                deviceName: environment.deviceName, appVersion: environment.appVersion, now: now)
                    try AutoSnapshotService().prune(folder: environment.snapshotFolder, keep: environment.keepAutomatic)
                    state.lastSnapshotDigest = digest
                    state.lastSnapshotAt = now
                    report.snapshotURL = url
                } catch {
                    report.errors.append("本机快照失败：\(error.localizedDescription)")
                }
            case .pushToICloud:
                guard let cloud = environment.cloud else {
                    report.notes.append("未选择 iCloud 位置，云端同步暂停")
                    continue
                }
                do {
                    let push = try cloud.service.planPush(scan: scan, deviceID: cloud.deviceID,
                                                          deviceName: cloud.deviceName, passphrase: passphrase)
                    if !push.skippedSources.isEmpty && !cloud.acceptsIncompleteMirror {
                        report.notes.append("有 \(push.skippedSources.count) 个 ~/.ssh 之外的 Include 文件不会上传；请在备份设置中确认云端副本可以不完整，才会自动同步")
                        continue
                    }
                    try cloud.service.push(push)
                    state.lastCloudDigest = cloudDigest
                    state.lastCloudAt = now
                    report.pushedFileCount = push.fileCount
                } catch let error as CloudPushError {
                    // A slot this passphrase cannot open is only ever replaced after an explicit confirmation.
                    report.errors.append(error.localizedDescription)
                } catch {
                    report.errors.append("iCloud 同步失败：\(error.localizedDescription)")
                }
            }
        }
        return (state, report)
    }

    /// The "立即备份" button: a manual encrypted snapshot now, plus an iCloud push when sync is
    /// switched on. Unlike `run` it does not wait for a change or for the daily limit.
    package static func backupNow(scan: ConfigScan, passphrase: String, environment: BackupEnvironment,
                                  state: BackupState, includeCloud: Bool, now: Date = Date()) -> (state: BackupState, report: BackupReport) {
        var state = state
        var report = BackupReport()
        guard scan.availability == .available, !scan.sources.isEmpty else {
            report.errors.append("没有可备份的 SSH 配置文件")
            return (state, report)
        }
        if let problem = BackupCrypto.passphraseProblem(passphrase) {
            report.errors.append(problem)
            return (state, report)
        }
        let digest = BackupArchive.digest(of: scan)
        do {
            report.snapshotURL = try EncryptedSnapshotService(folder: environment.snapshotFolder)
                .create(scan: scan, passphrase: passphrase, automatic: false,
                        deviceName: environment.deviceName, appVersion: environment.appVersion, now: now)
            state.lastSnapshotDigest = digest
            state.lastSnapshotAt = now
        } catch {
            report.errors.append("本机快照失败：\(error.localizedDescription)")
        }
        if includeCloud, let cloud = environment.cloud, environment.iCloudAvailable {
            do {
                let push = try cloud.service.planPush(scan: scan, deviceID: cloud.deviceID, deviceName: cloud.deviceName, passphrase: passphrase)
                if !push.skippedSources.isEmpty && !cloud.acceptsIncompleteMirror {
                    report.notes.append("有 \(push.skippedSources.count) 个 ~/.ssh 之外的 Include 文件不会上传；请先在备份设置中确认云端副本可以不完整")
                } else {
                    try cloud.service.push(push)
                    state.lastCloudDigest = BackupArchive.digest(of: scan, includeExternal: false)
                    state.lastCloudAt = now
                    report.pushedFileCount = push.fileCount
                }
            } catch {
                report.errors.append("iCloud 同步失败：\(error.localizedDescription)")
            }
        }
        return (state, report)
    }
}
