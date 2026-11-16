import AppKit
import ConfigSSHCore
import Darwin
import Foundation

struct TerminalCapability: Identifiable, Sendable {
    let profile: TerminalProfile
    let supportsWindow: Bool
    let supportsTab: Bool
    let explanation: String

    var id: String { profile.id }
}

@MainActor
final class TerminalLaunchService {
    private var cached: [String: TerminalCapability] = [:]

    func capabilities() -> [TerminalCapability] {
        (TerminalCatalog.shared.cachedProfiles ?? []).map { profile in
            cached[Self.cacheKey(for: profile)] ?? TerminalCapability(
                profile: profile, supportsWindow: false, supportsTab: false,
                explanation: "正在检测终端启动方式…"
            )
        }
    }

    func refreshCapabilities() async -> [TerminalCapability] {
        let profiles = await TerminalCatalog.shared.loadInstalled()
        let missing = profiles.filter { cached[Self.cacheKey(for: $0)] == nil }
        if !missing.isEmpty {
            let inspected = await Task.detached(priority: .utility) {
                missing.map(Self.inspect)
            }.value
            for capability in inspected {
                cached[Self.cacheKey(for: capability.profile)] = capability
            }
        }
        return profiles.compactMap { cached[Self.cacheKey(for: $0)] }
    }

    private nonisolated static func cacheKey(for profile: TerminalProfile) -> String {
        "\(profile.id)|\(profile.appPath)|\(profile.strategy.rawValue)|\(profile.executablePath)|\(profile.arguments)"
    }

    private nonisolated static func inspect(_ profile: TerminalProfile) -> TerminalCapability {
        switch profile.strategy {
        case .ottyCLI:
            let cli = URL(fileURLWithPath: profile.executablePath)
            guard FileManager.default.isExecutableFile(atPath: cli.path) else {
                return TerminalCapability(profile: profile, supportsWindow: false, supportsTab: false,
                                          explanation: "未找到可执行的 Otty CLI")
            }
            let window = commandOutput(cli, arguments: ["open", "--help"])?.contains("--command") == true
            let tab = commandOutput(cli, arguments: ["connect", "--help"])?.contains("<SSH_ARGS>") == true
            return TerminalCapability(profile: profile, supportsWindow: window, supportsTab: tab,
                                      explanation: window || tab ? "已检测到 CLI 启动入口" : "CLI 不支持预期的启动入口")
        case .ghosttyAppleScript:
            let dictionary = commandOutput(URL(fileURLWithPath: "/usr/bin/sdef"), arguments: [profile.appPath])
            let command = dictionary?.contains("<property name=\"command\"") == true
            let window = command && dictionary?.contains("<command name=\"new window\"") == true
            let tab = command && dictionary?.contains("<command name=\"new tab\"") == true
            return TerminalCapability(profile: profile, supportsWindow: window, supportsTab: tab,
                                      explanation: window || tab ? "已检测到脚本启动入口" : "未检测到预期的脚本入口")
        case .macOSTerminal:
            return TerminalCapability(profile: profile, supportsWindow: true, supportsTab: false,
                                      explanation: "支持新窗口")
        case .customCLI:
            let executable = URL(fileURLWithPath: profile.executablePath)
            let available = profile.executablePath.hasPrefix("/") &&
                FileManager.default.isExecutableFile(atPath: executable.path) &&
                profile.arguments.contains(where: { $0 == "{alias}" || $0 == "{ssh}" })
            return TerminalCapability(profile: profile, supportsWindow: available, supportsTab: false,
                                      explanation: available ? "已配置可执行命令" : "请设置可执行路径，并在参数中加入 {alias} 或 {ssh}")
        case .unconfigured:
            return TerminalCapability(profile: profile, supportsWindow: false, supportsTab: false,
                                      explanation: "请在设置中配置此终端的启动方式")
        }
    }

    @discardableResult
    func launch(host: HostRecord, with profile: TerminalProfile, mode: TerminalOpenMode) async throws -> Bool {
        let key = Self.cacheKey(for: profile)
        let capability: TerminalCapability
        if let ready = cached[key] {
            capability = ready
        } else {
            let inspected = await Task.detached(priority: .userInitiated) {
                Self.inspect(profile)
            }.value
            cached[key] = inspected
            capability = inspected
        }
        guard mode == .window ? capability.supportsWindow : capability.supportsTab else {
            throw TerminalLaunchError.unavailable(capability.explanation)
        }
        let plan = try TerminalLaunchPlanner.plan(alias: host.alias, profile: profile, mode: mode)
        NSApp.yieldActivation(toApplicationWithBundleIdentifier: profile.id)
        switch plan {
        case .process(let executableURL, let arguments):
            let result = await Task.detached(priority: .userInitiated) { () -> String? in
                let process = Process()
                process.executableURL = executableURL
                process.arguments = arguments
                let errorPipe = Pipe()
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = FileHandle.nullDevice
                process.standardError = errorPipe
                do {
                    let status = try BoundedProcessRunner.run(process, timeout: 10)
                    guard status == 0 else {
                        let detail = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                                            encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        return detail.isEmpty ? "终端未接收启动请求" : String(detail.prefix(500))
                    }
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value
            if let result {
                throw TerminalLaunchError.failed("\(profile.displayName) 启动失败：\(result)")
            }
        case .appleScript(let source):
            // NSAppleScript is documented as main-thread only; this service is @MainActor.
            let detail: String? = {
                guard let script = NSAppleScript(source: source) else {
                    return "无法创建终端启动脚本"
                }
                var errorInfo: NSDictionary?
                _ = script.executeAndReturnError(&errorInfo)
                guard let errorInfo else { return nil }
                return errorInfo["NSAppleScriptErrorMessage"] as? String ?? "请检查 macOS 自动化权限"
            }()
            if let detail {
                throw TerminalLaunchError.failed("\(profile.displayName) 未接收启动请求：\(detail)")
            }
        }
        return await focusTerminal(profile)
    }

    private func focusTerminal(_ profile: TerminalProfile) async -> Bool {
        let identifier = profile.id
        let appPath = URL(fileURLWithPath: profile.appPath).standardizedFileURL.path
        // CLI adapters can return before the terminal process appears.
        for attempt in 0..<20 {
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
                .filter { !$0.isTerminated }
            let application = running.first {
                $0.bundleURL?.standardizedFileURL.path == appPath
            } ?? running.first
            if let application {
                NSApp.yieldActivation(to: application)
                if application.activate(from: NSRunningApplication.current, options: []) {
                    try? await Task.sleep(for: .milliseconds(100))
                    if application.isActive ||
                        NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier {
                        return true
                    }
                }
            }
            if attempt < 19 { try? await Task.sleep(for: .milliseconds(150)) }
        }
        return false
    }

    private nonisolated static func commandOutput(_ executable: URL, arguments: [String]) -> String? {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("configssh-probe-\(UUID().uuidString)")
        let descriptor = temporary.path.withCString {
            Darwin.open($0, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        }
        guard descriptor >= 0 else { return nil }
        let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            guard try BoundedProcessRunner.run(process, timeout: 3) == 0 else { return nil }
            try output.seek(toOffset: 0)
            let data = try output.readToEnd() ?? Data()
            guard data.count <= 1_000_000 else { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}
