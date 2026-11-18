import AppKit
import Carbon
import ConfigSSHCore
import SwiftUI

enum GlobalShortcutSettings {
    static let defaultsKey = "globalShortcut"

    /// What the user saved: nil means "off", and a missing value means the default.
    static var stored: GlobalShortcut? {
        GlobalShortcut.resolved(UserDefaults.standard.string(forKey: defaultsKey))
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
    /// The shortcut actually registered with the system, which can differ from the saved
    /// preference when registration failed (for example, another app owns the combination).
    private(set) var activeShortcut: GlobalShortcut?
    private var panel: NSPanel?

    private init() { }

    /// Registers `shortcut` (nil switches the hotkey off). On failure the previous hotkey stays
    /// registered and false is returned.
    @discardableResult
    func apply(_ shortcut: GlobalShortcut?) -> Bool {
        if shortcut == activeShortcut { return true }
        let previous = activeShortcut
        unregister()
        guard let shortcut else { return true }
        if register(shortcut) { return true }
        if let previous { _ = register(previous) }
        return false
    }

    /// Releases the hotkey while the settings window records a new one, so pressing the current
    /// combination reaches the recorder instead of opening the panel. Call `apply` afterwards.
    func suspend() { unregister() }

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
        }.frame(width: Self.panelSize.width, height: Self.panelSize.height, alignment: .top)
            .ignoresSafeArea()
            .preferredColorScheme(AppAppearance.colorScheme))
        window.appearance = AppAppearance.nsAppearance
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
            preview.backgroundColor = .clear
            preview.isOpaque = false
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

    private func register(_ shortcut: GlobalShortcut) -> Bool {
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
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, identifier,
                                         GetApplicationEventTarget(), 0, &registered)
        guard status == noErr else { return false }
        hotKey = registered
        activeShortcut = shortcut
        return true
    }

    private func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        activeShortcut = nil
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
