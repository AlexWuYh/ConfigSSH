import ConfigSSHCore
import SwiftUI

struct HostMetadataSheet: View {
    let host: HostRecord
    let onSave: (HostMetadata) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var metadata: HostMetadata
    @State private var tagsText: String
    @State private var terminalRaw: String
    @State private var openModeRaw: String
    @State private var errorMessage: String?

    private var terminals: [TerminalProfile] { TerminalCatalog.shared.installed() }

    init(host: HostRecord, existing: HostMetadata?, onSave: @escaping (HostMetadata) throws -> Void) {
        self.host = host
        self.onSave = onSave
        let initial = existing ?? HostMetadata(hostKey: host.metadataKey)
        _metadata = State(initialValue: initial)
        _tagsText = State(initialValue: initial.tags.joined(separator: ", "))
        _terminalRaw = State(initialValue: initial.preferredTerminal ?? "default")
        _openModeRaw = State(initialValue: initial.preferredOpenMode ?? "default")
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Form {
                    Section("显示") {
                        TextField("显示名称", text: $metadata.displayName)
                        if let folderGroup = host.configGroup {
                            LabeledContent("文件分组", value: folderGroup)
                            Text("此分组来自 config.d 下的目录。")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            TextField("分组", text: $metadata.groupName)
                        }
                        TextField("标签（逗号分隔）", text: $tagsText)
                        Toggle("收藏", isOn: $metadata.isFavorite)
                    }
                    Section("连接偏好") {
                        Picker("默认终端", selection: $terminalRaw) {
                            Text("跟随全局设置").tag("default")
                            ForEach(terminals) { terminal in
                                Text(terminal.displayName).tag(terminal.id)
                            }
                        }
                        Picker("打开方式", selection: $openModeRaw) {
                            Text("跟随全局设置").tag("default")
                            ForEach(TerminalOpenMode.allCases) { mode in
                                Text(mode.displayName).tag(mode.rawValue)
                            }
                        }
                    }
                    Section("备注") {
                        TextEditor(text: $metadata.note)
                            .frame(minHeight: 80)
                    }
                }
                .formStyle(.grouped)
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .padding()
                }
                Divider()
                HStack {
                    Button("取消") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("保存") {
                        metadata.tags = tagsText.split(separator: ",")
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                        metadata.preferredTerminal = terminalRaw == "default" ? nil : terminalRaw
                        metadata.preferredOpenMode = openModeRaw == "default" ? nil : openModeRaw
                        do {
                            try onSave(metadata)
                            dismiss()
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                }
                .padding(16)
            }
            .navigationTitle("主机信息 · \(host.alias)")
            .frame(minWidth: 540, minHeight: 500)
        }
    }
}
