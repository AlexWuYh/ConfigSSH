import AppKit
import ConfigSSHCore

/// OpenSSH askpass helper for ConfigSSH.
///
/// ssh runs this program with the prompt as its argument when `SSH_ASKPASS_REQUIRE=force` is set
/// on the ssh process that ConfigSSH started. The answer is written only to stdout for ssh to
/// read; nothing is logged or written to disk, and every prompt needs an explicit user answer.
@MainActor
struct AlertPresenter: AskpassPresenter {
    func present(_ request: AskpassRequest) -> AskpassAnswer {
        let alert = NSAlert()
        // Contents/Helpers/configssh-askpass → Contents/Resources/ConfigSSH.icns, so the dialog shows
        // the app's icon rather than a generic one.
        if let helper = Bundle.main.executableURL?.resolvingSymlinksInPath(),
           let icon = NSImage(contentsOf: helper.deletingLastPathComponent().deletingLastPathComponent()
                                .appendingPathComponent("Resources/ConfigSSH.icns")) {
            alert.icon = icon
        }
        alert.messageText = title(for: request.kind)
        alert.informativeText = request.message
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        switch request.kind {
        case .secret:
            alert.alertStyle = .informational
            alert.accessoryView = field
            alert.addButton(withTitle: "继续")
            alert.addButton(withTitle: "取消")
        case .hostKeyConfirmation:
            alert.alertStyle = .warning
            alert.informativeText = request.message +
                "\n\n请先通过可信渠道核对服务器指纹。不确定时请选择“拒绝”。"
            alert.addButton(withTitle: "拒绝")
            alert.addButton(withTitle: "信任并继续")
        case .confirmation:
            alert.alertStyle = .warning
            alert.addButton(withTitle: "拒绝")
            alert.addButton(withTitle: "允许")
        case .information:
            alert.addButton(withTitle: "好")
        }
        NSApp.activate()
        if request.kind == .secret {
            alert.window.initialFirstResponder = field
        }
        let response = alert.runModal()
        switch request.kind {
        case .secret:
            return response == .alertFirstButtonReturn ? .text(field.stringValue) : .cancelled
        case .hostKeyConfirmation, .confirmation:
            return response == .alertSecondButtonReturn ? .approved : .rejected
        case .information:
            return .acknowledged
        }
    }

    private func title(for kind: AskpassPromptKind) -> String {
        switch kind {
        case .secret: "SSH 需要输入"
        case .hostKeyConfirmation: "首次连接此服务器"
        case .confirmation: "SSH 请求确认"
        case .information: "SSH 提示"
        }
    }
}

let request = AskpassRequest(arguments: Array(CommandLine.arguments.dropFirst()),
                             environment: ProcessInfo.processInfo.environment)
NSApplication.shared.setActivationPolicy(.accessory)
let output = AskpassResponder.respond(to: request, using: AlertPresenter())
FileHandle.standardOutput.write(Data(output.stdout.utf8))
exit(output.exitCode)
