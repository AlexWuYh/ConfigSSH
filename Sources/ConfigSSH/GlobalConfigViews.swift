import ConfigSSHCore
import SwiftUI

enum GlobalConfigPage: String, CaseIterable, Identifiable {
    case overview = "主配置原文"
    case files = "已读取文件"
    case rules = "规则与引用"
    case help = "参数说明"

    var id: Self { self }

    var symbol: String {
        switch self {
        case .overview: "doc.text"
        case .files: "doc.on.doc"
        case .rules: "list.bullet.rectangle"
        case .help: "questionmark.circle"
        }
    }
}

struct GlobalConfigOverviewView: View {
    let scan: ConfigScan
    let rootURL: URL
    let onEdit: () -> Void

    private var rootData: Data? {
        scan.sources.first { $0.url.standardizedFileURL == rootURL.standardizedFileURL }?.data
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("主配置原文").font(.largeTitle.bold())
                        Text(rootURL.path)
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: 16)
                    Button("编辑文件", action: onEdit)
                        .disabled(rootData == nil && scan.availability != .missing)
                }
                HStack(spacing: 14) {
                    Label("\(scan.hosts.count) 台主机", systemImage: "server.rack")
                    Label("\(scan.rules.count) 条规则", systemImage: "list.bullet.rectangle")
                    Label("\(scan.sources.count) 个已读取文件", systemImage: "doc.on.doc")
                }
                .font(.callout)
                .foregroundStyle(.secondary)

                GroupBox("~/.ssh/config · 完整原文") {
                    Group {
                        if let rootData {
                            if rootData.isEmpty {
                                Text("文件为空。").foregroundStyle(.secondary)
                            } else {
                                ScrollView(.horizontal) {
                                    VStack(alignment: .leading, spacing: 8) {
                                        if rootData.count > 1_000_000 {
                                            Label("文件较大，此处只预览前 1 MB；编辑前请用外部编辑器确认全文。", systemImage: "info.circle")
                                                .foregroundStyle(.secondary)
                                        }
                                        Text(String(decoding: rootData.prefix(1_000_000), as: UTF8.self))
                                            .font(.system(.body, design: .monospaced))
                                            .textSelection(.enabled)
                                            .fixedSize(horizontal: true, vertical: false)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                            }
                        } else if scan.availability == .missing {
                            ContentUnavailableView("尚无 config 文件", systemImage: "doc.badge.plus")
                        } else {
                            ContentUnavailableView("无法预览 config 文件", systemImage: "exclamationmark.triangle")
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
                    .padding(8)
                }
                Text("此处展示主配置文件的完整原文；Include 引入的文件不会拼接进来。编辑前可查看规则与引用。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("全局配置")
    }
}

struct GlobalConfigFilesView: View {
    let scan: ConfigScan
    let rootURL: URL

    @State private var selectedPath: String?

    private var selectedSource: SourceFileSnapshot? {
        scan.sources.first { $0.url.path == (selectedPath ?? rootURL.path) } ?? scan.sources.first
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("已读取文件")
                    .font(.largeTitle.bold())
                Text("这里逐个展示本次扫描读取的原始文件；不合并 Host 规则，也不运行 ssh -G。")
                    .foregroundStyle(.secondary)
                if scan.sources.isEmpty {
                    ContentUnavailableView("尚无已读取文件", systemImage: "doc")
                } else {
                    Picker("查看文件", selection: Binding(
                        get: { selectedSource?.url.path ?? "" },
                        set: { selectedPath = $0 }
                    )) {
                        ForEach(scan.sources, id: \.url) { source in
                            Text(source.url.path == rootURL.path ? "主配置 · config" :
                                 source.url.path.hasPrefix(rootURL.deletingLastPathComponent().path + "/")
                                 ? String(source.url.path.dropFirst(rootURL.deletingLastPathComponent().path.count + 1))
                                 : source.url.path)
                                .tag(source.url.path)
                        }
                    }
                    .pickerStyle(.menu)
                    if let source = selectedSource {
                        Text(source.url.path)
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        GroupBox("原始内容 · \(source.data.count) 字节") {
                            ScrollView(.horizontal) {
                                VStack(alignment: .leading, spacing: 8) {
                                    if source.data.count > 1_000_000 {
                                        Label("文件较大，仅预览前 1 MB。", systemImage: "info.circle")
                                            .foregroundStyle(.secondary)
                                    }
                                    Text(String(decoding: source.data.prefix(1_000_000), as: UTF8.self))
                                        .font(.system(.body, design: .monospaced))
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: true, vertical: false)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .frame(maxWidth: .infinity, minHeight: 180, alignment: .topLeading)
                            .padding(8)
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("已读取文件")
    }
}

struct GlobalConfigRulesView: View {
    let scan: ConfigScan

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("规则与引用").font(.largeTitle.bold())
                Text("Host 模式与 Match 规则可能影响最终连接参数；这里只做静态展示，不执行配置中的命令。")
                    .foregroundStyle(.secondary)
                GroupBox("配置规则 · \(scan.rules.count)") {
                    if scan.rules.isEmpty {
                        Text("没有 Host 模式或 Match 规则。")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(scan.rules) { rule in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("\(rule.kind == .match ? "Match" : "Host") \(rule.expression)")
                                        .font(.body.monospaced())
                                        .textSelection(.enabled)
                                    Text("\(rule.sourceURL.path):\(rule.line)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                                if rule.id != scan.rules.last?.id { Divider() }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    }
                }
                GroupBox("已读取文件 · \(scan.sources.count)") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(scan.sources, id: \.url) { source in
                            Text(source.url.path)
                                .font(.callout.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("规则与引用")
    }
}

struct GlobalConfigHelpView: View {
    private let examples: [(String, String)] = [
        ("全局默认值", "ServerAliveInterval 60\nServerAliveCountMax 3\nAddKeysToAgent yes"),
        ("引入按分组保存的主机", "Include config.d/*.conf\nInclude config.d/*/*.conf"),
        ("通配主机规则", "Host *.example.com\n  User deploy\n  Port 22"),
        ("单个主机", "Host production\n  HostName 192.0.2.10\n  User deploy\n  IdentityFile ~/.ssh/id_ed25519")
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("参数说明").font(.largeTitle.bold())
                Text("常见 OpenSSH 客户端配置示例。Host、Match 与 Include 的位置会影响作用范围；多个匹配项通常采用先取得的参数值，IdentityFile 等参数可重复添加。")
                    .foregroundStyle(.secondary)
                ForEach(examples.indices, id: \.self) { index in
                    GroupBox(examples[index].0) {
                        Text(examples[index].1)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                }
                Text("常见参数").font(.title2.bold())
                ForEach(GlobalConfigCatalog.options) { parameter in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(parameter.keyword).font(.headline.monospaced())
                        Text(parameter.description)
                        Text("示例：\(parameter.keyword) \(parameter.example)")
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 3)
                    Divider()
                }
                Text("这里只提供常见参数解释，不代替系统 ssh_config 手册；直接编辑前请确认语法和规则顺序。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("参数说明")
    }
}

struct RootConfigEditorView: View {
    let writer: ConfigWriter
    let scan: ConfigScan
    let onCommit: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var plan: ConfigChangePlan?
    @State private var errorMessage: String?

    init(writer: ConfigWriter, scan: ConfigScan, onCommit: @escaping () -> Void) {
        self.writer = writer
        self.scan = scan
        self.onCommit = onCommit
        let data = scan.sources.first { $0.url.standardizedFileURL == writer.rootURL }?.data
        _text = State(initialValue: data.flatMap { String(data: $0, encoding: .utf8) } ?? "")
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let plan {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("确认主配置变更").font(.title3.bold())
                            ForEach(Array(plan.changes.enumerated()), id: \.offset) { _, change in
                                GroupBox(change.url.path) {
                                    Text(change.diff)
                                        .font(.system(.body, design: .monospaced))
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(8)
                                }
                            }
                            if !plan.warnings.isEmpty {
                                GroupBox("静态检查提醒") {
                                    VStack(alignment: .leading, spacing: 8) {
                                        ForEach(plan.warnings, id: \.self) { warning in
                                            Label(warning, systemImage: "exclamationmark.triangle")
                                                .foregroundStyle(.orange)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(8)
                                }
                            }
                            Text("保存前会再次检查文件版本；保存时建立备份。请确认 Include、Host 和 Match 的顺序。")
                                .foregroundStyle(.secondary)
                        }
                        .padding(20)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(writer.rootURL.path)
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        TextEditor(text: $text)
                            .font(.system(.body, design: .monospaced))
                            .padding(4)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                        Text("编辑完整 config 原文；不会自动执行 ssh -G，也不会自动修改 Include 文件。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .padding(20)
                }
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .padding(12)
                }
                Divider()
                HStack {
                    Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                    Spacer()
                    if plan != nil {
                        Button("返回编辑") { plan = nil; errorMessage = nil }
                    }
                    Button(plan == nil ? "预览变更" : "确认保存") {
                        if let plan { commit(plan) } else { prepare() }
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                }
                .padding(14)
            }
            .navigationTitle("编辑 ~/.ssh/config")
            .frame(minWidth: 690, minHeight: 520)
        }
    }

    private func prepare() {
        do {
            plan = try writer.planRootConfigReplacement(text: text, from: scan)
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    private func commit(_ plan: ConfigChangePlan) {
        do {
            _ = try writer.commit(plan)
            onCommit()
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}
