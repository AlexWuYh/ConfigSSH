import CryptoKit
import Darwin
import Foundation

package struct PublicKeyRecord: Identifiable, Sendable {
    package let id: String
    package let name: String
    package let type: String
    package let fingerprint: String?
    package let publicKeyURL: URL
    package let publicKeyExists: Bool
    package let privateKeyURL: URL
    package let privateKeyExists: Bool
    package let associatedHosts: [String]
    package let isReferencedGlobally: Bool
    package let publicKeyText: String?
}

package struct KeyIndexResult: Sendable {
    package let keys: [PublicKeyRecord]
    package let issues: [String]

    package init(keys: [PublicKeyRecord], issues: [String]) {
        self.keys = keys
        self.issues = issues
    }
}

package struct KeyIndex {
    package let sshDirectory: URL

    package init(sshDirectory: URL = ConfigSSHPaths.sshDirectory) {
        self.sshDirectory = sshDirectory.standardizedFileURL
    }

    package func scan(hosts: [HostRecord], globalOptions: [GlobalOptionRecord] = []) -> KeyIndexResult {
        var publicPaths = Set<String>()
        var issues: [String] = []
        if FileManager.default.fileExists(atPath: sshDirectory.path) {
            do {
                var visited = 0
                try collectPublicKeys(in: sshDirectory, depth: 0, visited: &visited,
                                      paths: &publicPaths, issues: &issues)
            } catch {
                issues.append("无法读取 ~/.ssh 目录：\(error.localizedDescription)")
            }
        }

        var privatePaths: [String: Set<String>] = [:]
        var globallyReferenced: Set<String> = []
        for option in globalOptions where option.keyword.caseInsensitiveCompare("IdentityFile") == .orderedSame {
            guard let privateURL = resolve(option.value) else {
                issues.append("无法展开全局 IdentityFile 路径：\(option.value)")
                continue
            }
            let publicURL = privateURL.pathExtension == "pub"
                ? privateURL : URL(fileURLWithPath: privateURL.path + ".pub")
            publicPaths.insert(publicURL.standardizedFileURL.path)
            globallyReferenced.insert(publicURL.standardizedFileURL.path)
        }
        for host in hosts {
            for identity in host.explicitOptions
                .filter({ $0.keyword.caseInsensitiveCompare("IdentityFile") == .orderedSame })
                .flatMap(\.arguments) {
                guard let privateURL = resolve(identity) else {
                    issues.append("无法展开 \(host.alias) 的 IdentityFile 路径：\(identity)")
                    continue
                }
                let publicURL = privateURL.pathExtension == "pub"
                    ? privateURL : URL(fileURLWithPath: privateURL.path + ".pub")
                publicPaths.insert(publicURL.standardizedFileURL.path)
                privatePaths[publicURL.standardizedFileURL.path, default: []].insert(host.alias)
            }
        }

        let keys = publicPaths.sorted().compactMap { publicPath -> PublicKeyRecord? in
            let publicURL = URL(fileURLWithPath: publicPath)
            let privateURL = publicURL.pathExtension == "pub" ? publicURL.deletingPathExtension() : publicURL
            let parsed = parsePublicKey(at: publicURL, issues: &issues)
            guard parsed != nil || privatePaths[publicPath] != nil || globallyReferenced.contains(publicPath) else {
                return nil
            }
            return PublicKeyRecord(
                id: publicURL.path,
                name: privateURL.lastPathComponent,
                type: parsed?.type ?? "未知类型",
                fingerprint: parsed?.fingerprint,
                publicKeyURL: publicURL,
                publicKeyExists: parsed != nil,
                privateKeyURL: privateURL,
                privateKeyExists: FileManager.default.fileExists(atPath: privateURL.path),
                associatedHosts: Array(privatePaths[publicPath] ?? []).sorted(),
                isReferencedGlobally: globallyReferenced.contains(publicPath),
                publicKeyText: parsed?.text
            )
        }
        return KeyIndexResult(keys: keys, issues: issues)
    }

    private func collectPublicKeys(in directory: URL, depth: Int, visited: inout Int,
                                   paths: inout Set<String>, issues: inout [String]) throws {
        guard depth <= 2 else { return }
        let entries = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
        for entry in entries {
            visited += 1
            if visited > 2_000 {
                issues.append("密钥目录扫描超过 2000 个条目，已停止递归")
                return
            }
            let values: URLResourceValues
            do {
                values = try entry.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
            } catch {
                issues.append("无法检查密钥路径：\(entry.path)")
                continue
            }
            guard values.isSymbolicLink != true else { continue }
            if values.isDirectory == true, depth < 2 {
                do {
                    try collectPublicKeys(in: entry, depth: depth + 1, visited: &visited,
                                          paths: &paths, issues: &issues)
                } catch {
                    issues.append("无法读取密钥目录 \(entry.path)：\(error.localizedDescription)")
                }
            } else if values.isRegularFile == true, entry.pathExtension == "pub" {
                paths.insert(entry.standardizedFileURL.path)
            }
        }
    }

    private func resolve(_ path: String) -> URL? {
        guard !path.contains("%"), !path.contains("$"), !path.contains("*") else { return nil }
        if path.hasPrefix("~/") {
            return sshDirectory.deletingLastPathComponent()
                .appendingPathComponent(String(path.dropFirst(2))).standardizedFileURL
        }
        if path.hasPrefix("/") { return URL(fileURLWithPath: path).standardizedFileURL }
        return sshDirectory.deletingLastPathComponent().appendingPathComponent(path).standardizedFileURL
    }

    private func parsePublicKey(at url: URL, issues: inout [String]) -> (type: String, fingerprint: String, text: String)? {
        do {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            guard values.isSymbolicLink != true, values.isRegularFile == true else {
                issues.append("跳过非普通公钥文件：\(url.path)")
                return nil
            }
            let data = try Data(contentsOf: url)
            guard data.count <= 64 * 1024,
                  let content = String(data: data, encoding: .utf8),
                  let firstLine = content.split(whereSeparator: \.isNewline).first else {
                issues.append("公钥文件为空、过大或编码无效：\(url.path)")
                return nil
            }
            let parts = firstLine.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else {
                issues.append("无法解析公钥：\(url.path)")
                return nil
            }
            let digest = Data(SHA256.hash(data: blob)).base64EncodedString().replacingOccurrences(of: "=", with: "")
            return (String(parts[0]), "SHA256:\(digest)", String(firstLine))
        } catch {
            issues.append("无法读取公钥 \(url.path)：\(error.localizedDescription)")
            return nil
        }
    }
}

package enum SSHKeyAlgorithm: String, CaseIterable, Identifiable, Sendable {
    case ed25519
    case rsa3072
    case rsa4096

    package var id: String { rawValue }
    package var displayName: String { self == .ed25519 ? "Ed25519" : rawValue == "rsa3072" ? "RSA 3072" : "RSA 4096" }
    package var arguments: [String] {
        switch self {
        case .ed25519: ["-t", "ed25519"]
        case .rsa3072: ["-t", "rsa", "-b", "3072"]
        case .rsa4096: ["-t", "rsa", "-b", "4096"]
        }
    }
}

private final class KeyNameSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var lastTimestamp: Int64 = 0

    func next(after timestamp: Int64) -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        lastTimestamp = max(timestamp, lastTimestamp + 1)
        return lastTimestamp
    }
}

package enum SSHKeyGenerator {
    package static func suggestedPath(in directory: URL, algorithm: SSHKeyAlgorithm,
                                      now: Date = Date()) -> URL {
        let algorithmName = algorithm == .ed25519 ? "ed25519" : "rsa"
        while true {
            let timestamp = keyNameSequence.next(after: Int64(now.timeIntervalSince1970 * 1_000))
            let filename = "id_\(algorithmName)_\(timestamp)"
            let candidate = directory.appendingPathComponent(filename)
            if !pathExistsIncludingSymlink(candidate.path) &&
                !pathExistsIncludingSymlink(candidate.path + ".pub") {
                return candidate
            }
        }
    }

    private static let keyNameSequence = KeyNameSequence()

    package static func generate(path: URL, algorithm: SSHKeyAlgorithm, comment: String,
                                 timeout: TimeInterval = 120,
                                 beforePublish: (() throws -> Void)? = nil) throws {
        let target = path.standardizedFileURL
        guard target.path.hasPrefix("/") else { throw ConfigEditError.invalid("密钥路径必须是绝对路径") }
        guard !comment.contains(where: \.isNewline) else {
            throw ConfigEditError.invalid("密钥备注不能包含换行")
        }
        let parent = target.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: parent.path) else {
            throw ConfigEditError.invalid("密钥目录不存在")
        }
        let parentValues = try parent.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard parentValues.isDirectory == true, parentValues.isSymbolicLink != true else {
            throw ConfigEditError.unsafe("密钥目录不是普通目录：\(parent.path)")
        }
        let publicURL = URL(fileURLWithPath: target.path + ".pub")
        guard !pathExistsIncludingSymlink(target.path),
              !pathExistsIncludingSymlink(publicURL.path) else {
            throw ConfigEditError.conflict("密钥文件已存在，不会覆盖：\(target.path)")
        }
        guard comment.unicodeScalars.count <= 200,
              !comment.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ConfigEditError.invalid("密钥备注过长或包含控制字符")
        }
        let staging = parent.appendingPathComponent(".configssh-key-\(UUID().uuidString)")
        guard staging.path.withCString({ mkdir($0, 0o700) }) == 0 else {
            throw ConfigEditError.io("无法创建私有密钥生成目录：\(staging.path)")
        }
        defer { try? FileManager.default.removeItem(at: staging) }
        let stagedPrivate = staging.appendingPathComponent("key")
        let stagedPublic = staging.appendingPathComponent("key.pub")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = ["-q"] + algorithm.arguments + ["-f", stagedPrivate.path, "-C", comment, "-N", ""]
        let errors = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        let status: Int32
        do { status = try BoundedProcessRunner.run(process, timeout: timeout) }
        catch { throw ConfigEditError.io("无法完成 ssh-keygen：\(error.localizedDescription)") }
        guard status == 0,
              regularFileInfo(stagedPrivate.path) != nil,
              regularFileInfo(stagedPublic.path) != nil else {
            let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "密钥生成失败"
            throw ConfigEditError.io(String(message.prefix(500)))
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stagedPrivate.path)
        try beforePublish?()
        guard stagedPrivate.path.withCString({ source in
            target.path.withCString { destination in link(source, destination) }
        }) == 0 else {
            throw ConfigEditError.conflict("私钥目标已存在或无法安装，绝不会覆盖：\(target.path)")
        }
        var complete = false
        defer {
            if !complete {
                if let staged = regularFileInfo(stagedPublic.path),
                   let installed = regularFileInfo(publicURL.path), staged.st_ino == installed.st_ino {
                    _ = publicURL.path.withCString { unlink($0) }
                }
                if let staged = regularFileInfo(stagedPrivate.path),
                   let installed = regularFileInfo(target.path), staged.st_ino == installed.st_ino {
                    _ = target.path.withCString { unlink($0) }
                }
            }
        }
        guard stagedPublic.path.withCString({ source in
            publicURL.path.withCString { destination in link(source, destination) }
        }) == 0 else {
            throw ConfigEditError.conflict("公钥目标已存在或无法安装，私钥已回滚：\(publicURL.path)")
        }
        guard let installedPrivate = regularFileInfo(target.path),
              let installedKey = regularFileInfo(stagedPrivate.path),
              installedPrivate.st_ino == installedKey.st_ino else {
            throw ConfigEditError.io("私钥安装后校验失败：\(target.path)")
        }
        complete = true
    }

    private static func regularFileInfo(_ path: String) -> stat? {
        var info = stat()
        guard path.withCString({ lstat($0, &info) }) == 0,
              info.st_mode & S_IFMT == S_IFREG else { return nil }
        return info
    }

    private static func pathExistsIncludingSymlink(_ path: String) -> Bool {
        var info = stat()
        return path.withCString { lstat($0, &info) == 0 }
    }
}
