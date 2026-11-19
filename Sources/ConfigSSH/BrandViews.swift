import ConfigSSHCore
import AppKit
import SwiftUI

enum BrandPalette {
    /// Indigo: #5B6CF0 on light backgrounds, #8E9BFF on dark ones, #4C5BD6 for pressed/hover.
    static let indigo = Color(red: 0x5B / 255, green: 0x6C / 255, blue: 0xF0 / 255)
    static let indigoStrong = Color(red: 0x4C / 255, green: 0x5B / 255, blue: 0xD6 / 255)
    static let indigoLight = Color(red: 0x8E / 255, green: 0x9B / 255, blue: 0xFF / 255)

    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    /// Follows the window's appearance, so it can be used anywhere without a ColorScheme.
    static let accent = adaptive(light: NSColor(srgbRed: 0x5B / 255, green: 0x6C / 255, blue: 0xF0 / 255, alpha: 1),
                                 dark: NSColor(srgbRed: 0x8E / 255, green: 0x9B / 255, blue: 0xFF / 255, alpha: 1))
    static let accentStrong = adaptive(light: NSColor(srgbRed: 0x4C / 255, green: 0x5B / 255, blue: 0xD6 / 255, alpha: 1),
                                       dark: NSColor(srgbRed: 0x7A / 255, green: 0x88 / 255, blue: 0xF2 / 255, alpha: 1))
    /// Text and icons drawn on an accent-filled surface: white on light indigo, near-black on the pale dark-mode indigo.
    static let onAccent = adaptive(light: .white, dark: NSColor(srgbRed: 0x0E / 255, green: 0x14 / 255, blue: 0x20 / 255, alpha: 1))

    static func accent(for scheme: ColorScheme) -> Color {
        scheme == .dark ? indigoLight : indigo
    }
}

/// The appearance chosen in 设置 › 外观. Windows that SwiftUI scenes do not own (the floating
/// quick-connect panel) read it here so they follow the same choice as the main window.
enum AppAppearance {
    static var rawValue: String {
        #if DEBUG
        if ConfigSSHPaths.isPreviewMode, let preview = ProcessInfo.processInfo.environment["CONFIGSSH_PREVIEW_APPEARANCE"] {
            return preview
        }
        #endif
        return UserDefaults.standard.string(forKey: "appearance") ?? "system"
    }

    static var colorScheme: ColorScheme? {
        switch rawValue {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }

    static var nsAppearance: NSAppearance? {
        switch rawValue {
        case "light": NSAppearance(named: .aqua)
        case "dark": NSAppearance(named: .darkAqua)
        default: nil
        }
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
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 22) {
                    hero
                    HStack(alignment: .top, spacing: 12) {
                        LinkCard(symbol: "globe", title: "官方网站", subtitle: "configssh.wuewa.cn", destination: ProjectLinks.website)
                        LinkCard(symbol: "chevron.left.forwardslash.chevron.right", title: "GitHub 仓库", subtitle: "AlexWuYh/ConfigSSH", destination: ProjectLinks.repository)
                        LinkCard(symbol: "shippingbox", title: "版本发布", subtitle: "下载与更新日志", destination: ProjectLinks.releases)
                    }
                    updateCard
                    shortcuts
                }
                .padding(.horizontal, 28)
                .padding(.top, 26)
                .padding(.bottom, 18)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            footer
        }
        #if DEBUG
        .task {
            if ConfigSSHPaths.isPreviewMode, ProcessInfo.processInfo.environment["CONFIGSSH_PREVIEW_CHECK_UPDATE"] == "1" {
                checker.check()
            }
        }
        #endif
    }

    private var hero: some View {
        VStack(spacing: 10) {
            Image(nsImage: BrandIcon.image)
                .resizable()
                .interpolation(.high)
                .frame(width: 96, height: 96)
                .shadow(color: BrandPalette.accent.opacity(0.35), radius: 14, y: 6)
            Text("ConfigSSH")
                .font(.system(size: 30, weight: .bold))
            Text(UpdateChecker.currentVersion.map { "版本 \($0)" } ?? "开发版")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .foregroundStyle(BrandPalette.accent)
                .background(BrandPalette.accent.opacity(0.14), in: Capsule())
                .textSelection(.enabled)
            Text("让 SSH 配置管理更简单，让服务器连接更高效")
                .font(.headline)
                .multilineTextAlignment(.center)
                .padding(.top, 2)
            Text("原生 macOS 的 SSH Config 可视化管理工具 · 本地优先")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var updateCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundStyle(BrandPalette.accent)
                Text("版本更新").font(.headline)
                Spacer()
                if checker.state == .checking { ProgressView().controlSize(.small) }
                Button(checker.state == .checking ? "正在检查…" : "检查更新") { checker.check() }
                    .disabled(checker.state == .checking)
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
                      systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
            case .finished(.updateAvailable(let release), _):
                VStack(alignment: .leading, spacing: 6) {
                    Label("发现新版本 \(release.tag)\(release.isPrerelease ? "（预发布）" : "")",
                          systemImage: "arrow.down.circle.fill")
                        .foregroundStyle(BrandPalette.accent)
                        .font(.callout.bold())
                    Link("在 GitHub 查看并下载", destination: release.pageURL)
                        .font(.callout)
                        .foregroundStyle(BrandPalette.accent)
                    Text("ConfigSSH 不会自动下载或安装更新。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Divider()
            Toggle("启动时自动检查更新", isOn: $checkAtLaunch)
            Text("只向 GitHub 请求公开的版本列表，不发送任何主机或配置信息。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var shortcuts: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("常用快捷键").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 18) {
                ForEach([("⌘N", "新增主机"), ("⌘K", "快速连接"),
                         (GlobalShortcutSettings.stored?.display ?? "未设置", "全局呼出"), ("⌘,", "设置")], id: \.1) { item in
                    HStack(spacing: 6) {
                        Text(item.0)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.quaternary))
                        Text(item.1).font(.callout).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// License and author, pinned to the bottom of the page.
    private var footer: some View {
        VStack(spacing: 4) {
            Divider()
            HStack(spacing: 6) {
                Text("作者")
                    .foregroundStyle(.secondary)
                Link(ProjectLinks.authorName, destination: ProjectLinks.author)
                    .foregroundStyle(BrandPalette.accent)
                Text("·").foregroundStyle(.quaternary)
                Link(ProjectLinks.licenseName, destination: ProjectLinks.license)
                    .foregroundStyle(BrandPalette.accent)
                Text("开源").foregroundStyle(.secondary)
            }
            .font(.callout)
            .padding(.top, 8)
            Text("© \(ProjectLinks.copyrightYear) \(ProjectLinks.authorName). 以 \(ProjectLinks.licenseName) 发布，可自由使用、修改和分发。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 10)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct LinkCard: View {
    let symbol: String
    let title: String
    let subtitle: String
    let destination: URL

    var body: some View {
        Link(destination: destination) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(BrandPalette.accent)
                    .frame(width: 34, height: 34)
                    .background(BrandPalette.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                Text(title).font(.callout.weight(.semibold)).foregroundStyle(.primary)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.85)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(destination.absoluteString)
    }
}
