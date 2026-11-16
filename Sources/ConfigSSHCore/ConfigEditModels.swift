import Foundation

package struct HostInput: Equatable {
    package var alias: String
    package var hostName: String
    package var user: String
    package var port: String
    package var identityFile: String
    package var proxyJump: String
    package var group: String

    package init(
        alias: String = "",
        hostName: String = "",
        user: String = "",
        port: String = "22",
        identityFile: String = "",
        proxyJump: String = "",
        group: String = ""
    ) {
        self.alias = alias
        self.hostName = hostName
        self.user = user
        self.port = port
        self.identityFile = identityFile
        self.proxyJump = proxyJump
        self.group = group
    }

    package init(host: HostRecord) {
        self.init(
            alias: host.alias,
            hostName: host.hostName ?? "",
            user: host.user ?? "",
            port: host.port ?? "",
            identityFile: host.option("IdentityFile") ?? "",
            proxyJump: host.option("ProxyJump") ?? "",
            group: host.configGroup ?? ""
        )
    }
}

package enum ConfigEditAction {
    case add(HostInput)
    case update(hostID: String, input: HostInput)
    case delete(hostID: String)
}

package enum ConfigEditError: LocalizedError {
    case invalid(String)
    case unsafe(String)
    case conflict(String)
    case io(String)

    package var errorDescription: String? {
        switch self {
        case .invalid(let message), .unsafe(let message), .conflict(let message), .io(let message): message
        }
    }
}

package struct FileVersion: Equatable, Sendable {
    package let path: String
    package let exists: Bool
    package let fileID: UInt64?
    package let size: Int?
    package let modificationSeconds: Int64?
    package let modificationNanoseconds: Int64?
    package let mode: Int?
    package let sha256: String?
}

package struct PlannedFileChange: Sendable {
    package let url: URL
    package let before: Data?
    package let after: Data?
    package let expectedVersion: FileVersion
    package let desiredMode: Int?

    package init(url: URL, before: Data?, after: Data?, expectedVersion: FileVersion, desiredMode: Int? = nil) {
        self.url = url
        self.before = before
        self.after = after
        self.expectedVersion = expectedVersion
        self.desiredMode = desiredMode
    }

    package var diff: String {
        LineDiff.render(before: before ?? Data(), after: after ?? Data())
    }
}

package struct ConfigChangePlan: Sendable {
    package let title: String
    package let targetAlias: String?
    package let checkedVersions: [FileVersion]
    package let changes: [PlannedFileChange]
    package var warnings: [String] = []
}

private enum LineDiff {
    private struct Line {
        let marker: Character
        let text: String
    }

    static func render(before: Data, after: Data) -> String {
        if before == after { return "无文本变化" }
        let old = lines(in: before)
        let new = lines(in: after)
        if old == new { return "文本行相同，但文件的行尾格式或末尾换行已改变。" }
        let difference = new.difference(from: old)
        let removals = Set(difference.removals.compactMap { change -> Int? in
            if case .remove(let offset, _, _) = change { return offset }
            return nil
        })
        let insertions = Set(difference.insertions.compactMap { change -> Int? in
            if case .insert(let offset, _, _) = change { return offset }
            return nil
        })
        var operations: [Line] = []
        var oldIndex = 0
        var newIndex = 0
        while oldIndex < old.count || newIndex < new.count {
            if oldIndex < old.count && removals.contains(oldIndex) {
                operations.append(Line(marker: "-", text: old[oldIndex]))
                oldIndex += 1
            } else if newIndex < new.count && insertions.contains(newIndex) {
                operations.append(Line(marker: "+", text: new[newIndex]))
                newIndex += 1
            } else if oldIndex < old.count && newIndex < new.count && old[oldIndex] == new[newIndex] {
                operations.append(Line(marker: " ", text: old[oldIndex]))
                oldIndex += 1
                newIndex += 1
            } else if oldIndex < old.count {
                operations.append(Line(marker: "-", text: old[oldIndex]))
                oldIndex += 1
            } else {
                operations.append(Line(marker: "+", text: new[newIndex]))
                newIndex += 1
            }
        }
        let changed = operations.indices.filter { operations[$0].marker != " " }
        var ranges: [Range<Int>] = []
        for index in changed {
            let start = max(0, index - 3)
            let end = min(operations.count, index + 4)
            if let last = ranges.last, start <= last.upperBound {
                ranges[ranges.count - 1] = last.lowerBound..<max(last.upperBound, end)
            } else {
                ranges.append(start..<end)
            }
        }
        var rendered: [String] = []
        for range in ranges {
            let prefix = operations[..<range.lowerBound]
            let fragment = operations[range]
            let oldStart = prefix.filter { $0.marker != "+" }.count + 1
            let newStart = prefix.filter { $0.marker != "-" }.count + 1
            let oldCount = fragment.filter { $0.marker != "+" }.count
            let newCount = fragment.filter { $0.marker != "-" }.count
            rendered.append("@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@")
            rendered += fragment.map { "\($0.marker)\($0.text)" }
        }
        return rendered.joined(separator: "\n")
    }

    private static func lines(in data: Data) -> [String] {
        guard !data.isEmpty else { return [] }
        var lines = data.split(separator: 10, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        if data.last == 10 { lines.removeLast() }
        return lines.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
    }
}

package struct GroupDeletionPlan {
    package let name: String
    package let directoryURL: URL?
    package let movedHosts: [HostRecord]
    package let changePlan: ConfigChangePlan?
}

package struct GlobalConfigParameter: Identifiable {
    package let keyword: String
    package let description: String
    package let example: String

    package var id: String { keyword }
}

package enum GlobalConfigCatalog {
    package static let options: [GlobalConfigParameter] = [
        .init(keyword: "User", description: "未单独指定主机用户时使用的默认用户名。", example: "deploy"),
        .init(keyword: "Port", description: "未单独指定端口时使用的默认 SSH 端口。", example: "22"),
        .init(keyword: "IdentityFile", description: "默认私钥路径；主机配置可追加其他密钥。", example: "~/.ssh/id_ed25519"),
        .init(keyword: "IdentitiesOnly", description: "限制 ssh 只尝试显式配置的身份文件。", example: "yes"),
        .init(keyword: "AddKeysToAgent", description: "控制使用的私钥是否添加到 ssh-agent。", example: "yes"),
        .init(keyword: "UseKeychain", description: "在 macOS 上配合 ssh-agent 使用钥匙串。", example: "yes"),
        .init(keyword: "ServerAliveInterval", description: "无数据时发送保活消息的间隔秒数；0 表示不发送。", example: "60"),
        .init(keyword: "ServerAliveCountMax", description: "连续保活无响应后断开的次数。", example: "3"),
        .init(keyword: "ConnectTimeout", description: "建立连接的超时秒数。", example: "15"),
        .init(keyword: "TCPKeepAlive", description: "是否启用 TCP 层保活。", example: "yes"),
        .init(keyword: "ForwardAgent", description: "是否将本地 ssh-agent 转发到远端。", example: "no"),
        .init(keyword: "StrictHostKeyChecking", description: "控制服务器主机密钥校验策略。", example: "ask"),
        .init(keyword: "Compression", description: "是否压缩 SSH 连接数据。", example: "no"),
        .init(keyword: "LogLevel", description: "SSH 客户端日志详细程度。", example: "ERROR")
    ]

    package static func parameter(_ keyword: String) -> GlobalConfigParameter? {
        options.first { $0.keyword.caseInsensitiveCompare(keyword) == .orderedSame }
    }
}

package struct BackupRecord: Codable, Identifiable {
    package let id: UUID
    package let sourcePath: String
    package let backupPath: String?
    package let beforeHash: String?
    package let afterHash: String?
    package let originalMode: Int?
    package let originalModificationDate: Date?
    package let createdAt: Date
    package let reason: String
}

package struct CommitReceipt {
    package let backups: [BackupRecord]
    package let changedPaths: [String]
}
