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
        _ = GlobalShortcutManager.shared.apply(
            UserDefaults.standard.string(forKey: "globalShortcut") ?? "off"
        )
        Task { @MainActor in AutoSnapshotScheduler.shared.start() }
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
                .resizable()
                .interpolation(.high)
                .frame(width: 16, height: 16)
                .accessibilityLabel("ConfigSSH 快速连接")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .preferredColorScheme(colorScheme)
        }
    }
}
