import Foundation

/// Host-level `IdentitiesOnly`. `.unset` writes nothing and inherits OpenSSH's default (no).
package enum IdentitiesOnlyChoice: String, CaseIterable, Sendable {
    case unset = ""
    case yes
    case no

    /// Maps an OpenSSH flag value; returns nil for anything ssh would not accept as a flag.
    package init?(configValue: String) {
        switch configValue.trimmingCharacters(in: .whitespaces).lowercased() {
        case "": self = .unset
        case "yes", "true": self = .yes
        case "no", "false": self = .no
        default: return nil
        }
    }
}

/// Host-level OpenSSH connection multiplexing managed by ConfigSSH.
///
/// ConfigSSH writes exactly `ControlMaster auto`, `ControlPath ~/.ssh/cm/%C` and
/// `ControlPersist <n>m` with `n` in `ConnectionReuse.allowedMinutes`. Anything else already
/// present is `.custom` and left untouched, so the form never rewrites a user's own setup.
package enum ConnectionReuse: Equatable, Sendable {
    case off
    case minutes(Int)
    /// Some of the three keywords exist with values ConfigSSH does not manage.
    case custom(String)

    package static let allowedMinutes = 1...60
    package static let defaultMinutes = 10
    package static let presetMinutes = [5, 10, 30, 60]
    package static let controlPath = "~/.ssh/cm/%C"
    package static let keywords = ["ControlMaster", "ControlPath", "ControlPersist"]

    package init(host: HostRecord) {
        let values = Self.keywords.map { keyword in
            host.explicitOptions.filter { $0.keyword.caseInsensitiveCompare(keyword) == .orderedSame }
        }
        if values.allSatisfy(\.isEmpty) { self = .off; return }
        let summary = zip(Self.keywords, values).compactMap { keyword, options in
            options.isEmpty ? nil : options.map { "\(keyword) \($0.arguments.joined(separator: " "))" }
                .joined(separator: "，")
        }.joined(separator: "，")
        guard values.allSatisfy({ $0.count == 1 }),
              values[0][0].arguments.joined(separator: " ").lowercased() == "auto",
              values[1][0].arguments.joined(separator: " ") == Self.controlPath,
              let seconds = Self.persistSeconds(values[2][0].arguments.joined(separator: " ")),
              seconds % 60 == 0, Self.allowedMinutes.contains(seconds / 60) else {
            self = .custom(summary)
            return
        }
        self = .minutes(seconds / 60)
    }

    package var isManaged: Bool {
        if case .custom = self { return false }
        return true
    }

    /// Desired `(keyword, value)` pairs; an empty value removes the line.
    package var desiredOptions: [(String, String)] {
        switch self {
        case .off: return Self.keywords.map { ($0, "") }
        case .minutes(let minutes):
            return [("ControlMaster", "auto"), ("ControlPath", Self.controlPath), ("ControlPersist", "\(minutes)m")]
        case .custom: return []
        }
    }

    package var displayText: String? {
        switch self {
        case .off: return nil
        case .minutes(let minutes): return "已开启 · 最后一个会话关闭后保留 \(minutes) 分钟"
        case .custom(let summary): return "自定义：\(summary)"
        }
    }

    /// Parses an OpenSSH time value (`600`, `10m`, `1h30m`). `yes`, `no` and `0` return nil:
    /// they mean "forever" or "no background master" and are outside the managed range.
    package static func persistSeconds(_ raw: String) -> Int? {
        let text = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !text.isEmpty else { return nil }
        var total = 0
        var number = ""
        for character in text {
            if character.isASCII, character.isNumber {
                number.append(character)
                guard number.count <= 7 else { return nil }
                continue
            }
            let multiplier: Int
            switch character {
            case "s": multiplier = 1
            case "m": multiplier = 60
            case "h": multiplier = 3600
            case "d": multiplier = 86_400
            case "w": multiplier = 604_800
            default: return nil
            }
            guard let value = Int(number) else { return nil }
            total += value * multiplier
            number = ""
        }
        if !number.isEmpty {
            guard let value = Int(number) else { return nil }
            total += value
        }
        return total > 0 ? total : nil
    }
}

/// How the wizard records a verified key on a host that already has `IdentityFile` lines.
package enum IdentityFileUpdateMode: Sendable {
    /// Replace the single existing `IdentityFile` (or add one if there is none).
    case replace
    /// Keep existing `IdentityFile` lines and add this one after them.
    case append
}

package struct HostInput: Equatable {
    package var alias: String
    package var hostName: String
    package var user: String
    package var port: String
    package var identityFile: String
    package var proxyJump: String
    package var group: String
    package var identitiesOnly: IdentitiesOnlyChoice
    package var connectionReuse: ConnectionReuse
    /// Optional name shown in lists and used for the new config file's name. It is not an
    /// OpenSSH option and is only read when a host is added; empty means "use the alias".
    package var displayName: String

    package init(
        alias: String = "",
        hostName: String = "",
        user: String = "",
        port: String = "22",
        identityFile: String = "",
        proxyJump: String = "",
        group: String = "",
        identitiesOnly: IdentitiesOnlyChoice = .unset,
        connectionReuse: ConnectionReuse = .off,
        displayName: String = ""
    ) {
        self.alias = alias
        self.hostName = hostName
        self.user = user
        self.port = port
        self.identityFile = identityFile
        self.proxyJump = proxyJump
        self.group = group
        self.identitiesOnly = identitiesOnly
        self.connectionReuse = connectionReuse
        self.displayName = displayName
    }

    package init(host: HostRecord) {
        self.init(
            alias: host.alias,
            hostName: host.hostName ?? "",
            user: host.user ?? "",
            port: host.port ?? "",
            identityFile: host.option("IdentityFile") ?? "",
            proxyJump: host.option("ProxyJump") ?? "",
            group: host.configGroup ?? "",
            identitiesOnly: host.option("IdentitiesOnly").flatMap(IdentitiesOnlyChoice.init(configValue:)) ?? .unset,
            connectionReuse: ConnectionReuse(host: host)
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
    /// A private directory (mode 0700) created under `~/.ssh` before the changes are applied,
    /// used for the connection-reuse `ControlPath` sockets.
    package var privateDirectory: URL?
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

/// Rules for the name a new host's config file gets (display name, else alias).
package enum HostFileName {
    package static let maxLength = 80

    /// The stem used for `<stem>.conf`: the trimmed display name when given, else the alias.
    package static func stem(displayName: String, alias: String) -> String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? alias : trimmed
    }

    /// Why `name` cannot be a file name, or nil. Unicode (e.g. Chinese) and inner spaces are fine.
    package static func problem(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count > maxLength { return "显示名称最多 \(maxLength) 个字符" }
        if trimmed.hasPrefix(".") { return "显示名称不能以点开头（会变成隐藏文件）" }
        let forbidden = CharacterSet(charactersIn: "/\\:\"*?<>|")
        if trimmed.unicodeScalars.contains(where: { forbidden.contains($0) || CharacterSet.controlCharacters.contains($0) }) {
            return "显示名称不能包含 / \\ : \" * ? < > | 或控制字符，因为它会用作配置文件名"
        }
        return nil
    }
}

/// The rules the host form checks while typing and again when saving, so a field is flagged
/// as soon as it is wrong and the saved result can never disagree with the hint.
package enum HostFieldRules {
    private static let aliasCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
    private static let hostCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-")

    package static func aliasProblem(_ alias: String) -> String? {
        guard let first = alias.unicodeScalars.first,
              CharacterSet.alphanumerics.contains(first),
              alias.unicodeScalars.allSatisfy({ aliasCharacters.contains($0) }) else {
            return "Host 别名只能包含英文字母、数字、点、下划线和短横线，并以字母或数字开头"
        }
        return nil
    }

    package static func hostNameProblem(_ hostName: String) -> String? {
        if !hostName.isEmpty && !hostName.unicodeScalars.allSatisfy({ hostCharacters.contains($0) }) {
            return "主机地址包含不支持的字符（可用字母、数字、点、冒号、下划线、短横线）"
        }
        return nil
    }

    package static func portProblem(_ port: String) -> String? {
        if !port.isEmpty && !(Int(port).map { (1...65535).contains($0) } ?? false) {
            return "端口必须是 1 到 65535 的整数"
        }
        return nil
    }

    package static func userProblem(_ user: String) -> String? {
        if user.contains(where: \.isWhitespace) { return "用户名不能包含空白字符" }
        if user.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) || user.contains("#") ||
            user.contains("\"") || user.contains("\\") { return "用户名包含不支持的字符" }
        return nil
    }

    package static func proxyJumpProblem(_ value: String) -> String? {
        if value.contains(where: \.isWhitespace) { return "跳板机不能包含空白字符；多台请用逗号分隔" }
        if value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) || value.contains("#") ||
            value.contains("\"") || value.contains("\\") { return "跳板机包含不支持的字符" }
        return nil
    }
}
