import ConfigSSHCore
import SwiftUI
import UniformTypeIdentifiers

/// Export the host configuration to a `.zip`, or to an encrypted `.cssh` protected by a passphrase
/// chosen here. The two formats never include keys.
struct HostExportSheet: View {
    let writer: ConfigWriter

    @Environment(\.dismiss) private var dismiss
    @State private var encrypted = false
    @State private var passphrase = ""
    @State private var confirmation = ""
    @State private var isWorking = false
    @State private var result: String?
    @State private var resultIsError = false

    private var problem: String? {
        guard encrypted, !passphrase.isEmpty || !confirmation.isEmpty else { return nil }
        if let problem = BackupCrypto.passphraseProblem(passphrase) { return problem }
        if confirmation != passphrase { return confirmation.isEmpty ? "请再输入一次确认" : "两次输入不一致" }
        return nil
    }

    private var canExport: Bool { !isWorking && (!encrypted || (!passphrase.isEmpty && problem == nil)) }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("导出主机配置").font(.title3.bold())
                Text("导出 `config` 和 `config.d` 里的主机配置文件，可以在另一台 Mac 上导入。不包含私钥。")
                    .foregroundStyle(.secondary)
                Picker("格式", selection: $encrypted) {
                    Text("压缩包 .zip").tag(false)
                    Text("加密文件 .cssh").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if encrypted {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("为这个文件设置加密口令（至少 12 个字符）。导入时需要输入同样的口令，口令丢失后无法恢复内容。")
                            .font(.callout).foregroundStyle(.secondary)
                        SecureField("加密口令", text: $passphrase)
                        SecureField("再输入一次", text: $confirmation)
                        if let problem { Label(problem, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.red) }
                    }
                } else {
                    Label("压缩包没有加密，任何人拿到它都能看到你的主机地址和用户名。需要保密时请选择加密文件。",
                          systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.orange)
                }
                if let result {
                    Label(result, systemImage: resultIsError ? "xmark.octagon" : "checkmark.circle")
                        .foregroundStyle(resultIsError ? .red : .green)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 0)
                Divider()
                HStack {
                    Button("关闭") { dismiss() }
                    Spacer()
                    Button(isWorking ? "正在导出…" : "导出…") { export() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canExport)
                }
            }
            .padding(22)
            .frame(width: 520, height: encrypted ? 470 : 380)
            .navigationTitle("导出")
        }
    }

    private func export() {
        let panel = NSSavePanel()
        let stamp = Self.stamp()
        let ext = encrypted ? "cssh" : "zip"
        panel.nameFieldStringValue = FileNaming.withSingleExtension("ConfigSSH-主机配置-\(stamp)", ext)
        // A custom extension is appended by the panel itself, which doubled it in a suffixed name.
        // Leave the type open and make sure of the extension once, below.
        panel.allowedContentTypes = []
        panel.allowsOtherFileTypes = true
        panel.canCreateDirectories = true
        guard PanelFocus.run({ panel.runModal() }) == .OK, var url = panel.url else { return }
        url = url.deletingLastPathComponent().appendingPathComponent(FileNaming.withSingleExtension(url.lastPathComponent, ext))
        isWorking = true
        result = nil
        let root = writer.rootURL
        let secret = passphrase
        let useEncryption = encrypted
        let version = UpdateChecker.currentVersion ?? ""
        let device = BackupSettings.deviceName
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<HostTransfer.Export, Error> in
                Result {
                    let scan = ConfigReader(rootURL: root).scan()
                    return useEncryption
                        ? try HostTransfer.encryptedExport(scan: scan, passphrase: secret, appVersion: version, deviceName: device)
                        : try HostTransfer.zipExport(scan: scan, appVersion: version, deviceName: device)
                }
            }.value
            isWorking = false
            switch outcome {
            case .success(let export):
                do {
                    try export.data.write(to: url, options: .atomic)
                    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                    var text = "已导出 \(export.fileCount) 个配置文件到 \(url.lastPathComponent)。"
                    if !export.skippedExternal.isEmpty { text += "另有 \(export.skippedExternal.count) 个位于 ~/.ssh 之外的 Include 文件没有导出。" }
                    resultIsError = false
                    result = text
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } catch {
                    resultIsError = true
                    result = "无法写入文件：\(error.localizedDescription)"
                }
            case .failure(let error):
                resultIsError = true
                result = error.localizedDescription
            }
        }
    }

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return formatter.string(from: Date())
    }
}

/// Import a `.zip` or an encrypted `.cssh`: pick the file, enter the passphrase for an encrypted
/// one (nothing is shown until it is verified), choose whether to overwrite the main config, then
/// review the diff before anything is written.
struct HostImportSheet: View {
    let writer: ConfigWriter
    let onFinished: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var fileName: String?
    @State private var fileData: Data?
    @State private var kind: HostTransfer.Kind?
    @State private var passphrase = ""
    @State private var imported: HostTransfer.Imported?
    @State private var includeRoot = false
    @State private var plan: ConfigChangePlan?
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var notice: String?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("导入主机配置").font(.title3.bold())
                if fileData == nil { chooseStep } else if imported == nil { unlockStep } else { reviewStep }
                if let errorMessage { Label(errorMessage, systemImage: "xmark.octagon").foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                if let notice { Label(notice, systemImage: "info.circle").foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                Spacer(minLength: 0)
                Divider()
                HStack {
                    Button("取消") { dismiss() }
                    Spacer()
                    if imported != nil {
                        Button("预览变更…") { preparePlan() }.buttonStyle(.borderedProminent).disabled(isWorking)
                    } else if kind != nil, case .encrypted = kind {
                        Button(isWorking ? "正在验证…" : "验证口令并打开") { unlock() }
                            .buttonStyle(.borderedProminent).disabled(passphrase.isEmpty || isWorking)
                    }
                }
            }
            .padding(22)
            .frame(width: 560, height: 470)
            .navigationTitle("导入")
        }
        .sheet(item: Binding(get: { plan.map { ImportPlanBox(plan: $0) } }, set: { if $0 == nil { plan = nil } })) { box in
            PlanPreviewSheet(title: "预览导入", heading: "导入主机配置", confirmTitle: "确认导入", plan: box.plan, writer: writer) {
                afterImport()
            }
        }
    }

    // MARK: Steps

    private var chooseStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("选择之前导出的 .zip 压缩包或 .cssh 加密文件。加密文件需要输入导出时设置的口令，口令正确才会继续。")
                .foregroundStyle(.secondary)
            Button("选择文件…") { chooseFile() }.buttonStyle(.borderedProminent)
        }
    }

    private var unlockStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(fileName ?? "", systemImage: "lock.doc").font(.callout)
            Text("这是加密文件。输入导出时设置的口令来验证：").foregroundStyle(.secondary)
            SecureField("加密口令", text: $passphrase)
                .onSubmit { unlock() }
            Button("重新选择文件…") { reset() }.buttonStyle(.link)
        }
    }

    @ViewBuilder
    private var reviewStep: some View {
        if let imported {
            let count = imported.archive.entries.count
            VStack(alignment: .leading, spacing: 10) {
                Label("\(fileName ?? "")：包含 \(count) 个配置文件" + (imported.createdAt.map { "，导出于 \(ChineseDate.short($0))" } ?? ""),
                      systemImage: "checkmark.seal").foregroundStyle(.green)
                if !imported.archive.deviceName.isEmpty { Text("来自 \(imported.archive.deviceName)").font(.callout).foregroundStyle(.secondary) }
                if kind == .zip, !imported.hasManifest {
                    Label("这个 zip 不是 ConfigSSH 导出的（没有校验清单），内容未做完整性校验；请在下一步仔细核对差异。",
                          systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                }
                GroupBox {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(imported.archive.entries, id: \.path) { Text($0.path).font(.callout.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                        }
                        .padding(6)
                    }
                    .frame(height: 110)
                }
                Toggle("同时覆盖当前的主配置 config", isOn: $includeRoot)
                Text(includeRoot ? "会用导出文件里的 config 替换当前的主配置（全局设置和 Include）。预览里可以看到差异。"
                                 : "默认只导入主机文件，保留你现在的主配置。如果当前主配置里没有 Include config.d/*.conf 之类的引用，导入的主机暂时不会显示，导入后会提醒你。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("导入只会新增或覆盖同路径的文件，不会删除你现有的其他文件，写入前会备份被覆盖的文件。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Actions

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip, UTType(filenameExtension: "cssh") ?? .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard PanelFocus.run({ panel.runModal() }) == .OK, let url = panel.url else { return }
        errorMessage = nil
        notice = nil
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true, (values.fileSize ?? .max) <= BackupCrypto.maximumFileSize else {
                throw ConfigEditError.invalid("请选择一个小于 96 MB 的普通文件")
            }
            let data = try Data(contentsOf: url)
            let detected = try HostTransfer.inspect(data)
            fileData = data
            fileName = url.lastPathComponent
            kind = detected
            if detected == .zip { open(passphrase: nil) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func unlock() { open(passphrase: passphrase) }

    private func open(passphrase secret: String?) {
        guard let data = fileData else { return }
        isWorking = true
        errorMessage = nil
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<HostTransfer.Imported, Error> in
                Result { try secret.map { try HostTransfer.readEncrypted(data, passphrase: $0) } ?? HostTransfer.readZip(data) }
            }.value
            isWorking = false
            switch outcome {
            case .success(let opened): imported = opened; passphrase = ""
            case .failure(let error):
                errorMessage = error.localizedDescription
                if secret == nil { reset(keepError: true) }
            }
        }
    }

    private func preparePlan() {
        guard let imported else { return }
        isWorking = true
        errorMessage = nil
        let writer = writer
        let includeRoot = includeRoot
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<ConfigChangePlan, Error> in
                Result { try writer.planArchiveRestore(imported.archive, title: "导入主机配置", includeRoot: includeRoot) }
            }.value
            isWorking = false
            switch outcome {
            case .success(let prepared): plan = prepared
            case .failure(let error): errorMessage = error.localizedDescription
            }
        }
    }

    private func afterImport() {
        NotificationCenter.default.post(name: .configSSHConfigChanged, object: nil)
        onFinished()
        guard let imported else { dismiss(); return }
        let root = writer.rootURL
        Task {
            let missing = await Task.detached(priority: .userInitiated) {
                HostTransfer.unreferencedFiles(imported.archive, in: ConfigReader(rootURL: root).scan())
            }.value
            if missing.isEmpty { dismiss() } else {
                notice = "已写入，但有 \(missing.count) 个文件当前的主配置没有 Include 它们，主机暂时不会显示。请在主配置里加上 Include config.d/*.conf（和 Include config.d/*/*.conf），或重新导入并勾选“同时覆盖当前的主配置”。"
            }
        }
    }

    private func reset(keepError: Bool = false) {
        fileData = nil; fileName = nil; kind = nil; imported = nil; passphrase = ""
        if !keepError { errorMessage = nil }
    }
}

private struct ImportPlanBox: Identifiable {
    let id = UUID()
    let plan: ConfigChangePlan
}
