import AppKit
import ConfigSSHCore
import SwiftUI

extension Notification.Name {
    static let configSSHConfigChanged = Notification.Name("ConfigSSH.configChanged")
}

struct SnapshotBrowserView: View {
    let writer: ConfigWriter
    let localFolder: URL
    let cloudFolder: URL?

    @Environment(\.dismiss) private var dismiss
    @State private var snapshots: [SnapshotRecord] = []
    @State private var issues: [String] = []
    @State private var selectedID: String?
    @State private var restoreRecord: SnapshotRecord?
    @State private var loadTask: Task<Void, Never>?
    @State private var isLoading = false
    @State private var isImportingCloud = false
    @State private var importError: String?

    private var selectedSnapshot: SnapshotRecord? { snapshots.first { $0.id == selectedID } }

    var body: some View {
        NavigationSplitView {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    Text("本机快照")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 5)
                    ForEach(snapshots.filter { !$0.isCloud }) { snapshot in
                        snapshotButton(snapshot)
                    }
                    Text("iCloud Drive 快照 · 只读")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 15)
                    ForEach(snapshots.filter(\.isCloud)) { snapshot in
                        snapshotButton(snapshot)
                    }
                    if !issues.isEmpty {
                        Text("扫描告警")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.top, 15)
                        ForEach(issues, id: \.self) { issue in
                            Label(issue, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
            .navigationTitle("配置快照")
            .navigationSplitViewColumnWidth(min: 220, ideal: 240)
            .toolbar {
                Button("刷新", systemImage: "arrow.clockwise") { reload() }
                Button("关闭") { dismiss() }
            }
        } detail: {
            if let snapshot = selectedSnapshot {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(timestamp(snapshot.manifest.createdAt, includingSeconds: true))
                            .font(.title.bold())
                        Text(snapshot.url.path)
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        if snapshot.manifest.includesKeys {
                            Label("此快照包含密钥文件。应用内恢复只处理配置文件，不会恢复私钥。",
                                  systemImage: "exclamationmark.shield.fill")
                                .foregroundStyle(.orange)
                        }
                        if snapshot.isCloud {
                            Label("云端快照保持只读。可先协调读取并校验，导入仅含配置文件的本机副本，再预览恢复。",
                                  systemImage: "icloud")
                                .foregroundStyle(.secondary)
                            Button(isImportingCloud ? "正在导入本机副本…" : "导入本机副本以恢复") {
                                importCloud(snapshot)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(isImportingCloud)
                        } else if snapshot.manifest.entries.contains(where: {
                            $0.kind == "ssh-config" && $0.sha256 == nil
                        }) {
                            Label("这份旧快照缺少配置文件校验值，无法安全地自动恢复；请在 Finder 中人工核对。",
                                  systemImage: "exclamationmark.shield")
                                .foregroundStyle(.orange)
                        } else {
                            Button("预览配置恢复") { restoreRecord = snapshot }
                                .buttonStyle(.borderedProminent)
                        }
                        Button("在 Finder 中查看快照") {
                            NSWorkspace.shared.activateFileViewerSelecting([snapshot.url])
                        }
                        if let importError {
                            Label(importError, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                        GroupBox("快照文件 · \(snapshot.manifest.entries.count)") {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(Array(snapshot.manifest.entries.enumerated()), id: \.offset) { _, entry in
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(entry.kind == "ssh-config" ? "配置 · \(entry.backupFile)" :
                                            entry.kind == "private-key" ? "私钥 · \(entry.backupFile)" :
                                            "公钥 · \(entry.backupFile)")
                                            .font(.callout.bold())
                                        Text(entry.sourcePath)
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.secondary)
                                            .textSelection(.enabled)
                                    }
                                    if entry.backupFile != snapshot.manifest.entries.last?.backupFile { Divider() }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                if isLoading {
                    ProgressView("读取配置快照…")
                } else {
                    ContentUnavailableView("没有可选择的配置快照", systemImage: "archivebox")
                }
            }
        }
        .frame(minWidth: 900, minHeight: 500)
        .task {
            try? await Task.sleep(for: .milliseconds(100))
            if !Task.isCancelled { reload() }
        }
        .onDisappear { loadTask?.cancel() }
        .onChange(of: selectedID) { _, _ in importError = nil }
        .sheet(item: $restoreRecord) { record in
            SnapshotRestorePreviewView(snapshot: record, writer: writer) {
                NotificationCenter.default.post(name: .configSSHConfigChanged, object: nil)
                reload()
            }
        }
    }

    private func row(_ snapshot: SnapshotRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(timestamp(snapshot.manifest.createdAt))
            Text("\(snapshot.manifest.entries.filter { $0.kind == "ssh-config" }.count) 个配置文件")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func snapshotButton(_ snapshot: SnapshotRecord) -> some View {
        Button { selectedID = snapshot.id } label: {
            row(snapshot)
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(selectedID == snapshot.id ? BrandPalette.selectionBlue.opacity(0.28) : .clear,
                            in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(snapshot.isCloud ? "iCloud" : "本机")快照 \(timestamp(snapshot.manifest.createdAt))")
        .accessibilityAddTraits(selectedID == snapshot.id ? .isSelected : [])
    }

    private func timestamp(_ date: Date, includingSeconds: Bool = false) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let base = String(format: "%04d-%02d-%02d %02d:%02d", parts.year ?? 0, parts.month ?? 0,
                          parts.day ?? 0, parts.hour ?? 0, parts.minute ?? 0)
        return includingSeconds ? base + String(format: ":%02d", parts.second ?? 0) : base
    }

    private func reload() {
        loadTask?.cancel()
        isLoading = true
        let local = localFolder
        let cloud = cloudFolder
        loadTask = Task {
            let output = await Task.detached(priority: .utility) { () -> ([SnapshotRecord], [String]) in
                var collected: [SnapshotRecord] = []
                var warnings: [String] = []
                for (folder, isCloud) in [(Optional(local), false), (cloud, true)] {
                    guard let folder else { continue }
                    do {
                        let result = try BackupSnapshotService().list(in: folder, isCloud: isCloud)
                        collected += result.records
                        warnings += result.issues.map { "\(isCloud ? "iCloud" : "本机")：\($0)" }
                    } catch {
                        warnings.append("\(isCloud ? "iCloud" : "本机")：\(error.localizedDescription)")
                    }
                }
                return (collected.sorted { $0.manifest.createdAt > $1.manifest.createdAt }, warnings)
            }.value
            if Task.isCancelled { return }
            snapshots = output.0
            issues = output.1
            let fallbackID = snapshots.first?.id
            if !snapshots.contains(where: { $0.id == selectedID }) {
                Task { @MainActor in
                    await Task.yield()
                    if !snapshots.contains(where: { $0.id == selectedID }) { selectedID = fallbackID }
                }
            }
            isLoading = false
        }
    }

    private func importCloud(_ snapshot: SnapshotRecord) {
        guard !isImportingCloud else { return }
        importError = nil
        isImportingCloud = true
        let folder = localFolder
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> (URL?, String?) in
                do {
                    let result = try BackupSnapshotService().importCloudSnapshot(snapshot, to: folder)
                    return (result.url, nil)
                } catch {
                    return (nil, error.localizedDescription)
                }
            }.value
            isImportingCloud = false
            if let url = outcome.0 {
                selectedID = url.path
                reload()
            } else {
                importError = outcome.1
            }
        }
    }
}

struct SnapshotRestorePreviewView: View {
    let snapshot: SnapshotRecord
    let writer: ConfigWriter
    let onCommit: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var plan: ConfigChangePlan?
    @State private var errorMessage: String?
    @State private var isCommitting = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text("恢复快照中的配置文件")
                    .font(.title3.bold())
                if let plan {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(plan.warnings, id: \.self) { warning in
                                Label(warning, systemImage: "info.circle")
                                    .foregroundStyle(.orange)
                            }
                            ForEach(Array(plan.changes.enumerated()), id: \.offset) { _, change in
                                GroupBox(change.url.path) {
                                    Text(change.diff)
                                        .font(.system(.caption, design: .monospaced))
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(8)
                                }
                            }
                        }
                    }
                } else if errorMessage == nil {
                    ProgressView("检查快照与磁盘文件…")
                }
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
                Spacer(minLength: 0)
                Divider()
                HStack {
                    Button("取消") { dismiss() }
                        .disabled(isCommitting)
                    Spacer()
                    Button(isCommitting ? "正在恢复…" : "确认恢复配置") {
                        guard let plan else { return }
                        isCommitting = true
                        let writer = writer
                        Task {
                            let failure = await Task.detached(priority: .userInitiated) { () -> String? in
                                do { _ = try writer.commit(plan); return nil }
                                catch { return error.localizedDescription }
                            }.value
                            isCommitting = false
                            if let failure {
                                errorMessage = failure
                            } else {
                                onCommit()
                                dismiss()
                            }
                        }
                    }
                    .disabled(plan == nil || isCommitting)
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(20)
            .frame(minWidth: 660, minHeight: 450)
            .navigationTitle("预览快照恢复")
        }
        .task {
            do {
                let store = try MetadataStore()
                if try !GroupDeletionService(writer: writer, metadataStore: store).pendingOperations().isEmpty {
                    throw ConfigEditError.conflict("存在未完成的分组操作，请先在主窗口继续处理")
                }
            } catch {
                errorMessage = error.localizedDescription
                return
            }
            let writer = writer
            let snapshot = snapshot
            let prepared = await Task.detached(priority: .userInitiated) { () -> (ConfigChangePlan?, String?) in
                do { return (try writer.planSnapshotRestore(snapshot), nil) }
                catch { return (nil, error.localizedDescription) }
            }.value
            if Task.isCancelled { return }
            plan = prepared.0
            errorMessage = prepared.1
        }
    }
}
