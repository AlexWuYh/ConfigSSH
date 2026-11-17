import AppKit
import Carbon
import ConfigSSHCore
import SwiftUI

enum GlobalShortcutChoice: String, CaseIterable, Identifiable {
    case off
    case optionCommandK
    case controlOptionK
    case optionSpace
    case controlOptionSpace
    case controlShiftSpace

    var id: String { rawValue }

    static let defaultsKey = "globalShortcut"
    /// ⌥⌘K: free system-wide on a default macOS install, unlike ⌃Space / ⌃⌥Space (input sources).
    static let `default` = GlobalShortcutChoice.optionCommandK

    /// The saved preference, or the default when the user never chose one.
    static var stored: GlobalShortcutChoice {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(GlobalShortcutChoice.init(rawValue:)) ?? .default
    }

    var title: String {
        switch self {
        case .off: "关闭"
        case .optionCommandK: "⌥⌘K（推荐）"
        case .controlOptionK: "⌃⌥K"
        case .optionSpace: "⌥Space"
        case .controlOptionSpace: "⌃⌥Space"
        case .controlShiftSpace: "⌃⇧Space"
        }
    }

    var symbol: String {
        switch self {
        case .off: ""
        case .optionCommandK: "⌥⌘K"
        case .controlOptionK: "⌃⌥K"
        case .optionSpace: "⌥Space"
        case .controlOptionSpace: "⌃⌥Space"
        case .controlShiftSpace: "⌃⇧Space"
        }
    }

    /// Combinations that macOS or common tools already use; registration may still succeed but
    /// the other owner then stops working.
    var conflictNote: String? {
        switch self {
        case .controlOptionSpace: "与系统“选择输入法菜单中的下一个输入法”默认快捷键相同。"
        case .controlShiftSpace: "部分输入法和编辑器也使用此组合。"
        case .optionSpace: "Alfred 等启动器常用此组合。"
        default: nil
        }
    }

    var keyCode: UInt32 {
        switch self {
        case .off: 0
        case .controlOptionSpace, .controlShiftSpace, .optionSpace: UInt32(kVK_Space)
        case .optionCommandK, .controlOptionK: UInt32(kVK_ANSI_K)
        }
    }

    var modifiers: UInt32 {
        switch self {
        case .off: 0
        case .controlOptionSpace: UInt32(controlKey | optionKey)
        case .controlShiftSpace: UInt32(controlKey | shiftKey)
        case .optionCommandK: UInt32(optionKey | cmdKey)
        case .controlOptionK: UInt32(controlKey | optionKey)
        case .optionSpace: UInt32(optionKey)
        }
    }
}

private func handleGlobalHotKey(
    _ callRef: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData else { return OSStatus(eventNotHandledErr) }
    let manager = Unmanaged<GlobalShortcutManager>.fromOpaque(userData).takeUnretainedValue()
    DispatchQueue.main.async { manager.togglePanel() }
    return noErr
}

@MainActor
final class GlobalShortcutManager {
    static let shared = GlobalShortcutManager()

    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var activeChoice: GlobalShortcutChoice = .off

    /// The shortcut actually registered with the system, which can differ from the saved
    /// preference when registration failed (for example, another app owns the combination).
    var activeRawValue: String { activeChoice.rawValue }
    private var panel: NSPanel?

    private init() { }

    @discardableResult
    func apply(_ rawValue: String) -> Bool {
        let requested = GlobalShortcutChoice(rawValue: rawValue) ?? .off
        if requested == activeChoice { return true }
        let previous = activeChoice
        unregister()
        if requested == .off { return true }
        if register(requested) { return true }
        if previous != .off { _ = register(previous) }
        return false
    }

    /// The hotkey toggles: a second press closes the panel.
    func togglePanel() {
        if let panel, panel.isVisible { closePanel() } else { showPanel() }
    }

    /// Spotlight-style floating search panel. It becomes key without activating ConfigSSH, so
    /// the app the user was in stays frontmost until a terminal is opened.
    func showPanel() {
        let window = panel ?? makePanel()
        // Fixed size: the host list loads asynchronously, so fitting the first layout would leave
        // the panel too short once results arrive.
        let hosting = NSHostingView(rootView: QuickLaunchView(style: .floatingPanel) { [weak self] in
            self?.closePanel()
        }.frame(width: Self.panelSize.width, height: Self.panelSize.height, alignment: .top))
        hosting.sizingOptions = []
        window.contentView = hosting
        window.setContentSize(Self.panelSize)
        position(window)
        window.orderFrontRegardless()
        window.makeKey()
        panel = window
    }

    func closePanel() {
        panel?.orderOut(nil)
        panel?.contentView = nil
    }

    static let panelSize = NSSize(width: 560, height: 440)

    private func makePanel() -> NSPanel {
        #if DEBUG
        // Screenshots only: window capture fails on the borderless transparent panel, so the
        // preview hosts the same QuickLaunchView in an ordinary titled panel.
        if ConfigSSHPaths.isPreviewMode, ProcessInfo.processInfo.environment["CONFIGSSH_PREVIEW_QUICK_PANEL"] == "1" {
            let preview = QuickLaunchPanel(contentRect: NSRect(origin: .zero, size: Self.panelSize),
                                           styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
            preview.titlebarAppearsTransparent = true
            preview.titleVisibility = .hidden
            preview.title = "ConfigSSH · 快速连接"
            preview.hidesOnDeactivate = false
            return preview
        }
        #endif
        let window = QuickLaunchPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.isFloatingPanel = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        window.hidesOnDeactivate = false
        window.isMovableByWindowBackground = true
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.title = "ConfigSSH · 快速连接"
        window.onResignKey = { [weak self] in self?.closePanel() }
        return window
    }

    /// Upper third of the screen that has the pointer, like Spotlight.
    private func position(_ window: NSWindow) {
        let mouse = NSEvent.mouseLocation
        var screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        #if DEBUG
        // Screenshots: show the preview panel on the main window's display.
        if ConfigSSHPaths.isPreviewMode, ProcessInfo.processInfo.environment["CONFIGSSH_PREVIEW_QUICK_PANEL"] == "1",
           let mainScreen = NSApp.windows.first(where: { !($0 is NSPanel) && $0.isVisible })?.screen {
            screen = mainScreen
        }
        #endif
        guard let frame = screen?.visibleFrame else { window.center(); return }
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2,
                                      y: frame.maxY - frame.height / 4 - size.height / 2))
    }

    private func register(_ choice: GlobalShortcutChoice) -> Bool {
        if handler == nil {
            var installed: EventHandlerRef?
            var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                          eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(
                GetApplicationEventTarget(), handleGlobalHotKey, 1, &eventType,
                Unmanaged.passUnretained(self).toOpaque(), &installed
            )
            guard status == noErr else { return false }
            handler = installed
        }
        var registered: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: 0x43535348, id: 1)
        let status = RegisterEventHotKey(choice.keyCode, choice.modifiers, identifier,
                                         GetApplicationEventTarget(), 0, &registered)
        guard status == noErr else { return false }
        hotKey = registered
        activeChoice = choice
        return true
    }

    private func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        activeChoice = .off
    }
}

/// Borderless panels cannot become key by default; this one must, so the search field gets focus.
final class QuickLaunchPanel: NSPanel {
    var onResignKey: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }
}
