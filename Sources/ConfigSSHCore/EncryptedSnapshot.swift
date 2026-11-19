import Darwin
import Foundation

/// The decrypted content of a snapshot or an export: every config file the scan read.
package struct BackupArchive: Codable, Sendable {
    package struct Entry: Codable, Sendable {
        /// Relative to `~/.ssh`; absolute when `isExternal`.
        package let path: String
        /// Outside `~/.ssh` or reached through a symlink: kept for reference, never restored.
        package let isExternal: Bool
        package let content: Data

        package init(path: String, isExternal: Bool, content: Data) {
            self.path = path
            self.isExternal = isExternal
            self.content = content
        }

        package var sha256: String { SafeFileIO.hash(content) }
    }

    package let appVersion: String
    package let deviceName: String
    package let entries: [Entry]

    package init(appVersion: String, deviceName: String, entries: [Entry]) {
        self.appVersion = appVersion
        self.deviceName = deviceName
        self.entries = entries
    }

    /// Sorted "path␟hash" lines: equal digests mean the same config.
    package var digest: [String] {
        entries.map { "\($0.path)\u{1F}\($0.sha256)" }.sorted()
    }

    /// Where a scanned source goes in an archive.
    package static func location(of url: URL, sshRoot: URL) -> (path: String, isExternal: Bool) {
        let path = url.standardizedFileURL.path
        let root = sshRoot.standardizedFileURL.path
        if path.hasPrefix(root + "/"), url.standardizedFileURL.resolvingSymlinksInPath().path == path {
            return (String(path.dropFirst(root.count + 1)), false)
        }
        return (path, true)
    }

    /// Digest of what a scan read. `includeExternal: false` keeps only files inside `~/.ssh`.
    package static func digest(of scan: ConfigScan, includeExternal: Bool = true) -> [String] {
        let root = scan.rootURL.deletingLastPathComponent()
        return scan.sources.compactMap { source in
            let location = location(of: source.url, sshRoot: root)
            if location.isExternal && !includeExternal { return nil }
            return "\(location.path)\u{1F}\(source.sha256)"
        }.sorted()
    }
}

package struct EncryptedSnapshotRecord: Identifiable, Sendable {
    package let url: URL
    package let header: BackupHeader
    package let byteCount: Int
    package var id: String { url.path }
}

/// Local snapshots as single AES-GCM `.cssh` files. Unlike the older plaintext snapshot folders
/// these never contain keys: key bytes are never read into memory.
package struct EncryptedSnapshotService: Sendable {
    package static let fileExtension = "cssh"
    package let folder: URL

    package init(folder: URL) { self.folder = folder }

    @discardableResult
    package func create(scan: ConfigScan, passphrase: String?, automatic: Bool = false,
                        deviceName: String = ProcessInfo.processInfo.hostName,
                        appVersion: String = "", now: Date = Date()) throws -> URL {
        guard scan.availability == .available, !scan.sources.isEmpty else {
            throw ConfigEditError.invalid("没有可备份的 SSH 配置文件")
        }
        let target = try BackupSnapshotService().validate(.local(folder))
        let root = scan.rootURL.deletingLastPathComponent()
        var entries: [BackupArchive.Entry] = []
        var total = 0
        for source in scan.sources {
            let current = try SafeFileIO.snapshot(at: source.url)
            guard current.version.sha256 == source.sha256, let data = current.data else {
                throw ConfigEditError.conflict("配置文件在备份前已变化，请重新载入：\(source.url.path)")
            }
            guard data.count <= 16 * 1_024 * 1_024, total <= 64 * 1_024 * 1_024 - data.count else {
                throw ConfigEditError.unsafe("配置快照超过大小限制，请手动备份：\(source.url.path)")
            }
            total += data.count
            let location = BackupArchive.location(of: source.url, sshRoot: root)
            entries.append(.init(path: location.path, isExternal: location.isExternal, content: data))
        }
        let archive = BackupArchive(appVersion: appVersion, deviceName: String(deviceName.prefix(100)), entries: entries)
        let encoded = try JSONEncoder().encode(archive)
        // No passphrase means the user chose unencrypted local snapshots.
        let sealed = try passphrase.map { try BackupCrypto.seal(encoded, kind: .snapshot, passphrase: $0, createdAt: now, isAutomatic: automatic) }
            ?? BackupCrypto.sealPlain(encoded, createdAt: now, isAutomatic: automatic)
        try SafeFileIO.ensureDirectory(target)
        let stamp = Int(now.timeIntervalSince1970)
        let name = "ConfigSSH-\(automatic ? "auto-" : "")\(stamp)-\(UUID().uuidString.prefix(8).lowercased()).\(Self.fileExtension)"
        let url = target.appendingPathComponent(name)
        try Self.publish(sealed, at: url)
        return url
    }

    package func list() throws -> (records: [EncryptedSnapshotRecord], issues: [String]) {
        guard FileManager.default.fileExists(atPath: folder.path) else { return ([], []) }
        let info = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard info.isDirectory == true, info.isSymbolicLink != true else {
            throw ConfigEditError.unsafe("快照目录不是普通目录：\(folder.path)")
        }
        var records: [EncryptedSnapshotRecord] = []
        var issues: [String] = []
        for child in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        where child.lastPathComponent.hasPrefix("ConfigSSH-") && child.pathExtension == Self.fileExtension {
            do {
                let current = try SafeFileIO.snapshot(at: child)
                guard let data = current.data, data.count <= BackupCrypto.maximumFileSize else {
                    throw ConfigEditError.unsafe("文件不可读取或超过大小限制")
                }
                let header = try BackupCrypto.header(of: data)
                guard header.kind == .snapshot else { throw ConfigEditError.invalid("不是快照文件") }
                records.append(EncryptedSnapshotRecord(url: child, header: header, byteCount: data.count))
            } catch {
                issues.append("\(child.lastPathComponent)：\(error.localizedDescription)")
            }
        }
        return (records.sorted { $0.header.createdAt > $1.header.createdAt }, issues)
    }

    package func open(_ record: EncryptedSnapshotRecord, passphrase: String?) throws -> BackupArchive {
        let current = try SafeFileIO.snapshot(at: record.url)
        guard let data = current.data else { throw ConfigEditError.io("快照文件不存在或已被移除") }
        let opened: (header: BackupHeader, plaintext: Data)
        if record.header.isEncrypted {
            guard let passphrase else { throw ConfigEditError.invalid("这份快照已加密，需要备份口令才能打开") }
            opened = try BackupCrypto.open(data, passphrase: passphrase, expectedKind: .snapshot)
        } else {
            opened = try BackupCrypto.openPlain(data)
        }
        guard let archive = try? JSONDecoder().decode(BackupArchive.self, from: opened.plaintext) else {
            throw ConfigEditError.unsafe("快照内容无法解析，文件可能已损坏")
        }
        return archive
    }

    /// Writes `data` to a new file with mode 0600 and publishes it without replacing anything.
    static func publish(_ data: Data, at url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).tmp")
        let descriptor = temporary.path.withCString { Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600) }
        guard descriptor >= 0 else { throw ConfigEditError.io("无法创建备份文件：\(url.path)，系统错误 \(errno)") }
        var complete = false
        defer {
            _ = Darwin.close(descriptor)
            if !complete { _ = temporary.path.withCString { unlink($0) } }
        }
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                guard count > 0 else { throw ConfigEditError.io("写入备份文件失败：系统错误 \(errno)") }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else { throw ConfigEditError.io("同步备份文件失败") }
        let renamed = temporary.path.withCString { from in
            url.path.withCString { to in renamex_np(from, to, UInt32(RENAME_EXCL)) }
        }
        guard renamed == 0 else {
            throw errno == EEXIST ? ConfigEditError.conflict("备份文件已存在，不会覆盖：\(url.path)")
                                  : ConfigEditError.io("无法发布备份文件：系统错误 \(errno)")
        }
        complete = true
    }
}

/// Plaintext snapshot folders from earlier versions and encrypted `.cssh` snapshots in one list.
package struct SnapshotItem: Identifiable, Sendable {
    package enum Storage: Sendable {
        case legacy(SnapshotRecord)
        case encrypted(EncryptedSnapshotRecord)
    }

    package let storage: Storage

    package var id: String {
        switch storage {
        case .legacy(let record): record.id
        case .encrypted(let record): record.id
        }
    }
    package var url: URL {
        switch storage {
        case .legacy(let record): record.url
        case .encrypted(let record): record.url
        }
    }
    package var createdAt: Date {
        switch storage {
        case .legacy(let record): record.manifest.createdAt
        case .encrypted(let record): record.header.createdAt
        }
    }
    package var isAutomatic: Bool {
        switch storage {
        case .legacy(let record): AutoSnapshotService.isAutomatic(record)
        case .encrypted(let record): record.header.isAutomatic
        }
    }
    /// True only when the content is actually encrypted: not for old plaintext folders, and not
    /// for a `.cssh` snapshot the user chose to keep unencrypted.
    package var isEncrypted: Bool {
        if case .encrypted(let record) = storage { return record.header.isEncrypted }
        return false
    }
}

package enum SnapshotCatalog {
    package static func list(folder: URL) throws -> (items: [SnapshotItem], issues: [String]) {
        let legacy = try BackupSnapshotService().list(in: folder)
        let encrypted = try EncryptedSnapshotService(folder: folder).list()
        let items = legacy.records.map { SnapshotItem(storage: .legacy($0)) } +
            encrypted.records.map { SnapshotItem(storage: .encrypted($0)) }
        return (items.sorted { $0.createdAt > $1.createdAt }, legacy.issues + encrypted.issues)
    }
}
