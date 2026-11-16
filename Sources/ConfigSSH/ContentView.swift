import AppKit
import ConfigSSHCore
import SwiftUI

private enum SidebarSection: String, CaseIterable, Identifiable {
    case hosts = "全部主机"
    case favorites = "收藏"
    case recent = "最近启动"
    case keys = "密钥"
    case globalConfig = "全局配置"
    case backups = "变更记录"
    case issues = "解析告警"

    var id: Self { self }

    static var initial: Self {
        #if DEBUG
        if ConfigSSHPaths.isPreviewMode {
            switch ProcessInfo.processInfo.environment["CONFIGSSH_PREVIEW_SECTION"] {
            case "global": return .globalConfig
            case "keys": return .keys
            case "backups": return .backups
            case "issues": return .issues
            default: break
            }
        }
        #endif
        return .hosts
    }

    var symbol: String {
        switch self {
        case .hosts: "server.rack"
        case .favorites: "star"
        case .recent: "clock"
        case .keys: "key"
        case .globalConfig: "slider.horizontal.3"
        case .backups: "clock.arrow.circlepath"
        case .issues: "exclamationmark.triangle"
        }
    }
}

private struct EditorRequest: Identifiable {
    let id = UUID()
    let mode: HostEditorMode
}

private struct GroupDeleteRequest: Identifiable {
    let id = UUID()
    let name: String
}

private enum HostSort: String, CaseIterable, Identifiable {
    case source = "配置顺序"
    case name = "主机名称"

    var id: Self { self }
}

private struct AppToast: Identifiable {
    let id = UUID()
    let message: String
    let isError: Bool
}

private struct AppToastView: View {
    let toast: AppToast

    var body: some View {
        Label(toast.message, systemImage: toast.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
            .font(.callout)
            .foregroundStyle(toast.isError ? .orange : .primary)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator.opacity(0.5)))
            .shadow(color: .black.opacity(0.12), radius: 12, y: 6)
            .frame(maxWidth: 500)
            .allowsHitTesting(false)
            .accessibilityElement(children: .combine)
    }
}

struct ContentView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorContrast
    #if DEBUG
    @Environment(\.openSettings) private var openSettings
    #endif
    @State private var writer = ConfigWriter()
    @State private var scan = ConfigScan(rootURL: ConfigSSHPaths.rootURL, availability: .missing,
                                         hosts: [], globalOptions: [], rules: [], issues: [], sources: [])
    @State private var metadataStore = try? MetadataStore()
    @State private var metadata: [String: HostMetadata] = [:]
    @State private var recentEvents: [LaunchEvent] = []
    @State private var keyIndex = KeyIndexResult(keys: [], issues: [])
    @State private var scanTask: Task<Void, Never>?
    @State private var isScanning = true
    @State private var terminalService = TerminalLaunchService()
    @State private var terminalCapabilities: [TerminalCapability] = []
    @State private var terminalProbeTask: Task<Void, Never>?
    @AppStorage("defaultTerminal") private var defaultTerminalRaw = ""
    @AppStorage("defaultOpenMode") private var defaultOpenModeRaw = TerminalOpenMode.window.rawValue
    @State private var backupRecords: [BackupRecord] = []
    @State private var pendingGroupOperations: [PendingGroupDeletion] = []
    @State private var section: SidebarSection? = SidebarSection.initial
    @State private var selectedHostID: String?
    @State private var selectedIssueID: UUID?
    @State private var selectedBackupID: UUID?
    @State private var selectedKeyID: String?
    @State private var globalConfigPage: GlobalConfigPage? = .overview
    @State private var editorRequest: EditorRequest?
    @State private var showsGroupCreation = false
    @State private var groupDeleteRequest: GroupDeleteRequest?
    @State private var restoreRecord: BackupRecord?
    @State private var metadataHost: HostRecord?
    @State private var showsRootConfigEditor = false
    @State private var showsKeyGeneration = false
    @State private var keyGenerationID = UUID()
    @State private var showsQuickLaunch = false
    @State private var toast: AppToast?
    @State private var externalConfigChanged = false
    @State private var monitorGeneration = 0
    @State private var searchText = ""
    @State private var groupFilter: String?
    @State private var collapsedGroups: Set<String> = []
    @State private var hostSort: HostSort = .source

    private func group(for host: HostRecord) -> String {
        host.configGroup ?? metadata[host.metadataKey]?.groupName ?? "未分组"
    }

    private var groups: [String] {
        Array(Set(scan.hosts.map(group(for:))).union(writer.groupDirectories()))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var visibleHosts: [HostRecord] {
        let matching = scan.hosts.filter { host in
            let details = metadata[host.metadataKey]
            let terms = searchText.split(whereSeparator: \.isWhitespace).map(String.init)
            let extra = [details?.displayName, details?.groupName, details?.note]
                .compactMap { $0 } + (details?.tags ?? [])
            let searchMatches = terms.isEmpty || terms.allSatisfy { term in
                host.matches(term) || extra.contains {
                    $0.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                }
            }
            guard searchMatches else { return false }
            switch section ?? .hosts {
            case .hosts:
                return groupFilter == nil || group(for: host) == groupFilter
            case .favorites: return details?.isFavorite == true
            case .recent: return recentEvents.contains { $0.hostKey == host.metadataKey }
            default: return true
            }
        }
        if section == .recent {
            return matching.sorted { lhs, rhs in
                let left = recentEvents.first { $0.hostKey == lhs.metadataKey }?.requestedAt ?? .distantPast
                let right = recentEvents.first { $0.hostKey == rhs.metadataKey }?.requestedAt ?? .distantPast
                return left > right
            }
        }
        switch hostSort {
        case .source: return matching
        case .name: return matching.sorted {
            $0.alias.localizedStandardCompare($1.alias) == .orderedAscending
        }
        }
    }

    private var expandedVisibleHosts: [HostRecord] {
        visibleHosts.filter { !collapsedGroups.contains(group(for: $0)) }
    }

    private var displayedSelectedHostID: String? {
        HostListSelection.resolvedID(currentID: selectedHostID, visibleHosts: visibleHosts,
                                     collapsedGroups: collapsedGroups, groupForHost: group(for:))
    }

    private var selectedHostForDetail: HostRecord? {
        expandedVisibleHosts.first { $0.id == displayedSelectedHostID }
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                BrandHeaderView()
                Divider()
                List(SidebarSection.allCases, selection: $section) { item in
                    Label {
                        HStack {
                            Text(item.rawValue)
                            Spacer()
                            if item == .issues && !scan.issues.isEmpty {
                                Text(scan.issues.count, format: .number)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } icon: {
                        Image(systemName: item.symbol)
                    }
                    .tag(item)
                    .accessibilityIdentifier("sidebar-\(item.id)")
                }
                .listStyle(.sidebar)
            }
            .navigationTitle("ConfigSSH")
            .navigationSplitViewColumnWidth(min: 180, ideal: 210)
        } content: {
            if isScanning {
                ProgressView("读取 SSH 配置…")
            } else {
                switch section ?? .hosts {
                case .hosts, .favorites, .recent: hostList
                case .keys: keyList
                case .globalConfig: globalConfigList
                case .backups: backupList
                case .issues: issueList
                }
            }
        } detail: {
            if isScanning {
                ProgressView("建立主机索引…")
            } else {
                switch section ?? .hosts {
            case .hosts, .favorites, .recent:
                if let host = selectedHostForDetail {
                    HostDetailView(host: host,
                                   metadata: metadata[host.metadataKey],
                                   defaultTerminal: TerminalSelection.resolved(defaultTerminalRaw, from: terminalCapabilities),
                                   defaultOpenMode: metadata[host.metadataKey]?.preferredOpenMode.map(TerminalOpenMode.resolved(_:))
                                        ?? TerminalOpenMode.resolved(defaultOpenModeRaw),
                                   capabilities: terminalCapabilities,
                                   onEdit: { editorRequest = EditorRequest(mode: .edit(host)) },
                                   onDelete: { editorRequest = EditorRequest(mode: .delete(host)) },
                                   onMetadata: { metadataHost = host },
                                   onToggleFavorite: { toggleFavorite(host) },
                                   onLaunch: { terminal, mode in launch(host, terminal: terminal, mode: mode) },
                                   onCopyCommand: { copyCommand(host) })
                } else {
                    ContentUnavailableView("选择一台主机", systemImage: "server.rack")
                }
            case .backups:
                if let record = backupRecords.first(where: { $0.id == selectedBackupID }) {
                    BackupDetailView(record: record) { restoreRecord = record }
                } else {
                    ContentUnavailableView("选择一条变更记录", systemImage: "clock.arrow.circlepath")
                }
            case .keys:
                if let key = keyIndex.keys.first(where: { $0.id == selectedKeyID }) {
                    KeyDetailView(key: key) {
                        NSPasteboard.general.clearContents()
                        if let publicKey = key.publicKeyText {
                            NSPasteboard.general.setString(publicKey, forType: .string)
                        }
                        showToast("公钥已复制。")
                    }
                } else {
                    ContentUnavailableView("选择一把公钥", systemImage: "key")
                }
            case .globalConfig:
                switch globalConfigPage ?? .overview {
                case .overview:
                    GlobalConfigOverviewView(scan: scan, rootURL: writer.rootURL) {
                        showsRootConfigEditor = true
                    }
                case .files: GlobalConfigFilesView(scan: scan, rootURL: writer.rootURL)
                case .rules: GlobalConfigRulesView(scan: scan)
                case .help: GlobalConfigHelpView()
                }
            case .issues:
                if let issue = scan.issues.first(where: { $0.id == selectedIssueID }) {
                    IssueDetailView(issue: issue)
                } else {
                    ContentUnavailableView("选择一条告警", systemImage: "exclamationmark.triangle")
                }
                }
            }
        }
        .tint(BrandPalette.accent(for: colorScheme))
        .frame(minWidth: 900, minHeight: 540)
        .toolbar {
            Button {
                showsQuickLaunch = true
            } label: {
                Label("快速连接", systemImage: "bolt")
            }
            .keyboardShortcut("k", modifiers: .command)

            if section == .hosts {
                Button {
                    addHost()
                } label: {
                    Label("新增主机", systemImage: "plus")
                }
                .help("在受管 SSH 配置中新增主机")
                .disabled({
                    if case .unreadable = scan.availability { return true }
                    return false
                }())
            }

            Menu {
                if section == .hosts {
                    Button("创建分组…", systemImage: "folder.badge.plus") {
                        showsGroupCreation = true
                    }
                    if !groups.isEmpty {
                        Menu("筛选分组") {
                            Button("全部分组") { groupFilter = nil }
                            ForEach(groups, id: \.self) { group in
                                Button(group) { groupFilter = group }
                            }
                        }
                    }
                }
                if section == .hosts || section == .favorites || section == .recent {
                    Picker("主机排序", selection: $hostSort) {
                        ForEach(HostSort.allCases) { sort in
                            Text(sort.rawValue).tag(sort)
                        }
                    }
                    Divider()
                }
                Button("重新载入配置", systemImage: "arrow.clockwise") { reload() }
                    .keyboardShortcut("r", modifiers: .command)
            } label: {
                Label("更多操作", systemImage: "ellipsis.circle")
            }
            .help("分组、排序与重新载入")
        }
        .sheet(item: $editorRequest) { request in
            HostEditorView(mode: request.mode, scan: scan, writer: writer, availableKeys: keyIndex.keys,
                           availableGroups: groups) { alias in
                reload(selectAlias: alias)
            }
        }
        .sheet(isPresented: $showsGroupCreation) {
            GroupCreationView { name in
                try writer.createGroup(named: name)
                groupFilter = name
                collapsedGroups.remove(name)
                ensureSelection()
            }
        }
        .sheet(item: $groupDeleteRequest) { request in
            GroupDeletionView(name: request.name, writer: writer, scan: scan) { plan in
                try deleteGroup(plan)
            }
        }
        .sheet(item: $restoreRecord) { record in
            RestorePreviewView(record: record, writer: writer) {
                reload()
            }
        }
        .sheet(item: $metadataHost) { host in
            HostMetadataSheet(host: host, existing: metadata[host.metadataKey]) { updated in
                guard let metadataStore else {
                    throw MetadataError.database("本地数据库不可用，无法保存主机信息")
                }
                try metadataStore.save(updated)
                metadata[updated.hostKey] = updated
                ensureSelection()
            }
        }
        .sheet(isPresented: $showsRootConfigEditor) {
            RootConfigEditorView(writer: writer, scan: scan) { reload() }
        }
        .sheet(isPresented: $showsKeyGeneration) {
            KeyGenerationView { privateURL in
                let hosts = scan.hosts
                let options = scan.globalOptions
                let sshDirectory = writer.rootURL.deletingLastPathComponent()
                Task {
                    let refreshed = await Task.detached(priority: .utility) {
                        KeyIndex(sshDirectory: sshDirectory).scan(hosts: hosts, globalOptions: options)
                    }.value
                    keyIndex = refreshed
                    selectedKeyID = refreshed.keys.first(where: { $0.privateKeyURL == privateURL })?.id
                }
            }
            .id(keyGenerationID)
        }
        .sheet(isPresented: $showsQuickLaunch) {
            QuickLaunchView(onEscape: { showsQuickLaunch = false })
        }
        .overlay(alignment: .bottom) {
            if externalConfigChanged || !pendingGroupOperations.isEmpty {
                VStack(spacing: 8) {
                if externalConfigChanged {
                    HStack {
                        Label("SSH 配置已在磁盘上更新", systemImage: "arrow.triangle.2.circlepath")
                        Button("重新载入") { reload() }
                    }
                    .font(.callout)
                }
                if let operation = pendingGroupOperations.first {
                    HStack {
                        Label("“\(operation.name)”分组有未完成的移动", systemImage: "exclamationmark.triangle.fill")
                        Button("继续处理") { resumeGroupDeletion(operation) }
                    }
                    .font(.callout)
                }
                }
                .padding(12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .shadow(color: .black.opacity(0.12), radius: 12, y: 6)
                .padding(.bottom, 14)
            }
        }
        .overlay(alignment: .top) {
            if let toast {
                AppToastView(toast: toast)
                    .padding(.top, 14)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: toast?.id)
        .task(id: monitorGeneration) {
            if isScanning { return }
            let baseline = ConfigChangeMonitor.fingerprint(scan)
            let rootPath = writer.rootURL.path
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                if Task.isCancelled { return }
                let current = await Task.detached(priority: .utility) {
                    ConfigChangeMonitor.fingerprint(rootURL: URL(fileURLWithPath: rootPath))
                }.value
                if Task.isCancelled { return }
                if current != baseline {
                    externalConfigChanged = true
                    return
                }
            }
        }
        .task(id: toast?.id) {
            guard let id = toast?.id else { return }
            do {
                try await Task.sleep(for: .seconds(4))
                if toast?.id == id { toast = nil }
            } catch { }
        }
        .focusedSceneValue(\.newHostAction, { addHost() })
        .onAppear {
            #if DEBUG
            if ConfigSSHPaths.isPreviewMode { section = SidebarSection.initial }
            #endif
            refreshTerminals()
            loadBackups()
            loadMetadata()
            loadPendingGroupOperations()
            reload()
        }
        .onDisappear {
            scanTask?.cancel()
            terminalProbeTask?.cancel()
        }
        .onChange(of: searchText) { _, _ in ensureSelection() }
        .onChange(of: hostSort) { _, _ in ensureSelection() }
        .onChange(of: groupFilter) { _, _ in ensureSelection() }
        .onChange(of: section) { _, _ in ensureSelection() }
        .onReceive(NotificationCenter.default.publisher(for: .configSSHConfigChanged)) { _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: .configSSHTerminalProfilesChanged)) { _ in
            refreshTerminals()
        }
        #if DEBUG
        .task {
            if ConfigSSHPaths.isPreviewMode &&
                ProcessInfo.processInfo.environment["CONFIGSSH_PREVIEW_SETTINGS"] == "1" {
                try? await Task.sleep(for: .milliseconds(350))
                openSettings()
            }
        }
        #endif
    }

    private var hostList: some View {
        Group {
            switch scan.availability {
            case .missing:
                if section == .hosts && !groups.isEmpty && searchText.isEmpty {
                    hostGroupsView
                } else {
                    ContentUnavailableView {
                        Label("找不到 SSH 配置", systemImage: "server.rack")
                    } description: {
                        Text(section == .hosts ? "点击新增主机可创建第一条受管 SSH 配置。" : "请前往“全部主机”新增配置。")
                    } actions: {
                        if section == .hosts {
                            Button("新增主机") { addHost() }
                        }
                    }
                }
            case .unreadable(let message):
                ContentUnavailableView {
                    Label("无法读取 SSH 配置", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                }
            case .available:
                if visibleHosts.isEmpty && (section != .hosts || groups.isEmpty || !searchText.isEmpty) {
                    ContentUnavailableView {
                        Label(searchText.isEmpty ? (section == .favorites ? "暂无收藏主机" :
                            section == .recent ? "暂无启动记录" : "尚无可识别的主机") : "没有搜索结果",
                              systemImage: "server.rack")
                    } description: {
                        if searchText.isEmpty {
                            Text(section == .favorites ? "在主机详情中点击“收藏”即可加入。" :
                                section == .recent ? "启动主机后会在这里显示。" :
                                "让 SSH 配置管理更简单，让服务器连接更高效。")
                        } else {
                            Text("试试其他别名、地址或用户名。")
                        }
                    } actions: {
                        if searchText.isEmpty && section == .hosts {
                            Button("新增主机") { addHost() }
                        }
                    }
                } else {
                    hostGroupsView
                }
            }
        }
        .navigationTitle(section == .hosts ? (groupFilter ?? "全部主机") : (section ?? .hosts).rawValue)
        .searchable(text: $searchText, prompt: "搜索别名、地址或用户")
        .navigationSplitViewColumnWidth(min: 250, ideal: 310)
    }

    private var hostGroupsView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 5) {
                let selectedID = displayedSelectedHostID
                ForEach(groups.filter { groupFilter == nil || $0 == groupFilter }, id: \.self) { groupName in
                    let members = visibleHosts.filter { group(for: $0) == groupName }
                    if !members.isEmpty || (section == .hosts && searchText.isEmpty &&
                        writer.groupDirectories().contains(groupName)) {
                        HStack(spacing: 5) {
                            Button {
                                if collapsedGroups.contains(groupName) {
                                    collapsedGroups.remove(groupName)
                                } else {
                                    collapsedGroups.insert(groupName)
                                }
                                ensureSelection()
                            } label: {
                                HStack(spacing: 9) {
                                    Image(systemName: collapsedGroups.contains(groupName) ? "chevron.right" : "chevron.down")
                                        .font(.caption.weight(.semibold))
                                        .frame(width: 12)
                                        .foregroundStyle(.secondary)
                                    Image(systemName: "folder")
                                        .foregroundStyle(.tint)
                                    Text("\(groupName) · \(members.count)")
                                        .font(.headline)
                                    Spacer()
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(groupName)分组，\(members.count)台主机")
                            .accessibilityValue(collapsedGroups.contains(groupName) ? "已收起" : "已展开")
                            .accessibilityHint("按下以切换分组展开状态")
                            .accessibilityIdentifier("groupToggle-\(groupName)")

                            if section == .hosts {
                                Button { addHost(to: groupName) } label: {
                                    Image(systemName: "plus")
                                }
                                .buttonStyle(.borderless)
                                .help("在\(groupName)分组新增主机")
                                .accessibilityLabel("在\(groupName)分组新增主机")
                                if groupName != "未分组" {
                                    Button {
                                        groupDeleteRequest = GroupDeleteRequest(name: groupName)
                                    } label: {
                                        Image(systemName: "trash")
                                            .font(.callout)
                                            .frame(width: 20, height: 20)
                                    }
                                    .buttonStyle(.borderless)
                                    .foregroundStyle(.secondary)
                                    .help("删除“\(groupName)”分组；将先预览主机迁移")
                                    .accessibilityLabel("删除“\(groupName)”分组")
                                    .accessibilityHint("先预览主机迁移，再确认删除")
                                    .accessibilityIdentifier("groupDelete-\(groupName)")
                                }
                            }
                        }

                        if !collapsedGroups.contains(groupName) {
                            if members.isEmpty {
                                Text("暂无主机")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .padding(.leading, 43)
                                    .padding(.vertical, 8)
                            } else {
                                ForEach(members) { host in
                                    Button { selectedHostID = host.id } label: {
                                        HostRowView(host: host, metadata: metadata[host.metadataKey])
                                            .padding(.horizontal, 11)
                                            .padding(.vertical, 4)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .background(selectedID == host.id
                                                        ? BrandPalette.selectionBlue.opacity(colorContrast == .increased ? 0.42 : 0.28)
                                                        : .clear,
                                                        in: RoundedRectangle(cornerRadius: 9))
                                            .overlay {
                                                if selectedID == host.id {
                                                    RoundedRectangle(cornerRadius: 9)
                                                        .stroke(BrandPalette.accent(for: colorScheme)
                                                            .opacity(colorContrast == .increased ? 1 : 0.55),
                                                            lineWidth: colorContrast == .increased ? 1.5 : 1)
                                                }
                                            }
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .simultaneousGesture(TapGesture(count: 2).onEnded {
                                        selectedHostID = host.id
                                        launchDefault(host)
                                    })
                                    .accessibilityLabel("选择主机 \(host.alias)")
                                    .accessibilityValue([host.user, host.hostName]
                                        .compactMap { $0 }.joined(separator: "@"))
                                    .accessibilityHint("单击显示详情，双击使用默认终端连接")
                                    .accessibilityAddTraits(selectedID == host.id ? .isSelected : [])
                                    .accessibilityIdentifier("hostRow-\(host.alias)")
                                    .padding(.leading, 17)
                                }
                            }
                        }
                    }
                }
            }
            .padding(12)
        }
    }

    private var backupList: some View {
        Group {
            if backupRecords.isEmpty {
                ContentUnavailableView("没有变更记录", systemImage: "clock.arrow.circlepath")
            } else {
                List(backupRecords, selection: $selectedBackupID) { record in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(record.reason)
                        Text(record.createdAt, format: .dateTime.year().month().day().hour().minute())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(record.id)
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("变更记录")
        .navigationSplitViewColumnWidth(min: 250, ideal: 310)
    }

    private var keyList: some View {
        Group {
            if keyIndex.keys.isEmpty && keyIndex.issues.isEmpty {
                ContentUnavailableView("没有可识别的公钥", systemImage: "key")
            } else {
                List(selection: $selectedKeyID) {
                    Section("本地公钥") {
                        ForEach(keyIndex.keys) { key in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(key.name)
                                Text(key.type)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .tag(key.id)
                        }
                    }
                    if !keyIndex.issues.isEmpty {
                        Section("扫描告警") {
                            ForEach(keyIndex.issues, id: \.self) { issue in
                                Label(issue, systemImage: "exclamationmark.triangle")
                                    .font(.caption)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("密钥")
        .navigationSplitViewColumnWidth(min: 250, ideal: 310)
        .toolbar {
            Button {
                keyGenerationID = UUID()
                showsKeyGeneration = true
            } label: {
                Label("生成密钥", systemImage: "plus")
            }
            .help("使用 ssh-keygen 生成新密钥")
        }
    }

    private var globalConfigList: some View {
        List(GlobalConfigPage.allCases, selection: $globalConfigPage) { page in
            Label {
                Text(page.rawValue)
            } icon: {
                Image(systemName: page.symbol)
                    .foregroundStyle(BrandPalette.accent(for: colorScheme))
            }
                .tag(page)
        }
        .listStyle(.inset)
        .navigationTitle("全局配置")
        .navigationSplitViewColumnWidth(min: 250, ideal: 310)
    }

    private var issueList: some View {
        Group {
            if scan.issues.isEmpty {
                ContentUnavailableView("没有解析告警", systemImage: "checkmark.circle")
            } else {
                List(scan.issues, selection: $selectedIssueID) { issue in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(issue.message)
                            .lineLimit(2)
                        Text(issue.location)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .tag(issue.id)
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("解析告警")
        .navigationSplitViewColumnWidth(min: 250, ideal: 310)
    }

    private func reload(selectAlias alias: String? = nil) {
        scanTask?.cancel()
        isScanning = true
        externalConfigChanged = false
        let root = writer.rootURL
        scanTask = Task {
            let loaded = await Task.detached(priority: .userInitiated) { () -> (ConfigScan, KeyIndexResult) in
                let refreshed = ConfigReader(rootURL: root).scan()
                let keys = KeyIndex(sshDirectory: root.deletingLastPathComponent())
                    .scan(hosts: refreshed.hosts, globalOptions: refreshed.globalOptions)
                return (refreshed, keys)
            }.value
            if Task.isCancelled { return }
            scan = loaded.0
            keyIndex = loaded.1
            loadBackups()
            loadMetadata()
            loadPendingGroupOperations()
            collapsedGroups.formIntersection(Set(groups))
            if let groupFilter, !groups.contains(groupFilter) { self.groupFilter = nil }
            if let alias {
                if let host = scan.hosts.first(where: { $0.alias == alias }) {
                    selectedHostID = host.id
                    collapsedGroups.remove(group(for: host))
                }
                section = .hosts
            }
            selectedIssueID = scan.issues.first?.id
            ensureSelection()
            isScanning = false
            monitorGeneration += 1
        }
    }

    private func refreshTerminals() {
        terminalProbeTask?.cancel()
        terminalCapabilities = terminalService.capabilities()
        terminalProbeTask = Task {
            let loaded = await terminalService.refreshCapabilities()
            if Task.isCancelled { return }
            terminalCapabilities = loaded
        }
    }

    private func loadBackups() {
        backupRecords = (try? writer.backups.list()) ?? []
    }

    private func loadMetadata() {
        metadata = (try? metadataStore?.allMetadata()) ?? [:]
        recentEvents = (try? metadataStore?.recentEvents()) ?? []
    }

    private func loadPendingGroupOperations() {
        guard let metadataStore else { return }
        do {
            pendingGroupOperations = try GroupDeletionService(writer: writer, metadataStore: metadataStore)
                .pendingOperations()
        } catch {
            showToast("无法读取未完成的分组操作：\(error.localizedDescription)", isError: true)
        }
    }

    private func resumeGroupDeletion(_ operation: PendingGroupDeletion) {
        guard let metadataStore else { return }
        do {
            try GroupDeletionService(writer: writer, metadataStore: metadataStore).resume(operation)
            reload()
            showToast("分组操作已完成。")
        } catch {
            reload()
            showToast("无法继续分组操作：\(error.localizedDescription)", isError: true)
        }
    }

    private func launch(_ host: HostRecord, terminal: TerminalProfile, mode: TerminalOpenMode) {
        Task { @MainActor in
            do {
                let focused = try await terminalService.launch(host: host, with: terminal, mode: mode)
                if let metadataStore {
                    do {
                        try metadataStore.recordLaunch(hostKey: host.metadataKey, terminal: terminal.id)
                        recentEvents = (try? metadataStore.recentEvents()) ?? recentEvents
                        showToast(focused
                            ? "已切换到 \(terminal.displayName)；SSH 结果请在终端查看。"
                            : "已交给 \(terminal.displayName)，但未能自动切换窗口；请手动查看。",
                            isError: !focused)
                    } catch {
                        showToast("已交给 \(terminal.displayName)，但无法记录本地历史：\(error.localizedDescription)", isError: true)
                    }
                } else {
                    showToast("已交给 \(terminal.displayName)，但本地历史不可用。", isError: true)
                }
            } catch {
                showToast(error.localizedDescription, isError: true)
            }
        }
    }

    private func launchDefault(_ host: HostRecord) {
        guard let terminal = TerminalSelection.resolved(
            metadata[host.metadataKey]?.preferredTerminal ?? defaultTerminalRaw,
            from: terminalCapabilities
        ) else {
            showToast("尚无可用终端；请稍候检测完成或在设置中选择终端。", isError: true)
            return
        }
        let mode = TerminalOpenMode.resolved(metadata[host.metadataKey]?.preferredOpenMode ?? defaultOpenModeRaw)
        launch(host, terminal: terminal, mode: mode)
    }

    private func copyCommand(_ host: HostRecord) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(TerminalLaunchPlanner.copyableCommand(alias: host.alias), forType: .string)
        showToast("SSH 命令已复制。")
    }

    private func toggleFavorite(_ host: HostRecord) {
        guard let metadataStore else {
            showToast("本地元数据不可用，无法保存收藏状态。", isError: true)
            return
        }
        var record = metadata[host.metadataKey] ?? HostMetadata(hostKey: host.metadataKey)
        record.isFavorite.toggle()
        do {
            try metadataStore.save(record)
            metadata[host.metadataKey] = record
            ensureSelection()
        } catch {
            showToast("无法保存收藏状态：\(error.localizedDescription)", isError: true)
        }
    }

    private func addHost() {
        addHost(to: nil)
    }

    private func addHost(to groupName: String?) {
        if case .unreadable = scan.availability {
            showToast("主配置不可读，无法新增主机。", isError: true)
            return
        }
        section = .hosts
        editorRequest = EditorRequest(mode: .add(group: groupName == "未分组" ? "" : (groupName ?? "")))
    }

    private func deleteGroup(_ plan: GroupDeletionPlan) throws {
        guard let metadataStore else {
            throw MetadataError.database("本地数据库不可用，不能安全迁移分组中的主机信息")
        }
        defer { reload() }
        try GroupDeletionService(writer: writer, metadataStore: metadataStore).delete(plan)
        collapsedGroups.remove(plan.name)
        if groupFilter == plan.name { groupFilter = nil }
    }

    private func showToast(_ message: String, isError: Bool = false) {
        toast = AppToast(message: message, isError: isError)
    }

    private func ensureSelection() {
        selectedHostID = HostListSelection.resolvedID(currentID: selectedHostID, visibleHosts: visibleHosts,
                                                      collapsedGroups: collapsedGroups, groupForHost: group(for:))
        if selectedIssueID == nil { selectedIssueID = scan.issues.first?.id }
        if !backupRecords.contains(where: { $0.id == selectedBackupID }) {
            selectedBackupID = backupRecords.first?.id
        }
        if !keyIndex.keys.contains(where: { $0.id == selectedKeyID }) {
            selectedKeyID = keyIndex.keys.first?.id
        }
    }
}

private struct HostRowView: View {
    let host: HostRecord
    let metadata: HostMetadata?

    private var title: String {
        let name = metadata?.displayName ?? ""
        return name.isEmpty ? host.alias : name
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "server.rack")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text([host.user, host.hostName].compactMap { $0 }.joined(separator: "@"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if metadata?.isFavorite == true {
                Image(systemName: "star.fill")
                    .foregroundStyle(.yellow)
            }
            if !host.isSimple {
                Image(systemName: "lock.doc")
                    .foregroundStyle(.secondary)
                    .help(host.readOnlyReasons.joined(separator: "；"))
                    .accessibilityLabel("只读：\(host.readOnlyReasons.joined(separator: "；"))")
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

private struct HostDetailView: View {
    let host: HostRecord
    let metadata: HostMetadata?
    let defaultTerminal: TerminalProfile?
    let defaultOpenMode: TerminalOpenMode
    let capabilities: [TerminalCapability]
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onMetadata: () -> Void
    let onToggleFavorite: () -> Void
    let onLaunch: (TerminalProfile, TerminalOpenMode) -> Void
    let onCopyCommand: () -> Void

    private var selectedTerminal: TerminalProfile? {
        if let id = metadata?.preferredTerminal,
           let selected = capabilities.first(where: { $0.id == id }) { return selected.profile }
        return defaultTerminal
    }
    private var selectedCapability: TerminalCapability? { capabilities.first { $0.id == selectedTerminal?.id } }
    private var title: String {
        let name = metadata?.displayName ?? ""
        return name.isEmpty ? host.alias : name
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(title)
                            .font(.largeTitle.bold())
                            .lineLimit(2)
                            .accessibilityIdentifier("hostDetailTitle")
                        Spacer()
                        Button(action: onToggleFavorite) {
                            Image(systemName: metadata?.isFavorite == true ? "star.fill" : "star")
                        }
                        .buttonStyle(.borderless)
                        .help(metadata?.isFavorite == true ? "取消收藏" : "收藏主机")
                        .accessibilityLabel(metadata?.isFavorite == true ? "取消收藏" : "收藏主机")
                        .accessibilityIdentifier("hostFavoriteButton")
                    }
                    if metadata?.displayName.isEmpty == false {
                        Text("Host \(host.alias)")
                            .foregroundStyle(.secondary)
                    }
                    Text("此处仅展示 Host 块中的显式配置；全局规则、Include 和 Match 可能影响实际连接参数。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        Button("主机信息", action: onMetadata)
                        if host.isSimple {
                            Button("编辑配置", action: onEdit)
                            Button("删除主机…", role: .destructive, action: onDelete)
                                .foregroundStyle(.red)
                                .accessibilityIdentifier("hostDeleteButton")
                        }
                    }
                    .buttonStyle(.borderless)
                    .padding(.top, 5)
                }

                HStack(spacing: 10) {
                    Button("连接") {
                        if let selectedTerminal { onLaunch(selectedTerminal, defaultOpenMode) }
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("hostConnectButton")
                    .disabled(
                        !(defaultOpenMode == .window
                            ? selectedCapability?.supportsWindow == true
                            : selectedCapability?.supportsTab == true) ||
                        !TerminalLaunchPlanner.isSafeAlias(host.alias)
                    )
                    Menu("其他方式") {
                        ForEach(capabilities) { capability in
                            ForEach(TerminalOpenMode.allCases) { mode in
                                Button("\(capability.profile.displayName) · \(mode.displayName)") {
                                    onLaunch(capability.profile, mode)
                                }
                                .disabled(!(mode == .window ? capability.supportsWindow : capability.supportsTab) ||
                                          !TerminalLaunchPlanner.isSafeAlias(host.alias))
                            }
                        }
                    }
                    .fixedSize()
                    Spacer(minLength: 0)
                    Button(action: onCopyCommand) {
                        Image(systemName: "doc.on.doc")
                    }
                    .help("复制 SSH 命令")
                    .accessibilityLabel("复制 SSH 命令")
                }
                if let selectedTerminal {
                    Text("默认：\(selectedTerminal.displayName) · \(defaultOpenMode.displayName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if selectedCapability == nil || !(defaultOpenMode == .window
                    ? selectedCapability?.supportsWindow == true
                    : selectedCapability?.supportsTab == true) {
                    Text(selectedCapability?.explanation ?? "终端不可用")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                GroupBox("连接参数") {
                    VStack(alignment: .leading, spacing: 10) {
                        DetailField(label: "HostName", value: host.hostName)
                        DetailField(label: "User", value: host.user)
                        DetailField(label: "Port", value: host.port)
                        DetailField(label: "IdentityFile", value: host.option("IdentityFile"))
                        DetailField(label: "IdentitiesOnly", value: host.option("IdentitiesOnly"))
                        DetailField(label: "ProxyJump", value: host.option("ProxyJump"))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }

                GroupBox("配置来源") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(host.sourceURL.path)
                            .textSelection(.enabled)
                        Text("第 \(host.sourceLine) 行")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }

                if let metadata {
                    GroupBox("主机信息") {
                        VStack(alignment: .leading, spacing: 8) {
                            if !metadata.groupName.isEmpty { DetailField(label: "分组", value: metadata.groupName) }
                            if !metadata.tags.isEmpty { DetailField(label: "标签", value: metadata.tags.joined(separator: "、")) }
                            if !metadata.note.isEmpty { DetailField(label: "备注", value: metadata.note) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(4)
                    }
                }

                GroupBox("分组") {
                    Text(host.configGroup ?? metadata?.groupName ?? "未分组")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(4)
                }

                if !host.readOnlyReasons.isEmpty {
                    GroupBox("只读原因") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(host.readOnlyReasons, id: \.self) { reason in
                                Label(reason, systemImage: "info.circle")
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(4)
                    }
                }

                if !host.explicitOptions.isEmpty {
                    GroupBox("原始字段") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(host.explicitOptions, id: \.line) { option in
                                DetailField(label: option.keyword, value: option.rawValue)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(4)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(host.alias)
    }
}

private struct DetailField: View {
    let label: String
    let value: String?

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
            GridRow {
                Text(label)
                    .foregroundStyle(.secondary)
                    .frame(width: 124, alignment: .trailing)
                Group {
                    if let value, !value.isEmpty {
                        Text(value).foregroundStyle(.primary)
                    } else {
                        Text("未显式设置").foregroundStyle(.secondary)
                    }
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct IssueDetailView: View {
    let issue: ConfigIssue

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("解析告警")
                .font(.title.bold())
            Text(issue.message)
            Text(issue.location)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
