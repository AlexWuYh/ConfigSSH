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
    @State private var isReloading = false
    @State private var identitiesOnlyNeedsKey = false
    @State private var reuseMinutes = ConnectionReuse.defaultMinutes

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
        case .edit(let host), .delete(let host):
            let input = HostInput(host: host)
            _input = State(initialValue: input)
            if case .minutes(let minutes) = input.connectionReuse { _reuseMinutes = State(initialValue: minutes) }
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
                            identitiesOnlyControl
                            TextField("ProxyJump", text: $input.proxyJump)
                        }
                        Section("连接复用") {
                            connectionReuseControl
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
                                let root = writer.rootURL
                                isReloading = true
                                Task {
                                    let refreshed = await Task.detached(priority: .userInitiated) {
                                        ConfigReader(rootURL: root).scan()
                                    }.value
                                    workingScan = refreshed
                                    plan = nil
                                    self.errorMessage = nil
                                    diskComparison = nil
                                    isReloading = false
                                }
                            }
                            .disabled(isReloading)
                            if isReloading { ProgressView().controlSize(.small) }
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
            .frame(minWidth: 620, minHeight: 520, idealHeight: 600)
        }
        .fileImporter(isPresented: $showsKeyPicker, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result {
                input.identityFile = url.path
                plan = nil
            }
        }
    }

    private var hasIdentityFile: Bool {
        !input.identityFile.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// An imported host that already uses `IdentitiesOnly yes` with a key inherited from another
    /// rule (for example `Host *`) may keep it; the core planner applies the same exception.
    private var inheritsKeyForIdentitiesOnly: Bool {
        guard let host = mode.existingHost, !hasIdentityFile else { return false }
        return host.option("IdentitiesOnly").flatMap(IdentitiesOnlyChoice.init(configValue:)) == .yes &&
            host.option("IdentityFile") == nil
    }

    private var identitiesOnlySelection: Binding<IdentitiesOnlyChoice> {
        Binding(
            get: { input.identitiesOnly },
            set: { choice in
                if choice == .yes && !hasIdentityFile && !inheritsKeyForIdentitiesOnly {
                    identitiesOnlyNeedsKey = true
                    return
                }
                identitiesOnlyNeedsKey = false
                input.identitiesOnly = choice
                plan = nil
            }
        )
    }

    @ViewBuilder
    private var identitiesOnlyControl: some View {
        Picker("IdentitiesOnly", selection: identitiesOnlySelection) {
            Text("未设置").tag(IdentitiesOnlyChoice.unset)
            Text("yes").tag(IdentitiesOnlyChoice.yes)
            Text("no").tag(IdentitiesOnlyChoice.no)
        }
        .pickerStyle(.segmented)
        .onChange(of: input.identityFile) { _, _ in
            if hasIdentityFile { identitiesOnlyNeedsKey = false }
        }
        if identitiesOnlyNeedsKey {
            Label("请先填写或选择上面的 IdentityFile 密钥文件，再开启 IdentitiesOnly。",
                  systemImage: "key.slash")
                .foregroundStyle(.orange)
        } else if input.identitiesOnly == .yes && !hasIdentityFile && !inheritsKeyForIdentitiesOnly {
            Label("IdentitiesOnly 已开启，但 IdentityFile 为空，保存时会被拒绝。请填写密钥，或改为“未设置”/“no”。",
                  systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        } else if input.identitiesOnly == .yes && inheritsKeyForIdentitiesOnly {
            Text("此主机的密钥来自其他规则（例如 Host *）；保持开启不会修改原配置。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        Text("开启后，SSH 只尝试 IdentityFile 指定的密钥，不再逐个尝试 ssh-agent 中的其他密钥，可避免 “Too many authentication failures”。")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var reuseEnabled: Binding<Bool> {
        Binding(
            get: { if case .minutes = input.connectionReuse { return true } else { return false } },
            set: { enabled in
                input.connectionReuse = enabled ? .minutes(reuseMinutes) : .off
                plan = nil
            }
        )
    }

    private var reuseMinutesSelection: Binding<Int> {
        Binding(
            get: { reuseMinutes },
            set: { minutes in
                let clamped = min(max(minutes, ConnectionReuse.allowedMinutes.lowerBound),
                                  ConnectionReuse.allowedMinutes.upperBound)
                reuseMinutes = clamped
                if case .minutes = input.connectionReuse { input.connectionReuse = .minutes(clamped) }
                plan = nil
            }
        )
    }

    @ViewBuilder
    private var connectionReuseControl: some View {
        if case .custom(let summary) = input.connectionReuse {
            LabeledContent("当前设置") {
                Text(summary)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.trailing)
            }
            Label("此主机已有自定义的连接复用设置（超出 1–60 分钟或使用了其他 ControlPath）。为避免改写你的配置，请在源文件中修改。",
                  systemImage: "lock")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Toggle("复用已建立的连接", isOn: reuseEnabled)
            if case .minutes = input.connectionReuse {
                Picker("保留时间", selection: reuseMinutesSelection) {
                    ForEach(reuseMenuMinutes, id: \.self) { minutes in
                        Text(minutes == 60 ? "1 小时" : "\(minutes) 分钟").tag(minutes)
                    }
                }
                Stepper(value: reuseMinutesSelection, in: ConnectionReuse.allowedMinutes) {
                    Text("自定义：\(reuseMinutes) 分钟（1–60）")
                }
                Text("所有窗口关闭后，后台连接仍保留所选时间。期间本机打开新会话不再验证身份；端口转发与代理转发沿用第一个连接的设置。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(verbatim: "写入 ControlMaster auto、ControlPath ~/.ssh/cm/%C 与 ControlPersist；~/.ssh/cm 会以仅本人可访问（700）创建。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("开启后，同一台主机只需验证一次；在保留时间内打开新会话会复用已有连接。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var reuseMenuMinutes: [Int] {
        Array(Set(ConnectionReuse.presetMinutes + [reuseMinutes])).sorted()
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
