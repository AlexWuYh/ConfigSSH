import ConfigSSHCore
import SwiftUI

/// The backup page in 设置: what is protected and when it last happened, the one passphrase that
/// encrypts every backup, and a single automatic-backup switch that covers local snapshots and
/// iCloud together.
struct BackupSettingsView: View {
    let writer: ConfigWriter

    @AppStorage(BackupSettings.enabledKey) private var autoEnabled = false
    @AppStorage(BackupSettings.frequencyKey) private var frequency = SnapshotFrequency.daily.rawValue
    @AppStorage(BackupSettings.iCloudKey) private var syncICloud = false
    @AppStorage(BackupSettings.keepKey) private var keepAutomatic = AutoSnapshotService.defaultKeep
    @AppStorage(BackupSettings.acceptIncompleteKey) private var acceptsIncomplete = false
    @AppStorage("backupLimit") private var changeRecordLimit = 50
    @AppStorage(ICloudLocation.folderKey) private var iCloudFolderPath = ""

    @State private var scheduler = BackupScheduler.shared
    @State private var showsBrowser = false
    @State private var showsCloudSync = false
    @State private var isEditingPassphrase = false
    @State private var newPassphrase = ""
    @State private var confirmPassphrase = ""
    @State private var confirmsRemove = false
    @State private var message: String?
    @State private var messageIsError = false
    @State private var iCloudAvailable = ICloudLocation.isAvailable

    private var hasPassphrase: Bool { scheduler.hasPassphrase }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                statusCard
                passphraseCard
                automationCard
                moreCard
            }
            .padding(24)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $showsBrowser) {
            BackupBrowserView(writer: writer, folder: ConfigSSHPaths.localSnapshotFolder, cloudFolder: iCloudAvailable ? ICloudLocation.backupFolder : nil)
        }
        .sheet(isPresented: $showsCloudSync) {
            CloudSyncView(writer: writer, folder: ICloudLocation.backupFolder, cloudRoot: ICloudLocation.driveRoot)
        }
        .confirmationDialog("移除备份口令？", isPresented: $confirmsRemove) {
            Button("移除并暂停自动备份", role: .destructive) { removePassphrase() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("移除后，已有的加密快照和 iCloud 文件仍需要这个口令才能打开，请确认你记得它。自动备份会暂停，直到重新设置口令。")
        }
        .onChange(of: autoEnabled) { _, _ in changed() }
        .onChange(of: frequency) { _, _ in changed() }
        .onChange(of: syncICloud) { _, _ in changed() }
        .onChange(of: keepAutomatic) { _, _ in changed() }
        .onChange(of: acceptsIncomplete) { _, _ in changed() }
        .task { iCloudAvailable = await Task.detached { ICloudLocation.isAvailable }.value }
        #if DEBUG
        .task {
            guard ConfigSSHPaths.isPreviewMode else { return }
            let environment = ProcessInfo.processInfo.environment
            try? await Task.sleep(for: .seconds(1))
            if environment["CONFIGSSH_PREVIEW_SNAPSHOT_BROWSER"] == "1" { showsBrowser = true }
            if environment["CONFIGSSH_PREVIEW_CLOUD_SYNC"] == "1" { showsCloudSync = true }
        }
        #endif
    }

    // MARK: Status

    private var statusCard: some View {
        BackupCard {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: statusSymbol)
                    .font(.system(size: 26))
                    .foregroundStyle(statusColor)
                    .frame(width: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text(statusTitle).font(.title3.weight(.semibold))
                    Text(statusSubtitle).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                statusLine("本机快照", date: scheduler.state.lastSnapshotAt, empty: "还没有备份")
                if syncICloud { statusLine("iCloud 同步", date: scheduler.state.lastCloudAt, empty: "还没有同步") }
            }
            ForEach(scheduler.problems, id: \.self) { problem in
                Label(problem, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                if problem.contains("覆盖") { Button("打开云端设备管理…") { showsCloudSync = true } }
            }
            ForEach(scheduler.notes, id: \.self) { note in
                Label(note, systemImage: "info.circle").font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button { scheduler.backupNow() } label: {
                    if scheduler.isRunning { ProgressView().controlSize(.small) } else { Label("立即备份", systemImage: "arrow.clockwise.icloud") }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!hasPassphrase || scheduler.isRunning)
                .help(hasPassphrase ? "马上创建一份加密快照" + (syncICloud ? "，并同步到 iCloud" : "") : "先设置备份口令")
                Button("浏览与恢复…") { showsBrowser = true }
                Spacer()
            }
        }
    }

    private func statusLine(_ title: String, date: Date?, empty: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            if let date { Text(ChineseDate.short(date)) } else { Text(empty).foregroundStyle(.secondary) }
        }
        .font(.callout)
    }

    private var statusSymbol: String { !hasPassphrase ? "lock.slash" : autoEnabled ? "checkmark.shield.fill" : "shield" }
    private var statusColor: Color { !hasPassphrase ? .orange : autoEnabled ? .green : .secondary }
    private var statusTitle: String { !hasPassphrase ? "还没有设置备份口令" : autoEnabled ? "自动备份已开启" : "自动备份未开启" }
    private var statusSubtitle: String {
        if !hasPassphrase { return "备份都会用口令加密。先在下面设置一个口令，再开启自动备份。" }
        if !autoEnabled { return "现在只会在你点“立即备份”时保存。开启后，配置一有变化就会自动保护。" }
        var parts = ["本机快照\(SnapshotFrequency(rawValue: frequency)?.displayName ?? "每天")最多一次，配置没变化就跳过"]
        if syncICloud { parts.append("有变更会马上同步到 iCloud") }
        return parts.joined(separator: "；") + "。"
    }

    // MARK: Passphrase

    private var passphraseCard: some View {
        BackupCard(title: "备份口令", symbol: "key.fill") {
            if hasPassphrase && !isEditingPassphrase {
                Label("已设置，保存在这台 Mac 的钥匙串里，不会上传。", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Text("本机快照、iCloud 副本和导出的备份文件都用它加密。口令丢失后无法找回这些备份，请自行妥善记录。")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("更改口令…") { isEditingPassphrase = true; message = nil }
                    Button("移除…", role: .destructive) { confirmsRemove = true }
                }
            } else {
                Text(hasPassphrase ? "输入新的口令。" : "设置一个口令来加密所有备份，至少 12 个字符。")
                    .font(.callout).foregroundStyle(.secondary)
                SecureField("新口令", text: $newPassphrase).textContentType(.newPassword)
                SecureField("再输入一次", text: $confirmPassphrase)
                if let problem = passphraseProblem {
                    Label(problem, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.red)
                }
                if hasPassphrase {
                    Label("更改后，用旧口令加密的快照需要输入旧口令才能打开；iCloud 里这台 Mac 的旧文件需要你确认后才会被新口令覆盖。",
                          systemImage: "info.circle").font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    Button("保存口令") { savePassphrase() }
                        .buttonStyle(.borderedProminent)
                        .disabled(newPassphrase.isEmpty || passphraseProblem != nil)
                    if hasPassphrase { Button("取消") { isEditingPassphrase = false; newPassphrase = ""; confirmPassphrase = "" } }
                }
            }
            if let message {
                Label(message, systemImage: messageIsError ? "xmark.octagon" : "checkmark.circle").font(.callout).foregroundStyle(messageIsError ? .red : .green)
            }
        }
    }

    private var passphraseProblem: String? {
        if newPassphrase.isEmpty && confirmPassphrase.isEmpty { return nil }
        if let problem = BackupCrypto.passphraseProblem(newPassphrase) { return problem }
        if !confirmPassphrase.isEmpty && confirmPassphrase != newPassphrase { return "两次输入不一致" }
        if confirmPassphrase.isEmpty { return "请再输入一次确认" }
        return nil
    }

    // MARK: Automation

    private var automationCard: some View {
        BackupCard(title: "自动备份", symbol: "clock.arrow.circlepath") {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("自动备份").font(.body.weight(.medium))
                    Text("一个总开关，管理下面所有备份方式。").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("自动备份", isOn: $autoEnabled).labelsHidden().toggleStyle(.switch)
                    .disabled(!hasPassphrase)
                    .accessibilityIdentifier("backupAutoToggle")
            }
            if !hasPassphrase { Text("先设置备份口令才能开启。").font(.caption).foregroundStyle(.orange) }

            Group {
                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("本机快照").font(.body.weight(.medium))
                        Text("加密保存在这台 Mac，配置有变化时最多按这个频率创建。").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("频率", selection: $frequency) {
                        ForEach(SnapshotFrequency.allCases) { Text($0.displayName).tag($0.rawValue) }
                    }
                    .labelsHidden().frame(width: 96)
                }
                if frequency != SnapshotFrequency.off.rawValue {
                    Stepper("保留最近 \(keepAutomatic) 份自动快照（手动快照不受影响）", value: $keepAutomatic, in: AutoSnapshotService.keepRange)
                        .font(.callout)
                }
                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("同步到 iCloud").font(.body.weight(.medium))
                        Text("每次配置有变更，几秒内就把加密副本上传。只覆盖这台 Mac 自己的文件。").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("同步到 iCloud", isOn: $syncICloud).labelsHidden().toggleStyle(.switch)
                        .disabled(!iCloudAvailable)
                }
                if !iCloudAvailable {
                    Label("未检测到 iCloud Drive，请先在系统设置中登录并开启。", systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                }
                if syncICloud || iCloudAvailable {
                    LabeledContent("位置") {
                        Text(ICloudLocation.backupFolder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .font(.caption.monospaced()).textSelection(.enabled).lineLimit(2).multilineTextAlignment(.trailing)
                    }
                    .font(.callout)
                    HStack {
                        Button("更改位置…") { chooseICloudFolder() }
                        Button("管理云端设备 / 从其他 Mac 拉取…") { showsCloudSync = true }
                    }
                    Toggle("云端副本可以不包含 ~/.ssh 之外的 Include 文件", isOn: $acceptsIncomplete)
                        .font(.callout)
                    Text("如果配置里 Include 了 ~/.ssh 之外的文件，它们不会上传。不勾选时，遇到这种情况会暂停自动同步并提示你。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .opacity(hasPassphrase ? 1 : 0.55)
            .disabled(!hasPassphrase)
        }
    }

    // MARK: More

    private var moreCard: some View {
        BackupCard(title: "更多", symbol: "ellipsis.circle") {
            Stepper("变更记录最多保留 \(changeRecordLimit == 0 ? "不限" : String(changeRecordLimit)) 条", value: $changeRecordLimit, in: 0...200)
                .font(.callout)
            Text("每次在 ConfigSSH 里修改配置前，都会自动备份被改的文件（侧栏“变更记录”）。设为 0 表示不自动清理。")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            HStack {
                Button("在访达中打开快照文件夹") {
                    try? FileManager.default.createDirectory(at: ConfigSSHPaths.localSnapshotFolder, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(ConfigSSHPaths.localSnapshotFolder)
                }
                Spacer()
            }
            LabeledContent("主配置") { Text(writer.rootURL.path).font(.caption.monospaced()).textSelection(.enabled) }.font(.callout)
            LabeledContent("新增主机目录") { Text(writer.managedDirectoryURL.path).font(.caption.monospaced()).textSelection(.enabled) }.font(.callout)
            Text("快照只含配置文件，永远不含私钥；私钥请用你自己的方式备份。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Actions

    private func changed() {
        NotificationCenter.default.post(name: .backupSettingsChanged, object: nil)
    }

    private func savePassphrase() {
        do {
            try BackupPassphraseStore.save(newPassphrase)
            newPassphrase = ""; confirmPassphrase = ""
            isEditingPassphrase = false
            messageIsError = false
            message = "口令已保存到这台 Mac 的钥匙串。"
        } catch {
            messageIsError = true
            message = error.localizedDescription
        }
    }

    private func removePassphrase() {
        do {
            try BackupPassphraseStore.remove()
            autoEnabled = false
            messageIsError = false
            message = "口令已移除，自动备份已暂停。"
        } catch {
            messageIsError = true
            message = error.localizedDescription
        }
    }

    private func chooseICloudFolder() {
        switch ICloudLocation.choose() {
        case .chosen(let path): iCloudFolderPath = path; message = nil; changed()
        case .rejected(let reason): messageIsError = true; message = reason
        case nil: break
        }
    }
}

/// A rounded section with an optional title row.
private struct BackupCard<Content: View>: View {
    var title: String?
    var symbol: String?
    @ViewBuilder var content: Content

    init(title: String? = nil, symbol: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                HStack(spacing: 8) {
                    if let symbol { Image(systemName: symbol).foregroundStyle(BrandPalette.accent) }
                    Text(title).font(.headline)
                }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
