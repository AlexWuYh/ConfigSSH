import CryptoKit
import Darwin
import Foundation

package enum SafeFileIO {
    /// Test-only seams for exercising races between validation and the filesystem change.
    nonisolated(unsafe) static var testHookBeforeApply: ((URL) -> Void)?
    nonisolated(unsafe) static var testHookBeforeReplace: ((URL) -> Void)?

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

    /// Applies one planned change without following symlinks below `anchor` and without
    /// overwriting a file that changed after `expectedVersion` was taken.
    ///
    /// All operations go through a directory descriptor opened component by component with
    /// `O_NOFOLLOW`, so swapping a directory for a symlink after validation cannot redirect the
    /// write. Replacement uses `RENAME_SWAP`: the displaced file is verified after the atomic
    /// swap and swapped back if it is not the expected version. `anchor` defaults to the parent
    /// directory; `ConfigWriter` passes `~/.ssh` so every directory below it is checked.
    package static func apply(_ change: PlannedFileChange, anchor: URL? = nil) throws {
        let url = change.url.standardizedFileURL
        testHookBeforeApply?(url)
        let parent = url.deletingLastPathComponent()
        let root = (anchor ?? parent).standardizedFileURL
        guard parent == root || parent.path.hasPrefix(root.path + "/") else {
            throw ConfigEditError.unsafe("写入目标不在受控目录内：\(url.path)")
        }
        try ensureDirectory(root)
        let directory = try openDirectoryChain(from: root, to: parent)
        defer { _ = Darwin.close(directory) }
        let name = url.lastPathComponent
        let current = try version(in: directory, name: name, path: url.path)
        guard current == change.expectedVersion else {
            throw ConfigEditError.conflict("配置已被其他程序修改，请比较并重新载入：\(url.path)")
        }
        if let after = change.after {
            try replace(in: directory, name: name, url: url, data: after, expected: change.expectedVersion,
                        mode: mode_t(change.desiredMode ?? change.expectedVersion.mode ?? 0o600))
        } else {
            guard change.expectedVersion.exists else { return }
            try remove(in: directory, name: name, url: url, expected: change.expectedVersion)
        }
        guard fsync(directory) == 0 else { throw ConfigEditError.io("无法同步目录：\(parent.path)") }
    }

    private static func openDirectoryChain(from root: URL, to target: URL) throws -> Int32 {
        var descriptor = root.path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW) }
        guard descriptor >= 0 else {
            throw ConfigEditError.unsafe("目录路径不是普通目录，或是符号链接：\(root.path)")
        }
        let relative = target.path.dropFirst(root.path.count).split(separator: "/")
        var current = root
        for component in relative {
            current.appendPathComponent(String(component))
            var next = openat(descriptor, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            if next < 0, errno == ENOENT {
                if mkdirat(descriptor, String(component), 0o700) != 0, errno != EEXIST {
                    let code = errno
                    _ = Darwin.close(descriptor)
                    throw ConfigEditError.io("无法创建目录 \(current.path)：系统错误 \(code)")
                }
                next = openat(descriptor, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            }
            _ = Darwin.close(descriptor)
            guard next >= 0 else {
                throw ConfigEditError.unsafe("目录路径不是普通目录，或是符号链接：\(current.path)")
            }
            descriptor = next
        }
        return descriptor
    }

    private static func version(in directory: Int32, name: String, path: String) throws -> FileVersion {
        let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            if errno == ENOENT {
                return FileVersion(path: path, exists: false, fileID: nil, size: nil, modificationSeconds: nil,
                                   modificationNanoseconds: nil, mode: nil, sha256: nil)
            }
            throw ConfigEditError.unsafe("目标不是普通文件，或是符号链接：\(path)")
        }
        defer { _ = Darwin.close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG else {
            throw ConfigEditError.unsafe("目标不是普通文件，或是符号链接：\(path)")
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            guard count >= 0 else { throw ConfigEditError.io("无法读取 \(path)：系统错误 \(errno)") }
            if count == 0 { break }
            data.append(contentsOf: buffer[0..<count])
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0, after.st_size == before.st_size,
              after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec else {
            throw ConfigEditError.conflict("读取时文件已变化，请重新载入：\(path)")
        }
        return FileVersion(path: path, exists: true, fileID: UInt64(after.st_ino), size: data.count,
                           modificationSeconds: Int64(after.st_mtimespec.tv_sec),
                           modificationNanoseconds: Int64(after.st_mtimespec.tv_nsec),
                           mode: Int(after.st_mode & 0o777), sha256: hash(data))
    }

    private static func sameFile(_ lhs: FileVersion, _ rhs: FileVersion) -> Bool {
        lhs.exists == rhs.exists && lhs.fileID == rhs.fileID && lhs.size == rhs.size &&
            lhs.modificationSeconds == rhs.modificationSeconds &&
            lhs.modificationNanoseconds == rhs.modificationNanoseconds && lhs.sha256 == rhs.sha256
    }

    private static func replace(in directory: Int32, name: String, url: URL, data: Data,
                                expected: FileVersion, mode: mode_t) throws {
        let temporary = ".configssh-\(UUID().uuidString).tmp"
        let descriptor = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode)
        guard descriptor >= 0 else {
            throw ConfigEditError.io("无法创建临时文件：\(url.deletingLastPathComponent().path)/\(temporary)，系统错误 \(errno)")
        }
        var keepTemporary = false
        defer { if !keepTemporary { _ = unlinkat(directory, temporary, 0) } }
        do {
            defer { _ = Darwin.close(descriptor) }
            try data.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                var written = 0
                while written < bytes.count {
                    let count = Darwin.write(descriptor, base.advanced(by: written), bytes.count - written)
                    guard count > 0 else { throw ConfigEditError.io("写入临时文件失败：系统错误 \(errno)") }
                    written += count
                }
            }
            guard fchmod(descriptor, mode) == 0, fsync(descriptor) == 0 else {
                throw ConfigEditError.io("同步临时文件失败：系统错误 \(errno)")
            }
        }

        testHookBeforeReplace?(url)
        if expected.exists {
            guard renameatx_np(directory, temporary, directory, name, UInt32(RENAME_SWAP)) == 0 else {
                throw ConfigEditError.conflict("配置在保存时被移动或删除：\(url.path)")
            }
            // `temporary` now holds the file we displaced. If it is not the version the plan was
            // built from, something wrote in between: put it back and keep our data out.
            let displaced = try? version(in: directory, name: temporary, path: url.path)
            if displaced.map({ sameFile($0, expected) }) != true {
                guard renameatx_np(directory, temporary, directory, name, UInt32(RENAME_SWAP)) == 0 else {
                    keepTemporary = true
                    throw ConfigEditError.io("保存时检测到外部修改且无法自动还原；外部版本保留在 \(url.deletingLastPathComponent().path)/\(temporary)")
                }
                throw ConfigEditError.conflict("配置在保存时被其他程序修改，已保留外部版本：\(url.path)")
            }
        } else {
            guard renameatx_np(directory, temporary, directory, name, UInt32(RENAME_EXCL)) == 0 else {
                throw ConfigEditError.conflict("新配置路径已被其他程序创建：\(url.path)")
            }
        }
        guard try version(in: directory, name: name, path: url.path).sha256 == hash(data) else {
            throw ConfigEditError.io("写后校验失败，请从备份恢复：\(url.path)")
        }
    }

    private static func remove(in directory: Int32, name: String, url: URL, expected: FileVersion) throws {
        let aside = ".configssh-\(UUID().uuidString).removed"
        guard renameatx_np(directory, name, directory, aside, UInt32(RENAME_EXCL)) == 0 else {
            throw ConfigEditError.conflict("配置在删除前被移动或删除：\(url.path)")
        }
        let displaced = try? version(in: directory, name: aside, path: url.path)
        guard displaced.map({ sameFile($0, expected) }) == true else {
            guard renameatx_np(directory, aside, directory, name, UInt32(RENAME_EXCL)) == 0 else {
                throw ConfigEditError.io("删除时检测到外部修改且无法自动还原；外部版本保留在 \(url.deletingLastPathComponent().path)/\(aside)")
            }
            throw ConfigEditError.conflict("配置在删除时被其他程序修改，已保留外部版本：\(url.path)")
        }
        guard unlinkat(directory, aside, 0) == 0 else {
            throw ConfigEditError.io("删除配置文件失败：\(url.path)，系统错误 \(errno)")
        }
    }

    /// Creates (mode 0700) or verifies a directory below `anchor` without following symlinks.
    /// An existing directory must be owned by this user and closed to group and others.
    package static func ensurePrivateDirectory(_ url: URL, anchor: URL) throws {
        let target = url.standardizedFileURL
        let root = anchor.standardizedFileURL
        guard target.path.hasPrefix(root.path + "/") else {
            throw ConfigEditError.unsafe("目录不在受控目录内：\(target.path)")
        }
        try ensureDirectory(root)
        let directory = try openDirectoryChain(from: root, to: target)
        defer { _ = Darwin.close(directory) }
        var info = stat()
        guard fstat(directory, &info) == 0 else {
            throw ConfigEditError.io("无法检查目录 \(target.path)：系统错误 \(errno)")
        }
        guard info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            throw ConfigEditError.unsafe("目录 \(target.path) 不属于当前用户，或其他用户可以访问；请改为仅本人可访问（chmod 700）后再试")
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

    private static func fileStat(_ path: String) throws -> stat? {
        var info = stat()
        let result = path.withCString { lstat($0, &info) }
        if result == 0 { return info }
        if errno == ENOENT { return nil }
        throw ConfigEditError.io("无法检查路径 \(path)：系统错误 \(errno)")
    }
}
