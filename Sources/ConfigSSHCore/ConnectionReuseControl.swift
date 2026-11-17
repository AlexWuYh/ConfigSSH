import Foundation

/// Stops a host's background multiplexing master on explicit user request.
///
/// Runs `/usr/bin/ssh -O exit -- <alias>` with an argument array (no shell). Like any ssh
/// invocation this evaluates the user's config, including `Match exec`, so it must only run
/// from a button press, never during refresh or background polling.
package enum ConnectionReuseControl {
    package enum Outcome: Equatable, Sendable {
        case stopped
        case notRunning
        case failed(String)
    }

    package static func stopMaster(alias: String, configURL: URL? = nil,
                                   sshExecutable: URL = URL(fileURLWithPath: "/usr/bin/ssh"),
                                   timeout: TimeInterval = 10) -> Outcome {
        guard TerminalLaunchPlanner.isSafeAlias(alias) else { return .failed("主机别名包含不支持的字符") }
        let process = Process()
        process.executableURL = sshExecutable
        var arguments = ["-o", "BatchMode=yes"]
        if let configURL { arguments += ["-F", configURL.path] }
        process.arguments = arguments + ["-O", "exit", "--", alias]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        let status: Int32
        do {
            status = try BoundedProcessRunner.run(process, timeout: timeout)
        } catch {
            return .failed(error.localizedDescription)
        }
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile().prefix(4096), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if status == 0 { return .stopped }
        if message.contains("No such file or directory") || message.contains("Connection refused") ||
            message.contains("No ControlPath specified") {
            return .notRunning
        }
        return .failed(message.isEmpty ? "ssh 退出码 \(status)" : message)
    }
}
