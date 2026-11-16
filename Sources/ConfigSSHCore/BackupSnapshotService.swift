import Darwin
import Foundation

package enum SnapshotDestination: Sendable {
    case local(URL)
    case iCloudDrive(folder: URL, cloudRoot: URL)

    package var folderURL: URL {
        switch self {
        case .local(let folder), .iCloudDrive(let folder, _): folder.standardizedFileURL
        }
    }
}

package struct SnapshotManifest: Codable, Sendable {
    package struct Entry: Codable, Sendable {
        package let sourcePath: String
        package let backupFile: String
        package let kind: String
        package let byteCount: Int
        package let sha256: String?
    }

    package let createdAt: Date
    package let includesKeys: Bool
    package let entries: [Entry]
}

package struct SnapshotResult: Sendable {
    package let url: URL
    package let fileCount: Int
    package let keyCount: Int
}

package struct SnapshotRecord: Identifiable, Sendable {
    package let url: URL
    package let manifest: SnapshotManifest
    package let manifestHash: String
    package let isCloud: Bool

    package var id: String { url.path }
}

package struct SnapshotIndexResult: Sendable {
    package let records: [SnapshotRecord]
    package let issues: [String]
}

package struct BackupSnapshotService {
    package init() { }

    package func create(scan: ConfigScan, destination: SnapshotDestination,
                        includeKeys: Bool = false,
                        selectedKeyIDs: Set<String>? = nil,
                        afterKeyCopy: ((URL) throws -> Void)? = nil) throws -> SnapshotResult {
        guard scan.availability == .available, !scan.sources.isEmpty else {
            throw ConfigEditError.invalid("没有可备份的 SSH 配置文件")
        }
        if case .iCloudDrive = destination {
            throw ConfigEditError.unsafe("明文 iCloud 快照已停用；请使用加密的 iCloud 配置同步")
        }
        let folder = try validate(destination)
        try SafeFileIO.ensureDirectory(folder)

        let stamp = Int(Date().timeIntervalSince1970)
        let name = "ConfigSSH-\(stamp)-\(UUID().uuidString.prefix(8).lowercased())"
        let staging = folder.appendingPathComponent(".\(name).tmp")
        let final = folder.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        var complete = false
        defer { if !complete { try? FileManager.default.removeItem(at: staging) } }

        var entries: [SnapshotManifest.Entry] = []
        var totalConfigBytes = 0
        for (index, source) in scan.sources.enumerated() {
            let current = try SafeFileIO.snapshot(at: source.url)
            guard current.version.sha256 == source.sha256, let data = current.data else {
                throw ConfigEditError.conflict("配置文件在备份前已变化，请重新载入：\(source.url.path)")
            }
            guard data.count <= 16 * 1_024 * 1_024,
                  totalConfigBytes <= 128 * 1_024 * 1_024 - data.count else {
                throw ConfigEditError.unsafe("配置快照超过大小限制，请手动备份：\(source.url.path)")
            }
            totalConfigBytes += data.count
            let filename = String(format: "config-%03d.conf", index + 1)
            let target = staging.appendingPathComponent(filename)
            try data.write(to: target, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            entries.append(.init(sourcePath: source.url.path, backupFile: filename,
                                 kind: "ssh-config", byteCount: data.count,
                                 sha256: SafeFileIO.hash(data)))
        }

        var keyCount = 0
        if includeKeys {
            let index = KeyIndex(sshDirectory: scan.rootURL.deletingLastPathComponent())
                .scan(hosts: scan.hosts, globalOptions: scan.globalOptions)
            let selected: [PublicKeyRecord]
            if let selectedKeyIDs {
                let availableIDs = Set(index.keys.map(\.id))
                guard !selectedKeyIDs.isEmpty, selectedKeyIDs.isSubset(of: availableIDs) else {
                    throw ConfigEditError.invalid("请选择至少一把当前密钥页可识别的密钥；配置变化后请重新检查选择")
                }
                selected = index.keys.filter { selectedKeyIDs.contains($0.id) }
            } else {
                selected = index.keys
            }
            guard !selected.isEmpty else {
                throw ConfigEditError.invalid("没有可备份的已索引密钥")
            }
            var keyFiles: [URL] = []
            for key in selected {
                if key.publicKeyExists { keyFiles.append(key.publicKeyURL) }
                if key.privateKeyExists { keyFiles.append(key.privateKeyURL) }
            }
            guard !keyFiles.isEmpty else {
                throw ConfigEditError.invalid("所选密钥文件不存在，请重新扫描密钥")
            }
            keyFiles = Array(Set(keyFiles.map { $0.standardizedFileURL })).sorted { $0.path < $1.path }
            for (index, key) in keyFiles.enumerated() {
                let before = try regularFileInfo(key, maxSize: 1_048_576)
                let filename = String(format: "key-%03d", index + 1) +
                    (key.pathExtension.isEmpty ? "" : ".\(key.pathExtension)")
                let target = staging.appendingPathComponent(filename)
                try FileManager.default.copyItem(at: key, to: target)
                try afterKeyCopy?(target)
                let after = try regularFileInfo(key, maxSize: 1_048_576)
                let copied = try regularFileInfo(target, maxSize: 1_048_576)
                guard before.st_ino == after.st_ino,
                      before.st_size == after.st_size,
                      before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
                      before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
                      copied.st_size == before.st_size else {
                    throw ConfigEditError.conflict("密钥在备份时变化，请重试：\(key.path)")
                }
                let compare = Process()
                compare.executableURL = URL(fileURLWithPath: "/usr/bin/cmp")
                compare.arguments = ["-s", key.path, target.path]
                compare.standardInput = FileHandle.nullDevice
                compare.standardOutput = FileHandle.nullDevice
                compare.standardError = FileHandle.nullDevice
                guard try BoundedProcessRunner.run(compare, timeout: 5) == 0 else {
                    throw ConfigEditError.conflict("密钥备份内容校验失败，已取消本次快照：\(key.path)")
                }
                let verifiedSource = try regularFileInfo(key, maxSize: 1_048_576)
                guard verifiedSource.st_ino == before.st_ino,
                      verifiedSource.st_size == before.st_size,
                      verifiedSource.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
                      verifiedSource.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec else {
                    throw ConfigEditError.conflict("密钥在内容校验期间变化，已取消本次快照：\(key.path)")
                }
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
                entries.append(.init(sourcePath: key.path, backupFile: filename,
                                     kind: key.pathExtension == "pub" ? "public-key" : "private-key",
                                     byteCount: Int(before.st_size), sha256: nil))
                keyCount += 1
            }
        }

        let manifest = SnapshotManifest(createdAt: Date(), includesKeys: includeKeys, entries: entries)
        let manifestURL = staging.appendingPathComponent("manifest.json")
        try JSONEncoder().encode(manifest).write(to: manifestURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifestURL.path)
        let readme = """
        ConfigSSH SSH configuration snapshot
        Each file's original absolute path is recorded in manifest.json.
        Restore only after checking the current destination and file permissions.
        These files are not additionally encrypted by ConfigSSH.
        Never share this folder, especially when it contains private keys.
        """
        let readmeURL = staging.appendingPathComponent("README.txt")
        try Data(readme.utf8).write(to: readmeURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: readmeURL.path)
        try FileManager.default.moveItem(at: staging, to: final)
        complete = true
        return SnapshotResult(url: final, fileCount: entries.count, keyCount: keyCount)
    }

    package func list(in folder: URL, isCloud: Bool = false) throws -> SnapshotIndexResult {
        guard FileManager.default.fileExists(atPath: folder.path) else {
            return SnapshotIndexResult(records: [], issues: [])
        }
        let properties = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard properties.isDirectory == true, properties.isSymbolicLink != true else {
            throw ConfigEditError.unsafe("快照目录不是普通目录：\(folder.path)")
        }
        let children = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        var records: [SnapshotRecord] = []
        var issues: [String] = []
        for child in children where child.lastPathComponent.hasPrefix("ConfigSSH-") {
            do {
                let details = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard details.isDirectory == true, details.isSymbolicLink != true else {
                    throw ConfigEditError.unsafe("不是普通快照目录")
                }
                let manifestURL = child.appendingPathComponent("manifest.json")
                if isCloud && !isDownloadedUbiquitousItem(manifestURL) {
                    issues.append("\(child.lastPathComponent)：iCloud 清单尚未下载；请在 Finder 中下载后刷新")
                    continue
                }
                let snapshot = try coordinatedSnapshot(at: manifestURL, isCloud: isCloud)
                guard let data = snapshot.data, data.count <= 1_000_000 else {
                    throw ConfigEditError.unsafe("清单不存在或超过大小限制")
                }
                let manifest = try JSONDecoder().decode(SnapshotManifest.self, from: data)
                records.append(SnapshotRecord(url: child, manifest: manifest,
                                              manifestHash: SafeFileIO.hash(data), isCloud: isCloud))
            } catch {
                issues.append("\(child.lastPathComponent)：\(error.localizedDescription)")
            }
        }
        return SnapshotIndexResult(records: records.sorted { $0.manifest.createdAt > $1.manifest.createdAt },
                                   issues: issues)
    }

    /// Copies only verified configuration files from an iCloud snapshot into a private local snapshot.
    /// The original iCloud archive is never changed, and private-key entries are never imported.
    package func importCloudSnapshot(_ record: SnapshotRecord, to localFolder: URL) throws -> SnapshotResult {
        guard record.isCloud else { throw ConfigEditError.invalid("请选择 iCloud 快照") }
        let directory = try record.url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard directory.isDirectory == true, directory.isSymbolicLink != true else {
            throw ConfigEditError.unsafe("iCloud 快照不是普通目录")
        }
        let manifestURL = record.url.appendingPathComponent("manifest.json")
        guard isDownloadedUbiquitousItem(manifestURL) else {
            throw ConfigEditError.unsafe("iCloud 清单尚未下载；请先在 Finder 中下载")
        }
        let manifestSnapshot = try coordinatedSnapshot(at: manifestURL, isCloud: true)
        guard let manifestData = manifestSnapshot.data, manifestData.count <= 1_000_000,
              manifestSnapshot.version.sha256 == record.manifestHash else {
            throw ConfigEditError.conflict("iCloud 快照清单自浏览后已变化，请刷新列表")
        }
        let manifest = try JSONDecoder().decode(SnapshotManifest.self, from: manifestData)
        let configEntries = manifest.entries.filter { $0.kind == "ssh-config" }
        guard !configEntries.isEmpty, configEntries.count <= 1_000 else {
            throw ConfigEditError.unsafe("iCloud 快照没有可导入的配置文件，或文件数量超过限制")
        }

        let folder = localFolder.standardizedFileURL
        try SafeFileIO.ensureDirectory(folder)
        let name = "ConfigSSH-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8).lowercased())"
        let staging = folder.appendingPathComponent(".\(name).tmp")
        let final = folder.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        var complete = false
        defer { if !complete { try? FileManager.default.removeItem(at: staging) } }

        var names: Set<String> = []
        var totalBytes = 0
        for entry in configEntries {
            guard entry.sourcePath.hasPrefix("/"), !entry.sourcePath.contains("/../"),
                  entry.backupFile.hasPrefix("config-"), entry.backupFile.hasSuffix(".conf"),
                  entry.backupFile == URL(fileURLWithPath: entry.backupFile).lastPathComponent,
                  names.insert(entry.backupFile).inserted,
                  let digest = entry.sha256, digest.count == 64,
                  entry.byteCount >= 0, entry.byteCount <= 16 * 1_024 * 1_024,
                  totalBytes <= 128 * 1_024 * 1_024 - entry.byteCount else {
                throw ConfigEditError.unsafe("iCloud 快照清单包含无效配置文件、重复文件或缺少校验值")
            }
            totalBytes += entry.byteCount
            let source = record.url.appendingPathComponent(entry.backupFile)
            guard isDownloadedUbiquitousItem(source) else {
                throw ConfigEditError.unsafe("iCloud 配置文件尚未下载：\(entry.backupFile)")
            }
            let archived = try coordinatedSnapshot(at: source, isCloud: true)
            guard let data = archived.data, data.count == entry.byteCount,
                  archived.version.sha256 == digest else {
                throw ConfigEditError.conflict("iCloud 快照内容校验失败：\(entry.backupFile)")
            }
            let target = staging.appendingPathComponent(entry.backupFile)
            try data.write(to: target, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            guard try SafeFileIO.snapshot(at: target).version.sha256 == digest else {
                throw ConfigEditError.io("本机副本写后校验失败：\(entry.backupFile)")
            }
        }
        let imported = SnapshotManifest(createdAt: manifest.createdAt, includesKeys: false,
                                        entries: configEntries)
        let importedManifestURL = staging.appendingPathComponent("manifest.json")
        try JSONEncoder().encode(imported).write(to: importedManifestURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: importedManifestURL.path)
        let note = "ConfigSSH: coordinated local copy of an iCloud snapshot. Only verified SSH configuration files were imported; no key files were copied.\n"
        let noteURL = staging.appendingPathComponent("README.txt")
        try Data(note.utf8).write(to: noteURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: noteURL.path)
        try FileManager.default.moveItem(at: staging, to: final)
        complete = true
        return SnapshotResult(url: final, fileCount: configEntries.count, keyCount: 0)
    }

    private func isDownloadedUbiquitousItem(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [
            .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey
        ]), values.isUbiquitousItem == true else { return true }
        return values.ubiquitousItemDownloadingStatus == .current
    }

    private func coordinatedSnapshot(at url: URL, isCloud: Bool) throws -> (version: FileVersion, data: Data?) {
        if !isCloud { return try SafeFileIO.snapshot(at: url) }
        var coordinationError: NSError?
        var readResult: Result<(version: FileVersion, data: Data?), Error>?
        NSFileCoordinator(filePresenter: nil).coordinate(
            readingItemAt: url, options: .withoutChanges, error: &coordinationError
        ) { coordinatedURL in
            readResult = Result { try SafeFileIO.snapshot(at: coordinatedURL) }
        }
        if let coordinationError { throw ConfigEditError.io("iCloud 清单读取失败：\(coordinationError.localizedDescription)") }
        guard let readResult else { throw ConfigEditError.io("iCloud 清单未能完成协调读取") }
        return try readResult.get()
    }

    private func validate(_ destination: SnapshotDestination) throws -> URL {
        let folder = destination.folderURL
        switch destination {
        case .local:
            break
        case .iCloudDrive(_, let cloudRoot):
            let root = cloudRoot.standardizedFileURL
            let canonicalRoot = try canonicalPath(root)
            let canonicalFolder = try canonicalPath(folder)
            guard canonicalFolder == canonicalRoot || canonicalFolder.hasPrefix(canonicalRoot + "/") else {
                throw ConfigEditError.unsafe("iCloud 备份位置必须位于已选定的 iCloud Drive 目录内")
            }
            var info = stat()
            guard root.path.withCString({ lstat($0, &info) }) == 0,
                  info.st_mode & S_IFMT == S_IFDIR else {
                throw ConfigEditError.unsafe("iCloud Drive 尚不可用，请检查系统登录和同步状态")
            }
        }
        guard folder.path != "/" else { throw ConfigEditError.unsafe("不能将系统根目录作为备份位置") }
        var current = URL(fileURLWithPath: "/")
        for component in folder.pathComponents.dropFirst() {
            current.appendPathComponent(component)
            var info = stat()
            if current.path.withCString({ lstat($0, &info) }) == 0 {
                guard info.st_mode & S_IFMT == S_IFDIR else {
                    throw ConfigEditError.unsafe("备份路径包含符号链接或非目录：\(current.path)")
                }
            } else if errno != ENOENT {
                throw ConfigEditError.io("无法检查备份路径：\(current.path)")
            }
        }
        return folder
    }

    private func canonicalPath(_ url: URL) throws -> String {
        var current = url
        var suffix: [String] = []
        while !FileManager.default.fileExists(atPath: current.path) {
            guard current.path != "/" else { break }
            suffix.insert(current.lastPathComponent, at: 0)
            current = current.deletingLastPathComponent()
        }
        guard let resolved = current.path.withCString({ realpath($0, nil) }) else {
            throw ConfigEditError.io("无法检查备份位置：\(url.path)")
        }
        defer { free(resolved) }
        let base = String(cString: resolved)
        return suffix.reduce(base) { URL(fileURLWithPath: $0).appendingPathComponent($1).path }
    }

    private func regularFileInfo(_ url: URL, maxSize: Int64) throws -> stat {
        guard url.standardizedFileURL.path == url.resolvingSymlinksInPath().path else {
            throw ConfigEditError.unsafe("密钥路径包含符号链接，未备份：\(url.path)")
        }
        var info = stat()
        guard url.path.withCString({ lstat($0, &info) }) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0, info.st_size <= maxSize else {
            throw ConfigEditError.unsafe("密钥不是普通文件或超过 1 MiB，未备份：\(url.path)")
        }
        return info
    }
}
