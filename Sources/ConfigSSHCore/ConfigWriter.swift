import Darwin
import Foundation

package struct ConfigWriter: Sendable {
    package let rootURL: URL
    package let managedDirectoryURL: URL
    package let backups: BackupStore

    package init(rootURL: URL = ConfigSSHPaths.rootURL,
                 backupDirectory: URL? = nil) {
        self.rootURL = rootURL.standardizedFileURL
        self.managedDirectoryURL = rootURL.deletingLastPathComponent()
            .appendingPathComponent("config.d").standardizedFileURL
        self.backups = BackupStore(rootURL: rootURL, directoryURL: backupDirectory)
    }

    package func plan(_ action: ConfigEditAction, from scan: ConfigScan) throws -> ConfigChangePlan {
        guard scan.rootURL.standardizedFileURL == rootURL else {
            throw ConfigEditError.invalid("配置快照与当前项目路径不一致，请重新载入")
        }
        if case .unreadable = scan.availability {
            throw ConfigEditError.unsafe("主配置不可读，禁止写入")
        }
        return try makePlan(action, scan: scan)
    }

    package func commit(_ plan: ConfigChangePlan) throws -> CommitReceipt {
        guard !plan.changes.isEmpty else { throw ConfigEditError.invalid("没有需要保存的变更") }
        for change in plan.changes { try assertSafeDestination(change.url) }
        for version in plan.checkedVersions { try SafeFileIO.assertCurrent(version) }
        var records: [BackupRecord] = []
        do {
            for change in plan.changes {
                records.append(try backups.create(for: change, reason: plan.title))
            }
        } catch {
            records.forEach(backups.remove)
            throw error
        }

        if let directory = plan.privateDirectory {
            do {
                try SafeFileIO.ensurePrivateDirectory(directory, anchor: rootURL.deletingLastPathComponent())
            } catch {
                records.forEach(backups.remove)
                throw error
            }
        }

        var applied: [PlannedFileChange] = []
        do {
            for change in plan.changes {
                do {
                    try assertSafeDestination(change.url)
                    try SafeFileIO.apply(change, anchor: rootURL.deletingLastPathComponent())
                    applied.append(change)
                } catch {
                    if let current = try? SafeFileIO.snapshot(at: change.url).version,
                       current.sha256 == change.after.map(SafeFileIO.hash) {
                        applied.append(change)
                    }
                    throw error
                }
            }
            let rescan = ConfigReader(rootURL: rootURL).scan()
            guard rescan.availability == .available else {
                throw ConfigEditError.io("写后解析主配置失败，请从备份恢复")
            }
            if let alias = plan.targetAlias,
               !rescan.hosts.contains(where: { $0.alias.caseInsensitiveCompare(alias) == .orderedSame }) {
                throw ConfigEditError.io("写后未发现预期 Host：\(alias)")
            }
        } catch {
            var rollbackFailed = false
            for change in applied.reversed() {
                do {
                    try assertSafeDestination(change.url)
                    let current = try SafeFileIO.snapshot(at: change.url).version
                    guard current.sha256 == change.after.map(SafeFileIO.hash) else {
                        rollbackFailed = true
                        continue
                    }
                    try SafeFileIO.apply(PlannedFileChange(
                        url: change.url,
                        before: change.after,
                        after: change.before,
                        expectedVersion: current,
                        desiredMode: change.expectedVersion.mode
                    ), anchor: rootURL.deletingLastPathComponent())
                } catch {
                    rollbackFailed = true
                }
            }
            if rollbackFailed {
                throw ConfigEditError.io("保存未完成且自动回滚失败；备份位于 \(backups.directoryURL.path)。原错误：\(error.localizedDescription)")
            }
            records.forEach(backups.remove)
            throw error
        }
        let backupLimit = UserDefaults.standard.object(forKey: "backupLimit") as? Int ?? 50
        if backupLimit > 0 {
            try? backups.prune(keeping: max(backupLimit, records.count))
        }
        return CommitReceipt(backups: records, changedPaths: plan.changes.map { $0.url.path })
    }

    package func planRestore(_ record: BackupRecord) throws -> ConfigChangePlan {
        let url = URL(fileURLWithPath: record.sourcePath).standardizedFileURL
        try checkSSHDirectory()
        try validateWritableSource(url)
        let current = try SafeFileIO.snapshot(at: url)
        guard current.version.sha256 == record.afterHash else {
            throw ConfigEditError.conflict("备份创建后配置又发生变化，请先比较：\(url.path)")
        }
        let previous = try backups.previousData(for: record)
        return ConfigChangePlan(
            title: "恢复 \(url.lastPathComponent)",
            targetAlias: nil,
            checkedVersions: [current.version],
            changes: [PlannedFileChange(url: url, before: current.data,
                                        after: previous, expectedVersion: current.version,
                                        desiredMode: record.originalMode)]
        )
    }

    package func planSnapshotRestore(_ record: SnapshotRecord) throws -> ConfigChangePlan {
        guard !record.isCloud else {
            throw ConfigEditError.unsafe("iCloud 快照恢复尚未启用；请先在 Finder 下载并检查文件，再手动恢复")
        }
        try checkSSHDirectory()
        let directoryInfo = try record.url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard directoryInfo.isDirectory == true, directoryInfo.isSymbolicLink != true else {
            throw ConfigEditError.unsafe("快照路径不是普通目录")
        }
        let manifestURL = record.url.appendingPathComponent("manifest.json")
        let manifest = try SafeFileIO.snapshot(at: manifestURL)
        guard let manifestData = manifest.data,
              manifest.version.sha256 == record.manifestHash,
              manifestData.count <= 1_000_000 else {
            throw ConfigEditError.conflict("快照清单自打开后已变化或不可读取，请重新载入")
        }
        let currentManifest = try JSONDecoder().decode(SnapshotManifest.self, from: manifestData)
        let configEntries = currentManifest.entries.filter { $0.kind == "ssh-config" }
        guard !configEntries.isEmpty,
              configEntries.filter({ $0.sourcePath == rootURL.path }).count == 1 else {
            throw ConfigEditError.unsafe("快照缺少唯一的主配置文件，不能自动恢复")
        }
        let currentSources = Set(ConfigReader(rootURL: rootURL).scan().sources.map { $0.url.standardizedFileURL.path })
        var versions = [manifest.version]
        var changes: [PlannedFileChange] = []
        var destinations: Set<String> = []
        var backupNames: Set<String> = []
        for entry in configEntries {
            guard entry.sourcePath.hasPrefix("/"), !entry.sourcePath.contains("/../"),
                  let digest = entry.sha256, digest.count == 64,
                  entry.backupFile.hasPrefix("config-"), entry.backupFile.hasSuffix(".conf"),
                  entry.backupFile == URL(fileURLWithPath: entry.backupFile).lastPathComponent,
                  backupNames.insert(entry.backupFile).inserted else {
                throw ConfigEditError.unsafe("快照文件清单包含无效路径、重复文件或缺少校验值")
            }
            let target = URL(fileURLWithPath: entry.sourcePath).standardizedFileURL
            guard destinations.insert(target.path).inserted,
                  target == rootURL || target.path.hasPrefix(rootURL.deletingLastPathComponent().path + "/") else {
                throw ConfigEditError.unsafe("快照中的配置文件超出 ~/.ssh，不能自动恢复：\(entry.sourcePath)")
            }
            if target != rootURL {
                try validateWritableSource(target)
                try validateSnapshotDestination(target, currentSources: currentSources)
            }
            let archived = try SafeFileIO.snapshot(at: record.url.appendingPathComponent(entry.backupFile))
            guard let archivedData = archived.data,
                  archivedData.count == entry.byteCount,
                  archived.version.sha256 == digest else {
                throw ConfigEditError.conflict("快照内容校验失败：\(entry.backupFile)")
            }
            let current = try SafeFileIO.snapshot(at: target)
            versions += [archived.version, current.version]
            if current.data != archivedData {
                changes.append(PlannedFileChange(url: target, before: current.data,
                                                 after: archivedData, expectedVersion: current.version))
            }
        }
        guard !changes.isEmpty else { throw ConfigEditError.invalid("当前配置与此快照相同，无需恢复") }
        changes.sort { lhs, rhs in
            if lhs.url == rootURL { return false }
            if rhs.url == rootURL { return true }
            return lhs.url.path < rhs.url.path
        }
        var plan = ConfigChangePlan(title: "从快照恢复 SSH 配置", targetAlias: nil,
                                    checkedVersions: versions, changes: changes)
        plan.warnings = ["只恢复快照中的配置文件；不会删除快照后新增的文件，也不会恢复私钥。",
                         "保存前会再次检查当前文件与快照版本，并为被替换的文件建立新的本机备份。",
                         "应用不会对真实配置自动执行 ssh -G；恢复后请在终端自行检查连接。"]
        return plan
    }

    package func planCloudPull(_ files: [CloudConfigFile]) throws -> ConfigChangePlan {
        try checkSSHDirectory()
        guard !files.isEmpty, files.count <= 1_000,
              files.filter({ $0.relativePath == "config" }).count == 1 else {
            throw ConfigEditError.unsafe("云端配置缺少唯一主配置，或文件数量超过限制")
        }
        let sshDirectory = rootURL.deletingLastPathComponent()
        var seen: Set<String> = []
        var versions: [FileVersion] = []
        var changes: [PlannedFileChange] = []
        var totalBytes = 0
        for file in files {
            let components = file.relativePath.split(separator: "/", omittingEmptySubsequences: false)
            guard !file.relativePath.hasPrefix("/"), !file.relativePath.contains("\\"),
                  !file.relativePath.contains("\0"),
                  components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  // APFS is case-insensitive by default: Web.conf and web.conf are one file.
                  seen.insert(file.relativePath.lowercased()).inserted,
                  file.content.count <= 16 * 1_024 * 1_024,
                  totalBytes <= 48 * 1_024 * 1_024 - file.content.count else {
                throw ConfigEditError.unsafe("云端配置包含无效路径、重复文件或超出大小限制")
            }
            try validateConfigFilePath(file.relativePath)
            totalBytes += file.content.count
            let target = sshDirectory.appendingPathComponent(file.relativePath).standardizedFileURL
            guard target == rootURL || target.path.hasPrefix(sshDirectory.path + "/") else {
                throw ConfigEditError.unsafe("云端配置目标超出 ~/.ssh")
            }
            if target != rootURL { try validateWritableSource(target) }
            let current = try SafeFileIO.snapshot(at: target)
            versions.append(current.version)
            if current.data != file.content {
                changes.append(PlannedFileChange(url: target, before: current.data,
                                                 after: file.content, expectedVersion: current.version))
            }
        }
        guard !changes.isEmpty else { throw ConfigEditError.invalid("本机与所选云端配置相同，无需拉取") }
        changes.sort { lhs, rhs in
            if lhs.url == rootURL { return false }
            if rhs.url == rootURL { return true }
            return lhs.url.path < rhs.url.path
        }
        var plan = ConfigChangePlan(title: "从 iCloud 拉取 SSH 配置", targetAlias: nil,
                                    checkedVersions: versions, changes: changes)
        plan.warnings = ["云端仅覆盖同路径配置文件；本机其他文件和密钥不会删除或覆盖。",
                         "其他 Mac 的绝对路径、IdentityFile 和 Include 可能需要手工调整；不会自动执行 ssh -G。"]
        return plan
    }

    package func planGlobalOptionUpdate(keyword: String, value: String, from scan: ConfigScan) throws -> ConfigChangePlan {
        guard scan.rootURL.standardizedFileURL == rootURL else {
            throw ConfigEditError.invalid("全局配置快照与当前文件不一致，请重新载入")
        }
        if case .unreadable = scan.availability {
            throw ConfigEditError.unsafe("~/.ssh/config 不可读，禁止修改")
        }
        guard let parameter = GlobalConfigCatalog.parameter(keyword) else {
            throw ConfigEditError.invalid("此参数不在可编辑的常见全局参数列表中")
        }
        guard !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !value.contains("#"), !value.contains("\\"), !value.contains("\"") else {
            throw ConfigEditError.invalid("参数值不能包含换行、注释符、引号或转义字符")
        }
        if parameter.keyword == "Port", !value.isEmpty,
           !(Int(value).map { (1...65535).contains($0) } ?? false) {
            throw ConfigEditError.invalid("端口必须是 1 到 65535 的整数")
        }
        if ["ServerAliveInterval", "ServerAliveCountMax", "ConnectTimeout"].contains(parameter.keyword),
           !value.isEmpty, Int(value) == nil {
            throw ConfigEditError.invalid("此参数需要填写整数秒数")
        }

        let root = try SafeFileIO.snapshot(at: rootURL)
        if scan.availability == .missing && root.version.exists {
            throw ConfigEditError.conflict("~/.ssh/config 已在打开页面后创建，请重新载入")
        }
        if let scanned = scan.sources.first(where: { $0.url.standardizedFileURL == rootURL }),
           scanned.sha256 != root.version.sha256 {
            throw ConfigEditError.conflict("~/.ssh/config 自上次载入后已变化，请重新载入")
        }
        let rootOptions = scan.globalOptions.filter {
            $0.sourceURL.standardizedFileURL == rootURL &&
            $0.keyword.caseInsensitiveCompare(parameter.keyword) == .orderedSame
        }
        guard rootOptions.count <= 1 else {
            throw ConfigEditError.unsafe("根配置中存在多个 \(parameter.keyword) 全局值，无法确定要修改哪一个")
        }
        let before = root.data ?? Data()
        let lines = byteLines(in: before)
        var after = before
        if let option = rootOptions.first {
            guard let line = lines.first(where: { $0.number == option.line }) else {
                throw ConfigEditError.conflict("无法定位全局参数的原始行")
            }
            if value.isEmpty {
                after.replaceSubrange(line.range, with: commentOnlyLine(from: line.text))
            } else {
                let serialized = parameter.keyword == "IdentityFile" ? encodePath(value) : value
                after.replaceSubrange(line.range,
                                      with: try rewrite(line: line.text, keyword: parameter.keyword, value: serialized))
            }
        } else if !value.isEmpty {
            let insertion = globalInsertionOffset(in: before)
            let newline = lineEnding(in: before)
            let serialized = parameter.keyword == "IdentityFile" ? encodePath(value) : value
            let separator = insertion == before.count && before.last.map({ $0 != 0x0A }) == true ? newline : ""
            let inserted = Data("\(separator)\(parameter.keyword) \(serialized)\(newline)".utf8)
            after.replaceSubrange(insertion..<insertion, with: inserted)
        } else {
            throw ConfigEditError.invalid("此全局参数尚未设置")
        }
        guard after != root.data else { throw ConfigEditError.invalid("全局参数没有变化") }
        return ConfigChangePlan(title: "修改全局参数 \(parameter.keyword)", targetAlias: nil,
                                checkedVersions: [root.version],
                                changes: [PlannedFileChange(url: rootURL, before: root.data,
                                                           after: after, expectedVersion: root.version)])
    }

    package func planRootConfigReplacement(text: String, from scan: ConfigScan) throws -> ConfigChangePlan {
        guard scan.rootURL.standardizedFileURL == rootURL else {
            throw ConfigEditError.invalid("配置快照与当前主配置路径不一致，请重新载入")
        }
        if case .unreadable = scan.availability {
            throw ConfigEditError.unsafe("主配置不可读，禁止修改")
        }
        guard !text.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw ConfigEditError.invalid("SSH 配置不能包含 NUL 字符")
        }
        try checkSSHDirectory()
        let root = try SafeFileIO.snapshot(at: rootURL)
        switch scan.availability {
        case .missing:
            guard !root.version.exists else {
                throw ConfigEditError.conflict("主配置已由其他程序创建，请重新载入")
            }
        case .available:
            guard let scanned = scan.sources.first(where: { $0.url.standardizedFileURL == rootURL }),
                  scanned.sha256 == root.version.sha256,
                  root.version.exists else {
                throw ConfigEditError.conflict("主配置自上次载入后已变化，请重新载入")
            }
        case .unreadable:
            throw ConfigEditError.unsafe("主配置不可读，禁止修改")
        }
        let after = Data(text.utf8)
        guard after != root.data else { throw ConfigEditError.invalid("配置文件内容没有变化") }
        guard max(after.count, root.data?.count ?? 0) <= 2_000_000 else {
            throw ConfigEditError.unsafe("主配置超过 2 MB，应用内全文编辑不可安全预览；请使用外部编辑器")
        }
        let candidate = ConfigReader(rootURL: rootURL).preview(rootData: after)
        guard candidate.availability == .available else {
            throw ConfigEditError.invalid("修改后的主配置无法静态解析，请检查文本编码")
        }
        let introduced = newlyIntroducedIssues(candidate.issues, comparedWith: scan.issues)
        let errors = introduced.filter { $0.severity == .error }
        guard errors.isEmpty else {
            let details = errors.prefix(5).map { "\($0.location)：\($0.message)" }.joined(separator: "；")
            throw ConfigEditError.invalid("修改引入了配置语法问题：\(details)")
        }
        var versions = [root.version]
        var checkedPaths: Set<String> = [rootURL.path]
        for source in scan.sources + candidate.sources where source.url.standardizedFileURL != rootURL {
            let current = try SafeFileIO.snapshot(at: source.url)
            guard current.version.sha256 == source.sha256 else {
                throw ConfigEditError.conflict("Include 文件自上次载入后已变化：\(source.url.path)")
            }
            if checkedPaths.insert(source.url.standardizedFileURL.path).inserted {
                versions.append(current.version)
            }
        }
        var plan = ConfigChangePlan(title: "编辑主配置 config", targetAlias: nil,
                                    checkedVersions: versions,
                                    changes: [PlannedFileChange(url: rootURL, before: root.data,
                                                                after: after, expectedVersion: root.version)])
        plan.warnings = introduced.filter { $0.severity == .warning }
            .map { "\($0.location)：\($0.message)" }
        plan.warnings.append("静态检查不会执行 Match exec，也无法保证所有 OpenSSH 参数在当前系统上有效。")
        return plan
    }

    private func newlyIntroducedIssues(_ current: [ConfigIssue], comparedWith previous: [ConfigIssue]) -> [ConfigIssue] {
        func key(_ issue: ConfigIssue) -> String {
            "\(issue.sourceURL.standardizedFileURL.path)\u{1F}\(issue.severity)\u{1F}\(issue.message)"
        }
        var counts: [String: Int] = [:]
        for issue in previous { counts[key(issue), default: 0] += 1 }
        var introduced: [ConfigIssue] = []
        for issue in current {
            let fingerprint = key(issue)
            if counts[fingerprint, default: 0] > 0 {
                counts[fingerprint, default: 0] -= 1
            } else {
                introduced.append(issue)
            }
        }
        return introduced
    }

    private func globalInsertionOffset(in data: Data) -> Int {
        let bytes = Array(data)
        var offset = 0
        for line in byteLines(in: data) {
            let trimmed = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && !trimmed.hasPrefix("#") { return line.range.lowerBound }
            offset = line.range.upperBound
        }
        return offset <= bytes.count ? offset : bytes.count
    }

    private func commentOnlyLine(from line: String) -> Data {
        guard let marker = line.firstIndex(of: "#") else { return Data() }
        let indent = String(line.prefix(while: \.isWhitespace))
        let comment = String(line[marker...])
        let newline = line.hasSuffix("\r\n") ? "\r\n" : line.hasSuffix("\n") ? "\n" : ""
        return Data((indent + comment + newline).utf8)
    }

    private func makePlan(_ action: ConfigEditAction, scan: ConfigScan) throws -> ConfigChangePlan {
        var versions: [String: FileVersion] = [:]
        for source in scan.sources {
            let current = try SafeFileIO.snapshot(at: source.url)
            guard current.version.sha256 == source.sha256 else {
                throw ConfigEditError.conflict("配置自上次载入后已变化：\(source.url.path)")
            }
            versions[source.url.path] = current.version
        }
        let root = try SafeFileIO.snapshot(at: rootURL)
        if scan.availability == .missing && root.version.exists {
            throw ConfigEditError.conflict("主配置已由其他程序创建，请重新载入")
        }
        if let scannedRoot = scan.sources.first(where: { $0.url == rootURL }),
           scannedRoot.sha256 != root.version.sha256 {
            throw ConfigEditError.conflict("主配置自上次载入后已变化，请重新载入")
        }
        versions[rootURL.path] = root.version
        try checkSSHDirectory()

        let changes: [PlannedFileChange]
        let title: String
        let expectedAlias: String?
        switch action {
        case .add(let input):
            try validate(input, requireHostName: true)
            if let problem = HostFileName.problem(input.displayName) { throw ConfigEditError.invalid(problem) }
            try validateIdentitiesOnly(input, existing: nil)
            try validateConnectionReuse(input, existing: nil)
            guard !scan.hosts.contains(where: { $0.alias.caseInsensitiveCompare(input.alias) == .orderedSame }) else {
                throw ConfigEditError.invalid("Host 别名已存在：\(input.alias)")
            }
            guard !scan.issues.contains(where: { $0.message.contains("Include") }) else {
                throw ConfigEditError.unsafe("存在未解析的 Include，无法确认别名唯一性；请先处理解析告警")
            }
            let targetURL = try destination(for: input)
            try validateWritableSource(targetURL)
            let target = try SafeFileIO.snapshot(at: targetURL)
            guard !target.version.exists else {
                throw ConfigEditError.conflict("目标配置文件已存在，请先检查：\(targetURL.path)")
            }
            versions[targetURL.path] = target.version
            let rootAfter = try rootWithIncludes(root.data, destination: targetURL)
            if rootAfter != root.data {
                let indexed = Set(scan.sources.map { $0.url.standardizedFileURL.path })
                let newlyActivated = existingManagedFiles().filter { !indexed.contains($0.path) }
                if let first = newlyActivated.first {
                    throw ConfigEditError.unsafe("安装 Include 会同时启用尚未导入的配置 \(first.path)；请先检查并手动设置根配置")
                }
            }
            let newline = lineEnding(in: root.data ?? Data())
            let pendingTarget = PlannedFileChange(
                url: targetURL, before: nil, after: Data(render(input, newline: newline).utf8),
                expectedVersion: target.version
            )
            var pending = [pendingTarget]
            if rootAfter != root.data {
                pending.append(PlannedFileChange(url: rootURL, before: root.data,
                                                  after: rootAfter, expectedVersion: root.version))
            }
            changes = pending
            title = "新增主机 \(input.alias)"
            expectedAlias = input.alias

        case .update(let hostID, let input):
            let host = try editableHost(hostID, in: scan)
            guard input.alias == host.alias else {
                throw ConfigEditError.invalid("当前版本暂不支持修改 Host 别名")
            }
            try validate(input, requireHostName: false)
            try validateIdentitiesOnly(input, existing: host)
            try validateConnectionReuse(input, existing: host)
            let current = try SafeFileIO.snapshot(at: host.sourceURL)
            guard current.version.sha256 == scan.sources.first(where: { $0.url == host.sourceURL })?.sha256 else {
                throw ConfigEditError.conflict("主机源文件已变化，请重新载入")
            }
            let after = try patch(host, in: current.data ?? Data(), with: input)
            guard after != current.data else { throw ConfigEditError.invalid("没有需要保存的变更") }
            changes = [PlannedFileChange(url: host.sourceURL, before: current.data,
                                         after: after, expectedVersion: current.version)]
            title = "编辑主机 \(host.alias)"
            expectedAlias = host.alias

        case .delete(let hostID):
            let host = try editableHost(hostID, in: scan)
            let current = try SafeFileIO.snapshot(at: host.sourceURL)
            guard current.version.sha256 == scan.sources.first(where: { $0.url == host.sourceURL })?.sha256 else {
                throw ConfigEditError.conflict("主机文件已变化，请重新载入")
            }
            let source = current.data ?? Data()
            // The file name may be a display name, so it is not compared with the alias: a managed
            // file that holds only this one host (first real line `Host <alias>`) goes whole.
            let deletesWholeFile = isManagedHostFile(host.sourceURL) &&
                scan.hosts.filter({ $0.sourceURL == host.sourceURL }).count == 1 &&
                !scan.rules.contains(where: { $0.sourceURL.standardizedFileURL == host.sourceURL.standardizedFileURL }) &&
                String(data: source, encoding: .utf8)?.split(whereSeparator: \.isNewline).first(where: {
                    !$0.trimmingCharacters(in: .whitespaces).isEmpty &&
                    !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#")
                })?.trimmingCharacters(in: .whitespaces).lowercased() == "host \(host.alias.lowercased())"
            if deletesWholeFile {
                changes = [PlannedFileChange(url: host.sourceURL, before: source,
                                             after: nil, expectedVersion: current.version)]
            } else {
                guard host.byteRange.lowerBound >= 0,
                      host.byteRange.upperBound <= source.count,
                      let lastLine = byteLines(in: source).first(where: {
                          $0.number == max(host.sourceLine, host.explicitOptions.map(\.line).max() ?? host.sourceLine)
                      }),
                      lastLine.range.lowerBound >= host.byteRange.lowerBound,
                      lastLine.range.upperBound <= host.byteRange.upperBound else {
                    throw ConfigEditError.conflict("无法定位 Host 原始字节范围，请重新载入")
                }
                var after = source
                after.removeSubrange(host.byteRange.lowerBound..<lastLine.range.upperBound)
                changes = [PlannedFileChange(url: host.sourceURL, before: source,
                                             after: after, expectedVersion: current.version)]
            }
            title = "删除主机 \(host.alias)"
            expectedAlias = nil
        }
        var plan = ConfigChangePlan(title: title, targetAlias: expectedAlias,
                                    checkedVersions: Array(versions.values), changes: changes)
        switch action {
        case .add(let input), .update(_, let input):
            if case .minutes = input.connectionReuse { plan.privateDirectory = controlSocketDirectoryURL }
        case .delete: break
        }
        return plan
    }

    /// `~/.ssh/cm`, the directory behind `ConnectionReuse.controlPath`. ssh does not create it.
    package var controlSocketDirectoryURL: URL {
        rootURL.deletingLastPathComponent().appendingPathComponent("cm", isDirectory: true)
    }

    private func editableHost(_ id: String, in scan: ConfigScan) throws -> HostRecord {
        guard let host = scan.hosts.first(where: { $0.id == id }) else {
            throw ConfigEditError.invalid("找不到主机，请重新载入")
        }
        guard host.isSimple else {
            throw ConfigEditError.unsafe(host.readOnlyReasons.joined(separator: "；"))
        }
        guard scan.sources.contains(where: { $0.url == host.sourceURL }) else {
            throw ConfigEditError.unsafe("无法定位主机源文件")
        }
        try validateWritableSource(host.sourceURL)
        return host
    }

    private func validateWritableSource(_ sourceURL: URL) throws {
        let sshDirectory = rootURL.deletingLastPathComponent()
        guard sourceURL.path.hasPrefix(sshDirectory.path + "/") else {
            throw ConfigEditError.unsafe("外部 Include 文件不在 ~/.ssh 内，暂不支持自动编辑")
        }
        var directory = sshDirectory
        let relative = sourceURL.deletingLastPathComponent().path.dropFirst(sshDirectory.path.count + 1)
        for component in relative.split(separator: "/") {
            directory.appendPathComponent(String(component))
            guard FileManager.default.fileExists(atPath: directory.path) else { continue }
            let values = try directory.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard values.isSymbolicLink != true, values.isDirectory == true else {
                throw ConfigEditError.unsafe("主机源文件的目录路径包含符号链接：\(directory.path)")
            }
        }
    }

    /// Snapshot manifests live outside `~/.ssh` and are not trusted to choose arbitrary targets.
    /// Allowed: managed `config.d` files, files the current config statically Includes, or a
    /// not-yet-existing file whose name is not reserved for keys or OpenSSH state. Checked
    /// before the target is read so key bytes never enter memory.
    private func validateSnapshotDestination(_ target: URL, currentSources: Set<String>) throws {
        if isManagedHostFile(target) || currentSources.contains(target.path) { return }
        let name = target.lastPathComponent.lowercased()
        let reserved = name.hasPrefix("authorized_keys") || name.hasPrefix("known_hosts") ||
            name.hasPrefix("id_") || name.hasSuffix(".pub") || ["environment", "rc"].contains(name)
        var info = stat()
        let missing = lstat(target.path, &info) != 0 && errno == ENOENT
        guard missing, !reserved else {
            throw ConfigEditError.unsafe("快照目标不是当前配置引用的文件，或属于密钥/OpenSSH 保留文件，不能自动恢复：\(target.path)")
        }
    }

    /// Re-validated at commit time: a directory on the path may have been swapped for a
    /// symlink after the plan was previewed, and `lstat` on the leaf follows parent links.
    private func assertSafeDestination(_ url: URL) throws {
        try checkSSHDirectory()
        try validateWritableSource(url.standardizedFileURL)
    }

    private func checkSSHDirectory() throws {
        for url in [rootURL.deletingLastPathComponent(), managedDirectoryURL] {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard values.isSymbolicLink != true, values.isDirectory == true else {
                throw ConfigEditError.unsafe("SSH 配置目录不是普通目录：\(url.path)")
            }
        }
    }

    package func isManagedHostFile(_ url: URL) -> Bool {
        let components = url.standardizedFileURL.pathComponents
        let base = managedDirectoryURL.pathComponents
        guard components.starts(with: base), url.pathExtension.lowercased() == "conf" else { return false }
        return components.count == base.count + 1 || components.count == base.count + 2
    }

    package func groupDirectories() -> [String] {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: managedDirectoryURL,
                                                                        includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        else { return [] }
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true else { return nil }
            return url.lastPathComponent
        }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    package func createGroup(named name: String) throws {
        try validateGroup(name)
        try checkSSHDirectory()
        let directory = managedDirectoryURL.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: directory.path) else {
            throw ConfigEditError.conflict("分组已存在：\(name)")
        }
        try SafeFileIO.ensureDirectory(directory)
    }

    package func planGroupDeletion(named name: String, from scan: ConfigScan) throws -> GroupDeletionPlan {
        try validateGroup(name)
        guard scan.rootURL.standardizedFileURL == rootURL else {
            throw ConfigEditError.invalid("配置快照与当前文件不一致，请重新载入")
        }
        if case .unreadable = scan.availability {
            throw ConfigEditError.unsafe("主配置不可读，不能删除分组")
        }
        try checkSSHDirectory()
        let directory = managedDirectoryURL.appendingPathComponent(name).standardizedFileURL
        guard FileManager.default.fileExists(atPath: directory.path) else {
            guard !scan.hosts.contains(where: { $0.configGroup == name }) else {
                throw ConfigEditError.unsafe("此分组来自其他配置目录，不能从 ConfigSSH 删除")
            }
            return GroupDeletionPlan(name: name, directoryURL: nil, movedHosts: [], changePlan: nil)
        }
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw ConfigEditError.unsafe("分组路径不是普通目录：\(directory.path)")
        }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        var hosts: [HostRecord] = []
        var destinationChanges: [PlannedFileChange] = []
        var sourceChanges: [PlannedFileChange] = []
        var versions: [FileVersion] = []
        for source in scan.sources {
            let current = try SafeFileIO.snapshot(at: source.url)
            guard current.version.sha256 == source.sha256 else {
                throw ConfigEditError.conflict("配置自上次载入后已变化：\(source.url.path)")
            }
            versions.append(current.version)
        }
        let root = try SafeFileIO.snapshot(at: rootURL)
        if scan.availability == .missing && root.version.exists {
            throw ConfigEditError.conflict("主配置已由其他程序创建，请重新载入")
        }
        if !versions.contains(where: { $0.path == rootURL.path }) { versions.append(root.version) }
        var rootAfter = root.data

        for file in files.sorted(by: { $0.path < $1.path }) {
            if file.lastPathComponent == ".DS_Store" { continue }
            guard file.pathExtension.lowercased() == "conf",
                  let host = scan.hosts.first(where: { $0.sourceURL.standardizedFileURL == file.standardizedFileURL }),
                  scan.hosts.filter({ $0.sourceURL.standardizedFileURL == file.standardizedFileURL }).count == 1 else {
                throw ConfigEditError.unsafe("分组包含非独立主机文件，不能自动移动：\(file.path)")
            }
            let removal = try plan(.delete(hostID: host.id), from: scan)
            guard let sourceChange = removal.changes.first, sourceChange.after == nil else {
                throw ConfigEditError.unsafe("分组文件除主机外还包含其他规则，不能整体移动：\(file.path)")
            }
            let destination = managedDirectoryURL.appendingPathComponent(file.lastPathComponent)
            let target = try SafeFileIO.snapshot(at: destination)
            guard !target.version.exists else {
                throw ConfigEditError.conflict("未分组目录已有同名文件，不能覆盖：\(destination.path)")
            }
            rootAfter = try rootWithIncludes(rootAfter, destination: destination)
            versions.append(target.version)
            destinationChanges.append(PlannedFileChange(url: destination, before: nil, after: sourceChange.before,
                                                        expectedVersion: target.version, desiredMode: sourceChange.expectedVersion.mode))
            sourceChanges.append(sourceChange)
            hosts.append(host)
        }
        var changes = destinationChanges
        if rootAfter != root.data {
            let indexed = Set(scan.sources.map { $0.url.standardizedFileURL.path })
            if let first = existingManagedFiles().first(where: { !indexed.contains($0.path) }) {
                throw ConfigEditError.unsafe("安装 Include 会同时启用尚未导入的配置 \(first.path)，请先检查")
            }
            changes.append(PlannedFileChange(url: rootURL, before: root.data, after: rootAfter,
                                             expectedVersion: root.version))
        }
        changes += sourceChanges
        let changePlan = changes.isEmpty ? nil : ConfigChangePlan(
            title: "删除分组 \(name)并移动主机到未分组", targetAlias: nil,
            checkedVersions: versions, changes: changes
        )
        return GroupDeletionPlan(name: name, directoryURL: directory, movedHosts: hosts, changePlan: changePlan)
    }

    package func removeEmptyGroupDirectory(_ plan: GroupDeletionPlan) throws {
        guard let directory = plan.directoryURL else { return }
        guard directory.deletingLastPathComponent().standardizedFileURL.path == managedDirectoryURL.path else {
            throw ConfigEditError.unsafe("分组目录不在受管范围内")
        }
        // Finder metadata is the only non-host file a group may hold; drop it so rmdir works.
        let finderMetadata = directory.appendingPathComponent(".DS_Store").path
        var info = stat()
        if lstat(finderMetadata, &info) == 0, info.st_mode & S_IFMT == S_IFREG {
            _ = unlink(finderMetadata)
        }
        guard directory.path.withCString({ rmdir($0) }) == 0 else {
            throw ConfigEditError.io("主机可能已移动，但分组目录未能删除；请重新载入后检查：\(directory.path)")
        }
    }

    private func validateGroup(_ name: String) throws {
        guard !name.isEmpty, name != "未分组", name.count <= 80,
              name.trimmingCharacters(in: .whitespacesAndNewlines) == name,
              name != ".", name != "..", !name.contains("/"), !name.contains("\\"),
              !name.contains("*"), !name.contains("?"), !name.contains("["), !name.contains("]"),
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ConfigEditError.invalid("分组名称为空、保留名称或包含路径/通配符等不安全字符")
        }
    }

    private func destination(for input: HostInput) throws -> URL {
        let group = input.group.trimmingCharacters(in: .whitespacesAndNewlines)
        if !group.isEmpty {
            guard group == input.group, group != ".", group != "..", group.count <= 80,
                  !group.contains("/"), !group.contains("\\"),
                  !group.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw ConfigEditError.invalid("分组名称不能包含路径分隔符、控制字符或首尾空格")
            }
        }
        let directory = group.isEmpty ? managedDirectoryURL : managedDirectoryURL.appendingPathComponent(group)
        let stem = HostFileName.stem(displayName: input.displayName, alias: input.alias)
        return directory.appendingPathComponent("\(stem).conf").standardizedFileURL
    }

    private func existingManagedFiles() -> [URL] {
        let fm = FileManager.default
        guard let top = try? fm.contentsOfDirectory(at: managedDirectoryURL, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return []
        }
        var result: [URL] = []
        for entry in top {
            if entry.pathExtension.lowercased() == "conf" { result.append(entry.standardizedFileURL) }
            else if (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                    let children = try? fm.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil) {
                result += children.filter { $0.pathExtension.lowercased() == "conf" }.map(\.standardizedFileURL)
            }
        }
        return result
    }

    private func rootWithIncludes(_ data: Data?, destination: URL) throws -> Data {
        let includes = ["Include config.d/*.conf", "Include config.d/*/*.conf"]
        guard let data else { return Data((includes.joined(separator: "\n") + "\n").utf8) }
        guard String(data: data, encoding: .utf8) != nil else {
            throw ConfigEditError.unsafe("主配置不是 UTF-8，无法安装 Include")
        }
        let newline = lineEnding(in: data)
        var insertion = data.count
        var existing: Set<String> = []
        var encounteredHostRule = false
        var misplacedInclude = false
        var coveredByExistingPattern = false
        var hasOtherConfigDirectoryPattern = false
        let bytes = Array(data)
        var lineStart = 0
        while lineStart < bytes.count {
            let nextLF = bytes[lineStart...].firstIndex(of: 10)
            let lineEnd = nextLF ?? bytes.count
            let line = String(decoding: bytes[lineStart..<lineEnd], as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = line.lowercased()
            if startsWithKeyword(lower, "host") || startsWithKeyword(lower, "match") {
                if !encounteredHostRule {
                    insertion = lineStart
                    encounteredHostRule = true
                }
            }
            if startsWithKeyword(lower, "include") {
                let value = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "="))
                    .trimmingCharacters(in: .whitespaces)
                for pathPattern in value.split(whereSeparator: \.isWhitespace) {
                    let candidatePattern = String(pathPattern)
                    guard candidatePattern.contains("config.d/") else { continue }
                    if encounteredHostRule { misplacedInclude = true; continue }
                    let canonical = "Include \(candidatePattern)".lowercased()
                    if includes.map({ $0.lowercased() }).contains(canonical) {
                        existing.insert(canonical)
                    } else {
                        hasOtherConfigDirectoryPattern = true
                    }
                    let absolutePattern: String
                    if candidatePattern.hasPrefix("~/") {
                        absolutePattern = rootURL.deletingLastPathComponent().deletingLastPathComponent().path
                            + "/" + candidatePattern.dropFirst(2)
                    } else if candidatePattern.hasPrefix("/") {
                        absolutePattern = candidatePattern
                    } else {
                        absolutePattern = rootURL.deletingLastPathComponent().path + "/" + candidatePattern
                    }
                    if absolutePattern.withCString({ pattern in
                        destination.path.withCString { fnmatch(pattern, $0, FNM_PATHNAME) }
                    }) == 0 {
                        coveredByExistingPattern = true
                    }
                }
            }
            guard let nextLF else { break }
            lineStart = nextLF + 1
        }
        if misplacedInclude {
            throw ConfigEditError.unsafe("已有 config.d Include 位于 Host/Match 之后，无法安全自动安装")
        }
        if coveredByExistingPattern { return data }
        if hasOtherConfigDirectoryPattern {
            throw ConfigEditError.unsafe("根配置已有自定义 config.d Include，无法证明新增通配规则不会重复加载配置；请先检查根配置")
        }
        let missing = includes.filter { !existing.contains($0.lowercased()) }
        if missing.isEmpty { return data }
        var result = data
        let separator = insertion > 0 && data[insertion - 1] != 10 ? newline : ""
        result.replaceSubrange(insertion..<insertion, with: Data((separator + missing.joined(separator: newline) + newline).utf8))
        return result
    }

    /// `IdentitiesOnly yes` makes ssh offer only the configured IdentityFile, so turning it on
    /// without one would leave the host unable to authenticate with keys. An imported host that
    /// already had it on while inheriting its key (e.g. from `Host *`) stays editable unchanged.
    private func validateIdentitiesOnly(_ input: HostInput, existing: HostRecord?) throws {
        guard input.identitiesOnly == .yes,
              input.identityFile.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        if let existing,
           existing.option("IdentitiesOnly").flatMap(IdentitiesOnlyChoice.init(configValue:)) == .yes,
           existing.option("IdentityFile") == nil {
            return
        }
        throw ConfigEditError.invalid("开启 IdentitiesOnly 前，请先填写或选择 IdentityFile 密钥文件。开启后 SSH 只会使用这里指定的密钥，没有密钥将无法通过密钥认证。")
    }

    /// Only the managed shape may be written, and a host whose existing multiplexing lines are
    /// custom keeps them byte for byte: the form shows them read-only instead of normalising.
    private func validateConnectionReuse(_ input: HostInput, existing: HostRecord?) throws {
        let current = existing.map(ConnectionReuse.init(host:)) ?? .off
        switch input.connectionReuse {
        case .minutes(let minutes):
            guard ConnectionReuse.allowedMinutes.contains(minutes) else {
                throw ConfigEditError.invalid("连接复用的保留时间必须是 \(ConnectionReuse.allowedMinutes.lowerBound) 到 \(ConnectionReuse.allowedMinutes.upperBound) 分钟")
            }
            guard current.isManaged else {
                throw ConfigEditError.unsafe("此主机已有自定义的 ControlMaster/ControlPath/ControlPersist，请在源文件中修改")
            }
            // ssh expands `~` from the real home; `%C` is 40 hex characters; macOS caps socket paths at 104 bytes.
            let socketPath = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".ssh/cm/" + String(repeating: "0", count: 40)).path
            guard socketPath.utf8.count < 104 else {
                throw ConfigEditError.unsafe("用户目录路径过长，连接复用的 socket 路径会超过 macOS 的 104 字节限制")
            }
        case .off:
            guard current.isManaged else {
                throw ConfigEditError.unsafe("此主机已有自定义的 ControlMaster/ControlPath/ControlPersist，请在源文件中修改")
            }
        case .custom:
            guard current == input.connectionReuse else {
                throw ConfigEditError.invalid("不能通过表单写入自定义的连接复用设置")
            }
        }
    }

    /// OpenSSH separates a keyword from its value with whitespace (space or tab) or `=`.
    private func startsWithKeyword(_ lowercasedLine: String, _ keyword: String) -> Bool {
        guard lowercasedLine.hasPrefix(keyword),
              let next = lowercasedLine.dropFirst(keyword.count).first else { return false }
        return next == " " || next == "\t" || next == "="
    }

    private func validate(_ input: HostInput, requireHostName: Bool) throws {
        if let problem = HostFieldRules.aliasProblem(input.alias) { throw ConfigEditError.invalid(problem) }
        if requireHostName && input.hostName.isEmpty { throw ConfigEditError.invalid("请填写主机地址") }
        if let problem = HostFieldRules.hostNameProblem(input.hostName) { throw ConfigEditError.invalid(problem) }
        if let problem = HostFieldRules.portProblem(input.port) { throw ConfigEditError.invalid(problem) }
        if input.identityFile.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) ||
            input.identityFile.contains("#") || input.identityFile.contains("\"") || input.identityFile.contains("\\") {
            throw ConfigEditError.invalid("私钥路径包含不支持的字符")
        }
        if let problem = HostFieldRules.userProblem(input.user) { throw ConfigEditError.invalid(problem) }
        if let problem = HostFieldRules.proxyJumpProblem(input.proxyJump) { throw ConfigEditError.invalid(problem) }
    }

    private func render(_ input: HostInput, newline: String) -> String {
        let fields = [("HostName", input.hostName, false), ("User", input.user, false), ("Port", input.port, false),
                      ("IdentityFile", input.identityFile, true), ("IdentitiesOnly", input.identitiesOnly.rawValue, false),
                      ("ProxyJump", input.proxyJump, false)] +
            input.connectionReuse.desiredOptions.map { ($0.0, $0.1, false) }
        return (["Host \(input.alias)"] + fields.compactMap { key, value, allowsSpaces in
            value.isEmpty ? nil : "  \(key) \(allowsSpaces ? encodePath(value) : value)"
        }).joined(separator: newline) + newline
    }

    private func encodePath(_ value: String) -> String {
        value.contains(where: \.isWhitespace) ? "\"\(value)\"" : value
    }

    private func lineEnding(in data: Data) -> String {
        let bytes = Array(data)
        for index in bytes.indices where bytes[index] == 10 {
            return index > 0 && bytes[index - 1] == 13 ? "\r\n" : "\n"
        }
        return "\n"
    }

    private func patch(_ host: HostRecord, in data: Data, with input: HostInput) throws -> Data {
        guard host.byteRange.upperBound <= data.count else {
            throw ConfigEditError.conflict("Host 字节范围已变化，请重新载入")
        }
        let desired = [("HostName", input.hostName), ("User", input.user), ("Port", input.port),
                       ("IdentityFile", encodePath(input.identityFile)),
                       ("IdentitiesOnly", input.identitiesOnly.rawValue), ("ProxyJump", input.proxyJump)] +
            input.connectionReuse.desiredOptions
        let lines = byteLines(in: data)
        var edits: [(range: Range<Int>, replacement: Data)] = []
        var additions: [String] = []
        for (name, value) in desired {
            let options = host.explicitOptions.filter { $0.keyword.caseInsensitiveCompare(name) == .orderedSame }
            guard options.count <= 1 else {
                throw ConfigEditError.unsafe("Host 块内有重复的 \(name)，无法安全编辑")
            }
            guard let option = options.first else {
                if !value.isEmpty { additions.append("  \(name) \(value)") }
                continue
            }
            if name == "IdentitiesOnly" {
                // Compare meaning, not spelling, so an unchanged `True`/`YES` keeps its original bytes.
                guard let existingChoice = IdentitiesOnlyChoice(configValue: option.arguments.joined(separator: " ")) else {
                    throw ConfigEditError.unsafe("IdentitiesOnly 的原值无法识别，请在源文件中编辑")
                }
                if existingChoice == input.identitiesOnly { continue }
            }
            if name == "ControlMaster",
               option.arguments.joined(separator: " ").caseInsensitiveCompare(value) == .orderedSame { continue }
            if name == "ControlPersist", !value.isEmpty,
               ConnectionReuse.persistSeconds(option.arguments.joined(separator: " ")) ==
                ConnectionReuse.persistSeconds(value) { continue }
            let existingValue = name.caseInsensitiveCompare("IdentityFile") == .orderedSame
                ? option.arguments.first ?? ""
                : option.arguments.joined(separator: " ")
            let desiredValue = name.caseInsensitiveCompare("IdentityFile") == .orderedSame
                ? input.identityFile
                : value
            if existingValue == desiredValue { continue }
            guard let line = lines.first(where: { $0.number == option.line }),
                  line.range.lowerBound >= host.byteRange.lowerBound,
                  line.range.upperBound <= host.byteRange.upperBound else {
                throw ConfigEditError.conflict("无法定位 \(name) 的原始行")
            }
            edits.append((line.range, try rewrite(line: line.text, keyword: name, value: value)))
        }
        if !additions.isEmpty {
            // Insert right after the block's last option line, not at the end of its byte range:
            // the range also holds trailing blank lines and the next block's leading comments.
            let newline = lineEnding(in: data)
            let lastNumber = max(host.sourceLine, host.explicitOptions.map(\.line).max() ?? host.sourceLine)
            guard let lastLine = lines.first(where: { $0.number == lastNumber }),
                  lastLine.range.lowerBound >= host.byteRange.lowerBound,
                  lastLine.range.upperBound <= host.byteRange.upperBound else {
                throw ConfigEditError.conflict("无法定位 Host 的最后一行，请重新载入")
            }
            // Swift treats "\r\n" as one Character, so `hasSuffix("\n")` is false for CRLF lines.
            let endsWithNewline = lastLine.text.hasSuffix("\n") || lastLine.text.hasSuffix("\r\n")
            let prefix = endsWithNewline ? "" : newline
            edits.append((lastLine.range.upperBound..<lastLine.range.upperBound,
                          Data((prefix + additions.joined(separator: newline) + newline).utf8)))
        }
        var result = data
        for edit in edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            result.replaceSubrange(edit.range, with: edit.replacement)
        }
        return result
    }

    private func rewrite(line: String, keyword: String, value: String) throws -> Data {
        let newline: String = line.hasSuffix("\r\n") ? "\r\n" : line.hasSuffix("\n") ? "\n" : ""
        let content = String(line.dropLast(newline.count))
        guard let keywordRange = content.range(of: keyword, options: [.caseInsensitive, .anchored],
                                               range: content.startIndex..<content.endIndex) ??
                content.range(of: keyword, options: .caseInsensitive) else {
            throw ConfigEditError.unsafe("无法识别原始字段行")
        }
        var cursor = keywordRange.upperBound
        while cursor < content.endIndex && content[cursor].isWhitespace { cursor = content.index(after: cursor) }
        if cursor < content.endIndex && content[cursor] == "=" { cursor = content.index(after: cursor) }
        while cursor < content.endIndex && content[cursor].isWhitespace { cursor = content.index(after: cursor) }
        let prefix = String(content[..<cursor])
        let oldValue = String(content[cursor...])
        guard !oldValue.contains("\""), !oldValue.contains("\\") else {
            throw ConfigEditError.unsafe("原始字段含引号或转义，请在源文件中编辑")
        }
        let commentIndex = oldValue.indices.first { index in
            oldValue[index] == "#" && index > oldValue.startIndex &&
                oldValue[oldValue.index(before: index)].isWhitespace
        }
        let suffix: String
        if let commentIndex {
            let beforeComment = oldValue[..<commentIndex]
            let spaces = beforeComment.reversed().prefix(while: \.isWhitespace).reversed()
            suffix = String(spaces) + String(oldValue[commentIndex...])
        } else {
            suffix = String(oldValue.reversed().prefix(while: \.isWhitespace).reversed())
        }
        guard !value.isEmpty || commentIndex == nil else {
            throw ConfigEditError.unsafe("字段带有行尾注释，不能直接删除；请在源文件中编辑")
        }
        return value.isEmpty ? Data() : Data((prefix + value + suffix + newline).utf8)
    }

    private func byteLines(in data: Data) -> [(number: Int, range: Range<Int>, text: String)] {
        let bytes = Array(data)
        var lines: [(Int, Range<Int>, String)] = []
        var start = 0
        var number = 1
        for index in bytes.indices where bytes[index] == 10 {
            lines.append((number, start..<(index + 1), String(decoding: bytes[start...index], as: UTF8.self)))
            start = index + 1
            number += 1
        }
        if start < bytes.count {
            lines.append((number, start..<bytes.count, String(decoding: bytes[start..<bytes.count], as: UTF8.self)))
        }
        return lines
    }
}

extension ConfigWriter {
    /// Shows a path under the user's home as `~/...`, the form OpenSSH configs usually use.
    package static func displayPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// Plans `IdentityFile <key>` and `IdentitiesOnly yes` for a host after the key-only login
    /// check succeeded. Only bytes of those two keywords change; complex or read-only hosts
    /// throw so the caller shows `KeyDeployment.configSnippet` instead.
    package func planKeyLogin(_ proof: VerifiedKeyLogin, hostID: String, mode: IdentityFileUpdateMode,
                              from scan: ConfigScan) throws -> ConfigChangePlan {
        guard scan.rootURL.standardizedFileURL == rootURL else {
            throw ConfigEditError.invalid("配置快照与当前项目路径不一致，请重新载入")
        }
        let host = try editableHost(hostID, in: scan)
        guard host.alias == proof.alias else {
            throw ConfigEditError.invalid("验证结果属于主机 \(proof.alias)，不能写入 \(host.alias)")
        }
        let root = try SafeFileIO.snapshot(at: rootURL)
        guard root.version.sha256 == scan.sources.first(where: { $0.url == rootURL })?.sha256 else {
            throw ConfigEditError.conflict("主配置自上次载入后已变化，请重新载入")
        }
        try checkSSHDirectory()
        let current = try SafeFileIO.snapshot(at: host.sourceURL)
        guard current.version.sha256 == scan.sources.first(where: { $0.url == host.sourceURL })?.sha256 else {
            throw ConfigEditError.conflict("主机源文件已变化，请重新载入")
        }
        let data = current.data ?? Data()
        guard host.byteRange.upperBound <= data.count else {
            throw ConfigEditError.conflict("Host 字节范围已变化，请重新载入")
        }
        let path = Self.displayPath(proof.privateKeyURL.path)
        guard !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !path.contains("#"), !path.contains("\""), !path.contains("\\") else {
            throw ConfigEditError.invalid("私钥路径包含不支持的字符")
        }
        let lines = byteLines(in: data)
        func line(for option: ConfigOption) throws -> (number: Int, range: Range<Int>, text: String) {
            guard let line = lines.first(where: { $0.number == option.line }),
                  line.range.lowerBound >= host.byteRange.lowerBound,
                  line.range.upperBound <= host.byteRange.upperBound else {
                throw ConfigEditError.conflict("无法定位 \(option.keyword) 的原始行")
            }
            return line
        }
        var edits: [(range: Range<Int>, replacement: Data)] = []
        var additions: [String] = []

        let identityFiles = host.explicitOptions.filter { $0.keyword.caseInsensitiveCompare("IdentityFile") == .orderedSame }
        let expanded = { (value: String) -> String in
            value.hasPrefix("~/") ? FileManager.default.homeDirectoryForCurrentUser.path + value.dropFirst(1) : value
        }
        let alreadyListed = identityFiles.contains { expanded($0.arguments.first ?? "") == proof.privateKeyURL.path }
        switch mode {
        case .replace:
            if identityFiles.count > 1 {
                throw ConfigEditError.unsafe("此主机有多行 IdentityFile，无法确定替换哪一行；请选择“追加”")
            }
            if let existing = identityFiles.first {
                if !alreadyListed {
                    edits.append((try line(for: existing).range,
                                  try rewrite(line: try line(for: existing).text, keyword: "IdentityFile", value: encodePath(path))))
                }
            } else {
                additions.append("  IdentityFile \(encodePath(path))")
            }
        case .append:
            if !alreadyListed { additions.append("  IdentityFile \(encodePath(path))") }
        }

        let identitiesOnly = host.explicitOptions.filter { $0.keyword.caseInsensitiveCompare("IdentitiesOnly") == .orderedSame }
        guard identitiesOnly.count <= 1 else {
            throw ConfigEditError.unsafe("Host 块内有重复的 IdentitiesOnly，无法安全编辑")
        }
        if let existing = identitiesOnly.first {
            guard let choice = IdentitiesOnlyChoice(configValue: existing.arguments.joined(separator: " ")) else {
                throw ConfigEditError.unsafe("IdentitiesOnly 的原值无法识别，请在源文件中编辑")
            }
            if choice != .yes {
                edits.append((try line(for: existing).range,
                              try rewrite(line: try line(for: existing).text, keyword: "IdentitiesOnly", value: "yes")))
            }
        } else {
            additions.append("  IdentitiesOnly yes")
        }

        if !additions.isEmpty {
            let newline = lineEnding(in: data)
            let lastNumber = max(host.sourceLine, host.explicitOptions.map(\.line).max() ?? host.sourceLine)
            guard let lastLine = lines.first(where: { $0.number == lastNumber }),
                  lastLine.range.lowerBound >= host.byteRange.lowerBound,
                  lastLine.range.upperBound <= host.byteRange.upperBound else {
                throw ConfigEditError.conflict("无法定位 Host 的最后一行，请重新载入")
            }
            let endsWithNewline = lastLine.text.hasSuffix("\n") || lastLine.text.hasSuffix("\r\n")
            edits.append((lastLine.range.upperBound..<lastLine.range.upperBound,
                          Data(((endsWithNewline ? "" : newline) + additions.joined(separator: newline) + newline).utf8)))
        }
        guard !edits.isEmpty else { throw ConfigEditError.invalid("此主机已配置这把密钥，无需修改") }
        var after = data
        for edit in edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            after.replaceSubrange(edit.range, with: edit.replacement)
        }
        var plan = ConfigChangePlan(title: "为 \(host.alias) 配置密钥登录", targetAlias: host.alias,
                                    checkedVersions: [root.version, current.version],
                                    changes: [PlannedFileChange(url: host.sourceURL, before: current.data,
                                                                after: after, expectedVersion: current.version)])
        plan.warnings = ["只修改此 Host 块中的 IdentityFile 与 IdentitiesOnly；服务器端的密码登录不会被关闭。"]
        return plan
    }
}

extension ConfigWriter {
    /// Plans writing a decrypted snapshot or an import back into `~/.ssh`.
    ///
    /// Only files that stay inside `~/.ssh` are touched, with the same limits as a plaintext
    /// snapshot restore: the main `config`, managed `config.d` files, files the current config
    /// statically Includes, or new files whose names are not keys or OpenSSH state. Entries that
    /// came from outside `~/.ssh`, and any file the archive does not contain, are left alone.
    ///
    /// `includeRoot: false` leaves the current main `config` alone and writes only the other files
    /// (used when importing hosts into a setup that should keep its own global settings).
    package func planArchiveRestore(_ archive: BackupArchive, title: String, includeRoot: Bool = true) throws -> ConfigChangePlan {
        try checkSSHDirectory()
        let sshDirectory = rootURL.deletingLastPathComponent().standardizedFileURL
        var restorable = archive.entries.filter { !$0.isExternal }
        guard restorable.filter({ $0.path == "config" }).count == 1 else {
            throw ConfigEditError.unsafe("备份缺少唯一的主配置文件，不能自动恢复")
        }
        if !includeRoot { restorable.removeAll { $0.path == "config" } }
        guard !restorable.isEmpty else { throw ConfigEditError.invalid("除主配置外没有可导入的文件") }
        let currentSources = Set(ConfigReader(rootURL: rootURL).scan().sources.map { $0.url.standardizedFileURL.path })
        var versions: [FileVersion] = []
        var changes: [PlannedFileChange] = []
        var destinations: Set<String> = []
        for entry in restorable {
            try validateArchiveRelativePath(entry.path)
            guard entry.content.count <= 16 * 1_024 * 1_024 else {
                throw ConfigEditError.unsafe("备份中的文件超过大小限制：\(entry.path)")
            }
            let target = entry.path == "config" ? rootURL : sshDirectory.appendingPathComponent(entry.path).standardizedFileURL
            if entry.path != "config" { try validateImportedFilePath(entry.path) }
            guard destinations.insert(target.path.lowercased()).inserted,
                  target == rootURL || target.path.hasPrefix(sshDirectory.path + "/") else {
                throw ConfigEditError.unsafe("备份中的路径重复或超出 ~/.ssh：\(entry.path)")
            }
            if target != rootURL {
                try validateWritableSource(target)
                try validateSnapshotDestination(target, currentSources: currentSources)
            }
            let current = try SafeFileIO.snapshot(at: target)
            versions.append(current.version)
            if current.data != entry.content {
                changes.append(PlannedFileChange(url: target, before: current.data, after: entry.content,
                                                 expectedVersion: current.version))
            }
        }
        guard !changes.isEmpty else { throw ConfigEditError.invalid("备份内容与当前配置完全一致，无需恢复") }
        // Included files first, the root last, so a failed write never leaves a root that points at
        // files that were not restored.
        changes.sort { lhs, rhs in
            if lhs.url == rootURL { return false }
            if rhs.url == rootURL { return true }
            return lhs.url.path < rhs.url.path
        }
        var plan = ConfigChangePlan(title: title, targetAlias: nil, checkedVersions: versions, changes: changes)
        var warnings = ["只写入备份中的配置文件；不会删除备份之外新增的文件，也不会恢复私钥或 known_hosts。"]
        let external = archive.entries.filter(\.isExternal).count
        if external > 0 { warnings.append("备份中有 \(external) 个位于 ~/.ssh 之外的 Include 文件，不会被恢复，需要时请手动处理。") }
        plan.warnings = warnings
        return plan
    }

    /// Besides the safety rules above, only `config.d/` hosts and files beside `config` that are not
    /// key or OpenSSH-state names come from an archive.
    private func validateImportedFilePath(_ path: String) throws {
        let lowered = path.lowercased()
        let name = (lowered as NSString).lastPathComponent
        let reserved = name.hasPrefix("authorized_keys") || name.hasPrefix("known_hosts") || name.hasPrefix("id_") ||
            name.hasSuffix(".pub") || name.hasSuffix(".pem") || name.hasSuffix(".key") || ["environment", "rc"].contains(name)
        guard !reserved, !name.hasPrefix(".") else {
            throw ConfigEditError.unsafe("备份中包含密钥或 OpenSSH 状态文件，已拒绝：\(path)")
        }
    }

    private func validateArchiveRelativePath(_ path: String) throws {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0"),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw ConfigEditError.unsafe("备份包含无效的相对路径：\(path)")
        }
    }
}
