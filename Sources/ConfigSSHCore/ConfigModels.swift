import Foundation

package enum ConfigAvailability: Equatable, Sendable {
    case available
    case missing
    case unreadable(String)
}

package struct ConfigIssue: Identifiable, Sendable {
    package enum Severity: Equatable, Sendable { case warning, error }

    package let id = UUID()
    package let sourceURL: URL
    package let line: Int?
    package let message: String
    package let severity: Severity

    package init(sourceURL: URL, line: Int?, message: String, severity: Severity = .warning) {
        self.sourceURL = sourceURL
        self.line = line
        self.message = message
        self.severity = severity
    }

    package var location: String {
        if let line {
            return "\(sourceURL.path):\(line)"
        }
        return sourceURL.path
    }
}

package struct ConfigOption: Sendable {
    package let keyword: String
    package let arguments: [String]
    package let line: Int
    package let rawValue: String
}

package struct HostRecord: Identifiable, Sendable {
    package let id: String
    package let alias: String
    package let sourceOrder: Int
    package let sourceURL: URL
    package let sourceLine: Int
    package let byteRange: Range<Int>
    package let explicitOptions: [ConfigOption]
    package var readOnlyReasons: [String]

    package var metadataKey: String { "\(sourceURL.path)\u{1F}\(alias.lowercased())" }

    package var configGroup: String? {
        let components = sourceURL.standardizedFileURL.pathComponents
        guard let index = components.lastIndex(of: "config.d"), index + 2 < components.count else { return nil }
        return components[index + 1]
    }

    package var isSimple: Bool { readOnlyReasons.isEmpty }

    package func option(_ name: String) -> String? {
        explicitOptions.first { $0.keyword.caseInsensitiveCompare(name) == .orderedSame }?
            .arguments.joined(separator: " ")
    }

    package var hostName: String? { option("HostName") }
    package var user: String? { option("User") }
    package var port: String? { option("Port") }

    package func matches(_ query: String) -> Bool {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let searchable = [alias] + explicitOptions
            .filter { ["hostname", "user"].contains($0.keyword.lowercased()) }
            .flatMap(\.arguments) + [configGroup].compactMap { $0 }
        return terms.allSatisfy { term in
            searchable.contains { $0.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }
}

package struct ConfigRule: Identifiable, Sendable {
    package enum Kind: Sendable {
        case hostPattern
        case match
    }

    package let id = UUID()
    package let kind: Kind
    package let expression: String
    package let sourceURL: URL
    package let line: Int
}

package struct GlobalOptionRecord: Identifiable, Sendable {
    package let id: String
    package let keyword: String
    package let value: String
    package let sourceURL: URL
    package let line: Int
}

package struct SourceFileSnapshot: Sendable {
    package let url: URL
    package let data: Data
    package let sha256: String
}

package struct ConfigScan: Sendable {
    package let rootURL: URL
    package let availability: ConfigAvailability
    package var hosts: [HostRecord]
    package var globalOptions: [GlobalOptionRecord]
    package var rules: [ConfigRule]
    package var issues: [ConfigIssue]
    package var sources: [SourceFileSnapshot]

    package init(rootURL: URL, availability: ConfigAvailability, hosts: [HostRecord],
                 globalOptions: [GlobalOptionRecord], rules: [ConfigRule], issues: [ConfigIssue],
                 sources: [SourceFileSnapshot]) {
        self.rootURL = rootURL
        self.availability = availability
        self.hosts = hosts
        self.globalOptions = globalOptions
        self.rules = rules
        self.issues = issues
        self.sources = sources
    }
}

extension ConfigScan {
    /// The host block exactly as written in its source file: from the `Host` line through the
    /// block's last option line, including comments, indentation and blank lines in between, but
    /// not trailing blank lines or the next block's leading comments. Line endings are normalised
    /// to `\n` for display only.
    package func sourceText(for host: HostRecord) -> String? {
        guard let source = sources.first(where: { $0.url == host.sourceURL }) else { return nil }
        let lines = String(decoding: source.data, as: UTF8.self)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
        let first = host.sourceLine
        let last = max(first, host.explicitOptions.map(\.line).max() ?? first)
        guard first >= 1, last <= lines.count else { return nil }
        return lines[(first - 1)...(last - 1)].joined(separator: "\n")
    }
}
