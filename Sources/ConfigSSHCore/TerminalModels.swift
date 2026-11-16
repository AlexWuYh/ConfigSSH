import Foundation

package struct TerminalProfile: Codable, Hashable, Identifiable, Sendable {
    package enum Strategy: String, Codable, CaseIterable, Sendable {
        case ottyCLI
        case ghosttyAppleScript
        case macOSTerminal
        case customCLI
        case unconfigured
    }

    package var id: String
    package var displayName: String
    package var appPath: String
    package var strategy: Strategy
    package var executablePath: String
    package var arguments: [String]

    package init(id: String, displayName: String, appPath: String, strategy: Strategy,
                 executablePath: String = "", arguments: [String] = []) {
        self.id = id
        self.displayName = displayName
        self.appPath = appPath
        self.strategy = strategy
        self.executablePath = executablePath
        self.arguments = arguments
    }

    package static func canonicalID(_ raw: String) -> String? {
        switch raw {
        case "": return nil
        case "otty": return "io.appmakes.otty"
        case "ghostty": return "com.mitchellh.ghostty"
        default: return raw
        }
    }
}

package enum TerminalOpenMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case window
    case tab

    package var id: String { rawValue }
    package var displayName: String { self == .window ? "新窗口" : "新标签页" }

    package static func resolved(_ raw: String?) -> TerminalOpenMode {
        TerminalOpenMode(rawValue: raw ?? "") ?? .window
    }
}

package enum TerminalLaunchPlan {
    case process(executableURL: URL, arguments: [String])
    case appleScript(String)
}

package enum TerminalLaunchError: LocalizedError {
    case invalidAlias
    case unavailable(String)
    case failed(String)

    package var errorDescription: String? {
        switch self {
        case .invalidAlias: "此 Host 别名包含无法安全传给终端的字符；请复制命令并手动连接"
        case .unavailable(let message), .failed(let message): message
        }
    }
}

package enum TerminalLaunchPlanner {
    package static func isSafeAlias(_ alias: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return alias.unicodeScalars.first.map { CharacterSet.alphanumerics.contains($0) } == true &&
            alias.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    package static func plan(alias: String, profile: TerminalProfile, mode: TerminalOpenMode) throws -> TerminalLaunchPlan {
        guard isSafeAlias(alias) else { throw TerminalLaunchError.invalidAlias }
        switch profile.strategy {
        case .ottyCLI:
            guard !profile.executablePath.isEmpty else {
                throw TerminalLaunchError.unavailable("Otty CLI 未配置")
            }
            if mode == .window {
                return .process(executableURL: URL(fileURLWithPath: profile.executablePath),
                                arguments: ["open", "--command", "/usr/bin/ssh \(alias)"])
            }
            return .process(executableURL: URL(fileURLWithPath: profile.executablePath), arguments: ["connect", alias])
        case .ghosttyAppleScript:
            guard profile.id == "com.mitchellh.ghostty" else {
                throw TerminalLaunchError.unavailable("Ghostty 脚本适配只能用于 Ghostty")
            }
            let command = "/usr/bin/ssh \(alias)"
            let script = """
            tell application id "com.mitchellh.ghostty"
                set surfaceConfig to new surface configuration
                set command of surfaceConfig to "\(command)"
                \(mode == .window ? "new window with configuration surfaceConfig" : "new tab with configuration surfaceConfig")
                activate
            end tell
            """
            return .appleScript(script)
        case .macOSTerminal:
            guard profile.id == "com.apple.Terminal", mode == .window else {
                throw TerminalLaunchError.unavailable("Terminal.app 当前只支持新窗口")
            }
            let script = """
            tell application id "com.apple.Terminal"
                activate
                do script "/usr/bin/ssh \(alias)"
            end tell
            """
            return .appleScript(script)
        case .customCLI:
            guard profile.executablePath.hasPrefix("/") else {
                throw TerminalLaunchError.unavailable("请配置自定义终端可执行文件的绝对路径")
            }
            guard mode == .window else {
                throw TerminalLaunchError.unavailable("自定义命令目前只支持新窗口")
            }
            return .process(executableURL: URL(fileURLWithPath: profile.executablePath),
                            arguments: profile.arguments.flatMap { $0 == "{alias}" ? [alias] :
                                $0 == "{ssh}" ? ["/usr/bin/ssh", alias] : [$0] })
        case .unconfigured:
            throw TerminalLaunchError.unavailable("此终端尚未配置启动方式，请在设置中选择可执行文件和参数")
        }
    }

    package static func copyableCommand(alias: String) -> String {
        let quoted = "'" + alias.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "/usr/bin/ssh \(quoted)"
    }
}
