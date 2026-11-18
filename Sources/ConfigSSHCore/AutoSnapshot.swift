import Foundation

/// How often ConfigSSH takes an automatic, config-only local snapshot.
package enum AutoSnapshotInterval: String, CaseIterable, Identifiable, Sendable {
    case off
    case daily
    case weekly

    package var id: String { rawValue }
    package var displayName: String {
        switch self {
        case .off: "关闭"
        case .daily: "每天"
        case .weekly: "每周"
        }
    }
    package var seconds: TimeInterval? {
        switch self {
        case .off: nil
        case .daily: 86_400
        case .weekly: 604_800
        }
    }
}

package enum AutoSnapshotOutcome: Equatable, Sendable {
    case disabled
    case notDue(next: Date)
    case unchanged
    case created(URL)
}

/// Scheduled snapshots of `config` and its Include files.
///
/// They never include keys, are skipped when nothing changed since the newest snapshot, and
/// pruning only ever removes older automatic snapshots (`ConfigSSH-auto-*` with
/// `isAutomatic: true`); manual snapshots are never touched.
package struct AutoSnapshotService {
    package static let defaultKeep = 14
    package static let keepRange = 1...200

    private let service = BackupSnapshotService()

    package init() {}

    package func runIfDue(scan: ConfigScan, folder: URL, interval: AutoSnapshotInterval, keep: Int,
                          now: Date = Date()) throws -> AutoSnapshotOutcome {
        guard let seconds = interval.seconds else { return .disabled }
        let records = try service.list(in: folder).records
        let automatic = records.filter(Self.isAutomatic)
        if let last = automatic.first?.manifest.createdAt, now.timeIntervalSince(last) < seconds {
            return .notDue(next: last.addingTimeInterval(seconds))
        }
        if let newest = records.first, Self.configDigest(of: newest.manifest) == Self.configDigest(of: scan) {
            return .unchanged
        }
        let result = try service.create(scan: scan, destination: .local(folder), automatic: true)
        try prune(folder: folder, keep: keep)
        return .created(result.url)
    }

    /// Removes the oldest automatic snapshots beyond `keep`.
    package func prune(folder: URL, keep: Int) throws {
        let keep = min(max(keep, Self.keepRange.lowerBound), Self.keepRange.upperBound)
        let automatic = try service.list(in: folder).records.filter(Self.isAutomatic)
        for record in automatic.dropFirst(keep) {
            try FileManager.default.removeItem(at: record.url)
        }
    }

    package static func isAutomatic(_ record: SnapshotRecord) -> Bool {
        record.manifest.isAutomatic == true && !record.manifest.includesKeys &&
            record.url.lastPathComponent.hasPrefix("ConfigSSH-auto-")
    }

    static func configDigest(of manifest: SnapshotManifest) -> [String] {
        manifest.entries.filter { $0.kind == "ssh-config" }
            .map { "\($0.sourcePath)\u{1F}\($0.sha256 ?? "")" }.sorted()
    }

    static func configDigest(of scan: ConfigScan) -> [String] {
        scan.sources.map { "\($0.url.path)\u{1F}\($0.sha256)" }.sorted()
    }
}
