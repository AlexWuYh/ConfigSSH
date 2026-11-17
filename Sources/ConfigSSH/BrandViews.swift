import ConfigSSHCore
import AppKit
import SwiftUI

enum BrandPalette {
    static let selectionBlue = Color(red: 104 / 255, green: 151 / 255, blue: 208 / 255)
    static let deepBlue = Color(red: 43 / 255, green: 101 / 255, blue: 171 / 255)
    static let lightBlue = Color(red: 145 / 255, green: 190 / 255, blue: 243 / 255)

    static func accent(for scheme: ColorScheme) -> Color {
        scheme == .dark ? lightBlue : deepBlue
    }
}

enum BrandIcon {
    static let image: NSImage = {
        guard let url = Bundle.module.url(forResource: "ConfigSSH-Mark", withExtension: "png"),
              let image = NSImage(contentsOf: url) else {
            return NSImage(named: NSImage.applicationIconName) ?? NSImage()
        }
        return image
    }()

    /// Menu bar status-item glyph. The 64 px PNG loads as 64×64 *points*, and `MenuBarExtra`
    /// sizes the status item from the image itself (a SwiftUI `.frame` on the label is ignored),
    /// so set the point size here: 18 pt matches system status icons, and the glyph's built-in
    /// padding keeps the drawn mark at about 13 pt.
    static let menuBarPointSize: CGFloat = 18

    static let menuImage: NSImage = {
        guard let url = Bundle.module.url(forResource: "ConfigSSH-Menu", withExtension: "png"),
              let source = NSImage(contentsOf: url) else { return BrandIcon.image }
        let image = source.copy() as! NSImage
        image.size = NSSize(width: menuBarPointSize, height: menuBarPointSize)
        image.isTemplate = true
        image.accessibilityDescription = "ConfigSSH"
        return image
    }()
}

struct BrandHeaderView: View {
    var body: some View {
        HStack(spacing: 11) {
            Image(nsImage: BrandIcon.image)
                .resizable()
                .interpolation(.high)
                .frame(width: 43, height: 43)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("ConfigSSH")
                    .font(.headline)
                Text("Native · Simple · Local First")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }
}

struct AboutConfigSSHView: View {
    @AppStorage(UpdateChecker.autoCheckKey) private var checkAtLaunch = false
    private let checker = UpdateChecker.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Image(nsImage: BrandIcon.image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 88, height: 88)
                Text("ConfigSSH")
                    .font(.largeTitle.bold())
                Text(UpdateChecker.currentVersion.map { "版本 \($0)" } ?? "开发版")
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text("Manage SSH Config Visually. Connect Effortlessly.")
                    .font(.headline)
                Text("让 SSH 配置管理更简单，让服务器连接更高效。")
                    .foregroundStyle(.secondary)
                Text("Native · Simple · Local First")
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)

                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Image(systemName: "chevron.left.forwardslash.chevron.right")
                                .foregroundStyle(.secondary)
                            Link("github.com/AlexWuYh/ConfigSSH", destination: UpdateCheck.repositoryURL)
                            Spacer()
                            Button("复制") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(UpdateCheck.repositoryURL.absoluteString, forType: .string)
                            }
                            .buttonStyle(.borderless)
                            .font(.caption)
                        }
                        Divider()
                        updateSection
                    }
                    .padding(6)
                }
                .frame(maxWidth: 420)

                GroupBox("常用命令") {
                    Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                        GridRow { Text("⌘N").font(.body.monospaced()); Text("新增主机配置") }
                        GridRow { Text("⌘K").font(.body.monospaced()); Text("快速连接") }
                        GridRow { Text("⌘,").font(.body.monospaced()); Text("打开设置") }
                    }
                    .padding(10)
                }
                .frame(maxWidth: 420)
                Text("MIT License · © 2026 ConfigSSH contributors")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        #if DEBUG
        .task {
            if ConfigSSHPaths.isPreviewMode, ProcessInfo.processInfo.environment["CONFIGSSH_PREVIEW_CHECK_UPDATE"] == "1" {
                checker.check()
            }
        }
        #endif
    }

    @ViewBuilder
    private var updateSection: some View {
        HStack {
            Button(checker.state == .checking ? "正在检查…" : "检查更新") { checker.check() }
                .disabled(checker.state == .checking)
            if checker.state == .checking { ProgressView().controlSize(.small) }
            Spacer()
            Link("所有版本", destination: UpdateCheck.releasesPageURL)
                .font(.callout)
        }
        switch checker.state {
        case .idle, .checking:
            EmptyView()
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .font(.callout)
        case .finished(.upToDate(let current), let date):
            Label("已是最新版本（\(current)）· \(date.formatted(date: .omitted, time: .shortened)) 检查",
                  systemImage: "checkmark.circle")
                .font(.callout)
        case .finished(.updateAvailable(let release), _):
            VStack(alignment: .leading, spacing: 6) {
                Label("发现新版本 \(release.tag)\(release.isPrerelease ? "（预发布）" : "")",
                      systemImage: "arrow.down.circle.fill")
                    .foregroundStyle(Color.accentColor)
                    .font(.callout.bold())
                Link("在 GitHub 查看并下载", destination: release.pageURL)
                    .font(.callout)
                Text("ConfigSSH 不会自动下载或安装更新。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        Toggle("启动时自动检查更新", isOn: $checkAtLaunch)
            .font(.callout)
        Text("检查更新只会向 GitHub 请求公开的版本列表，不发送任何主机或配置信息。")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
