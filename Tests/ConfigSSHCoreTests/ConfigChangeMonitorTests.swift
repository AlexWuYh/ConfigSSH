import Foundation
import XCTest
@testable import ConfigSSHCore

final class ConfigChangeMonitorTests: XCTestCase {
    func testDetectsRootIncludeAndNewWildcardFilesWithoutExecutingMatch() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ConfigSSHMonitor-\(UUID().uuidString)")
        let ssh = directory.appendingPathComponent(".ssh")
        let included = ssh.appendingPathComponent("config.d")
        try FileManager.default.createDirectory(at: included, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let root = ssh.appendingPathComponent("config")
        let marker = directory.appendingPathComponent("must-not-run")
        try Data("Include config.d/*.conf\nMatch exec /usr/bin/touch \(marker.path)\n  Port 22\n".utf8).write(to: root)
        let baseline = ConfigChangeMonitor.fingerprint(rootURL: root)
        XCTAssertEqual(baseline, ConfigChangeMonitor.fingerprint(rootURL: root))
        try Data("Host demo\n HostName demo.example\n".utf8).write(to: included.appendingPathComponent("demo.conf"))
        let withInclude = ConfigChangeMonitor.fingerprint(rootURL: root)
        XCTAssertNotEqual(baseline, withInclude)
        try Data("Host demo\n HostName changed.example\n".utf8).write(to: included.appendingPathComponent("demo.conf"))
        XCTAssertNotEqual(withInclude, ConfigChangeMonitor.fingerprint(rootURL: root))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testDetectsMissingRootBeingCreated() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ConfigSSHMonitor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("config")
        let missing = ConfigChangeMonitor.fingerprint(rootURL: root)
        try Data("# new\n".utf8).write(to: root)
        XCTAssertNotEqual(missing, ConfigChangeMonitor.fingerprint(rootURL: root))
    }
}
