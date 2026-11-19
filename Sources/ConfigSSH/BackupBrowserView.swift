import ConfigSSHCore
import SwiftUI

/// Lists local snapshots (encrypted `.cssh` files and older plaintext folders), unlocks an
/// encrypted one with the saved backup passphrase, and restores it after a diff preview.
struct BackupBrowserView: View {
    let writer: ConfigWriter
    let folder: URL
    let cloudFolder: URL?

    @Environment(\.dismiss) private var dismiss
    @State private var items: [SnapshotItem] = []
    @State private var issues: [String] = []
    @State private var selectedID: String?
    @State private var isLoading = false
    @State private var archive: BackupArchive?
    @State private var isUnlocking = false
    @State private var unlockError: String?
    @State private var manualPassphrase = ""
    @State private var restorePlan: ConfigChangePlan?
    @State private var legacyRestore: SnapshotRecord?
    @State private var showsLegacyBrowser = false
    @State private var confirmsDelete = false
    @State private var errorMessage: String?

    private var selected: SnapshotItem? { items.first { $0.id == selectedID } }

    var body: some View {
        NavigationSplitView {
            list
                .navigationTitle("备份历史")
                .navigationSplitViewColumnWidth(min: 250, ideal: 270)
        } detail: {
            detail
        }
        .frame(minWidth: 900, minHeight: 520)
        .task { reload() }
        .onReceive(NotificationCenter.default.publisher(for: .backupSnapshotsChanged)) { _ in reload() }
        .onChange(of: selectedID) { _, _ in
            archive = nil; unlockError = nil; manualPassphrase = ""; errorMessage = nil
            unlockWithSavedPassphrase()
        }
        .sheet(item: Binding(get: { restorePlan.map { PlanBox(plan: $0) } }, set: { if $0 == nil { restorePlan = nil } })) { box in
            PlanPreviewSheet(title: "预览快照恢复", heading: "恢复快照中的配置文件", confirmTitle: "确认恢复配置",
                             plan: box.plan, writer: writer) {
                NotificationCenter.default.post(name: .configSSHConfigChanged, object: nil)
                reload()
            }
        }
        .sheet(item: $legacyRestore) { record in
            SnapshotRestorePreviewView(snapshot: record, writer: writer) {
                NotificationCenter.default.post(name: .configSSHConfigChanged, object: nil)
                reload()
            }
        }
        .sheet(isPresented: $showsLegacyBrowser) {
            SnapshotBrowserView(writer: writer, localFolder: folder, cloudFolder: cloudFolder)
        }
        .confirmationDialog("删除这个快照？", isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) { deleteSelected() }
        } message: {
            Text("只删除这一份快照文件，当前的 SSH 配置不受影响。此操作不能撤销。")
        }
    }

    // MARK: List

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                let encrypted = items.filter(\.isEncrypted)
                let legacy = items.filter { !$0.isEncrypted }
                header("加密快照 · \(encrypted.count)")
                if encrypted.isEmpty { Text(isLoading ? "读取中…" : "还没有加密快照").font(.callout).foregroundStyle(.secondary).padding(.horizontal, 9) }
                ForEach(encrypted) { row($0) }
                if !legacy.isEmpty {
                    header("旧版快照（未加密）· \(legacy.count)").padding(.top, 14)
                    ForEach(legacy) { row($0) }
                }
                if !issues.isEmpty {
                    header("读取告警").padding(.top, 14)
                    ForEach(issues, id: \.self) { issue in
                        Label(issue, systemImage: "exclamationmark.triangle").font(.caption).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 9)
                    }
                }
                if cloudFolder != nil {
                    Button("旧版 iCloud 明文快照…") { showsLegacyBrowser = true }
                        .buttonStyle(.link).font(.caption).padding(.horizontal, 9).padding(.top, 14)
                }
            }
            .padding(12)
        }
    }

    private func header(_ text: String) -> some View {
        Text(text).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 9).padding(.top, 4)
    }

    private func row(_ item: SnapshotItem) -> some View {
        Button { selectedID = item.id } label: {
            HStack(spacing: 10) {
                Image(systemName: item.isEncrypted ? "lock.fill" : "lock.open")
                    .foregroundStyle(item.isEncrypted ? BrandPalette.accent : Color.orange)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ChineseDate.short(item.createdAt))
                    Text(item.isAutomatic ? "自动" : "手动").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selectedID == item.id ? BrandPalette.accent.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(item.isEncrypted ? "加密" : "未加密")快照 \(ChineseDate.short(item.createdAt))")
        .accessibilityAddTraits(selectedID == item.id ? .isSelected : [])
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let item = selected {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(ChineseDate.full(item.createdAt)).font(.title2.bold())
                    Text(item.url.path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    switch item.storage {
                    case .encrypted(let record): encryptedDetail(item, record)
                    case .legacy(let record): legacyDetail(record)
                    }
                    if let errorMessage { Label(errorMessage, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                    HStack {
                        Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                        if item.isEncrypted { Button("删除快照…", role: .destructive) { confirmsDelete = true } }
                    }
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView(isLoading ? "读取备份历史…" : "选择一份快照", systemImage: "clock.arrow.circlepath",
                                   description: Text("快照保存在本机，用备份口令加密；恢复前会先预览差异。"))
        }
    }

    @ViewBuilder
    private func encryptedDetail(_ item: SnapshotItem, _ record: EncryptedSnapshotRecord) -> some View {
        Label("已加密（AES-GCM），只含配置文件，不含任何密钥。", systemImage: "lock.shield").foregroundStyle(.secondary)
        if let archive {
            GroupBox("包含 \(archive.entries.count) 个配置文件 · 来自 \(archive.deviceName.isEmpty ? "未知设备" : archive.deviceName)") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(archive.entries, id: \.path) { entry in
                        HStack {
                            Image(systemName: entry.isExternal ? "arrow.up.right.square" : "doc.text").foregroundStyle(.secondary)
                            Text(entry.path).font(.callout.monospaced()).textSelection(.enabled)
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: Int64(entry.content.count), countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                        }
                        if entry.isExternal {
                            Text("位于 ~/.ssh 之外，仅作记录，不会恢复").font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(6)
            }
            Button("恢复这份快照…") { prepareRestore(archive) }.buttonStyle(.borderedProminent)
        } else if isUnlocking {
            ProgressView("正在解锁…")
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if let unlockError { Label(unlockError, systemImage: "lock.trianglebadge.exclamationmark").foregroundStyle(.orange) }
                Text("输入加密这份快照时使用的备份口令：").font(.callout)
                HStack {
                    SecureField("备份口令", text: $manualPassphrase).frame(maxWidth: 280)
                    Button("解锁") { unlock(with: manualPassphrase) }.disabled(manualPassphrase.isEmpty)
                }
            }
        }
    }

    @ViewBuilder
    private func legacyDetail(_ record: SnapshotRecord) -> some View {
        Label("这是旧版本创建的快照，文件未加密。可以照常预览并恢复，建议确认不再需要后删除。", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        GroupBox("\(record.manifest.entries.filter { $0.kind == "ssh-config" }.count) 个配置文件") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(record.manifest.entries.filter { $0.kind == "ssh-config" }, id: \.backupFile) { entry in
                    Text(entry.sourcePath).font(.callout.monospaced()).textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(6)
        }
        Button("恢复这份快照…") { legacyRestore = record }.buttonStyle(.borderedProminent)
    }

    // MARK: Actions

    private func reload() {
        isLoading = true
        let folder = folder
        Task {
            let result = await Task.detached(priority: .utility) { () -> ([SnapshotItem], [String]) in
                guard let listing = try? SnapshotCatalog.list(folder: folder) else { return ([], ["无法读取快照目录"]) }
                return (listing.items, listing.issues)
            }.value
            items = result.0
            issues = result.1
            isLoading = false
            if selectedID == nil || !items.contains(where: { $0.id == selectedID }) { selectedID = items.first?.id }
        }
    }

    private func unlockWithSavedPassphrase() {
        guard let item = selected, item.isEncrypted, let saved = BackupPassphraseStore.read() else { return }
        unlock(with: saved, silent: true)
    }

    private func unlock(with passphrase: String, silent: Bool = false) {
        guard let item = selected, case .encrypted(let record) = item.storage else { return }
        isUnlocking = true
        unlockError = nil
        let folder = folder
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<BackupArchive, Error> in
                Result { try EncryptedSnapshotService(folder: folder).open(record, passphrase: passphrase) }
            }.value
            isUnlocking = false
            guard selectedID == item.id else { return }
            switch result {
            case .success(let opened): archive = opened
            case .failure(let error):
                unlockError = silent ? "已保存的备份口令打不开这份快照（可能是更换口令前创建的）。" : error.localizedDescription
            }
        }
    }

    private func prepareRestore(_ archive: BackupArchive) {
        errorMessage = nil
        let writer = writer
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<ConfigChangePlan, Error> in
                Result { try writer.planArchiveRestore(archive, title: "从快照恢复 SSH 配置") }
            }.value
            switch result {
            case .success(let plan): restorePlan = plan
            case .failure(let error): errorMessage = error.localizedDescription
            }
        }
    }

    private func deleteSelected() {
        guard let item = selected, item.isEncrypted else { return }
        do {
            try FileManager.default.removeItem(at: item.url)
            selectedID = nil
            reload()
        } catch { errorMessage = "无法删除：\(error.localizedDescription)" }
    }
}

private struct PlanBox: Identifiable {
    let id = UUID()
    let plan: ConfigChangePlan
}

extension SnapshotRecord: @retroactive Identifiable {}
