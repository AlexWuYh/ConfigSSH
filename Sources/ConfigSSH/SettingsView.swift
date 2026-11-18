import AppKit
import ConfigSSHCore
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

private struct ProfileSelection: Identifiable {
    let id: String
}

struct SettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedTab = Self.initialTab
    @AppStorage("defaultTerminal") private var defaultTerminalRaw = ""
    @AppStorage("defaultOpenMode") private var defaultOpenModeRaw = TerminalOpenMode.window.rawValue
    @AppStorage("backupLimit") private var backupLimit = 50
    @AppStorage("snapshotICloudFolder") private var snapshotICloudFolder = ""
    @AppStorage(AutoSnapshotScheduler.intervalKey) private var autoSnapshotInterval = AutoSnapshotInterval.daily.rawValue
    @AppStorage(AutoSnapshotScheduler.keepKey) private var autoSnapshotKeep = AutoSnapshotService.defaultKeep
    @AppStorage(AutoSnapshotScheduler.lastResultKey) private var autoSnapshotLastResult = ""
    @State private var snapshotIncludeKeys = false
    @State private var snapshotKeys: [PublicKeyRecord] = []
    @State private var selectedSnapshotKeyIDs: Set<String> = []
    @State private var isIndexingSnapshotKeys = false
    @State private var snapshotKeyIndexTask: Task<Void, Never>?
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage(GlobalShortcutSettings.defaultsKey) private var globalShortcut = GlobalShortcut.default.storageValue
    @State private var shortcutRecorder = ShortcutRecorderModel()
    @State private var iCloudDriveAvailable = true
    @State private var launchService = TerminalLaunchService()
    @State private var profiles: [TerminalProfile] = []
    @State private var terminalCapabilities: [String: TerminalCapability] = [:]
    @State private var terminalProbeTask: Task<Void, Never>?
    @State private var editingProfileID: String?
    @State private var executablePath = ""
    @State private var argumentsText = ""
    @State private var showsAppPicker = false
    @State private var loginItemEnabled = SMAppService.mainApp.status == .enabled
    @State private var settingsError: String?
    @State private var showsKeyBackupRisk = false
    @State private var showsSnapshotKeyConfirmation = false
    @State private var showsSnapshotBrowser = false
    @State private var showsCloudSync = false
    @State private var snapshotResult: SnapshotResult?
    @State private var isCreatingSnapshot = false

    private let writer = ConfigWriter()

    private static var initialTab: Int {
        #if DEBUG
        if ConfigSSHPaths.isPreviewMode &&
            ProcessInfo.processInfo.environment["CONFIGSSH_PREVIEW_SETTINGS_TAB"] == "backup" { return 1 }
        if ConfigSSHPaths.isPreviewMode &&
            ProcessInfo.processInfo.environment["CONFIGSSH_PREVIEW_SETTINGS_TAB"] == "about" { return 3 }
        if ConfigSSHPaths.isPreviewMode &&
            ProcessInfo.processInfo.environment["CONFIGSSH_PREVIEW_SETTINGS_TAB"] == "general" { return 2 }
        #endif
        return 0
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            Form {
                Picker("默认终端", selection: $defaultTerminalRaw) {
                    Text("自动选择已配置终端").tag("")
                    ForEach(profiles) { terminal in
                        Text(terminal.displayName).tag(terminal.id)
                    }
                }
                Picker("默认打开方式", selection: $defaultOpenModeRaw) {
                    ForEach(TerminalOpenMode.allCases) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }
                Section("已安装的终端") {
                    ForEach(profiles) { terminal in
                        let capability = terminalCapabilities[terminal.id]
                        HStack {
                            VStack(alignment: .leading) {
                                Text(terminal.displayName)
                                Text(capability?.explanation ?? "正在检测终端启动方式…")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("配置") {
                                editingProfileID = terminal.id
                                // Only a custom CLI owns these fields; prefilling an automatic
                                // profile's internal path would turn an unchanged save into a
                                // custom CLI without {alias} and break launching.
                                let isCustom = terminal.strategy == .customCLI
                                executablePath = isCustom ? terminal.executablePath : ""
                                argumentsText = isCustom ? terminal.arguments.joined(separator: "\n") : ""
                            }
                        }
                    }
                    Button("重新扫描已安装终端") {
                        TerminalCatalog.shared.refresh()
                        refreshTerminals()
                    }
                    Button("选择其他终端应用…") { showsAppPicker = true }
                }
                Text("支持自动发现常见终端。其他已安装终端可在此配置 CLI 绝对路径与参数，每行一个参数；用 {alias} 或 {ssh} 表示连接目标。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("使用 AppleScript 的终端可能需要在 macOS“隐私与安全性 → 自动化”中授权。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .tabItem { Label("终端", systemImage: "terminal") }
            .tag(0)

            Form {
                Section("自动快照") {
                    Picker("自动创建快照", selection: $autoSnapshotInterval) {
                        ForEach(AutoSnapshotInterval.allCases) { interval in
                            Text(interval.displayName).tag(interval.rawValue)
                        }
                    }
                    .onChange(of: autoSnapshotInterval) { _, _ in AutoSnapshotScheduler.shared.runNow() }
                    if autoSnapshotInterval != AutoSnapshotInterval.off.rawValue {
                        Stepper("保留最近 \(autoSnapshotKeep) 份自动快照", value: $autoSnapshotKeep,
                                in: AutoSnapshotService.keepRange)
                        LabeledContent("上次执行", value: autoSnapshotLastResult.isEmpty ? "尚未执行" : autoSnapshotLastResult)
                    }
                    Text("App 运行时每小时检查一次：到期且配置有变化时，自动保存 config 与 Include 文件的本机快照。自动快照从不包含密钥；清理时只删除较旧的自动快照，手动快照不受影响。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Section("配置快照") {
                    Text("本机快照可包含配置文件，并在逐次确认后选择密钥；不会上传 iCloud。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Toggle("包含密钥文件（含私钥）", isOn: Binding(
                        get: { snapshotIncludeKeys },
                        set: { enabled in
                            if enabled { showsKeyBackupRisk = true }
                            else {
                                snapshotIncludeKeys = false
                                selectedSnapshotKeyIDs.removeAll()
                            }
                        }
                    ))
                    if snapshotIncludeKeys {
                        Label("高风险：私钥会以未额外加密的文件复制到本机快照目录；本次操作后会自动关闭该选项。", systemImage: "exclamationmark.shield.fill")
                            .foregroundStyle(.red)
                            .font(.callout.bold())
                        LabeledContent("已选密钥") {
                            Text("\(selectedSnapshotKeyIDs.count) / \(snapshotKeys.count)")
                        }
                        if isIndexingSnapshotKeys {
                            ProgressView("扫描可选密钥…")
                        } else if snapshotKeys.isEmpty {
                            Text("没有可备份的已索引密钥。请先在密钥页检查公钥或主机的 IdentityFile。")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        } else {
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 8) {
                                    ForEach(snapshotKeys) { key in
                                        Toggle(isOn: Binding(
                                            get: { selectedSnapshotKeyIDs.contains(key.id) },
                                            set: { selected in
                                                if selected { selectedSnapshotKeyIDs.insert(key.id) }
                                                else { selectedSnapshotKeyIDs.remove(key.id) }
                                            }
                                        )) {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(key.name)
                                                Text(key.privateKeyURL.path)
                                                    .font(.caption.monospaced())
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(1)
                                                    .help(key.privateKeyURL.path)
                                                Text(key.privateKeyExists ? "包含私钥" : "仅公钥")
                                                    .font(.caption)
                                                    .foregroundStyle(key.privateKeyExists ? .orange : .secondary)
                                            }
                                        }
                                        .disabled(!key.publicKeyExists && !key.privateKeyExists)
                                    }
                                }
                            }
                            .frame(maxHeight: 150)
                            .accessibilityLabel("选择要加入本机快照的密钥")
                            Button("重新扫描可选密钥", action: reloadSnapshotKeys)
                        }
                    } else {
                        Text("默认只备份 config 与 Include 文件，不复制私钥。密钥备份仅包含“密钥”页可识别的文件。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Button(isCreatingSnapshot ? "正在创建快照…" : "立即创建配置快照") {
                        if snapshotIncludeKeys { showsSnapshotKeyConfirmation = true }
                        else { createSnapshot() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isCreatingSnapshot || (snapshotIncludeKeys &&
                        (isIndexingSnapshotKeys || selectedSnapshotKeyIDs.isEmpty)))
                    Button("浏览与恢复快照") { showsSnapshotBrowser = true }
                    if let snapshotResult {
                        Label("已备份 \(snapshotResult.fileCount) 个文件到 \(snapshotResult.url.path)", systemImage: "checkmark.circle")
                            .font(.callout)
                            .textSelection(.enabled)
                        Button("在 Finder 中查看") {
                            NSWorkspace.shared.activateFileViewerSelecting([snapshotResult.url])
                        }
                    }
                    Text("这是未额外加密的本机手动快照；自动变更记录也只保存在本机。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Section("iCloud 加密配置") {
                    LabeledContent("iCloud 位置") {
                        Text(iCloudBackupFolder.path)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                    Button("选择 iCloud Drive 文件夹…", action: chooseICloudFolder)
                    Button("连接测试、推送与拉取…") { showsCloudSync = true }
                        .task(id: cloudDriveRoot.path) {
                            let path = cloudDriveRoot.path
                            iCloudDriveAvailable = await Task.detached(priority: .utility) {
                                FileManager.default.fileExists(atPath: path)
                            }.value
                        }
                    Label("云端仅写入每台 Mac 独立的加密配置文件；不上传私钥。拉取前会展示差异并备份本机原文件。",
                          systemImage: "lock.shield")
                        .font(.callout)
                    if !iCloudDriveAvailable {
                        Label("未检测到 iCloud Drive，请先在系统设置中启用。", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
                Section("配置文件") {
                    LabeledContent("主配置") { Text(writer.rootURL.path).textSelection(.enabled) }
                    LabeledContent("新增主机目录") { Text(writer.managedDirectoryURL.path).textSelection(.enabled) }
                    Text("新增主机前会展示文本差异；保存时检查外部改动并备份原文件。复杂配置保持只读。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Section("备份") {
                    LabeledContent("备份目录") { Text(writer.backups.directoryURL.path).textSelection(.enabled) }
                    Stepper("最多保留 \(backupLimit == 0 ? "不限" : String(backupLimit)) 条备份", value: $backupLimit, in: 0...200)
                    Text("设为 0 可关闭自动清理。恢复前会检查当前文件是否仍与备份记录匹配。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("配置与备份", systemImage: "externaldrive") }
            .tag(1)

            Form {
                Section("外观与启动") {
                Picker("外观", selection: $appearance) {
                    Text("跟随系统").tag("system")
                    Text("浅色").tag("light")
                    Text("深色").tag("dark")
                }
                Toggle("登录时启动", isOn: Binding(
                    get: { loginItemEnabled },
                    set: { updateLoginItem($0) }
                ))
                .disabled(Bundle.main.bundleURL.pathExtension != "app")
                if Bundle.main.bundleURL.pathExtension != "app" {
                    Text("登录时启动需要从打包后的 ConfigSSH.app 运行。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                }
                Section("快速连接") {
                    LabeledContent("全局快捷键") {
                        HStack(spacing: 10) {
                            if let shortcut = currentShortcut {
                                ShortcutKeycaps(text: shortcut.display)
                            } else {
                                Text("已关闭").foregroundStyle(.secondary)
                            }
                            Button(shortcutRecorder.isRecording ? "请按下新的组合键…" : "更改…") {
                                if shortcutRecorder.isRecording { shortcutRecorder.stop(restore: true) }
                                else {
                                    shortcutRecorder.start { recorded in globalShortcut = recorded.storageValue }
                                }
                            }
                            .accessibilityIdentifier("shortcutRecordButton")
                            Menu("常用组合") {
                                ForEach(GlobalShortcut.presets, id: \.storageValue) { preset in
                                    Button(preset.display + (preset == .default ? "（默认）" : "")) {
                                        globalShortcut = preset.storageValue
                                    }
                                }
                                Divider()
                                Button("关闭全局快捷键") { globalShortcut = GlobalShortcut.offValue }
                            }
                            .fixedSize()
                        }
                    }
                    if shortcutRecorder.isRecording {
                        Label("按下想用的组合键（需包含 ⌘、⌃、⌥ 之一），按 Esc 取消。", systemImage: "keyboard")
                            .font(.callout)
                            .foregroundStyle(BrandPalette.accent)
                    }
                    if let message = shortcutRecorder.message {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                    if let note = currentShortcut?.cautionNote {
                        Label(note, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                    if let shortcut = currentShortcut, shortcut != GlobalShortcutManager.shared.activeShortcut,
                       !shortcutRecorder.isRecording {
                        Label("这个快捷键当前未生效（可能已被其他应用占用），请换一个组合。",
                              systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    HStack {
                        Button("立即试用") { GlobalShortcutManager.shared.showPanel() }
                            .disabled(currentShortcut == nil)
                        Button("恢复默认（\(GlobalShortcut.default.display)）") { globalShortcut = GlobalShortcut.default.storageValue }
                            .disabled(currentShortcut == .default)
                    }
                    Text("在任何应用中按全局快捷键，屏幕上方会弹出主机搜索框：输入关键词，用 ↑↓ 选择，回车即用默认终端连接，⌘↵ 用新标签页；Esc 或再次按快捷键关闭。也可以点击菜单栏图标搜索；主窗口内按 ⌘K。快捷键只在 ConfigSSH 运行时有效，建议同时开启“登录时启动”。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("通用", systemImage: "gearshape") }
            .tag(2)

            AboutConfigSSHView()
                .tabItem { Label("关于 ConfigSSH", systemImage: "info.circle") }
                .tag(3)
        }
        .frame(width: 700, height: 600)
        .tint(BrandPalette.accent(for: colorScheme))
        .onAppear {
            refreshTerminals()
            UserDefaults.standard.removeObject(forKey: "snapshotIncludeKeys")
            reloadSnapshotKeys()
        }
        .onDisappear {
            snapshotKeyIndexTask?.cancel()
            terminalProbeTask?.cancel()
        }
        .onReceive(NotificationCenter.default.publisher(for: .configSSHTerminalProfilesChanged)) { _ in
            refreshTerminals()
        }
        #if DEBUG
        .task {
            if ConfigSSHPaths.isPreviewMode &&
                ProcessInfo.processInfo.environment["CONFIGSSH_PREVIEW_SNAPSHOT_BROWSER"] == "1" {
                try? await Task.sleep(for: .seconds(1))
                showsSnapshotBrowser = true
            }
            if ConfigSSHPaths.isPreviewMode &&
                ProcessInfo.processInfo.environment["CONFIGSSH_PREVIEW_CLOUD_SYNC"] == "1" {
                try? await Task.sleep(for: .seconds(1))
                showsCloudSync = true
            }
        }
        #endif
        .fileImporter(isPresented: $showsAppPicker, allowedContentTypes: [.applicationBundle]) { result in
            do {
                let url = try result.get()
                try TerminalCatalog.shared.addApplication(at: url)
                refreshTerminals()
            } catch { settingsError = error.localizedDescription }
        }
        .sheet(isPresented: $showsSnapshotBrowser) {
            SnapshotBrowserView(writer: writer, localFolder: localSnapshotFolder,
                                cloudFolder: nil)
        }
        .sheet(isPresented: $showsCloudSync) {
            CloudSyncView(writer: writer, folder: iCloudBackupFolder, cloudRoot: cloudDriveRoot)
        }
        .sheet(item: Binding(
            get: { editingProfileID.map(ProfileSelection.init(id:)) },
            set: { editingProfileID = $0?.id }
        )) { selection in
            if let profile = profiles.first(where: { $0.id == selection.id }) {
                NavigationStack {
                    Form {
                        LabeledContent("应用", value: profile.displayName)
                        LabeledContent("Bundle ID", value: profile.id)
                        LabeledContent("当前方式", value: profile.strategy.rawValue)
                        TextField("CLI 绝对路径", text: $executablePath)
                        Text("参数（每行一个；{alias} 或 {ssh}）")
                        TextEditor(text: $argumentsText).frame(height: 110)
                        Text("保存后使用自定义 CLI 启动；留空时恢复自动检测方式。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .formStyle(.grouped)
                    .toolbar {
                        Button("取消") { editingProfileID = nil }
                        Button("保存") {
                            do {
                                var updated = profile
                                if executablePath.isEmpty && argumentsText.isEmpty {
                                    updated = TerminalCatalog.shared.automaticProfile(for: profile)
                                } else {
                                    updated.strategy = .customCLI
                                    updated.executablePath = executablePath
                                    updated.arguments = argumentsText.split(whereSeparator: \.isNewline).map(String.init)
                                }
                                try TerminalCatalog.shared.save(updated)
                                refreshTerminals()
                                editingProfileID = nil
                            } catch { settingsError = error.localizedDescription }
                        }
                    }
                    .frame(width: 520, height: 380)
                }
            }
        }
        .onChange(of: globalShortcut) { previous, current in
            if !GlobalShortcutManager.shared.apply(GlobalShortcut.resolved(current)) {
                globalShortcut = previous
                _ = GlobalShortcutManager.shared.apply(GlobalShortcut.resolved(previous))
                settingsError = "这个快捷键已被其他应用占用，请换一个组合。"
            }
        }
        .onDisappear { if shortcutRecorder.isRecording { shortcutRecorder.stop(restore: true) } }
        .alert("操作未完成", isPresented: Binding(
            get: { settingsError != nil },
            set: { if !$0 { settingsError = nil } }
        )) {
            Button("确定", role: .cancel) { settingsError = nil }
        } message: {
            Text(settingsError ?? "")
        }
        .confirmationDialog("开启私钥备份？", isPresented: $showsKeyBackupRisk) {
            Button("我了解风险，选择密钥", role: .destructive) {
                snapshotIncludeKeys = true
                selectedSnapshotKeyIDs.removeAll()
                reloadSnapshotKeys()
            }
            Button("取消", role: .cancel) {
                snapshotIncludeKeys = false
                selectedSnapshotKeyIDs.removeAll()
            }
        } message: {
            Text("本次本机快照会复制私钥文件，ConfigSSH 不会额外加密。任何能访问备份的人都可能使用该私钥；建议先给私钥设置口令。")
        }
        .confirmationDialog("确认备份私钥文件？", isPresented: $showsSnapshotKeyConfirmation) {
            Button("继续备份私钥", role: .destructive) { createSnapshot() }
            Button("取消", role: .cancel) {
                snapshotIncludeKeys = false
                selectedSnapshotKeyIDs.removeAll()
            }
        } message: {
            Text("本次只会复制已勾选的 \(selectedSnapshotKeyIDs.count) 把已索引密钥所对应的现有公钥和私钥。ConfigSSH 不会对快照额外加密。")
        }
    }

    private var cloudDriveRoot: URL {
        #if DEBUG
        if ConfigSSHPaths.isPreviewMode {
            return writer.rootURL.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("iCloudDrive")
        }
        #endif
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
    }

    private var iCloudBackupFolder: URL {
        #if DEBUG
        if ConfigSSHPaths.isPreviewMode { return cloudDriveRoot.appendingPathComponent("ConfigSSH") }
        #endif
        return snapshotICloudFolder.isEmpty ? cloudDriveRoot.appendingPathComponent("ConfigSSH") :
            URL(fileURLWithPath: snapshotICloudFolder)
    }

    private var localSnapshotFolder: URL { ConfigSSHPaths.localSnapshotFolder }

    private var currentShortcut: GlobalShortcut? { GlobalShortcut.resolved(globalShortcut) }

    private func chooseICloudFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = cloudDriveRoot
        guard panel.runModal() == .OK, let selected = panel.url else { return }
        let path = selected.standardizedFileURL.path
        guard path == cloudDriveRoot.path || path.hasPrefix(cloudDriveRoot.path + "/") else {
            settingsError = "请选择 iCloud Drive 内的文件夹，不能选择其他位置。"
            return
        }
        snapshotICloudFolder = path
    }

    private func createSnapshot() {
        let includeKeys = snapshotIncludeKeys
        let selectedKeys: Set<String>? = includeKeys ? selectedSnapshotKeyIDs : nil
        snapshotIncludeKeys = false
        selectedSnapshotKeyIDs.removeAll()
        let destination: SnapshotDestination = .local(localSnapshotFolder)
        let root = writer.rootURL
        isCreatingSnapshot = true
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> (SnapshotResult?, String?) in
                do {
                    let scan = ConfigReader(rootURL: root).scan()
                    return (try BackupSnapshotService().create(scan: scan, destination: destination,
                                                               includeKeys: includeKeys,
                                                               selectedKeyIDs: selectedKeys), nil)
                } catch {
                    return (nil, error.localizedDescription)
                }
            }.value
            isCreatingSnapshot = false
            if let result = outcome.0 { snapshotResult = result }
            if let error = outcome.1 { settingsError = error }
        }
    }

    private func reloadSnapshotKeys() {
        snapshotKeyIndexTask?.cancel()
        isIndexingSnapshotKeys = true
        let root = writer.rootURL
        snapshotKeyIndexTask = Task {
            let index = await Task.detached(priority: .utility) {
                let scan = ConfigReader(rootURL: root).scan()
                return KeyIndex(sshDirectory: root.deletingLastPathComponent())
                    .scan(hosts: scan.hosts, globalOptions: scan.globalOptions)
            }.value
            if Task.isCancelled { return }
            snapshotKeys = index.keys.filter { $0.publicKeyExists || $0.privateKeyExists }
            selectedSnapshotKeyIDs.formIntersection(Set(snapshotKeys.map(\.id)))
            isIndexingSnapshotKeys = false
        }
    }

    private func refreshTerminals() {
        terminalProbeTask?.cancel()
        profiles = TerminalCatalog.shared.cachedProfiles ?? []
        terminalCapabilities = Dictionary(uniqueKeysWithValues:
            launchService.capabilities().map { ($0.id, $0) })
        terminalProbeTask = Task {
            let installed = await TerminalCatalog.shared.loadInstalled()
            if Task.isCancelled { return }
            profiles = installed
            let loaded = await launchService.refreshCapabilities()
            if Task.isCancelled { return }
            terminalCapabilities = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })
        }
    }

    private func updateLoginItem(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginItemEnabled = SMAppService.mainApp.status == .enabled
        } catch {
            settingsError = error.localizedDescription
            loginItemEnabled = SMAppService.mainApp.status == .enabled
        }
    }
}
