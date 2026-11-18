import ConfigSSHCore
import SwiftUI

/// "部署公钥" wizard: choose a key → confirm → deploy with ssh-copy-id → key-only check →
/// preview and write IdentityFile / IdentitiesOnly. ConfigSSH never sees the password: OpenSSH
/// asks for it through `configssh-askpass`.
struct KeyDeploymentWizard: View {
    enum Step: Int, CaseIterable {
        case chooseKey, confirm, deploy, verify, writeConfig

        var title: String {
            switch self {
            case .chooseKey: "选择密钥"
            case .confirm: "确认目标"
            case .deploy: "部署"
            case .verify: "验证"
            case .writeConfig: "更新配置"
            }
        }
    }

    let initialHost: HostRecord?
    let hosts: [HostRecord]
    let keys: [PublicKeyRecord]
    let writer: ConfigWriter
    let scan: ConfigScan
    let onGenerateKey: () -> Void
    let onFinished: (String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var step: Step
    @State private var hostID: String?
    @State private var keyID: String?
    @State private var updateMode: IdentityFileUpdateMode = .replace
    @State private var isRunning = false
    @State private var process = GroupProcess()
    @State private var deployOutcome: KeyDeploymentOutcome?
    @State private var loginOutcome: KeyLoginOutcome?
    @State private var proof: VerifiedKeyLogin?
    @State private var plan: ConfigChangePlan?
    @State private var planError: String?
    @State private var committed = false
    @State private var copiedSnippet = false

    init(initialHost: HostRecord?, initialKeyID: String? = nil, initialStep: Step = .chooseKey,
         hosts: [HostRecord], keys: [PublicKeyRecord], writer: ConfigWriter, scan: ConfigScan,
         onGenerateKey: @escaping () -> Void, onFinished: @escaping (String?) -> Void) {
        self.initialHost = initialHost
        self.hosts = hosts.filter { TerminalLaunchPlanner.isSafeAlias($0.alias) }
        self.keys = keys
        self.writer = writer
        self.scan = scan
        self.onGenerateKey = onGenerateKey
        self.onFinished = onFinished
        _hostID = State(initialValue: initialHost?.id)
        _keyID = State(initialValue: initialKeyID ?? keys.first(where: \.isDeployable)?.id)
        _step = State(initialValue: initialStep)
    }

    private var host: HostRecord? { hosts.first { $0.id == hostID } }
    private var key: PublicKeyRecord? { keys.first { $0.id == keyID } }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                stepIndicator
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        switch step {
                        case .chooseKey: chooseKeyStep
                        case .confirm: confirmStep
                        case .deploy: deployStep
                        case .verify: verifyStep
                        case .writeConfig: writeStep
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                footer.padding(16)
            }
            .navigationTitle(host.map { "部署公钥 · \($0.alias)" } ?? "部署公钥")
            .frame(minWidth: 640, minHeight: 520, idealHeight: 600)
        }
        .interactiveDismissDisabled(isRunning)
        #if DEBUG
        .task {
            if ConfigSSHPaths.isPreviewMode,
               ProcessInfo.processInfo.environment["CONFIGSSH_PREVIEW_DEPLOY_STEP"] == "deploy" {
                startDeploy()
            }
        }
        #endif
        .onDisappear { process.cancel() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            GroupProcess.terminateAll()
        }
    }

    // MARK: Steps

    private var stepIndicator: some View {
        HStack(spacing: 6) {
            ForEach(Step.allCases, id: \.self) { item in
                HStack(spacing: 6) {
                    Image(systemName: item.rawValue < step.rawValue ? "checkmark.circle.fill"
                          : item == step ? "\(item.rawValue + 1).circle.fill" : "\(item.rawValue + 1).circle")
                        .foregroundStyle(item.rawValue <= step.rawValue ? BrandPalette.accent : Color.secondary)
                    Text(item.title)
                        .font(.callout)
                        .foregroundStyle(item == step ? .primary : .secondary)
                }
                if item != Step.allCases.last {
                    Rectangle().fill(.quaternary).frame(height: 1).frame(maxWidth: 28)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var chooseKeyStep: some View {
        if initialHost == nil {
            Text("选择目标主机和密钥").font(.title3.bold())
            TargetHostPicker(hosts: hosts, selection: $hostID)
            Text("密钥").font(.headline)
        } else {
            Text("选择要安装到服务器的密钥").font(.title3.bold())
        }
        if keys.isEmpty {
            ContentUnavailableView("还没有可用的密钥", systemImage: "key",
                                   description: Text("先生成一把新密钥，再回到这里部署。"))
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(keys) { record in
                    KeyChoiceRow(record: record, isSelected: record.id == keyID)
                        .contentShape(Rectangle())
                        .onTapGesture { if record.isDeployable { keyID = record.id } }
                }
            }
        }
        Button("生成新密钥…") {
            onGenerateKey()
            dismiss()
        }
        Text("只读取 .pub 公钥文件；私钥只检查是否存在，由 ssh 自己加载。")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var confirmStep: some View {
        if let host, let key {
            Text("确认部署目标").font(.title3.bold())
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("主机", value: host.alias)
                    LabeledContent("HostName", value: host.hostName ?? "未显式设置")
                    LabeledContent("User", value: host.user ?? "未显式设置")
                    LabeledContent("Port", value: host.port ?? "未显式设置")
                    LabeledContent("密钥", value: "\(key.name) · \(key.type)")
                    LabeledContent("远端写入位置", value: "~/.ssh/authorized_keys")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }
            if !scan.rules.isEmpty || host.option("ProxyJump") != nil {
                Label("此主机可能受到 Host *、Match、ProxyJump 或 Include 中规则的影响，实际连接参数由 OpenSSH 按你的配置解析，可能与上面显示的不同。",
                      systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    Label("接下来系统会弹出对话框，请输入一次服务器密码。ConfigSSH 不会读取或保存这个密码。",
                          systemImage: "lock")
                    Label("如果是第一次连接这台服务器，还会请你核对服务器指纹；不确定时请选择“拒绝”。",
                          systemImage: "checkmark.shield")
                    Label("部署与验证都会强制不使用连接复用，确保结果是真实登录得到的。",
                          systemImage: "arrow.triangle.branch")
                }
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }
            Text("只支持能执行远程命令的服务器；只允许 SFTP 的服务器暂不支持。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var deployStep: some View {
        Text("部署公钥").font(.title3.bold())
        if isRunning {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("正在连接服务器并安装公钥。请在弹出的对话框中完成输入。")
            }
        } else if let deployOutcome {
            Label(deployOutcome.explanation,
                  systemImage: deployOutcome.canVerify ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(deployOutcome.canVerify ? Color.primary : Color.orange)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private var verifyStep: some View {
        Text("验证密钥登录").font(.title3.bold())
        Text("只用这把密钥登录一次（不允许密码、不复用已有连接），在服务器上执行 true 后立即退出。")
            .foregroundStyle(.secondary)
        if isRunning {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("正在验证…如果私钥设置了口令，会弹出对话框请你输入。")
            }
        } else if let loginOutcome {
            Label(loginOutcome.explanation,
                  systemImage: loginOutcome.isSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(loginOutcome.isSuccess ? Color.primary : Color.orange)
                .textSelection(.enabled)
            if !loginOutcome.isSuccess {
                Text("本机配置不会被修改。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var writeStep: some View {
        if committed {
            Label("完成：\(host?.alias ?? "") 已配置为使用这把密钥登录。", systemImage: "checkmark.circle.fill")
                .font(.title3.bold())
            Text("如需关闭服务器的密码登录，请在服务器上自行修改 sshd 配置。ConfigSSH 不修改服务器设置。")
                .foregroundStyle(.secondary)
        } else if let host, let proof {
            Text("更新本机配置").font(.title3.bold())
            let identityFiles = host.explicitOptions.filter { $0.keyword.caseInsensitiveCompare("IdentityFile") == .orderedSame }
            if !identityFiles.isEmpty && host.isSimple {
                Picker("已有 IdentityFile", selection: $updateMode) {
                    Text("替换").tag(IdentityFileUpdateMode.replace)
                    Text("追加").tag(IdentityFileUpdateMode.append)
                }
                .pickerStyle(.segmented)
                .onChange(of: updateMode) { _, _ in preparePlan(proof: proof) }
            }
            if let plan {
                ForEach(Array(plan.changes.enumerated()), id: \.offset) { _, change in
                    GroupBox(change.url.path) {
                        Text(change.diff)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                }
                ForEach(plan.warnings, id: \.self) { warning in
                    Text(warning).font(.caption).foregroundStyle(.secondary)
                }
            } else if let planError {
                Label(planError, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                if !host.isSimple {
                    let snippet = KeyDeployment.configSnippet(alias: host.alias, identityFile: proof.privateKeyURL.path)
                    Text("此主机无法安全地自动修改。请把以下内容合并到源文件 \(host.sourceURL.path)：")
                        .foregroundStyle(.secondary)
                    Text(snippet)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                    Button(copiedSnippet ? "已复制" : "复制配置片段") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(snippet, forType: .string)
                        copiedSnippet = true
                    }
                }
            }
        }
    }

    // MARK: Footer and actions

    private var footer: some View {
        HStack {
            if isRunning {
                Button("取消", role: .cancel) { process.cancel() }
                    .keyboardShortcut(.cancelAction)
            } else {
                Button(committed ? "关闭" : "取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            Spacer()
            if !isRunning && !committed && (step == .confirm || (step == .deploy && deployOutcome?.canVerify != true)) {
                Button("返回") { step = step == .deploy ? .confirm : .chooseKey }
            }
            primaryButton
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch step {
        case .chooseKey:
            Button("下一步") { step = .confirm }
                .disabled(host == nil || key?.isDeployable != true)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        case .confirm:
            Button("开始部署") { startDeploy() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        case .deploy:
            if deployOutcome?.canVerify == true {
                Button("验证登录") { startVerify() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            } else if !isRunning && deployOutcome != nil {
                Button("重试") { startDeploy() }
            }
        case .verify:
            if let proof {
                Button("下一步") {
                    step = .writeConfig
                    preparePlan(proof: proof)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            } else if !isRunning && loginOutcome != nil {
                Button("重新验证") { startVerify() }
            }
        case .writeConfig:
            if committed {
                EmptyView()
            } else if let plan {
                Button("确认写入") { commit(plan) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func deploymentInputs() -> (String, DeployableKey, KeyDeploymentOptions)? {
        guard let host, let key else { return nil }
        guard let askpass = AskpassHelperLocator.helperURL() else {
            deployOutcome = .failed("找不到内置的 configssh-askpass 辅助程序，请重新安装 ConfigSSH。")
            return nil
        }
        do {
            let deployable = try DeployableKey(publicKeyURL: key.publicKeyURL, privateKeyURL: key.privateKeyURL)
            var options = KeyDeploymentOptions(askpassURL: askpass)
            #if DEBUG
            // Debug preview reads a /tmp fixture; ssh must resolve the alias from that same file.
            // ssh resolves a relative Include in an -F file against the real ~/.ssh, so refuse it.
            if ConfigSSHPaths.isPreviewMode {
                guard !scan.sources.contains(where: { $0.url != ConfigSSHPaths.rootURL }),
                      !((try? String(contentsOf: ConfigSSHPaths.rootURL, encoding: .utf8)) ?? "").lowercased().contains("include") else {
                    deployOutcome = .failed("预览模式下的部署夹具不能使用 Include")
                    return nil
                }
                options.configURL = ConfigSSHPaths.rootURL
            }
            #endif
            return (host.alias, deployable, options)
        } catch {
            deployOutcome = .failed(error.localizedDescription)
            return nil
        }
    }

    private func startDeploy() {
        step = .deploy
        deployOutcome = nil
        guard let (alias, key, options) = deploymentInputs() else { return }
        let runner = GroupProcess()
        process = runner
        isRunning = true
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                KeyDeployment.deploy(alias: alias, key: key, options: options, process: runner)
            }.value
            deployOutcome = outcome
            isRunning = false
        }
    }

    private func startVerify() {
        step = .verify
        loginOutcome = nil
        proof = nil
        guard let (alias, key, options) = deploymentInputs() else { return }
        let runner = GroupProcess()
        process = runner
        isRunning = true
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                KeyDeployment.verify(alias: alias, key: key, options: options, process: runner)
            }.value
            loginOutcome = result.outcome
            proof = result.proof
            isRunning = false
        }
    }

    private func preparePlan(proof: VerifiedKeyLogin) {
        plan = nil
        planError = nil
        guard let host else { return }
        do {
            plan = try writer.planKeyLogin(proof, hostID: host.id, mode: updateMode, from: scan)
        } catch {
            planError = error.localizedDescription
        }
    }

    private func commit(_ plan: ConfigChangePlan) {
        do {
            _ = try writer.commit(plan)
            committed = true
            onFinished(plan.targetAlias)
        } catch {
            self.plan = nil
            planError = error.localizedDescription
        }
    }
}

/// Searchable list for choosing the target host; matches alias, HostName, User and group.
private struct TargetHostPicker: View {
    let hosts: [HostRecord]
    @Binding var selection: String?
    @State private var query = ""

    private var filtered: [HostRecord] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? hosts : hosts.filter { $0.matches(trimmed) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("目标主机").font(.headline)
                Spacer()
                if let selected = hosts.first(where: { $0.id == selection }) {
                    Label(selected.alias, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(BrandPalette.accent)
                        .font(.callout)
                }
            }
            TextField("搜索别名、地址、用户或分组", text: $query)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("deployHostSearch")
            Text(query.isEmpty ? "共 \(hosts.count) 台主机" : "匹配 \(filtered.count) / \(hosts.count) 台")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(filtered) { host in
                        HStack(spacing: 10) {
                            Image(systemName: host.id == selection ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(BrandPalette.accent)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(host.alias).font(.body.weight(.medium))
                                Text([host.user.map { "\($0)@" }, host.hostName].compactMap { $0 }.joined())
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let group = host.configGroup {
                                Text(group)
                                    .font(.caption)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.quaternary, in: Capsule())
                            }
                            if host.option("IdentityFile") != nil {
                                Image(systemName: "key.horizontal")
                                    .foregroundStyle(.secondary)
                                    .help("已设置 IdentityFile")
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(host.id == selection ? BrandPalette.accent.opacity(0.12) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                        .onTapGesture { selection = host.id }
                    }
                    if filtered.isEmpty {
                        Text("没有匹配的主机").foregroundStyle(.secondary).padding(10)
                    }
                }
            }
            .frame(height: 190)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
        }
        Divider()
    }
}

private struct KeyChoiceRow: View {
    let record: PublicKeyRecord
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(record.isDeployable ? BrandPalette.accent : Color.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(record.name).font(.body.weight(.medium))
                Text("\(record.type) · \(record.fingerprint ?? "无指纹")")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                if let reason = record.notDeployableReason {
                    Text(reason).font(.caption).foregroundStyle(.orange)
                } else if !record.associatedHosts.isEmpty {
                    Text("已用于：\(record.associatedHosts.joined(separator: "、"))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(10)
        .background(isSelected ? BrandPalette.accent.opacity(0.12) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8))
        .opacity(record.isDeployable ? 1 : 0.55)
    }
}

extension PublicKeyRecord {
    var isDeployable: Bool { notDeployableReason == nil }

    var notDeployableReason: String? {
        if !publicKeyExists || fingerprint == nil { return "缺少可读取的 .pub 公钥文件" }
        if !privateKeyExists { return "找不到对应的私钥文件" }
        return nil
    }
}
