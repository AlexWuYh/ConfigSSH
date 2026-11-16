import AppKit
import ConfigSSHCore
import SwiftUI

struct KeyGenerationView: View {
    let onGenerated: (URL) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var algorithm: SSHKeyAlgorithm = .ed25519
    @State private var path: String
    @State private var automaticPath: String
    @State private var comment = ""
    @State private var errorMessage: String?
    @State private var isGenerating = false
    @State private var confirmGenerate = false

    init(onGenerated: @escaping (URL) -> Void) {
        self.onGenerated = onGenerated
        let sshDirectory = ConfigSSHPaths.sshDirectory
        let suggested = SSHKeyGenerator.suggestedPath(in: sshDirectory, algorithm: .ed25519).path
        _path = State(initialValue: suggested)
        _automaticPath = State(initialValue: suggested)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Form {
                    Section("密钥参数") {
                        Picker("算法", selection: $algorithm) {
                            ForEach(SSHKeyAlgorithm.allCases) { option in
                                Text(option.displayName).tag(option)
                            }
                        }
                        HStack {
                            TextField("私钥保存路径", text: $path)
                            Button("选择…", action: choosePath)
                        }
                        TextField("备注", text: $comment)
                    }
                    Section("文件安全") {
                        Label("不会覆盖已存在的私钥或公钥。", systemImage: "checkmark.shield")
                        Label("私钥不会发送到网络，也不会读入应用。", systemImage: "lock")
                        Text("生成的私钥不设口令，文件权限限制为当前用户。若需要口令保护，可生成后在终端使用 ssh-keygen -p 加密。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .padding(12)
                }

                Divider()
                HStack {
                    Button("取消") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button(isGenerating ? "正在生成…" : "生成密钥") {
                        confirmGenerate = true
                    }
                    .disabled(isGenerating || path.isEmpty)
                    .buttonStyle(.borderedProminent)
                }
                .padding(16)
            }
            .navigationTitle("生成 SSH 密钥")
            .frame(minWidth: 540, minHeight: 430)
            .confirmationDialog("生成新的 \(algorithm.displayName) 密钥？", isPresented: $confirmGenerate) {
                Button("生成", role: .destructive) { generate() }
                Button("取消", role: .cancel) { }
            } message: {
                Text("私钥将写入 \(expandedPath.path)，现有文件不会被覆盖。")
            }
            .onChange(of: algorithm) { _, current in
                guard path == automaticPath else { return }
                let sshDirectory = ConfigSSHPaths.sshDirectory
                let suggested = SSHKeyGenerator.suggestedPath(in: sshDirectory, algorithm: current).path
                path = suggested
                automaticPath = suggested
            }
        }
    }

    private var expandedPath: URL {
        if path.hasPrefix("~/") {
            return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(String(path.dropFirst(2)))
        }
        return URL(fileURLWithPath: path)
    }

    private func choosePath() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = expandedPath.lastPathComponent
        panel.directoryURL = expandedPath.deletingLastPathComponent()
        panel.canCreateDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        path = url.path
    }

    private func generate() {
        isGenerating = true
        errorMessage = nil
        let destination = expandedPath
        let selectedAlgorithm = algorithm
        let keyComment = comment
        Task { @MainActor in
            do {
                try await Task.detached(priority: .userInitiated) {
                    try SSHKeyGenerator.generate(path: destination, algorithm: selectedAlgorithm, comment: keyComment)
                }.value
                isGenerating = false
                onGenerated(destination)
                dismiss()
            } catch {
                isGenerating = false
                errorMessage = error.localizedDescription
            }
        }
    }
}
