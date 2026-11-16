import Foundation
import XCTest
@testable import ConfigSSHCore

final class ConfigWriterTests: XCTestCase {
    private func fixture() throws -> (root: URL, backup: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ConfigSSHWriter-\(UUID().uuidString)")
        let ssh = directory.appendingPathComponent(".ssh")
        try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return (ssh.appendingPathComponent("config"), directory.appendingPathComponent("backups"))
    }

    func testAddFromMissingConfigRequiresPreviewAndCreatesManagedInclude() throws {
        let paths = try fixture()
        let writer = ConfigWriter(rootURL: paths.root, backupDirectory: paths.backup)
        let input = HostInput(alias: "demo", hostName: "demo.example", user: "deploy", port: "2202")
        let plan = try writer.plan(.add(input), from: ConfigReader(rootURL: paths.root).scan())
        XCTAssertEqual(plan.changes.count, 2)
        XCTAssertTrue(plan.changes.first?.diff.contains("Host demo") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.root.path))

        let receipt = try writer.commit(plan)
        XCTAssertEqual(receipt.changedPaths.count, 2)
        XCTAssertEqual(try String(contentsOf: paths.root, encoding: .utf8), "Include config.d/*.conf\nInclude config.d/*/*.conf\n")
        XCTAssertEqual(try String(contentsOf: writer.managedDirectoryURL.appendingPathComponent("demo.conf"), encoding: .utf8),
                       "Host demo\n  HostName demo.example\n  User deploy\n  Port 2202\n")
        XCTAssertEqual(ConfigReader(rootURL: paths.root).scan().hosts.map(\.alias), ["demo"])
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: writer.managedDirectoryURL.appendingPathComponent("demo.conf").path))[.posixPermissions] as? Int, 0o600)
    }

    func testAddPreservesExistingConfigAndRejectsUnsafePrefix() throws {
        let paths = try fixture()
        let original = Data("# existing\r\nHost old\r\n  HostName old.example\r\n".utf8)
        try original.write(to: paths.root)
        let writer = ConfigWriter(rootURL: paths.root, backupDirectory: paths.backup)
        let plan = try writer.plan(.add(HostInput(alias: "new", hostName: "new.example")),
                                   from: ConfigReader(rootURL: paths.root).scan())
        _ = try writer.commit(plan)
        let result = try Data(contentsOf: paths.root)
        let resultText = String(decoding: result, as: UTF8.self)
        XCTAssertTrue(resultText.contains("Include config.d/*.conf\r\nInclude config.d/*/*.conf\r\nHost old"), resultText.debugDescription)
        XCTAssertTrue(resultText.hasPrefix("# existing\r\n"))
        XCTAssertTrue(resultText.hasSuffix("Host old\r\n  HostName old.example\r\n"), resultText.debugDescription)

        let unsafeRoot = paths.root.deletingLastPathComponent().appendingPathComponent("unsafe-config")
        let unsafeData = Data("Host old\n HostName old.example\nInclude config.d/*.conf\n".utf8)
        try unsafeData.write(to: unsafeRoot)
        let unsafeWriter = ConfigWriter(rootURL: unsafeRoot, backupDirectory: paths.backup)
        XCTAssertThrowsError(try unsafeWriter.plan(.add(HostInput(alias: "another", hostName: "another.example")),
                                                      from: ConfigReader(rootURL: unsafeRoot).scan()))
        XCTAssertEqual(try Data(contentsOf: unsafeRoot), unsafeData)
    }

    func testGroupedHostGetsSeparateFileAndBothIncludePatterns() throws {
        let paths = try fixture()
        let writer = ConfigWriter(rootURL: paths.root, backupDirectory: paths.backup)
        let input = HostInput(alias: "db", hostName: "db.example", group: "DeepGlint")
        let plan = try writer.plan(.add(input), from: ConfigReader(rootURL: paths.root).scan())
        XCTAssertEqual(plan.changes.count, 2)
        XCTAssertEqual(plan.changes.first?.url.path,
                       paths.root.deletingLastPathComponent().appendingPathComponent("config.d/DeepGlint/db.conf").path)
        _ = try writer.commit(plan)
        let scan = ConfigReader(rootURL: paths.root).scan()
        XCTAssertEqual(scan.hosts.map(\.alias), ["db"])
        XCTAssertEqual(scan.hosts.first?.configGroup, "DeepGlint")
        XCTAssertEqual(try String(contentsOf: paths.root, encoding: .utf8),
                       "Include config.d/*.conf\nInclude config.d/*/*.conf\n")
        XCTAssertEqual(try String(contentsOf: plan.changes[0].url, encoding: .utf8),
                       "Host db\n  HostName db.example\n  Port 22\n")
    }

    func testIdentityFileWithSpacesIsQuotedAndParsedAsSinglePath() throws {
        let paths = try fixture()
        let writer = ConfigWriter(rootURL: paths.root, backupDirectory: paths.backup)
        let identity = paths.root.deletingLastPathComponent().appendingPathComponent("keys/company key")
        let input = HostInput(alias: "company", hostName: "company.example", identityFile: identity.path)
        let plan = try writer.plan(.add(input), from: ConfigReader(rootURL: paths.root).scan())
        _ = try writer.commit(plan)
        let host = try XCTUnwrap(ConfigReader(rootURL: paths.root).scan().hosts.first)
        XCTAssertEqual(host.option("IdentityFile"), identity.path)
        XCTAssertEqual(try String(contentsOf: plan.changes[0].url, encoding: .utf8),
                       "Host company\n  HostName company.example\n  Port 22\n  IdentityFile \"\(identity.path)\"\n")
    }

    func testAddingAnotherGroupPreservesExistingGlobalRulesAndIncludes() throws {
        let paths = try fixture()
        let original = "Include config.d/*.conf\nInclude config.d/*/*.conf\nHost *\n  ServerAliveInterval 30\n"
        try Data(original.utf8).write(to: paths.root)
        let writer = ConfigWriter(rootURL: paths.root, backupDirectory: paths.backup)
        _ = try writer.commit(writer.plan(.add(HostInput(alias: "one", hostName: "one.example", group: "A")),
                                          from: ConfigReader(rootURL: paths.root).scan()))
        _ = try writer.commit(writer.plan(.add(HostInput(alias: "two", hostName: "two.example", group: "B")),
                                          from: ConfigReader(rootURL: paths.root).scan()))
        XCTAssertEqual(try String(contentsOf: paths.root, encoding: .utf8), original)
        XCTAssertEqual(ConfigReader(rootURL: paths.root).scan().hosts.map(\.configGroup), ["A", "B"])
    }

    func testCombinedIncludeDirectiveIsReusedWithoutChangingRoot() throws {
        let paths = try fixture()
        let original = "Include config.d/*.conf config.d/*/*.conf\nHost *\n  ServerAliveInterval 30\n"
        try Data(original.utf8).write(to: paths.root)
        let writer = ConfigWriter(rootURL: paths.root, backupDirectory: paths.backup)
        let plan = try writer.plan(.add(HostInput(alias: "new-host", hostName: "new.example", group: "Work")),
                                   from: ConfigReader(rootURL: paths.root).scan())
        XCTAssertEqual(plan.changes.count, 1)
        _ = try writer.commit(plan)
        XCTAssertEqual(try String(contentsOf: paths.root, encoding: .utf8), original)
    }

    func testUnsafeGroupPathRejected() throws {
        let paths = try fixture()
        let writer = ConfigWriter(rootURL: paths.root, backupDirectory: paths.backup)
        for group in ["../other", "A/B", " leading", "A\nB"] {
            XCTAssertThrowsError(try writer.plan(.add(HostInput(alias: "host", hostName: "host.example", group: group)),
                                                       from: ConfigReader(rootURL: paths.root).scan()))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.root.path))
    }

    func testInstallingIncludeDoesNotSilentlyActivateExistingUnindexedHosts() throws {
        let paths = try fixture()
        let directory = paths.root.deletingLastPathComponent().appendingPathComponent("config.d/Existing")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("Host already-there\n  HostName existing.example\n".utf8)
            .write(to: directory.appendingPathComponent("already-there.conf"))
        try Data("ServerAliveInterval 30\n".utf8).write(to: paths.root)
        let writer = ConfigWriter(rootURL: paths.root, backupDirectory: paths.backup)
        XCTAssertThrowsError(try writer.plan(.add(HostInput(alias: "new", hostName: "new.example", group: "New")),
                                                   from: ConfigReader(rootURL: paths.root).scan()))
        XCTAssertEqual(try String(contentsOf: paths.root, encoding: .utf8), "ServerAliveInterval 30\n")
    }

    func testGroupedHostIsVisibleToOpenSSHUsingFixtureOnly() throws {
        let paths = try fixture()
        let writer = ConfigWriter(rootURL: paths.root, backupDirectory: paths.backup)
        _ = try writer.commit(writer.plan(.add(HostInput(alias: "fixture-demo", hostName: "fixture.example", group: "Work")),
                                          from: ConfigReader(rootURL: paths.root).scan()))
        let validationConfig = paths.root.deletingLastPathComponent().appendingPathComponent("validation-config")
        let fixtureDirectory = paths.root.deletingLastPathComponent().appendingPathComponent("config.d")
        let absoluteIncludes = "Include \(fixtureDirectory.path)/*.conf\nInclude \(fixtureDirectory.path)/*/*.conf\n"
        try Data(absoluteIncludes.utf8).write(to: validationConfig)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-G", "-F", validationConfig.path, "fixture-demo"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let effective = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertTrue(effective.contains("hostname fixture.example"))
    }

    func testGlobalOptionEditPreservesCommentsIncludesAndHostBlocks() throws {
        let paths = try fixture()
        let original = Data("# header\r\nInclude config.d/*.conf\r\n\r\nHost root-host\r\n  User local\r\n".utf8)
        try original.write(to: paths.root)
        let writer = ConfigWriter(rootURL: paths.root, backupDirectory: paths.backup)
        let scan = ConfigReader(rootURL: paths.root).scan()
        let plan = try writer.planGlobalOptionUpdate(keyword: "ServerAliveInterval", value: "45", from: scan)
        XCTAssertEqual(plan.changes.count, 1)
        _ = try writer.commit(plan)
        let updated = try Data(contentsOf: paths.root)
        let updatedText = String(decoding: updated, as: UTF8.self)
        XCTAssertTrue(updatedText.hasPrefix("# header\r\nServerAliveInterval 45\r\nInclude config.d/*.conf\r\n"))
        XCTAssertTrue(updatedText.hasSuffix("Host root-host\r\n  User local\r\n"))
        XCTAssertEqual(ConfigReader(rootURL: paths.root).scan().globalOptions.first?.value, "45")

        let removePlan = try writer.planGlobalOptionUpdate(keyword: "ServerAliveInterval", value: "",
                                                           from: ConfigReader(rootURL: paths.root).scan())
        _ = try writer.commit(removePlan)
        XCTAssertFalse(String(decoding: try Data(contentsOf: paths.root), as: UTF8.self)
            .contains("ServerAliveInterval"))
    }

    func testGlobalOptionWriteChecksConflictAndRejectsUnknownOption() throws {
        let paths = try fixture()
        try Data("# untouched\n".utf8).write(to: paths.root)
        let scan = ConfigReader(rootURL: paths.root).scan()
        let writer = ConfigWriter(rootURL: paths.root, backupDirectory: paths.backup)
        XCTAssertThrowsError(try writer.planGlobalOptionUpdate(keyword: "ProxyCommand", value: "unsafe", from: scan))
        try Data("# external edit\n".utf8).write(to: paths.root)
        XCTAssertThrowsError(try writer.planGlobalOptionUpdate(keyword: "Port", value: "2200", from: scan))
        XCTAssertEqual(try String(contentsOf: paths.root, encoding: .utf8), "# external edit\n")
    }

    func testWholeRootEditPreviewsPreservesTextAndCanRestore() throws {
        let paths = try fixture()
        let original = "# keep this\r\nInclude config.d/*.conf\r\nHost *\r\n  ProxyCommand command --raw\r\n"
        try Data(original.utf8).write(to: paths.root)
        let writer = ConfigWriter(rootURL: paths.root, backupDirectory: paths.backup)
        let changed = original.replacingOccurrences(of: "# keep this", with: "# edited")
        let plan = try writer.planRootConfigReplacement(text: changed, from: ConfigReader(rootURL: paths.root).scan())
        XCTAssertEqual(try String(contentsOf: paths.root, encoding: .utf8), original)
        XCTAssertTrue(plan.changes[0].diff.contains("# edited"))
        let receipt = try writer.commit(plan)
        XCTAssertEqual(try String(contentsOf: paths.root, encoding: .utf8), changed)
        let backup = try XCTUnwrap(receipt.backups.first)
        _ = try writer.commit(writer.planRestore(backup))
        XCTAssertEqual(try String(contentsOf: paths.root, encoding: .utf8), original)
    }

    func testWholeRootEditRejectsExternalChangesAndSymlink() throws {
        let paths = try fixture()
        try Data("# original\n".utf8).write(to: paths.root)
        let writer = ConfigWriter(rootURL: paths.root, backupDirectory: paths.backup)
        let scan = ConfigReader(rootURL: paths.root).scan()
        let plan = try writer.planRootConfigReplacement(text: "# edited\n", from: scan)
        try Data("# external\n".utf8).write(to: paths.root)
        XCTAssertThrowsError(try writer.commit(plan))
        XCTAssertThrowsError(try writer.planRootConfigReplacement(text: "# edited\n", from: scan))
        XCTAssertEqual(try String(contentsOf: paths.root, encoding: .utf8), "# external\n")

        let link = paths.root.deletingLastPathComponent().appendingPathComponent("linked-config")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: paths.root)
        let linkedWriter = ConfigWriter(rootURL: link, backupDirectory: paths.backup)
        XCTAssertThrowsError(try linkedWriter.planRootConfigReplacement(text: "# edited\n",
                                                                         from: ConfigReader(rootURL: link).scan()))
    }

    func testWholeRootEditCanCreateMissingConfigButRejectsNoOpAndNUL() throws {
        let paths = try fixture()
        let writer = ConfigWriter(rootURL: paths.root, backupDirectory: paths.backup)
        let scan = ConfigReader(rootURL: paths.root).scan()
        XCTAssertThrowsError(try writer.planRootConfigReplacement(text: "a\0b", from: scan))
        let plan = try writer.planRootConfigReplacement(text: "# new config\n", from: scan)
        _ = try writer.commit(plan)
        XCTAssertEqual(try String(contentsOf: paths.root, encoding: .utf8), "# new config\n")
        XCTAssertThrowsError(try writer.planRootConfigReplacement(text: "# new config\n",
                                                                     from: ConfigReader(rootURL: paths.root).scan()))
    }

    func testWholeRootEditRejectsIntroducedSyntaxErrorsAndNeverRunsMatchExec() throws {
        let paths = try fixture()
        let marker = paths.root.deletingLastPathComponent().appendingPathComponent("must-not-run")
        try Data("Host demo\n  HostName demo.example\n".utf8).write(to: paths.root)
        let writer = ConfigWriter(rootURL: paths.root, backupDirectory: paths.backup)
        let scan = ConfigReader(rootURL: paths.root).scan()
        XCTAssertThrowsError(try writer.planRootConfigReplacement(text: "Host demo\n  User \"unfinished\n", from: scan))
        XCTAssertThrowsError(try writer.planRootConfigReplacement(text: "Host\n  User deploy\n", from: scan))
        let safe = "Host demo\n  HostName demo.example\nMatch exec /usr/bin/touch \(marker.path)\n  Port 22\n"
        let plan = try writer.planRootConfigReplacement(text: safe, from: scan)
        XCTAssertFalse(plan.warnings.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(try String(contentsOf: paths.root, encoding: .utf8), "Host demo\n  HostName demo.example\n")
    }

    func testWholeRootEditSurfacesNewIncludeWarningAndChecksExistingIncludeVersion() throws {
        let paths = try fixture()
        let included = paths.root.deletingLastPathComponent().appendingPathComponent("included.conf")
        try Data("Host included\n  HostName included.example\n".utf8).write(to: included)
        try Data("Include included.conf\n".utf8).write(to: paths.root)
        let writer = ConfigWriter(rootURL: paths.root, backupDirectory: paths.backup)
        let scan = ConfigReader(rootURL: paths.root).scan()
        let plan = try writer.planRootConfigReplacement(text: "Include included.conf\nInclude missing.conf\n", from: scan)
        XCTAssertTrue(plan.warnings.contains { $0.contains("missing.conf") })
        XCTAssertEqual(plan.checkedVersions.count, 2)
        try Data("# external change\nHost included\n".utf8).write(to: included)
        XCTAssertThrowsError(try writer.commit(plan))
        XCTAssertThrowsError(try writer.planRootConfigReplacement(text: "Include included.conf\n# change\n", from: scan))
    }

    func testLineDiffShowsTwoSeparateEditsWithContext() throws {
        let paths = try fixture()
        let before = (1...16).map { "# line \($0)" }.joined(separator: "\n") + "\n"
        try Data(before.utf8).write(to: paths.root)
        let after = before.replacingOccurrences(of: "# line 3", with: "# line three")
            .replacingOccurrences(of: "# line 14", with: "# line fourteen")
        let plan = try ConfigWriter(rootURL: paths.root, backupDirectory: paths.backup)
            .planRootConfigReplacement(text: after, from: ConfigReader(rootURL: paths.root).scan())
        let diff = try XCTUnwrap(plan.changes.first?.diff)
        XCTAssertEqual(diff.components(separatedBy: "@@ -").count - 1, 2)
        XCTAssertTrue(diff.contains("-# line 3"))
        XCTAssertTrue(diff.contains("+# line three"))
        XCTAssertTrue(diff.contains("-# line 14"))
        XCTAssertTrue(diff.contains("+# line fourteen"))
        XCTAssertFalse(diff.contains("# line 8"))
    }

    func testLineDiffHandlesRepeatedLinesAndLineEndingOnlyChanges() throws {
        let paths = try fixture()
        try Data("# same\n# repeat\n# same\n".utf8).write(to: paths.root)
        let writer = ConfigWriter(rootURL: paths.root, backupDirectory: paths.backup)
        let scan = ConfigReader(rootURL: paths.root).scan()
        let added = try writer.planRootConfigReplacement(text: "# same\n# repeat\n# new\n# same\n", from: scan)
        XCTAssertTrue(try XCTUnwrap(added.changes.first?.diff).contains("+# new"))
        let lineEnding = try writer.planRootConfigReplacement(text: "# same\r\n# repeat\r\n# same\r\n", from: scan)
        XCTAssertTrue(try XCTUnwrap(lineEnding.changes.first?.diff).contains("行尾格式"))
    }

    func testExternalChangeStopsCommitWithoutOverwriting() throws {
        let paths = try fixture()
        try Data("Host old\n HostName old.example\n".utf8).write(to: paths.root)
        let writer = ConfigWriter(rootURL: paths.root, backupDirectory: paths.backup)
        let plan = try writer.plan(.add(HostInput(alias: "new", hostName: "new.example")),
                                   from: ConfigReader(rootURL: paths.root).scan())
        let external = Data("# external\nHost old\n HostName old.example\n".utf8)
        try external.write(to: paths.root)
        XCTAssertThrowsError(try writer.commit(plan)) { error in
            XCTAssertTrue(error.localizedDescription.contains("修改"))
        }
        XCTAssertEqual(try Data(contentsOf: paths.root), external)
        XCTAssertFalse(FileManager.default.fileExists(atPath: writer.managedDirectoryURL.appendingPathComponent("new.conf").path))
    }

    func testImportedHostPatchPreservesCommentsUnknownOptionsAndOtherHosts() throws {
        let paths = try fixture()
        let original = Data("# heading\r\nHost demo\r\n  HostName old.example # keep this\r\n  CustomOption untouched\r\n  Port 22\r\n\r\nHost other\r\n  HostName other.example\r\n".utf8)
        try original.write(to: paths.root)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: paths.root.path)
        let writer = ConfigWriter(rootURL: paths.root, backupDirectory: paths.backup)
        let scan = ConfigReader(rootURL: paths.root).scan()
        let host = try XCTUnwrap(scan.hosts.first)
        var input = HostInput(host: host)
        input.hostName = "new.example"
        input.port = "2200"
        let plan = try writer.plan(.update(hostID: host.id, input: input), from: scan)
        XCTAssertEqual(try Data(contentsOf: paths.root), original)
        let receipt = try writer.commit(plan)
        let updated = try String(contentsOf: paths.root, encoding: .utf8)
        XCTAssertEqual(updated, "# heading\r\nHost demo\r\n  HostName new.example # keep this\r\n  CustomOption untouched\r\n  Port 2200\r\n\r\nHost other\r\n  HostName other.example\r\n")
        XCTAssertEqual(ConfigReader(rootURL: paths.root).scan().hosts.map(\.alias), ["demo", "other"])
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: paths.root.path))[.posixPermissions] as? Int, 0o640)
        let backup = try XCTUnwrap(receipt.backups.first)
        XCTAssertEqual(backup.originalMode, 0o640)
        _ = try writer.commit(writer.planRestore(backup))
        XCTAssertEqual(try Data(contentsOf: paths.root), original)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: paths.root.path))[.posixPermissions] as? Int, 0o640)
    }

    func testManagedDeletionCanBeRestoredFromVerifiedBackup() throws {
        let paths = try fixture()
        let writer = ConfigWriter(rootURL: paths.root, backupDirectory: paths.backup)
        let add = try writer.plan(.add(HostInput(alias: "demo", hostName: "demo.example")),
                                  from: ConfigReader(rootURL: paths.root).scan())
        _ = try writer.commit(add)
        let host = try XCTUnwrap(ConfigReader(rootURL: paths.root).scan().hosts.first)
        let deletion = try writer.plan(.delete(hostID: host.id), from: ConfigReader(rootURL: paths.root).scan())
        let receipt = try writer.commit(deletion)
        XCTAssertTrue(ConfigReader(rootURL: paths.root).scan().hosts.isEmpty)
        let backup = try XCTUnwrap(receipt.backups.first)
        XCTAssertTrue(try writer.backups.list().contains { $0.id == backup.id })

        let restore = try writer.planRestore(backup)
        XCTAssertTrue(restore.changes.first?.diff.contains("Host demo") == true)
        _ = try writer.commit(restore)
        XCTAssertEqual(ConfigReader(rootURL: paths.root).scan().hosts.map(\.alias), ["demo"])
    }

    func testImportedRootHostCanBeDeletedWithoutRemovingOtherRulesOrComments() throws {
        let paths = try fixture()
        let original = "# global\r\nServerAliveInterval 30\r\nHost first\r\n  HostName first.example\r\n  CustomOption untouched\r\n# keep this comment\r\n\r\nHost second\r\n  HostName second.example\r\n"
        try Data(original.utf8).write(to: paths.root)
        let writer = ConfigWriter(rootURL: paths.root, backupDirectory: paths.backup)
        let scan = ConfigReader(rootURL: paths.root).scan()
        let first = try XCTUnwrap(scan.hosts.first(where: { $0.alias == "first" }))
        let plan = try writer.plan(.delete(hostID: first.id), from: scan)
        XCTAssertEqual(plan.changes.count, 1)
        XCTAssertNotNil(plan.changes[0].after)
        XCTAssertEqual(try Data(contentsOf: paths.root), Data(original.utf8))
        let receipt = try writer.commit(plan)
        XCTAssertEqual(try String(contentsOf: paths.root, encoding: .utf8),
                       "# global\r\nServerAliveInterval 30\r\n# keep this comment\r\n\r\nHost second\r\n  HostName second.example\r\n")
        XCTAssertEqual(ConfigReader(rootURL: paths.root).scan().hosts.map(\.alias), ["second"])
        let backup = try XCTUnwrap(receipt.backups.first)
        _ = try writer.commit(writer.planRestore(backup))
        XCTAssertEqual(try String(contentsOf: paths.root, encoding: .utf8), original)
    }

    func testImportedMultiHostIncludeDeletesOnlySelectedBlock() throws {
        let paths = try fixture()
        let include = paths.root.deletingLastPathComponent().appendingPathComponent("imported.conf")
        try Data("Include imported.conf\n".utf8).write(to: paths.root)
        try Data("Host first\n  HostName first.example\n\nHost second\n  HostName second.example\n".utf8)
            .write(to: include)
        let writer = ConfigWriter(rootURL: paths.root, backupDirectory: paths.backup)
        let scan = ConfigReader(rootURL: paths.root).scan()
        let first = try XCTUnwrap(scan.hosts.first(where: { $0.alias == "first" }))
        let plan = try writer.plan(.delete(hostID: first.id), from: scan)
        _ = try writer.commit(plan)
        XCTAssertEqual(try String(contentsOf: include, encoding: .utf8),
                       "\nHost second\n  HostName second.example\n")
        XCTAssertEqual(try String(contentsOf: paths.root, encoding: .utf8), "Include imported.conf\n")
    }

    func testChangeBeforePreviewIsRejected() throws {
        let paths = try fixture()
        try Data("Host old\n HostName old.example\n".utf8).write(to: paths.root)
        let scan = ConfigReader(rootURL: paths.root).scan()
        let external = Data("# new line\nHost old\n HostName old.example\n".utf8)
        try external.write(to: paths.root)

        let writer = ConfigWriter(rootURL: paths.root, backupDirectory: paths.backup)
        XCTAssertThrowsError(try writer.plan(.add(HostInput(alias: "new", hostName: "new.example")), from: scan))
        XCTAssertEqual(try Data(contentsOf: paths.root), external)
    }

    func testRestoreRefusesFileChangedAfterBackup() throws {
        let paths = try fixture()
        let writer = ConfigWriter(rootURL: paths.root, backupDirectory: paths.backup)
        _ = try writer.commit(writer.plan(.add(HostInput(alias: "demo", hostName: "demo.example")),
                                          from: ConfigReader(rootURL: paths.root).scan()))
        let host = try XCTUnwrap(ConfigReader(rootURL: paths.root).scan().hosts.first)
        let receipt = try writer.commit(writer.plan(.delete(hostID: host.id),
                                                   from: ConfigReader(rootURL: paths.root).scan()))
        let backup = try XCTUnwrap(receipt.backups.first)
        let external = Data("# changed after deletion\n".utf8)
        try external.write(to: writer.managedDirectoryURL.appendingPathComponent("demo.conf"))
        XCTAssertThrowsError(try writer.planRestore(backup))
        XCTAssertEqual(try Data(contentsOf: writer.managedDirectoryURL.appendingPathComponent("demo.conf")), external)
    }

    func testSymlinkedConfigIsNeverReplaced() throws {
        let paths = try fixture()
        let target = paths.root.deletingLastPathComponent().appendingPathComponent("real-config")
        try Data("Host old\n HostName old.example\n".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: paths.root, withDestinationURL: target)
        let writer = ConfigWriter(rootURL: paths.root, backupDirectory: paths.backup)
        XCTAssertThrowsError(try writer.plan(.add(HostInput(alias: "new", hostName: "new.example")),
                                                   from: ConfigReader(rootURL: paths.root).scan()))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "Host old\n HostName old.example\n")
    }

    func testImportedHostThroughSymlinkedDirectoryCannotBeEdited() throws {
        let paths = try fixture()
        let ssh = paths.root.deletingLastPathComponent()
        let actual = ssh.appendingPathComponent("actual")
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
        let linked = ssh.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: actual)
        let included = actual.appendingPathComponent("hosts.conf")
        let original = Data("Host demo\n HostName demo.example\n".utf8)
        try original.write(to: included)
        try Data("Include linked/hosts.conf\n".utf8).write(to: paths.root)
        let scan = ConfigReader(rootURL: paths.root).scan()
        let host = try XCTUnwrap(scan.hosts.first)
        var input = HostInput(host: host)
        input.hostName = "new.example"
        let writer = ConfigWriter(rootURL: paths.root, backupDirectory: paths.backup)
        XCTAssertThrowsError(try writer.plan(.update(hostID: host.id, input: input), from: scan))
        XCTAssertEqual(try Data(contentsOf: included), original)
    }

    func testManagedFileRollsBackIfRootInstallationFails() throws {
        let paths = try fixture()
        let writer = ConfigWriter(rootURL: paths.root, backupDirectory: paths.backup)
        let plan = try writer.plan(.add(HostInput(alias: "demo", hostName: "demo.example")),
                                   from: ConfigReader(rootURL: paths.root).scan())
        let invalidTarget = paths.root.deletingLastPathComponent()
        let second = try XCTUnwrap(plan.changes.last)
        let broken = PlannedFileChange(url: invalidTarget, before: second.before,
                                       after: second.after, expectedVersion: second.expectedVersion)
        let failingPlan = ConfigChangePlan(title: plan.title, targetAlias: plan.targetAlias,
                                           checkedVersions: plan.checkedVersions,
                                           changes: [try XCTUnwrap(plan.changes.first), broken])
        XCTAssertThrowsError(try writer.commit(failingPlan))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.root.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: writer.managedDirectoryURL.appendingPathComponent("demo.conf").path))
    }

    func testDeletingManagedHostKeepsOtherRulesInSameFile() throws {
        let paths = try fixture()
        try Data("Include config.d/*.conf\n".utf8).write(to: paths.root)
        let writer = ConfigWriter(rootURL: paths.root, backupDirectory: paths.backup)
        try FileManager.default.createDirectory(at: writer.managedDirectoryURL, withIntermediateDirectories: true)
        let file = writer.managedDirectoryURL.appendingPathComponent("web.conf")
        for trailer in ["Host *.corp\n  User ops\n", "Match host db\n  User admin\n", "Host a b\n  Port 22\n"] {
            let original = Data("Host web\n  HostName web.example\n\n\(trailer)".utf8)
            try original.write(to: file)
            let scan = ConfigReader(rootURL: paths.root).scan()
            let host = try XCTUnwrap(scan.hosts.first { $0.alias == "web" })
            let plan = try writer.plan(.delete(hostID: host.id), from: scan)
            let after = try XCTUnwrap(plan.changes.first?.after, "whole file deletion would drop: \(trailer)")
            XCTAssertTrue(String(decoding: after, as: UTF8.self).hasSuffix(trailer))
            XCTAssertFalse(String(decoding: after, as: UTF8.self).contains("Host web"))
        }
    }

    func testGlobalOptionInsertAfterCommentWithoutTrailingNewline() throws {
        let paths = try fixture()
        let writer = ConfigWriter(rootURL: paths.root, backupDirectory: paths.backup)
        for (original, expected) in [("# my config", "# my config\nServerAliveInterval 30\n"),
                                     ("# a\r\n# b", "# a\r\n# b\r\nServerAliveInterval 30\r\n")] {
            try Data(original.utf8).write(to: paths.root)
            let scan = ConfigReader(rootURL: paths.root).scan()
            _ = try writer.commit(writer.planGlobalOptionUpdate(keyword: "ServerAliveInterval", value: "30", from: scan))
            XCTAssertEqual(try String(contentsOf: paths.root, encoding: .utf8), expected)
            XCTAssertEqual(ConfigReader(rootURL: paths.root).scan().globalOptions.map(\.keyword), ["ServerAliveInterval"])
        }
    }

    func testCommitRefusesDirectorySwappedForSymlinkAfterPreview() throws {
        let paths = try fixture()
        let writer = ConfigWriter(rootURL: paths.root, backupDirectory: paths.backup)
        _ = try writer.commit(writer.plan(.add(HostInput(alias: "web", hostName: "web.example", group: "Work")),
                                          from: ConfigReader(rootURL: paths.root).scan()))
        let scan = ConfigReader(rootURL: paths.root).scan()
        let host = try XCTUnwrap(scan.hosts.first { $0.alias == "web" })
        let plan = try writer.plan(.update(hostID: host.id, input: HostInput(alias: "web", hostName: "changed.example", group: "Work")),
                                   from: scan)
        let outside = paths.backup.deletingLastPathComponent().appendingPathComponent("outside")
        for swapped in [writer.managedDirectoryURL.appendingPathComponent("Work"), writer.managedDirectoryURL] {
            try FileManager.default.moveItem(at: swapped, to: outside)
            try FileManager.default.createSymbolicLink(at: swapped, withDestinationURL: outside)
            let moved = swapped == writer.managedDirectoryURL ? outside.appendingPathComponent("Work/web.conf")
                                                               : outside.appendingPathComponent("web.conf")
            let before = try Data(contentsOf: moved)
            XCTAssertThrowsError(try writer.commit(plan), "swapped \(swapped.lastPathComponent)")
            XCTAssertEqual(try Data(contentsOf: moved), before)
            try FileManager.default.removeItem(at: swapped)
            try FileManager.default.moveItem(at: outside, to: swapped)
        }
        XCTAssertEqual(try writer.backups.list().count, 2, "no backup may be taken through the symlink")
    }
}
