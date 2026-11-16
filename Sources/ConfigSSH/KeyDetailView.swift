import ConfigSSHCore
import SwiftUI

struct KeyDetailView: View {
    let key: PublicKeyRecord
    let onCopyPublicKey: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(key.name)
                    .font(.largeTitle.bold())
                Text(key.isReferencedGlobally ? "由全局配置引用的密钥" :
                    key.associatedHosts.isEmpty ? "本地密钥索引" : "由主机配置引用的密钥")
                    .foregroundStyle(.secondary)
                GroupBox("公钥") {
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent("类型", value: key.type)
                        LabeledContent("指纹", value: key.fingerprint ?? "未找到对应 .pub 文件")
                        LabeledContent("公钥文件", value: key.publicKeyExists ? "已找到" : "未找到")
                        Text(key.publicKeyURL.path)
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }
                GroupBox("对应私钥") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(key.privateKeyURL.path)
                            .textSelection(.enabled)
                        Label(key.privateKeyExists ? "文件存在" : "未找到文件",
                              systemImage: key.privateKeyExists ? "checkmark.circle" : "exclamationmark.circle")
                            .foregroundStyle(.secondary)
                        Text("应用只检查路径是否存在，不读取私钥内容。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }
                if !key.associatedHosts.isEmpty {
                    GroupBox("关联主机") {
                        Text(key.associatedHosts.joined(separator: "、"))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(4)
                    }
                }
                Button("复制公钥", action: onCopyPublicKey)
                    .buttonStyle(.borderedProminent)
                    .disabled(key.publicKeyText == nil)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
