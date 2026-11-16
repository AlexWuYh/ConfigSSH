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

    static let menuImage: NSImage = {
        guard let url = Bundle.module.url(forResource: "ConfigSSH-Menu", withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return image }
        image.isTemplate = true
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
    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: BrandIcon.image)
                .resizable()
                .interpolation(.high)
                .frame(width: 88, height: 88)
            Text("ConfigSSH")
                .font(.largeTitle.bold())
            Text("Manage SSH Config Visually. Connect Effortlessly.")
                .font(.headline)
            Text("让 SSH 配置管理更简单，让服务器连接更高效。")
                .foregroundStyle(.secondary)
            Text("原生 macOS SSH Config 可视化管理工具")
                .foregroundStyle(.secondary)
            Text("Native · Simple · Local First")
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
            Text("MIT License · © 2026 ConfigSSH contributors")
                .font(.caption)
                .foregroundStyle(.secondary)
            GroupBox("常用命令") {
                Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                    GridRow { Text("⌘N").font(.body.monospaced()); Text("新增主机配置") }
                    GridRow { Text("⌘K").font(.body.monospaced()); Text("快速连接") }
                    GridRow { Text("⌘,").font(.body.monospaced()); Text("打开设置") }
                }
                .padding(10)
            }
            .frame(maxWidth: 360)
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
