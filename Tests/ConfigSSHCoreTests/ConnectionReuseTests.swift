import Foundation
import XCTest
@testable import ConfigSSHCore

final class ConnectionReuseTests: XCTestCase {
    private func fixture(_ config: String? = nil) throws -> (root: URL, backup: URL, writer: ConfigWriter) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ConfigSSHReuse-\(UUID().uuidString)")
        let ssh = directory.appendingPathComponent(".ssh")
        try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let root = ssh.appendingPathComponent("config")
        if let config { try Data(config.utf8).write(to: root) }
        let backup = directory.appendingPathComponent("backups")
        return (root, backup, ConfigWriter(rootURL: root, backupDirectory: backup))
    }

    private func edit(_ paths: (root: URL, backup: URL, writer: ConfigWriter), alias: String = "web",
                      _ change: (inout HostInput) -> Void) throws {
        let scan = ConfigReader(rootURL: paths.root).scan()
        let host = try XCTUnwrap(scan.hosts.first { $0.alias == alias })
        var input = HostInput(host: host)
        change(&input)
        _ = try paths.writer.commit(paths.writer.plan(.update(hostID: host.id, input: input), from: scan))
    }

    private func reuse(_ paths: (root: URL, backup: URL, writer: ConfigWriter), alias: String = "web") throws -> ConnectionReuse {
        let host = try XCTUnwrap(ConfigReader(rootURL: paths.root).scan().hosts.first { $0.alias == alias })
        return ConnectionReuse(host: host)
    }

    func testPersistParsingFollowsOpenSSHTimeFormat() {
        XCTAssertEqual(ConnectionReuse.persistSeconds("600"), 600)
        XCTAssertEqual(ConnectionReuse.persistSeconds("10m"), 600)
        XCTAssertEqual(ConnectionReuse.persistSeconds("1h"), 3600)
        XCTAssertEqual(ConnectionReuse.persistSeconds("1h30m"), 5400)
        XCTAssertEqual(ConnectionReuse.persistSeconds("10M"), 600)
        XCTAssertNil(ConnectionReuse.persistSeconds("yes"), "yes keeps the master forever")
        XCTAssertNil(ConnectionReuse.persistSeconds("no"))
        XCTAssertNil(ConnectionReuse.persistSeconds("0"), "0 also means forever")
        XCTAssertNil(ConnectionReuse.persistSeconds(""))
        XCTAssertNil(ConnectionReuse.persistSeconds("10x"))
    }

    func testNewHostWritesManagedReuseAndCreatesPrivateSocketDirectory() throws {
        let paths = try fixture()
        let scan = ConfigReader(rootURL: paths.root).scan()
        let plan = try paths.writer.plan(.add(HostInput(alias: "demo", hostName: "demo.example",
                                                        connectionReuse: .minutes(10))), from: scan)
        XCTAssertEqual(plan.privateDirectory, paths.writer.controlSocketDirectoryURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.writer.controlSocketDirectoryURL.path),
                       "planning must not touch the disk")
        _ = try paths.writer.commit(plan)
        XCTAssertEqual(try String(contentsOf: paths.writer.managedDirectoryURL.appendingPathComponent("demo.conf"), encoding: .utf8),
                       "Host demo\n  HostName demo.example\n  Port 22\n  ControlMaster auto\n  ControlPath ~/.ssh/cm/%C\n  ControlPersist 10m\n")
        let attributes = try FileManager.default.attributesOfItem(atPath: paths.writer.controlSocketDirectoryURL.path)
        XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeDirectory)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o700)
        XCTAssertEqual(try reuse(paths, alias: "demo"), .minutes(10))
    }

    func testTurnOnChangeDurationAndTurnOffOnlyTouchesTheThreeLines() throws {
        let original = "# keep me\r\nHost web\r\n  HostName web.example\r\n  User deploy # inline\r\n\r\n# next block\r\nHost other\r\n  HostName other.example\r\n"
        let paths = try fixture(original)
        try edit(paths) { $0.connectionReuse = .minutes(10) }
        XCTAssertEqual(try String(contentsOf: paths.root, encoding: .utf8),
                       "# keep me\r\nHost web\r\n  HostName web.example\r\n  User deploy # inline\r\n  ControlMaster auto\r\n  ControlPath ~/.ssh/cm/%C\r\n  ControlPersist 10m\r\n\r\n# next block\r\nHost other\r\n  HostName other.example\r\n")
        try edit(paths) { $0.connectionReuse = .minutes(60) }
        XCTAssertTrue(try String(contentsOf: paths.root, encoding: .utf8).contains("  ControlPersist 60m\r\n"))
        XCTAssertEqual(try reuse(paths), .minutes(60))
        try edit(paths) { $0.connectionReuse = .off }
        XCTAssertEqual(try String(contentsOf: paths.root, encoding: .utf8), original, "turning off restores the original bytes")
    }

    func testEquivalentImportedSpellingIsManagedAndPreserved() throws {
        let paths = try fixture("Host web\n  HostName web.example\n  ControlMaster AUTO\n  ControlPath ~/.ssh/cm/%C\n  ControlPersist 600\n")
        XCTAssertEqual(try reuse(paths), .minutes(10))
        try edit(paths) { $0.hostName = "changed.example" }
        XCTAssertEqual(try String(contentsOf: paths.root, encoding: .utf8),
                       "Host web\n  HostName changed.example\n  ControlMaster AUTO\n  ControlPath ~/.ssh/cm/%C\n  ControlPersist 600\n",
                       "unchanged reuse values keep their original spelling")
    }

    func testCustomValuesAreReadOnlyButOtherFieldsStayEditable() throws {
        for custom in ["  ControlMaster auto\n  ControlPath ~/.ssh/cm/%C\n  ControlPersist yes\n",
                       "  ControlMaster auto\n  ControlPath ~/.ssh/cm/%C\n  ControlPersist 4h\n",
                       "  ControlMaster auto\n  ControlPath /tmp/ssh-%r@%h:%p\n  ControlPersist 10m\n",
                       "  ControlPersist 5m\n",
                       "  ControlMaster autoask\n  ControlPath ~/.ssh/cm/%C\n  ControlPersist 10m\n"] {
            let config = "Host web\n  HostName web.example\n" + custom
            let paths = try fixture(config)
            guard case .custom = try reuse(paths) else { return XCTFail("expected custom for \(custom)") }
            XCTAssertThrowsError(try edit(paths) { $0.connectionReuse = .off })
            XCTAssertThrowsError(try edit(paths) { $0.connectionReuse = .minutes(10) })
            XCTAssertEqual(try String(contentsOf: paths.root, encoding: .utf8), config)
            try edit(paths) { $0.user = "deploy" }
            XCTAssertEqual(try String(contentsOf: paths.root, encoding: .utf8),
                           "Host web\n  HostName web.example\n" + custom.dropLast() + "\n  User deploy\n")
        }
    }

    func testDurationOutsideRangeIsRefused() throws {
        let paths = try fixture("Host web\n  HostName web.example\n")
        for minutes in [0, 61, 600, -5] {
            XCTAssertThrowsError(try edit(paths) { $0.connectionReuse = .minutes(minutes) }) { error in
                XCTAssertTrue(error.localizedDescription.contains("1 到 60"), error.localizedDescription)
            }
        }
        XCTAssertThrowsError(try edit(paths) { $0.connectionReuse = .custom("ControlPersist yes") })
        XCTAssertEqual(try String(contentsOf: paths.root, encoding: .utf8), "Host web\n  HostName web.example\n")
    }

    func testSocketDirectoryOpenToOthersIsRefusedAndNothingIsWritten() throws {
        let paths = try fixture("Host web\n  HostName web.example\n")
        let directory = paths.writer.controlSocketDirectoryURL
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o755])
        XCTAssertThrowsError(try edit(paths) { $0.connectionReuse = .minutes(10) }) { error in
            XCTAssertTrue(error.localizedDescription.contains("chmod 700"), error.localizedDescription)
        }
        XCTAssertEqual(try String(contentsOf: paths.root, encoding: .utf8), "Host web\n  HostName web.example\n")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: paths.backup.path).isEmpty,
                      "backups created for the refused commit are removed")
    }

    func testSymlinkedSocketDirectoryIsRefused() throws {
        let paths = try fixture("Host web\n  HostName web.example\n")
        let elsewhere = paths.root.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.createSymbolicLink(at: paths.writer.controlSocketDirectoryURL, withDestinationURL: elsewhere)
        XCTAssertThrowsError(try edit(paths) { $0.connectionReuse = .minutes(10) })
        XCTAssertEqual(try String(contentsOf: paths.root, encoding: .utf8), "Host web\n  HostName web.example\n")
    }

    func testWrittenConfigIsAcceptedByOpenSSH() throws {
        let paths = try fixture()
        _ = try paths.writer.commit(paths.writer.plan(.add(HostInput(alias: "demo", hostName: "demo.example",
                                                                     connectionReuse: .minutes(30))),
                                                      from: ConfigReader(rootURL: paths.root).scan()))
        // A standalone copy with absolute paths: never `ssh -G` the real config or an Include chain.
        let host = paths.writer.managedDirectoryURL.appendingPathComponent("demo.conf")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-G", "-F", host.path, "demo"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        XCTAssertEqual(try BoundedProcessRunner.run(process, timeout: 10), 0)
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertTrue(text.contains("controlmaster auto"), text)
        XCTAssertTrue(text.contains("controlpersist 1800"), text)
        XCTAssertTrue(text.contains("controlpath ") && text.contains("/.ssh/cm/"), text)
    }
}

final class ConnectionReuseControlTests: XCTestCase {
    func testStopMasterReportsNotRunningWithoutTouchingTheNetwork() throws {
        // Short path: macOS limits Unix socket paths to 104 bytes, and %C alone is 40 characters.
        let directory = URL(fileURLWithPath: "/tmp").appendingPathComponent("cssh-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("config")
        try Data("Host demo\n  HostName 192.0.2.1\n  ControlMaster auto\n  ControlPath \(directory.path)/%C\n".utf8).write(to: config)
        XCTAssertEqual(ConnectionReuseControl.stopMaster(alias: "demo", configURL: config), .notRunning)
    }

    func testStopMasterRefusesUnsafeAlias() {
        guard case .failed = ConnectionReuseControl.stopMaster(alias: "-oProxyCommand=x") else {
            return XCTFail("an alias starting with a dash must never reach ssh")
        }
    }

    func testStopMasterPassesAliasAfterDoubleDash() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ConfigSSHReuseArgs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("args")
        let fake = directory.appendingPathComponent("fake-ssh")
        try Data("#!/bin/sh\nprintf '%s\\n' \"$@\" > '\(log.path)'\nexit 0\n".utf8).write(to: fake)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
        XCTAssertEqual(ConnectionReuseControl.stopMaster(alias: "web", sshExecutable: fake), .stopped)
        XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), "-o\nBatchMode=yes\n-O\nexit\n--\nweb\n")
    }
}
