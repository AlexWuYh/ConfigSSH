import Foundation

/// Retention for automatic snapshots. Pruning only ever removes older automatic snapshots;
/// manual snapshots are never touched.
package struct AutoSnapshotService {
    package static let defaultKeep = 14
    package static let keepRange = 1...200

    package init() {}

    /// Removes the oldest automatic snapshots beyond `keep`.
    package func prune(folder: URL, keep: Int) throws {
        let keep = min(max(keep, Self.keepRange.lowerBound), Self.keepRange.upperBound)
        for item in try SnapshotCatalog.list(folder: folder).items.filter(\.isAutomatic).dropFirst(keep) {
            try FileManager.default.removeItem(at: item.url)
        }
    }

    package static func isAutomatic(_ record: SnapshotRecord) -> Bool {
        record.manifest.isAutomatic == true && !record.manifest.includesKeys &&
            record.url.lastPathComponent.hasPrefix("ConfigSSH-auto-")
    }
}
