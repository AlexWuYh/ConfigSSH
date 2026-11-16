import CryptoKit
import Darwin
import Foundation

package struct ConfigReader {
    package let rootURL: URL

    package init(rootURL: URL = ConfigSSHPaths.rootURL) {
        self.rootURL = rootURL.standardizedFileURL
    }

    package func scan() -> ConfigScan {
        guard FileManager.default.fileExists(atPath: rootURL.path) else {
            return ConfigScan(rootURL: rootURL, availability: .missing, hosts: [], globalOptions: [], rules: [], issues: [], sources: [])
        }

        var context = ScanContext(rootURL: rootURL)
        let readRoot = context.visit(rootURL, conditional: false)
        context.markDuplicateAliases()
        return ConfigScan(
            rootURL: rootURL,
            availability: readRoot ? .available : .unreadable(context.rootFailure ?? "无法读取 SSH 配置"),
            hosts: context.hosts.sorted { $0.sourceOrder < $1.sourceOrder },
            globalOptions: context.globalOptions,
            rules: context.rules,
            issues: context.issues,
            sources: context.sources.values.sorted { $0.url.path < $1.url.path }
        )
    }

    package func preview(rootData: Data) -> ConfigScan {
        var context = ScanContext(rootURL: rootURL)
        let readRoot = context.visit(rootURL, conditional: false, rootReplacement: rootData)
        context.markDuplicateAliases()
        return ConfigScan(rootURL: rootURL,
                          availability: readRoot ? .available : .unreadable(context.rootFailure ?? "无法解析主配置"),
                          hosts: context.hosts.sorted { $0.sourceOrder < $1.sourceOrder },
                          globalOptions: context.globalOptions, rules: context.rules, issues: context.issues,
                          sources: context.sources.values.sorted { $0.url.path < $1.url.path })
    }
}

private struct SourceLine {
    let number: Int
    let start: Int
    let text: String
}

private struct Directive {
    let keyword: String
    let arguments: [String]
    let rawValue: String
}

private enum ParsedLine {
    case empty
    case directive(Directive)
    case invalid(String)
}

private struct HostDraft {
    let alias: String
    let sourceOrder: Int
    let sourceURL: URL
    let sourceLine: Int
    let start: Int
    var options: [ConfigOption] = []
    var readOnlyReasons: [String] = []
}

private struct ScanContext {
    let rootURL: URL
    let sshDirectory: URL
    var hosts: [HostRecord] = []
    var globalOptions: [GlobalOptionRecord] = []
    var rules: [ConfigRule] = []
    var issues: [ConfigIssue] = []
    var sources: [String: SourceFileSnapshot] = [:]
    var rootFailure: String?
    private var nextHostOrder = 0
    private var visitedFileCount = 0
    private var visitLimitReported = false
    private var activePaths: [String] = []

    init(rootURL: URL) {
        self.rootURL = rootURL
        self.sshDirectory = rootURL.deletingLastPathComponent()
    }

    @discardableResult
    mutating func visit(_ url: URL, conditional: Bool, rootReplacement: Data? = nil) -> Bool {
        let sourceURL = url.standardizedFileURL
        guard visitedFileCount < 512 else {
            if !visitLimitReported {
                report(sourceURL, nil, "Include 展开超过 512 个文件，已停止扫描")
                visitLimitReported = true
            }
            return false
        }
        visitedFileCount += 1
        let resolvedPath = sourceURL.resolvingSymlinksInPath().path
        if activePaths.contains(resolvedPath) {
            report(sourceURL, nil, "检测到 Include 循环，已跳过此文件")
            return false
        }
        if activePaths.count >= 32 {
            report(sourceURL, nil, "Include 嵌套超过 32 层，已停止展开")
            return false
        }

        let data: Data
        do {
            data = try rootReplacement ?? Data(contentsOf: sourceURL)
        } catch {
            let message = "无法读取配置文件：\(error.localizedDescription)"
            report(sourceURL, nil, message)
            if sourceURL == rootURL { rootFailure = message }
            return false
        }
        guard String(data: data, encoding: .utf8) != nil else {
            let message = "配置文件不是有效的 UTF-8，已跳过此文件"
            report(sourceURL, nil, message)
            if sourceURL == rootURL { rootFailure = message }
            return false
        }

        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        sources[sourceURL.path] = SourceFileSnapshot(url: sourceURL, data: data, sha256: digest)
        activePaths.append(resolvedPath)
        defer { activePaths.removeLast() }
        parse(data, sourceURL: sourceURL, conditional: conditional)
        return true
    }

    private mutating func parse(_ data: Data, sourceURL: URL, conditional: Bool) {
        var draft: HostDraft?
        var inMatch = false

        for line in makeLines(data) {
            let directive: Directive
            switch parseDirective(line.text) {
            case .empty:
                continue
            case .invalid(let reason):
                report(sourceURL, line.number, reason, severity: .error)
                draft?.readOnlyReasons.append("Host 块中有无法解析的指令，无法安全编辑")
                continue
            case .directive(let parsed):
                directive = parsed
            }
            switch directive.keyword.lowercased() {
            case "host":
                finish(&draft, at: line.start)
                inMatch = false
                if directive.arguments.isEmpty {
                    report(sourceURL, line.number, "Host 缺少匹配模式", severity: .error)
                    continue
                }
                if directive.arguments.count == 1,
                   let alias = directive.arguments.first,
                   !alias.contains(where: { "*!?[]".contains($0) || $0.isWhitespace }) {
                    draft = HostDraft(
                        alias: alias,
                        sourceOrder: nextHostOrder,
                        sourceURL: sourceURL,
                        sourceLine: line.number,
                        start: line.start,
                        readOnlyReasons: conditional ? ["此文件由条件 Include 引入，无法安全编辑"] : []
                    )
                    nextHostOrder += 1
                } else {
                    rules.append(ConfigRule(
                        kind: .hostPattern,
                        expression: directive.rawValue,
                        sourceURL: sourceURL,
                        line: line.number
                    ))
                }

            case "match":
                finish(&draft, at: line.start)
                inMatch = true
                if directive.arguments.isEmpty {
                    report(sourceURL, line.number, "Match 缺少匹配条件", severity: .error)
                    continue
                }
                rules.append(ConfigRule(
                    kind: .match,
                    expression: directive.rawValue,
                    sourceURL: sourceURL,
                    line: line.number
                ))

            case "include":
                if draft != nil {
                    draft?.readOnlyReasons.append("Host 块中包含 Include，无法安全编辑")
                }
                if directive.arguments.isEmpty {
                    report(sourceURL, line.number, "Include 缺少文件路径", severity: .error)
                }
                for pattern in directive.arguments {
                    for includedURL in expandedIncludes(pattern, sourceURL: sourceURL, line: line.number) {
                        visit(includedURL, conditional: conditional || inMatch || draft != nil)
                    }
                }

            default:
                if directive.arguments.isEmpty {
                    report(sourceURL, line.number, "指令缺少值：\(directive.keyword)", severity: .error)
                    draft?.readOnlyReasons.append("Host 块中有缺少值的指令，无法安全编辑")
                    continue
                }
                if draft != nil {
                    draft?.options.append(ConfigOption(
                        keyword: directive.keyword,
                        arguments: directive.arguments,
                        line: line.number,
                        rawValue: directive.rawValue
                    ))
                    if directive.keyword.caseInsensitiveCompare("ProxyCommand") == .orderedSame {
                        draft?.readOnlyReasons.append("Host 块包含 ProxyCommand，无法安全编辑")
                    }
                } else if !inMatch && !conditional {
                    globalOptions.append(GlobalOptionRecord(
                        id: "\(sourceURL.path):\(line.number):\(directive.keyword)",
                        keyword: directive.keyword,
                        value: directive.arguments.joined(separator: " "),
                        sourceURL: sourceURL,
                        line: line.number
                    ))
                }
            }
        }
        finish(&draft, at: data.count)
    }

    private mutating func finish(_ draft: inout HostDraft?, at end: Int) {
        guard let current = draft else { return }
        var uniqueReasons: [String] = []
        for reason in current.readOnlyReasons where !uniqueReasons.contains(reason) {
            uniqueReasons.append(reason)
        }
        hosts.append(HostRecord(
            id: "\(current.sourceURL.path):\(current.sourceLine):\(current.alias):\(current.sourceOrder)",
            alias: current.alias,
            sourceOrder: current.sourceOrder,
            sourceURL: current.sourceURL,
            sourceLine: current.sourceLine,
            byteRange: current.start..<end,
            explicitOptions: current.options,
            readOnlyReasons: uniqueReasons
        ))
        draft = nil
    }

    mutating func markDuplicateAliases() {
        let counts = Dictionary(grouping: hosts, by: { $0.alias.lowercased() }).mapValues(\.count)
        for index in hosts.indices where counts[hosts[index].alias.lowercased(), default: 0] > 1 {
            hosts[index].readOnlyReasons.append("别名在配置中重复出现，无法安全编辑")
            report(hosts[index].sourceURL, hosts[index].sourceLine, "重复的 Host 别名：\(hosts[index].alias)")
        }
    }

    private mutating func expandedIncludes(_ pattern: String, sourceURL: URL, line: Int) -> [URL] {
        let path: String
        if pattern.hasPrefix("~/") {
            path = sshDirectory.deletingLastPathComponent().appendingPathComponent(String(pattern.dropFirst(2))).path
        } else if pattern.hasPrefix("~") || pattern.contains("%") || pattern.contains("$") {
            report(sourceURL, line, "暂无法静态展开动态 Include：\(pattern)")
            return []
        } else if pattern.hasPrefix("/") {
            path = pattern
        } else {
            path = sshDirectory.appendingPathComponent(pattern).path
        }

        var matches = glob_t()
        let result = path.withCString { glob($0, 0, nil, &matches) }
        defer { globfree(&matches) }
        guard result == 0 else {
            if result != GLOB_NOMATCH || !pattern.contains(where: { "*?[".contains($0) }) {
                report(sourceURL, line, result == GLOB_NOMATCH
                    ? "Include 未匹配文件：\(pattern)"
                    : "Include 展开失败：\(pattern)")
            }
            return []
        }
        return (0..<Int(matches.gl_pathc)).compactMap { index in
            matches.gl_pathv?[index].map { URL(fileURLWithPath: String(cString: $0)) }
        }
    }

    private mutating func report(_ url: URL, _ line: Int?, _ message: String,
                                 severity: ConfigIssue.Severity = .warning) {
        issues.append(ConfigIssue(sourceURL: url, line: line, message: message, severity: severity))
    }
}

private func makeLines(_ data: Data) -> [SourceLine] {
    let bytes = Array(data)
    var lines: [SourceLine] = []
    var start = 0
    var number = 1
    for index in bytes.indices where bytes[index] == 10 {
        let contentEnd = index > start && bytes[index - 1] == 13 ? index - 1 : index
        lines.append(SourceLine(
            number: number,
            start: start,
            text: String(decoding: bytes[start..<contentEnd], as: UTF8.self)
        ))
        start = index + 1
        number += 1
    }
    if start < bytes.count {
        lines.append(SourceLine(
            number: number,
            start: start,
            text: String(decoding: bytes[start..<bytes.count], as: UTF8.self)
        ))
    }
    return lines
}

private func parseDirective(_ line: String) -> ParsedLine {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return .empty }
    guard !trimmed.contains("\0") else { return .invalid("配置行包含 NUL 字符") }
    let boundary = trimmed.firstIndex { $0.isWhitespace || $0 == "=" } ?? trimmed.endIndex
    let keyword = String(trimmed[..<boundary])
    guard !keyword.isEmpty else { return .invalid("配置行缺少指令名称") }
    var value = trimmed[boundary...].trimmingCharacters(in: .whitespaces)
    if value.hasPrefix("=") {
        value.removeFirst()
        value = value.trimmingCharacters(in: .whitespaces)
    }
    guard let arguments = tokenize(value) else { return .invalid("配置行引号或转义不完整") }
    return .directive(Directive(keyword: keyword, arguments: arguments, rawValue: value))
}

private func tokenize(_ value: String) -> [String]? {
    var tokens: [String] = []
    var token = ""
    var quoted = false
    var escaped = false
    for character in value {
        if escaped {
            token.append(character)
            escaped = false
        } else if character == "\\" {
            escaped = true
        } else if character == "\"" {
            quoted.toggle()
        } else if character == "#" && !quoted && token.isEmpty {
            break
        } else if character.isWhitespace && !quoted {
            if !token.isEmpty {
                tokens.append(token)
                token = ""
            }
        } else {
            token.append(character)
        }
    }
    guard !quoted, !escaped else { return nil }
    if !token.isEmpty { tokens.append(token) }
    return tokens
}
