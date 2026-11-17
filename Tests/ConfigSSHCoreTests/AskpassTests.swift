import Foundation
import XCTest
@testable import ConfigSSHCore

@MainActor
private final class ScriptedPresenter: AskpassPresenter {
    var answer: AskpassAnswer
    private(set) var presented: [AskpassRequest] = []
    init(_ answer: AskpassAnswer) { self.answer = answer }
    func present(_ request: AskpassRequest) -> AskpassAnswer {
        presented.append(request)
        return answer
    }
}

@MainActor
final class AskpassTests: XCTestCase {
    private let hostKeyPrompt = """
    The authenticity of host '[127.0.0.1]:22999 ([127.0.0.1]:22999)' can't be established.
    ED25519 key fingerprint is SHA256:abc.
    Are you sure you want to continue connecting (yes/no/[fingerprint])?
    """

    func testPromptKinds() {
        XCTAssertEqual(AskpassRequest(arguments: ["deploy@127.0.0.1's password: "], environment: [:]).kind, .secret)
        XCTAssertEqual(AskpassRequest(arguments: ["Enter passphrase for key '/tmp/k': "], environment: [:]).kind, .secret)
        XCTAssertEqual(AskpassRequest(arguments: ["Verification code: "], environment: [:]).kind, .secret,
                       "unknown prompts are answered by the user in a hidden field, never automatically")
        XCTAssertEqual(AskpassRequest(arguments: [hostKeyPrompt], environment: [:]).kind, .hostKeyConfirmation)
        XCTAssertEqual(AskpassRequest(arguments: ["Allow use of key?"], environment: ["SSH_ASKPASS_PROMPT": "confirm"]).kind,
                       .confirmation)
        XCTAssertEqual(AskpassRequest(arguments: ["Touch your key"], environment: ["SSH_ASKPASS_PROMPT": "none"]).kind,
                       .information)
    }

    func testSanitizeDropsControlCharactersAndCapsLength() {
        let request = AskpassRequest(arguments: ["pass\u{1B}[2Jword:\u{7}\u{0}"], environment: [:])
        XCTAssertEqual(request.message, "pass[2Jword:")
        let long = AskpassRequest(arguments: [String(repeating: "x", count: 5000)], environment: [:])
        XCTAssertEqual(long.message.count, AskpassRequest.maximumMessageLength + 1)
        XCTAssertEqual(AskpassRequest(arguments: [], environment: [:]).message, "OpenSSH 请求输入")
    }

    func testSecretIsReturnedOnStdoutOnlyOnce() {
        let presenter = ScriptedPresenter(.text("s3cret\nignored"))
        let output = AskpassResponder.respond(to: AskpassRequest(arguments: ["password:"], environment: [:]),
                                              using: presenter)
        XCTAssertEqual(output, .init(stdout: "s3cretignored\n", exitCode: 0), "a newline cannot inject a second answer")
        XCTAssertEqual(presenter.presented.count, 1)
    }

    func testCancellationAndRejectionNeverAnswer() {
        for (prompt, answer) in [("password:", AskpassAnswer.cancelled),
                                 (hostKeyPrompt, .rejected),
                                 (hostKeyPrompt, .cancelled),
                                 (hostKeyPrompt, .text("yes")),
                                 ("password:", .approved)] {
            let output = AskpassResponder.respond(to: AskpassRequest(arguments: [prompt], environment: [:]),
                                                  using: ScriptedPresenter(answer))
            XCTAssertEqual(output, .init(stdout: "", exitCode: 1), "\(prompt) / \(answer)")
        }
    }

    func testHostKeyIsTrustedOnlyByExplicitApproval() {
        let output = AskpassResponder.respond(to: AskpassRequest(arguments: [hostKeyPrompt], environment: [:]),
                                              using: ScriptedPresenter(.approved))
        XCTAssertEqual(output, .init(stdout: "yes\n", exitCode: 0))
    }

    func testHelperLocatorPrefersBundleHelpersAndRefusesSymlinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ConfigSSHAskpass-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let macOS = root.appendingPathComponent("ConfigSSH.app/Contents/MacOS")
        let helpers = root.appendingPathComponent("ConfigSSH.app/Contents/Helpers")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        let main = macOS.appendingPathComponent("ConfigSSH")
        try Data().write(to: main)
        XCTAssertNil(AskpassHelperLocator.helperURL(mainExecutable: main))

        let elsewhere = root.appendingPathComponent("evil")
        try Data("#!/bin/sh\n".utf8).write(to: elsewhere)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: elsewhere.path)
        try FileManager.default.createSymbolicLink(at: helpers.appendingPathComponent("configssh-askpass"),
                                                   withDestinationURL: elsewhere)
        XCTAssertNil(AskpassHelperLocator.helperURL(mainExecutable: main), "a symlinked helper is refused")

        try FileManager.default.removeItem(at: helpers.appendingPathComponent("configssh-askpass"))
        let helper = helpers.appendingPathComponent("configssh-askpass")
        try Data("#!/bin/sh\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        XCTAssertEqual(AskpassHelperLocator.helperURL(mainExecutable: main)?.standardizedFileURL, helper.standardizedFileURL)
    }

    func testBuiltHelperExistsNextToTheTestBundle() throws {
        // `swift build` places every executable product in the same directory as the test bundle.
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let helper = products.appendingPathComponent(AskpassHelperLocator.executableName)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: helper.path), helper.path)
    }
}
