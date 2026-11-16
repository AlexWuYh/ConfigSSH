import ConfigSSHCore
import SwiftUI

struct GroupCreationView: View {
    let onCreate: (String) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                TextField("分组名称", text: $name)
                Text("将在 ~/.ssh/config.d/ 下创建同名目录；即使暂无主机，分组也会保留。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("创建分组")
            .toolbar {
                Button("取消") { dismiss() }
                Button("创建") {
                    do {
                        try onCreate(name)
                        dismiss()
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .buttonStyle(.borderedProminent)
            }
            .frame(width: 460, height: 250)
        }
    }
}

struct GroupDeletionView: View {
    let name: String
    let writer: ConfigWriter
    let scan: ConfigScan
    let onCommit: (GroupDeletionPlan) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var plan: GroupDeletionPlan?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Label("删除“\(name)”分组", systemImage: "folder.badge.minus")
                    .font(.title2.bold())
                if let plan {
                    if plan.movedHosts.isEmpty {
                        Text("分组中没有受管主机。删除后，该分组不再显示；仅使用本地元数据分组的主机会归入“未分组”。")
                            .foregroundStyle(.secondary)
                    } else {
                        Label("以下 \(plan.movedHosts.count) 台主机将默认移动到“未分组”，不会删除连接配置。", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        ScrollView {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(plan.movedHosts) { host in
                                    Text("\(host.alias)  →  config.d/\(host.sourceURL.lastPathComponent)")
                                        .font(.body.monospaced())
                                }
                                if let changePlan = plan.changePlan {
                                    Divider()
                                    Text("保存前已检查目标文件不会被覆盖；移动时会创建备份。")
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                    ForEach(Array(changePlan.changes.enumerated()), id: \.offset) { _, change in
                                        GroupBox(change.url.lastPathComponent) {
                                            Text(change.diff)
                                                .font(.system(.caption, design: .monospaced))
                                                .textSelection(.enabled)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
                Spacer(minLength: 0)
                Divider()
                HStack {
                    Button("取消") { dismiss() }
                    Spacer()
                    Button(plan?.movedHosts.isEmpty == true ? "删除空分组" : "移动主机并删除分组", role: .destructive) {
                        guard let plan else { return }
                        do {
                            try onCommit(plan)
                            dismiss()
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                    .disabled(plan == nil)
                }
            }
            .padding(22)
            .frame(minWidth: 560, minHeight: 330)
            .navigationTitle("删除分组")
        }
        .onAppear {
            do {
                plan = try writer.planGroupDeletion(named: name, from: scan)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
