import ConfigSSHCore
import SwiftUI

struct BackupDetailView: View {
    let record: BackupRecord
    let onRestore: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(record.reason)
                .font(.title.bold())
            Text(record.createdAt, format: .dateTime.year().month().day().hour().minute().second())
                .foregroundStyle(.secondary)
            GroupBox("原文件") {
                Text(record.sourcePath)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
            }
            Text("恢复前会检查当前文件是否仍为本次写入的版本，并展示恢复差异。")
                .foregroundStyle(.secondary)
            Button("预览恢复", action: onRestore)
                .buttonStyle(.borderedProminent)
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct RestorePreviewView: View {
    let record: BackupRecord
    let writer: ConfigWriter
    let onCommit: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var plan: ConfigChangePlan?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                if let plan {
                    Text("请确认恢复差异")
                        .font(.title3.bold())
                    ScrollView {
                        ForEach(Array(plan.changes.enumerated()), id: \.offset) { _, change in
                            GroupBox(change.url.path) {
                                Text(change.diff)
                                    .font(.system(.body, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(8)
                            }
                        }
                    }
                } else {
                    ContentUnavailableView("无法准备恢复", systemImage: "exclamationmark.triangle")
                }
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
                Divider()
                HStack {
                    Button("取消") { dismiss() }
                    Spacer()
                    Button("确认恢复") {
                        guard let plan else { return }
                        do {
                            _ = try writer.commit(plan)
                            onCommit()
                            dismiss()
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                    .disabled(plan == nil)
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(20)
            .frame(minWidth: 580, minHeight: 420)
            .navigationTitle("恢复备份")
        }
        .onAppear {
            do {
                plan = try writer.planRestore(record)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
