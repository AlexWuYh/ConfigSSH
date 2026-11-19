import Foundation

/// How often a local snapshot is taken at the most. The finest grain is once a day.
package enum SnapshotFrequency: String, CaseIterable, Identifiable, Sendable {
    case off, daily, weekly

    package var id: String { rawValue }
    package var displayName: String {
        switch self {
        case .off: "关闭"
        case .daily: "每天"
        case .weekly: "每周"
        }
    }
    package var interval: TimeInterval? {
        switch self {
        case .off: nil
        case .daily: 86_400
        case .weekly: 604_800
        }
    }
}

/// Everything the automatic-backup switch decides, in one place and free of I/O.
///
/// One global switch covers every backup destination. Local snapshots are taken at most once per
/// `SnapshotFrequency` and only when the config changed. The iCloud copy follows every change:
/// the scheduler calls this after each change it sees, and a push happens whenever the config
/// differs from what was last uploaded, with a short debounce so a burst of edits is one upload.
package struct BackupPlan: Equatable, Sendable {
    package var isEnabled: Bool
    package var snapshotFrequency: SnapshotFrequency
    package var syncToICloud: Bool
    /// Local snapshots only. The iCloud copy is always encrypted, so it still needs a passphrase.
    package var encryptSnapshots: Bool

    package init(isEnabled: Bool, snapshotFrequency: SnapshotFrequency, syncToICloud: Bool, encryptSnapshots: Bool = true) {
        self.isEnabled = isEnabled
        self.snapshotFrequency = snapshotFrequency
        self.syncToICloud = syncToICloud
        self.encryptSnapshots = encryptSnapshots
    }

    package static let `default` = BackupPlan(isEnabled: false, snapshotFrequency: .daily, syncToICloud: false)

    /// Wait this long after the last change before uploading, so saving several hosts in a row
    /// is one upload instead of one per save.
    package static let cloudDebounce: TimeInterval = 5

    package struct Inputs: Sendable {
        package var hasPassphrase: Bool
        package var iCloudAvailable: Bool
        /// Every config file the scan read; what a snapshot records.
        package var configDigest: [String]
        /// Only the files an iCloud push uploads (inside `~/.ssh`), so a change to an external
        /// Include file alone does not cause a pointless upload.
        package var cloudDigest: [String]
        package var lastSnapshotDigest: [String]?
        package var lastSnapshotAt: Date?
        package var lastCloudDigest: [String]?
        package var lastChangeAt: Date?
        package var now: Date

        package init(hasPassphrase: Bool, iCloudAvailable: Bool, configDigest: [String], cloudDigest: [String]? = nil,
                     lastSnapshotDigest: [String]?, lastSnapshotAt: Date?, lastCloudDigest: [String]?,
                     lastChangeAt: Date?, now: Date) {
            self.hasPassphrase = hasPassphrase
            self.iCloudAvailable = iCloudAvailable
            self.configDigest = configDigest
            self.cloudDigest = cloudDigest ?? configDigest
            self.lastSnapshotDigest = lastSnapshotDigest
            self.lastSnapshotAt = lastSnapshotAt
            self.lastCloudDigest = lastCloudDigest
            self.lastChangeAt = lastChangeAt
            self.now = now
        }
    }

    package enum Action: Equatable, Sendable {
        case takeSnapshot
        case pushToICloud
    }

    package struct Decision: Equatable, Sendable {
        package var actions: [Action]
        /// Why something was not done, for the status line.
        package var notes: [String]
        /// When to look again for a pending debounced upload.
        package var recheckAt: Date?
    }

    package func decide(_ input: Inputs) -> Decision {
        guard isEnabled else { return Decision(actions: [], notes: [], recheckAt: nil) }
        var actions: [Action] = []
        var notes: [String] = []
        var recheck: Date?
        let snapshotsNeedPassphrase = encryptSnapshots
        if !input.hasPassphrase && (snapshotsNeedPassphrase || syncToICloud) {
            notes.append(syncToICloud ? "iCloud 同步需要备份口令，已暂停" : "还没有设置备份口令，自动备份暂停")
        }

        if let interval = snapshotFrequency.interval, input.hasPassphrase || !snapshotsNeedPassphrase {
            let changed = input.lastSnapshotDigest != input.configDigest
            if let last = input.lastSnapshotAt, input.now.timeIntervalSince(last) < interval {
                // Not due yet; the next hourly check handles it.
            } else if changed {
                actions.append(.takeSnapshot)
            }
        }

        if syncToICloud, input.hasPassphrase {
            if !input.iCloudAvailable {
                notes.append("未检测到 iCloud Drive，云端同步暂停")
            } else if input.lastCloudDigest != input.cloudDigest {
                let ready = input.lastChangeAt.map { $0.addingTimeInterval(Self.cloudDebounce) } ?? input.now
                if input.now >= ready {
                    actions.append(.pushToICloud)
                } else {
                    recheck = ready
                }
            }
        }
        return Decision(actions: actions, notes: notes, recheckAt: recheck)
    }
}
