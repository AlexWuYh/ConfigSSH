import Darwin
import Foundation

/// A key chosen for deployment. Only the `.pub` file is read; the private key is checked for
/// existence so `ssh -i` can use it, but its bytes never enter ConfigSSH.
package struct DeployableKey: Sendable {
    package let publicKeyURL: URL
    package let privateKeyURL: URL
    package let type: String
    package let fingerprint: String

    package init(publicKeyURL: URL, privateKeyURL: URL) throws {
        let parsed = try KeyIndex.readPublicKey(at: publicKeyURL)
        var info = stat()
        guard privateKeyURL.path.withCString({ lstat($0, &info) }) == 0,
              info.st_mode & S_IFMT == S_IFREG else {
            throw ConfigEditError.invalid("找不到对应的私钥文件（需为普通文件，不能是符号链接）：\(privateKeyURL.path)")
        }
        self.publicKeyURL = publicKeyURL
        self.privateKeyURL = privateKeyURL
        self.type = parsed.type
        self.fingerprint = parsed.fingerprint
    }
}

/// Proof that `alias` accepted exactly this key. Only `KeyDeployment.verify` creates it (the
/// initializer is internal to this module), so the UI cannot write key settings unverified.
package struct VerifiedKeyLogin: Sendable, Equatable {
    package let alias: String
    package let privateKeyURL: URL
    package let fingerprint: String

    init(alias: String, privateKeyURL: URL, fingerprint: String) {
        self.alias = alias
        self.privateKeyURL = privateKeyURL
        self.fingerprint = fingerprint
    }
}

package struct KeyDeploymentOptions: Sendable {
    package var askpassURL: URL
    package var sshExecutable = URL(fileURLWithPath: "/usr/bin/ssh")
    package var copyIDExecutable = URL(fileURLWithPath: "/usr/bin/ssh-copy-id")
    package var timeout: TimeInterval = 120
    package var parentProcessID: pid_t = getpid()
    package var baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    /// Test fixtures only: an `ssh -F` config, a HOME for ssh-copy-id's local scratch directory,
    /// and the remote `authorized_keys` path (`ssh-copy-id -t`). Production leaves them nil.
    package var configURL: URL?
    package var homeDirectory: URL?
    package var remoteTargetPath: String?

    package init(askpassURL: URL) { self.askpassURL = askpassURL }
}

package enum KeyLoginOutcome: Equatable, Sendable {
    /// The server accepted exactly this key and authentication completed.
    case verified
    /// Authentication succeeded with a different key (for example one from the config or agent).
    case otherKeyAccepted
    case rejected
    case hostKeyChanged
    case hostKeyNotTrusted
    case cancelled
    case timedOut
    case failed(String)
}

package enum KeyDeploymentOutcome: Equatable, Sendable {
    case installed
    case alreadyInstalled
    case hostKeyChanged
    case hostKeyNotTrusted
    case authenticationFailed
    case cancelled
    case timedOut
    case failed(String)
}

/// Deploys and verifies keys with the system OpenSSH tools.
///
/// Every ssh call passes `-o ControlMaster=no -o ControlPath=none`, so the wizard neither reuses a
/// multiplexed connection (which would skip authentication and fake a successful verification)
/// nor leaves a background master behind. Prompts go to `configssh-askpass` through
/// `SSH_ASKPASS_REQUIRE=force`, set only in the child's environment.
package enum KeyDeployment {
    package static let isolationOptions = ["-o", "ControlMaster=no", "-o", "ControlPath=none"]

    /// Builds the child environment: the parent's variables minus any inherited `SSH_ASKPASS*`,
    /// plus this helper. Nothing is changed in ConfigSSH's own environment.
    package static func environment(for options: KeyDeploymentOptions) -> [String: String] {
        var environment = options.baseEnvironment.filter { !$0.key.hasPrefix("SSH_ASKPASS") }
        environment["SSH_ASKPASS"] = options.askpassURL.path
        environment["SSH_ASKPASS_REQUIRE"] = "force"
        // Lets the helper exit if ConfigSSH itself goes away (crash or forced quit).
        environment[AskpassParentWatch.environmentKey] = String(options.parentProcessID)
        if let home = options.homeDirectory { environment["HOME"] = home.path }
        return environment
    }

    package static func verificationArguments(alias: String, key: DeployableKey,
                                              options: KeyDeploymentOptions) -> [String] {
        var arguments = ["-v"]
        if let configURL = options.configURL { arguments += ["-F", configURL.path] }
        arguments += ["-o", "PreferredAuthentications=publickey",
                      "-o", "PasswordAuthentication=no",
                      "-o", "KbdInteractiveAuthentication=no",
                      "-o", "IdentitiesOnly=yes"] + isolationOptions
        return arguments + ["-i", key.privateKeyURL.path, "--", alias, "true"]
    }

    package static func deploymentArguments(alias: String, key: DeployableKey,
                                            options: KeyDeploymentOptions) -> [String] {
        // -f skips ssh-copy-id's own "already installed" probe: that probe also uses the
        // IdentityFile keys from the config, so a working old key makes it skip a new key.
        // `verifyLogin` performs a fingerprint-exact check before this runs instead.
        // No `-s` (SFTP mode): it starts a background `ssh -f -M` master that leaves our process
        // group, and if that master fails its `sftp` connects to a literal host named "ignored"
        // using the user's own config. SFTP-only servers are therefore not supported.
        var arguments = ["-f", "-i", key.publicKeyURL.path]
        if let target = options.remoteTargetPath { arguments += ["-t", target] }
        if let configURL = options.configURL { arguments += ["-F", configURL.path] }
        return arguments + isolationOptions + ["--", alias]
    }

    /// Tries to log in with only `key`, without passwords or keyboard-interactive prompts.
    package static func verifyLogin(alias: String, key: DeployableKey, options: KeyDeploymentOptions,
                                    process: GroupProcess = GroupProcess()) -> KeyLoginOutcome {
        guard TerminalLaunchPlanner.isSafeAlias(alias) else { return .failed("主机别名包含不支持的字符") }
        let result: GroupProcess.Result
        do {
            result = try process.run(executable: options.sshExecutable,
                                     arguments: verificationArguments(alias: alias, key: key, options: options),
                                     environment: environment(for: options), timeout: options.timeout)
        } catch {
            return .failed(error.localizedDescription)
        }
        return interpretLogin(result, expectedFingerprint: key.fingerprint)
    }

    /// Runs the key-only check and, on success, returns the proof `ConfigWriter.planKeyLogin`
    /// requires before it will write `IdentityFile`/`IdentitiesOnly`.
    package static func verify(alias: String, key: DeployableKey, options: KeyDeploymentOptions,
                               process: GroupProcess = GroupProcess()) -> (outcome: KeyLoginOutcome, proof: VerifiedKeyLogin?) {
        let outcome = verifyLogin(alias: alias, key: key, options: options, process: process)
        guard outcome == .verified else { return (outcome, nil) }
        return (outcome, VerifiedKeyLogin(alias: alias, privateKeyURL: key.privateKeyURL, fingerprint: key.fingerprint))
    }

    /// The lines to add by hand when the host cannot be edited safely (complex or read-only).
    package static func configSnippet(alias: String, identityFile: String) -> String {
        "Host \(alias)\n  IdentityFile \(ConfigWriter.displayPath(identityFile))\n  IdentitiesOnly yes\n"
    }

    /// Checks whether the key already works, then installs it with `ssh-copy-id -f`.
    package static func deploy(alias: String, key: DeployableKey, options: KeyDeploymentOptions,
                               process: GroupProcess = GroupProcess()) -> KeyDeploymentOutcome {
        guard TerminalLaunchPlanner.isSafeAlias(alias) else { return .failed("主机别名包含不支持的字符") }
        switch verifyLogin(alias: alias, key: key, options: options, process: process) {
        case .verified: return .alreadyInstalled
        case .hostKeyChanged: return .hostKeyChanged
        case .hostKeyNotTrusted: return .hostKeyNotTrusted
        case .cancelled: return .cancelled
        case .timedOut: return .timedOut
        case .failed(let message): return .failed(message)
        case .rejected, .otherKeyAccepted: break
        }
        let result: GroupProcess.Result
        do {
            result = try process.run(executable: options.copyIDExecutable,
                                     arguments: deploymentArguments(alias: alias, key: key, options: options),
                                     environment: environment(for: options), timeout: options.timeout)
        } catch {
            return .failed(error.localizedDescription)
        }
        if result.wasCancelled { return .cancelled }
        if result.timedOut { return .timedOut }
        let errors = result.stderr
        if errors.contains("REMOTE HOST IDENTIFICATION HAS CHANGED") { return .hostKeyChanged }
        if errors.contains("Host key verification failed") { return .hostKeyNotTrusted }
        if result.status == 0, result.stdout.contains("Number of key(s) added:") { return .installed }
        if errors.contains("Permission denied") { return .authenticationFailed }
        return .failed(summary(of: errors, status: result.status))
    }

    package static func interpretLogin(_ result: GroupProcess.Result, expectedFingerprint: String) -> KeyLoginOutcome {
        if result.wasCancelled { return .cancelled }
        if result.timedOut { return .timedOut }
        let lines = result.stderr.split(whereSeparator: \.isNewline).map(String.init)
        if lines.contains(where: { $0.contains("REMOTE HOST IDENTIFICATION HAS CHANGED") }) { return .hostKeyChanged }
        if lines.contains(where: { $0.hasPrefix("Host key verification failed") }) { return .hostKeyNotTrusted }
        let accepted = lines.filter { $0.hasPrefix("debug1: Server accepts key:") }
            .compactMap { line in line.split(separator: " ").first(where: { $0.hasPrefix("SHA256:") }).map(String.init) }
        if lines.contains(where: { $0.hasPrefix("Authenticated to ") }) {
            // The remote command's exit status does not matter (an SFTP-only server refuses
            // `true`); what matters is which key the server accepted.
            return accepted.last == expectedFingerprint ? .verified : .otherKeyAccepted
        }
        if lines.contains(where: { $0.contains("Permission denied") }) { return .rejected }
        return .failed(summary(of: result.stderr, status: result.status))
    }

    /// The last few non-debug lines, for display; never includes anything typed into a prompt.
    package static func summary(of stderr: String, status: Int32) -> String {
        let lines = stderr.split(whereSeparator: \.isNewline).map(String.init)
            .filter { !$0.hasPrefix("debug") && !$0.contains(": INFO: ") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let text = lines.suffix(4).joined(separator: "\n")
        return text.isEmpty ? "退出码 \(status)" : String(text.prefix(800))
    }
}

extension KeyLoginOutcome {
    /// User-facing result of the key-only login check, with the usual causes when it fails.
    package var explanation: String {
        switch self {
        case .verified:
            return "已可只用这把密钥登录。"
        case .otherKeyAccepted:
            return "服务器接受的是另一把密钥（来自配置或 ssh-agent），这把新密钥本身还不能登录。"
        case .rejected:
            return """
            服务器拒绝了这把密钥。常见原因：服务器上 ~/.ssh 或 authorized_keys 权限过宽（StrictModes 会拒绝）；\
            sshd 自定义了 AuthorizedKeysFile；sshd 设置了 PubkeyAuthentication no；或公钥被装到了其他用户。
            """
        case .hostKeyChanged:
            return "服务器指纹与已记录的不一致，可能有人冒充服务器。已停止，ConfigSSH 不会修改 known_hosts；请先通过可信渠道核实。"
        case .hostKeyNotTrusted:
            return "未信任此服务器的指纹，已停止。"
        case .cancelled:
            return "已取消。"
        case .timedOut:
            return "连接超时，已停止。"
        case .failed(let message):
            return "无法完成验证：\(message)"
        }
    }

    package var isSuccess: Bool { self == .verified }
}

extension KeyDeploymentOutcome {
    package var explanation: String {
        switch self {
        case .installed: return "公钥已安装到服务器。"
        case .alreadyInstalled: return "服务器上已存在此公钥，并且可以登录。"
        case .hostKeyChanged: return KeyLoginOutcome.hostKeyChanged.explanation
        case .hostKeyNotTrusted: return KeyLoginOutcome.hostKeyNotTrusted.explanation
        case .authenticationFailed: return "服务器认证失败：密码错误、输入被取消，或服务器不允许密码登录。可以返回重试。"
        case .cancelled: return "已取消，服务器未被修改。"
        case .timedOut: return "连接超时，已停止。"
        case .failed(let message): return "部署失败：\(message)"
        }
    }

    /// Whether the wizard may go on to the key-only verification step.
    package var canVerify: Bool { self == .installed || self == .alreadyInstalled }
}
