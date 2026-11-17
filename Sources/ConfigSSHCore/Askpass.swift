import Darwin
import Foundation

/// What OpenSSH is asking for when it runs the askpass helper.
///
/// With `SSH_ASKPASS_REQUIRE=force` every prompt goes through the helper, so the helper must
/// never answer by itself: each kind maps to a dialog the user answers explicitly.
package enum AskpassPromptKind: Equatable, Sendable {
    /// Passwords, key passphrases, PINs and any other free-form prompt (input is hidden).
    case secret
    /// "Are you sure you want to continue connecting (yes/no/[fingerprint])?"
    case hostKeyConfirmation
    /// `SSH_ASKPASS_PROMPT=confirm` (for example ssh-agent key confirmation).
    case confirmation
    /// `SSH_ASKPASS_PROMPT=none`: a notice that expects no answer.
    case information
}

package struct AskpassRequest: Equatable, Sendable {
    package static let maximumMessageLength = 1000

    package let message: String
    package let kind: AskpassPromptKind

    package init(arguments: [String], environment: [String: String]) {
        let message = Self.sanitize(arguments.joined(separator: " "))
        self.message = message
        switch environment["SSH_ASKPASS_PROMPT"]?.lowercased() {
        case "confirm": kind = .confirmation
        case "none": kind = .information
        default:
            kind = message.lowercased().contains("are you sure you want to continue connecting")
                ? .hostKeyConfirmation : .secret
        }
    }

    /// The prompt text can come from the remote server (keyboard-interactive), so drop control
    /// characters other than newline and tab, and cap the length shown in the dialog.
    package static func sanitize(_ raw: String) -> String {
        let scalars = raw.unicodeScalars.filter { scalar in
            scalar == "\n" || scalar == "\t" || !CharacterSet.controlCharacters.contains(scalar)
        }
        var text = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > maximumMessageLength {
            text = String(text.prefix(maximumMessageLength)) + "…"
        }
        return text.isEmpty ? "OpenSSH 请求输入" : text
    }
}

package enum AskpassAnswer: Equatable, Sendable {
    case text(String)
    case approved
    case rejected
    case cancelled
    case acknowledged
}

@MainActor
package protocol AskpassPresenter {
    func present(_ request: AskpassRequest) -> AskpassAnswer
}

package enum AskpassResponder {
    package struct Output: Equatable, Sendable {
        package let stdout: String
        package let exitCode: Int32
    }

    /// Asks the presenter exactly once and converts the answer into what OpenSSH reads from the
    /// helper: the text on stdout and exit status 0, or no output and a non-zero status.
    /// An answer that does not fit the prompt kind is treated as a cancellation.
    @MainActor
    package static func respond(to request: AskpassRequest, using presenter: AskpassPresenter) -> Output {
        let answer = presenter.present(request)
        switch (request.kind, answer) {
        case (.secret, .text(let value)):
            let line = value.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
            return Output(stdout: line + "\n", exitCode: 0)
        case (.hostKeyConfirmation, .approved):
            return Output(stdout: "yes\n", exitCode: 0)
        case (.confirmation, .approved), (.information, .acknowledged):
            return Output(stdout: "", exitCode: 0)
        default:
            return Output(stdout: "", exitCode: 1)
        }
    }
}

/// Finds the bundled `configssh-askpass`: `Contents/Helpers/` in the packaged app, or next to
/// the executable in a SwiftPM build directory. Symlinks are refused.
package enum AskpassHelperLocator {
    package static let executableName = "configssh-askpass"

    package static func helperURL(mainExecutable: URL? = Bundle.main.executableURL) -> URL? {
        guard let directory = mainExecutable?.resolvingSymlinksInPath().deletingLastPathComponent() else { return nil }
        let candidates = [
            directory.deletingLastPathComponent().appendingPathComponent("Helpers").appendingPathComponent(executableName),
            directory.appendingPathComponent(executableName)
        ]
        return candidates.first(where: isRegularExecutable)
    }

    private static func isRegularExecutable(_ url: URL) -> Bool {
        var info = stat()
        guard url.path.withCString({ lstat($0, &info) }) == 0,
              info.st_mode & S_IFMT == S_IFREG else { return false }
        return FileManager.default.isExecutableFile(atPath: url.path)
    }
}

/// ConfigSSH passes its own PID to the askpass helper. If ConfigSSH has gone away (crashed or was
/// force-quit) the helper must not keep a password dialog on screen for an orphaned ssh.
package enum AskpassParentWatch {
    package static let environmentKey = "CONFIGSSH_PARENT_PID"

    package static func parentPID(in environment: [String: String]) -> pid_t? {
        environment[environmentKey].flatMap { pid_t($0) }.flatMap { $0 > 1 ? $0 : nil }
    }

    package static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}
