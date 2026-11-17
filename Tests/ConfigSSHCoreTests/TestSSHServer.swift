import Darwin
import Foundation
import XCTest
@testable import ConfigSSHCore

/// An unprivileged `sshd` on 127.0.0.1 for wizard acceptance tests.
///
/// Everything lives in a short `/tmp` directory: host key, `authorized_keys`, client config with
/// its own known_hosts, a bootstrap key (passphrase-protected, standing in for the password step,
/// since an unprivileged sshd cannot check real passwords), and a scripted askpass that records
/// every prompt. Real `~/.ssh` is never read or written: the client config sets
/// `IdentitiesOnly yes`/`IdentityAgent none`, and ssh-copy-id gets its own HOME.
final class TestSSHServer {
    let directory: URL
    let home: URL
    let port: Int
    let configURL: URL
    let authorizedKeys: URL
    let askpass: URL
    let promptLog: URL
    let bootstrapPassphrase = "boot-pass-123"
    private var pidFile: URL { directory.appendingPathComponent("sshd.pid") }

    /// Whether the scripted askpass approves first-connection host key prompts.
    var trustsHostKey: Bool {
        get { FileManager.default.fileExists(atPath: directory.appendingPathComponent("trust").path) }
        set {
            let flag = directory.appendingPathComponent("trust")
            if newValue { FileManager.default.createFile(atPath: flag.path, contents: Data()) }
            else { try? FileManager.default.removeItem(at: flag) }
        }
    }

    init(extraClientOptions: [String] = []) throws {
        directory = URL(fileURLWithPath: "/tmp").appendingPathComponent("cssh-t-\(UUID().uuidString.prefix(8))")
        home = directory.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".ssh"), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        authorizedKeys = directory.appendingPathComponent("authorized_keys")
        configURL = directory.appendingPathComponent("client_config")
        askpass = directory.appendingPathComponent("askpass")
        promptLog = directory.appendingPathComponent("prompts")

        try Self.keygen(directory.appendingPathComponent("hostkey"), passphrase: "")
        try Self.keygen(directory.appendingPathComponent("boot"), passphrase: bootstrapPassphrase)
        try FileManager.default.copyItem(at: directory.appendingPathComponent("boot.pub"), to: authorizedKeys)

        let script = """
        #!/bin/sh
        printf '%s\\n---\\n' "$1" >> '\(promptLog.path)'
        case "$1" in
          *"continue connecting"*) [ -f '\(directory.path)/trust' ] && { echo yes; exit 0; }; exit 1 ;;
          *"passphrase for key '\(directory.path)/boot'"*) echo '\(bootstrapPassphrase)' ;;
          *) exit 1 ;;
        esac
        """
        try Data(script.utf8).write(to: askpass)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: askpass.path)

        var chosen: Int?
        for _ in 0..<10 {
            let candidate = Int.random(in: 20000...40000)
            if try Self.start(directory: directory, port: candidate, authorizedKeys: authorizedKeys) {
                chosen = candidate
                break
            }
        }
        guard let port = chosen else { throw XCTSkip("无法在 127.0.0.1 启动测试 sshd") }
        self.port = port

        let user = String(cString: getpwuid(getuid())!.pointee.pw_name)
        let client = (["Host target",
                       "  HostName 127.0.0.1",
                       "  Port \(port)",
                       "  User \(user)",
                       "  UserKnownHostsFile \(directory.path)/known_hosts",
                       "  GlobalKnownHostsFile /dev/null",
                       "  IdentityFile \(directory.path)/boot",
                       "  IdentitiesOnly yes",
                       "  IdentityAgent none",
                       "  ConnectTimeout 5"] + extraClientOptions.map { "  " + $0 }).joined(separator: "\n") + "\n"
        try Data(client.utf8).write(to: configURL)
        trustsHostKey = true
    }

    func options() -> KeyDeploymentOptions {
        var options = KeyDeploymentOptions(askpassURL: askpass)
        options.configURL = configURL
        options.homeDirectory = home
        options.remoteTargetPath = authorizedKeys.path
        options.timeout = 30
        return options
    }

    func makeKey(_ name: String, passphrase: String = "") throws -> DeployableKey {
        let url = directory.appendingPathComponent(name)
        try Self.keygen(url, passphrase: passphrase)
        return try DeployableKey(publicKeyURL: URL(fileURLWithPath: url.path + ".pub"), privateKeyURL: url)
    }

    func authorizedComments() throws -> [String] {
        try String(contentsOf: authorizedKeys, encoding: .utf8).split(whereSeparator: \.isNewline)
            .compactMap { $0.split(separator: " ").dropFirst(2).first.map(String.init) }
    }

    func prompts() -> [String] {
        ((try? String(contentsOf: promptLog, encoding: .utf8)) ?? "")
            .components(separatedBy: "\n---\n").filter { !$0.isEmpty }
    }

    /// Replaces the server's host key, simulating a changed or impersonated server.
    func rotateHostKey() throws {
        stop()
        let key = directory.appendingPathComponent("hostkey")
        try FileManager.default.removeItem(at: key)
        try FileManager.default.removeItem(at: URL(fileURLWithPath: key.path + ".pub"))
        try Self.keygen(key, passphrase: "")
        guard try Self.start(directory: directory, port: port, authorizedKeys: authorizedKeys) else {
            throw XCTSkip("无法在原端口重启测试 sshd")
        }
    }

    func stop() {
        if let text = try? String(contentsOf: pidFile, encoding: .utf8), let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            kill(pid, SIGTERM)
            for _ in 0..<40 where kill(pid, 0) == 0 { usleep(50_000) }
        }
        try? FileManager.default.removeItem(at: pidFile)
    }

    deinit {
        stop()
        try? FileManager.default.removeItem(at: directory)
    }

    private static func start(directory: URL, port: Int, authorizedKeys: URL) throws -> Bool {
        let config = directory.appendingPathComponent("sshd_config")
        let text = """
        Port \(port)
        ListenAddress 127.0.0.1
        HostKey \(directory.path)/hostkey
        PidFile \(directory.path)/sshd.pid
        AuthorizedKeysFile \(authorizedKeys.path)
        UsePAM no
        StrictModes no
        PasswordAuthentication no
        KbdInteractiveAuthentication no

        """
        try Data(text.utf8).write(to: config)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/sshd")
        process.arguments = ["-f", config.path, "-E", directory.appendingPathComponent("sshd.log").path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard try BoundedProcessRunner.run(process, timeout: 10) == 0 else { return false }
        for _ in 0..<60 {
            if canConnect(port: port) { return true }
            usleep(50_000)
        }
        return false
    }

    private static func canConnect(port: Int) -> Bool {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { return false }
        defer { close(socket) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    private static func keygen(_ url: URL, passphrase: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = ["-q", "-t", "ed25519", "-N", passphrase, "-C", url.lastPathComponent, "-f", url.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard try BoundedProcessRunner.run(process, timeout: 20) == 0 else {
            throw ConfigEditError.io("测试密钥生成失败")
        }
    }
}
