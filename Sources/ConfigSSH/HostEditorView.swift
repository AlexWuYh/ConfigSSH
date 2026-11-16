import ConfigSSHCore
import SwiftUI
import UniformTypeIdentifiers

enum HostEditorMode {
    case add(group: String)
    case edit(HostRecord)
    case delete(HostRecord)

    var title: String {
        switch self {
        case .add: "新增主机"
        case .edit(let host): "编辑 \(host.alias)"
        case .delete(let host): "删除 \(host.alias)"
        }
    }

    var existingHost: HostRecord? {
        switch self {
        case .add: nil
        case .edit(let host), .delete(let host): host
        }
    }
}

struct HostEditorView: View {
    let mode: HostEditorMode
    let writer: ConfigWriter
    let availableKeys: [PublicKeyRecord]
    let availableGroups: [String]
    let onCommit: (String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var workingScan: ConfigScan
    @State private var input: HostInput
    @State private var plan: ConfigChangePlan?
    @State private var errorMessage: String?
    @State private var diskComparison: String?
    @State private var showsKeyPicker = false

    init(mode: HostEditorMode, scan: ConfigScan, writer: ConfigWriter, availableKeys: [PublicKeyRecord],
         availableGroups: [String],
         onCommit: @escaping (String?) -> Void) {
        self.mode = mode
        self.writer = writer
        self.availableKeys = availableKeys.filter(\.privateKeyExists)
        self.availableGroups = availableGroups.filter { $0 != "未分组" }
        self.onCommit = onCommit
        _workingScan = State(initialValue: scan)
        switch mode {
        case .add(let group): _input = State(initialValue: HostInput(group: group))
        case .edit(let host), .delete(let host): _input = State(initialValue: HostInput(host: host))
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let plan {
                    preview(plan)
                } else if case .delete(let host) = mode {
                    VStack(alignment: .leading, spacing: 14) {
                        Label("将删除 Host \(host.alias) 的配置。", systemImage: "trash")
                            .font(.title3)
                        Text(host.sourceURL.path)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Text("受管独立主机文件会删除整文件；其他来源仅移除该 Host 配置块，保留相邻规则与注释。保存前可预览差异，并为原文件建立备份。")
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
                } else {
                    Form {
                        Section("基本信息") {
                            TextField("Host Alias", text: $input.alias)
                                .disabled(mode.existingHost != nil)
                            if case .add = mode {
                                TextField("分组（留空则保存到 config.d）", text: $input.group)
                                if !availableGroups.isEmpty {
                                    Menu("选择现有分组") {
                                        ForEach(availableGroups, id: \.self) { group in
                                            Button(group) { input.group = group }
                                        }
                                    }
                                }
                                Text("有分组时保存为 ~/.ssh/config.d/分组/别名.conf")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else if !input.group.isEmpty {
                                LabeledContent("文件分组", value: input.group)
                            }
                            TextField("HostName", text: $input.hostName)
                            TextField("User", text: $input.user)
                            TextField("Port", text: $input.port)
                        }
                        Section("认证与跳板") {
                            HStack {
                                TextField("IdentityFile 路径", text: $input.identityFile)
                                Button("选择…") { showsKeyPicker = true }
                            }
                            if !availableKeys.isEmpty {
                                Menu("选择密钥页面中的已有密钥") {
                                    ForEach(availableKeys) { key in
                                        Button("\(key.name) · \(key.type)") {
                                            input.identityFile = key.privateKeyURL.path
                                            plan = nil
                                        }
                                    }
                                }
                            }
                            TextField("ProxyJump", text: $input.proxyJump)
                        }
                        if let host = mode.existingHost {
                            Section("配置来源") {
                                Text("\(host.sourceURL.path):\(host.sourceLine)")
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .formStyle(.grouped)
                }

                if let currentError = errorMessage {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(currentError, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                        if let diskComparison {
                            Text("磁盘版本相对预览版本的变化")
                                .font(.caption.bold())
                            ScrollView {
                                Text(diskComparison)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 120)
                        }
                        HStack {
                            Button("重新载入并保留草稿") {
                                workingScan = ConfigReader(rootURL: writer.rootURL).scan()
                                plan = nil
                                self.errorMessage = nil
                                diskComparison = nil
                            }
                            Spacer()
                        }
                    }
                    .padding(16)
                    .background(.quaternary.opacity(0.4))
                }

                Divider()
                HStack {
                    Button("取消") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                    if plan != nil {
                        Button("返回编辑") {
                            self.plan = nil
                            errorMessage = nil
                            diskComparison = nil
                        }
                    }
                    Button(plan == nil ? "预览变更" : "确认写入") {
                        if let plan { commit(plan) } else { prepare() }
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                }
                .padding(16)
            }
            .navigationTitle(mode.title)
            .frame(minWidth: 620, minHeight: 520)
        }
        .fileImporter(isPresented: $showsKeyPicker, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result {
                input.identityFile = url.path
                plan = nil
            }
        }
    }

    private func preview(_ plan: ConfigChangePlan) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("请确认以下文件变更")
                    .font(.title3.bold())
                ForEach(Array(plan.changes.enumerated()), id: \.offset) { _, change in
                    GroupBox(change.url.path) {
                        Text(change.diff)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                }
                Text("确认后会先检查磁盘版本，再建立备份并写入。")
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func prepare() {
        errorMessage = nil
        diskComparison = nil
        do {
            let action: ConfigEditAction
            switch mode {
            case .add:
                action = .add(input)
            case .edit(let original):
                let id = currentID(for: original)
                action = .update(hostID: id, input: input)
            case .delete(let original):
                action = .delete(hostID: currentID(for: original))
            }
            plan = try writer.plan(action, from: workingScan)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func commit(_ plan: ConfigChangePlan) {
        errorMessage = nil
        diskComparison = nil
        do {
            _ = try writer.commit(plan)
            onCommit(plan.targetAlias)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            diskComparison = plan.changes.compactMap { change in
                guard let current = try? SafeFileIO.snapshot(at: change.url),
                      current.data != change.before else { return nil }
                let difference = PlannedFileChange(
                    url: change.url, before: change.before, after: current.data,
                    expectedVersion: change.expectedVersion
                )
                return "\(change.url.path)\n\(difference.diff)"
            }.joined(separator: "\n\n")
        }
    }

    private func currentID(for original: HostRecord) -> String {
        workingScan.hosts.first {
            $0.alias == original.alias && $0.sourceURL == original.sourceURL
        }?.id ?? original.id
    }
}
