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
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage(GlobalShortcutSettings.defaultsKey) private var globalShortcut = GlobalShortcut.default.storageValue
    @State private var shortcutRecorder = ShortcutRecorderModel()
    @State private var launchService = TerminalLaunchService()
    @State private var profiles: [TerminalProfile] = []
    @State private var terminalCapabilities: [String: TerminalCapability] = [:]
    @State private var terminalProbeTask: Task<Void, Never>?
    @State private var editingProfileID: String?
    @State private var executablePath = ""
    @State private var argumentsText = ""
    @State private var showsAppPicker = false
    @State private var loginItemStatus = SMAppService.mainApp.status
    @State private var settingsError: String?

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

            BackupSettingsView(writer: writer)
            .tabItem { Label("备份", systemImage: "externaldrive") }
            .tag(1)

            Form {
                Section("启动") {
                    Toggle("开机自启", isOn: Binding(
                        get: { loginItemStatus == .enabled || loginItemStatus == .requiresApproval },
                        set: { updateLoginItem($0) }
                    ))
                    .disabled(Bundle.main.bundleURL.pathExtension != "app")
                    .accessibilityIdentifier("launchAtLoginToggle")
                    Text("开启后，登录 Mac 时自动在菜单栏运行 ConfigSSH，全局快捷键和菜单栏搜索随时可用。默认关闭。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if loginItemStatus == .requiresApproval {
                        HStack {
                            Label("还需要在“系统设置 › 通用 › 登录项”中允许 ConfigSSH。", systemImage: "exclamationmark.triangle")
                                .font(.callout)
                                .foregroundStyle(.orange)
                            Spacer()
                            Button("打开系统设置") { SMAppService.openSystemSettingsLoginItems() }
                        }
                    }
                    if Bundle.main.bundleURL.pathExtension != "app" {
                        Text("开机自启需要从打包后的 ConfigSSH.app 运行。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("外观") {
                    Picker("外观", selection: $appearance) {
                        Text("跟随系统").tag("system")
                        Text("浅色").tag("light")
                        Text("深色").tag("dark")
                    }
                }
                Section("快速连接") {
                    LabeledContent("全局快捷键") {
                        HStack(spacing: 10) {
                            if let shortcut = currentShortcut {
                                ShortcutKeycaps(parts: shortcut.keyParts)
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
                    Text("在任何应用中按全局快捷键，屏幕上方会弹出主机搜索框：输入关键词，用 ↑↓ 选择，回车即用默认终端连接，⌘↵ 用新标签页；Esc 或再次按快捷键关闭。也可以点击菜单栏图标搜索；主窗口内按 ⌘K。快捷键只在 ConfigSSH 运行时有效，建议同时开启“开机自启”。")
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
            // Older versions could ask for a key-inclusive snapshot; that option no longer exists.
            UserDefaults.standard.removeObject(forKey: "snapshotIncludeKeys")
        }
        .onDisappear {
            terminalProbeTask?.cancel()
        }
        .onReceive(NotificationCenter.default.publisher(for: .configSSHTerminalProfilesChanged)) { _ in
            refreshTerminals()
        }
        .fileImporter(isPresented: $showsAppPicker, allowedContentTypes: [.applicationBundle]) { result in
            do {
                let url = try result.get()
                try TerminalCatalog.shared.addApplication(at: url)
                refreshTerminals()
            } catch { settingsError = error.localizedDescription }
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
    }

    private var currentShortcut: GlobalShortcut? { GlobalShortcut.resolved(globalShortcut) }

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
        } catch {
            settingsError = error.localizedDescription
        }
        loginItemStatus = SMAppService.mainApp.status
    }
}
