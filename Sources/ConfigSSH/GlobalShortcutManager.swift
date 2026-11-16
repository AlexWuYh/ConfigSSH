import AppKit
import Carbon
import SwiftUI

enum GlobalShortcutChoice: String, CaseIterable, Identifiable {
    case off
    case controlOptionSpace
    case controlShiftSpace
    case optionCommandK

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: "关闭"
        case .controlOptionSpace: "⌃⌥Space"
        case .controlShiftSpace: "⌃⇧Space"
        case .optionCommandK: "⌥⌘K"
        }
    }

    var keyCode: UInt32 {
        switch self {
        case .off: 0
        case .controlOptionSpace, .controlShiftSpace: UInt32(kVK_Space)
        case .optionCommandK: UInt32(kVK_ANSI_K)
        }
    }

    var modifiers: UInt32 {
        switch self {
        case .off: 0
        case .controlOptionSpace: UInt32(controlKey | optionKey)
        case .controlShiftSpace: UInt32(controlKey | shiftKey)
        case .optionCommandK: UInt32(optionKey | cmdKey)
        }
    }
}

private func handleGlobalHotKey(
    _ callRef: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData else { return OSStatus(eventNotHandledErr) }
    let manager = Unmanaged<GlobalShortcutManager>.fromOpaque(userData).takeUnretainedValue()
    DispatchQueue.main.async { manager.showPanel() }
    return noErr
}

@MainActor
final class GlobalShortcutManager {
    static let shared = GlobalShortcutManager()

    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var activeChoice: GlobalShortcutChoice = .off
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

    func showPanel() {
        let window = panel ?? NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 400),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = "ConfigSSH · 快速连接"
        window.contentView = NSHostingView(rootView: QuickLaunchView { [weak self] in self?.closePanel() })
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        panel = window
    }

    func closePanel() {
        panel?.close()
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
