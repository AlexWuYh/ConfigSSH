import Darwin
import Foundation
import XCTest
@testable import ConfigSSHCore

final class KeyDeploymentTests: XCTestCase {
    func testInstallsNewKeyThenReportsAlreadyInstalled() throws {
        let server = try TestSSHServer()
        let key = try server.makeKey("newkey")
        XCTAssertEqual(KeyDeployment.deploy(alias: "target", key: key, options: server.options()), .installed)
        XCTAssertEqual(try server.authorizedComments(), ["boot", "newkey"])
        XCTAssertTrue(server.prompts().contains { $0.contains("continue connecting") },
                      "the first-connection host key prompt went through askpass")
        XCTAssertTrue(server.prompts().contains { $0.contains("passphrase for key") },
                      "the authentication prompt went through askpass")
        XCTAssertEqual(KeyDeployment.verifyLogin(alias: "target", key: key, options: server.options()), .verified)
        XCTAssertEqual(KeyDeployment.deploy(alias: "target", key: key, options: server.options()), .alreadyInstalled)
        XCTAssertEqual(try server.authorizedComments(), ["boot", "newkey"], "no duplicate line is appended")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: server.home.appendingPathComponent(".ssh").path).isEmpty,
                      "ssh-copy-id cleaned up its scratch directory")
    }

    func testVerificationDoesNotCountAnotherWorkingKey() throws {
        // ssh-copy-id's own probe would report this key as "already installed" because the
        // config's bootstrap key logs in; the fingerprint check must not.
        let server = try TestSSHServer()
        let key = try server.makeKey("newkey")
        XCTAssertEqual(KeyDeployment.verifyLogin(alias: "target", key: key, options: server.options()), .otherKeyAccepted)
        XCTAssertEqual(try server.authorizedComments(), ["boot"])
    }

    func testRejectedHostKeyStopsBeforeAnythingIsInstalled() throws {
        let server = try TestSSHServer()
        server.trustsHostKey = false
        let key = try server.makeKey("newkey")
        XCTAssertEqual(KeyDeployment.deploy(alias: "target", key: key, options: server.options()), .hostKeyNotTrusted)
        XCTAssertEqual(try server.authorizedComments(), ["boot"])
        XCTAssertFalse(server.prompts().contains { $0.contains("passphrase") }, "no credential is asked for an untrusted host")
    }

    func testChangedHostKeyIsReportedAndNothingIsInstalled() throws {
        let server = try TestSSHServer()
        let first = try server.makeKey("first")
        XCTAssertEqual(KeyDeployment.deploy(alias: "target", key: first, options: server.options()), .installed)
        try server.rotateHostKey()
        let second = try server.makeKey("second")
        XCTAssertEqual(KeyDeployment.deploy(alias: "target", key: second, options: server.options()), .hostKeyChanged)
        XCTAssertEqual(try server.authorizedComments(), ["boot", "first"])
    }

    func testAuthenticationFailureIsReported() throws {
        let server = try TestSSHServer()
        try Data().write(to: server.authorizedKeys)   // bootstrap key no longer accepted
        let key = try server.makeKey("newkey")
        XCTAssertEqual(KeyDeployment.deploy(alias: "target", key: key, options: server.options()), .authenticationFailed)
        XCTAssertEqual(try String(contentsOf: server.authorizedKeys, encoding: .utf8), "")
    }

    func testVerificationIsNotSatisfiedByAnExistingMasterConnection() throws {
        // A multiplexed master authenticated with the bootstrap key must not make an uninstalled
        // key look verified: the wizard passes ControlMaster=no / ControlPath=none.
        let socket = "/tmp/cssh-cm-\(UUID().uuidString.prefix(6))"
        let server = try TestSSHServer(extraClientOptions: ["ControlMaster auto", "ControlPath \(socket)", "ControlPersist 60"])
        let clientConfig = server.configURL.path
        addTeardownBlock {
            let stop = Process()
            stop.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            stop.arguments = ["-F", clientConfig, "-O", "exit", "target"]
            stop.standardError = FileHandle.nullDevice
            _ = try? BoundedProcessRunner.run(stop, timeout: 5)
        }
        let master = GroupProcess()
        var environment = KeyDeployment.environment(for: server.options())
        environment.removeValue(forKey: "SSH_ASKPASS_REQUIRE")
        environment["SSH_ASKPASS_REQUIRE"] = "force"
        let started = try master.run(executable: URL(fileURLWithPath: "/usr/bin/ssh"),
                                     arguments: ["-F", server.configURL.path, "--", "target", "true"],
                                     environment: environment, timeout: 20)
        XCTAssertEqual(started.status, 0, started.stderr)
        XCTAssertTrue(FileManager.default.fileExists(atPath: socket), "a master connection is running")

        let key = try server.makeKey("newkey")
        XCTAssertEqual(KeyDeployment.verifyLogin(alias: "target", key: key, options: server.options()), .otherKeyAccepted,
                       "authentication really happened instead of reusing the master")
        try Data((try String(contentsOf: key.publicKeyURL, encoding: .utf8)).utf8).write(to: server.authorizedKeys)
        XCTAssertEqual(KeyDeployment.verifyLogin(alias: "target", key: key, options: server.options()), .verified)
    }

    func testCancelStopsTheWholeProcessTree() throws {
        let directory = URL(fileURLWithPath: "/tmp").appendingPathComponent("cssh-g-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let pids = directory.appendingPathComponent("pids")
        let script = directory.appendingPathComponent("tree.sh")
        try Data("#!/bin/sh\nsleep 30 &\necho $! >> '\(pids.path)'\nsleep 30\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let process = GroupProcess()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { process.cancel() }
        let started = Date()
        let result = try process.run(executable: script, arguments: [], environment: [:], timeout: 20)
        XCTAssertTrue(result.wasCancelled)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        let child = try XCTUnwrap(pid_t(try String(contentsOf: pids, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        usleep(200_000)
        XCTAssertNotEqual(kill(child, 0), 0, "the background grandchild was stopped too")
    }

    func testTimeoutStopsTheProcess() throws {
        let result = try GroupProcess().run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"],
                                            environment: [:], timeout: 0.5)
        XCTAssertTrue(result.timedOut)
        XCTAssertFalse(result.wasCancelled)
    }

    func testArgumentsAlwaysIsolateFromConnectionReuseAndEndOptionsBeforeAlias() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ConfigSSHDeployArgs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let privateKey = directory.appendingPathComponent("k")
        try Data("not read".utf8).write(to: privateKey)
        let publicKey = directory.appendingPathComponent("k.pub")
        try Data("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl demo\n".utf8).write(to: publicKey)
        let key = try DeployableKey(publicKeyURL: publicKey, privateKeyURL: privateKey)
        var options = KeyDeploymentOptions(askpassURL: URL(fileURLWithPath: "/x/configssh-askpass"))
        options.baseEnvironment = ["PATH": "/usr/bin", "SSH_ASKPASS": "/evil", "SSH_ASKPASS_REQUIRE": "never"]

        for arguments in [KeyDeployment.verificationArguments(alias: "web", key: key, options: options),
                          KeyDeployment.deploymentArguments(alias: "web", key: key, options: options)] {
            let joined = arguments.joined(separator: " ")
            XCTAssertTrue(joined.contains("-o ControlMaster=no -o ControlPath=none"), joined)
            let dash = try XCTUnwrap(arguments.firstIndex(of: "--"))
            XCTAssertEqual(arguments[dash + 1], "web")
        }
        XCTAssertEqual(KeyDeployment.deploymentArguments(alias: "web", key: key, options: options).first, "-f")
        XCTAssertFalse(KeyDeployment.deploymentArguments(alias: "web", key: key, options: options).contains("-s"),
                       "ssh-copy-id's SFTP mode is never used")
        XCTAssertEqual(KeyDeployment.environment(for: options),
                       ["PATH": "/usr/bin", "SSH_ASKPASS": "/x/configssh-askpass", "SSH_ASKPASS_REQUIRE": "force"])
        XCTAssertNil(ProcessInfo.processInfo.environment["SSH_ASKPASS_REQUIRE"], "the test process itself is unchanged")
        XCTAssertEqual(KeyDeployment.deploy(alias: "-oProxyCommand=x", key: key, options: options), .failed("主机别名包含不支持的字符"))
    }

    func testSymlinkedPrivateKeyIsRefused() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ConfigSSHDeployKey-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let publicKey = directory.appendingPathComponent("k.pub")
        try Data("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl demo\n".utf8).write(to: publicKey)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("k"), withDestinationURL: publicKey)
        XCTAssertThrowsError(try DeployableKey(publicKeyURL: publicKey, privateKeyURL: directory.appendingPathComponent("k")))
    }
}
