import AppKit
import ConfigSSHCore
import SwiftUI

/// Keycap-style display of a shortcut, e.g. ⌥ ⌘ K.
struct ShortcutKeycaps: View {
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(text.enumerated()), id: \.offset) { _, character in
                Text(String(character))
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .frame(minWidth: 24, minHeight: 24)
                    .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

/// Records one key combination: click "更改…", press the new combination, Esc cancels.
///
/// The current hotkey is released while recording so pressing it reaches this view, and the saved
/// shortcut is registered again afterwards (the caller's `onChange` does that).
@MainActor
@Observable
final class ShortcutRecorderModel {
    var isRecording = false
    var message: String?
    private var monitor: Any?

    func start(onRecorded: @escaping (GlobalShortcut) -> Void) {
        stop(restore: false)
        message = nil
        isRecording = true
        GlobalShortcutManager.shared.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isDisjoint(with: [.command, .control, .option]) {
                self.stop(restore: true)
                return nil
            }
            let candidate = GlobalShortcut(keyCode: UInt32(event.keyCode), modifiers: Self.carbonModifiers(event.modifierFlags))
            if let reason = candidate.problemDescription {
                self.message = reason
                return nil
            }
            self.stop(restore: false)
            onRecorded(candidate)
            return nil
        }
    }

    func stop(restore: Bool) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
        if restore { _ = GlobalShortcutManager.shared.apply(GlobalShortcutSettings.stored) }
    }

    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= GlobalShortcut.command }
        if flags.contains(.shift) { result |= GlobalShortcut.shift }
        if flags.contains(.option) { result |= GlobalShortcut.option }
        if flags.contains(.control) { result |= GlobalShortcut.control }
        return result
    }
}
