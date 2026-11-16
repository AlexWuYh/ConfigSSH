import Foundation
import XCTest
@testable import ConfigSSHCore

final class TerminalAndMetadataTests: XCTestCase {
    private func databaseURL() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ConfigSSHMetadata-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("metadata.sqlite")
    }

    func testMetadataPersistsSeparatelyFromSSHConfig() throws {
        let url = databaseURL()
        let store = try MetadataStore(databaseURL: url)
        let entry = HostMetadata(hostKey: "/tmp/config\u{1F}demo", displayName: "生产机",
                                 groupName: "工作", tags: ["重要", "Linux"], isFavorite: true,
                                 preferredTerminal: "com.mitchellh.ghostty", preferredOpenMode: "tab",
                                 note: "部署目标")
        try store.save(entry)
        let loaded = try XCTUnwrap(store.allMetadata()[entry.hostKey])
        XCTAssertEqual(loaded.displayName, "生产机")
        XCTAssertEqual(loaded.groupName, "工作")
        XCTAssertEqual(loaded.tags, ["重要", "Linux"])
        XCTAssertTrue(loaded.isFavorite)
        XCTAssertEqual(loaded.preferredTerminal, "com.mitchellh.ghostty")
        XCTAssertEqual(loaded.preferredOpenMode, "tab")
        XCTAssertEqual(loaded.note, "部署目标")
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: url.path))[.posixPermissions] as? Int, 0o600)
    }

    func testOnlyLocallyAcceptedLaunchesEnterRecentHistory() throws {
        let store = try MetadataStore(databaseURL: databaseURL())
        XCTAssertTrue(try store.recentEvents().isEmpty)
        try store.recordLaunch(hostKey: "host-1", terminal: "io.appmakes.otty",
                               at: Date(timeIntervalSince1970: 100))
        try store.recordLaunch(hostKey: "host-2", terminal: "com.mitchellh.ghostty",
                               at: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(try store.recentEvents().map(\.hostKey), ["host-2", "host-1"])
        XCTAssertEqual(try store.recentEvents(limit: 1).map(\.terminal), ["com.mitchellh.ghostty"])
    }

    func testMovingGroupHostPreservesFavoriteAndHistory() throws {
        let store = try MetadataStore(databaseURL: databaseURL())
        let oldKey = "/fixture/config.d/Work/demo.conf\u{1F}demo"
        let newKey = "/fixture/config.d/demo.conf\u{1F}demo"
        try store.save(HostMetadata(hostKey: oldKey, displayName: "演示", groupName: "Work", isFavorite: true))
        try store.recordLaunch(hostKey: oldKey, terminal: "com.apple.Terminal")
        try store.moveHostKeys([(from: oldKey, to: newKey)])
        try store.clearGroup(named: "Work")
        XCTAssertNil(try store.allMetadata()[oldKey])
        let moved = try XCTUnwrap(store.allMetadata()[newKey])
        XCTAssertTrue(moved.isFavorite)
        XCTAssertEqual(moved.displayName, "演示")
        XCTAssertEqual(moved.groupName, "")
        XCTAssertEqual(try store.recentEvents().first?.hostKey, newKey)
    }

    func testExistingMetadataDatabaseAddsOpenModeColumnWithoutLosingRows() throws {
        let url = databaseURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let legacySchema = "CREATE TABLE host_metadata (host_key TEXT PRIMARY KEY, display_name TEXT NOT NULL DEFAULT '', group_name TEXT NOT NULL DEFAULT '', tags_json TEXT NOT NULL DEFAULT '[]', is_favorite INTEGER NOT NULL DEFAULT 0, preferred_terminal TEXT, note TEXT NOT NULL DEFAULT ''); INSERT INTO host_metadata (host_key, display_name, is_favorite) VALUES ('legacy-host', 'Old host', 1);"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [url.path, legacySchema]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let store = try MetadataStore(databaseURL: url)
        var old = try XCTUnwrap(store.allMetadata()["legacy-host"])
        XCTAssertEqual(old.displayName, "Old host")
        XCTAssertTrue(old.isFavorite)
        XCTAssertNil(old.preferredOpenMode)
        old.preferredOpenMode = "tab"
        try store.save(old)
        XCTAssertEqual(try store.allMetadata()["legacy-host"]?.preferredOpenMode, "tab")
    }

    func testTerminalPlansUseValidatedAliasesAndNoShellProcess() throws {
        let cli = URL(fileURLWithPath: "/Applications/Otty.app/Contents/MacOS/otty-cli")
        let otty = TerminalProfile(id: "io.appmakes.otty", displayName: "Otty", appPath: "/Applications/Otty.app",
                                   strategy: .ottyCLI, executablePath: cli.path)
        let tab = try TerminalLaunchPlanner.plan(alias: "my-host_1", profile: otty, mode: .tab)
        if case .process(let executable, let arguments) = tab {
            XCTAssertEqual(executable, cli)
            XCTAssertEqual(arguments, ["connect", "my-host_1"])
        } else { XCTFail("Expected direct Process plan") }

        let window = try TerminalLaunchPlanner.plan(alias: "demo", profile: otty, mode: .window)
        if case .process(_, let arguments) = window {
            XCTAssertEqual(arguments, ["open", "--command", "/usr/bin/ssh demo"])
        } else { XCTFail("Expected direct Process plan") }

        let ghosttyProfile = TerminalProfile(id: "com.mitchellh.ghostty", displayName: "Ghostty",
                                             appPath: "/Applications/Ghostty.app", strategy: .ghosttyAppleScript)
        let ghostty = try TerminalLaunchPlanner.plan(alias: "demo", profile: ghosttyProfile, mode: .tab)
        if case .appleScript(let script) = ghostty {
            XCTAssertTrue(script.contains("new tab with configuration surfaceConfig"))
            XCTAssertTrue(script.contains("/usr/bin/ssh demo"))
        } else { XCTFail("Expected AppleScript plan") }

        for alias in ["-bad", "has space", "x;touch /tmp/bad", "bad\nline", "bad\"quote"] {
            XCTAssertThrowsError(try TerminalLaunchPlanner.plan(alias: alias, profile: ghosttyProfile,
                                                                 mode: .window))
        }
        XCTAssertEqual(TerminalLaunchPlanner.copyableCommand(alias: "that's-it"),
                       "/usr/bin/ssh 'that'\\''s-it'")
    }

    func testCustomTerminalUsesArgumentArrayWithoutShell() throws {
        let profile = TerminalProfile(id: "org.example.Term", displayName: "Example Terminal",
                                      appPath: "/Applications/Example.app", strategy: .customCLI,
                                      executablePath: "/usr/bin/open", arguments: ["--args", "{ssh}"])
        let plan = try TerminalLaunchPlanner.plan(alias: "dev-server", profile: profile, mode: .window)
        if case .process(let executable, let arguments) = plan {
            XCTAssertEqual(executable.path, "/usr/bin/open")
            XCTAssertEqual(arguments, ["--args", "/usr/bin/ssh", "dev-server"])
        } else { XCTFail("Expected direct Process plan") }
        XCTAssertThrowsError(try TerminalLaunchPlanner.plan(alias: "dev-server", profile: profile, mode: .tab))
        XCTAssertThrowsError(try TerminalLaunchPlanner.plan(alias: "bad;touch", profile: profile, mode: .window))
    }

    func testOpenModeFallbackUsesWindowForUnknownValues() {
        XCTAssertEqual(TerminalOpenMode.resolved(nil), .window)
        XCTAssertEqual(TerminalOpenMode.resolved("tab"), .tab)
        XCTAssertEqual(TerminalOpenMode.resolved("unknown"), .window)
    }
}
