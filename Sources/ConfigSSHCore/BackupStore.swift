import Darwin
import Foundation

package struct BackupStore: Sendable {
    package let directoryURL: URL

    package init(rootURL: URL, directoryURL: URL? = nil) {
        let home = rootURL.deletingLastPathComponent().deletingLastPathComponent()
        self.directoryURL = directoryURL ?? home
            .appendingPathComponent("Library/Application Support/ConfigSSH/Backups")
    }

    package func create(for change: PlannedFileChange, reason: String) throws -> BackupRecord {
        try SafeFileIO.ensureDirectory(directoryURL)
        let id = UUID()
        let backupURL = change.before == nil ? nil : directoryURL.appendingPathComponent("\(id.uuidString).bak")
        let originalDate = change.expectedVersion.modificationSeconds.map {
            Date(timeIntervalSince1970: Double($0) + Double(change.expectedVersion.modificationNanoseconds ?? 0) / 1_000_000_000)
        }
        if let backupURL, let before = change.before {
            try privateWrite(before, to: backupURL)
            if let originalDate {
                try FileManager.default.setAttributes([.modificationDate: originalDate], ofItemAtPath: backupURL.path)
            }
        }
        let record = BackupRecord(
            id: id,
            sourcePath: change.url.path,
            backupPath: backupURL?.path,
            beforeHash: change.expectedVersion.sha256,
            afterHash: change.after.map(SafeFileIO.hash),
            originalMode: change.expectedVersion.mode,
            originalModificationDate: originalDate,
            createdAt: Date(),
            reason: reason
        )
        do {
            try privateWrite(JSONEncoder().encode(record), to: manifestURL(for: id))
        } catch {
            if let backupURL { try? FileManager.default.removeItem(at: backupURL) }
            throw error
        }
        return record
    }

    package func list() throws -> [BackupRecord] {
        guard FileManager.default.fileExists(atPath: directoryURL.path) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)
        return files.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(BackupRecord.self, from: data)
        }.sorted { $0.createdAt > $1.createdAt }
    }

    package func previousData(for record: BackupRecord) throws -> Data? {
        guard let path = record.backupPath else { return nil }
        let url = URL(fileURLWithPath: path)
        guard url.deletingLastPathComponent().standardizedFileURL == directoryURL.standardizedFileURL else {
            throw ConfigEditError.unsafe("备份文件不在 ConfigSSH 备份目录中")
        }
        let data = try Data(contentsOf: url)
        guard SafeFileIO.hash(data) == record.beforeHash else {
            throw ConfigEditError.conflict("备份校验失败：\(path)")
        }
        return data
    }

    package func remove(_ record: BackupRecord) {
        try? FileManager.default.removeItem(at: manifestURL(for: record.id))
        // Manifests are plain files in a user-writable folder; only ever delete the backup
        // name `create` would have produced for this record, never a path read from JSON.
        let expected = directoryURL.appendingPathComponent("\(record.id.uuidString).bak").standardizedFileURL
        if let path = record.backupPath, URL(fileURLWithPath: path).standardizedFileURL == expected {
            _ = expected.path.withCString { unlink($0) }
        }
    }

    package func prune(keeping limit: Int) throws {
        guard limit > 0 else { return }
        for record in try list().dropFirst(limit) {
            remove(record)
        }
    }

    private func manifestURL(for id: UUID) -> URL {
        directoryURL.appendingPathComponent("\(id.uuidString).json")
    }

    private func privateWrite(_ data: Data, to url: URL) throws {
        let descriptor = url.path.withCString { Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600) }
        guard descriptor >= 0 else {
            throw ConfigEditError.io("无法创建备份文件：\(url.path)，系统错误 \(errno)")
        }
        var closed = false
        var complete = false
        defer {
            if !closed { _ = Darwin.close(descriptor) }
            if !complete { _ = url.path.withCString { unlink($0) } }
        }
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var written = 0
            while written < bytes.count {
                let count = Darwin.write(descriptor, base.advanced(by: written), bytes.count - written)
                guard count > 0 else {
                    throw ConfigEditError.io("备份写入失败：系统错误 \(errno)")
                }
                written += count
            }
        }
        guard fsync(descriptor) == 0 else {
            throw ConfigEditError.io("备份同步失败：系统错误 \(errno)")
        }
        guard Darwin.close(descriptor) == 0 else {
            closed = true
            throw ConfigEditError.io("备份关闭失败：系统错误 \(errno)")
        }
        closed = true
        complete = true
    }
}
