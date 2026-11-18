import AppKit
import ConfigSSHCore
import SwiftUI

@main
struct ConfigSSHApp: App {
    @AppStorage("appearance") private var appearance = "system"
    @FocusedValue(\.newHostAction) private var newHostAction

    private var colorScheme: ColorScheme? {
        #if DEBUG
        let selected = ConfigSSHPaths.isPreviewMode
            ? ProcessInfo.processInfo.environment["CONFIGSSH_PREVIEW_APPEARANCE"] ?? appearance
            : appearance
        #else
        let selected = appearance
        #endif
        return switch selected {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }

    init() {
        NSApplication.shared.applicationIconImage = BrandIcon.image
        _ = GlobalShortcutManager.shared.apply(GlobalShortcutSettings.stored)
        Task { @MainActor in AutoSnapshotScheduler.shared.start() }
        #if DEBUG
        if ConfigSSHPaths.isPreviewMode, ProcessInfo.processInfo.environment["CONFIGSSH_PREVIEW_QUICK_PANEL"] == "1" {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                GlobalShortcutManager.shared.showPanel()
            }
        }
        if ConfigSSHPaths.isPreviewMode, ProcessInfo.processInfo.environment["CONFIGSSH_PREVIEW_MENU_DROPDOWN"] == "1" {
            // Screenshots: the menu bar dropdown's content (same embedded QuickLaunchView) in an
            // ordinary window, for setups where a menu bar manager hides new status items.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
                                      styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
                window.styleMask = [.borderless]
                window.title = "ConfigSSH · 菜单栏预览"
                let hosting = NSHostingView(rootView: QuickLaunchView())
                window.contentView = hosting
                window.setContentSize(NSSize(width: 520, height: 430))
                window.isReleasedWhenClosed = false
                if let main = NSApp.windows.first(where: { $0.isVisible })?.frame {
                    window.setFrameTopLeftPoint(NSPoint(x: main.midX - 260, y: main.maxY - 60))
                }
                window.orderFrontRegardless()
            }
        }
        #endif
        Task { @MainActor in UpdateChecker.shared.checkAtLaunchIfEnabled() }
    }

    var body: some Scene {
        WindowGroup("ConfigSSH") {
            ContentView()
                .preferredColorScheme(colorScheme)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新增主机配置") { newHostAction?() }
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(newHostAction == nil)
            }
        }

        MenuBarExtra {
            QuickLaunchView()
                .preferredColorScheme(colorScheme)
        } label: {
            Image(nsImage: BrandIcon.menuImage)
                .accessibilityLabel("ConfigSSH 快速连接")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .preferredColorScheme(colorScheme)
        }
    }
}
