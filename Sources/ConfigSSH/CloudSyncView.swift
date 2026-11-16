import ConfigSSHCore
import SwiftUI

struct CloudSyncView: View {
    let writer: ConfigWriter
    let folder: URL
    let cloudRoot: URL

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var deviceID: UUID?
    @State private var slots: [CloudConfigSlot] = []
    @State private var selectedSlotID: UUID?
    @State private var deviceNames: [UUID: String] = [:]
    @State private var deviceNameErrors: [UUID: String] = [:]
    @State private var deviceNameTask: Task<Void, Never>?
    @State private var isUnlockingDeviceNames = false
    @State private var slotsTask: Task<Void, Never>?
    @State private var passphrase = ""
    @State private var hasSavedPassphrase = false
    @State private var confirmation = ""
    @State private var pendingPush: CloudPushPlan?
    @State private var acceptsIncompletePush = false
    @State private var pendingPull: CloudPullPlan?
    @State private var isBusy = false
    @State private var message: String?
    @State private var isError = false

    private var service: CloudConfigSyncService {
        CloudConfigSyncService(folder: folder, cloudRoot: cloudRoot)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    LabeledContent("iCloud 目录") {
                        Text(folder.path).font(.caption.monospaced()).textSelection(.enabled)
                    }
                    Label("云端仅保存 AES-GCM 加密的 .cssh 文件。每台 Mac 使用独立设备槽；共用口令只在本机输入，不写入云端。",
                          systemImage: "lock.shield")
                        .font(.callout)
                    if let deviceID {
                        Text("此设备 · \(deviceID.uuidString)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Text("若重装系统或钥匙串被清除，此 Mac 会生成新设备 ID；旧云端文件仍保留，需要手动选择拉取或清理。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("连接测试", systemImage: "network") { testConnection() }
                        Button("刷新设备列表", systemImage: "arrow.clockwise") { reloadSlots() }
                    }
                    .disabled(isBusy)

                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        Text("加密口令").font(.headline)
                        SecureField("至少 12 个字符；多台 Mac 使用同一口令", text: $passphrase)
                            .textContentType(.password)
                        HStack {
                            Button(hasSavedPassphrase ? "更新已保存口令" : "保存口令到本机钥匙串") {
                                savePassphrase()
                            }
                            .disabled(passphrase.count < 12 || isBusy)
                            if hasSavedPassphrase {
                                Button("移除已保存口令") { removePassphrase() }
                            }
                        }
                        if hasSavedPassphrase {
                            Label("已保存在此 Mac 的钥匙串，下次打开会自动填入。", systemImage: "checkmark.shield")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text("口令丢失后无法解密云端配置。钥匙串仅保存在此 Mac，不随配置上传；修改口令后请点“更新已保存口令”。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        Text("本机 → iCloud").font(.headline)
                        Text("上传主 config 和受管 config.d 文件；外部或非受管 Include 会跳过并在预览中列出，不上传密钥。只覆盖此设备的云端文件。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        if pendingPush == nil {
                            Button("预览推送") { preparePush() }
                                .disabled(isBusy || deviceID == nil || passphrase.count < 12)
                        } else if let pendingPush {
                            GroupBox("即将推送") {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("\(pendingPush.fileCount) 个配置文件 · \(pendingPush.expectedRemote.exists ? "覆盖此设备云端文件" : "新建设备云端文件")")
                                    Text(pendingPush.slot.url.lastPathComponent)
                                        .font(.caption.monospaced())
                                    ForEach(pendingPush.warnings, id: \.self) { warning in
                                        Label(warning, systemImage: "exclamationmark.triangle")
                                            .foregroundStyle(.orange)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    if !pendingPush.skippedSources.isEmpty {
                                        DisclosureGroup("查看跳过的 \(pendingPush.skippedSources.count) 个文件") {
                                            ForEach(pendingPush.skippedSources, id: \.self) { path in
                                                Text(path)
                                                    .font(.caption.monospaced())
                                                    .textSelection(.enabled)
                                                    .frame(maxWidth: .infinity, alignment: .leading)
                                            }
                                        }
                                    }
                                    if !pendingPush.warnings.isEmpty {
                                        Toggle("我已了解：云端副本可能缺少这些 Include 文件", isOn: $acceptsIncompletePush)
                                    }
                                    if pendingPush.expectedRemote.exists {
                                        Label("旧云端文件将被覆盖，其他 Mac 的设备文件不会受影响。",
                                              systemImage: "exclamationmark.triangle")
                                            .foregroundStyle(.orange)
                                    }
                                    SecureField("再次输入口令确认", text: $confirmation)
                                    HStack {
                                        Button("取消") {
                                            self.pendingPush = nil
                                            confirmation = ""
                                            acceptsIncompletePush = false
                                        }
                                        Button("确认推送", role: .destructive) { push(pendingPush) }
                                            .disabled(isBusy || confirmation != passphrase ||
                                                (!pendingPush.warnings.isEmpty && !acceptsIncompletePush))
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(6)
                            }
                        }
                    }

                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        Text("iCloud → 本机").font(.headline)
                        Text("选择一台设备，先解密并预览差异，再覆盖本机相同路径的配置文件。本机其他文件和密钥保持不变。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        GroupBox("云端设备 · \(slots.count)") {
                            VStack(alignment: .leading, spacing: 7) {
                                if slots.isEmpty {
                                    Label("尚无加密设备文件", systemImage: "icloud.slash")
                                        .foregroundStyle(.secondary)
                                    Text("先从这台 Mac 推送，或等待其他 Mac 的 iCloud Drive 文件下载完成后点“刷新设备列表”。")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else {
                                    ForEach(slots) { slot in
                                        Button {
                                            selectedSlotID = slot.id
                                        } label: {
                                            HStack(spacing: 10) {
                                                Image(systemName: slot.deviceID == deviceID ? "laptopcomputer" : "desktopcomputer")
                                                VStack(alignment: .leading, spacing: 2) {
                                                    Text(deviceNames[slot.id] ??
                                                         (slot.deviceID == deviceID ? "此 Mac 的配置" : "其他 Mac 的配置"))
                                                        .fontWeight(.medium)
                                                    Text(slot.deviceID.uuidString)
                                                        .font(.caption.monospaced())
                                                        .foregroundStyle(.secondary)
                                                    if deviceNameErrors[slot.id] != nil {
                                                        Text("名称未解锁；可选中后重试")
                                                            .font(.caption)
                                                            .foregroundStyle(.orange)
                                                    }
                                                }
                                                Spacer()
                                                if selectedSlotID == slot.id {
                                                    Image(systemName: "checkmark.circle.fill")
                                                        .foregroundStyle(.tint)
                                                }
                                            }
                                            .padding(10)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .background(selectedSlotID == slot.id
                                                        ? BrandPalette.selectionBlue.opacity(0.20) : .clear,
                                                        in: RoundedRectangle(cornerRadius: 8))
                                            .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel("选择\(slot.deviceID == deviceID ? "此 Mac" : "其他 Mac")的云端配置")
                                        .accessibilityValue(slot.deviceID.uuidString)
                                        .accessibilityAddTraits(selectedSlotID == slot.id ? .isSelected : [])
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                        }
                        HStack {
                            Button("使用口令识别设备名称") { unlockDeviceNames() }
                                .disabled(slots.isEmpty || passphrase.isEmpty || isBusy || isUnlockingDeviceNames)
                            if isUnlockingDeviceNames { ProgressView().controlSize(.small) }
                        }
                        Button("预览拉取到本机") { preparePull() }
                            .disabled(isBusy || selectedSlotID == nil || passphrase.isEmpty)
                            .help(slots.isEmpty ? "暂无可拉取的设备配置；请先推送或刷新列表" : "解密所选设备配置并预览本机差异")
                        if let pendingPull {
                            GroupBox("来自 \(pendingPull.archive.deviceName) · \(pendingPull.archive.files.count) 个配置文件") {
                                VStack(alignment: .leading, spacing: 10) {
                                    ForEach(pendingPull.changes.warnings, id: \.self) { warning in
                                        Label(warning, systemImage: "exclamationmark.triangle")
                                            .font(.callout)
                                            .foregroundStyle(.orange)
                                    }
                                    ForEach(pendingPull.changes.changes, id: \.url) { change in
                                        DisclosureGroup(change.url.path) {
                                            Text(change.diff)
                                                .font(.system(.caption, design: .monospaced))
                                                .textSelection(.enabled)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                    }
                                    HStack {
                                        Button("取消") { self.pendingPull = nil }
                                        Button("确认拉取并覆盖本地同路径配置", role: .destructive) {
                                            pull(pendingPull)
                                        }
                                        .disabled(isBusy)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(6)
                            }
                        }
                    }
                    if let message {
                        Label(message, systemImage: isError ? "exclamationmark.triangle" : "checkmark.circle")
                            .foregroundStyle(isError ? .orange : .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minWidth: 720, minHeight: 570)
            .navigationTitle("iCloud 加密配置")
            .toolbar { Button("关闭") { dismiss() } }
            .onAppear {
                do { deviceID = try CloudDeviceIdentity.currentID() }
                catch { report(error) }
                do {
                    if let saved = try CloudSyncSecretStore.read() {
                        passphrase = saved
                        hasSavedPassphrase = true
                    }
                } catch { report(error) }
                reloadSlots()
            }
            .onDisappear {
                slotsTask?.cancel()
                deviceNameTask?.cancel()
                passphrase = ""
                confirmation = ""
                pendingPush = nil
                pendingPull = nil
            }
            .onChange(of: selectedSlotID) { _, _ in pendingPull = nil }
            .onChange(of: passphrase) { _, _ in
                deviceNameTask?.cancel()
                deviceNames = [:]
                deviceNameErrors = [:]
                isUnlockingDeviceNames = false
                pendingPush = nil
                pendingPull = nil
                confirmation = ""
                acceptsIncompletePush = false
            }
        }
        .tint(BrandPalette.accent(for: colorScheme))
    }

    private func testConnection() {
        isBusy = true
        let service = service
        Task {
            let failure = await Task.detached(priority: .utility) { () -> String? in
                do { try service.testConnection(); return nil }
                catch { return error.localizedDescription }
            }.value
            isBusy = false
            if let failure { report(failure) }
            else {
                isError = false
                message = "本机目录读写正常；iCloud 云端上传状态仍需在 Finder 中确认。"
                reloadSlots()
            }
        }
    }

    private func reloadSlots() {
        slotsTask?.cancel()
        let service = service
        slotsTask = Task {
            let result = await Task.detached(priority: .utility) { () -> Result<[CloudConfigSlot], Error> in
                Result { try service.slots() }
            }.value
            if Task.isCancelled { return }
            switch result {
            case .success(let loaded):
                deviceNameTask?.cancel()
                slots = loaded
                deviceNames = [:]
                deviceNameErrors = [:]
                if !slots.contains(where: { $0.id == selectedSlotID }) {
                    selectedSlotID = loaded.first?.id
                }
                if !passphrase.isEmpty && !loaded.isEmpty { unlockDeviceNames() }
            case .failure(let error): report(error)
            }
        }
    }

    private func preparePush() {
        guard let deviceID else { return }
        isBusy = true
        let service = service
        let root = writer.rootURL
        let secret = passphrase
        let deviceName = ProcessInfo.processInfo.hostName
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<CloudPushPlan, Error> in
                Result {
                    try service.planPush(scan: ConfigReader(rootURL: root).scan(), deviceID: deviceID,
                                         deviceName: deviceName, passphrase: secret)
                }
            }.value
            isBusy = false
            switch result {
            case .success(let plan):
                pendingPush = plan
                message = nil
                acceptsIncompletePush = false
            case .failure(let error): report(error)
            }
        }
    }

    private func push(_ plan: CloudPushPlan) {
        isBusy = true
        let service = service
        Task {
            let failure = await Task.detached(priority: .userInitiated) { () -> String? in
                do { try service.push(plan); return nil }
                catch { return error.localizedDescription }
            }.value
            isBusy = false
            pendingPush = nil
            confirmation = ""
            acceptsIncompletePush = false
            if let failure { report(failure) }
            else {
                isError = false
                message = "已写入此设备的加密文件；请在 Finder 确认云端同步状态。"
                reloadSlots()
            }
        }
    }

    private func preparePull() {
        guard let slot = slots.first(where: { $0.id == selectedSlotID }) else { return }
        isBusy = true
        let service = service
        let writer = writer
        let secret = passphrase
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<CloudPullPlan, Error> in
                Result { try service.planPull(slot: slot, writer: writer, passphrase: secret) }
            }.value
            isBusy = false
            switch result {
            case .success(let plan): pendingPull = plan; message = nil
            case .failure(let error): report(error)
            }
        }
    }

    private func pull(_ plan: CloudPullPlan) {
        isBusy = true
        let service = service
        let writer = writer
        Task {
            let failure = await Task.detached(priority: .userInitiated) { () -> String? in
                do { try service.pull(plan, writer: writer); return nil }
                catch { return error.localizedDescription }
            }.value
            isBusy = false
            pendingPull = nil
            if let failure { report(failure) }
            else {
                isError = false
                message = "配置已写入本机并建立变更备份。"
                NotificationCenter.default.post(name: .configSSHConfigChanged, object: nil)
            }
        }
    }

    private func report(_ error: Error) { report(error.localizedDescription) }
    private func report(_ text: String) { message = text; isError = true }

    private func unlockDeviceNames() {
        guard !passphrase.isEmpty, !slots.isEmpty else { return }
        deviceNameTask?.cancel()
        isUnlockingDeviceNames = true
        let service = service
        let secret = passphrase
        deviceNameTask = Task {
            let result = await Task.detached(priority: .utility) { () -> Result<[CloudConfigDeviceSummary], Error> in
                Result { try service.describeSlots(passphrase: secret) }
            }.value
            if Task.isCancelled { return }
            isUnlockingDeviceNames = false
            switch result {
            case .success(let summaries):
                deviceNames = Dictionary(uniqueKeysWithValues: summaries.compactMap { summary in
                    summary.deviceName.map { (summary.deviceID, $0) }
                })
                deviceNameErrors = Dictionary(uniqueKeysWithValues: summaries.compactMap { summary in
                    summary.error.map { (summary.deviceID, $0) }
                })
            case .failure(let error): report(error)
            }
        }
    }

    private func savePassphrase() {
        guard passphrase.count >= 12 else { return }
        do {
            try CloudSyncSecretStore.save(passphrase)
            hasSavedPassphrase = true
            isError = false
            message = "口令已保存到此 Mac 的钥匙串；云端不保存口令。"
        } catch { report(error) }
    }

    private func removePassphrase() {
        do {
            try CloudSyncSecretStore.remove()
            hasSavedPassphrase = false
            isError = false
            message = "已从此 Mac 的钥匙串移除口令。"
        } catch { report(error) }
    }
}
