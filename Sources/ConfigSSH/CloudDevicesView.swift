import ConfigSSHCore
import SwiftUI

/// iCloud devices, rewritten around the one backup passphrase: it asks for no passphrase of its
/// own. The list shows every Mac that has uploaded, and a selected device can be pulled onto this
/// Mac after a diff preview. Uploading is automatic (or "立即备份"); the only upload action kept
/// here is replacing this Mac's own cloud file when the current passphrase cannot open it.
struct CloudDevicesView: View {
    let writer: ConfigWriter
    let folder: URL
    let cloudRoot: URL

    @Environment(\.dismiss) private var dismiss
    @State private var deviceID: UUID?
    @State private var slots: [CloudConfigSlot] = []
    @State private var summaries: [UUID: CloudConfigDeviceSummary] = [:]
    @State private var selectedID: UUID?
    @State private var isLoading = false
    @State private var isBusy = false
    @State private var typedPassphrase = ""
    @State private var pendingPull: CloudPullPlan?
    @State private var showsReplace = false
    @State private var acceptsReplacement = false
    @State private var acceptsIncomplete = false
    @State private var message: String?
    @State private var isError = false
    @State private var loadTask: Task<Void, Never>?

    private var service: CloudConfigSyncService { CloudConfigSyncService(folder: folder, cloudRoot: cloudRoot) }
    private var passphrase: String? { BackupPassphraseStore.read() ?? (typedPassphrase.isEmpty ? nil : typedPassphrase) }
    private var selectedSlot: CloudConfigSlot? { slots.first { $0.id == selectedID } }
    private var ownSlotUnreadable: Bool {
        guard let deviceID, let summary = summaries[deviceID] else { return false }
        return summary.error != nil
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        header
                        if passphrase == nil { passphraseNeeded }
                        devices
                        if let selectedSlot, passphrase != nil { actions(for: selectedSlot) }
                        if ownSlotUnreadable { replacement }
                        if let message {
                            Label(message, systemImage: isError ? "exclamationmark.triangle" : "checkmark.circle")
                                .foregroundStyle(isError ? .orange : .secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(22)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                HStack {
                    Button("刷新", systemImage: "arrow.clockwise") { reload() }.disabled(isLoading || isBusy)
                    Spacer()
                    Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
                }
                .padding(14)
            }
            .frame(minWidth: 640, minHeight: 520)
            .navigationTitle("iCloud 云端设备")
        }
        .onAppear {
            deviceID = try? CloudDeviceIdentity.currentID()
            reload()
        }
        .onDisappear { loadTask?.cancel(); typedPassphrase = ""; pendingPull = nil }
        .sheet(item: Binding(get: { pendingPull.map { PullBox(plan: $0) } }, set: { if $0 == nil { pendingPull = nil } })) { box in
            PlanPreviewSheet(title: "预览拉取", heading: "从 \(box.plan.archive.deviceName) 拉取配置", confirmTitle: "确认拉取并覆盖同路径配置",
                             plan: box.plan.changes, writer: writer) {
                NotificationCenter.default.post(name: .configSSHConfigChanged, object: nil)
                message = "已拉取。云端文件保持不变。"; isError = false
            }
        }
        .tint(BrandPalette.accent(for: .light))
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("每台 Mac 在 iCloud 里有一个自己的加密文件，彼此不会覆盖。选择一台设备，可以把它的配置拉取到这台 Mac。")
                .foregroundStyle(.secondary)
            Label(folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"), systemImage: "icloud")
                .font(.caption.monospaced()).textSelection(.enabled).foregroundStyle(.secondary)
            Text("同步用的是“设置 › 备份”里的备份口令，这里不需要再设置口令。上传由自动备份或“立即备份”完成。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var passphraseNeeded: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("当前没有可用的备份口令，无法识别设备名称或拉取。", systemImage: "lock.slash").foregroundStyle(.orange)
            Text("请先到“设置 › 备份”设置口令（所有 Mac 要用同一个）。如果你选了“仅本次运行”，也可以在这里临时输入一次：")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                SecureField("备份口令", text: $typedPassphrase).frame(maxWidth: 280).onSubmit { reload() }
                Button("使用") { reload() }.disabled(typedPassphrase.isEmpty)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
    }

    private var devices: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("设备 · \(slots.count)").font(.headline)
            if slots.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label(isLoading ? "正在读取…" : "还没有设备上传过配置", systemImage: "icloud.slash").foregroundStyle(.secondary)
                    if !isLoading {
                        Text("在“设置 › 备份”里打开“同步到 iCloud”并点“立即备份”，这台 Mac 就会出现在这里；其他 Mac 的文件可能还在下载，稍后点“刷新”。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
            } else {
                ForEach(slots) { slot in deviceRow(slot) }
            }
        }
    }

    private func deviceRow(_ slot: CloudConfigSlot) -> some View {
        let summary = summaries[slot.id]
        let isThisMac = slot.deviceID == deviceID
        return Button { selectedID = slot.id; pendingPull = nil } label: {
            HStack(spacing: 12) {
                Image(systemName: isThisMac ? "laptopcomputer" : "desktopcomputer")
                    .font(.title3).foregroundStyle(BrandPalette.accent).frame(width: 30)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(summary?.deviceName ?? (isThisMac ? "这台 Mac" : "其他 Mac")).fontWeight(.semibold)
                        if isThisMac { Text("这台").font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 1)
                            .background(BrandPalette.accent.opacity(0.15), in: Capsule()).foregroundStyle(BrandPalette.accent) }
                    }
                    if let summary, summary.error == nil {
                        Text([summary.updatedAt.map { "上次上传 " + ChineseDate.short($0) }, summary.fileCount.map { "\($0) 个文件" }]
                            .compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                    } else if summary?.error != nil {
                        Label("口令不对或文件已损坏，无法打开", systemImage: "lock.trianglebadge.exclamationmark").font(.caption).foregroundStyle(.orange)
                    } else if passphrase == nil {
                        Text("需要备份口令才能识别").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("正在识别…").font(.caption).foregroundStyle(.secondary)
                    }
                    Text(slot.deviceID.uuidString).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                }
                Spacer()
                if selectedID == slot.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(BrandPalette.accent) }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selectedID == slot.id ? BrandPalette.accent.opacity(0.14) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selectedID == slot.id ? BrandPalette.accent.opacity(0.5) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(isThisMac ? "这台 Mac" : "其他 Mac")的云端配置")
        .accessibilityAddTraits(selectedID == slot.id ? .isSelected : [])
    }

    @ViewBuilder
    private func actions(for slot: CloudConfigSlot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { preparePull(slot) } label: { Label("预览拉取到这台 Mac…", systemImage: "icloud.and.arrow.down") }
                .buttonStyle(.borderedProminent)
                .disabled(isBusy || summaries[slot.id]?.error != nil)
            Text("先解密并逐个文件显示差异，确认后才覆盖这台 Mac 上同路径的配置。其他文件和私钥保持不变，覆盖前会先备份。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var replacement: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("这台 Mac 在 iCloud 里的旧文件打不开", systemImage: "exclamationmark.octagon").foregroundStyle(.red).font(.headline)
            Text("通常是因为备份口令改过。自动同步遇到这种情况会停下，不会擅自覆盖。你可以用现在的口令重新上传一份：旧文件会先原样（仍为加密）备份到本机，其他 Mac 的文件不受影响。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("我确认用现在的备份口令覆盖这台 Mac 在 iCloud 里的文件", isOn: $acceptsReplacement)
            Toggle("云端副本可以不包含 ~/.ssh 之外的 Include 文件（如果有）", isOn: $acceptsIncomplete)
            Button("覆盖并重新上传…", role: .destructive) { replaceOwnSlot() }
                .disabled(!acceptsReplacement || isBusy || passphrase == nil)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.red.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: Actions

    private func reload() {
        loadTask?.cancel()
        isLoading = true
        message = nil
        let service = service
        let secret = passphrase
        loadTask = Task {
            let outcome = await Task.detached(priority: .utility) { () -> Result<([CloudConfigSlot], [CloudConfigDeviceSummary]), Error> in
                Result {
                    let loaded = try service.slots()
                    let described = secret.flatMap { try? service.describeSlots(passphrase: $0) } ?? []
                    return (loaded, described)
                }
            }.value
            if Task.isCancelled { return }
            isLoading = false
            switch outcome {
            case .success(let result):
                slots = result.0
                summaries = Dictionary(uniqueKeysWithValues: result.1.map { ($0.deviceID, $0) })
                if !slots.contains(where: { $0.id == selectedID }) {
                    selectedID = slots.first(where: { $0.deviceID != deviceID })?.id ?? slots.first?.id
                }
            case .failure(let error):
                message = error.localizedDescription
                isError = true
            }
        }
    }

    private func preparePull(_ slot: CloudConfigSlot) {
        guard let secret = passphrase else { return }
        isBusy = true
        let service = service
        let writer = writer
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<CloudPullPlan, Error> in
                Result { try service.planPull(slot: slot, writer: writer, passphrase: secret) }
            }.value
            isBusy = false
            switch result {
            case .success(let plan): pendingPull = plan
            case .failure(let error): message = error.localizedDescription; isError = true
            }
        }
    }

    private func replaceOwnSlot() {
        guard let secret = passphrase, let deviceID else { return }
        isBusy = true
        let service = service
        let root = writer.rootURL
        let backups = writer.backups.directoryURL
        let device = BackupSettings.deviceName
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<(Int, [String], URL?), Error> in
                Result {
                    let scan = ConfigReader(rootURL: root).scan()
                    let plan = try service.planPush(scan: scan, deviceID: deviceID, deviceName: device, passphrase: secret, replaceUnreadableSlot: true)
                    let backup = try service.push(plan, replacedSlotBackupDirectory: backups)
                    return (plan.fileCount, plan.skippedSources, backup)
                }
            }.value
            isBusy = false
            switch outcome {
            case .success(let result):
                isError = false
                acceptsReplacement = false
                message = "已重新上传 \(result.0) 个文件" + (result.2.map { "，旧文件已备份到 \($0.path)" } ?? "") + "。请在 Finder 确认云端同步状态。"
                NotificationCenter.default.post(name: .backupSettingsChanged, object: nil)
                reload()
            case .failure(let error): message = error.localizedDescription; isError = true
            }
        }
    }
}

private struct PullBox: Identifiable {
    let id = UUID()
    let plan: CloudPullPlan
}
