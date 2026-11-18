import AppKit
import ConfigSSHCore
import SwiftUI

struct QuickLaunchView: View {
    enum Style {
        /// Menu bar dropdown and the main window's ⌘K sheet.
        case embedded
        /// Global-shortcut panel: floating, Spotlight-like, closes after handing off to a terminal.
        case floatingPanel
    }

    let style: Style
    let onEscape: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    init(style: Style = .embedded, onEscape: (() -> Void)? = nil) {
        self.style = style
        self.onEscape = onEscape
    }

    @State private var scan = ConfigScan(rootURL: ConfigSSHPaths.rootURL, availability: .missing,
                                         hosts: [], globalOptions: [], rules: [], issues: [], sources: [])
    @State private var scanTask: Task<Void, Never>?
    @State private var isLoading = true
    @State private var metadataStore = try? MetadataStore()
    @State private var metadata: [String: HostMetadata] = [:]
    @State private var recent: [LaunchEvent] = []
    @State private var launcher = TerminalLaunchService()
    @State private var capabilities: [TerminalCapability] = []
    @State private var terminalProbeTask: Task<Void, Never>?
    @State private var query = Self.previewQuery
    @State private var selectedHostID: String?
    @State private var statusMessage: String?
    @FocusState private var searchFocused: Bool
    @AppStorage("defaultTerminal") private var defaultTerminalRaw = ""
    @AppStorage("defaultOpenMode") private var defaultOpenModeRaw = TerminalOpenMode.window.rawValue

    private static var previewQuery: String {
        #if DEBUG
        if ConfigSSHPaths.isPreviewMode { return ProcessInfo.processInfo.environment["CONFIGSSH_PREVIEW_QUERY"] ?? "" }
        #endif
        return ""
    }

    private var effectiveSelectedID: String? {
        QuickLaunchSelection.resolvedID(selectedHostID, visibleIDs: results.map(\.id))
    }

    private var selectedHost: HostRecord? {
        results.first { $0.id == effectiveSelectedID }
    }

    private var results: [HostRecord] {
        let filtered = scan.hosts.filter { host in
            let details = metadata[host.metadataKey]
            let fields = [host.alias, host.hostName ?? "", host.user ?? "", host.configGroup ?? "",
                          details?.displayName ?? "", details?.groupName ?? ""] + (details?.tags ?? [])
            let terms = query.split(whereSeparator: \.isWhitespace)
            return terms.allSatisfy { term in
                fields.contains { $0.range(of: String(term), options: [.caseInsensitive, .diacriticInsensitive]) != nil }
            }
        }
        guard query.isEmpty else { return Array(filtered.prefix(30)) }
        return Array(filtered.sorted { lhs, rhs in
            let left = recent.first { $0.hostKey == lhs.metadataKey }?.requestedAt ?? .distantPast
            let right = recent.first { $0.hostKey == rhs.metadataKey }?.requestedAt ?? .distantPast
            return left > right
        }.prefix(20))
    }

    private var isFloating: Bool { style == .floatingPanel }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchField
            Divider().opacity(0.5)
            resultsSection
            if let host = selectedHost { footer(for: host) }
            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
            }
        }
        .frame(width: isFloating ? 560 : 520)
        .frame(maxHeight: isFloating ? .infinity : nil, alignment: .top)
        .background {
            if isFloating {
                ZStack {
                    Rectangle().fill(.regularMaterial)
                    LinearGradient(colors: [BrandPalette.accent.opacity(0.10), .clear],
                                   startPoint: .top, endPoint: .center)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: isFloating ? 18 : 0, style: .continuous))
        .overlay {
            if isFloating {
                RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.primary.opacity(0.10))
            }
        }
        .tint(BrandPalette.accent(for: colorScheme))
        .onExitCommand(perform: close)
        .onAppear {
            metadata = (try? metadataStore?.allMetadata()) ?? [:]
            recent = (try? metadataStore?.recentEvents()) ?? []
            reloadScan()
            refreshTerminals()
            Task { @MainActor in
                await Task.yield()
                searchFocused = true
            }
        }
        .onDisappear {
            scanTask?.cancel()
            terminalProbeTask?.cancel()
        }
        .onChange(of: query) { _, _ in selectedHostID = nil }
        .onReceive(NotificationCenter.default.publisher(for: .configSSHConfigChanged)) { _ in reloadScan() }
        .onReceive(NotificationCenter.default.publisher(for: .configSSHTerminalProfilesChanged)) { _ in
            refreshTerminals()
        }
        .task(id: statusMessage) {
            guard let shown = statusMessage else { return }
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled && statusMessage == shown { statusMessage = nil }
        }
    }

    private var searchField: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: isFloating ? 20 : 15, weight: .semibold))
                .foregroundStyle(BrandPalette.accent)
            TextField("搜索主机、地址、分组或标签", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: isFloating ? 20 : 14))
                .focused($searchFocused)
                .onSubmit { launchSelected() }
                .onKeyPress(.downArrow) {
                    selectedHostID = QuickLaunchSelection.movedID(selectedHostID, by: 1, visibleIDs: results.map(\.id))
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    selectedHostID = QuickLaunchSelection.movedID(selectedHostID, by: -1, visibleIDs: results.map(\.id))
                    return .handled
                }
                .onKeyPress(.escape) {
                    close()
                    return .handled
                }
                .onKeyPress(keys: [.return], phases: .down) { press in
                    // ⌘↵ opens the selected host in a new tab; plain ↵ is handled by onSubmit.
                    guard press.modifiers.contains(.command), let host = selectedHost else { return .ignored }
                    launch(host, terminal: preferredTerminal(for: host), mode: .tab)
                    return .handled
                }
                .accessibilityIdentifier("quickLaunchSearch")
            if isFloating, let shortcut = GlobalShortcutSettings.stored {
                Text(shortcut.display)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.quaternary))
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, isFloating ? 16 : 12)
    }

    @ViewBuilder
    private var resultsSection: some View {
        if isLoading {
            ProgressView("搜索本地 SSH 配置…")
                .frame(maxWidth: .infinity, minHeight: 120)
        } else if results.isEmpty {
            ContentUnavailableView(query.isEmpty ? "没有主机" : "没有匹配的主机", systemImage: "server.rack")
                .frame(maxWidth: .infinity)
        } else {
            Text(query.isEmpty ? "最近连接" : "匹配 \(results.count) 台主机")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 18)
                .padding(.top, 10)
                .padding(.bottom, 4)
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(results) { host in
                        Button {
                            selectedHostID = host.id
                            launch(host, terminal: preferredTerminal(for: host), mode: preferredOpenMode(for: host))
                        } label: {
                            QuickLaunchRow(
                                name: displayName(for: host),
                                address: [host.user.map { "\($0)@" }, host.hostName ?? host.alias].compactMap { $0 }.joined(),
                                group: host.configGroup ?? metadata[host.metadataKey]?.groupName,
                                terminalName: preferredTerminal(for: host)?.displayName ?? "未配置",
                                query: query,
                                isSelected: host.id == effectiveSelectedID
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("连接 \(host.alias)")
                        .accessibilityValue("\(host.hostName ?? host.alias)，\(preferredTerminal(for: host)?.displayName ?? "未配置终端")")
                        .accessibilityHint("按下以在终端中启动连接")
                        .accessibilityAddTraits(host.id == effectiveSelectedID ? .isSelected : [])
                        .accessibilityIdentifier("quickLaunchHost-\(host.alias)")
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            .frame(minHeight: isFloating ? 0 : min(CGFloat(results.count), 5) * 58,
                   maxHeight: isFloating ? .infinity : 300)
        }
    }

    private func footer(for host: HostRecord) -> some View {
        HStack(spacing: 14) {
            keyHint("↑↓", "选择")
            keyHint("↵", "连接")
            keyHint("⌘↵", "新标签页")
            keyHint("esc", "关闭")
            Spacer(minLength: 8)
            Menu {
                ForEach(capabilities) { capability in
                    Button("\(capability.profile.displayName) · 新窗口") {
                        launch(host, terminal: capability.profile, mode: .window)
                    }
                    .disabled(!capability.supportsWindow)
                    Button("\(capability.profile.displayName) · 新标签页") {
                        launch(host, terminal: capability.profile, mode: .tab)
                    }
                    .disabled(!capability.supportsTab)
                }
                if !TerminalLaunchPlanner.isSafeAlias(host.alias) {
                    Divider()
                    Button("复制 SSH 命令") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(TerminalLaunchPlanner.copyableCommand(alias: host.alias), forType: .string)
                        statusMessage = "SSH 命令已复制。"
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text("终端").foregroundStyle(.secondary)
                    Text(preferredTerminal(for: host)?.displayName ?? "选择").foregroundStyle(BrandPalette.accent).fontWeight(.semibold)
                }
                .font(.system(size: 11.5))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .background(.primary.opacity(0.04))
        .overlay(alignment: .top) { Divider().opacity(0.5) }
    }

    private func keyHint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.quaternary))
            Text(label)
        }
        .font(.system(size: 11.5))
        .foregroundStyle(.secondary)
    }

    private func reloadScan() {
        scanTask?.cancel()
        isLoading = true
        let root = ConfigSSHPaths.rootURL
        scanTask = Task {
            let refreshed = await Task.detached(priority: .userInitiated) {
                ConfigReader(rootURL: root).scan()
            }.value
            if Task.isCancelled { return }
            scan = refreshed
            selectedHostID = QuickLaunchSelection.resolvedID(selectedHostID, visibleIDs: results.map(\.id))
            isLoading = false
        }
    }

    private func refreshTerminals() {
        terminalProbeTask?.cancel()
        capabilities = launcher.capabilities()
        terminalProbeTask = Task {
            let loaded = await launcher.refreshCapabilities()
            if Task.isCancelled { return }
            capabilities = loaded
        }
    }

    private func close() {
        if let onEscape { onEscape() } else { dismiss() }
    }

    private func preferredTerminal(for host: HostRecord) -> TerminalProfile? {
        TerminalSelection.resolved(metadata[host.metadataKey]?.preferredTerminal ?? defaultTerminalRaw,
                                   from: capabilities)
    }

    private func preferredOpenMode(for host: HostRecord) -> TerminalOpenMode {
        TerminalOpenMode.resolved(metadata[host.metadataKey]?.preferredOpenMode ?? defaultOpenModeRaw)
    }

    private func displayName(for host: HostRecord) -> String {
        let name = metadata[host.metadataKey]?.displayName ?? ""
        return name.isEmpty ? host.alias : name
    }

    private func launchSelected() {
        guard let host = selectedHost else { return }
        launch(host, terminal: preferredTerminal(for: host), mode: preferredOpenMode(for: host))
    }

    private func launch(_ host: HostRecord, terminal: TerminalProfile?, mode: TerminalOpenMode) {
        Task { @MainActor in
            do {
                guard let terminal else { throw TerminalLaunchError.unavailable("未找到已安装并配置的终端") }
                let focused = try await launcher.launch(host: host, with: terminal, mode: mode)
                if let metadataStore {
                    do {
                        try metadataStore.recordLaunch(hostKey: host.metadataKey, terminal: terminal.id)
                        recent = (try? metadataStore.recentEvents()) ?? recent
                        statusMessage = focused
                            ? "已切换到 \(terminal.displayName)；连接结果请在终端查看。"
                            : "已交给 \(terminal.displayName)，但未能自动切换窗口；请手动查看。"
                    } catch {
                        statusMessage = "已交给 \(terminal.displayName)，但无法记录本地历史：\(error.localizedDescription)"
                    }
                } else {
                    statusMessage = "已交给 \(terminal.displayName)，但本地历史不可用。"
                }
                if focused || style == .floatingPanel { close() }
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }
}

/// One host in the quick-connect list: avatar initial, name and address with the matched text
/// highlighted, group chip, and the terminal (or "↵ 连接" on the selected row).
private struct QuickLaunchRow: View {
    let name: String
    let address: String
    let group: String?
    let terminalName: String
    let query: String
    let isSelected: Bool

    private func highlighted(_ text: String) -> Text {
        var attributed = AttributedString(text)
        for range in SearchHighlight.ranges(of: query, in: text) {
            guard let lower = AttributedString.Index(range.lowerBound, within: attributed),
                  let upper = AttributedString.Index(range.upperBound, within: attributed) else { continue }
            attributed[lower..<upper].foregroundColor = isSelected ? BrandPalette.onAccent : BrandPalette.accent
            attributed[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
            if isSelected { attributed[lower..<upper].underlineStyle = .single }
        }
        return Text(attributed)
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(SearchHighlight.initial(of: name))
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .frame(width: 34, height: 34)
                .foregroundStyle(isSelected ? BrandPalette.onAccent : BrandPalette.accent)
                .background(isSelected ? BrandPalette.onAccent.opacity(0.22) : BrandPalette.accent.opacity(0.14),
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                highlighted(name).font(.system(size: 14, weight: .semibold))
                highlighted(address)
                    .font(.system(size: 11.5, design: .monospaced))
                    .opacity(isSelected ? 0.85 : 0.6)
            }
            Spacer(minLength: 8)
            if let group, !group.isEmpty {
                highlighted(group)
                    .font(.system(size: 11))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(isSelected ? BrandPalette.onAccent.opacity(0.22) : Color.primary.opacity(0.07), in: Capsule())
            }
            Text(isSelected ? "↵ 连接" : terminalName)
                .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
                .opacity(isSelected ? 1 : 0.6)
        }
        .foregroundStyle(isSelected ? BrandPalette.onAccent : Color.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? BrandPalette.accent : .clear, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .contentShape(Rectangle())
    }
}
