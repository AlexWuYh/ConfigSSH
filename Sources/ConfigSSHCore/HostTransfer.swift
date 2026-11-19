import Foundation

/// Exporting host configuration to a file and reading one back.
///
/// Two formats: a plain `.zip` (default), and an encrypted `.cssh` protected by a passphrase the
/// user chooses for that export. Both hold only config files that live inside `~/.ssh`
/// (`config`, `config.d/…` and files beside them) and never any key.
package enum HostTransfer {
    package static let manifestName = "configssh-export.json"
    private static let manifestFormat = "ConfigSSH-export"

    private struct Manifest: Codable {
        struct File: Codable { let path: String; let sha256: String }
        let format: String
        let version: Int
        let appVersion: String
        let deviceName: String
        let createdAt: Date
        let files: [File]
    }

    package struct Export: Sendable {
        package let data: Data
        package let fileCount: Int
        /// Files the config reads from outside `~/.ssh`; not exported.
        package let skippedExternal: [String]
    }

    /// What a chosen file turned out to be.
    package enum Kind: Equatable, Sendable {
        case zip
        case encrypted(createdAt: Date)
    }

    package struct Imported: Sendable {
        package let archive: BackupArchive
        package let createdAt: Date?
        /// A zip without the manifest (for example made by hand); its files are not integrity-checked.
        package let hasManifest: Bool
        /// Entries that were left out (macOS metadata and the like).
        package let ignored: [String]
    }

    // MARK: Export

    package static func archive(from scan: ConfigScan, appVersion: String, deviceName: String) throws -> (archive: BackupArchive, skipped: [String]) {
        guard scan.availability == .available, !scan.sources.isEmpty else { throw ConfigEditError.invalid("没有可导出的 SSH 配置") }
        let root = scan.rootURL.deletingLastPathComponent()
        var entries: [BackupArchive.Entry] = []
        var skipped: [String] = []
        var total = 0
        for source in scan.sources {
            let location = BackupArchive.location(of: source.url, sshRoot: root)
            if location.isExternal { skipped.append(location.path); continue }
            guard source.data.count <= ZipArchive.maxEntrySize, total <= ZipArchive.maxTotalSize - source.data.count else {
                throw ConfigEditError.unsafe("配置超过导出大小限制：\(location.path)")
            }
            total += source.data.count
            entries.append(.init(path: location.path, isExternal: false, content: source.data))
        }
        guard entries.contains(where: { $0.path == "config" }) else { throw ConfigEditError.unsafe("缺少主配置文件，不能导出") }
        return (BackupArchive(appVersion: appVersion, deviceName: String(deviceName.prefix(100)), entries: entries), skipped.sorted())
    }

    package static func zipExport(scan: ConfigScan, appVersion: String, deviceName: String, now: Date = Date()) throws -> Export {
        let (archive, skipped) = try archive(from: scan, appVersion: appVersion, deviceName: deviceName)
        let manifest = Manifest(format: manifestFormat, version: 1, appVersion: appVersion, deviceName: archive.deviceName, createdAt: now,
                                files: archive.entries.map { .init(path: $0.path, sha256: $0.sha256) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        var files = archive.entries.map { ZipArchive.Entry(path: $0.path, content: $0.content) }
        files.append(.init(path: manifestName, content: try encoder.encode(manifest)))
        return Export(data: try ZipArchive.write(files, date: now), fileCount: archive.entries.count, skippedExternal: skipped)
    }

    package static func encryptedExport(scan: ConfigScan, passphrase: String, appVersion: String, deviceName: String,
                                        now: Date = Date()) throws -> Export {
        let (archive, skipped) = try archive(from: scan, appVersion: appVersion, deviceName: deviceName)
        let sealed = try BackupCrypto.seal(try JSONEncoder().encode(archive), kind: .export, passphrase: passphrase, createdAt: now)
        return Export(data: sealed, fileCount: archive.entries.count, skippedExternal: skipped)
    }

    // MARK: Import

    package static func inspect(_ data: Data) throws -> Kind {
        if ZipArchive.isZip(data) { return .zip }
        let header = try BackupCrypto.header(of: data)
        guard header.kind == .export else { throw ConfigEditError.invalid("这是本机快照文件，请在“备份 › 浏览与恢复”中使用；这里只能导入导出的主机配置") }
        return .encrypted(createdAt: header.createdAt)
    }

    /// Reads a zip export, checking every file against the manifest when there is one.
    package static func readZip(_ data: Data) throws -> Imported {
        var entries = try ZipArchive.read(data)
        var ignored: [String] = []
        entries.removeAll { entry in
            let hidden = entry.path.hasPrefix("__MACOSX/") || (entry.path as NSString).lastPathComponent == ".DS_Store"
            if hidden { ignored.append(entry.path) }
            return hidden
        }
        var manifest: Manifest?
        if let index = entries.firstIndex(where: { $0.path == manifestName || $0.path.hasSuffix("/" + manifestName) }) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let decoded = try? decoder.decode(Manifest.self, from: entries[index].content), decoded.format == manifestFormat, decoded.version == 1 else {
                throw ConfigEditError.invalid("导出清单无法识别，文件可能不是 ConfigSSH 导出的")
            }
            manifest = decoded
            entries.remove(at: index)
        }
        // A folder zipped in Finder has one top-level directory around everything.
        if !entries.contains(where: { $0.path == "config" }) {
            let tops = Set(entries.compactMap { $0.path.split(separator: "/").first.map(String.init) })
            if tops.count == 1, let top = tops.first, entries.contains(where: { $0.path == top + "/config" }) {
                entries = entries.map { .init(path: String($0.path.dropFirst(top.count + 1)), content: $0.content) }
            }
        }
        guard entries.contains(where: { $0.path == "config" }) else {
            throw ConfigEditError.invalid("这个 zip 里没有主配置文件 config，不像是 SSH 配置的导出")
        }
        if let manifest {
            let listed = Dictionary(uniqueKeysWithValues: manifest.files.map { ($0.path, $0.sha256) })
            guard Set(listed.keys) == Set(entries.map(\.path)) else { throw ConfigEditError.unsafe("导出文件的内容与清单不一致，文件可能被改动过") }
            for entry in entries where SafeFileIO.hash(entry.content) != listed[entry.path] {
                throw ConfigEditError.unsafe("文件校验失败，导出文件可能已被改动：\(entry.path)")
            }
        }
        let archive = BackupArchive(appVersion: manifest?.appVersion ?? "", deviceName: manifest?.deviceName ?? "",
                                    entries: entries.map { .init(path: $0.path, isExternal: false, content: $0.content) })
        return Imported(archive: archive, createdAt: manifest?.createdAt, hasManifest: manifest != nil, ignored: ignored.sorted())
    }

    /// Decrypts an encrypted export. A wrong passphrase or a damaged file throws before anything
    /// can be previewed or written.
    package static func readEncrypted(_ data: Data, passphrase: String) throws -> Imported {
        let opened = try BackupCrypto.open(data, passphrase: passphrase, expectedKind: .export)
        guard let archive = try? JSONDecoder().decode(BackupArchive.self, from: opened.plaintext) else {
            throw ConfigEditError.unsafe("导出内容无法解析，文件可能已损坏")
        }
        return Imported(archive: archive, createdAt: opened.header.createdAt, hasManifest: true, ignored: [])
    }

    /// Imported files a scan does not read. Call it with a scan taken after the import: a file that
    /// is still missing then has no matching `Include` in the main config, so it was written but
    /// does not show up until the user adds one or also imports the main config.
    package static func unreferencedFiles(_ archive: BackupArchive, in scan: ConfigScan) -> [String] {
        let root = scan.rootURL.deletingLastPathComponent()
        let read = Set(scan.sources.map { BackupArchive.location(of: $0.url, sshRoot: root).path })
        return archive.entries.filter { $0.path != "config" && !read.contains($0.path) }.map(\.path).sorted()
    }
}
