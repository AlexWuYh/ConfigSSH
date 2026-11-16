import AppKit
import ConfigSSHCore
import SwiftUI

struct QuickLaunchView: View {
    let onEscape: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    init(onEscape: (() -> Void)? = nil) {
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
    @State private var query = ""
    @State private var selectedHostID: String?
    @State private var statusMessage: String?
    @FocusState private var searchFocused: Bool
    @AppStorage("defaultTerminal") private var defaultTerminalRaw = ""
    @AppStorage("defaultOpenMode") private var defaultOpenModeRaw = TerminalOpenMode.window.rawValue

    private var effectiveSelectedID: String? {
        QuickLaunchSelection.resolvedID(selectedHostID, visibleIDs: results.map(\.id))
    }

    private var selectedHost: HostRecord? {
        results.first { $0.id == effectiveSelectedID }
    }

    private var results: [HostRecord] {
        let filtered = scan.hosts.filter { host in
            let details = metadata[host.metadataKey]
            let fields = [host.alias, host.hostName ?? "", host.user ?? "",
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索主机、地址或标签", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit { launchSelected() }
                    .onKeyPress(.downArrow) {
                        selectedHostID = QuickLaunchSelection.movedID(
                            selectedHostID, by: 1, visibleIDs: results.map(\.id)
                        )
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        selectedHostID = QuickLaunchSelection.movedID(
                            selectedHostID, by: -1, visibleIDs: results.map(\.id)
                        )
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        close()
                        return .handled
                    }
                    .accessibilityIdentifier("quickLaunchSearch")
            }
            .padding(12)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))

            if isLoading {
                ProgressView("搜索本地 SSH 配置…")
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else if results.isEmpty {
                ContentUnavailableView(query.isEmpty ? "没有主机" : "没有匹配的主机", systemImage: "server.rack")
                    .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(results) { host in
                            Button {
                                selectedHostID = host.id
                                launch(host, terminal: preferredTerminal(for: host), mode: preferredOpenMode(for: host))
                            } label: {
                                HStack {
                                    Image(systemName: "server.rack")
                                        .foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(displayName(for: host))
                                            .fontWeight(.medium)
                                        Text(host.alias == host.hostName ? host.alias : (host.hostName ?? host.alias))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text(preferredTerminal(for: host)?.displayName ?? "未配置")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(9)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(host.id == effectiveSelectedID ? BrandPalette.selectionBlue.opacity(0.24) : .clear,
                                            in: RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("连接 \(host.alias)")
                            .accessibilityValue("\(host.hostName ?? host.alias)，\(preferredTerminal(for: host)?.displayName ?? "未配置终端")")
                            .accessibilityHint("按下以在终端中启动连接")
                            .accessibilityAddTraits(host.id == effectiveSelectedID ? .isSelected : [])
                            .accessibilityIdentifier("quickLaunchHost-\(host.alias)")
                        }
                    }
                }
                .frame(maxHeight: 300)
            }
            if let host = selectedHost {
                HStack {
                    Text("↵ 连接 · ⌘K 快速打开")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Menu("选择终端") {
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
                    }
                    if !TerminalLaunchPlanner.isSafeAlias(host.alias) {
                        Button("复制 SSH 命令") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(
                                TerminalLaunchPlanner.copyableCommand(alias: host.alias), forType: .string
                            )
                            statusMessage = "SSH 命令已复制。"
                        }
                    }
                }
            }
            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 520)
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
                if focused { close() }
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }
}
