import CryptoKit
import Darwin
import Foundation

package enum SafeFileIO {
    package static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    package static func snapshot(at url: URL) throws -> (version: FileVersion, data: Data?) {
        let path = url.standardizedFileURL.path
        guard let before = try fileStat(path) else {
            return (FileVersion(path: path, exists: false, fileID: nil, size: nil,
                                modificationSeconds: nil, modificationNanoseconds: nil,
                                mode: nil, sha256: nil), nil)
        }
        guard before.st_mode & S_IFMT == S_IFREG else {
            throw ConfigEditError.unsafe("目标不是普通文件，或是符号链接：\(path)")
        }
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw ConfigEditError.io("无法读取 \(path)：\(error.localizedDescription)")
        }
        guard let after = try fileStat(path),
              before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else {
            throw ConfigEditError.conflict("读取时文件已变化，请重新载入：\(path)")
        }
        return (FileVersion(
            path: path,
            exists: true,
            fileID: UInt64(after.st_ino),
            size: data.count,
            modificationSeconds: Int64(after.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(after.st_mtimespec.tv_nsec),
            mode: Int(after.st_mode & 0o777),
            sha256: hash(data)
        ), data)
    }

    package static func assertCurrent(_ expected: FileVersion) throws {
        let current = try snapshot(at: URL(fileURLWithPath: expected.path)).version
        guard current == expected else {
            throw ConfigEditError.conflict("配置已被其他程序修改，请比较并重新载入：\(expected.path)")
        }
    }

    package static func apply(_ change: PlannedFileChange) throws {
        let url = change.url.standardizedFileURL
        try ensureDirectory(url.deletingLastPathComponent())
        try assertCurrent(change.expectedVersion)
        if let after = change.after {
            try atomicWrite(after, to: url, expected: change.expectedVersion, desiredMode: change.desiredMode)
        } else {
            guard change.expectedVersion.exists else { return }
            guard url.path.withCString({ unlink($0) }) == 0 else {
                throw ConfigEditError.io("删除配置文件失败：\(url.path)，系统错误 \(errno)")
            }
            try syncDirectory(url.deletingLastPathComponent())
        }
    }

    package static func ensureDirectory(_ url: URL) throws {
        let path = url.standardizedFileURL.path
        if path == "/" { return }
        if let info = try fileStat(path) {
            guard info.st_mode & S_IFMT == S_IFDIR else {
                throw ConfigEditError.unsafe("目录路径不是普通目录，或是符号链接：\(path)")
            }
            return
        }
        try ensureDirectory(url.deletingLastPathComponent())
        let result = path.withCString { mkdir($0, 0o700) }
        guard result == 0 || errno == EEXIST else {
            throw ConfigEditError.io("无法创建目录 \(path)：系统错误 \(errno)")
        }
        guard let created = try fileStat(path), created.st_mode & S_IFMT == S_IFDIR else {
            throw ConfigEditError.unsafe("目录创建后路径已变化：\(path)")
        }
    }

    private static func atomicWrite(_ data: Data, to url: URL, expected: FileVersion, desiredMode: Int?) throws {
        let parent = url.deletingLastPathComponent()
        let temporary = parent.appendingPathComponent(".configssh-\(UUID().uuidString).tmp")
        let mode = mode_t(desiredMode ?? expected.mode ?? 0o600)
        let descriptor = temporary.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode)
        }
        guard descriptor >= 0 else {
            throw ConfigEditError.io("无法创建临时文件：\(temporary.path)，系统错误 \(errno)")
        }
        var closed = false
        defer {
            if !closed { _ = Darwin.close(descriptor) }
            _ = temporary.path.withCString { unlink($0) }
        }

        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var written = 0
            while written < bytes.count {
                let count = Darwin.write(descriptor, base.advanced(by: written), bytes.count - written)
                guard count > 0 else {
                    throw ConfigEditError.io("写入临时文件失败：系统错误 \(errno)")
                }
                written += count
            }
        }
        guard fchmod(descriptor, mode) == 0, fsync(descriptor) == 0 else {
            throw ConfigEditError.io("同步临时文件失败：系统错误 \(errno)")
        }
        guard Darwin.close(descriptor) == 0 else {
            closed = true
            throw ConfigEditError.io("关闭临时文件失败：系统错误 \(errno)")
        }
        closed = true

        try assertCurrent(expected)
        if expected.exists {
            guard temporary.path.withCString({ temp in
                url.path.withCString { target in rename(temp, target) }
            }) == 0 else {
                throw ConfigEditError.io("替换配置文件失败：\(url.path)，系统错误 \(errno)")
            }
        } else {
            guard temporary.path.withCString({ temp in
                url.path.withCString { target in link(temp, target) }
            }) == 0 else {
                throw ConfigEditError.conflict("新配置路径已被其他程序创建：\(url.path)")
            }
        }
        try syncDirectory(parent)
        let actual = try snapshot(at: url).version
        guard actual.sha256 == hash(data) else {
            throw ConfigEditError.io("写后校验失败，请从备份恢复：\(url.path)")
        }
    }

    private static func syncDirectory(_ url: URL) throws {
        let descriptor = url.path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY) }
        guard descriptor >= 0 else {
            throw ConfigEditError.io("无法打开目录进行同步：\(url.path)")
        }
        defer { _ = Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw ConfigEditError.io("无法同步目录：\(url.path)")
        }
    }

    private static func fileStat(_ path: String) throws -> stat? {
        var info = stat()
        let result = path.withCString { lstat($0, &info) }
        if result == 0 { return info }
        if errno == ENOENT { return nil }
        throw ConfigEditError.io("无法检查路径 \(path)：系统错误 \(errno)")
    }
}
