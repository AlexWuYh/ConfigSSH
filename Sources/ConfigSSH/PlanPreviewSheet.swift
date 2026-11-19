import ConfigSSHCore
import SwiftUI

/// Shows a prepared change plan as diffs and writes it only after the user confirms. Used for
/// restoring an encrypted snapshot and for importing an export; both go through
/// `ConfigWriter.commit` (version checks, backup, atomic replace).
struct PlanPreviewSheet: View {
    let title: String
    let heading: String
    let confirmTitle: String
    let plan: ConfigChangePlan
    let writer: ConfigWriter
    let onCommit: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?
    @State private var isCommitting = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text(heading).font(.title3.bold())
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(plan.warnings, id: \.self) { warning in
                            Label(warning, systemImage: "info.circle")
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
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
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
                Divider()
                HStack {
                    Button("取消") { dismiss() }.disabled(isCommitting)
                    Spacer()
                    Button(isCommitting ? "正在写入…" : confirmTitle) { commit() }
                        .disabled(isCommitting)
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(20)
            .frame(minWidth: 660, minHeight: 450)
            .navigationTitle(title)
        }
        .task {
            do {
                let store = try MetadataStore()
                if try !GroupDeletionService(writer: writer, metadataStore: store).pendingOperations().isEmpty {
                    errorMessage = "存在未完成的分组操作，请先在主窗口继续处理"
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func commit() {
        isCommitting = true
        let writer = writer
        let plan = plan
        Task {
            let failure = await Task.detached(priority: .userInitiated) { () -> String? in
                do { _ = try writer.commit(plan); return nil } catch { return error.localizedDescription }
            }.value
            isCommitting = false
            if let failure { errorMessage = failure } else { onCommit(); dismiss() }
        }
    }
}
