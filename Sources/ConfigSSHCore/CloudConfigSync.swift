import CommonCrypto
import CryptoKit
import Darwin
import Foundation
import Security

package struct CloudConfigFile: Codable, Sendable {
    package let relativePath: String
    package let content: Data
}

package struct CloudConfigArchive: Codable, Sendable {
    package let deviceID: UUID
    package let deviceName: String
    package let createdAt: Date
    package let files: [CloudConfigFile]
}

private struct EncryptedCloudEnvelope: Codable {
    let version: Int
    let salt: Data
    let sealed: Data
}

package enum CloudConfigCrypto {
    private static let iterations: UInt32 = 310_000

    package static func encrypt(_ archive: CloudConfigArchive, passphrase: String) throws -> Data {
        guard passphrase.count >= 12 else {
            throw ConfigEditError.invalid("加密口令至少需要 12 个字符；请使用独立的强口令")
        }
        var salt = Data(count: 16)
        let randomStatus = salt.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!)
        }
        guard randomStatus == errSecSuccess else { throw ConfigEditError.io("无法生成加密随机数") }
        let key = try deriveKey(passphrase: passphrase, salt: salt)
        let plaintext = try JSONEncoder().encode(archive)
        let associated = Data("ConfigSSH-v1:\(archive.deviceID.uuidString)".utf8)
        let sealed = try AES.GCM.seal(plaintext, using: key, authenticating: associated)
        guard let combined = sealed.combined else { throw ConfigEditError.io("无法生成加密文件") }
        return try JSONEncoder().encode(EncryptedCloudEnvelope(version: 1, salt: salt, sealed: combined))
    }

    package static func decrypt(_ data: Data, deviceID: UUID, passphrase: String) throws -> CloudConfigArchive {
        guard data.count <= 96 * 1_024 * 1_024 else { throw ConfigEditError.unsafe("云端加密文件超过大小限制") }
        let envelope = try JSONDecoder().decode(EncryptedCloudEnvelope.self, from: data)
        guard envelope.version == 1, envelope.salt.count == 16,
              envelope.sealed.count >= 28 else {
            throw ConfigEditError.unsafe("云端加密文件格式或版本不受支持")
        }
        let key = try deriveKey(passphrase: passphrase, salt: envelope.salt)
        do {
            let box = try AES.GCM.SealedBox(combined: envelope.sealed)
            let associated = Data("ConfigSSH-v1:\(deviceID.uuidString)".utf8)
            let plaintext = try AES.GCM.open(box, using: key, authenticating: associated)
            let archive = try JSONDecoder().decode(CloudConfigArchive.self, from: plaintext)
            guard archive.deviceID == deviceID else { throw ConfigEditError.unsafe("云端设备槽标识不匹配") }
            return archive
        } catch {
            throw ConfigEditError.unsafe("解密失败：口令不正确，或云端文件已损坏")
        }
    }

    private static func deriveKey(passphrase: String, salt: Data) throws -> SymmetricKey {
        var bytes = [UInt8](repeating: 0, count: 32)
        let result = passphrase.withCString { password in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password, passphrase.utf8.count,
                                     saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations,
                                     &bytes, bytes.count)
            }
        }
        guard result == kCCSuccess else { throw ConfigEditError.io("无法派生加密密钥") }
        defer { _ = bytes.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        return SymmetricKey(data: bytes)
    }
}

package struct CloudConfigSlot: Identifiable, Sendable {
    package let deviceID: UUID
    package let url: URL
    package var id: UUID { deviceID }
}

package struct CloudConfigDeviceSummary: Sendable {
    package let deviceID: UUID
    package let deviceName: String?
    package let error: String?
}

package struct CloudPushPlan: Sendable {
    package let slot: CloudConfigSlot
    package let expectedRemote: FileVersion
    package let localVersions: [FileVersion]
    package let encryptedData: Data
    package let fileCount: Int
    package let skippedSources: [String]
    package let warnings: [String]
}

package struct CloudPullPlan: Sendable {
    package let slot: CloudConfigSlot
    package let expectedRemote: FileVersion
    package let archive: CloudConfigArchive
    package let changes: ConfigChangePlan
}

package struct CloudConfigSyncService: Sendable {
    package let folder: URL
    package let cloudRoot: URL

    package init(folder: URL, cloudRoot: URL) {
        self.folder = folder.standardizedFileURL
        self.cloudRoot = cloudRoot.standardizedFileURL
    }

    package func testConnection() throws {
        try validateFolder(create: true)
        let probe = folder.appendingPathComponent(".configssh-connection-\(UUID().uuidString)")
        let payload = Data(UUID().uuidString.utf8)
        let descriptor = probe.path.withCString { Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600) }
        guard descriptor >= 0 else { throw ConfigEditError.io("无法在所选 iCloud 目录创建测试文件") }
        defer { _ = Darwin.close(descriptor); try? FileManager.default.removeItem(at: probe) }
        guard payload.withUnsafeBytes({ Darwin.write(descriptor, $0.baseAddress, $0.count) }) == payload.count,
              fsync(descriptor) == 0,
              try Data(contentsOf: probe) == payload else {
            throw ConfigEditError.io("iCloud 目录的本机读写测试失败")
        }
    }

    package func slots() throws -> [CloudConfigSlot] {
        try validateFolder(create: false)
        let devices = folder.appendingPathComponent("Devices")
        guard FileManager.default.fileExists(atPath: devices.path) else { return [] }
        try validatePlainDirectory(devices)
        var found: [UUID: CloudConfigSlot] = [:]
        for url in try FileManager.default.contentsOfDirectory(at: devices, includingPropertiesForKeys: nil) {
            guard url.pathExtension.caseInsensitiveCompare("cssh") == .orderedSame,
                  let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { continue }
            let canonicalURL = devices.appendingPathComponent("\(id.uuidString.lowercased()).cssh")
            guard url.lastPathComponent == canonicalURL.lastPathComponent else { continue }
            if found[id] == nil { found[id] = CloudConfigSlot(deviceID: id, url: canonicalURL) }
        }
        guard found.count <= 64 else { throw ConfigEditError.unsafe("iCloud 中的设备配置超过 64 个，请先在 Finder 中检查") }
        return found.values.sorted { $0.deviceID.uuidString < $1.deviceID.uuidString }
    }

    package func describeSlots(passphrase: String) throws -> [CloudConfigDeviceSummary] {
        try slots().map { slot in
            do {
                guard let data = try coordinatedSnapshot(slot.url).data else {
                    throw ConfigEditError.io("云端文件尚未下载")
                }
                let archive = try CloudConfigCrypto.decrypt(data, deviceID: slot.deviceID,
                                                            passphrase: passphrase)
                return CloudConfigDeviceSummary(deviceID: slot.deviceID, deviceName: archive.deviceName,
                                                error: nil)
            } catch {
                return CloudConfigDeviceSummary(deviceID: slot.deviceID, deviceName: nil,
                                                error: error.localizedDescription)
            }
        }
    }

    package func planPush(scan: ConfigScan, deviceID: UUID, deviceName: String,
                          passphrase: String) throws -> CloudPushPlan {
        try validateFolder(create: true)
        guard scan.availability == .available, !scan.sources.isEmpty else {
            throw ConfigEditError.invalid("没有可推送的 SSH 配置")
        }
        let sshRoot = scan.rootURL.deletingLastPathComponent().standardizedFileURL
        var files: [CloudConfigFile] = []
        var versions: [FileVersion] = []
        var totalBytes = 0
        var skippedSources: [String] = []
        for source in scan.sources {
            let path = source.url.standardizedFileURL.path
            if !path.hasPrefix(sshRoot.path + "/") {
                skippedSources.append(path)
                continue
            }
            let relative = String(path.dropFirst(sshRoot.path.count + 1))
            try validateRelativePath(relative)
            if relative != "config" {
                guard (try? validateConfigFilePath(relative)) != nil,
                      source.url.standardizedFileURL.resolvingSymlinksInPath().path == path else {
                    skippedSources.append(path)
                    continue
                }
            } else if source.url.standardizedFileURL.resolvingSymlinksInPath().path != path {
                throw ConfigEditError.unsafe("主配置路径包含符号链接，无法安全推送")
            }
            let current = try SafeFileIO.snapshot(at: source.url)
            guard let data = current.data, current.version.sha256 == source.sha256,
                  data.count <= 16 * 1_024 * 1_024,
                  totalBytes <= 48 * 1_024 * 1_024 - data.count else {
                throw ConfigEditError.conflict("配置文件已变化或超过大小限制：\(path)")
            }
            totalBytes += data.count
            files.append(CloudConfigFile(relativePath: relative, content: data))
            versions.append(current.version)
        }
        guard files.contains(where: { $0.relativePath == "config" }) else {
            throw ConfigEditError.unsafe("缺少唯一的主配置文件")
        }
        let archive = CloudConfigArchive(deviceID: deviceID, deviceName: String(deviceName.prefix(100)),
                                         createdAt: Date(), files: files)
        let encrypted = try CloudConfigCrypto.encrypt(archive, passphrase: passphrase)
        let slot = try ownSlot(deviceID)
        let remote = try coordinatedSnapshot(slot.url)
        if let existing = remote.data {
            _ = try CloudConfigCrypto.decrypt(existing, deviceID: deviceID, passphrase: passphrase)
        }
        var warnings: [String] = []
        if !skippedSources.isEmpty {
            warnings.append("已跳过 \(skippedSources.count) 个外部或非受管 Include 文件。主 config 中的引用仍保留；其他 Mac 拉取后可能需要手工调整路径。")
        }
        let includeIssues = scan.issues.filter { $0.message.localizedCaseInsensitiveContains("Include") }
        if !includeIssues.isEmpty {
            warnings.append("另有 \(includeIssues.count) 条 Include 解析告警；请检查配置是否完整。")
        }
        return CloudPushPlan(slot: slot, expectedRemote: remote.version, localVersions: versions,
                             encryptedData: encrypted, fileCount: files.count,
                             skippedSources: skippedSources.sorted(), warnings: warnings)
    }

    package func push(_ plan: CloudPushPlan) throws {
        try validateFolder(create: true)
        guard plan.slot.url == (try ownSlot(plan.slot.deviceID)).url else {
            throw ConfigEditError.unsafe("只能推送到当前设备自己的云端文件")
        }
        for version in plan.localVersions { try SafeFileIO.assertCurrent(version) }
        let devices = plan.slot.url.deletingLastPathComponent()
        try SafeFileIO.ensureDirectory(devices)
        try coordinatedWrite(plan.slot.url, expected: plan.expectedRemote, data: plan.encryptedData)
    }

    package func planPull(slot: CloudConfigSlot, writer: ConfigWriter,
                          passphrase: String) throws -> CloudPullPlan {
        try validateFolder(create: false)
        let expectedSlot = try ownSlot(slot.deviceID)
        guard expectedSlot.url.standardizedFileURL.path == slot.url.standardizedFileURL.path else {
            throw ConfigEditError.unsafe("云端设备槽路径无效")
        }
        let remote = try coordinatedSnapshot(slot.url)
        guard let data = remote.data else { throw ConfigEditError.io("云端设备配置尚未下载或已删除") }
        let archive = try CloudConfigCrypto.decrypt(data, deviceID: slot.deviceID, passphrase: passphrase)
        let changes = try writer.planCloudPull(archive.files)
        return CloudPullPlan(slot: slot, expectedRemote: remote.version, archive: archive, changes: changes)
    }

    package func pull(_ plan: CloudPullPlan, writer: ConfigWriter) throws {
        guard try coordinatedSnapshot(plan.slot.url).version == plan.expectedRemote else {
            throw ConfigEditError.conflict("云端配置自预览后已变化，请重新拉取")
        }
        _ = try writer.commit(plan.changes)
    }

    private func ownSlot(_ id: UUID) throws -> CloudConfigSlot {
        let url = folder.appendingPathComponent("Devices/\(id.uuidString.lowercased()).cssh")
        return CloudConfigSlot(deviceID: id, url: url)
    }

    private func validateFolder(create: Bool) throws {
        guard folder.path == cloudRoot.path || folder.path.hasPrefix(cloudRoot.path + "/"),
              cloudRoot.path != "/" else {
            throw ConfigEditError.unsafe("所选目录不在指定的 iCloud Drive 根目录内")
        }
        try validatePlainDirectory(cloudRoot)
        var current = cloudRoot
        let suffix = folder.path.dropFirst(cloudRoot.path.count).split(separator: "/")
        for component in suffix {
            current.appendPathComponent(String(component))
            if FileManager.default.fileExists(atPath: current.path) {
                try validatePlainDirectory(current)
            } else if create {
                try SafeFileIO.ensureDirectory(current)
            }
        }
    }

    private func validatePlainDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw ConfigEditError.unsafe("云端路径包含符号链接或非目录：\(url.path)")
        }
    }

    private func coordinatedSnapshot(_ url: URL) throws -> (version: FileVersion, data: Data?) {
        if FileManager.default.fileExists(atPath: url.path) {
            let values = try url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
            if values.isUbiquitousItem == true, values.ubiquitousItemDownloadingStatus != .current {
                throw ConfigEditError.unsafe("云端文件尚未下载；请先在 Finder 中下载后重试")
            }
        }
        var coordinationError: NSError?
        var output: Result<(version: FileVersion, data: Data?), Error>?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: .withoutChanges,
                                                         error: &coordinationError) { coordinatedURL in
            output = Result {
                if FileManager.default.fileExists(atPath: coordinatedURL.path) {
                    let size = try coordinatedURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= 96 * 1_024 * 1_024 else {
                        throw ConfigEditError.unsafe("云端加密文件超过 96 MiB，已拒绝读取")
                    }
                }
                return try SafeFileIO.snapshot(at: coordinatedURL)
            }
        }
        if let coordinationError { throw ConfigEditError.io("云端协调读取失败：\(coordinationError.localizedDescription)") }
        guard let output else { throw ConfigEditError.io("云端读取未完成") }
        return try output.get()
    }

    private func coordinatedWrite(_ url: URL, expected: FileVersion, data: Data) throws {
        var coordinationError: NSError?
        var outcome: Result<Void, Error>?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forReplacing,
                                                         error: &coordinationError) { coordinatedURL in
            outcome = Result {
                let current = try SafeFileIO.snapshot(at: coordinatedURL)
                guard current.version.sha256 == expected.sha256,
                      current.version.exists == expected.exists else {
                    throw ConfigEditError.conflict("此设备的云端配置已被其他操作修改，请重新预览")
                }
                try SafeFileIO.apply(PlannedFileChange(url: coordinatedURL, before: current.data,
                                                        after: data, expectedVersion: current.version))
            }
        }
        if let coordinationError { throw ConfigEditError.io("云端协调写入失败：\(coordinationError.localizedDescription)") }
        guard let outcome else { throw ConfigEditError.io("云端写入未完成") }
        try outcome.get()
    }
}

private func validateRelativePath(_ path: String) throws {
    let components = path.split(separator: "/", omittingEmptySubsequences: false)
    guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0"),
          components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
        throw ConfigEditError.unsafe("云端配置包含无效的相对路径：\(path)")
    }
}

package func validateConfigFilePath(_ path: String) throws {
    if path == "config" { return }
    let components = path.split(separator: "/", omittingEmptySubsequences: false)
    guard (components.count == 2 || components.count == 3),
          components.first == "config.d",
          let filename = components.last, filename != ".conf", filename.hasSuffix(".conf") else {
        throw ConfigEditError.unsafe("只支持同步主配置与 config.d 下的 .conf 文件：\(path)")
    }
}
